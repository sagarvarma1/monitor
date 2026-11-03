// Draws the app icon into Resources/Assets.xcassets. Run from the repo root: swift scripts/make-icon.swift
import AppKit

let set = URL(fileURLWithPath: "Resources/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect { NSRect(x: x * s, y: y * s, width: w * s, height: h * s) }

    // Apple's icon grid: an 824pt rounded square inside the 1024pt canvas.
    let tile = NSBezierPath(roundedRect: rect(100, 100, 824, 824), xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(starting: color(0.20, 0.22, 0.30), ending: color(0.07, 0.08, 0.12))!.draw(in: tile, angle: -90)

    // The pill, with its three session dots.
    let pill = NSBezierPath(roundedRect: rect(190, 392, 644, 240), xRadius: 120 * s, yRadius: 120 * s)
    NSGradient(starting: color(1, 1, 1, 0.30), ending: color(1, 1, 1, 0.12))!.draw(in: pill, angle: -90)
    color(1, 1, 1, 0.35).setStroke()
    pill.lineWidth = 6 * s
    pill.stroke()
    let dots = [color(1.00, 0.27, 0.23), color(1.00, 0.80, 0.00), color(0.20, 0.84, 0.29)]
    for (i, dot) in dots.enumerated() {
        dot.setFill()
        NSBezierPath(ovalIn: rect(272 + CGFloat(i) * 180, 452, 120, 120)).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(size)x\(size)@\(scale)x.png"
        try render(size * scale).write(to: set.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: set.appendingPathComponent("Contents.json"))
try #"{"info":{"author":"xcode","version":1}}"#.write(to: set.deletingLastPathComponent().appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
