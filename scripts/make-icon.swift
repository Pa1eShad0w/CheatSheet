import AppKit
import Foundation

// Generated artwork, not a copy of Media Atelier's icon.
guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: swift scripts/make-icon.swift <output.iconset>")
}
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func writeIcon(points: Int, scale: Int) throws {
    let pixels = points * scale
    guard
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap)
    else {
        fatalError("Cannot create icon graphics context")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let size = CGFloat(pixels)
    let inset = size * 0.08
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let shape = NSBezierPath(roundedRect: rect, xRadius: size * 0.18, yRadius: size * 0.18)
    let gradient = NSGradient(
        starting: NSColor(srgbRed: 0.22, green: 0.33, blue: 0.65, alpha: 1),
        ending: NSColor(srgbRed: 0.09, green: 0.14, blue: 0.30, alpha: 1)
    )!
    gradient.draw(in: shape, angle: -90)
    let symbol = "⌘" as NSString
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size * 0.58, weight: .regular),
        .foregroundColor: NSColor.white,
    ]
    let bounds = symbol.size(withAttributes: attributes)
    symbol.draw(
        at: NSPoint(x: (size - bounds.width) / 2, y: (size - bounds.height) / 2),
        withAttributes: attributes
    )
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Cannot encode icon")
    }
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try data.write(to: output.appendingPathComponent(name))
}

for points in [16, 32, 128, 256, 512] {
    try writeIcon(points: points, scale: 1)
    try writeIcon(points: points, scale: 2)
}
