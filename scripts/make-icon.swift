import AppKit
import Foundation
let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
func icon(_ pixels: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    let outer = NSBezierPath(roundedRect: NSRect(x: 88, y: 88, width: 848, height: 848), xRadius: 194, yRadius: 194)
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.17); shadow.shadowBlurRadius = 34; shadow.shadowOffset = NSSize(width: 0, height: -12)
    NSGraphicsContext.saveGraphicsState(); shadow.set()
    NSColor(srgbRed: 0.075, green: 0.13, blue: 0.14, alpha: 1).setFill(); outer.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: NSColor(srgbRed: 0.16, green: 0.27, blue: 0.25, alpha: 1), ending: NSColor(srgbRed: 0.07, green: 0.13, blue: 0.14, alpha: 1))!.draw(in: outer, angle: -65)
    NSColor(srgbRed: 0.70, green: 0.88, blue: 0.77, alpha: 0.4).setStroke()
    let ring = NSBezierPath(ovalIn: NSRect(x: 237, y: 237, width: 550, height: 550)); ring.lineWidth = 18; ring.stroke()
    let ring2 = NSBezierPath(ovalIn: NSRect(x: 177, y: 177, width: 670, height: 670)); ring2.lineWidth = 2; ring2.stroke()
    NSColor(srgbRed: 0.70, green: 0.88, blue: 0.77, alpha: 1).setStroke()
    let trace = NSBezierPath(); trace.move(to: NSPoint(x: 198, y: 484)); trace.line(to: NSPoint(x: 366, y: 484)); trace.line(to: NSPoint(x: 430, y: 588)); trace.line(to: NSPoint(x: 520, y: 385)); trace.line(to: NSPoint(x: 590, y: 510)); trace.line(to: NSPoint(x: 681, y: 510)); trace.lineWidth = 31; trace.lineCapStyle = .round; trace.lineJoinStyle = .round; trace.stroke()
    NSColor(srgbRed: 0.68, green: 0.94, blue: 0.84, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 660, y: 489, width: 42, height: 42)).fill()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}
var images: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try icon(size * scale).write(to: output.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": name])
    }
}
let json: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("Contents.json"))
