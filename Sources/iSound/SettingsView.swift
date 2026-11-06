import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            AppearanceSettings().tabItem { Label("Appearance", systemImage: "paintpalette") }
            ShortcutSettings().tabItem { Label("Shortcuts", systemImage: "keyboard") }
            QuickConfigSettings().tabItem { Label("Quick Configs", systemImage: "square.stack.3d.down.right") }
        }
        .frame(width: 520, height: 460)
        .tint(store.state.prefs.accent.color)
    }
}

struct GeneralSettings: View {
    @EnvironmentObject var model: MixerModel
    @EnvironmentObject var store: Store
    @State private var feedback = VolumeFeedback.isEnabled
    @State private var alertVolume = AlertVolume.value
    @State private var trusted = MediaKeys.shared.isTrusted

    var body: some View {
        let p = store.state.prefs
        Form {
            Section("Volume") {
                Toggle("Super Volume Keys", isOn: Binding(get: { p.superVolumeKeys }, set: { v in
                    model.setPrefs { $0.superVolumeKeys = v }
                    MediaKeys.shared.setEnabled(v)
                    trusted = MediaKeys.shared.isTrusted
                }))
                Text("Lets your keyboard's volume keys control outputs that have no volume control of their own (HDMI, some USB devices, output groups). Hold ⌥⇧ for fine steps.")
                    .font(.caption).foregroundStyle(.secondary)
                if p.superVolumeKeys && !trusted {
                    HStack {
                        Text("Needs Accessibility permission.").font(.caption).foregroundStyle(.orange)
                        Button("Grant…") { MediaKeys.shared.requestAccess() }.controlSize(.small)
                        Button("Check again") { trusted = MediaKeys.shared.isTrusted; MediaKeys.shared.setEnabled(true) }.controlSize(.small)
                    }
                }
                Picker("Volume key step", selection: Binding(get: { p.volumeKeyStep }, set: { v in model.setPrefs { $0.volumeKeyStep = v } })) {
                    Text("Fine (1/32)").tag(Float(1.0 / 32))
                    Text("Normal (1/16)").tag(Float(1.0 / 16))
                    Text("Large (1/8)").tag(Float(1.0 / 8))
                }
                Toggle("Play feedback when volume is changed", isOn: $feedback)
                    .onChange(of: feedback) { _, v in VolumeFeedback.isEnabled = v }
                HStack {
                    Text("Sound effects volume")
                    Slider(value: $alertVolume, in: 0...1).onChange(of: alertVolume) { _, v in AlertVolume.value = v }
                }
                Toggle("Fade audio back in when unmuting", isOn: Binding(get: { p.smoothUnmute }, set: { v in model.setPrefs { $0.smoothUnmute = v } }))
            }
            Section("Devices") {
                Toggle("Move sound effects with the output device", isOn: Binding(get: { p.moveSystemSoundsWithOutput }, set: { v in model.setPrefs { $0.moveSystemSoundsWithOutput = v } }))
            }
            Section("Application list") {
                Picker("Show apps after they go quiet for", selection: Binding(get: { p.recentSeconds }, set: { v in model.setPrefs { $0.recentSeconds = v } })) {
                    Text("10 seconds").tag(10.0)
                    Text("60 seconds").tag(60.0)
                    Text("5 minutes").tag(300.0)
                    Text("30 minutes").tag(1800.0)
                }
            }
            Section("Startup") { LaunchAtLoginToggle() }
        }
        .formStyle(.grouped)
    }
}

struct AppearanceSettings: View {
    @EnvironmentObject var model: MixerModel
    @EnvironmentObject var store: Store

    var body: some View {
        let p = store.state.prefs
        Form {
            Section("Accent color") {
                HStack(spacing: 10) {
                    ForEach(AccentChoice.allCases) { c in
                        Button { model.setPrefs { $0.accent = c } } label: {
                            ZStack {
                                Circle().fill(c == .system ? AnyShapeStyle(AngularGradient(colors: [.red, .yellow, .green, .blue, .purple, .red], center: .center)) : AnyShapeStyle(c.color))
                                    .frame(width: 22, height: 22)
                                if p.accent == c { Circle().strokeBorder(.primary, lineWidth: 2).frame(width: 28, height: 28) }
                            }
                            .frame(width: 30, height: 30)
                        }
                        .buttonStyle(.plain)
                        .help(c.rawValue.capitalized)
                        .accessibilityLabel("\(c.rawValue) accent color")
                    }
                }
            }
            Section("Menu bar") {
                Picker("Menu bar icon", selection: Binding(get: { p.menuBarIcon }, set: { v in model.setPrefs { $0.menuBarIcon = v } })) {
                    ForEach(MenuBarIconStyle.allCases) { Text($0.label).tag($0) }
                }
                Text("Individual apps can also get their own menu bar icon: open an app's options and tick “Show in menu bar”.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Window") {
                Toggle("Compact view", isOn: Binding(get: { p.compact }, set: { v in model.setPrefs { $0.compact = v } }))
                Toggle("Show level meters", isOn: Binding(get: { p.showMeters }, set: { v in model.setPrefs { $0.showMeters = v } }))
                Toggle("Show microphone meter", isOn: Binding(get: { p.showInputMeter }, set: { v in model.setPrefs { $0.showInputMeter = v } }))
                Text("The microphone meter reads your mic while iSound is open, so the orange mic dot will show.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Keep the iSound window on top", isOn: Binding(get: { p.pinWindow }, set: { v in model.setPrefs { $0.pinWindow = v } }))
            }
        }
        .formStyle(.grouped)
    }
}

struct ShortcutSettings: View {
    @EnvironmentObject var model: MixerModel
    @EnvironmentObject var store: Store
    @EnvironmentObject var devices: DeviceManager

    var body: some View {
        Form {
            Section("Global") {
                row("Mute microphone (cough button)", .toggleMicMute)
                row("Output volume up", .outputVolumeUp)
                row("Output volume down", .outputVolumeDown)
                row("Mute output", .toggleOutputMute)
                row("Show iSound window", .showMixer)
            }
            Section("Switch output") {
                ForEach(devices.visibleOutputs) { d in row(devices.displayName(d), .setOutput(d.uid)) }
            }
            Section("Switch input") {
                ForEach(devices.visibleInputs) { d in row(devices.displayName(d), .setInput(d.uid)) }
            }
            if !store.state.quickConfigs.isEmpty {
                Section("Quick configs") {
                    ForEach(store.state.quickConfigs) { c in row(c.name, .applyQuickConfig(c.id)) }
                }
            }
            Section {
                Text("Per-app shortcuts are in each app's options in the mixer.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ title: String, _ action: HotkeyAction) -> some View {
        HStack {
            Text(title)
            Spacer()
            ShortcutRecorder(binding: model.binding(for: action),
                             onChange: { model.setBinding(action, keyCode: $0, modifiers: $1) },
                             onClear: { model.clearBinding(action) })
        }
    }
}

struct QuickConfigSettings: View {
    @EnvironmentObject var model: MixerModel
    @EnvironmentObject var store: Store
    @State private var newName = ""

    var body: some View {
        Form {
            Section {
                Text("A quick config saves every app's volume, routing and effects, device settings, and your output/input. Apply it from the menu bar.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("Name", text: $newName, prompt: Text("e.g. Calls, Movies, Gaming"))
                    Button("Save Current Setup") { model.saveQuickConfig(name: newName.isEmpty ? "Config \(store.state.quickConfigs.count + 1)" : newName); newName = "" }
                }
            }
            Section("Saved") {
                if store.state.quickConfigs.isEmpty { Text("None yet").foregroundStyle(.secondary) }
                ForEach(store.state.quickConfigs) { c in
                    HStack {
                        TextField("Name", text: Binding(get: { c.name }, set: { v in
                            store.change { s in if let i = s.quickConfigs.firstIndex(where: { $0.id == c.id }) { s.quickConfigs[i].name = v } }
                        }))
                        Text("\(c.sources.count) apps").font(.caption).foregroundStyle(.secondary)
                        Button("Apply") { model.applyQuickConfig(c) }
                        Button("Update") {
                            model.saveAUStates()
                            store.change { s in
                                if let i = s.quickConfigs.firstIndex(where: { $0.id == c.id }) {
                                    s.quickConfigs[i].sources = s.sources
                                    s.quickConfigs[i].devices = s.devices
                                    s.quickConfigs[i].defaultOutputUID = model.outputDevice?.uid
                                    s.quickConfigs[i].defaultInputUID = model.inputDevice?.uid
                                }
                            }
                        }
                        Button(role: .destructive) { store.change { $0.quickConfigs.removeAll { $0.id == c.id } } } label: { Image(systemName: "trash") }
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct AlertsView: View {
    @EnvironmentObject var model: MixerModel

    var body: some View {
        VStack(alignment: .leading) {
            if model.alerts.isEmpty {
                ContentUnavailableView("No alerts", systemImage: "checkmark.circle", description: Text("Problems with devices, effects or audio capture show up here."))
            } else {
                List(model.alerts) { a in
                    VStack(alignment: .leading) {
                        Text(a.message)
                        Text(a.date.formatted(date: .omitted, time: .standard)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack { Spacer(); Button("Clear") { model.clearAlerts() }.padding(8) }
            }
        }
        .frame(minWidth: 380, minHeight: 280)
    }
}
