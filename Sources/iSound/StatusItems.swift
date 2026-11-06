import AppKit
import Combine
import SwiftUI

/// Optional per-app menu bar icons that light up when the app makes sound.
final class StatusItemController {
    private let model: MixerModel
    private var items: [String: NSStatusItem] = [:]
    private var cancellables = Set<AnyCancellable>()

    init(model: MixerModel) {
        self.model = model
        model.store.$state.map { $0.sources.filter(\.value.menuBarIndicator).map(\.key).sorted() }
            .removeDuplicates()
            .sink { [weak self] keys in DispatchQueue.main.async { self?.sync(keys) } }
            .store(in: &cancellables)
        model.$levels
            .throttle(for: .milliseconds(100), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] levels in self?.update(levels) }
            .store(in: &cancellables)
    }

    private func sync(_ keys: [String]) {
        for (k, item) in items where !keys.contains(k) {
            NSStatusBar.system.removeStatusItem(item)
            items[k] = nil
        }
        for k in keys where items[k] == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.toolTip = model.name(of: k)
            item.menu = menu(for: k)
            items[k] = item
        }
        update(model.levels)
    }

    private func update(_ levels: [String: Float]) {
        for (k, item) in items {
            let s = model.setting(for: k)
            let level = levels[k] ?? 0
            item.button?.image = icon(for: k, level: level, muted: s.muted)
        }
    }

    private func icon(for key: String, level: Float, muted: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let base: NSImage = model.setting(for: key).iconPath.map(AppIcon.image)
            ?? NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil)!
        return NSImage(size: size, flipped: false) { rect in
            let active = LevelMeter.scale(level) > 0.05
            base.draw(in: rect.insetBy(dx: 1, dy: 1), from: .zero, operation: .sourceOver, fraction: muted ? 0.3 : (active ? 1 : 0.55))
            if active && !muted {
                NSColor.systemGreen.setFill()
                NSBezierPath(ovalIn: NSRect(x: rect.maxX - 6, y: 0, width: 6, height: 6)).fill()
            }
            if muted {
                NSColor.systemRed.setStroke()
                let p = NSBezierPath(); p.move(to: NSPoint(x: 2, y: 2)); p.line(to: NSPoint(x: 16, y: 16)); p.lineWidth = 2; p.stroke()
            }
            return true
        }
    }

    private func menu(for key: String) -> NSMenu {
        let menu = NSMenu()
        let title = NSMenuItem(title: model.name(of: key), action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        let sliderItem = NSMenuItem()
        let host = NSHostingView(rootView: MenuSlider(model: model, key: key))
        host.frame = NSRect(x: 0, y: 0, width: 220, height: 30)
        sliderItem.view = host
        menu.addItem(sliderItem)
        menu.addItem(ActionItem(title: "Mute / Unmute") { [weak self] in self?.model.toggleMute(key) })
        menu.addItem(.separator())
        menu.addItem(ActionItem(title: "Remove from Menu Bar") { [weak self] in
            self?.model.updateSource(key) { $0.menuBarIndicator = false }
            self?.model.prefsChanged()
        })
        return menu
    }

    private struct MenuSlider: View {
        let model: MixerModel
        let key: String
        @State private var v: Double = 1
        var body: some View {
            HStack {
                Slider(value: $v, in: 0...4) { _ in }.onChange(of: v) { _, nv in model.setVolume(Float(nv), for: key) }
                Text(Float(v).percent).font(.caption.monospacedDigit()).frame(width: 40)
            }
            .padding(.horizontal, 14)
            .onAppear { v = Double(model.setting(for: key).volume) }
        }
    }
}

/// NSMenuItem that runs a closure.
final class ActionItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func run() { handler() }
}
