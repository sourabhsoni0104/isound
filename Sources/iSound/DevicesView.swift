import SwiftUI

struct DevicesView: View {
    @EnvironmentObject var devices: DeviceManager
    @EnvironmentObject var store: Store
    @State private var selection: String? = "order"
    @State private var showHidden = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Outputs") {
                    ForEach(devices.outputs.filter { showHidden || !devices.settings($0.uid).hidden }) { d in deviceRow(d, input: false).tag(Optional("out." + d.uid)) }
                }
                Section("Inputs") {
                    ForEach(devices.inputs.filter { showHidden || !devices.settings($0.uid).hidden }) { d in deviceRow(d, input: true).tag(Optional("in." + d.uid)) }
                }
                Section("Setup") {
                    Label("Output Groups", systemImage: "hifispeaker.2.fill").tag(Optional("groups"))
                    Label("Preferred Order", systemImage: "list.number").tag(Optional("order"))
                }
            }
            .safeAreaInset(edge: .bottom) {
                Toggle("Show hidden devices", isOn: $showHidden).toggleStyle(.checkbox).font(.caption).padding(8)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            Group {
                switch selection {
                case .some(let s) where s.hasPrefix("out."):
                    if let d = devices.device(uid: String(s.dropFirst(4))) { DeviceDetail(device: d, input: false) }
                case .some(let s) where s.hasPrefix("in."):
                    if let d = devices.device(uid: String(s.dropFirst(3))) { DeviceDetail(device: d, input: true) }
                case "groups": GroupsView()
                default: PreferredOrderView()
                }
            }
            .frame(minWidth: 420, minHeight: 420)
        }
        .tint(store.state.prefs.accent.color)
    }

    private func deviceRow(_ d: AudioDevice, input: Bool) -> some View {
        let isDefault = (input ? devices.defaultInput : devices.defaultOutput) == d.id
        return HStack {
            Image(systemName: devices.symbol(d)).frame(width: 18)
            Text(devices.displayName(d)).lineLimit(1)
                .foregroundStyle(devices.settings(d.uid).hidden ? .secondary : .primary)
            Spacer()
            if isDefault { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
        }
    }
}

struct DeviceDetail: View {
    let device: AudioDevice
    let input: Bool
    @EnvironmentObject var devices: DeviceManager
    @EnvironmentObject var model: MixerModel
    @EnvironmentObject var store: Store

    private var s: DeviceSettings { devices.settings(device.uid) }

    var body: some View {
        let _ = devices.tick
        Form {
            Section {
                HStack(spacing: 12) {
                    IconPicker(symbol: devices.symbol(device)) { sym in devices.update(device.uid) { $0.icon = sym } }
                    VStack(alignment: .leading) {
                        Text(devices.displayName(device)).font(.title3.weight(.semibold))
                        Text(details).font(.caption).foregroundStyle(.secondary)
                        if let b = devices.battery(for: device) { Label(b, systemImage: "battery.75percent").font(.caption) }
                    }
                    Spacer()
                    let isDefault = (input ? devices.defaultInput : devices.defaultOutput) == device.id
                    Button(isDefault ? (input ? "Current Input" : "Current Output") : (input ? "Use as Input" : "Use as Output")) {
                        if input { devices.setDefaultInput(device) } else { devices.setDefaultOutput(device) }
                    }
                    .disabled(isDefault)
                }
                TextField("Nickname", text: Binding(get: { s.nickname ?? "" }, set: { v in devices.update(device.uid, coalesce: "nick") { $0.nickname = v.isEmpty ? nil : v } }),
                          prompt: Text(device.name))
            }

            if input { inputSection } else { outputSection }

            Section("Device") {
                let rates = devices.availableSampleRates(device.id)
                if rates.count > 1 {
                    Picker("Sample rate", selection: Binding(get: { devices.sampleRate(device.id) ?? 0 }, set: { devices.setSampleRate(device.id, $0) })) {
                        ForEach(rates, id: \.self) { Text("\(String(format: "%g", $0 / 1000)) kHz").tag($0) }
                    }
                } else if let r = devices.sampleRate(device.id) {
                    LabeledContent("Sample rate", value: "\(String(format: "%g", r / 1000)) kHz")
                }
                Toggle("Lock settings", isOn: Binding(get: { s.locked }, set: { devices.setLocked(device, $0) }))
                    .help("Stops other apps (like Zoom) from changing this device's volume or sample rate")
                Toggle("Hide this device", isOn: Binding(get: { s.hidden }, set: { v in devices.update(device.uid) { $0.hidden = v } }))
                    .help("Hidden devices don't appear in menus, and iSound moves the system away from them")
                if device.isBluetooth {
                    if device.hasInput && device.hasOutput {
                        Toggle("Output only (better sound quality)", isOn: Binding(get: { s.outputOnly }, set: { v in devices.update(device.uid) { $0.outputOnly = v } }))
                            .help("Stops the Mac using this device's mic, which drops Bluetooth audio to low-quality call mode")
                    }
                    Toggle("Reconnect after sleep", isOn: Binding(get: { s.autoReconnect }, set: { v in devices.update(device.uid) { $0.autoReconnect = v } }))
                }
                HStack {
                    Text(input ? "Shortcut: use as input" : "Shortcut: use as output")
                    Spacer()
                    let action: HotkeyAction = input ? .setInput(device.uid) : .setOutput(device.uid)
                    ShortcutRecorder(binding: model.binding(for: action),
                                     onChange: { model.setBinding(action, keyCode: $0, modifiers: $1) },
                                     onClear: { model.clearBinding(action) })
                }
            }
        }
        .formStyle(.grouped)
    }

    private var details: String {
        var parts: [String] = []
        if device.isBluetooth { parts.append("Bluetooth") } else if device.isAirPlay { parts.append("AirPlay") } else if device.isBuiltIn { parts.append("Built-in") } else if device.isGroup { parts.append("Output group") }
        parts.append("\(input ? device.inputChannels : device.outputChannels) channels")
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var outputSection: some View {
        Section("Output") {
            let software = devices.usesSoftwareVolume(device)
            HStack {
                Text("Volume")
                Slider(value: Binding(
                    get: { Double(software ? s.softwareVolume : (devices.hardwareVolume(device.id) ?? 0)) },
                    set: { v in
                        if software { devices.update(device.uid, coalesce: "swvol") { $0.softwareVolume = min(Float(v), $0.maxVolume ?? 1) } }
                        else { devices.setHardwareVolume(device.id, Float(v)) }
                    }), in: 0...1)
            }
            if devices.hasBalance(device.id) {
                HStack {
                    Text("Balance")
                    Text("L").font(.caption)
                    Slider(value: Binding(get: { Double(devices.balance(device.id) ?? 0.5) },
                                          set: { devices.setBalance(device.id, abs($0 - 0.5) < 0.02 ? 0.5 : Float($0)) }), in: 0...1)
                    Text("R").font(.caption)
                }
            }
            Toggle("Limit maximum volume", isOn: Binding(get: { s.maxVolume != nil }, set: { v in devices.update(device.uid) { $0.maxVolume = v ? 0.75 : nil } }))
            if let maxV = s.maxVolume {
                HStack {
                    Text("Maximum")
                    Slider(value: Binding(get: { Double(maxV) }, set: { v in devices.update(device.uid, coalesce: "max") { $0.maxVolume = Float(v) } }), in: 0.05...1)
                    Text(maxV.percent).font(.caption.monospacedDigit()).frame(width: 40)
                }
            }
            Toggle("Use software volume control", isOn: Binding(get: { s.forceSoftwareVolume }, set: { v in devices.update(device.uid) { $0.forceSoftwareVolume = v } }))
                .help("For devices whose volume control doesn't really work. iSound handles volume instead.")
                .disabled(!devices.hasHardwareVolume(device.id))
            if !devices.hasHardwareVolume(device.id) {
                Text("This device has no volume control of its own, so iSound uses software volume. Turn on Super Volume Keys in Settings to use your keyboard's volume keys with it.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            let sources = devices.dataSources(device.id)
            if sources.count > 1 {
                Picker("Destination", selection: Binding(get: { devices.currentDataSource(device.id) ?? 0 }, set: { devices.setDataSource(device.id, $0) })) {
                    ForEach(sources) { Text($0.name).tag($0.id) }
                }
            }

            if device.outputChannels > 2 {
                Picker("Channels", selection: Binding(get: { s.channelMode }, set: { v in devices.update(device.uid) { $0.channelMode = v } })) {
                    ForEach(ChannelMode.allCases) { Text($0.label).tag($0) }
                }
                if s.channelMode != .allPairs {
                    Stepper("Start at channel \(s.channelOffset + 1)–\(s.channelOffset + 2)",
                            value: Binding(get: { s.channelOffset }, set: { v in devices.update(device.uid) { $0.channelOffset = v } }),
                            in: 0...max(0, device.outputChannels - 2))
                }
            } else if device.outputChannels == 2 {
                Picker("Channels", selection: Binding(get: { s.channelMode }, set: { v in devices.update(device.uid) { $0.channelMode = v } })) {
                    ForEach(ChannelMode.allCases.filter { $0 != .allPairs }) { Text($0.label).tag($0) }
                }
            }
        }
        Section("Effects on this device") {
            Text("Applied to every app playing through this device, e.g. a Headphone EQ for these headphones.")
                .font(.caption).foregroundStyle(.secondary)
            EffectChainView(target: .device(device.uid))
        }
    }

    @ViewBuilder private var inputSection: some View {
        Section("Input") {
            HStack {
                Text("Volume")
                Slider(value: Binding(get: { Double(devices.hardwareVolume(device.id, input: true) ?? 0) },
                                      set: { devices.setHardwareVolume(device.id, Float($0), input: true) }), in: 0...1)
                    .disabled(!devices.hasHardwareVolume(device.id, input: true))
            }
            if devices.canMute(device.id, input: true) {
                Toggle("Muted", isOn: Binding(get: { devices.isMuted(device.id, input: true) }, set: { devices.setMuted(device.id, $0, input: true) }))
            }
        }
    }
}

struct IconPicker: View {
    let symbol: String
    let onPick: (String?) -> Void
    static let symbols = ["speaker.wave.2.fill", "hifispeaker.fill", "hifispeaker.2.fill", "homepod.fill", "headphones", "airpods",
                          "airpodspro", "airpodsmax", "beats.headphones", "earbuds", "laptopcomputer", "desktopcomputer", "display",
                          "tv", "mic.fill", "music.mic", "cable.connector", "airplayaudio", "car.fill", "gamecontroller.fill",
                          "radio.fill", "guitars.fill", "pianokeys", "waveform"]

    var body: some View {
        Menu {
            Button("Default") { onPick(nil) }
            Divider()
            ForEach(Self.symbols, id: \.self) { s in Button { onPick(s) } label: { Label(s, systemImage: s) } }
        } label: {
            Image(systemName: symbol).font(.system(size: 26)).frame(width: 44, height: 44)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Change icon")
    }
}

struct GroupsView: View {
    @EnvironmentObject var devices: DeviceManager
    @EnvironmentObject var store: Store
    @State private var editing: OutputGroup?

    var body: some View {
        Form {
            Section {
                Text("An output group plays the same audio on several devices at once (kept in sync). Use it as the system output, or send single apps to it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(store.state.groups) { g in
                Section(g.name) {
                    ForEach(devices.outputs.filter { !$0.isGroup && !devices.settings($0.uid).hidden }) { d in
                        Toggle(isOn: Binding(get: { g.deviceUIDs.contains(d.uid) }, set: { on in
                            var ng = g
                            if on { ng.deviceUIDs.append(d.uid) } else { ng.deviceUIDs.removeAll { $0 == d.uid } }
                            devices.saveGroup(ng)
                        })) { Label(devices.displayName(d), systemImage: devices.symbol(d)) }
                    }
                    HStack {
                        TextField("Name", text: Binding(get: { g.name }, set: { var ng = g; ng.name = $0; devices.saveGroup(ng) }))
                        Spacer()
                        if let d = devices.device(uid: g.uid) {
                            Button("Use as Output") { devices.setDefaultOutput(d) }.disabled(devices.defaultOutput == d.id)
                        }
                        Button("Delete", role: .destructive) { devices.deleteGroup(g) }
                    }
                }
            }
            Button("New Output Group") {
                devices.saveGroup(OutputGroup(name: "Group \(store.state.groups.count + 1)", deviceUIDs: devices.defaultOutput.flatMap(CA.deviceUID).map { [$0] } ?? []))
            }
        }
        .formStyle(.grouped)
    }
}

struct PreferredOrderView: View {
    @EnvironmentObject var devices: DeviceManager
    @EnvironmentObject var model: MixerModel
    @EnvironmentObject var store: Store

    var body: some View {
        let p = store.state.prefs
        Form {
            Section {
                Toggle("Use preferred device order", isOn: Binding(get: { p.preferredOrderEnabled }, set: { v in model.setPrefs { $0.preferredOrderEnabled = v } }))
                Text("When devices connect or disconnect, iSound switches to the highest available device in each list.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            orderSection("Outputs", list: p.preferredOutputs, all: devices.outputs) { new in model.setPrefs { $0.preferredOutputs = new } }
            orderSection("Inputs", list: p.preferredInputs, all: devices.inputs) { new in model.setPrefs { $0.preferredInputs = new } }
        }
        .formStyle(.grouped)
    }

    private func orderSection(_ title: String, list: [String], all: [AudioDevice], set: @escaping ([String]) -> Void) -> some View {
        Section(title) {
            ForEach(Array(list.enumerated()), id: \.element) { i, uid in
                HStack {
                    Text("\(i + 1).").monospacedDigit().foregroundStyle(.secondary)
                    if let d = devices.device(uid: uid) {
                        Label(devices.displayName(d), systemImage: devices.symbol(d))
                    } else {
                        Text("Disconnected device").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { var l = list; l.swapAt(i, i - 1); set(l) } label: { Image(systemName: "chevron.up") }.disabled(i == 0)
                    Button { var l = list; l.swapAt(i, i + 1); set(l) } label: { Image(systemName: "chevron.down") }.disabled(i == list.count - 1)
                    Button { var l = list; l.remove(at: i); set(l) } label: { Image(systemName: "minus.circle") }
                }
                .buttonStyle(.borderless)
            }
            let remaining = all.filter { !list.contains($0.uid) }
            if !remaining.isEmpty {
                Menu("Add Device") {
                    ForEach(remaining) { d in Button(devices.displayName(d)) { set(list + [d.uid]) } }
                }
                .fixedSize()
            }
        }
    }
}
