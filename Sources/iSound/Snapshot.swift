import AppKit
import SwiftUI

/// Debug helper: `iSound --snapshot <folder>` renders the main screens to PNG files
/// (used to check layout without clicking through the UI).
enum Snapshot {
    static let folder: URL? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1], isDirectory: true)
    }()
    static var isActive: Bool { folder != nil }

    private static var windows: [NSWindow] = []

    static func run(_ d: AppDelegate) {
        guard let folder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let shots: [(String, CGSize?, AnyView)] = [
            ("mixer", nil, AnyView(MixerView().environment(d))),
            ("mixer-expanded", nil, AnyView(MixerView(expandFirst: true).environment(d))),
            ("devices", CGSize(width: 760, height: 560), AnyView(DevicesView().environment(d))),
            ("settings", CGSize(width: 520, height: 460), AnyView(SettingsView().environment(d))),
            ("eq10", CGSize(width: 560, height: 300), AnyView(EQ10Editor(eq: { var e = EQ10(); e.gains = EQ10.presets[5].1; return e }(), onChange: { _ in }).padding().environment(d))),
            ("parametric", CGSize(width: 560, height: 420), AnyView(ParametricEditor(eq: ParametricEQ(name: "Apple AirPods Pro", preampDB: -6, filters: [
                FilterSpec(type: .lowShelf, freq: 105, gainDB: 2.6, q: 0.7), FilterSpec(type: .peak, freq: 514, gainDB: -4.4, q: 0.68)]), onChange: { _ in }).padding().environment(d))),
            ("balance", CGSize(width: 460, height: 200), AnyView(BalancePanEditor(value: BalancePan(mode: .balance, value: -0.3), onChange: { _ in }).padding().environment(d))),
            ("browser", CGSize(width: 440, height: 480), AnyView(EffectBrowser(target: .source("snapshot")).environment(d))),
        ]
        for dark in [true, false] {
            for (name, size, view) in shots {
                let host = NSHostingView(rootView: view)
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let fit = size ?? host.fittingSize
                let w = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: fit.width, height: max(fit.height, 50)),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
                w.appearance = host.appearance
                w.backgroundColor = dark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.95, alpha: 1)
                w.contentView = host
                w.orderFrontRegardless()
                windows.append(w)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    let s = size ?? host.fittingSize
                    w.setContentSize(s)
                    host.layoutSubtreeIfNeeded()
                    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
                    host.cacheDisplay(in: host.bounds, to: rep)
                    let url = folder.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
                    try? rep.representation(using: .png, properties: [:])?.write(to: url)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { NSApp.terminate(nil) }
    }
}
