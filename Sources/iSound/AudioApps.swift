import AppKit
import CoreAudio
import Darwin

/// One process that Core Audio knows about.
struct AudioProcess {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let isPlaying: Bool
    let isRecording: Bool

    static func all() -> [AudioProcess] {
        CA.getIDs(CA.system, kAudioHardwarePropertyProcessObjectList).compactMap { id in
            guard let pid = CA.get(id, kAudioProcessPropertyPID, initial: pid_t(0)), pid > 0 else { return nil }
            let playing = (CA.get(id, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0)) ?? 0) != 0
            let recording = (CA.get(id, kAudioProcessPropertyIsRunningInput, initial: UInt32(0)) ?? 0) != 0
            return AudioProcess(objectID: id, pid: pid,
                                bundleID: CA.getString(id, kAudioProcessPropertyBundleID),
                                isPlaying: playing, isRecording: recording)
        }
    }
}

/// The app a user would recognise (e.g. "Google Chrome" instead of "Google Chrome Helper").
struct AppIdentity: Hashable {
    let key: String
    let name: String
    let iconPath: String?
    var symbol: String? = nil
}

/// System audio sources that aren't normal apps.
enum SpecialSource {
    struct Info { let key: String; let name: String; let symbol: String; let iconPath: String? }

    /// Matched against the process bundle ID or process name.
    static let table: [(match: [String], info: Info)] = [
        (["com.apple.avconferenced", "avconferenced"],
         Info(key: "com.apple.avconferenced", name: "FaceTime calls", symbol: "phone.fill", iconPath: "/System/Applications/FaceTime.app")),
        (["systemsoundserverd", "com.apple.systemsoundserverd"],
         Info(key: "special.soundeffects", name: "Sound Effects", symbol: "bell.fill", iconPath: nil)),
        (["com.apple.siri", "Siri", "assistantd", "com.apple.assistantd", "com.apple.SiriNCService", "siriactionsd"],
         Info(key: "special.siri", name: "Siri", symbol: "waveform.circle.fill", iconPath: "/System/Applications/Siri.app")),
        (["com.apple.VoiceOver", "VoiceOver"],
         Info(key: "special.voiceover", name: "VoiceOver", symbol: "voiceover", iconPath: nil)),
        (["com.apple.speech.speechsynthesisd", "speechsynthesisd", "com.apple.SpeechSynthesisServer"],
         Info(key: "special.tts", name: "Text to Speech", symbol: "text.bubble.fill", iconPath: nil)),
        (["heard", "com.apple.accessibility.heard"],
         Info(key: "special.backgroundsounds", name: "Background Sounds", symbol: "water.waves", iconPath: nil)),
        (["com.apple.controlcenter", "ControlCenter"],
         Info(key: "com.apple.controlcenter", name: "Control Center", symbol: "switch.2", iconPath: nil)),
    ]

    static func match(bundleID: String?, processName: String?) -> Info? {
        for entry in table {
            if let b = bundleID, entry.match.contains(b) { return entry.info }
            if let n = processName, entry.match.contains(n) { return entry.info }
        }
        return nil
    }
}

/// Maps helper processes (browser renderers, WebKit GPU processes…) to the app that owns them.
final class AppResolver {
    private var cache: [pid_t: AppIdentity] = [:]

    func identity(for process: AudioProcess) -> AppIdentity {
        if let cached = cache[process.pid] { return cached }
        let id = resolve(process)
        cache[process.pid] = id
        return id
    }

    func prune(keeping pids: Set<pid_t>) {
        cache = cache.filter { pids.contains($0.key) }
    }

    private func resolve(_ process: AudioProcess) -> AppIdentity {
        let pid = process.pid
        if let special = SpecialSource.match(bundleID: process.bundleID, processName: Self.processName(pid)) {
            return AppIdentity(key: special.key, name: special.name, iconPath: special.iconPath, symbol: special.symbol)
        }
        var chain: [pid_t] = [pid]
        if let r = Self.responsiblePID(pid), r > 1, r != pid { chain.append(r) }
        var current = pid
        for _ in 0..<6 {
            let parent = Self.parentPID(current)
            guard parent > 1, !chain.contains(parent) else { break }
            chain.append(parent)
            current = parent
        }

        // Prefer a normal Dock app, then a menu-bar app.
        for policy in [NSApplication.ActivationPolicy.regular, .accessory] {
            for candidate in chain {
                if let app = NSRunningApplication(processIdentifier: candidate),
                   app.activationPolicy == policy, let bid = app.bundleIdentifier {
                    return AppIdentity(key: bid, name: app.localizedName ?? bid, iconPath: app.bundleURL?.path)
                }
            }
        }

        let bid = process.bundleID ?? ""
        let procName = Self.processName(pid)
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? procName ?? (bid.isEmpty ? "PID \(pid)" : bid)
        return AppIdentity(key: bid.isEmpty ? "pid.\(pid)" : bid, name: name,
                           iconPath: NSRunningApplication(processIdentifier: pid)?.bundleURL?.path)
    }

    // MARK: - Process helpers

    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    private static let responsibleFn: ResponsibleFn? = {
        guard let handle = dlopen(nil, RTLD_NOW),
              let sym = dlsym(handle, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: ResponsibleFn.self)
    }()

    static func responsiblePID(_ pid: pid_t) -> pid_t? { responsibleFn?(pid) }

    static func parentPID(_ pid: pid_t) -> pid_t {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return 0 }
        return pid_t(info.pbi_ppid)
    }

    static func processName(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(cString: buf)
    }
}

/// Wraps the "System Audio Recording" privacy permission (TCC service kTCCServiceAudioCapture).
enum AudioPermission {
    enum Status { case unknown, authorized, denied }

    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFn = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void
    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    static func current() -> Status {
        guard let tcc, let sym = dlsym(tcc, "TCCAccessPreflight") else { return .unknown }
        switch unsafeBitCast(sym, to: PreflightFn.self)(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .unknown
        }
    }

    static func request(_ done: @escaping (Bool) -> Void) {
        guard let tcc, let sym = dlsym(tcc, "TCCAccessRequest") else { done(false); return }
        unsafeBitCast(sym, to: RequestFn.self)(service, nil) { granted in
            DispatchQueue.main.async { done(granted) }
        }
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
