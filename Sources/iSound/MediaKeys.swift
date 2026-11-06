import AppKit
import ApplicationServices
import SwiftUI

/// "Super Volume Keys": makes the keyboard volume keys work on outputs without hardware volume
/// (HDMI, some USB DACs, output groups) by using iSound's software volume.
final class MediaKeys {
    static let shared = MediaKeys()
    weak var model: MixerModel?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    var isTrusted: Bool { AXIsProcessTrusted() }

    func requestAccess() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func setEnabled(_ on: Bool) {
        if on { start() } else { stop() }
    }

    private func start() {
        guard tap == nil else { return }
        guard isTrusted else { requestAccess(); return }
        let mask = CGEventMask(1 << 14)   // NSEventTypeSystemDefined
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = MediaKeys.shared.tap { CGEvent.tapEnable(tap: t, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            return MediaKeys.shared.handle(event) ? nil : Unmanaged.passUnretained(event)
        }, userInfo: nil) else { return }
        tap = t
        source = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
    }

    private func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        tap = nil
        source = nil
    }

    /// Returns true when the key was handled (and should not reach macOS).
    private func handle(_ cg: CGEvent) -> Bool {
        guard let e = NSEvent(cgEvent: cg), e.type == .systemDefined, e.subtype.rawValue == 8 else { return false }
        let code = (e.data1 & 0xFFFF0000) >> 16
        let down = ((e.data1 & 0xFF00) >> 8) == 0xA
        guard [0, 1, 7].contains(code) else { return false }   // sound up, down, mute
        guard let model, let out = model.outputDevice, model.devices.usesSoftwareVolume(out) else { return false }
        guard down else { return true }
        let fine = e.modifierFlags.contains(.option) && e.modifierFlags.contains(.shift)
        let step = model.prefs.volumeKeyStep / (fine ? 4 : 1)
        DispatchQueue.main.async {
            switch code {
            case 0: model.nudgeOutputVolume(step)
            case 1: model.nudgeOutputVolume(-step)
            default: model.toggleOutputMute()
            }
            VolumeHUD.shared.show(symbol: model.isOutputMuted() ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                  title: model.devices.displayName(out),
                                  level: model.isOutputMuted() ? 0 : model.outputVolume())
            if code != 7 { VolumeFeedback.playIfEnabled() }
        }
        return true
    }
}

/// macOS's "Play feedback when volume is changed" setting.
enum VolumeFeedback {
    private static let key = "com.apple.sound.beep.feedback" as CFString

    static var isEnabled: Bool {
        get {
            (CFPreferencesCopyValue(key, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Int ?? 0) != 0
        }
        set {
            CFPreferencesSetValue(key, (newValue ? 1 : 0) as CFNumber, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        }
    }

    static func playIfEnabled() {
        guard isEnabled else { return }
        let path = "/System/Library/LoginPlugins/BezelServices.loginPlugin/Contents/Resources/volume.aiff"
        (NSSound(contentsOfFile: path, byReference: true) ?? NSSound(named: "Pop"))?.play()
    }
}

/// macOS's alert ("sound effects") volume.
enum AlertVolume {
    private static let key = "com.apple.sound.beep.volume" as CFString

    static var value: Float {
        get {
            (CFPreferencesCopyValue(key, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? NSNumber)?.floatValue ?? 1
        }
        set {
            CFPreferencesSetValue(key, NSNumber(value: min(max(newValue, 0), 1)), kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            DistributedNotificationCenter.default().postNotificationName(
                NSNotification.Name("com.apple.sound.settingsChangedNotification"), object: nil, userInfo: nil, deliverImmediately: true)
        }
    }
}

/// A small on-screen popup like the system volume overlay.
final class VolumeHUD {
    static let shared = VolumeHUD()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(symbol: String, title: String? = nil, level: Float?) {
        let view = HUDView(symbol: symbol, title: title, level: level)
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: view)
        if let screen = NSScreen.main {
            let size = NSSize(width: 220, height: 160)
            panel.setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.minY + 140,
                                  width: size.width, height: size.height), display: true)
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak panel] in
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; panel?.animator().alphaValue = 0 }) { panel?.orderOut(nil) }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3, execute: work)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary]
        return p
    }

    private struct HUDView: View {
        let symbol: String
        let title: String?
        let level: Float?

        var body: some View {
            VStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 44, weight: .medium))
                if let title { Text(title).font(.callout).lineLimit(1) }
                if let level {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.primary.opacity(0.15))
                            Capsule().fill(.primary).frame(width: g.size.width * CGFloat(min(max(level, 0), 1)))
                        }
                    }
                    .frame(height: 6)
                }
            }
            .padding(20)
            .frame(width: 220, height: 160)
            .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 18))
        }
    }
}
