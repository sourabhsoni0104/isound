import AppKit
import Carbon
import SwiftUI

/// Global keyboard shortcuts (work from any app, no extra permission needed).
final class HotkeyCenter {
    static let shared = HotkeyCenter()
    var perform: ((HotkeyAction) -> Void)?

    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: HotkeyAction] = [:]
    private var installed = false

    func register(_ bindings: [HotkeyBinding]) {
        installHandler()
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        actions.removeAll()
        for (i, b) in bindings.enumerated() {
            let id = UInt32(i + 1)
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: OSType(0x69534E44), id: id)   // 'iSND'
            if RegisterEventHotKey(b.keyCode, b.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                refs.append(ref)
                actions[id] = b.action
            }
        }
    }

    private func installHandler() {
        guard !installed else { return }
        installed = true
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let center = HotkeyCenter.shared
            if let action = center.actions[hk.id] {
                DispatchQueue.main.async { center.perform?(action) }
            }
            return noErr
        }, 1, &type, nil, nil)
    }

    // MARK: - Display

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    static func describe(_ b: HotkeyBinding) -> String {
        var s = ""
        if b.modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if b.modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if b.modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if b.modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + keyName(b.keyCode)
    }

    static func keyName(_ code: UInt32) -> String {
        let special: [UInt32: String] = [
            36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑",
            115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9",
            109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17",
            79: "F18", 80: "F19", 90: "F20",
        ]
        if let s = special[code] { return s }
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "#\(code)" }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { raw -> OSStatus in
            let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress!
            return UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "#\(code)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

/// Click, then press a key combination to record a shortcut.
struct ShortcutRecorder: View {
    let binding: HotkeyBinding?
    let onChange: (UInt32, UInt32) -> Void
    let onClear: () -> Void
    @State private var recording = false

    var body: some View {
        HStack(spacing: 4) {
            Button(recording ? "Press keys…" : (binding.map(HotkeyCenter.describe) ?? "Record Shortcut")) {
                recording.toggle()
            }
            .controlSize(.small)
            .background(KeyCatcher(active: $recording) { code, mods in onChange(code, mods) })
            if binding != nil {
                Button { onClear() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Remove shortcut")
            }
        }
    }

    private struct KeyCatcher: NSViewRepresentable {
        @Binding var active: Bool
        let onKey: (UInt32, UInt32) -> Void

        func makeNSView(context: Context) -> CatcherView {
            let v = CatcherView()
            v.onKey = { code, mods in onKey(code, mods); active = false }
            v.onCancel = { active = false }
            return v
        }

        func updateNSView(_ v: CatcherView, context: Context) {
            v.onKey = { code, mods in onKey(code, mods); active = false }
            v.onCancel = { active = false }
            if active { DispatchQueue.main.async { v.window?.makeFirstResponder(v) } }
        }

        final class CatcherView: NSView {
            var onKey: ((UInt32, UInt32) -> Void)?
            var onCancel: (() -> Void)?
            override var acceptsFirstResponder: Bool { true }
            override func keyDown(with event: NSEvent) {
                if event.keyCode == 53 { onCancel?(); return }   // Esc cancels
                let mods = HotkeyCenter.carbonModifiers(event.modifierFlags)
                let isFunctionKey = (96...122).contains(Int(event.keyCode))
                guard mods != 0 || isFunctionKey else { NSSound.beep(); return }
                onKey?(UInt32(event.keyCode), mods)
            }
            override func resignFirstResponder() -> Bool { onCancel?(); return true }
        }
    }
}
