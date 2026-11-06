import AppKit
import AudioToolbox
import Combine
import CoreAudio
import IOBluetooth

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transport: UInt32
    let inputChannels: Int
    let outputChannels: Int
    let modelUID: String?

    var hasOutput: Bool { outputChannels > 0 }
    var hasInput: Bool { inputChannels > 0 }
    var isBluetooth: Bool {
        transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }
    var isAirPlay: Bool { transport == kAudioDeviceTransportTypeAirPlay }
    var isGroup: Bool { uid.hasPrefix(DeviceManager.groupPrefix) }
    var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }

    var defaultSymbol: String {
        if isGroup { return "hifispeaker.2.fill" }
        if isAirPlay { return "airplayaudio" }
        let n = name.lowercased()
        if n.contains("airpods max") { return "airpodsmax" }
        if n.contains("airpods pro") { return "airpodspro" }
        if n.contains("airpods") { return "airpods" }
        if isBluetooth { return n.contains("speaker") ? "hifispeaker.fill" : "headphones" }
        if n.contains("headphone") { return "headphones" }
        if n.contains("microphone") || (hasInput && !hasOutput) { return "mic.fill" }
        if transport == kAudioDeviceTransportTypeHDMI || transport == kAudioDeviceTransportTypeDisplayPort { return "tv" }
        if transport == kAudioDeviceTransportTypeVirtual { return "waveform" }
        if transport == kAudioDeviceTransportTypeUSB { return "cable.connector" }
        if transport == kAudioDeviceTransportTypeAggregate { return "square.stack.3d.up.fill" }
        return isBuiltIn ? "laptopcomputer" : "speaker.wave.2.fill"
    }
}

struct DataSource: Identifiable, Hashable {
    let id: UInt32
    let name: String
}

/// Lists audio devices and applies per-device rules (max volume, locks, output-only, preferred order…).
final class DeviceManager: ObservableObject {
    static let privatePrefix = "com.sourabh.isound.tap."
    static let groupPrefix = "com.sourabh.isound-group."

    @Published private(set) var devices: [AudioDevice] = []
    @Published private(set) var defaultOutput: AudioDeviceID?
    @Published private(set) var defaultInput: AudioDeviceID?
    @Published private(set) var batteries: [String: String] = [:]   // device name -> "L 80% · R 75%"
    /// Bumped whenever a volume/mute/rate changes, so views re-read hardware values.
    @Published private(set) var tick = 0

    let store: Store
    var onAlert: ((String) -> Void)?
    var onDevicesChanged: (() -> Void)?

    private var watched = Set<AudioDeviceID>()
    private var timer: Timer?
    private var batteryTimer: Timer?
    private var lastDeviceUIDs: Set<String> = []
    private var cancellables = Set<AnyCancellable>()

    init(store: Store) {
        self.store = store
        reload()
        lastDeviceUIDs = Set(devices.map(\.uid))
        syncGroups()
        addListeners()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.enforce() }
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.refreshBatteries() }
        refreshBatteries()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self?.reconnectBluetooth() }
        }
    }

    // MARK: - Listing

    var outputs: [AudioDevice] { devices.filter(\.hasOutput) }
    var inputs: [AudioDevice] { devices.filter(\.hasInput) }
    var visibleOutputs: [AudioDevice] { outputs.filter { !settings($0.uid).hidden } }
    var visibleInputs: [AudioDevice] { inputs.filter { !settings($0.uid).hidden } }

    func device(uid: String) -> AudioDevice? { devices.first { $0.uid == uid } }
    func device(id: AudioDeviceID?) -> AudioDevice? { devices.first { $0.id == id } }
    func settings(_ uid: String) -> DeviceSettings { store.state.devices[uid] ?? DeviceSettings() }

    func displayName(_ d: AudioDevice) -> String { settings(d.uid).nickname.flatMap { $0.isEmpty ? nil : $0 } ?? d.name }
    func symbol(_ d: AudioDevice) -> String { settings(d.uid).icon ?? d.defaultSymbol }

    func reload() {
        let list = CA.getIDs(CA.system, kAudioHardwarePropertyDevices).compactMap { id -> AudioDevice? in
            guard let uid = CA.deviceUID(id), !uid.hasPrefix(Self.privatePrefix) else { return nil }
            let ins = Self.channelCount(id, kAudioObjectPropertyScopeInput)
            let outs = Self.channelCount(id, kAudioObjectPropertyScopeOutput)
            // A device that was just removed can linger for a moment with no channels; skip it.
            guard ins + outs > 0 else { return nil }
            return AudioDevice(id: id, uid: uid, name: CA.name(id) ?? uid,
                               transport: CA.get(id, kAudioDevicePropertyTransportType, initial: UInt32(0)) ?? 0,
                               inputChannels: ins, outputChannels: outs,
                               modelUID: CA.getString(id, kAudioDevicePropertyModelUID))
        }
        if list != devices { devices = list }
        let out = CA.defaultOutputDevice()
        let inp = CA.get(CA.system, kAudioHardwarePropertyDefaultInputDevice, initial: AudioDeviceID(0)).flatMap { $0 == 0 ? nil : $0 }
        if out != defaultOutput { defaultOutput = out }
        if inp != defaultInput { defaultInput = inp }
        for d in list where !watched.contains(d.id) { watch(d.id) }
    }

    static func channelCount(_ id: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Int {
        var addr = CA.address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    // MARK: - Default devices

    func setDefaultOutput(_ d: AudioDevice) {
        var id = d.id
        var addr = CA.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectSetPropertyData(CA.system, &addr, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &id)
        if store.state.prefs.moveSystemSoundsWithOutput {
            var sys = CA.address(kAudioHardwarePropertyDefaultSystemOutputDevice)
            AudioObjectSetPropertyData(CA.system, &sys, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &id)
        }
        reload()
    }

    func setDefaultInput(_ d: AudioDevice) {
        var id = d.id
        var addr = CA.address(kAudioHardwarePropertyDefaultInputDevice)
        AudioObjectSetPropertyData(CA.system, &addr, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &id)
        reload()
    }

    // MARK: - Hardware controls

    private func scope(_ input: Bool) -> AudioObjectPropertyScope { input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput }

    func hasHardwareVolume(_ id: AudioDeviceID, input: Bool = false) -> Bool {
        var addr = CA.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope(input))
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(id, &addr) && AudioObjectIsPropertySettable(id, &addr, &settable) == noErr && settable.boolValue
    }

    /// True when iSound handles this output's volume in software.
    func usesSoftwareVolume(_ d: AudioDevice) -> Bool {
        settings(d.uid).forceSoftwareVolume || !hasHardwareVolume(d.id)
    }

    func hardwareVolume(_ id: AudioDeviceID, input: Bool = false) -> Float? {
        CA.get(id, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope(input), initial: Float32(0))
    }

    func setHardwareVolume(_ id: AudioDeviceID, _ v: Float, input: Bool = false) {
        var value = Float32(min(max(v, 0), 1))
        if !input, let uid = CA.deviceUID(id), let maxV = settings(uid).maxVolume { value = min(value, maxV) }
        var addr = CA.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope(input))
        AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        if !input, value > 0, isMuted(id) { setMuted(id, false) }
        tick &+= 1
    }

    func isMuted(_ id: AudioDeviceID, input: Bool = false) -> Bool {
        (CA.get(id, kAudioDevicePropertyMute, scope: scope(input), initial: UInt32(0)) ?? 0) != 0
    }

    func canMute(_ id: AudioDeviceID, input: Bool = false) -> Bool {
        var addr = CA.address(kAudioDevicePropertyMute, scope(input))
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(id, &addr) && AudioObjectIsPropertySettable(id, &addr, &settable) == noErr && settable.boolValue
    }

    func setMuted(_ id: AudioDeviceID, _ muted: Bool, input: Bool = false) {
        var value: UInt32 = muted ? 1 : 0
        var addr = CA.address(kAudioDevicePropertyMute, scope(input))
        AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        tick &+= 1
    }

    func balance(_ id: AudioDeviceID) -> Float? {
        CA.get(id, kAudioHardwareServiceDeviceProperty_VirtualMainBalance, scope: kAudioObjectPropertyScopeOutput, initial: Float32(0.5))
    }

    func hasBalance(_ id: AudioDeviceID) -> Bool {
        var addr = CA.address(kAudioHardwareServiceDeviceProperty_VirtualMainBalance, kAudioObjectPropertyScopeOutput)
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(id, &addr) && AudioObjectIsPropertySettable(id, &addr, &settable) == noErr && settable.boolValue
    }

    func setBalance(_ id: AudioDeviceID, _ v: Float) {
        var value = Float32(min(max(v, 0), 1))
        var addr = CA.address(kAudioHardwareServiceDeviceProperty_VirtualMainBalance, kAudioObjectPropertyScopeOutput)
        AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        tick &+= 1
    }

    func sampleRate(_ id: AudioDeviceID) -> Double? { CA.get(id, kAudioDevicePropertyNominalSampleRate, initial: Float64(0)) }

    func availableSampleRates(_ id: AudioDeviceID) -> [Double] {
        var addr = CA.address(kAudioDevicePropertyAvailableNominalSampleRates)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: Int(size) / MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &ranges) == noErr else { return [] }
        let common: [Double] = [8000, 11025, 16000, 22050, 24000, 32000, 44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000]
        var out = Set<Double>()
        for r in ranges {
            if r.mMinimum == r.mMaximum { out.insert(r.mMinimum) } else { common.filter { $0 >= r.mMinimum && $0 <= r.mMaximum }.forEach { out.insert($0) } }
        }
        return out.sorted()
    }

    func setSampleRate(_ id: AudioDeviceID, _ rate: Double) {
        var value = Float64(rate)
        var addr = CA.address(kAudioDevicePropertyNominalSampleRate)
        AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Float64>.size), &value)
        tick &+= 1
    }

    func dataSources(_ id: AudioDeviceID) -> [DataSource] {
        let ids = CA.getIDs(id, kAudioDevicePropertyDataSources, scope: kAudioObjectPropertyScopeOutput)
        return ids.map { src in
            var source = src
            var name: Unmanaged<CFString>?
            var translation = AudioValueTranslation(
                mInputData: withUnsafeMutablePointer(to: &source) { UnsafeMutableRawPointer($0) },
                mInputDataSize: UInt32(MemoryLayout<UInt32>.size),
                mOutputData: withUnsafeMutablePointer(to: &name) { UnsafeMutableRawPointer($0) },
                mOutputDataSize: UInt32(MemoryLayout<Unmanaged<CFString>?>.size))
            var addr = CA.address(kAudioDevicePropertyDataSourceNameForIDCFString, kAudioObjectPropertyScopeOutput)
            var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &translation)
            return DataSource(id: src, name: name?.takeRetainedValue() as String? ?? "Source \(src)")
        }
    }

    func currentDataSource(_ id: AudioDeviceID) -> UInt32? {
        CA.get(id, kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput, initial: UInt32(0))
    }

    func setDataSource(_ id: AudioDeviceID, _ src: UInt32) {
        var value = src
        var addr = CA.address(kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeOutput)
        AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        tick &+= 1
    }

    // MARK: - Settings

    func update(_ uid: String, coalesce: String? = nil, _ body: (inout DeviceSettings) -> Void) {
        store.change(coalesce.map { "device.\(uid).\($0)" }) { s in
            var d = s.devices[uid] ?? DeviceSettings()
            body(&d)
            s.devices[uid] = d == DeviceSettings() ? nil : d
        }
        tick &+= 1
        enforce()
    }

    func setLocked(_ d: AudioDevice, _ locked: Bool) {
        update(d.uid) { s in
            s.locked = locked
            s.lockedOutputVolume = locked && d.hasOutput ? hardwareVolume(d.id) : nil
            s.lockedInputVolume = locked && d.hasInput ? hardwareVolume(d.id, input: true) : nil
            s.lockedSampleRate = locked ? sampleRate(d.id) : nil
        }
    }

    // MARK: - Rules (run every second and on every change)

    private func enforce() {
        reload()
        for d in devices {
            let s = settings(d.uid)
            if d.hasOutput, let maxV = s.maxVolume, let v = hardwareVolume(d.id), v > maxV + 0.001 {
                setHardwareVolume(d.id, maxV)
            }
            if s.locked {
                if let v = s.lockedOutputVolume, let now = hardwareVolume(d.id), abs(now - v) > 0.005 { setHardwareVolume(d.id, v) }
                if let v = s.lockedInputVolume, let now = hardwareVolume(d.id, input: true), abs(now - v) > 0.005 { setHardwareVolume(d.id, v, input: true) }
                if let r = s.lockedSampleRate, let now = sampleRate(d.id), now != r { setSampleRate(d.id, r) }
            }
        }

        // Output-only devices (e.g. AirPods) and hidden devices may not be the default input.
        if let inp = device(id: defaultInput), settings(inp.uid).outputOnly || settings(inp.uid).hidden,
           let replacement = bestInput(excluding: inp.uid) {
            setDefaultInput(replacement)
            onAlert?("Kept \(displayName(inp)) as output only — switched the mic to \(displayName(replacement)).")
        }
        if let out = device(id: defaultOutput), settings(out.uid).hidden, let replacement = bestOutput(excluding: out.uid) {
            setDefaultOutput(replacement)
        }
    }

    private func bestInput(excluding uid: String) -> AudioDevice? {
        let ok = inputs.filter { $0.uid != uid && !settings($0.uid).outputOnly && !settings($0.uid).hidden }
        for p in store.state.prefs.preferredInputs { if let d = ok.first(where: { $0.uid == p }) { return d } }
        return ok.first(where: \.isBuiltIn) ?? ok.first
    }

    private func bestOutput(excluding uid: String? = nil) -> AudioDevice? {
        let ok = outputs.filter { $0.uid != uid && !settings($0.uid).hidden }
        for p in store.state.prefs.preferredOutputs { if let d = ok.first(where: { $0.uid == p }) { return d } }
        return ok.first(where: \.isBuiltIn) ?? ok.first
    }

    /// When devices come or go, pick the highest one in the preferred order.
    private func applyPreferredOrder() {
        let prefs = store.state.prefs
        guard prefs.preferredOrderEnabled else { return }
        if let best = prefs.preferredOutputs.lazy.compactMap({ uid in
            self.outputs.first { $0.uid == uid && !self.settings(uid).hidden }
        }).first, best.id != defaultOutput {
            setDefaultOutput(best)
        }
        if let best = prefs.preferredInputs.lazy.compactMap({ uid in
            self.inputs.first { $0.uid == uid && !self.settings(uid).hidden && !self.settings(uid).outputOnly }
        }).first, best.id != defaultInput {
            setDefaultInput(best)
        }
    }

    // MARK: - Output groups (system-wide multi-output devices)

    /// Creates a system-visible stacked aggregate for each saved group, removes stale ones.
    func syncGroups() {
        let groups = store.state.groups
        let existing = CA.getIDs(CA.system, kAudioHardwarePropertyDevices).compactMap { id -> (AudioDeviceID, String)? in
            guard let uid = CA.deviceUID(id), uid.hasPrefix(Self.groupPrefix) else { return nil }
            return (id, uid)
        }
        for (id, uid) in existing {
            guard let g = groups.first(where: { $0.uid == uid }) else { AudioHardwareDestroyAggregateDevice(id); continue }
            // Recreate if members changed.
            let currentUIDs = Self.subDeviceUIDs(id)
            if currentUIDs != g.deviceUIDs { AudioHardwareDestroyAggregateDevice(id) }
        }
        let present = Set(CA.getIDs(CA.system, kAudioHardwarePropertyDevices).compactMap(CA.deviceUID))
        for g in groups where !present.contains(g.uid) {
            let members = g.deviceUIDs.filter { present.contains($0) }
            guard !members.isEmpty else { continue }
            let subs: [[String: Any]] = members.enumerated().map { i, uid in
                i == 0 ? [kAudioSubDeviceUIDKey: uid] : [kAudioSubDeviceUIDKey: uid, kAudioSubDeviceDriftCompensationKey: 1]
            }
            let config: [String: Any] = [
                kAudioAggregateDeviceNameKey: g.name,
                kAudioAggregateDeviceUIDKey: g.uid,
                kAudioAggregateDeviceMainSubDeviceKey: members[0],
                kAudioAggregateDeviceIsPrivateKey: false,
                kAudioAggregateDeviceIsStackedKey: true,
                kAudioAggregateDeviceSubDeviceListKey: subs,
            ]
            var id = AudioObjectID(0)
            let err = AudioHardwareCreateAggregateDevice(config as CFDictionary, &id)
            if err != noErr { onAlert?("Couldn't create output group \(g.name) (\(err))") }
        }
        reload()
    }

    static func subDeviceUIDs(_ id: AudioDeviceID) -> [String] {
        var addr = CA.address(kAudioAggregateDevicePropertyFullSubDeviceList)
        var size = UInt32(MemoryLayout<Unmanaged<CFArray>?>.size)
        var ref: Unmanaged<CFArray>?
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &ref) == noErr, let ref else { return [] }
        return ref.takeRetainedValue() as? [String] ?? []
    }

    func saveGroup(_ g: OutputGroup) {
        store.change { s in
            if let i = s.groups.firstIndex(where: { $0.id == g.id }) { s.groups[i] = g } else { s.groups.append(g) }
        }
        // Rebuild: destroy then recreate with new members.
        if let d = device(uid: g.uid) { AudioHardwareDestroyAggregateDevice(d.id) }
        syncGroups()
    }

    func deleteGroup(_ g: OutputGroup) {
        store.change { s in s.groups.removeAll { $0.id == g.id } }
        syncGroups()
    }

    /// Member devices of an output target, for per-app routing.
    func members(of group: OutputGroup) -> [AudioDevice] { group.deviceUIDs.compactMap { device(uid: $0) } }

    // MARK: - Bluetooth

    func refreshBatteries() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            p.arguments = ["SPBluetoothDataType", "-json"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            var result: [String: String] = [:]
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let items = json["SPBluetoothDataType"] as? [[String: Any]] {
                for item in items {
                    for entry in (item["device_connected"] as? [[String: Any]]) ?? [] {
                        for (name, value) in entry {
                            guard let info = value as? [String: Any] else { continue }
                            var parts: [String] = []
                            for (key, label) in [("device_batteryLevelMain", ""), ("device_batteryLevelLeft", "L "),
                                                 ("device_batteryLevelRight", "R "), ("device_batteryLevelCase", "Case ")] {
                                if let v = info[key] as? String { parts.append(label + v) }
                            }
                            if !parts.isEmpty { result[name] = parts.joined(separator: " · ") }
                        }
                    }
                }
            }
            DispatchQueue.main.async { if self?.batteries != result { self?.batteries = result } }
        }
    }

    func battery(for d: AudioDevice) -> String? {
        guard d.isBluetooth else { return nil }
        return batteries[d.name] ?? batteries.first { d.name.hasPrefix($0.key) || $0.key.hasPrefix(d.name) }?.value
    }

    /// Reconnects Bluetooth audio devices marked "Reconnect after sleep" that aren't connected.
    func reconnectBluetooth() {
        let wanted = store.state.devices.filter(\.value.autoReconnect).map(\.key)
        guard !wanted.isEmpty, let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return }
        for uid in wanted {
            // Bluetooth audio device UIDs start with the MAC address, e.g. "70-F9-4A-98-91-8C:output".
            let mac = uid.split(separator: ":").first.map { $0.replacingOccurrences(of: "-", with: ":").lowercased() } ?? ""
            let name = store.state.devices[uid]?.nickname
            guard let bt = paired.first(where: { ($0.addressString ?? "").lowercased() == mac || $0.name == name }),
                  !bt.isConnected() else { continue }
            bt.openConnection()
        }
    }

    // MARK: - Listeners

    /// What the rest of the app cares about: real devices (not iSound's private helpers) and defaults.
    private var lastSignature = ""
    private var signature: String {
        devices.map(\.uid).joined(separator: ",") + "|\(defaultOutput ?? 0)|\(defaultInput ?? 0)"
    }

    private func addListeners() {
        lastSignature = signature
        for sel in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultInputDevice] {
            var addr = CA.address(sel)
            AudioObjectAddPropertyListenerBlock(CA.system, &addr, .main) { [weak self] _, _ in
                guard let self else { return }
                self.reload()
                // iSound's own private capture devices come and go constantly; ignore those.
                let sig = self.signature
                guard sig != self.lastSignature else { return }
                let outputsChanged = sig.split(separator: "|").prefix(2) != self.lastSignature.split(separator: "|").prefix(2)
                self.lastSignature = sig
                let now = Set(self.devices.map(\.uid))
                if now != self.lastDeviceUIDs {
                    self.lastDeviceUIDs = now
                    self.syncGroups()
                    self.applyPreferredOrder()
                }
                self.enforce()
                if outputsChanged { self.onDevicesChanged?() }
            }
        }
    }

    private func watch(_ id: AudioDeviceID) {
        watched.insert(id)
        let props: [(AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
            (kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyScopeOutput),
            (kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyScopeInput),
            (kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput),
            (kAudioDevicePropertyMute, kAudioObjectPropertyScopeInput),
            (kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
        ]
        for (sel, sc) in props {
            var addr = CA.address(sel, sc)
            guard AudioObjectHasProperty(id, &addr) else { continue }
            AudioObjectAddPropertyListenerBlock(id, &addr, .main) { [weak self] _, _ in
                guard let self else { return }
                self.tick &+= 1
                // Clamp right away (don't wait for the timer) so max volume protects your ears.
                if sel == kAudioHardwareServiceDeviceProperty_VirtualMainVolume || sel == kAudioDevicePropertyNominalSampleRate {
                    self.enforce()
                }
            }
        }
    }
}
