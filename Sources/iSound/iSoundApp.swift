import Combine
import SwiftUI

@main
struct ISoundApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MixerView().environment(delegate)
        } label: {
            MenuBarLabel().environment(delegate)
        }
        .menuBarExtraStyle(.window)

        Window("iSound", id: "mixer") {
            MixerView(inWindow: true).environment(delegate)
        }
        .defaultSize(width: 420, height: 640)

        Window("Audio Devices", id: "devices") {
            DevicesView().environment(delegate)
        }
        .defaultSize(width: 760, height: 560)

        Window("Audio Alerts", id: "alerts") {
            AlertsView().environment(delegate)
        }

        Settings {
            SettingsView().environment(delegate)
        }
    }
}

extension View {
    func environment(_ d: AppDelegate) -> some View {
        environmentObject(d.model)
            .environmentObject(d.model.store)
            .environmentObject(d.model.devices)
            .environmentObject(d.model.auHost)
            .environmentObject(d.library)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = MixerModel()
    let library = HeadphoneEQLibrary()
    private var statusItems: StatusItemController?
    private var cancellables = Set<AnyCancellable>()

    override init() {
        super.init()
        if Snapshot.isActive { return }
        HotkeyCenter.shared.perform = { [weak model] in model?.perform($0) }
        model.store.$state.map(\.hotkeys).removeDuplicates()
            .sink { HotkeyCenter.shared.register($0) }
            .store(in: &cancellables)
        MediaKeys.shared.model = model
        if model.prefs.superVolumeKeys { MediaKeys.shared.setEnabled(true) }
        statusItems = StatusItemController(model: model)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Snapshot.isActive { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Snapshot.run(self) } }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Un-mute everything we captured before exiting.
        if !Snapshot.isActive { model.shutdown() }
    }
}

/// The menu bar icon: app icon, volume, current device or a live meter.
struct MenuBarLabel: View {
    @EnvironmentObject var model: MixerModel
    @EnvironmentObject var store: Store
    @EnvironmentObject var devices: DeviceManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let _ = devices.tick
        Group {
            switch store.state.prefs.menuBarIcon {
            case .app:
                Image(systemName: "slider.vertical.3")
            case .speaker:
                let v = model.outputVolume()
                Image(systemName: model.isOutputMuted() ? "speaker.slash.fill" : "speaker.wave.3.fill", variableValue: Double(v))
            case .device:
                Image(systemName: model.outputDevice.map(devices.symbol) ?? "speaker.slash")
            case .meter:
                Image(nsImage: Self.meterImage(model.outputLevel))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showMixerWindow)) { _ in
            openWindow(id: "mixer")
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    static func meterImage(_ level: Float) -> NSImage {
        let img = NSImage(size: NSSize(width: 20, height: 16), flipped: false) { rect in
            let bars = 5
            let lit = Int((LevelMeter.scale(level) * Float(bars)).rounded(.up))
            for i in 0..<bars {
                let h = CGFloat(4 + i * 3)
                let r = NSRect(x: CGFloat(i) * 4, y: (rect.height - h) / 2, width: 3, height: h)
                NSColor.black.withAlphaComponent(i < lit ? 1 : 0.3).setFill()
                NSBezierPath(roundedRect: r, xRadius: 1, yRadius: 1).fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}
