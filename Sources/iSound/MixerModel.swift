import AppKit
import AVFoundation
import Combine
import CoreAudio

/// Debug log at ~/Library/Application Support/iSound/debug.log (kept small).
func dlog(_ message: String) {
    let url = Store.directory.appendingPathComponent("debug.log")
    let line = "\(Date().formatted(date: .omitted, time: .standard)) \(message)\n"
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile()
        h.write(line.data(using: .utf8)!)
        if h.offsetInFile > 2_000_000 { h.truncateFile(atOffset: 0) }
        try? h.close()
    } else {
        try? line.data(using: .utf8)!.write(to: url)
    }
}

struct AppRow: Identifiable, Equatable {
    let id: String
    let name: String
    let iconPath: String?
    let symbol: String?
    let isRunning: Bool
    let isPlaying: Bool
    let isCall: Bool
    let isProcessed: Bool
    let error: String?
}

struct AlertItem: Identifiable, Equatable {
    let id = UUID()
    let date = Date()
    let message: String
}

/// How it works:
/// - Normal apps: their audio is captured, muted at the source and re-played through an effect
///   chain (volume, EQ, balance, plug-ins…) to the chosen output(s). Apps with nothing changed
///   are left alone.
/// - During calls (an app playing + using the mic) macOS lowers ("ducks") other sound, so the
///   other apps get an extra "call boost". The call app itself is processed like any other app.
final class MixerModel: ObservableObject {
    let store: Store
    let devices: DeviceManager
    let auHost: AUHost

    @Published private(set) var rows: [AppRow] = []
    @Published private(set) var permission = AudioPermission.current()
    @Published private(set) var callActive = false
    @Published private(set) var levels: [String: Float] = [:]
    @Published private(set) var outputLevel: Float = 0
    @Published private(set) var inputLevel: Float = 0
    @Published private(set) var alerts: [AlertItem] = []
    @Published private(set) var mixerVisible = false { didSet { if mixerVisible != oldValue { updateMeterTimer(); refresh() } } }
    private var visibleViews = 0
    func mixerAppeared() { visibleViews += 1; mixerVisible = visibleViews > 0 }
    func mixerDisappeared() { visibleViews = max(0, visibleViews - 1); mixerVisible = visibleViews > 0 }

    private struct Group {
        let identity: AppIdentity
        var objectIDs: [AudioObjectID] = []
        var isPlaying = false
        var isRecording = false
    }

    private let resolver = AppResolver()
    private let myPID = ProcessInfo.processInfo.processIdentifier
    private var taps: [String: AppTap] = [:]
    private var chains: [String: ChainShared] = [:]
    private var tapErrors: [String: String] = [:]
    private var lastPlaying: [String: Date] = [:]
    private var lastNeeded: [String: Date] = [:]
    private var fadeUntil: [String: Date] = [:]
    private var wasMuted: [String: Bool] = [:]
    private var identities: [String: AppIdentity] = [:]
    private var watchedProcesses = Set<AudioObjectID>()
    private var refreshPending = false
    private var timer: Timer?
    private var meterTimer: Timer?
    private var inputEngine: AVAudioEngine?
    private var inputPeak: Float = 0
    private var cancellables = Set<AnyCancellable>()
    private var latencyWarned = Set<UUID>()

    private static let pendingRestoreKey = "pendingVolumeRestore"

    private let tapLinger: TimeInterval = 10    // keep a capture alive across short pauses
    static let callApps: Set<String> = [
        "net.whatsapp.WhatsApp", "com.apple.avconferenced", "com.apple.FaceTime", "us.zoom.xos",
        "com.microsoft.teams2", "com.microsoft.teams", "com.tinyspeck.slackmacgap", "com.hnc.Discord",
        "com.skype.skype", "com.cisco.webexmeetingsapp", "Cisco-Systems.Spark", "ru.keepcoder.Telegram",
        "com.tdesktop.Telegram", "org.whispersystems.signal-desktop", "com.viber.osx", "com.facebook.archon",
        "com.google.Chrome", "com.brave.Browser", "com.apple.Safari", "org.mozilla.firefox",
        "company.thebrowser.Browser", "com.microsoft.edgemac", "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
    ]
    private static let maxGain: Float = 16      // about +24 dB including call boost

    var prefs: Prefs { store.state.prefs }

    init() {
        store = Store()
        devices = DeviceManager(store: store)
        auHost = AUHost()

        devices.onAlert = { [weak self] in self?.alert($0) }
        devices.onDevicesChanged = { [weak self] in
            self?.stopAllTaps()
            self?.tapErrors.removeAll()
            self?.scheduleRefresh()
        }
        auHost.onLoaded = { [weak self] in self?.scheduleRefresh() }

        store.$state
            .map(\.sources).removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.settingsChanged() } }
            .store(in: &cancellables)
        store.$state
            .map(\.devices).removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.settingsChanged() } }
            .store(in: &cancellables)

        if !Snapshot.isActive {
            restoreVolumeAfterCrash()
            if permission != .authorized { requestPermission(openSettingsIfDenied: false) }
        }
        addSystemListeners()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkTimedMutes()
            self?.refresh()
        }
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.saveAUStates() }
        settingsChanged()
    }

    // MARK: - Source settings

    func setting(for key: String) -> SourceSettings { store.state.sources[key] ?? SourceSettings() }

    func updateSource(_ key: String, coalesce: String? = nil, _ body: (inout SourceSettings) -> Void) {
        let identity = identities[key]
        store.change(coalesce.map { "source.\(key).\($0)" }) { s in
            var v = s.sources[key] ?? SourceSettings()
            body(&v)
            if let identity {
                v.displayName = identity.name
                v.iconPath = identity.iconPath
            }
            let keep = !v.isNeutral || v.favorite || v.menuBarIndicator
            s.sources[key] = keep ? v : nil
        }
    }

    func setVolume(_ volume: Float, for key: String) {
        updateSource(key, coalesce: "volume") { $0.volume = abs(volume - 1.0) < 0.03 ? 1.0 : volume }
    }

    func nudgeVolume(_ key: String, by delta: Float) {
        updateSource(key, coalesce: "volume") { $0.volume = min(max($0.volume + delta, 0), 4); $0.muted = false }
    }

    func toggleMute(_ key: String) {
        updateSource(key) { $0.muted.toggle(); $0.muteUntil = nil }
    }

    func mute(_ key: String, for seconds: TimeInterval) {
        updateSource(key) { $0.muted = true; $0.muteUntil = Date().addingTimeInterval(seconds) }
    }

    func reset(_ key: String) { updateSource(key) { $0.volume = 1; $0.muted = false; $0.muteUntil = nil } }

    private func checkTimedMutes() {
        let now = Date()
        for (key, s) in store.state.sources {
            if let until = s.muteUntil, until <= now {
                fadeUntil[key] = now.addingTimeInterval(2.5)
                updateSource(key) { $0.muted = false; $0.muteUntil = nil }
            }
        }
    }

    // MARK: - Effects

    func effects(of target: EffectTarget) -> [EffectConfig] {
        switch target {
        case .source(let k): setting(for: k).effects
        case .device(let uid): devices.settings(uid).effects
        }
    }

    func updateEffects(_ target: EffectTarget, coalesce: String? = nil, _ body: (inout [EffectConfig]) -> Void) {
        switch target {
        case .source(let k): updateSource(k, coalesce: coalesce) { body(&$0.effects) }
        case .device(let uid): devices.update(uid, coalesce: coalesce) { body(&$0.effects) }
        }
    }

    func addEffect(_ kind: EffectKind, to target: EffectTarget) {
        updateEffects(target) { $0.append(EffectConfig(kind: kind)) }
    }

    /// Copies (or moves) an effect, with its plug-in state, to another app or device.
    func transfer(_ effect: EffectConfig, from: EffectTarget, to: EffectTarget, move: Bool) {
        var copy = effect
        copy.id = UUID()
        if case .audioUnit(var a) = copy.kind {
            a.state = auHost.state(effect.id) ?? a.state
            copy.kind = .audioUnit(a)
        }
        updateEffects(to) { $0.append(copy) }
        if move { updateEffects(from) { $0.removeAll { $0.id == effect.id } } }
    }

    func savePreset(_ effect: EffectConfig, name: String) {
        var kind = effect.kind
        if case .audioUnit(var a) = kind {
            a.state = auHost.state(effect.id) ?? a.state
            kind = .audioUnit(a)
        }
        store.change { $0.presets.append(EffectPreset(name: name, kind: kind)) }
    }

    func applyPreset(_ preset: EffectPreset, to effect: EffectConfig, in target: EffectTarget) {
        updateEffects(target) { list in
            guard let i = list.firstIndex(where: { $0.id == effect.id }) else { return }
            list[i].kind = preset.kind
            if preset.kind.isAudioUnit { list[i].id = UUID() }  // reload the plug-in with the preset's state
        }
    }

    func toggleFavoriteEffect(_ key: String) {
        store.change(undoable: false) { s in
            if let i = s.favoriteEffects.firstIndex(of: key) { s.favoriteEffects.remove(at: i) } else { s.favoriteEffects.append(key) }
        }
    }

    func saveAUStates() {
        var updates: [(EffectTarget, UUID, Data)] = []
        for (key, s) in store.state.sources {
            for e in s.effects where e.kind.isAudioUnit { if let d = auHost.state(e.id) { updates.append((.source(key), e.id, d)) } }
        }
        for (uid, s) in store.state.devices {
            for e in s.effects where e.kind.isAudioUnit { if let d = auHost.state(e.id) { updates.append((.device(uid), e.id, d)) } }
        }
        guard !updates.isEmpty else { return }
        store.change(undoable: false) { s in
            for (target, id, data) in updates {
                func patch(_ list: inout [EffectConfig]) {
                    guard let i = list.firstIndex(where: { $0.id == id }), case .audioUnit(var a) = list[i].kind, a.state != data else { return }
                    a.state = data
                    list[i].kind = .audioUnit(a)
                }
                switch target {
                case .source(let k): if s.sources[k] != nil { patch(&s.sources[k]!.effects) }
                case .device(let u): if s.devices[u] != nil { patch(&s.devices[u]!.effects) }
                }
            }
        }
    }

    // MARK: - Output (system) volume

    var outputDevice: AudioDevice? { devices.device(id: devices.defaultOutput) }
    var inputDevice: AudioDevice? { devices.device(id: devices.defaultInput) }

    func outputVolume() -> Float {
        guard let d = outputDevice else { return 0 }
        if devices.usesSoftwareVolume(d) { return devices.settings(d.uid).softwareVolume }
        return devices.hardwareVolume(d.id) ?? 0
    }

    func isOutputMuted() -> Bool {
        guard let d = outputDevice else { return false }
        if devices.usesSoftwareVolume(d) { return devices.settings(d.uid).softwareMuted }
        return devices.isMuted(d.id)
    }

    func setOutputVolume(_ v: Float) {
        guard let d = outputDevice else { return }
        if devices.usesSoftwareVolume(d) {
            let maxV = devices.settings(d.uid).maxVolume ?? 1
            devices.update(d.uid, coalesce: "swvol") { $0.softwareVolume = min(max(v, 0), maxV); $0.softwareMuted = false }
        } else {
            devices.setHardwareVolume(d.id, v)
        }
    }

    func toggleOutputMute() {
        guard let d = outputDevice else { return }
        if devices.usesSoftwareVolume(d) {
            devices.update(d.uid) { $0.softwareMuted.toggle() }
        } else if devices.canMute(d.id) {
            devices.setMuted(d.id, !devices.isMuted(d.id))
        }
    }

    func nudgeOutputVolume(_ delta: Float) { setOutputVolume(outputVolume() + delta) }

    // MARK: - Microphone

    func inputVolume() -> Float { inputDevice.flatMap { devices.hardwareVolume($0.id, input: true) } ?? 0 }
    func setInputVolume(_ v: Float) { if let d = inputDevice { devices.setHardwareVolume(d.id, v, input: true) } }
    func isMicMuted() -> Bool { inputDevice.map { devices.isMuted($0.id, input: true) || (devices.hardwareVolume($0.id, input: true) ?? 1) == 0 } ?? false }

    /// "Cough button": mutes the mic, using volume 0 if the device has no mute switch.
    private var micVolumeBeforeMute: Float?
    func toggleMicMute() {
        guard let d = inputDevice else { return }
        if devices.canMute(d.id, input: true) {
            devices.setMuted(d.id, !devices.isMuted(d.id, input: true), input: true)
        } else if let saved = micVolumeBeforeMute {
            devices.setHardwareVolume(d.id, saved, input: true)
            micVolumeBeforeMute = nil
        } else {
            micVolumeBeforeMute = devices.hardwareVolume(d.id, input: true)
            devices.setHardwareVolume(d.id, 0, input: true)
        }
        objectWillChange.send()
    }

    // MARK: - Quick configs

    func saveQuickConfig(name: String) {
        saveAUStates()
        let s = store.state
        let config = QuickConfig(name: name, sources: s.sources, devices: s.devices,
                                 defaultOutputUID: outputDevice?.uid, defaultInputUID: inputDevice?.uid,
                                 callBoost: s.prefs.callBoost)
        store.change { $0.quickConfigs.append(config) }
    }

    func applyQuickConfig(_ c: QuickConfig) {
        store.change { s in
            s.sources = c.sources
            s.devices = c.devices
            if let b = c.callBoost { s.prefs.callBoost = b }
        }
        if let uid = c.defaultOutputUID, let d = devices.device(uid: uid) { devices.setDefaultOutput(d) }
        if let uid = c.defaultInputUID, let d = devices.device(uid: uid) { devices.setDefaultInput(d) }
        alert("Applied “\(c.name)”")
    }

    // MARK: - Shortcut actions

    func perform(_ action: HotkeyAction) {
        let step = prefs.volumeKeyStep
        switch action {
        case .toggleMicMute: toggleMicMute(); VolumeHUD.shared.show(symbol: isMicMuted() ? "mic.slash.fill" : "mic.fill", level: nil)
        case .outputVolumeUp: nudgeOutputVolume(step); VolumeHUD.shared.show(symbol: "speaker.wave.3.fill", level: outputVolume())
        case .outputVolumeDown: nudgeOutputVolume(-step); VolumeHUD.shared.show(symbol: "speaker.wave.1.fill", level: outputVolume())
        case .toggleOutputMute: toggleOutputMute(); VolumeHUD.shared.show(symbol: isOutputMuted() ? "speaker.slash.fill" : "speaker.wave.2.fill", level: isOutputMuted() ? 0 : outputVolume())
        case .appVolumeUp(let k): nudgeVolume(k, by: 0.1); VolumeHUD.shared.show(symbol: "app", title: name(of: k), level: setting(for: k).volume / 4)
        case .appVolumeDown(let k): nudgeVolume(k, by: -0.1); VolumeHUD.shared.show(symbol: "app", title: name(of: k), level: setting(for: k).volume / 4)
        case .appToggleMute(let k): toggleMute(k); VolumeHUD.shared.show(symbol: setting(for: k).muted ? "speaker.slash.fill" : "speaker.wave.2.fill", title: name(of: k), level: nil)
        case .setOutput(let uid): if let d = devices.device(uid: uid) { devices.setDefaultOutput(d); VolumeHUD.shared.show(symbol: devices.symbol(d), title: devices.displayName(d), level: nil) }
        case .setInput(let uid): if let d = devices.device(uid: uid) { devices.setDefaultInput(d); VolumeHUD.shared.show(symbol: "mic.fill", title: devices.displayName(d), level: nil) }
        case .applyQuickConfig(let id): if let c = store.state.quickConfigs.first(where: { $0.id == id }) { applyQuickConfig(c) }
        case .showMixer: NotificationCenter.default.post(name: .showMixerWindow, object: nil)
        }
    }

    func name(of key: String) -> String {
        identities[key]?.name ?? setting(for: key).displayName ?? key
    }

    // MARK: - Permission

    func requestPermission(openSettingsIfDenied: Bool = true) {
        AudioPermission.request { [weak self] granted in
            guard let self else { return }
            // Trust the answer to the request: the quick check can report "unknown" even when allowed.
            self.permission = granted ? .authorized : AudioPermission.current()
            dlog("permission request -> \(granted)")
            if !granted && openSettingsIfDenied { AudioPermission.openSettings() }
            self.refresh()
        }
    }

    func shutdown() {
        saveAUStates()
        store.saveNow()
        stopAllTaps()
    }

    private func stopAllTaps() {
        taps.values.forEach { $0.stop() }
        taps.removeAll()
    }

    func alert(_ message: String) {
        alerts.insert(AlertItem(message: message), at: 0)
        if alerts.count > 100 { alerts.removeLast() }
    }

    func clearAlerts() { alerts.removeAll() }

    // MARK: - Refresh

    private func settingsChanged() {
        let all = store.state.sources.values.flatMap(\.effects) + store.state.devices.values.flatMap(\.effects)
        auHost.sync(all)
        refresh()
    }

    private func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.async { [weak self] in
            self?.refreshPending = false
            self?.refresh()
        }
    }

    func refresh() {
        if permission == .unknown, AudioPermission.current() == .authorized { permission = .authorized }
        debugOnce("_perm", "permission \(permission)")

        let processes = AudioProcess.all().filter { $0.pid != myPID && $0.bundleID?.hasPrefix("com.sourabh.isound") != true }
        resolver.prune(keeping: Set(processes.map(\.pid)))
        watchProcesses(processes)

        var groups: [String: Group] = [:]
        for p in processes {
            let id = resolver.identity(for: p)
            groups[id.key, default: Group(identity: id)].objectIDs.append(p.objectID)
            if p.isPlaying { groups[id.key]?.isPlaying = true }
            if p.isRecording { groups[id.key]?.isRecording = true }
            identities[id.key] = id
        }

        let now = Date()
        for (key, g) in groups where g.isPlaying { lastPlaying[key] = now }

        // A call = a known calling app (or browser, for web calls) that is playing and using the mic.
        // Dictation apps also use the mic, so they don't count.
        let callKeys = Set(groups.values.filter {
            $0.isPlaying && $0.isRecording && Self.callApps.contains($0.identity.key)
        }.map(\.identity.key))
        if callActive != !callKeys.isEmpty { callActive = !callKeys.isEmpty }

        // Capture and re-play each adjusted app (call apps included) with its chain.
        updateTaps(groups: groups, callKeys: callKeys, now: now)

        // 3. Rows: recent noise, playing, processed, favourites.
        let recent = prefs.recentSeconds
        var newRows: [AppRow] = groups.values.compactMap { g in
            let key = g.identity.key
            let s = setting(for: key)
            let show = g.isPlaying || taps[key]?.muteSource == true || s.favorite
                || now.timeIntervalSince(lastPlaying[key] ?? .distantPast) < recent
            guard show else { return nil }
            let isCall = callKeys.contains(key)
            let error = tapErrors[key]
            return AppRow(id: key, name: g.identity.name, iconPath: g.identity.iconPath, symbol: g.identity.symbol,
                          isRunning: true, isPlaying: g.isPlaying, isCall: isCall,
                          isProcessed: taps[key]?.muteSource == true, error: error)
        }
        for (key, s) in store.state.sources where s.favorite && groups[key] == nil {
            newRows.append(AppRow(id: key, name: s.displayName ?? key, iconPath: s.iconPath, symbol: nil,
                                  isRunning: false, isPlaying: false, isCall: false, isProcessed: false, error: nil))
        }
        newRows.sort {
            if $0.isRunning != $1.isRunning { return $0.isRunning }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        if newRows != rows { rows = newRows }
        updateSystemMeter()
    }

    /// Output devices (with channel maps) for a source, expanding output groups.
    private func outputs(for target: OutputTarget) -> [TapOutput] {
        var uids: [String]
        switch target {
        case .system:
            uids = devices.defaultOutput.flatMap(CA.deviceUID).map { [$0] } ?? []
        case .device(let uid):
            uids = devices.device(uid: uid) != nil ? [uid] : (devices.defaultOutput.flatMap(CA.deviceUID).map { [$0] } ?? [])
        case .group(let id):
            uids = store.state.groups.first { $0.id == id }?.deviceUIDs ?? []
        }
        // A system group device can't be nested in our capture device: use its members.
        uids = uids.flatMap { uid -> [String] in
            if let g = store.state.groups.first(where: { $0.uid == uid }) { return g.deviceUIDs }
            if let d = devices.device(uid: uid), d.transport == kAudioDeviceTransportTypeAggregate, Self.isStacked(d.id) {
                return DeviceManager.subDeviceUIDs(d.id)
            }
            return [uid]
        }
        return uids.compactMap { uid in
            guard let d = devices.device(uid: uid), d.hasOutput else { return nil }
            return TapOutput(device: d.id, uid: uid, channelMap: channelMap(d))
        }
    }

    private static func isStacked(_ id: AudioDeviceID) -> Bool {
        var addr = CA.address(kAudioAggregateDevicePropertyComposition)
        var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        var ref: Unmanaged<CFDictionary>?
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &ref) == noErr, let ref else { return false }
        let dict = ref.takeRetainedValue() as? [String: Any]
        return (dict?[kAudioAggregateDeviceIsStackedKey] as? Int ?? 0) != 0
    }

    private func channelMap(_ d: AudioDevice) -> [Int32] {
        let s = devices.settings(d.uid)
        let n = d.outputChannels
        var map = [Int32](repeating: -1, count: n)
        guard n > 0 else { return map }
        if n == 1 { map[0] = 2; return map }
        let o = min(max(s.channelOffset, 0), n - 2)
        switch s.channelMode {
        case .stereo: map[o] = 0; map[o + 1] = 1
        case .swapped: map[o] = 1; map[o + 1] = 0
        case .monoLeft: map[o] = 2
        case .monoRight: map[o + 1] = 2
        case .allPairs:
            for i in stride(from: 0, to: n - 1, by: 2) { map[i] = 0; map[i + 1] = 1 }
        }
        return map
    }

    private func isDefaultRouting(_ outs: [TapOutput]) -> Bool {
        guard outs.count == 1, let o = outs.first, o.device == devices.defaultOutput else { return false }
        let s = devices.settings(o.uid)
        return s.channelMode == .stereo && s.channelOffset == 0
    }

    private func updateTaps(groups: [String: Group], callKeys: Set<String>, now: Date) {
        if Snapshot.isActive { return }   // a second copy rendering screenshots must not touch audio
        guard permission == .authorized else {
            debugOnce("_noperm", "no permission (\(String(describing: self.permission)))")
            stopAllTaps()
            return
        }

        for key in taps.keys where groups[key] == nil {
            taps.removeValue(forKey: key)?.stop()
        }

        for (key, group) in groups {
            let s = setting(for: key)
            let outs = outputs(for: s.output)
            guard let first = outs.first, let firstDevice = devices.device(id: first.device) else {
                if group.isPlaying { debugOnce(key, "no output for \(key) target=\(String(describing: s.output)) default=\(String(describing: devices.defaultOutput)) devices=\(devices.devices.count)") }
                taps.removeValue(forKey: key)?.stop()
                continue
            }
            let isCall = callKeys.contains(key)
            let recentlyPlaying = now.timeIntervalSince(lastPlaying[key] ?? .distantPast) < tapLinger
            // Smooth unmute: fade back in instead of jumping.
            if wasMuted[key] == true && !s.muted && prefs.smoothUnmute {
                fadeUntil[key] = max(fadeUntil[key] ?? now, now.addingTimeInterval(1.2))
            }
            wasMuted[key] = s.muted
            if let f = fadeUntil[key], f <= now { fadeUntil[key] = nil }
            let fading = fadeUntil[key] != nil

            // Gain: app volume × output's software volume × call boost (macOS lowers other
            // sound during calls; the boost makes up for it).
            let devSettings = devices.settings(first.uid)
            var gain = s.gain
            if devices.usesSoftwareVolume(firstDevice) {
                gain *= devSettings.softwareMuted ? 0 : devSettings.softwareVolume
            }
            if callActive && !isCall { gain *= prefs.callBoost }
            gain = min(gain, Self.maxGain)

            let effectList = s.effects + devSettings.effects
            let hasEffects = effectList.contains { !$0.bypassed }
            let needsProcessing = abs(gain - 1) > 0.005 || hasEffects || !isDefaultRouting(outs) || fading
            if needsProcessing { lastNeeded[key] = now }
            let recentlyNeeded = now.timeIntervalSince(lastNeeded[key] ?? .distantPast) < 3
            let process = recentlyPlaying && recentlyNeeded
            let meterOnly = !process && group.isPlaying && prefs.showMeters
                && (mixerVisible || prefs.menuBarIcon == .meter || s.menuBarIndicator)
            if group.isPlaying {
                debugOnce(key, "\(key) gain=\(gain) vol=\(s.volume) call=\(isCall) callActive=\(callActive) needs=\(needsProcessing) process=\(process) meter=\(meterOnly)")
            }

            guard process || meterOnly else {
                taps.removeValue(forKey: key)?.stop()
                tapErrors[key] = nil
                continue
            }

            let chain = chains[key] ?? ChainShared()
            chains[key] = chain

            let loadedAUs: [(UUID, AUAudioUnit)] = process ? effectList.compactMap { e in
                guard e.kind.isAudioUnit, let u = auHost.unit(e.id) else { return nil }
                return (e.id, u)
            } : []
            let auIndex = Dictionary(uniqueKeysWithValues: loadedAUs.enumerated().map { ($1.0, $0) })
            let sampleRate = taps[key]?.sampleRate ?? devices.sampleRate(first.device) ?? 48000
            let compiled = ChainCompiler.compile(process ? effectList : [], sampleRate: sampleRate) { auIndex[$0] }
            let fade: Float = fading ? Float(max((fadeUntil[key] ?? now).timeIntervalSince(now), 0.3)) : 0.015
            chain.publish(gain: process ? gain : 1, fadeSeconds: fade, outputEnabled: process,
                          stages: compiled.stages, biquads: compiled.biquads)

            for (id, _) in loadedAUs where auHost.latency(id) > 0.03 && !latencyWarned.contains(id) {
                latencyWarned.insert(id)
                let ms = Int(auHost.latency(id) * 1000)
                alert("\(effectList.first { $0.id == id }?.displayName ?? "An effect") on \(group.identity.name) adds \(ms) ms of delay.")
            }

            let ids = group.objectIDs.sorted()
            if let tap = taps[key], tap.processObjectIDs == ids, tap.outputs == outs,
               tap.auEffectIDs == loadedAUs.map(\.0), tap.muteSource == process {
                continue
            }
            if tapErrors[key] != nil, taps[key] == nil, !group.isPlaying { continue }

            let old = taps.removeValue(forKey: key)
            if let old {
                dlog("rebuild \(key): ids \(old.processObjectIDs == ids) outs \(old.outputs == outs) au \(old.auEffectIDs == loadedAUs.map(\.0)) mode \(old.muteSource == process)")
                old.stop()
            }
            do {
                taps[key] = try AppTap(name: group.identity.name, processObjectIDs: ids, outputs: outs,
                                       shared: chain, audioUnits: loadedAUs, muteSource: process)
                dlog("tap \(key) process=\(process) gain=\(gain) ids=\(ids) out=\(outs.map(\.uid))")
                tapErrors[key] = nil
            } catch {
                dlog("tap \(key) failed: \(error.localizedDescription)")
                if tapErrors[key] != error.localizedDescription {
                    alert("\(group.identity.name): \(error.localizedDescription)")
                }
                tapErrors[key] = error.localizedDescription
            }
        }
    }

    private var lastDebug: [String: String] = [:]
    private func debugOnce(_ key: String, _ msg: String) {
        guard lastDebug[key] != msg else { return }
        lastDebug[key] = msg
        dlog("\(msg)")
    }

    // MARK: - Meters

    private func updateMeterTimer() {
        let wanted = ((mixerVisible || prefs.menuBarIcon == .meter) && prefs.showMeters) || prefs.menuBarIcon == .meter
            || store.state.sources.values.contains { $0.menuBarIndicator }
        if wanted && meterTimer == nil {
            meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in self?.readMeters() }
        } else if !wanted, let t = meterTimer {
            t.invalidate()
            meterTimer = nil
            levels = [:]
            outputLevel = 0
        }
        updateInputMeter()
    }

    private func readMeters() {
        var next: [String: Float] = [:]
        for (key, chain) in chains where taps[key] != nil {
            let (l, r) = chain.takeMeters()
            let v = max(l, r)
            next[key] = max(v, (levels[key] ?? 0) * 0.7)   // gentle fall-off
        }
        if next != levels { levels = next }
        let o = max(next.values.max() ?? 0, outputLevel * 0.7)
        if abs(o - outputLevel) > 0.002 { outputLevel = o }
        let i = max(inputPeak, inputLevel * 0.7)
        inputPeak = 0
        if abs(i - inputLevel) > 0.002 { inputLevel = i }
    }

    /// The output meter is the loudest app meter. (A whole-system listen-only capture would
    /// un-mute apps that are being processed and play them twice, which sounds distorted.)
    private func updateSystemMeter() {}

    /// Mic level (off by default: reading the mic turns on the orange mic indicator).
    private func updateInputMeter() {
        let wanted = mixerVisible && prefs.showInputMeter
        if wanted, inputEngine == nil {
            let engine = AVAudioEngine()
            let node = engine.inputNode
            let format = node.outputFormat(forBus: 0)
            guard format.channelCount > 0 else { return }
            node.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
                guard let data = buf.floatChannelData else { return }
                var peak: Float = 0
                for c in 0..<Int(buf.format.channelCount) {
                    for f in 0..<Int(buf.frameLength) { peak = max(peak, abs(data[c][f])) }
                }
                DispatchQueue.main.async { self?.inputPeak = max(self?.inputPeak ?? 0, peak) }
            }
            try? engine.start()
            inputEngine = engine
        } else if !wanted, let engine = inputEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            inputEngine = nil
            inputLevel = 0
        }
    }

    func prefsChanged() {
        updateMeterTimer()
        refresh()
    }

    // MARK: - Old call-volume cleanup

    /// An earlier version lowered the hardware volume during calls. If it quit mid-call, undo that.
    private func restoreVolumeAfterCrash() {
        guard let saved = UserDefaults.standard.dictionary(forKey: Self.pendingRestoreKey),
              let uid = saved["uid"] as? String, let db = saved["db"] as? Float32 else { return }
        if let device = DeviceVolume.device(withUID: uid) { DeviceVolume.shift(device, by: -db) }
        UserDefaults.standard.removeObject(forKey: Self.pendingRestoreKey)
    }

    // MARK: - Change notifications

    private func addSystemListeners() {
        var procs = CA.address(kAudioHardwarePropertyProcessObjectList)
        AudioObjectAddPropertyListenerBlock(CA.system, &procs, .main) { [weak self] _, _ in self?.scheduleRefresh() }
    }

    private func watchProcesses(_ processes: [AudioProcess]) {
        let current = Set(processes.map(\.objectID))
        watchedProcesses.formIntersection(current)
        for p in processes where !watchedProcesses.contains(p.objectID) {
            var out = CA.address(kAudioProcessPropertyIsRunningOutput)
            var inp = CA.address(kAudioProcessPropertyIsRunningInput)
            let a = AudioObjectAddPropertyListenerBlock(p.objectID, &out, .main) { [weak self] _, _ in self?.scheduleRefresh() }
            AudioObjectAddPropertyListenerBlock(p.objectID, &inp, .main) { [weak self] _, _ in self?.scheduleRefresh() }
            if a == noErr { watchedProcesses.insert(p.objectID) }
        }
    }
}

// MARK: - Shortcut bindings

extension MixerModel {
    func binding(for action: HotkeyAction) -> HotkeyBinding? {
        store.state.hotkeys.first { $0.action == action }
    }

    func setBinding(_ action: HotkeyAction, keyCode: UInt32, modifiers: UInt32) {
        store.change(undoable: false) { s in
            s.hotkeys.removeAll { $0.action == action || ($0.keyCode == keyCode && $0.modifiers == modifiers) }
            s.hotkeys.append(HotkeyBinding(action: action, keyCode: keyCode, modifiers: modifiers))
        }
    }

    func clearBinding(_ action: HotkeyAction) {
        store.change(undoable: false) { s in s.hotkeys.removeAll { $0.action == action } }
    }

    func setPrefs(_ body: (inout Prefs) -> Void) {
        store.change(undoable: false) { body(&$0.prefs) }
        prefsChanged()
    }
}

enum EffectTarget: Hashable {
    case source(String)
    case device(String)
}

extension Notification.Name {
    static let showMixerWindow = Notification.Name("iSound.showMixerWindow")
}
