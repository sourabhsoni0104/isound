import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// The list of effects on an app or device, with bypass, edit, presets, copy/move.
struct EffectChainView: View {
    let target: EffectTarget
    @EnvironmentObject var model: MixerModel
    @EnvironmentObject var store: Store
    @EnvironmentObject var auHost: AUHost
    @EnvironmentObject var library: HeadphoneEQLibrary

    var body: some View {
        let effects = model.effects(of: target)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Effects").font(.caption)
                Spacer()
                AddEffectMenu(target: target)
            }
            ForEach(Array(effects.enumerated()), id: \.element.id) { index, e in
                EffectRow(target: target, effect: e, index: index, count: effects.count)
            }
        }
    }
}

struct EffectRow: View {
    let target: EffectTarget
    let effect: EffectConfig
    let index: Int
    let count: Int
    @EnvironmentObject var model: MixerModel
    @EnvironmentObject var store: Store
    @EnvironmentObject var auHost: AUHost
    @EnvironmentObject var library: HeadphoneEQLibrary
    @EnvironmentObject var devices: DeviceManager
    @State private var renaming = false
    @State private var newName = ""
    @State private var savingPreset = false
    @State private var presetName = ""

    var body: some View {
        HStack(spacing: 6) {
            Button {
                model.updateEffects(target) { list in if let i = list.firstIndex(where: { $0.id == effect.id }) { list[i].bypassed.toggle() } }
            } label: {
                Image(systemName: "power").foregroundStyle(effect.bypassed ? Color.secondary : Color.accentColor)
            }
            .buttonStyle(.plain)
            .help(effect.bypassed ? "Turn on" : "Bypass")
            .accessibilityLabel(effect.bypassed ? "Turn on \(effect.displayName)" : "Bypass \(effect.displayName)")

            Image(systemName: effect.kind.symbol).font(.caption).foregroundStyle(.secondary)
            Button { openEditor() } label: {
                Text(effect.displayName).font(.caption).lineLimit(1).foregroundStyle(effect.bypassed ? .secondary : .primary)
            }
            .buttonStyle(.plain)
            .help("Edit")

            if effect.kind.isAudioUnit {
                if let err = auHost.failed[effect.id] {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(err)
                } else if auHost.latency(effect.id) > 0.03 {
                    Text("\(Int(auHost.latency(effect.id) * 1000)) ms").font(.caption2).foregroundStyle(.orange)
                        .help("This effect delays audio noticeably")
                }
            }
            Spacer()
            Menu {
                Button("Edit…") { openEditor() }
                Button("Rename…") { newName = effect.nickname ?? ""; renaming = true }
                Divider()
                Button("Save as Preset…") { presetName = effect.displayName; savingPreset = true }
                let presets = store.state.presets.filter { sameType($0.kind, effect.kind) }
                if !presets.isEmpty {
                    Menu("Load Preset") {
                        ForEach(presets) { p in Button(p.name) { model.applyPreset(p, to: effect, in: target) } }
                    }
                }
                Divider()
                Menu("Copy To") { transferTargets(move: false) }
                Menu("Move To") { transferTargets(move: true) }
                Divider()
                Button("Move Up") { move(-1) }.disabled(index == 0)
                Button("Move Down") { move(1) }.disabled(index == count - 1)
                Divider()
                Button("Remove", role: .destructive) {
                    model.updateEffects(target) { $0.removeAll { $0.id == effect.id } }
                }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .alert("Rename Effect", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Save") {
                model.updateEffects(target) { list in
                    if let i = list.firstIndex(where: { $0.id == effect.id }) { list[i].nickname = newName.isEmpty ? nil : newName }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Save Preset", isPresented: $savingPreset) {
            TextField("Name", text: $presetName)
            Button("Save") { if !presetName.isEmpty { model.savePreset(effect, name: presetName) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder private func transferTargets(move: Bool) -> some View {
        ForEach(model.rows.filter { EffectTarget.source($0.id) != target }) { r in
            Button(r.name) { model.transfer(effect, from: target, to: .source(r.id), move: move) }
        }
        Divider()
        ForEach(devices.visibleOutputs.filter { EffectTarget.device($0.uid) != target }) { d in
            Button("\(devices.displayName(d)) (device)") { model.transfer(effect, from: target, to: .device(d.uid), move: move) }
        }
    }

    private func move(_ delta: Int) {
        model.updateEffects(target) { list in
            guard let i = list.firstIndex(where: { $0.id == effect.id }) else { return }
            let j = i + delta
            guard list.indices.contains(j) else { return }
            list.swapAt(i, j)
        }
    }

    private func sameType(_ a: EffectKind, _ b: EffectKind) -> Bool {
        switch (a, b) {
        case (.eq10, .eq10), (.parametric, .parametric), (.balancePan, .balancePan), (.magicBoost, .magicBoost): return true
        case (.audioUnit(let x), .audioUnit(let y)): return x.type == y.type && x.subType == y.subType && x.manufacturer == y.manufacturer
        default: return false
        }
    }

    private func openEditor() {
        if effect.kind.isAudioUnit {
            auHost.showWindow(effect.id, title: effect.displayName)
            return
        }
        let id = "effect.\(effect.id)"
        if WindowManager.shared.isOpen(id) {
            // Pinned/open somewhere: bring it forward instead of opening another.
            WindowManager.shared.show(id: id, title: effect.displayName, size: .zero) { EmptyView() }
            return
        }
        WindowManager.shared.show(id: id, title: effect.displayName, size: CGSize(width: 520, height: 380)) {
            EffectEditor(target: target, effectID: effect.id)
                .environmentObject(model).environmentObject(store).environmentObject(library)
                .tint(store.state.prefs.accent.color)
        }
    }
}

// MARK: - Adding effects

struct AddEffectMenu: View {
    let target: EffectTarget
    @EnvironmentObject var model: MixerModel
    @EnvironmentObject var store: Store
    @EnvironmentObject var auHost: AUHost
    @EnvironmentObject var library: HeadphoneEQLibrary

    var body: some View {
        Menu {
            let favs = store.state.favoriteEffects
            if !favs.isEmpty {
                Section("Favorites") {
                    ForEach(favs, id: \.self) { key in
                        if let item = BuiltInEffect.all.first(where: { $0.key == key }) {
                            Button { model.addEffect(item.make(), to: target) } label: { Label(item.name, systemImage: item.symbol) }
                        } else if let c = auHost.available.first(where: { AUHost.key($0) == key }) {
                            Button { model.addEffect(.audioUnit(AUHost.effect(from: c)), to: target) } label: { Label(c.name, systemImage: "puzzlepiece.extension") }
                        }
                    }
                }
            }
            Section("Built-in") {
                ForEach(BuiltInEffect.all, id: \.key) { item in
                    Button { model.addEffect(item.make(), to: target) } label: { Label(item.name, systemImage: item.symbol) }
                }
            }
            Divider()
            Button("Browse All Effects…") {
                WindowManager.shared.show(id: "browse.\(target)", title: "Add Effect", size: CGSize(width: 440, height: 480)) {
                    EffectBrowser(target: target)
                        .environmentObject(model).environmentObject(store).environmentObject(auHost)
                        .tint(store.state.prefs.accent.color)
                }
            }
        } label: {
            Label("Add", systemImage: "plus").font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

struct BuiltInEffect {
    let key: String
    let name: String
    let symbol: String
    let detail: String
    let make: () -> EffectKind

    static let all: [BuiltInEffect] = [
        BuiltInEffect(key: "builtin.eq10", name: "10-Band EQ", symbol: "slider.vertical.3",
                      detail: "Ten-band equalizer with presets and preamp") { .eq10(EQ10()) },
        BuiltInEffect(key: "builtin.headphone", name: "Headphone EQ", symbol: "headphones",
                      detail: "Correction for thousands of headphone models, or import AutoEq / Equalizer APO / REW files") { .parametric(ParametricEQ()) },
        BuiltInEffect(key: "builtin.boost", name: "Magic Boost", symbol: "wand.and.stars",
                      detail: "Lifts quiet sound, leaves loud sound alone") { .magicBoost(MagicBoost()) },
        BuiltInEffect(key: "builtin.balance", name: "Balance", symbol: "arrow.left.and.right",
                      detail: "Left/right balance") { .balancePan(BalancePan(mode: .balance)) },
        BuiltInEffect(key: "builtin.pan", name: "Pan", symbol: "arrow.left.and.right.circle",
                      detail: "Send all audio toward the left or right") { .balancePan(BalancePan(mode: .pan)) },
    ]
}

/// Searchable list of every effect: built-ins and installed Audio Unit plug-ins.
struct EffectBrowser: View {
    let target: EffectTarget
    @EnvironmentObject var model: MixerModel
    @EnvironmentObject var store: Store
    @EnvironmentObject var auHost: AUHost
    @State private var query = ""
    @State private var added: String?

    var body: some View {
        let q = query.lowercased()
        let builtIns = BuiltInEffect.all.filter { q.isEmpty || $0.name.lowercased().contains(q) }
        let plugins = auHost.available.filter { q.isEmpty || $0.name.lowercased().contains(q) || $0.manufacturerName.lowercased().contains(q) }
        let favs = Set(store.state.favoriteEffects)
        VStack(spacing: 0) {
            TextField("Search effects", text: $query).textFieldStyle(.roundedBorder).padding(10)
            List {
                Section("Built-in") {
                    ForEach(builtIns, id: \.key) { e in
                        row(name: e.name, detail: e.detail, symbol: e.symbol, key: e.key, favorite: favs.contains(e.key)) {
                            model.addEffect(e.make(), to: target)
                        }
                    }
                }
                let byMaker = Dictionary(grouping: plugins, by: \.manufacturerName)
                ForEach(byMaker.keys.sorted(), id: \.self) { maker in
                    Section(maker.isEmpty ? "Other" : maker) {
                        ForEach(byMaker[maker] ?? [], id: \.self) { c in
                            row(name: c.name, detail: c.typeName, symbol: "puzzlepiece.extension", key: AUHost.key(c), favorite: favs.contains(AUHost.key(c))) {
                                model.addEffect(.audioUnit(AUHost.effect(from: c)), to: target)
                            }
                        }
                    }
                }
            }
            if let added { Text("Added \(added)").font(.caption).foregroundStyle(.green).padding(6) }
        }
        .frame(minWidth: 360, minHeight: 360)
    }

    private func row(name: String, detail: String, symbol: String, key: String, favorite: Bool, add: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: symbol).frame(width: 20)
            VStack(alignment: .leading) {
                Text(name)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button { model.toggleFavoriteEffect(key) } label: { Image(systemName: favorite ? "star.fill" : "star").foregroundStyle(favorite ? .yellow : .secondary) }
                .buttonStyle(.plain).help(favorite ? "Remove from favorites" : "Add to favorites")
            Button("Add") { add(); added = name }.controlSize(.small)
        }
    }
}

// MARK: - Editors

struct EffectEditor: View {
    let target: EffectTarget
    let effectID: UUID
    @EnvironmentObject var model: MixerModel
    @EnvironmentObject var store: Store

    var body: some View {
        let _ = store.state
        if let e = model.effects(of: target).first(where: { $0.id == effectID }) {
            Group {
                switch e.kind {
                case .eq10(let eq): EQ10Editor(eq: eq) { update(.eq10($0)) }
                case .parametric(let p): ParametricEditor(eq: p) { update(.parametric($0)) }
                case .balancePan(let b): BalancePanEditor(value: b) { update(.balancePan($0)) }
                case .magicBoost(let m): MagicBoostEditor(value: m) { update(.magicBoost($0)) }
                case .audioUnit: Text("This plug-in has its own window.")
                }
            }
            .padding()
            .frame(minWidth: 460, minHeight: 260)
        } else {
            Text("This effect was removed.").foregroundStyle(.secondary).padding()
        }
    }

    private func update(_ kind: EffectKind) {
        model.updateEffects(target, coalesce: "fx.\(effectID)") { list in
            if let i = list.firstIndex(where: { $0.id == effectID }) { list[i].kind = kind }
        }
    }
}

struct EQ10Editor: View {
    let eq: EQ10
    let onChange: (EQ10) -> Void
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Menu("Presets") {
                    ForEach(EQ10.presets, id: \.0) { name, gains in
                        Button(name) { var e = eq; e.gains = gains; onChange(e) }
                    }
                    let mine = store.state.presets.compactMap { p -> (String, EQ10)? in
                        if case .eq10(let e) = p.kind { return (p.name, e) }; return nil
                    }
                    if !mine.isEmpty {
                        Divider()
                        ForEach(mine, id: \.0) { name, e in Button(name) { onChange(e) } }
                    }
                }
                .fixedSize()
                Spacer()
                Button("Reset") { onChange(EQ10()) }
            }
            HStack(alignment: .bottom, spacing: 14) {
                band(label: "Preamp", value: eq.preampDB) { var e = eq; e.preampDB = $0; onChange(e) }
                Divider().frame(height: 150)
                ForEach(0..<10, id: \.self) { i in
                    band(label: Self.label(EQ10.frequencies[i]), value: eq.gains[i]) { var e = eq; e.gains[i] = $0; onChange(e) }
                }
            }
        }
    }

    private func band(label: String, value: Double, set: @escaping (Double) -> Void) -> some View {
        VStack(spacing: 4) {
            Text(String(format: "%+.0f", value)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            Slider(value: Binding(get: { value }, set: { set(($0 * 2).rounded() / 2) }), in: -12...12)
                .frame(width: 140)
                .rotationEffect(.degrees(-90))
                .frame(width: 22, height: 140)
                .accessibilityLabel("\(label) gain")
            Text(label).font(.caption2)
        }
    }

    static func label(_ f: Double) -> String { f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))" }
}

struct ParametricEditor: View {
    let eq: ParametricEQ
    let onChange: (ParametricEQ) -> Void
    @EnvironmentObject var library: HeadphoneEQLibrary
    @State private var query = ""
    @State private var fetching = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GroupBox("Find your headphones") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("Search, e.g. AirPods Pro", text: $query).textFieldStyle(.roundedBorder)
                        Button("Import File…") { importFile() }
                    }
                    if library.loading { ProgressView().controlSize(.small) }
                    if let err = library.error { Text(err).font(.caption).foregroundStyle(.red) }
                    if !query.isEmpty {
                        List(library.search(query)) { entry in
                            Button {
                                fetching = true
                                library.fetch(entry) { result in
                                    fetching = false
                                    if let result { onChange(result); message = "Loaded \(entry.name) (\(entry.source))"; query = "" }
                                    else { message = "Couldn't load that profile" }
                                }
                            } label: {
                                HStack { Text(entry.name); Spacer(); Text(entry.source).font(.caption).foregroundStyle(.secondary) }
                            }
                            .buttonStyle(.plain)
                        }
                        .frame(height: 140)
                    }
                    if fetching { ProgressView().controlSize(.small) }
                    if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                }
            }
            .onAppear { library.loadIndex() }

            HStack {
                TextField("Name", text: Binding(get: { eq.name }, set: { var e = eq; e.name = $0; onChange(e) }))
                    .textFieldStyle(.roundedBorder).frame(width: 200)
                Spacer()
                Text("Preamp").font(.caption)
                TextField("dB", value: Binding(get: { eq.preampDB }, set: { var e = eq; e.preampDB = $0; onChange(e) }), format: .number.precision(.fractionLength(1)))
                    .textFieldStyle(.roundedBorder).frame(width: 60)
                Text("dB").font(.caption)
            }

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(Array(eq.filters.enumerated()), id: \.offset) { i, f in
                        HStack(spacing: 6) {
                            Picker("", selection: Binding(get: { f.type }, set: { var e = eq; e.filters[i].type = $0; onChange(e) })) {
                                ForEach(FilterType.allCases) { Text($0.label).tag($0) }
                            }.labelsHidden().frame(width: 110)
                            num("Hz", f.freq) { var e = eq; e.filters[i].freq = $0; onChange(e) }
                            num("dB", f.gainDB) { var e = eq; e.filters[i].gainDB = $0; onChange(e) }
                            num("Q", f.q) { var e = eq; e.filters[i].q = $0; onChange(e) }
                            Button { var e = eq; e.filters.remove(at: i); onChange(e) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
            Button("Add Filter") { var e = eq; e.filters.append(FilterSpec(type: .peak, freq: 1000, gainDB: 0, q: 1)); onChange(e) }
        }
    }

    private func num(_ unit: String, _ v: Double, set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 2) {
            TextField(unit, value: Binding(get: { v }, set: set), format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.roundedBorder).frame(width: 66)
            Text(unit).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        if let parsed = FilterFileParser.parse(text, name: url.deletingPathExtension().lastPathComponent) {
            onChange(parsed)
            message = "Imported \(parsed.filters.count) filters"
        } else {
            message = "That file doesn't contain any filters iSound understands"
        }
    }
}

struct BalancePanEditor: View {
    let value: BalancePan
    let onChange: (BalancePan) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Mode", selection: Binding(get: { value.mode }, set: { var v = value; v.mode = $0; onChange(v) })) {
                Text("Balance").tag(BalancePan.Mode.balance)
                Text("Pan").tag(BalancePan.Mode.pan)
            }
            .pickerStyle(.segmented)
            Text(value.mode == .balance ? "Turns the left or right channel down." : "Mixes to mono and places it left or right.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("L")
                Slider(value: Binding(get: { value.value }, set: { var v = value; v.value = abs($0) < 0.04 ? 0 : $0; onChange(v) }), in: -1...1)
                Text("R")
            }
            Text(value.value == 0 ? "Center" : String(format: "%.0f%% %@", abs(value.value) * 100, value.value < 0 ? "left" : "right"))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

struct MagicBoostEditor: View {
    let value: MagicBoost
    let onChange: (MagicBoost) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Lifts quiet parts (whispers, quiet dialogue, soft music) while leaving loud parts roughly where they are.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Amount")
                Slider(value: Binding(get: { value.amount }, set: { var v = value; v.amount = $0; onChange(v) }), in: 0...1)
                Text("\(Int(value.amount * 100))%").font(.caption.monospacedDigit()).frame(width: 40)
            }
        }
    }
}
