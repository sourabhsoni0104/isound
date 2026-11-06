import SwiftUI

struct AppRowView: View {
    let row: AppRow
    @Binding var expanded: Bool
    @EnvironmentObject var model: MixerModel
    @EnvironmentObject var store: Store

    private var s: SourceSettings { store.state.sources[row.id] ?? SourceSettings() }
    private var compact: Bool { store.state.prefs.compact }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Line 1: icon, name + status, percentage, mute, options
            HStack(spacing: 10) {
                AppIcon(iconPath: row.iconPath, symbol: row.symbol, size: compact ? 22 : 28)
                    .opacity(row.isRunning ? (row.isPlaying ? 1 : 0.7) : 0.4)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(row.name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.tail)
                        if s.favorite { Image(systemName: "star.fill").font(.system(size: 8)).foregroundStyle(.yellow) }
                    }
                    if !compact { status }
                }
                .layoutPriority(1)

                Spacer(minLength: 4)

                PercentText(value: s.volume)
                    .onTapGesture(count: 2) { model.reset(row.id) }
                    .help("Double-click to reset to 100%")

                Button { model.toggleMute(row.id) } label: {
                    Image(systemName: s.muted ? (s.muteUntil != nil ? "timer" : "speaker.slash.fill") : speakerSymbol)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(s.muted ? .red : .primary)
                        .frame(width: 26, height: 26)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassCircle()
                .help(s.muted ? "Unmute" : "Mute")
                .accessibilityLabel(s.muted ? "Unmute \(row.name)" : "Mute \(row.name)")

                Button { withAnimation(.snappy(duration: 0.2)) { expanded.toggle() } } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                        .foregroundStyle(s.hasActiveEffects || s.output != .system ? Color.accentColor : .secondary)
                        .frame(width: 22, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Options, routing and effects")
                .accessibilityLabel("\(row.name) options")
            }

            // Line 2: full-width volume slider with the level meter underneath
            VStack(spacing: 3) {
                VolumeSlider(value: Binding(get: { Double(s.volume) }, set: { model.setVolume(Float($0), for: row.id) }),
                             range: 0...4, marks: [1], label: "\(row.name) volume")
                    .disabled(s.muted)
                if store.state.prefs.showMeters && row.isRunning {
                    LevelMeter(level: model.levels[row.id] ?? 0, outlined: !row.isPlaying)
                }
            }
            .padding(.leading, compact ? 0 : 38)

            if let error = row.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, compact ? 0 : 38)
            }

            if expanded {
                AppOptionsView(key: row.id)
                    .padding(.top, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(10)
        .background(.primary.opacity(expanded ? 0.07 : 0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contextMenu { RowContextMenu(key: row.id) }
    }

    private var status: some View {
        let text: String
        let color: Color
        if row.isCall { text = "On a call"; color = .blue }
        else if s.muted, let until = s.muteUntil { text = "Muted until \(until.formatted(date: .omitted, time: .shortened))"; color = .red }
        else if s.muted { text = "Muted"; color = .red }
        else if row.isPlaying { text = row.isProcessed ? "Playing · adjusted" : "Playing"; color = .green }
        else if row.isRunning { text = "Quiet"; color = .secondary }
        else { text = "Not running"; color = .secondary }
        return Text(text).font(.caption2).foregroundStyle(color).lineLimit(1)
    }

    private var speakerSymbol: String {
        switch s.volume {
        case 0: "speaker.fill"
        case ..<0.5: "speaker.wave.1.fill"
        case ..<1.01: "speaker.wave.2.fill"
        default: "speaker.wave.3.fill"
        }
    }
}

struct RowContextMenu: View {
    let key: String
    @EnvironmentObject var model: MixerModel

    var body: some View {
        let s = model.setting(for: key)
        Button(s.muted ? "Unmute" : "Mute") { model.toggleMute(key) }
        Menu("Mute For") { TimedMuteItems(key: key) }
        Button("Reset Volume to 100%") { model.reset(key) }
        Divider()
        Button(s.favorite ? "Remove from Favorites" : "Add to Favorites") { model.updateSource(key) { $0.favorite.toggle() } }
        Button(s.menuBarIndicator ? "Hide from Menu Bar" : "Show in Menu Bar") {
            model.updateSource(key) { $0.menuBarIndicator.toggle() }
            model.prefsChanged()
        }
    }
}

struct TimedMuteItems: View {
    let key: String
    @EnvironmentObject var model: MixerModel
    var body: some View {
        ForEach([(60.0, "1 minute"), (300, "5 minutes"), (900, "15 minutes"), (1800, "30 minutes"), (3600, "1 hour"), (7200, "2 hours")], id: \.0) { secs, label in
            Button(label) { model.mute(key, for: secs) }
        }
    }
}

/// Expanded per-app options: routing, timed mute, effects, shortcuts, menu bar.
struct AppOptionsView: View {
    let key: String
    @EnvironmentObject var model: MixerModel
    @EnvironmentObject var store: Store
    @EnvironmentObject var devices: DeviceManager

    var body: some View {
        let s = model.setting(for: key)
        VStack(alignment: .leading, spacing: 10) {
            Divider()

            optionRow("Output", symbol: "hifispeaker") {
                Menu {
                    Button("System output") { model.updateSource(key) { $0.output = .system } }
                    Divider()
                    ForEach(devices.visibleOutputs.filter { !$0.isGroup }) { d in
                        Button { model.updateSource(key) { $0.output = .device(d.uid) } } label: {
                            Label(devices.displayName(d), systemImage: devices.symbol(d))
                        }
                    }
                    if !store.state.groups.isEmpty {
                        Divider()
                        ForEach(store.state.groups) { g in
                            Button { model.updateSource(key) { $0.output = .group(g.id) } } label: {
                                Label(g.name, systemImage: "hifispeaker.2.fill")
                            }
                        }
                    }
                } label: { pill(outputName(s.output)) }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            }

            optionRow("Mute for", symbol: "timer") {
                Menu { TimedMuteItems(key: key) } label: {
                    pill(s.muteUntil.map { "until \($0.formatted(date: .omitted, time: .shortened))" } ?? "Choose")
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            }

            EffectChainView(target: .source(key))

            DisclosureGroup {
                VStack(alignment: .leading, spacing: 6) {
                    shortcutRow("Volume up", .appVolumeUp(key))
                    shortcutRow("Volume down", .appVolumeDown(key))
                    shortcutRow("Mute", .appToggleMute(key))
                }
                .padding(.top, 4)
            } label: {
                Label("Keyboard shortcuts", systemImage: "keyboard").font(.caption)
            }

            HStack(spacing: 14) {
                Toggle("Favorite", isOn: Binding(get: { s.favorite }, set: { v in model.updateSource(key) { $0.favorite = v } }))
                Toggle("Menu bar icon", isOn: Binding(get: { s.menuBarIndicator }, set: { v in
                    model.updateSource(key) { $0.menuBarIndicator = v }
                    model.prefsChanged()
                }))
            }
            .toggleStyle(.checkbox)
            .font(.caption)
        }
    }

    private func optionRow<C: View>(_ title: String, symbol: String, @ViewBuilder control: () -> C) -> some View {
        HStack(spacing: 8) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 8)
            control()
        }
    }

    private func pill(_ text: String) -> some View {
        HStack(spacing: 4) {
            Text(text).font(.caption.weight(.medium)).lineLimit(1).truncationMode(.tail)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(.primary.opacity(0.07), in: Capsule())
        .frame(maxWidth: 180, alignment: .trailing)
    }

    private func shortcutRow(_ title: String, _ action: HotkeyAction) -> some View {
        HStack {
            Text(title).font(.caption)
            Spacer()
            ShortcutRecorder(binding: model.binding(for: action),
                             onChange: { model.setBinding(action, keyCode: $0, modifiers: $1) },
                             onClear: { model.clearBinding(action) })
        }
    }

    private func outputName(_ o: OutputTarget) -> String {
        switch o {
        case .system: return "System output"
        case .device(let uid): return devices.device(uid: uid).map(devices.displayName) ?? "Disconnected device"
        case .group(let id): return store.state.groups.first { $0.id == id }?.name ?? "Deleted group"
        }
    }
}
