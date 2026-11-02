import Charts
import SwiftUI

/// Speed and responsiveness test using Apple's `networkQuality`.
struct SpeedTestView: View {
    @Environment(MonitorStore.self) private var store

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                SpeedTestHero()
                if store.speedTestResults.count > 1 {
                    Card("Recent Tests", symbol: "chart.bar.xaxis",
                         accessory: AnyView(ChartLegend(items: [("Download", Theme.download), ("Upload", Theme.upload)]))) {
                        SpeedHistoryChart(results: store.speedTestResults)
                            .frame(height: 190)
                    }
                }
                if !store.speedTestResults.isEmpty {
                    Card("Past Results", symbol: "clock.arrow.circlepath") {
                        PastResultsTable(results: Array(store.speedTestResults.prefix(10)))
                    }
                }
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
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

// MARK: - Hero

private struct SpeedTestHero: View {
    @Environment(MonitorStore.self) private var store
    /// networkQuality is run with `-M 25`, so a test takes at most this long.
    private let maxDuration: Double = 25

    var body: some View {
        let latest = store.speedTestResults.first
        let running = store.speedTestRunning
        // While testing, show what the interfaces are actually moving (the kernel counters the rest of
        // the app uses); networkQuality itself only reports when it finishes.
        let download = running ? store.currentIn * 8 : latest?.download
        let upload = running ? store.currentOut * 8 : latest?.upload

        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 36) {
                gauge(download: download, upload: upload, running: running)
                details(latest: latest, download: download, upload: upload, running: running)
                    .frame(minWidth: 400)
            }
            VStack(spacing: 24) {
                gauge(download: download, upload: upload, running: running)
                details(latest: latest, download: download, upload: upload, running: running)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
        }
    }

    private func gauge(download: Double?, upload: Double?, running: Bool) -> some View {
        SpeedGauge(download: download, upload: upload, running: running)
            .frame(width: 300, height: 270)
            .background {
                // A soft wash of the download colour behind the gauge, wherever the layout puts it.
                RadialGradient(colors: [Theme.download.opacity(0.16), .clear], center: .center, startRadius: 0, endRadius: 260)
                    .frame(width: 520, height: 520)
                    .allowsHitTesting(false)
            }
    }

    private func details(latest: SpeedTestResult?, download: Double?, upload: Double?, running: Bool) -> some View {
        let previous = store.speedTestResults.dropFirst().first
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Network Quality").font(.title2.weight(.semibold))
                    statusLine(latest: latest, running: running)
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .help("Uses Apple's built-in networkQuality test, the same one behind System Settings. It measures download and upload capacity and responsiveness under load against Apple's servers, and can transfer a few hundred megabytes.")
                    .accessibilityLabel("About this test")
            }

            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    MetricCell(title: "Download", symbol: "arrow.down", tint: Theme.download,
                               value: download.map(SpeedFormat.value),
                               note: running ? ("Live", Theme.download) : change(latest?.download, previous?.download))
                    MetricCell(title: "Upload", symbol: "arrow.up", tint: Theme.upload,
                               value: upload.map(SpeedFormat.value),
                               note: running ? ("Live", Theme.upload) : change(latest?.upload, previous?.upload))
                }
                GridRow {
                    MetricCell(title: "Responsiveness", symbol: "bolt.horizontal", tint: .purple,
                               value: running ? nil : latest?.responsivenessRPM.map { ("\(Int($0))", "RPM") },
                               note: running ? ("Measuring…", .secondary)
                                   : latest.flatMap { r in r.responsivenessRPM.map { _ in
                                       (r.responsivenessRating, SpeedFormat.responsivenessColor(r.responsivenessRating)) } })
                        .help("Round trips per minute while the connection is busy. Higher is better; low values mean calls and games lag when something else is downloading.")
                    MetricCell(title: "Idle Latency", symbol: "timer", tint: .teal,
                               value: running ? nil : latest?.baseRTTms.map { (String(format: "%.0f", $0), "ms") },
                               note: running ? ("Measuring…", .secondary) : latest?.baseRTTms.map(SpeedFormat.latencyRating))
                        .help("Round-trip time to Apple's test servers on an otherwise idle connection.")
                }
            }

            if let latest, !running {
                SuitabilityRow(result: latest)
            }

            HStack(spacing: 14) {
                Button {
                    store.runSpeedTest()
                } label: {
                    Label(running ? "Testing…" : (latest == nil ? "Run Test" : "Test Again"),
                          systemImage: running ? "hourglass" : "play.fill")
                        .frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(running)
                .keyboardShortcut("r", modifiers: [.command])

                if running, let started = store.speedTestStarted {
                    TimelineView(.periodic(from: started, by: 0.5)) { context in
                        let elapsed = max(0, context.date.timeIntervalSince(started))
                        HStack(spacing: 10) {
                            ProgressView(value: min(elapsed, maxDuration), total: maxDuration)
                                .progressViewStyle(.linear)
                                .frame(width: 140)
                            Text("\(Int(elapsed)) s").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
                if let error = store.speedTestError, !running {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.callout).lineLimit(2)
                }
            }
        }
    }

    /// "+4.3 Mbps vs last" — how this result compares with the test before it.
    private func change(_ now: Double?, _ before: Double?) -> (String, Color)? {
        guard let now, let before else { return nil }
        let delta = now - before
        guard abs(delta) >= 0.05e6 else { return ("Same as last", .secondary) }
        return ("\(delta > 0 ? "+" : "−")\(SpeedFormat.text(abs(delta))) vs last", delta > 0 ? .green : .orange)
    }

    @ViewBuilder
    private func statusLine(latest: SpeedTestResult?, running: Bool) -> some View {
        if running {
            Text("Testing download, upload and responsiveness — up to \(Int(maxDuration)) seconds")
        } else if let latest {
            let interface = latest.interface.map { " · via \($0)" } ?? ""
            Text("Last tested \(latest.date.formatted(.relative(presentation: .named)))\(interface)")
        } else {
            Text("Measure your connection with Apple's networkQuality test.")
        }
    }
}

/// One measurement in the hero: label, big number with its unit, and an optional rating.
private struct MetricCell: View {
    var title: String
    var symbol: String
    var tint: Color
    var value: (number: String, unit: String)?
    var note: (String, Color)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value?.number ?? "—")
                    .font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let unit = value?.unit {
                    Text(unit).font(.callout).foregroundStyle(.secondary)
                }
            }
            // Reserve the line so every cell has the same height.
            Group {
                if let note {
                    Text(note.0)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(note.1)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(note.1.opacity(0.14), in: .capsule)
                } else {
                    Text(" ").font(.caption2)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.07), in: .rect(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint.opacity(0.15), lineWidth: 0.5) }
        .animation(.smooth, value: value?.number)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue([value.map { "\($0.number) \($0.unit)" } ?? "No result", note?.0].compactMap { $0 }.joined(separator: ", "))
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
            Text("Good for").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
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

// MARK: - Gauge

/// 270° gauge on a log scale (1 Mbps … 10 Gbps) with decade ticks. Shows download in the centre and
/// upload underneath.
struct SpeedGauge: View {
    var download: Double?
    var upload: Double?
    var running: Bool

    private let startAngle = 135.0, sweep = 270.0, lineWidth: CGFloat = 16

    var body: some View {
        let fraction = normalized(download)
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height / 0.9)
            let radius = size / 2 - lineWidth
            let center = CGPoint(x: geo.size.width / 2, y: size / 2)
            ZStack {
                ticks(center: center, radius: radius)
                ArcShape(start: startAngle, sweep: sweep, fraction: 1, center: center, radius: radius)
                    .stroke(.quaternary, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                ArcShape(start: startAngle, sweep: sweep, fraction: fraction, center: center, radius: radius)
                    .stroke(AngularGradient(colors: [Theme.download.opacity(0.35), Theme.download, Theme.download],
                                            center: .init(x: center.x / max(geo.size.width, 1), y: center.y / max(geo.size.height, 1)),
                                            startAngle: .degrees(startAngle), endAngle: .degrees(startAngle + sweep)),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .shadow(color: Theme.download.opacity(fraction > 0 ? 0.45 : 0), radius: 8)
                // Knob at the end of the arc.
                Circle()
                    .fill(.white)
                    .frame(width: lineWidth - 4, height: lineWidth - 4)
                    .shadow(color: Theme.download.opacity(0.8), radius: 4)
                    .position(point(center: center, radius: radius, fraction: fraction))
                    .opacity(fraction > 0 ? 1 : 0)
                readout
                    .position(x: center.x, y: center.y + 6)
            }
            .animation(.spring(duration: 0.9, bounce: 0.2), value: fraction)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(running ? "Live download speed" : "Download speed")
        .accessibilityValue(download.map(SpeedFormat.text) ?? "No result yet")
    }

    private var readout: some View {
        VStack(spacing: 2) {
            HStack(spacing: 5) {
                if running {
                    Circle().fill(.red).frame(width: 6, height: 6)
                        .symbolEffect(.pulse, isActive: true)
                    Text("LIVE")
                } else {
                    Image(systemName: "arrow.down")
                    Text("DOWNLOAD")
                }
            }
            .font(.caption2.weight(.semibold))
            .tracking(1.2)
            .foregroundStyle(.secondary)

            if let download {
                let v = SpeedFormat.value(download)
                Text(v.number)
                    .font(.system(size: 54, weight: .semibold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(v.unit).font(.title3.weight(.medium)).foregroundStyle(.secondary)
            } else {
                Text("—")
                    .font(.system(size: 54, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tertiary)
                Text("Ready").font(.title3.weight(.medium)).foregroundStyle(.secondary)
            }
            if let upload {
                Label(SpeedFormat.text(upload), systemImage: "arrow.up")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(Theme.upload)
                    .contentTransition(.numericText())
                    .padding(.top, 6)
            }
        }
        .frame(width: 200)
        .animation(.smooth, value: download)
    }

    /// Decade ticks (1, 10, 100 Mbps, 1, 10 Gbps) with labels, and minor ticks at 2× and 5×.
    private func ticks(center: CGPoint, radius: CGFloat) -> some View {
        let labels = ["1", "10", "100", "1G", "10G"]
        let minor = (0..<4).flatMap { decade in [log10(2.0), log10(5.0)].map { (Double(decade) + $0) / 4 } }
        return ZStack {
            ForEach(0..<5, id: \.self) { i in
                let f = Double(i) / 4
                tick(center: center, from: radius - lineWidth / 2 - 6, to: radius - lineWidth / 2 - 14, fraction: f)
                    .stroke(.secondary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                Text(labels[i])
                    .font(.caption2.weight(.medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .position(point(center: center, radius: radius - lineWidth / 2 - 26, fraction: f))
            }
            ForEach(minor, id: \.self) { f in
                tick(center: center, from: radius - lineWidth / 2 - 6, to: radius - lineWidth / 2 - 10, fraction: f)
                    .stroke(.tertiary, style: StrokeStyle(lineWidth: 1, lineCap: .round))
            }
        }
    }

    private func tick(center: CGPoint, from r1: CGFloat, to r2: CGFloat, fraction: Double) -> Path {
        Path { p in
            p.move(to: point(center: center, radius: r1, fraction: fraction))
            p.addLine(to: point(center: center, radius: r2, fraction: fraction))
        }
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
