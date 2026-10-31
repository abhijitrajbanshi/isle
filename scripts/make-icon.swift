// Renders Isle's app icon: a dark squircle with a glowing island pill.
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icon grid: 824/1024 body with ~185 radius
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let squircle = NSBezierPath(roundedRect: body, xRadius: s * 0.18, yRadius: s * 0.18)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = s * 0.025
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.set()
    NSGradient(colors: [NSColor(white: 0.20, alpha: 1), NSColor(white: 0.05, alpha: 1)])!
        .draw(in: squircle, angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()

    // the island
    let pillW = body.width * 0.62, pillH = body.width * 0.2
    let pill = CGRect(x: body.midX - pillW / 2, y: body.midY - pillH / 2 + body.height * 0.04, width: pillW, height: pillH)
    let glow = NSShadow()
    glow.shadowColor = NSColor(calibratedRed: 0.45, green: 0.6, blue: 1, alpha: 0.55)
    glow.shadowBlurRadius = s * 0.06
    NSGraphicsContext.current?.saveGraphicsState()
    glow.set()
    NSColor.black.setFill()
    NSBezierPath(roundedRect: pill, xRadius: pillH / 2, yRadius: pillH / 2).fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    NSColor(white: 1, alpha: 0.12).setStroke()
    let rim = NSBezierPath(roundedRect: pill.insetBy(dx: 0.5, dy: 0.5), xRadius: pillH / 2, yRadius: pillH / 2)
    rim.lineWidth = max(1, s * 0.003)
    rim.stroke()

    // waveform on the right, art on the left
    let colors: [NSColor] = [.systemPink, .systemOrange, .systemYellow, .systemGreen]
    let barW = pillH * 0.11
    for i in 0..<4 {
        let h = pillH * [0.32, 0.56, 0.42, 0.26][i]
        let x = pill.maxX - pillH * 0.62 - CGFloat(3 - i) * barW * 1.9
        colors[i].setFill()
        NSBezierPath(roundedRect: CGRect(x: x, y: pill.midY - h / 2, width: barW, height: h),
                     xRadius: barW / 2, yRadius: barW / 2).fill()
    }
    let art = CGRect(x: pill.minX + pillH * 0.22, y: pill.minY + pillH * 0.22, width: pillH * 0.56, height: pillH * 0.56)
    NSGradient(colors: [.systemPurple, .systemBlue])!
        .draw(in: NSBezierPath(roundedRect: art, xRadius: art.width * 0.26, yRadius: art.width * 0.26), angle: -45)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
