import AppKit
import SwiftUI

// MARK: - Glass styling

extension View {
    /// Liquid Glass on macOS 26+, a frosted material before that.
    @ViewBuilder func glassCard(radius: CGFloat = 16) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: radius))
        } else {
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
    }

    /// Small round glass button background.
    @ViewBuilder func glassCircle() -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(.regular.interactive(), in: .circle)
        } else {
            self.background(.quaternary, in: Circle())
        }
    }
}

/// A rounded section with padding.
struct Card<Content: View>: View {
    var padding: CGFloat = 12
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard()
    }
}

/// Icon-only round button used in headers.
struct RoundIconButton: View {
    let symbol: String
    let help: String
    var tint: Color = .primary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassCircle()
        .help(help)
        .accessibilityLabel(help)
    }
}

/// App icon from a bundle path, or an SF Symbol for system sources.
struct AppIcon: View {
    let iconPath: String?
    let symbol: String?
    var size: CGFloat = 28

    private static var cache: [String: NSImage] = [:]

    var body: some View {
        if let path = iconPath {
            Image(nsImage: Self.image(path)).resizable().frame(width: size, height: size)
        } else {
            Image(systemName: symbol ?? "app.dashed")
                .font(.system(size: size * 0.5, weight: .medium))
                .frame(width: size, height: size)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
        }
    }

    static func image(_ path: String) -> NSImage {
        if let i = cache[path] { return i }
        let i = NSWorkspace.shared.icon(forFile: path)
        i.size = NSSize(width: 64, height: 64)
        cache[path] = i
        return i
    }
}

/// Thin level meter. Outlined when the source is quiet but was recently active.
struct LevelMeter: View {
    let level: Float
    var outlined = false

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(outlined ? 0 : 0.08))
                if outlined { Capsule().strokeBorder(.secondary.opacity(0.4), lineWidth: 1) }
                Capsule()
                    .fill(color.gradient)
                    .frame(width: max(0, g.size.width * CGFloat(min(Self.scale(level), 1))))
                    .animation(.linear(duration: 0.08), value: level)
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }

    private var color: Color { level > 0.95 ? .red : level > 0.7 ? .orange : .green }

    /// dB scale so quiet sounds are visible: -60 dB … 0 dB.
    static func scale(_ v: Float) -> Float {
        guard v > 0.001 else { return 0 }
        return max(0, (20 * log10(v) + 60) / 60)
    }
}

/// Opens SwiftUI content in its own window (with a pin-on-top button). Reuses windows by id.
final class WindowManager {
    static let shared = WindowManager()
    private var windows: [String: NSWindow] = [:]

    func show<V: View>(id: String, title: String, size: CGSize, @ViewBuilder content: () -> V) {
        if let w = windows[id], w.isVisible {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let host = NSHostingController(rootView: content())
        let w = NSWindow(contentViewController: host)
        w.title = title
        w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        w.setContentSize(size)
        w.isReleasedWhenClosed = false
        let pin = NSTitlebarAccessoryViewController()
        let button = NSButton(image: NSImage(systemSymbolName: "pin", accessibilityDescription: "Pin")!, target: w,
                              action: #selector(NSWindow.toggleFloating(_:)))
        button.isBordered = false
        button.toolTip = "Keep this window on top"
        pin.view = button
        pin.layoutAttribute = .trailing
        w.addTitlebarAccessoryViewController(pin)
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        windows[id] = w
    }

    func isOpen(_ id: String) -> Bool { windows[id]?.isVisible == true }
    func close(_ id: String) { windows[id]?.close() }
}

/// Gives access to the NSWindow hosting a SwiftUI view.
struct WindowAccessor: NSViewRepresentable {
    let configure: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { if let w = v.window { configure(w) } }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async { if let w = v.window { configure(w) } }
    }
}

/// Section title used across the app.
struct SectionLabel: View {
    let title: String
    var symbol: String?
    var body: some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol).foregroundStyle(.secondary) }
            Text(title).font(.subheadline.weight(.semibold))
        }
        .lineLimit(1)
    }
}

/// Percentage label that never truncates.
struct PercentText: View {
    let value: Float
    var warnAbove: Float = 1
    var body: some View {
        Text(value.percent)
            .font(.system(.caption, design: .rounded).weight(.medium).monospacedDigit())
            .foregroundStyle(value > warnAbove ? .orange : .secondary)
            .lineLimit(1)
            .fixedSize()
            .frame(minWidth: 40, alignment: .trailing)
    }
}

extension Float {
    var percent: String { "\(Int((self * 100).rounded()))%" }
}
