import AppKit
import Charts
import UniformTypeIdentifiers
import SwiftUI

/// Download/upload colors, switchable in Settings › General › Theme. Reading these from a view
/// body registers an observation on the preference, so views recolor live.
@MainActor
enum Theme {
    static func colors(for theme: ColorTheme) -> (download: Color, upload: Color) {
        switch theme {
        case .classic: (.blue, .orange)
        case .ocean: (.teal, .indigo)
        case .sunset: (.pink, .yellow)
        case .forest: (.green, .mint)
        case .graphite: (.primary, .gray)
        }
    }

    static var download: Color { colors(for: Preferences.shared.colorTheme).download }
    static var upload: Color { colors(for: Preferences.shared.colorTheme).upload }
    static var downloadGradient: LinearGradient {
        LinearGradient(colors: [download.opacity(0.45), download.opacity(0.03)], startPoint: .top, endPoint: .bottom)
    }
    static var uploadGradient: LinearGradient {
        LinearGradient(colors: [upload.opacity(0.03), upload.opacity(0.45)], startPoint: .top, endPoint: .bottom)
    }
}

// MARK: - Icons

/// Caches app icons by identity (NSWorkspace icon lookups hit the disk).
@MainActor
final class IconCache {
    static let shared = IconCache()
    private var cache: [String: NSImage] = [:]

    func icon(for identity: AppIdentity) -> NSImage {
        if let image = cache[identity.id] { return image }
        let image: NSImage
        if let path = identity.bundlePath {
            image = NSWorkspace.shared.icon(forFile: path)
        } else if identity.executablePath != nil || identity.id.hasPrefix("/") {
            image = NSWorkspace.shared.icon(for: .unixExecutable)
        } else {
            image = NSImage(systemSymbolName: "gearshape.2", accessibilityDescription: nil) ?? NSImage()
        }
        // Workspace icons carry 1024-px representations; downscaling them on every redraw
        // dominated CPU time, so cache a small bitmap once.
        let thumbnail = Self.thumbnail(image, points: 32)
        cache[identity.id] = thumbnail
        return thumbnail
    }

    private static func thumbnail(_ image: NSImage, points: CGFloat) -> NSImage {
        let pixels = Int(points * 2)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return image }
        rep.size = NSSize(width: points, height: points)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: points, height: points))
        NSGraphicsContext.restoreGraphicsState()
        let result = NSImage(size: rep.size)
        result.addRepresentation(rep)
        return result
    }

    func icon(forAppID id: String, name: String) -> NSImage {
        icon(for: AppIdentity(id: id, name: name, bundlePath: id.hasSuffix(".app") ? id : nil,
                              executablePath: id.hasPrefix("/") ? id : nil, isSystem: false))
    }
}

struct AppIcon: View {
    var identity: AppIdentity
    var size: CGFloat = 18

    var body: some View {
        Image(nsImage: IconCache.shared.icon(for: identity))
            .resizable()
            .interpolation(.medium)
            .frame(width: size, height: size)
    }
}

struct AppLabel: View {
    var identity: AppIdentity
    var size: CGFloat = 18
    var showsSystemBadge = true

    var body: some View {
        HStack(spacing: 8) {
            AppIcon(identity: identity, size: size)
            Text(identity.name).lineLimit(1)
            if showsSystemBadge && identity.isSystem {
                Text("System")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.quaternary, in: .capsule)
            }
        }
    }
}

// MARK: - Sparkline

/// Lightweight path-based sparkline for table rows (Swift Charts is too heavy per row).
struct Sparkline: View {
    var values: [Double]
    var color: Color = .accentColor

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            let maxValue = max(values.max() ?? 0, 1)
            let step = size.width / CGFloat(max(values.count - 1, 1))
            var line = Path()
            for (i, v) in values.enumerated() {
                let point = CGPoint(x: CGFloat(i) * step, y: size.height - CGFloat(v / maxValue) * (size.height - 1))
                i == 0 ? line.move(to: point) : line.addLine(to: point)
            }
            var fill = line
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()
            context.fill(fill, with: .linearGradient(Gradient(colors: [color.opacity(0.35), color.opacity(0.02)]),
                                                     startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            context.stroke(line, with: .color(color), lineWidth: 1.2)
        }
    }
}

// MARK: - Throughput chart

/// Mirrored live chart: download above the axis, upload below. Hover shows a callout.
struct ThroughputChart: View {
    var points: [ThroughputPoint]
    var window: TimeInterval = 300
    var showsAxes = true
    var interactive = true
    /// Animating the sliding window re-renders every mark at display rate for part of each
    /// second, which is costly for long series; only small, transient charts opt in.
    var animated = false
    @Environment(Preferences.self) private var preferences
    @State private var hovered: Date?

    var body: some View {
        let now = points.last?.date ?? Date()
        let peak = max(points.map { max($0.rateIn, $0.rateOut) }.max() ?? 0, 2_000)
        Chart {
            ForEach(points) { p in
                AreaMark(x: .value("Time", p.date), yStart: .value("Zero", 0), yEnd: .value("Download", p.rateIn), series: .value("Dir", "Download"))
                    .foregroundStyle(Theme.downloadGradient)
                    .interpolationMethod(.catmullRom)
                LineMark(x: .value("Time", p.date), y: .value("Download", p.rateIn), series: .value("Dir", "Download"))
                    .foregroundStyle(Theme.download)
                    .lineStyle(StrokeStyle(lineWidth: 1.6))
                    .interpolationMethod(.catmullRom)
                AreaMark(x: .value("Time", p.date), yStart: .value("Zero", 0), yEnd: .value("Upload", -p.rateOut), series: .value("Dir", "Upload"))
                    .foregroundStyle(Theme.uploadGradient)
                    .interpolationMethod(.catmullRom)
                LineMark(x: .value("Time", p.date), y: .value("Upload", -p.rateOut), series: .value("Dir", "Upload"))
                    .foregroundStyle(Theme.upload)
                    .lineStyle(StrokeStyle(lineWidth: 1.6))
                    .interpolationMethod(.catmullRom)
            }
            RuleMark(y: .value("Zero", 0)).foregroundStyle(.separator).lineStyle(StrokeStyle(lineWidth: 0.5))
            if let hovered, let p = nearest(to: hovered) {
                RuleMark(x: .value("Selected", p.date))
                    .foregroundStyle(.secondary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        callout(p)
                    }
            }
        }
        .chartXScale(domain: now.addingTimeInterval(-window)...now)
        .chartYScale(domain: -peak * 1.1...peak * 1.1)
        .chartXAxis(showsAxes ? .automatic : .hidden)
        .chartYAxis {
            if showsAxes {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(preferences.compactRate(abs(v))).font(.caption2).monospacedDigit()
                        }
                    }
                }
            }
        }
        .chartLegend(.hidden)
        .chartXSelection(value: interactive ? $hovered : .constant(nil))
        .animation(animated ? .easeOut(duration: 0.45) : nil, value: points.last?.date)
    }

    private func nearest(to date: Date) -> ThroughputPoint? {
        points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }

    private func callout(_ p: ThroughputPoint) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(p.date.shortTime).font(.caption2).foregroundStyle(.secondary)
            Label(preferences.rate(p.rateIn), systemImage: "arrow.down").foregroundStyle(Theme.download)
            Label(preferences.rate(p.rateOut), systemImage: "arrow.up").foregroundStyle(Theme.upload)
        }
        .font(.caption.monospacedDigit())
        .padding(8)
        .background(.regularMaterial, in: .rect(cornerRadius: 8))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }
}

// MARK: - Cards & tiles

struct Card<Content: View>: View {
    var title: String?
    var symbol: String?
    var accessory: AnyView?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, symbol: String? = nil, accessory: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.accessory = accessory
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                HStack {
                    Label(title, systemImage: symbol ?? "circle")
                        .labelStyle(.titleAndIcon)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                    accessory
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
        }
    }
}

struct StatTile: View {
    var title: String
    var value: String
    var detail: String?
    var symbol: String
    var tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.14), in: .rect(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).foregroundStyle(.secondary)
                Text(value)
                    .font(.title2.weight(.semibold).monospacedDigit())
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
        }
    }
}

struct RateText: View {
    var rate: Double
    var direction: Direction
    var font: Font = .body
    @Environment(Preferences.self) private var preferences

    enum Direction { case down, up }

    var body: some View {
        Text(rate < 1 ? "—" : preferences.rate(rate))
            .font(font.monospacedDigit())
            .foregroundStyle(rate < 1 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(direction == .down ? Theme.download : Theme.upload))
    }
}

struct CategoryBadge: View {
    var category: DestinationCategory

    var body: some View {
        Label(category.rawValue, systemImage: category.symbol)
            .font(.caption2.weight(.medium))
            .foregroundStyle(category.tint)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(category.tint.opacity(0.12), in: .capsule)
    }
}

struct StatusDot: View {
    var color: Color
    var pulsing = false
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .shadow(color: color.opacity(0.6), radius: pulsing ? 3 : 0)
            .symbolEffectsRemoved()
    }
}

/// Row used in key/value inspector lists.
struct DetailRow: View {
    var label: String
    var value: String
    var monospaced = false
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize()
            Spacer(minLength: 0)
            Text(value)
                .font(monospaced ? .callout.monospaced() : .callout)
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
                .lineLimit(3)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity)
    }
}

struct SignatureBadge: View {
    var info: SigningInfo?
    var compact = false

    var body: some View {
        if let info {
            let tint: Color = info.status.isConcerning ? .orange : (info.status == .invalid ? .red : .secondary)
            Label(compact ? "" : info.status.rawValue, systemImage: info.status.symbol)
                .labelStyle(compact ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
                .font(.caption)
                .foregroundStyle(tint)
                .help(helpText(info))
        } else {
            Text("…").font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func helpText(_ info: SigningInfo) -> String {
        var text = "Code signature: \(info.status.rawValue)"
        if let team = info.teamID { text += " · Team \(team)" }
        return text
    }
}

struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView
    init<S: LabelStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

/// Circular progress ring used for the data plan.
struct UsageRing: View {
    var fraction: Double
    var tint: Color
    var lineWidth: CGFloat = 7

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0.001), 1))
                .stroke(tint.gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}
