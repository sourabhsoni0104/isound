import AppKit
import AVFoundation
import AudioToolbox
import Combine
import CoreAudioKit
import SwiftUI

/// Finds, loads, saves and shows Audio Unit effect plug-ins.
final class AUHost: ObservableObject {
    @Published private(set) var available: [AVAudioUnitComponent] = []
    @Published private(set) var loaded: Set<UUID> = []
    @Published private(set) var failed: [UUID: String] = [:]

    private var units: [UUID: AUAudioUnit] = [:]
    private var loading: Set<UUID> = []
    private var windows: [UUID: NSWindow] = [:]
    var onLoaded: (() -> Void)?

    init() {
        refreshList()
        NotificationCenter.default.addObserver(forName: .AVAudioUnitComponentTagsDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.refreshList()
        }
    }

    func refreshList() {
        var list: [AVAudioUnitComponent] = []
        for type in [kAudioUnitType_Effect, kAudioUnitType_MusicEffect] {
            let desc = AudioComponentDescription(componentType: type, componentSubType: 0, componentManufacturer: 0,
                                                 componentFlags: 0, componentFlagsMask: 0)
            list += AVAudioUnitComponentManager.shared().components(matching: desc)
        }
        available = list.sorted {
            ($0.manufacturerName, $0.name) < ($1.manufacturerName, $1.name)
        }
    }

    static func key(_ c: AVAudioUnitComponent) -> String {
        let d = c.audioComponentDescription
        return "au.\(d.componentType).\(d.componentSubType).\(d.componentManufacturer)"
    }

    static func effect(from c: AVAudioUnitComponent) -> AUEffect {
        let d = c.audioComponentDescription
        return AUEffect(type: d.componentType, subType: d.componentSubType, manufacturer: d.componentManufacturer,
                        name: c.name, manufacturerName: c.manufacturerName)
    }

    func unit(_ id: UUID) -> AUAudioUnit? { units[id] }

    /// Loads plug-ins for the given effects (async) and unloads ones no longer used.
    func sync(_ effects: [EffectConfig]) {
        let wanted = Dictionary(effects.compactMap { e -> (UUID, AUEffect)? in
            if case .audioUnit(let a) = e.kind { return (e.id, a) }
            return nil
        }, uniquingKeysWith: { a, _ in a })

        for id in units.keys where wanted[id] == nil {
            windows.removeValue(forKey: id)?.close()
            units.removeValue(forKey: id)
            loaded.remove(id)
        }
        for (id, effect) in wanted where units[id] == nil && !loading.contains(id) && failed[id] == nil {
            loading.insert(id)
            AUAudioUnit.instantiate(with: effect.description, options: .loadOutOfProcess) { [weak self] unit, error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.loading.remove(id)
                    guard let unit else {
                        self.failed[id] = error?.localizedDescription ?? "Couldn't load \(effect.name)"
                        return
                    }
                    if let data = effect.state,
                       let state = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                        unit.fullState = state
                    }
                    self.units[id] = unit
                    self.loaded.insert(id)
                    self.onLoaded?()
                }
            }
        }
    }

    /// The plug-in's current settings, for saving.
    func state(_ id: UUID) -> Data? {
        guard let s = units[id]?.fullState else { return nil }
        return try? PropertyListSerialization.data(fromPropertyList: s, format: .binary, options: 0)
    }

    func latency(_ id: UUID) -> TimeInterval { units[id]?.latency ?? 0 }

    // MARK: - Windows

    func isWindowOpen(_ id: UUID) -> Bool { windows[id]?.isVisible == true }

    func toggleWindow(_ id: UUID, title: String) {
        if let w = windows[id], w.isVisible {
            w.close()
        } else {
            showWindow(id, title: title)
        }
    }

    func showWindow(_ id: UUID, title: String) {
        if let w = windows[id] {
            // Already open (maybe pinned somewhere): bring it forward and flash it so it's easy to find.
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            w.animator().alphaValue = 0.3
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { w.animator().alphaValue = 1 }
            return
        }
        guard let unit = units[id] else { return }
        unit.requestViewController { [weak self] vc in
            DispatchQueue.main.async {
                guard let self else { return }
                let content: NSViewController = vc ?? NSHostingController(rootView: GenericAUView(unit: unit))
                let window = NSWindow(contentViewController: content)
                window.title = title
                window.styleMask.insert([.titled, .closable, .resizable])
                window.isReleasedWhenClosed = false
                let pin = NSTitlebarAccessoryViewController()
                let button = NSButton(image: NSImage(systemSymbolName: "pin", accessibilityDescription: "Pin")!,
                                      target: nil, action: nil)
                button.isBordered = false
                button.toolTip = "Keep this window on top"
                button.target = window
                button.action = #selector(NSWindow.toggleFloating(_:))
                pin.view = button
                pin.layoutAttribute = .trailing
                window.addTitlebarAccessoryViewController(pin)
                window.center()
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                self.windows[id] = window
            }
        }
    }
}

extension NSWindow {
    @objc func toggleFloating(_ sender: NSButton) {
        level = level == .floating ? .normal : .floating
        sender.image = NSImage(systemSymbolName: level == .floating ? "pin.fill" : "pin", accessibilityDescription: "Pin")
    }
}

/// Simple sliders for plug-ins that don't ship their own interface.
struct GenericAUView: View {
    let unit: AUAudioUnit

    var body: some View {
        let params = unit.parameterTree?.allParameters ?? []
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if params.isEmpty {
                    Text("This effect has no adjustable settings.").foregroundStyle(.secondary)
                }
                ForEach(params, id: \.address) { p in
                    ParamRow(param: p)
                }
            }
            .padding()
        }
        .frame(minWidth: 360, minHeight: 120)
    }

    private struct ParamRow: View {
        let param: AUParameter
        @State private var value: Float = 0

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(param.displayName).font(.callout)
                    Spacer()
                    Text(param.string(fromValue: &value)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { value }, set: { value = $0; param.value = $0 }),
                       in: param.minValue...max(param.maxValue, param.minValue + 0.0001))
            }
            .onAppear { value = param.value }
        }
    }
}
