import AppKit

/// Artwork coordinates match Tools/dmg-settings.py. Both TIFF representations
/// carry the same logical size so Finder renders crisp text on Retina displays.
@main
struct GenerateDMGArtwork {
    static let size = NSSize(width: 680, height: 460)
    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            throw NSError(domain: "ProcScopeArtwork", code: 1, userInfo: [NSLocalizedDescriptionKey: "Usage: GenerateArtwork <output> <version>"])
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let reps = [1, 2].map { draw(scale: $0, version: CommandLine.arguments[2]) }
        let image = NSImage(size: size)
        reps.forEach { image.addRepresentation($0) }
        try image.tiffRepresentation!.write(to: directory.appendingPathComponent("background.tiff"))
        try reps[1].representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("background@2x.png"))
    }

    static func draw(scale: Int, version: String) -> NSBitmapImageRep {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale,
            pixelsHigh: Int(size.height) * scale, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let cg = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
        cg.translateBy(x: 0, y: size.height)
        cg.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        let ink = color(0x263C3C), muted = color(0x73817C), mint = color(0xB3E0C4)
        color(0xF5F6F3).setFill()
        NSRect(origin: .zero, size: size).fill()
        color(0x142322).setFill()
        NSRect(x: 0, y: 0, width: 680, height: 136).fill()
        cg.saveGState()
        cg.clip(to: CGRect(x: 0, y: 0, width: 680, height: 136))
        for radius in [58.0, 90.0, 122.0, 154.0] {
            mint.withAlphaComponent(0.09).setStroke()
            let ring = NSBezierPath(ovalIn: NSRect(x: 596 - radius, y: 70 - radius, width: radius * 2, height: radius * 2))
            ring.lineWidth = 0.7; ring.stroke()
        }
        cg.restoreGState()
        mint.setFill()
        NSBezierPath(roundedRect: NSRect(x: 38, y: 31, width: 44, height: 44), xRadius: 13, yRadius: 13).fill()
        cg.setStrokeColor(ink.cgColor); cg.setLineWidth(1.8); cg.setLineCap(.round); cg.setLineJoin(.round)
        cg.move(to: CGPoint(x: 45, y: 53)); cg.addLines(between: [CGPoint(x: 51, y: 53), CGPoint(x: 55, y: 44), CGPoint(x: 61, y: 63), CGPoint(x: 66, y: 50), CGPoint(x: 73, y: 50)]); cg.strokePath()
        label("ProcScope", rect: NSRect(x: 98, y: 33, width: 350, height: 34), size: 27, color: .white, weight: .semibold)
        label("看清每一个运行中的任务。", rect: NSRect(x: 40, y: 98, width: 450, height: 20), size: 12, color: mint.withAlphaComponent(0.75))
        color(0x203B35).setFill()
        NSBezierPath(roundedRect: NSRect(x: 554, y: 41, width: 86, height: 26), xRadius: 13, yRadius: 13).fill()
        label("v\(version)", rect: NSRect(x: 554, y: 47, width: 86, height: 18), size: 10, color: mint, centered: true)
        label("拖入应用程序，开始观察。", rect: NSRect(x: 40, y: 156, width: 600, height: 24), size: 16, color: ink, weight: .medium, centered: true)
        for x in [184.0, 496.0] {
            let circle = NSBezierPath(ovalIn: NSRect(x: x - 68, y: 180, width: 136, height: 136))
            NSColor.white.setFill(); circle.fill()
            color(0xDDE7DE).setStroke(); circle.lineWidth = 1; circle.stroke()
        }
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: 308, y: 248)); arrow.line(to: NSPoint(x: 372, y: 248))
        arrow.move(to: NSPoint(x: 362, y: 238)); arrow.line(to: NSPoint(x: 372, y: 248)); arrow.line(to: NSPoint(x: 362, y: 258))
        color(0x468779).setStroke(); arrow.lineWidth = 2; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round; arrow.stroke()
        label("Drag to install", rect: NSRect(x: 288, y: 271, width: 104, height: 20), size: 10, color: muted, centered: true)
        label("01  拖动图标", rect: NSRect(x: 110, y: 348, width: 148, height: 20), size: 10, color: muted, centered: true)
        label("02  放入应用程序", rect: NSRect(x: 422, y: 348, width: 148, height: 20), size: 10, color: muted, centered: true)
        color(0xDFE6DE).setFill(); NSRect(x: 40, y: 386, width: 600, height: 1).fill()
        label("安装后，从「应用程序」打开 ProcScope。", rect: NSRect(x: 40, y: 403, width: 600, height: 21), size: 11, color: muted, centered: true)
        label("macOS 14+    /    Apple Silicon & Intel    /    本机运行", rect: NSRect(x: 40, y: 435, width: 600, height: 18), size: 9, color: muted, centered: true)
        return bitmap
    }
    static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, alpha: 1)
    }
    static func label(_ text: String, rect: NSRect, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular, centered: Bool = false) {
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = centered ? .center : .left
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: paragraph]).draw(in: rect)
    }
}
