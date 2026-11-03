import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
func drawIcon(_ size: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let scale = CGFloat(size) / 1024
    NSGraphicsContext.current!.cgContext.scaleBy(x: scale, y: scale)
    let card = NSBezierPath(roundedRect: NSRect(x: 55, y: 55, width: 914, height: 914), xRadius: 205, yRadius: 205)
    NSGradient(starting: NSColor(red: 0.12, green: 0.65, blue: 0.59, alpha: 1), ending: NSColor(red: 0.04, green: 0.30, blue: 0.33, alpha: 1))!.draw(in: card, angle: -70)
    let back = NSBezierPath(roundedRect: NSRect(x: 220, y: 330, width: 570, height: 360), xRadius: 46, yRadius: 46)
    NSColor.white.withAlphaComponent(0.20).setFill(); back.fill()
    let tab = NSBezierPath(roundedRect: NSRect(x: 220, y: 620, width: 235, height: 135), xRadius: 40, yRadius: 40)
    NSColor.white.withAlphaComponent(0.20).setFill(); tab.fill()
    let front = NSBezierPath(roundedRect: NSRect(x: 220, y: 260, width: 585, height: 370), xRadius: 47, yRadius: 47)
    NSColor.white.withAlphaComponent(0.96).setFill(); front.fill()
    let cloud = NSBezierPath()
    cloud.move(to: NSPoint(x: 401, y: 376))
    cloud.curve(to: NSPoint(x: 394, y: 483), controlPoint1: NSPoint(x: 322, y: 376), controlPoint2: NSPoint(x: 322, y: 479))
    cloud.curve(to: NSPoint(x: 554, y: 509), controlPoint1: NSPoint(x: 395, y: 582), controlPoint2: NSPoint(x: 531, y: 595))
    cloud.curve(to: NSPoint(x: 616, y: 376), controlPoint1: NSPoint(x: 667, y: 548), controlPoint2: NSPoint(x: 700, y: 376))
    cloud.close()
    NSColor(red: 0.08, green: 0.48, blue: 0.46, alpha: 1).setFill(); cloud.fill()
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 504, y: 365)); arrow.line(to: NSPoint(x: 504, y: 466))
    arrow.move(to: NSPoint(x: 467, y: 430)); arrow.line(to: NSPoint(x: 504, y: 467)); arrow.line(to: NSPoint(x: 541, y: 430))
    arrow.lineWidth = 21; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
    NSColor.white.setStroke(); arrow.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}
for size in [16, 32, 128, 256, 512] {
    try drawIcon(size).write(to: directory.appendingPathComponent("icon_\(size)x\(size).png"))
    try drawIcon(size * 2).write(to: directory.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
