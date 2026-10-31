import SwiftUI
import AppKit

enum Palette {
    static let accent = adaptive(light: 0x16766C, dark: 0x79D6BF)
    static let green = adaptive(light: 0x25816A, dark: 0x83D3AF)
    static let orange = adaptive(light: 0xA76C29, dark: 0xE5B875)
    static let canvas = adaptive(light: 0xF5F6F3, dark: 0x181E20)
    static let sidebar = Color(red: 0.075, green: 0.13, blue: 0.14)
    static let card = adaptive(light: 0xFFFFFF, dark: 0x20282A)
    static let ink = adaptive(light: 0x263C3C, dark: 0xE6EDE8)
    static let secondary = adaptive(light: 0x73817C, dark: 0x9EAEA7)
    static let line = adaptive(light: 0xE4E9E3, dark: 0x34413E)
    static let mint = Color(red: 0.70, green: 0.88, blue: 0.77)
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                           green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: 1)
        })
    }
}

enum Motion {
    static let quick = Animation.easeOut(duration: 0.16)
    static let gentle = Animation.spring(response: 0.34, dampingFraction: 0.88)
}

struct BrandMark: View {
    var size: CGFloat = 35
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.30).fill(Palette.mint)
            Circle().stroke(Palette.sidebar.opacity(0.3), lineWidth: 1).padding(size * 0.18)
            Image(systemName: "waveform.path")
                .font(.system(size: size * 0.48, weight: .semibold)).foregroundStyle(Palette.sidebar)
        }.frame(width: size, height: size)
    }
}

struct AppIcon: View {
    let image: NSImage?
    var size: CGFloat = 30
    var fallback: String = "terminal"
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit) }
            else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.25).fill(Palette.secondary.opacity(0.08))
                    Image(systemName: fallback).font(.system(size: size * 0.45, weight: .medium)).foregroundStyle(Palette.secondary)
                }
            }
        }.frame(width: size, height: size)
    }
}

struct StatusBadge: View {
    let text: String
    var color: Color = Palette.green
    var dot = true
    var body: some View {
        HStack(spacing: 5) {
            if dot { Circle().fill(color).frame(width: 4, height: 4) }
            Text(text).font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(color).padding(.horizontal, 8).padding(.vertical, 5)
        .background(color.opacity(0.08), in: Capsule())
        .fixedSize()
    }
}

extension ProcessState {
    var color: Color {
        switch self {
        case .running: Palette.green
        case .stopped: Palette.orange
        case .zombie, .uninterruptible: .red
        default: Palette.secondary
        }
    }
}

/// Only real samples are drawn. The first reading is a point, not invented history.
struct Sparkline: View {
    let values: [Double]
    var color: Color = Palette.accent
    var body: some View {
        Canvas { context, size in
            guard !values.isEmpty else { return }
            let low = values.min() ?? 0
            let high = values.max() ?? 1
            let span = max(high - low, max(high * 0.08, 1))
            let points = values.enumerated().map { index, value in
                CGPoint(x: values.count == 1 ? size.width : CGFloat(index) / CGFloat(values.count - 1) * size.width,
                        y: size.height - 4 - CGFloat((value - low) / span) * (size.height - 8))
            }
            var line = Path()
            line.addLines(points)
            if points.count > 1 {
                var area = line
                area.addLine(to: CGPoint(x: size.width, y: size.height))
                area.addLine(to: CGPoint(x: 0, y: size.height))
                area.closeSubpath()
                context.fill(area, with: .linearGradient(Gradient(colors: [color.opacity(0.16), color.opacity(0.01)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                context.stroke(line, with: .color(color.opacity(0.75)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
            if let last = points.last {
                context.fill(Path(ellipseIn: CGRect(x: last.x - 2, y: last.y - 2, width: 4, height: 4)), with: .color(color))
            }
        }.accessibilityHidden(true)
    }
}

struct StatCard: View {
    let label: String
    let value: String
    let symbol: String
    let caption: String
    var color: Color = Palette.accent
    var history: [Double] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(color)
                Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.secondary)
                Spacer(minLength: 0)
            }
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text(value).font(.system(size: 29, weight: .medium, design: .rounded)).tracking(-0.8)
                    .monospacedDigit().foregroundStyle(Palette.ink)
                    .contentTransition(.numericText()).animation(reduceMotion ? nil : Motion.gentle, value: value)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                Sparkline(values: history, color: color).frame(width: 54, height: 28)
            }
            Text(caption).font(.system(size: 10)).foregroundStyle(Palette.secondary).lineLimit(1)
        }
        .padding(17).frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.line.opacity(0.8), lineWidth: 1))
    }
}

struct SmallSectionTitle: View {
    let title: String
    var trailing: String? = nil
    var body: some View {
        HStack {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.ink)
            Spacer()
            if let trailing { Text(trailing).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.secondary) }
        }
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().stroke(Palette.line, lineWidth: 1).frame(width: 94, height: 94)
                Circle().fill(Palette.accent.opacity(0.05)).frame(width: 72, height: 72)
                Image(systemName: symbol).font(.system(size: 27, weight: .light)).foregroundStyle(Palette.accent.opacity(0.7))
            }.padding(.bottom, 3)
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.ink)
            Text(message).font(.system(size: 11)).foregroundStyle(Palette.secondary).multilineTextAlignment(.center).lineSpacing(5).frame(maxWidth: 250)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
    }
}

struct PillButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Button(action: action) { Text(title).font(.system(size: 11, weight: isSelected ? .semibold : .regular)).padding(.horizontal, 12).padding(.vertical, 8) }
            .buttonStyle(QuietButtonStyle())
            .foregroundStyle(isSelected ? Palette.accent : Palette.secondary)
            .background(isSelected ? Palette.accent.opacity(0.09) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .animation(reduceMotion ? nil : Motion.quick, value: isSelected)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct QuietButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.65 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : Motion.quick, value: configuration.isPressed)
    }
}

struct RowSurface: ViewModifier {
    let selected: Bool
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .background(selected ? Palette.accent.opacity(0.085) : hovered ? Palette.secondary.opacity(0.045) : Color.clear)
            .overlay(alignment: .leading) {
                Capsule().fill(Palette.accent).frame(width: 3, height: 24).opacity(selected ? 1 : 0)
            }
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : Motion.quick, value: hovered)
            .animation(reduceMotion ? nil : Motion.quick, value: selected)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct IconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).frame(width: 30, height: 30)
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .background(hovered ? Palette.secondary.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(QuietButtonStyle()).foregroundStyle(Palette.secondary)
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : Motion.quick, value: hovered)
            .help(label).accessibilityLabel(label)
    }
}
