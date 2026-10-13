// Renders Resources/AppIcon.icns. Run via scripts/build.sh (only when the icon is missing).
import AppKit

let out = CommandLine.arguments[1]
let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let body = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(colors: [NSColor(red: 0.93, green: 0.55, blue: 0.33, alpha: 1),
                        NSColor(red: 0.72, green: 0.33, blue: 0.20, alpha: 1)])!.draw(in: body, angle: -90)

    // Chat bubble
    let bw = rect.width * 0.62, bh = rect.height * 0.48
    let bubble = NSRect(x: rect.midX - bw / 2, y: rect.midY - bh / 2 + rect.height * 0.04, width: bw, height: bh)
    let path = NSBezierPath(roundedRect: bubble, xRadius: bh * 0.3, yRadius: bh * 0.3)
    let tail = NSBezierPath()
    tail.move(to: NSPoint(x: bubble.minX + bw * 0.18, y: bubble.minY + 1))
    tail.line(to: NSPoint(x: bubble.minX + bw * 0.12, y: bubble.minY - bh * 0.24))
    tail.line(to: NSPoint(x: bubble.minX + bw * 0.38, y: bubble.minY + 1))
    tail.close()
    NSColor.white.setFill()
    path.fill()
    tail.fill()

    // Check mark
    let check = NSBezierPath()
    check.move(to: NSPoint(x: bubble.minX + bw * 0.3, y: bubble.midY))
    check.line(to: NSPoint(x: bubble.minX + bw * 0.45, y: bubble.midY - bh * 0.2))
    check.line(to: NSPoint(x: bubble.minX + bw * 0.72, y: bubble.midY + bh * 0.22))
    check.lineWidth = s * 0.05
    check.lineCapStyle = .round
    check.lineJoinStyle = .round
    NSColor(red: 0.78, green: 0.38, blue: 0.22, alpha: 1).setStroke()
    check.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try! render(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try! render(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", out]
try! task.run()
task.waitUntilExit()
exit(task.terminationStatus)
