// Draws the iSound app icon and writes Resources/AppIcon.icns.
// Run: swift tools/make-icon.swift
import AppKit

func render(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = CGFloat(px) / 1024
    ctx.scaleBy(x: s, y: s)

    // Body: Apple icon grid, 824pt squircle centred on a 1024 canvas.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor.black.setFill(); shape.fill()
    ctx.restoreGState()

    ctx.saveGState()
    shape.addClip()
    NSGradient(colors: [NSColor(red: 0.20, green: 0.10, blue: 0.55, alpha: 1),
                        NSColor(red: 0.45, green: 0.18, blue: 0.85, alpha: 1),
                        NSColor(red: 0.95, green: 0.35, blue: 0.62, alpha: 1)],
               atLocations: [0, 0.55, 1], colorSpace: .deviceRGB)!.draw(in: body, angle: 60)
    // Soft top highlight for a glassy feel.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
        .draw(in: CGRect(x: 100, y: 512, width: 824, height: 412), angle: -90)

    // Three faders at different levels: a mixer.
    let xs: [CGFloat] = [322, 512, 702]
    let levels: [CGFloat] = [0.45, 0.80, 0.30]
    let bottom: CGFloat = 250, top: CGFloat = 774, w: CGFloat = 58, knob: CGFloat = 132
    for (x, level) in zip(xs, levels) {
        let track = CGRect(x: x - w / 2, y: bottom, width: w, height: top - bottom)
        NSColor.white.withAlphaComponent(0.20).setFill()
        NSBezierPath(roundedRect: track, xRadius: w / 2, yRadius: w / 2).fill()
        let ky = bottom + (top - bottom) * level
        let filled = CGRect(x: x - w / 2, y: bottom, width: w, height: ky - bottom)
        NSColor.white.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: filled, xRadius: w / 2, yRadius: w / 2).fill()
        let k = CGRect(x: x - knob / 2, y: ky - knob / 2, width: knob, height: knob)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 16, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        NSColor.white.setFill(); NSBezierPath(ovalIn: k).fill()
        ctx.restoreGState()
        NSColor(red: 0.45, green: 0.18, blue: 0.85, alpha: 1).setFill()
        NSBezierPath(ovalIn: k.insetBy(dx: 40, dy: 40)).fill()
    }
    ctx.restoreGState()

    // Thin inner edge.
    NSColor.white.withAlphaComponent(0.18).setStroke()
    let edge = NSBezierPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), xRadius: 185, yRadius: 185)
    edge.lineWidth = 3; edge.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let set = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
        try render(size * scale).representation(using: .png, properties: [:])!.write(to: set.appendingPathComponent(name))
    }
}
try render(1024).representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("Resources/AppIcon.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
