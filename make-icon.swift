import AppKit
let target = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let factor = CGFloat(pixels) / 1024
        let transform = NSAffineTransform(); transform.scale(by: factor); transform.concat()
        let path = NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880), xRadius: 205, yRadius: 205)
        NSGradient(starting: NSColor(red: 0.03, green: 0.52, blue: 0.45, alpha: 1), ending: NSColor(red: 0.04, green: 0.25, blue: 0.27, alpha: 1))!.draw(in: path, angle: -60)
        NSColor.white.setStroke()
        let arrow = NSBezierPath(); arrow.lineWidth = 60; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
        arrow.move(to: NSPoint(x: 512, y: 738)); arrow.line(to: NSPoint(x: 512, y: 350))
        arrow.move(to: NSPoint(x: 341, y: 520)); arrow.line(to: NSPoint(x: 512, y: 348)); arrow.line(to: NSPoint(x: 684, y: 520)); arrow.stroke()
        let tray = NSBezierPath(); tray.lineWidth = 54; tray.lineCapStyle = .round; tray.lineJoinStyle = .round
        tray.move(to: NSPoint(x: 300, y: 337)); tray.line(to: NSPoint(x: 300, y: 257)); tray.line(to: NSPoint(x: 724, y: 257)); tray.line(to: NSPoint(x: 724, y: 337)); tray.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: target).appendingPathComponent(name))
    }
}
