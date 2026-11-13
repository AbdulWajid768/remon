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

/// Remon's button accent: mint emerald, in place of the system blue. The dark teal label reaches
/// 6.8:1 against the fill, where white would reach only 2.1:1. Not `@MainActor` (unlike `Theme`),
/// so button styles can read it outside a view body.
enum Accent {
    /// #00C9A7
    static let base = Color(red: 0, green: 0.788, blue: 0.655)
    /// #00B894
    static let hover = Color(red: 0, green: 0.722, blue: 0.580)
    /// #009F80
    static let pressed = Color(red: 0, green: 0.624, blue: 0.502)
    /// #042F2E
    static let label = Color(red: 0.016, green: 0.184, blue: 0.180)
}

/// Filled button in the mint accent, with its hover and pressed shades. Used for the one primary
/// action of a section or sheet; secondary actions stay the system's bordered grey, and
/// destructive ones stay red.
struct MintButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { MintButton(configuration: configuration) }

    // A view of its own, not just a modified label: it needs @State for the hover shade. Not named
    // `Body`, which would collide with the protocol's associated type.
    private struct MintButton: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
            configuration.label
                .font(.body.weight(.medium))
                .foregroundStyle(Accent.label.opacity(isEnabled ? 1 : 0.45))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(fill, in: shape)
                .shadow(color: Accent.base.opacity(isEnabled && !configuration.isPressed ? 0.3 : 0), radius: 6, y: 2)
                .contentShape(shape)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }

        private var fill: Color {
            guard isEnabled else { return Accent.base.opacity(0.3) }
            if configuration.isPressed { return Accent.pressed }
            return hovering ? Accent.hover : Accent.base
        }
    }
}

extension ButtonStyle where Self == MintButtonStyle {
    /// A section's or sheet's primary action.
    static var mint: MintButtonStyle { MintButtonStyle() }
}

/// Secondary action: a mint-tinted chip with the ordinary label colour. Mint is a mid-tone, so it
/// works as a fill but not as text — #00C9A7 on either a white or a dark grey panel lands near
/// 2:1, well under the 4.5:1 text needs. The tint stays in the chip, the label stays readable.
struct MintSoftButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { SoftButton(configuration: configuration) }

    private struct SoftButton: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
            configuration.label
                .font(.body.weight(.medium))
                .foregroundStyle(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Accent.base.opacity(fillOpacity), in: shape)
                .overlay { shape.strokeBorder(Accent.base.opacity(isEnabled ? 0.45 : 0.2), lineWidth: 1) }
                .contentShape(shape)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }

        private var fillOpacity: Double {
            guard isEnabled else { return 0.06 }
            if configuration.isPressed { return 0.38 }
            return hovering ? 0.28 : 0.16
        }
    }
}

extension ButtonStyle where Self == MintSoftButtonStyle {
    /// A secondary action beside the primary one.
    static var mintSoft: MintSoftButtonStyle { MintSoftButtonStyle() }
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
        .chartXAxis {
            if showsAxes {
                if window <= 180 {
                    // Short windows (the 2-minute inspector chart): whole minutes only, away from the
                    // edges. The default 30-s ticks print seconds and truncate ("6:16:54 p…"), and a
                    // tick at the very edge gets its label clipped.
                    AxisMarks(values: minuteTicks(start: now.addingTimeInterval(-window), end: now)) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                        AxisValueLabel(format: .dateTime.hour().minute())
                    }
                } else {
                    AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                        AxisValueLabel(format: .dateTime.hour().minute())
                    }
                }
            }
        }
        .chartYAxis {
            if showsAxes {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            // These are rates, so label them as rates ("50 KB/s", not "50 KB").
                            Text(preferences.compactRate(abs(v)) + (preferences.useBits ? "ps" : "/s")).font(.caption2).monospacedDigit()
                        }
                    }
                }
            }
        }
        .chartLegend(.hidden)
        .chartXSelection(value: interactive ? $hovered : .constant(nil))
        .animation(animated ? .easeOut(duration: 0.45) : nil, value: points.last?.date)
        // Read as one summary instead of one element per sample ("10:55:19 pm to 10:55:24 pm"…).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Network throughput, last \(Int(window / 60) > 0 ? "\(Int(window / 60)) minutes" : "\(Int(window)) seconds")")
        .accessibilityValue(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        guard let last = points.last else { return "No data yet" }
        let peakIn = points.map(\.rateIn).max() ?? 0, peakOut = points.map(\.rateOut).max() ?? 0
        return "Now: download \(preferences.rate(last.rateIn)), upload \(preferences.rate(last.rateOut)). "
            + "Peak: download \(preferences.rate(peakIn)), upload \(preferences.rate(peakOut))."
    }

    private func minuteTicks(start: Date, end: Date) -> [Date] {
        guard let first = Calendar.current.nextDate(after: start.addingTimeInterval(15), matching: DateComponents(second: 0),
                                                    matchingPolicy: .nextTime) else { return [] }
        return stride(from: first.timeIntervalSinceReferenceDate, through: end.timeIntervalSinceReferenceDate - 25, by: 60)
            .map(Date.init(timeIntervalSinceReferenceDate:))
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

// MARK: - Glass surfaces

/// The translucent window body. Whatever is behind the window (the desktop, other windows) shows
/// through, blurred, like Finder's sidebar. Every section sits on this; cards and tiles are
/// frosted panels on top of it.
struct WindowGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        // HUD lets most of the desktop through while staying readable; `underWindowBackground`
        // is nearly opaque and reads as plain grey.
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Frosted panel used by every card and tile: a material fill the window glass shows through,
/// lifted off the background by a soft shadow. No edge line: the material and the shadow define it.
struct CardSurface: ViewModifier {
    var cornerRadius: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.thinMaterial)
                    .shadow(color: .black.opacity(0.14), radius: 14, y: 5)
            }
    }
}

extension View {
    func cardSurface(cornerRadius: CGFloat = 16) -> some View { modifier(CardSurface(cornerRadius: cornerRadius)) }

    /// Controls that float over content (map overlays): Liquid Glass on macOS 26, a material before.
    @ViewBuilder
    func glassPanel<S: Shape>(in shape: S) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }
}

/// Row pinned under the toolbar on sections with page-level controls: filters and actions on
/// the left, status on the right. No background of its own, so the page reads as one surface.
struct PageBar<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            leading
            Spacer(minLength: 12)
            trailing
        }
        .font(.callout)
        .padding(.horizontal, 16).padding(.top, 2).padding(.bottom, 8)
        .frame(maxWidth: .infinity)
    }
}

/// Heading above a group of cards, so a page reads top to bottom: what this block is, in a few words.
struct SectionHeading: View {
    var title: String
    var subtitle: String?

    init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.headline)
            if let subtitle {
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 4)
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// One line of the essentials, shown in a card's place while it is folded ("CPU 8% · GPU 34%").
struct CardSummary: View {
    var items: [String]

    init(_ items: [String]) { self.items = items }

    var body: some View {
        Text(items.filter { !$0.isEmpty }.joined(separator: "  ·  "))
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

// MARK: - Cards & tiles

/// Titled, collapsible panel. The chevron in the top-right corner folds the detail away; while
/// folded the card keeps showing its `summary` (the one line that matters). The state is
/// remembered per card (by `key`, or the title), so rarely-used sections can start folded.
struct Card<Content: View>: View {
    var title: String?
    var symbol: String?
    var accessory: AnyView?
    var summary: AnyView?
    var collapsible: Bool
    @AppStorage private var collapsed: Bool
    @ViewBuilder var content: Content

    init(_ title: String? = nil, symbol: String? = nil, accessory: AnyView? = nil, summary: AnyView? = nil,
         key: String? = nil, collapsible: Bool = true, collapsed: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.accessory = accessory
        self.summary = summary
        self.collapsible = collapsible && title != nil
        let storageKey = (key ?? title ?? "untitled").lowercased().filter { $0.isLetter || $0.isNumber }
        _collapsed = AppStorage(wrappedValue: collapsed, "card.\(storageKey).collapsed")
        self.content = content()
    }

    private var isFolded: Bool { collapsible && collapsed }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                HStack(spacing: 8) {
                    Label(title, systemImage: symbol ?? "circle")
                        .labelStyle(.titleAndIcon)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                    if !isFolded { accessory }
                    if collapsible { foldButton(title) }
                }
            }
            if isFolded {
                summary
            } else {
                content
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private func foldButton(_ title: String) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.25)) { collapsed.toggle() }
        } label: {
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(collapsed ? -90 : 0))
                .frame(width: 22, height: 22)
                .background(.primary.opacity(0.06), in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(collapsed ? "Show \(title)" : "Hide \(title)")
        .accessibilityLabel(collapsed ? "Show \(title)" : "Hide \(title)")
    }
}

struct StatTile: View {
    var title: String
    var value: String
    var detail: String?
    var symbol: String
    var tint: Color
    /// Colour for the detail line, when it carries a rating ("Excellent", "+4 Mbps vs last").
    var detailTint: Color?

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
                // Always reserve the detail line so tiles in a row line up at the same height.
                Text(detail ?? " ")
                    .font(.caption)
                    .foregroundStyle(detailTint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.tertiary))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 14)
        // One VoiceOver element per tile ("Download, 974 B/s, Peak 7 KB/s"); numeric-transition
        // text on its own exposes an empty value.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue([value, detail].compactMap { $0 }.joined(separator: ", "))
    }
}

/// Series key shown in a card's title row, so every chart's legend sits in the same place.
struct ChartLegend: View {
    var items: [(String, Color)]
    var note: String?

    var body: some View {
        HStack(spacing: 10) {
            ForEach(items, id: \.0) { item in
                HStack(spacing: 4) {
                    Circle().fill(item.1).frame(width: 7, height: 7)
                    Text(item.0).foregroundStyle(.secondary)
                }
            }
            if let note { Text(note).foregroundStyle(.secondary) }
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
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

/// A compact on/off switch that assistive technologies can operate. A label-hidden `.switch`
/// toggle inside a grouped Form exposes no AXPress action and no settable value on macOS 26, so
/// VoiceOver / Switch Control (and UI tests) couldn't flip it — add the action explicitly.
struct AccessibleSwitch: View {
    var label: String
    @Binding var isOn: Bool
    var small = true

    var body: some View {
        Toggle(label, isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(small ? .small : .regular)
            .accessibilityLabel(label)
            .accessibilityValue(isOn ? "On" : "Off")
            .accessibilityAddTraits(.isToggle)
            .accessibilityAction(.default) { isOn.toggle() }
    }
}
