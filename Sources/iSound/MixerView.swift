import ServiceManagement
import SwiftUI

struct MixerView: View {
    @EnvironmentObject var model: MixerModel
    @EnvironmentObject var store: Store
    @EnvironmentObject var devices: DeviceManager
    var inWindow = false
    var expandFirst = false   // used for snapshots
    @State private var expanded: String?
    @Environment(\.openWindow) private var openWindow

    private var compact: Bool { store.state.prefs.compact }
    static let popoverWidth: CGFloat = 360

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            header
            if model.permission != .authorized { permissionBanner }
            OutputCard()
            InputCard()
            appsCard
            CallBoostCard()
            footer
        }
        .padding(compact ? 10 : 14)
        .frame(width: inWindow ? nil : (compact ? 320 : Self.popoverWidth))
        .frame(minWidth: inWindow ? 340 : nil)
        .tint(store.state.prefs.accent.color)
        .onAppear {
            model.mixerAppeared()
            if expandFirst { expanded = model.rows.first?.id }
        }
        .onDisappear { model.mixerDisappeared() }
        .background(WindowAccessor { w in
            if inWindow {
                w.level = store.state.prefs.pinWindow ? .floating : .normal
            } else {
                // Round the menu panel's corners.
                w.isOpaque = false
                w.backgroundColor = .clear
                if let frame = w.contentView?.superview {
                    frame.wantsLayer = true
                    frame.layer?.cornerRadius = 22
                    frame.layer?.cornerCurve = .continuous
                    frame.layer?.masksToBounds = true
                }
            }
        })
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "slider.vertical.3")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text("iSound").font(.system(size: 15, weight: .bold, design: .rounded))
            Spacer(minLength: 8)
            RoundIconButton(symbol: "arrow.uturn.backward", help: "Undo") { store.undo() }
                .disabled(!store.canUndo).opacity(store.canUndo ? 1 : 0.4)
                .keyboardShortcut("z", modifiers: .command)
            QuickConfigMenu()
            RoundIconButton(symbol: "hifispeaker.2", help: "Audio Devices") { open("devices") }
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 26, height: 26)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassCircle()
            .help("Settings")
            moreMenu
        }
    }

    private var moreMenu: some View {
        Menu {
            Button("Redo") { store.redo() }.disabled(!store.canRedo)
            Button(model.alerts.isEmpty ? "Audio Alerts" : "Audio Alerts (\(model.alerts.count))") { open("alerts") }
            if inWindow {
                Button(store.state.prefs.pinWindow ? "Unpin Window" : "Keep Window on Top") { model.setPrefs { $0.pinWindow.toggle() } }
            } else {
                Button("Open in a Window") { open("mixer") }
            }
            Divider()
            Button("Quit iSound") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: model.alerts.isEmpty ? "ellipsis" : "exclamationmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(model.alerts.isEmpty ? Color.primary : Color.orange)
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .glassCircle()
        .fixedSize()
        .help("More")
    }

    private func open(_ id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }

    private var permissionBanner: some View {
        Card {
            Label("Allow audio access", systemImage: "lock.shield").font(.subheadline.weight(.semibold))
            Text(model.permission == .denied
                 ? "Turn on iSound in System Settings → Privacy & Security → Screen & System Audio Recording."
                 : "iSound needs permission to capture app audio before it can change volumes.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button(model.permission == .denied ? "Open System Settings" : "Allow…") {
                if model.permission == .denied { AudioPermission.openSettings() } else { model.requestPermission() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }

    // MARK: Apps

    private var appsCard: some View {
        Card(padding: 10) {
            HStack {
                SectionLabel(title: "Apps", symbol: "square.grid.2x2")
                Spacer()
                if model.callActive {
                    Label("On a call", systemImage: "phone.fill").font(.caption.weight(.medium)).foregroundStyle(.green)
                }
            }
            .padding(.horizontal, 2)
            if model.rows.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "speaker.wave.2").font(.title2).foregroundStyle(.tertiary)
                    Text("Nothing is playing").font(.callout.weight(.medium))
                    Text("Apps show up here as soon as they make sound.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(model.rows) { row in
                            AppRowView(row: row, expanded: Binding(
                                get: { expanded == row.id },
                                set: { expanded = $0 ? row.id : nil }))
                        }
                    }
                }
                .scrollIndicators(.never)
                .frame(maxHeight: inWindow ? .infinity : 380)
                .fixedSize(horizontal: false, vertical: !inWindow)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            LaunchAtLoginToggle()
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
        }
        .padding(.horizontal, 4)
    }
}

struct LaunchAtLoginToggle: View {
    @State private var on = SMAppService.mainApp.status == .enabled
    var body: some View {
        Toggle("Launch at login", isOn: $on)
            .toggleStyle(.checkbox)
            .font(.caption)
            .onChange(of: on) { _, v in
                do { if v { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                catch { on = SMAppService.mainApp.status == .enabled }
            }
    }
}

// MARK: - Output / input

struct OutputCard: View {
    @EnvironmentObject var model: MixerModel
    @EnvironmentObject var devices: DeviceManager
    @EnvironmentObject var store: Store

    var body: some View {
        let _ = devices.tick
        let muted = model.isOutputMuted()
        Card {
            HStack(spacing: 8) {
                SectionLabel(title: "Output")
                Spacer(minLength: 6)
                DevicePicker(input: false)
            }
            HStack(spacing: 10) {
                Button { model.toggleOutputMute() } label: {
                    Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundStyle(muted ? .red : .primary)
                        .frame(width: 22)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(muted ? "Unmute output" : "Mute output")
                Slider(value: Binding(get: { Double(model.outputVolume()) }, set: { model.setOutputVolume(Float($0)) }), in: 0...1)
                    .controlSize(.small)
                    .accessibilityLabel("Output volume")
                PercentText(value: model.outputVolume())
            }
            if store.state.prefs.showMeters { LevelMeter(level: model.outputLevel).padding(.leading, 32).padding(.trailing, 50) }
            if let d = model.outputDevice, devices.usesSoftwareVolume(d) || devices.battery(for: d) != nil {
                HStack(spacing: 10) {
                    if devices.usesSoftwareVolume(d) { Label("Software volume", systemImage: "cpu") }
                    if let b = devices.battery(for: d) { Label(b, systemImage: "battery.75percent") }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.leading, 32)
            }
        }
    }
}

struct InputCard: View {
    @EnvironmentObject var model: MixerModel
    @EnvironmentObject var devices: DeviceManager
    @EnvironmentObject var store: Store

    var body: some View {
        let _ = devices.tick
        let muted = model.isMicMuted()
        Card {
            HStack(spacing: 8) {
                SectionLabel(title: "Microphone")
                Spacer(minLength: 6)
                DevicePicker(input: true)
            }
            HStack(spacing: 10) {
                Button { model.toggleMicMute() } label: {
                    Image(systemName: muted ? "mic.slash.fill" : "mic.fill")
                        .foregroundStyle(muted ? .red : .primary)
                        .frame(width: 22)
                }
                .buttonStyle(.plain)
                .help("Mute microphone")
                .accessibilityLabel(muted ? "Unmute microphone" : "Mute microphone")
                Slider(value: Binding(get: { Double(model.inputVolume()) }, set: { model.setInputVolume(Float($0)) }), in: 0...1)
                    .controlSize(.small)
                    .accessibilityLabel("Microphone volume")
                PercentText(value: model.inputVolume())
            }
            if store.state.prefs.showInputMeter { LevelMeter(level: model.inputLevel).padding(.leading, 32).padding(.trailing, 50) }
        }
    }
}

struct DevicePicker: View {
    let input: Bool
    @EnvironmentObject var devices: DeviceManager

    var body: some View {
        let list = input ? devices.visibleInputs : devices.visibleOutputs
        let current = devices.device(id: input ? devices.defaultInput : devices.defaultOutput)
        Menu {
            ForEach(list) { d in
                Button {
                    if input { devices.setDefaultInput(d) } else { devices.setDefaultOutput(d) }
                } label: {
                    Label(devices.displayName(d) + (d.id == current?.id ? "  ✓" : ""), systemImage: devices.symbol(d))
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: current.map(devices.symbol) ?? "speaker.slash").font(.caption)
                Text(current.map(devices.displayName) ?? "None")
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.primary.opacity(0.07), in: Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(maxWidth: 190, alignment: .trailing)
        .help(input ? "Choose microphone" : "Choose output device")
    }
}

// MARK: - Calls

struct CallBoostCard: View {
    @EnvironmentObject var model: MixerModel
    @EnvironmentObject var store: Store

    var body: some View {
        Card {
            HStack(spacing: 8) {
                SectionLabel(title: "During calls", symbol: "phone")
                Spacer()
                Text("boost other apps").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Image(systemName: "speaker.plus").frame(width: 22).foregroundStyle(.secondary)
                Slider(value: Binding(get: { Double(store.state.prefs.callBoost) },
                                      set: { v in model.setPrefs { $0.callBoost = Float((v * 20).rounded() / 20) } }),
                       in: 1...4)
                    .controlSize(.small)
                    .accessibilityLabel("Boost other apps during calls")
                PercentText(value: store.state.prefs.callBoost, warnAbove: 4)
            }
        }
        .help("macOS turns other sound down during calls (WhatsApp, FaceTime, Zoom…). This raises your other apps to make up for it.")
    }
}

// MARK: - Quick configs

struct QuickConfigMenu: View {
    @EnvironmentObject var model: MixerModel
    @EnvironmentObject var store: Store
    @State private var naming = false
    @State private var name = ""

    var body: some View {
        Menu {
            if store.state.quickConfigs.isEmpty { Text("No saved configs yet") }
            ForEach(store.state.quickConfigs) { c in
                Button(c.name) { model.applyQuickConfig(c) }
            }
            Divider()
            Button("Save Current Setup…") { name = "Config \(store.state.quickConfigs.count + 1)"; naming = true }
        } label: {
            Image(systemName: "square.stack.3d.down.right")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .glassCircle()
        .fixedSize()
        .help("Quick Configs")
        .alert("Save Quick Config", isPresented: $naming) {
            TextField("Name", text: $name)
            Button("Save") { if !name.isEmpty { model.saveQuickConfig(name: name) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves every app's volume, routing and effects, plus your current devices.")
        }
    }
}
