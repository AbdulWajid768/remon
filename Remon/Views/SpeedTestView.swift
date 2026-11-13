import Charts
import SwiftUI

/// Speed and responsiveness test using Apple's `networkQuality`. Laid out like every other
/// section: a page bar with the action, headline tiles, then cards.
struct SpeedTestView: View {
    @Environment(MonitorStore.self) private var store
    @State private var width: CGFloat = 1_000

    var body: some View {
        let latest = store.speedTestResults.first
        let running = store.speedTestRunning
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeading(running ? "Testing…" : (latest == nil ? "No Test Yet" : "Latest Result"), subtitle: subtitle(latest, running: running))
                SpeedTiles(latest: latest, running: running, columns: width >= 820 ? 4 : 2)
                QualityCard(latest: latest, running: running)
                if !store.speedTestResults.isEmpty {
                    SectionHeading("Previous Tests", subtitle: "How this connection has measured over time.")
                }
                if store.speedTestResults.count > 1 {
                    Card("Recent Tests", symbol: "chart.bar.xaxis",
                         accessory: AnyView(ChartLegend(items: [("Download", Theme.download), ("Upload", Theme.upload)])),
                         summary: AnyView(CardSummary(["\(store.speedTestResults.count) tests",
                                                       "best ↓ \(SpeedFormat.text(store.speedTestResults.map(\.download).max() ?? 0))",
                                                       "best ↑ \(SpeedFormat.text(store.speedTestResults.map(\.upload).max() ?? 0))"]))) {
                        SpeedHistoryChart(results: store.speedTestResults)
                            .frame(height: 190)
                    }
                }
                if !store.speedTestResults.isEmpty {
                    // The chart above is the quick read; the full table is there when needed.
                    Card("Past Results", symbol: "clock.arrow.circlepath",
                         summary: AnyView(CardSummary(store.speedTestResults.prefix(3).map {
                             "\($0.date.formatted(.dateTime.day().month(.abbreviated))) ↓ \(SpeedFormat.text($0.download)) ↑ \(SpeedFormat.text($0.upload))" })),
                         collapsed: true) {
                        PastResultsTable(results: Array(store.speedTestResults.prefix(10)))
                    }
                }
            }
            .padding(16)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .safeAreaInset(edge: .top, spacing: 0) { SpeedTestBar() }
    }

    private func subtitle(_ latest: SpeedTestResult?, running: Bool) -> String {
        if running { return "Download and upload update live from this Mac's interfaces; responsiveness arrives when the test ends." }
        guard let latest else { return "Run a test to measure download, upload and responsiveness against Apple's servers." }
        let interface = latest.interface.map { " via \($0)" } ?? ""
        return "Measured \(latest.date.formatted(.relative(presentation: .named)))\(interface)."
    }
}

/// Page bar: the one action this section has, progress while it runs, and when it last ran.
private struct SpeedTestBar: View {
    @Environment(MonitorStore.self) private var store
    /// networkQuality is run with `-M 25`, so a test takes at most this long.
    static let maxDuration: Double = 25

    var body: some View {
        let running = store.speedTestRunning
        let latest = store.speedTestResults.first
        PageBar {
            Button {
                store.runSpeedTest()
            } label: {
                Label(running ? "Testing…" : (latest == nil ? "Run Test" : "Test Again"),
                      systemImage: running ? "hourglass" : "play.fill")
                    .frame(minWidth: 96)
            }
            .buttonStyle(.mint)
            .disabled(running)
            .keyboardShortcut("r", modifiers: [.command])
            .help("Run Apple's networkQuality test (⌘R)")

            if running, let started = store.speedTestStarted {
                TimelineView(.periodic(from: started, by: 0.5)) { context in
                    let elapsed = max(0, context.date.timeIntervalSince(started))
                    HStack(spacing: 10) {
                        ProgressView(value: min(elapsed, Self.maxDuration), total: Self.maxDuration)
                            .progressViewStyle(.linear)
                            .frame(width: 140)
                        Text("\(Int(elapsed)) s of up to \(Int(Self.maxDuration))").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            } else if let error = store.speedTestError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).lineLimit(1).truncationMode(.tail)
            }
        } trailing: {
            if let latest, !running {
                Text("Last tested \(latest.date.formatted(.relative(presentation: .named)))").foregroundStyle(.secondary)
            }
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .help("Uses Apple's built-in networkQuality test, the same one behind System Settings. It measures download and upload capacity and responsiveness under load against Apple's servers, and can transfer a few hundred megabytes.")
                .accessibilityLabel("About this test")
        }
    }
}

/// The four headline numbers, in the same tiles the Overview and System sections use.
private struct SpeedTiles: View {
    @Environment(MonitorStore.self) private var store
    var latest: SpeedTestResult?
    var running: Bool
    var columns: Int

    var body: some View {
        // While testing, show what the interfaces are actually moving (the kernel counters the rest of
        // the app uses); networkQuality itself only reports when it finishes.
        let download = running ? store.currentIn * 8 : latest?.download
        let upload = running ? store.currentOut * 8 : latest?.upload
        let previous = store.speedTestResults.dropFirst().first
        let rpm = running ? nil : latest?.responsivenessRPM
        let rtt = running ? nil : latest?.baseRTTms
        let downloadNote = running ? ("Live", Theme.download) : change(latest?.download, previous?.download)
        let uploadNote = running ? ("Live", Theme.upload) : change(latest?.upload, previous?.upload)
        let rpmNote: (String, Color)? = running ? ("Measuring…", .secondary)
            : latest.flatMap { r in r.responsivenessRPM.map { _ in ("\(r.responsivenessRating) responsiveness", SpeedFormat.responsivenessColor(r.responsivenessRating)) } }
        let rttNote: (String, Color)? = running ? ("Measuring…", .secondary) : rtt.map(SpeedFormat.latencyRating)

        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columns), spacing: 12) {
            StatTile(title: "Download", value: download.map(SpeedFormat.text) ?? "—", detail: downloadNote?.0,
                     symbol: "arrow.down.circle.fill", tint: Theme.download, detailTint: downloadNote?.1)
            StatTile(title: "Upload", value: upload.map(SpeedFormat.text) ?? "—", detail: uploadNote?.0,
                     symbol: "arrow.up.circle.fill", tint: Theme.upload, detailTint: uploadNote?.1)
            StatTile(title: "Responsiveness", value: rpm.map { "\(Int($0)) RPM" } ?? "—", detail: rpmNote?.0,
                     symbol: "bolt.horizontal.circle.fill", tint: .purple, detailTint: rpmNote?.1)
                .help("Round trips per minute while the connection is busy. Higher is better; low values mean calls and games lag when something else is downloading.")
            StatTile(title: "Idle Latency", value: rtt.map { String(format: "%.0f ms", $0) } ?? "—", detail: rttNote?.0,
                     symbol: "timer.circle.fill", tint: .teal, detailTint: rttNote?.1)
                .help("Round-trip time to Apple's test servers on an otherwise idle connection.")
        }
        .animation(.smooth, value: download)
    }

    /// "+4.3 Mbps vs last" — how this result compares with the test before it.
    private func change(_ now: Double?, _ before: Double?) -> (String, Color)? {
        guard let now, let before else { return nil }
        let delta = now - before
        guard abs(delta) >= 0.05e6 else { return ("Same as last test", .secondary) }
        return ("\(delta > 0 ? "+" : "−")\(SpeedFormat.text(abs(delta))) vs last test", delta > 0 ? .green : .orange)
    }
}

/// The gauge, and what the result means in practice.
private struct QualityCard: View {
    @Environment(MonitorStore.self) private var store
    var latest: SpeedTestResult?
    var running: Bool

    var body: some View {
        let download = running ? store.currentIn * 8 : latest?.download
        let upload = running ? store.currentOut * 8 : latest?.upload
        Card("Connection Quality", symbol: "gauge.with.needle", collapsible: false) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 24) {
                    gauge(download: download, upload: upload)
                    explanation.frame(maxWidth: .infinity, alignment: .leading)
                }
                VStack(spacing: 16) {
                    gauge(download: download, upload: upload)
                    explanation
                }
            }
        }
    }

    private func gauge(download: Double?, upload: Double?) -> some View {
        SpeedGauge(download: download, upload: upload, running: running)
            .frame(width: 250, height: 220)
    }

    @ViewBuilder private var explanation: some View {
        if running {
            VStack(alignment: .leading, spacing: 8) {
                Text("Measuring…").font(.headline)
                Text("The gauge follows this Mac's live download rate while networkQuality loads the connection. Download, upload and responsiveness are reported together when it finishes.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } else if let latest {
            VStack(alignment: .leading, spacing: 14) {
                SuitabilityRow(result: latest)
                Text(verdict(latest)).font(.callout).foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Nothing measured yet").font(.headline)
                Text("Click Run Test to measure download and upload capacity and how responsive the connection stays under load. The result shows what the connection is good for.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    /// One plain sentence about the result.
    private func verdict(_ r: SpeedTestResult) -> String {
        let down = r.download / 1e6
        let speed = down >= 100 ? "Fast" : (down >= 25 ? "Solid" : "Modest")
        let responsiveness: String = switch r.responsivenessRating {
        case "High": "stays responsive when busy"
        case "Medium": "slows a little when busy"
        case "Low": "gets sluggish when busy, so calls and games may lag during downloads"
        default: "responsiveness was not measured"
        }
        return "\(speed) connection that \(responsiveness)."
    }
}

/// "Good for" checks derived from the latest result. Thresholds are in each chip's tooltip.
private struct SuitabilityRow: View {
    var result: SpeedTestResult

    private var checks: [(name: String, symbol: String, ok: Bool, rule: String)] {
        let down = result.download / 1e6, up = result.upload / 1e6
        let rpm = result.responsivenessRPM, rtt = result.baseRTTms
        return [
            ("HD video", "play.rectangle", down >= 5, "5 Mbps download"),
            ("4K video", "4k.tv", down >= 25, "25 Mbps download"),
            ("Video calls", "video", down >= 3 && up >= 3 && (rpm ?? 0) >= 200,
             "3 Mbps each way and medium or high responsiveness (200+ RPM)"),
            ("Gaming", "gamecontroller", (rtt ?? .infinity) < 60 && (rpm ?? 0) >= 400,
             "idle latency under 60 ms and 400+ RPM"),
            ("Large uploads", "icloud.and.arrow.up", up >= 20, "20 Mbps upload"),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Good for").font(.subheadline.weight(.semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach(checks, id: \.name) { check in
                    HStack(spacing: 6) {
                        Image(systemName: check.ok ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundStyle(check.ok ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
                        Label(check.name, systemImage: check.symbol)
                            .labelStyle(.titleOnly)
                            .foregroundStyle(check.ok ? .primary : .secondary)
                    }
                    .font(.callout)
                    .help("\(check.ok ? "Meets" : "Needs") \(check.rule)")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(check.name)
                    .accessibilityValue(check.ok ? "Suitable" : "Not suitable; needs \(check.rule)")
                }
            }
        }
    }
}

/// Formatting shared by the speed-test views. Speeds are bits per second, shown in Mbps / Gbps.
enum SpeedFormat {
    static func value(_ bitsPerSecond: Double) -> (number: String, unit: String) {
        let mbps = bitsPerSecond / 1e6
        if mbps >= 1000 { return (String(format: "%.2f", mbps / 1000), "Gbps") }
        // Live readings between bursts can be tiny; "0.0 Mbps" reads as broken.
        if mbps < 1 { return (String(format: "%.0f", bitsPerSecond / 1e3), "Kbps") }
        return (mbps >= 100 ? String(format: "%.0f", mbps) : String(format: "%.1f", mbps), "Mbps")
    }

    static func text(_ bitsPerSecond: Double) -> String {
        let v = value(bitsPerSecond)
        return "\(v.number) \(v.unit)"
    }

    static func latencyRating(_ ms: Double) -> (String, Color) {
        switch ms {
        case ..<30: ("Excellent", .green)
        case ..<60: ("Good", .green)
        case ..<120: ("Fair", .yellow)
        default: ("Poor", .orange)
        }
    }

    static func responsivenessColor(_ rating: String) -> Color {
        switch rating {
        case "High": .green
        case "Medium": .yellow
        case "Low": .orange
        default: .secondary
        }
    }
}

// MARK: - Gauge

/// Twin-ring gauge on a log scale (1 Mbps … 10 Gbps): the outer ring is download, the thinner inner
/// ring upload. A 240° sweep leaves a gap at the bottom for the scale's ends.
struct SpeedGauge: View {
    var download: Double?
    var upload: Double?
    var running: Bool

    private let startAngle = 150.0, sweep = 240.0
    private let outerWidth: CGFloat = 13, innerWidth: CGFloat = 7

    var body: some View {
        let down = normalized(download), up = normalized(upload)
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2 + size * 0.03)
            let outer = size / 2 - outerWidth
            let inner = outer - outerWidth - 8
            let unitCenter = UnitPoint(x: center.x / max(geo.size.width, 1), y: center.y / max(geo.size.height, 1))
            ZStack {
                // Tracks.
                ArcShape(start: startAngle, sweep: sweep, fraction: 1, center: center, radius: outer)
                    .stroke(.primary.opacity(0.07), style: StrokeStyle(lineWidth: outerWidth, lineCap: .round))
                ArcShape(start: startAngle, sweep: sweep, fraction: 1, center: center, radius: inner)
                    .stroke(.primary.opacity(0.07), style: StrokeStyle(lineWidth: innerWidth, lineCap: .round))
                // Decade marks just outside the outer ring.
                ForEach(0..<5, id: \.self) { i in
                    Circle().fill(.tertiary)
                        .frame(width: 3, height: 3)
                        .position(point(center: center, radius: outer + outerWidth, fraction: Double(i) / 4))
                }
                // Download (outer) and upload (inner).
                ArcShape(start: startAngle, sweep: sweep, fraction: down, center: center, radius: outer)
                    .stroke(AngularGradient(colors: [Theme.download.opacity(0.4), Theme.download], center: unitCenter,
                                            startAngle: .degrees(startAngle), endAngle: .degrees(startAngle + sweep)),
                            style: StrokeStyle(lineWidth: outerWidth, lineCap: .round))
                    .shadow(color: Theme.download.opacity(down > 0 ? 0.5 : 0), radius: 8)
                ArcShape(start: startAngle, sweep: sweep, fraction: up, center: center, radius: inner)
                    .stroke(AngularGradient(colors: [Theme.upload.opacity(0.4), Theme.upload], center: unitCenter,
                                            startAngle: .degrees(startAngle), endAngle: .degrees(startAngle + sweep)),
                            style: StrokeStyle(lineWidth: innerWidth, lineCap: .round))
                    .shadow(color: Theme.upload.opacity(up > 0 ? 0.45 : 0), radius: 6)
                Circle()
                    .fill(.white)
                    .frame(width: outerWidth - 5, height: outerWidth - 5)
                    .shadow(color: Theme.download.opacity(0.8), radius: 3)
                    .position(point(center: center, radius: outer, fraction: down))
                    .opacity(down > 0 ? 1 : 0)
                // Scale ends, in the gap under the rings.
                Text("1 Mbps").position(point(center: center, radius: outer + 2, fraction: 0).applying(.init(translationX: 4, y: 16)))
                Text("10 Gbps").position(point(center: center, radius: outer + 2, fraction: 1).applying(.init(translationX: -4, y: 16)))
                readout.position(center)
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .animation(.spring(duration: 0.9, bounce: 0.15), value: down)
            .animation(.spring(duration: 0.9, bounce: 0.15), value: up)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(running ? "Live speed" : "Measured speed")
        .accessibilityValue("Download \(download.map(SpeedFormat.text) ?? "no result"), upload \(upload.map(SpeedFormat.text) ?? "no result")")
    }

    private var readout: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                if running {
                    Circle().fill(.red).frame(width: 6, height: 6)
                    Text("LIVE")
                } else {
                    Image(systemName: "arrow.down")
                    Text("DOWNLOAD")
                }
            }
            .font(.caption2.weight(.semibold))
            .tracking(1.2)
            .foregroundStyle(.secondary)
            .padding(.bottom, 2)

            if let download {
                let v = SpeedFormat.value(download)
                Text(v.number)
                    .font(.system(size: 46, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(v.unit).font(.callout.weight(.medium)).foregroundStyle(.secondary)
            } else {
                Text("—")
                    .font(.system(size: 46, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tertiary)
                Text("Ready").font(.callout.weight(.medium)).foregroundStyle(.secondary)
            }
            if let upload {
                Label(SpeedFormat.text(upload), systemImage: "arrow.up")
                    .font(.callout.weight(.medium).monospacedDigit())
                    .foregroundStyle(Theme.upload)
                    .contentTransition(.numericText())
                    .padding(.top, 8)
            }
        }
        .frame(width: 150)
        .animation(.smooth, value: download)
    }

    private func point(center: CGPoint, radius: CGFloat, fraction: Double) -> CGPoint {
        let angle = Angle.degrees(startAngle + sweep * fraction).radians
        return CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
    }

    private func normalized(_ bps: Double?) -> Double {
        guard let bps, bps > 0 else { return 0 }
        return min(max(log10(bps / 1e6) / 4, 0.015), 1) // 1 Mbps → 0, 10 Gbps → 1
    }

    private struct ArcShape: Shape {
        var start: Double
        var sweep: Double
        var fraction: Double
        var center: CGPoint
        var radius: CGFloat

        var animatableData: Double {
            get { fraction }
            set { fraction = newValue }
        }

        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.addArc(center: center, radius: radius, startAngle: .degrees(start),
                     endAngle: .degrees(start + sweep * max(fraction, 0.0001)), clockwise: false)
            return p
        }
    }
}

// MARK: - History

/// One pair of bars per test, oldest to newest. Tests are discrete events, often days apart, so a
/// time axis just drew long straight lines between them.
private struct SpeedHistoryChart: View {
    var results: [SpeedTestResult]
    @State private var hovered: String?

    var body: some View {
        let recent = Array(results.prefix(12).reversed())
        Chart {
            ForEach(recent) { r in
                BarMark(x: .value("Test", r.id.uuidString), y: .value("Mbps", r.download / 1e6), width: .ratio(0.7))
                    .foregroundStyle(Theme.download.gradient)
                    .position(by: .value("Direction", "Download"))
                    .cornerRadius(3)
                BarMark(x: .value("Test", r.id.uuidString), y: .value("Mbps", r.upload / 1e6), width: .ratio(0.7))
                    .foregroundStyle(Theme.upload.gradient)
                    .position(by: .value("Direction", "Upload"))
                    .cornerRadius(3)
            }
            if let hovered, let r = recent.first(where: { $0.id.uuidString == hovered }) {
                RuleMark(x: .value("Test", hovered))
                    .foregroundStyle(.gray.opacity(0.12))
                    .lineStyle(StrokeStyle(lineWidth: 44))
                    .annotation(position: .top, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(r.date.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                            Label(SpeedFormat.text(r.download), systemImage: "arrow.down").foregroundStyle(Theme.download)
                            Label(SpeedFormat.text(r.upload), systemImage: "arrow.up").foregroundStyle(Theme.upload)
                            if let rpm = r.responsivenessRPM {
                                Text("\(Int(rpm)) RPM · \(r.responsivenessRating)").foregroundStyle(.secondary)
                            }
                        }
                        .font(.caption.monospacedDigit())
                        .padding(8)
                        .background(.regularMaterial, in: .rect(cornerRadius: 8))
                    }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                AxisValueLabel { if let v = value.as(Double.self) { Text("\(v.formatted()) Mbps").font(.caption2) } }
            }
        }
        .chartXAxis {
            AxisMarks { value in
                AxisValueLabel(centered: true) {
                    if let id = value.as(String.self), let r = recent.first(where: { $0.id.uuidString == id }) {
                        VStack(spacing: 0) {
                            Text(day(r.date))
                            Text(r.date.formatted(date: .omitted, time: .shortened)).foregroundStyle(.tertiary)
                        }
                        .font(.caption2)
                    }
                }
            }
        }
        .chartXSelection(value: $hovered)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recent speed tests")
        .accessibilityValue("\(recent.count) tests. Latest: download \(SpeedFormat.text(results[0].download)), upload \(SpeedFormat.text(results[0].upload)).")
    }

    private func day(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

private struct PastResultsTable: View {
    var results: [SpeedTestResult]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
            GridRow {
                Text("Date")
                Text("Download").gridColumnAlignment(.trailing)
                Text("Upload").gridColumnAlignment(.trailing)
                Text("Responsiveness").gridColumnAlignment(.trailing)
                Text("Latency").gridColumnAlignment(.trailing)
                Text("Interface")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.bottom, 6)
            Divider()
            ForEach(Array(results.enumerated()), id: \.element.id) { index, r in
                GridRow {
                    Text(date(r.date)).foregroundStyle(.primary)
                    Text(SpeedFormat.text(r.download)).foregroundStyle(Theme.download)
                    Text(SpeedFormat.text(r.upload)).foregroundStyle(Theme.upload)
                    HStack(spacing: 6) {
                        Text(r.responsivenessRPM.map { "\(Int($0)) RPM" } ?? "—").foregroundStyle(.secondary)
                        if r.responsivenessRPM != nil {
                            Circle().fill(SpeedFormat.responsivenessColor(r.responsivenessRating)).frame(width: 7, height: 7)
                                .help("\(r.responsivenessRating) responsiveness")
                        }
                    }
                    Text(r.baseRTTms.map { String(format: "%.0f ms", $0) } ?? "—").foregroundStyle(.secondary)
                    Text(r.interface ?? "—").foregroundStyle(.secondary)
                }
                .font(.callout.monospacedDigit())
                .padding(.vertical, 7)
                if index < results.count - 1 { Divider().opacity(0.5) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func date(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "Today, \(time)" }
        if calendar.isDateInYesterday(date) { return "Yesterday, \(time)" }
        return date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }
}
