#!/usr/bin/env swift
// Renders the SuperBar app icon (macOS squircle, blue gradient, white menu glyph)
// into an .appiconset directory. Usage: swift scripts/make-icon.swift <dir>
import AppKit

let outDir = CommandLine.arguments.dropFirst().first ?? "App/SuperBar/Resources/Assets.xcassets/AppIcon.appiconset"
let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

func squircle(in rect: NSRect) -> NSBezierPath {
    // macOS icon shape: rounded rect with ~22.4% radius and continuous corners.
    let radius = rect.width * 0.2237
    return NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func render(size: Int) -> NSBitmapImageRep {
    let s = CGFloat(size)
    // Draw into a bitmap with exact pixel dimensions (lockFocus would use the
    // screen's 2x scale and produce oversized PNGs).
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: s, height: s)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    // Apple's icon grid: the shape fills ~80% of the canvas.
    let inset = s * 0.1
    let shape = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = squircle(in: shape)

    // Shadow
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = s * 0.025
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.set()
    NSColor.black.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Gradient background
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.36, green: 0.62, blue: 1.0, alpha: 1),
        NSColor(srgbRed: 0.05, green: 0.36, blue: 0.95, alpha: 1),
    ])!
    gradient.draw(in: path, angle: -90)

    // Subtle inner highlight
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    let highlight = NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
    highlight.draw(in: NSRect(x: shape.minX, y: shape.midY, width: shape.width, height: shape.height / 2), angle: 90)
    NSGraphicsContext.restoreGraphicsState()

    // Glyph: a menu "window" with a title bar and three list lines + a bolt.
    let g = shape.insetBy(dx: shape.width * 0.2, dy: shape.height * 0.22)
    let lineWidth = max(1, s * 0.045)
    let window = NSBezierPath(roundedRect: g, xRadius: g.width * 0.12, yRadius: g.width * 0.12)
    window.lineWidth = lineWidth
    NSColor.white.setStroke()
    window.stroke()
    // Title bar line
    let barY = g.maxY - g.height * 0.24
    let bar = NSBezierPath()
    bar.move(to: NSPoint(x: g.minX, y: barY))
    bar.line(to: NSPoint(x: g.maxX, y: barY))
    bar.lineWidth = lineWidth
    bar.stroke()
    // List lines
    NSColor.white.setFill()
    let rows = 3
    let rowGap = (barY - g.minY) / CGFloat(rows + 1)
    for i in 1...rows {
        let y = barY - rowGap * CGFloat(i)
        let w = g.width * (i == 2 ? 0.42 : 0.56)
        let r = NSRect(x: g.minX + g.width * 0.16, y: y - lineWidth * 0.55, width: w, height: lineWidth * 1.1)
        NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
    }
    // Bolt (quick selection) in the lower-right corner
    let bolt = NSBezierPath()
    let bx = g.maxX - g.width * 0.02, by = g.minY + g.height * 0.02
    let bw = g.width * 0.28, bh = g.height * 0.34
    bolt.move(to: NSPoint(x: bx - bw * 0.35, y: by + bh))
    bolt.line(to: NSPoint(x: bx - bw, y: by + bh * 0.42))
    bolt.line(to: NSPoint(x: bx - bw * 0.52, y: by + bh * 0.42))
    bolt.line(to: NSPoint(x: bx - bw * 0.65, y: by))
    bolt.line(to: NSPoint(x: bx, y: by + bh * 0.6))
    bolt.line(to: NSPoint(x: bx - bw * 0.45, y: by + bh * 0.6))
    bolt.close()
    // Punch a blue outline so the bolt reads over the window lines.
    NSColor(srgbRed: 0.08, green: 0.4, blue: 0.96, alpha: 1).setStroke()
    bolt.lineWidth = lineWidth * 1.6
    bolt.lineJoinStyle = .round
    bolt.stroke()
    NSColor.white.setFill()
    bolt.fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let fm = FileManager.default
try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)
for (name, size) in sizes {
    let rep = render(size: size)
    guard let png = rep.representation(using: .png, properties: [:]) else { continue }
    let url = URL(fileURLWithPath: outDir).appendingPathComponent(name + ".png")
    try png.write(to: url)
}
print("icon written to \(outDir)")
