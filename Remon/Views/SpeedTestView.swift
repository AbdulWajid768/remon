import Charts
import SwiftUI

/// Speed and responsiveness test using Apple's `networkQuality`.
struct SpeedTestView: View {
    @Environment(MonitorStore.self) private var store

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Card {
                    HStack(alignment: .center, spacing: 32) {
                        SpeedGauge(value: store.speedTestResults.first?.download, running: store.speedTestRunning,
                                   started: store.speedTestStarted)
                            .frame(width: 240, height: 200)
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Network Quality").font(.title2.weight(.semibold))
                            Text("Measures download and upload capacity and responsiveness under load using Apple's built-in networkQuality test — the same one behind System Settings. It uses Apple's servers and can transfer a few hundred megabytes.")
                                .font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack {
                                Button {
                                    store.runSpeedTest()
                                } label: {
                                    Label(store.speedTestRunning ? "Testing…" : "Run Test", systemImage: "play.fill")
                                        .frame(minWidth: 110)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                                .disabled(store.speedTestRunning)
                                .keyboardShortcut("r", modifiers: [.command])
                                if let error = store.speedTestError {
                                    Label(error, systemImage: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange).font(.callout).lineLimit(2)
                                }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }

                if let latest = store.speedTestResults.first {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 4), spacing: 14) {
                        StatTile(title: "Download", value: mbps(latest.download), symbol: "arrow.down.circle.fill", tint: Theme.download)
                        StatTile(title: "Upload", value: mbps(latest.upload), symbol: "arrow.up.circle.fill", tint: Theme.upload)
                        StatTile(title: "Responsiveness", value: latest.responsivenessRPM.map { "\(Int($0)) RPM" } ?? "—",
                                 detail: latest.responsivenessRating, symbol: "bolt.horizontal.circle.fill", tint: .purple)
                        StatTile(title: "Idle Latency", value: latest.baseRTTms.map { String(format: "%.0f ms", $0) } ?? "—",
                                 detail: latest.interface.map { "via \($0)" }, symbol: "timer", tint: .teal)
                    }
                }

                if store.speedTestResults.count > 1 {
                    Card("History", symbol: "chart.xyaxis.line") {
                        Chart {
                            ForEach(store.speedTestResults.reversed()) { r in
                                LineMark(x: .value("Date", r.date), y: .value("Mbps", r.download / 1e6))
                                    .foregroundStyle(by: .value("Direction", "Download"))
                                    .symbol(.circle)
                                LineMark(x: .value("Date", r.date), y: .value("Mbps", r.upload / 1e6))
                                    .foregroundStyle(by: .value("Direction", "Upload"))
                                    .symbol(.circle)
                            }
                        }
                        .chartForegroundStyleScale(["Download": Theme.download, "Upload": Theme.upload])
                        .chartYAxisLabel("Mbps")
                        .frame(height: 180)
                    }
                }

                if !store.speedTestResults.isEmpty {
                    Card("Past Results", symbol: "clock") {
                        VStack(spacing: 8) {
                            ForEach(store.speedTestResults.prefix(10)) { r in
                                HStack {
                                    Text(r.date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                                    Spacer()
                                    Text("↓ \(mbps(r.download))").foregroundStyle(Theme.download)
                                    Text("↑ \(mbps(r.upload))").foregroundStyle(Theme.upload).frame(width: 110, alignment: .trailing)
                                    Text(r.responsivenessRPM.map { "\(Int($0)) RPM" } ?? "—").foregroundStyle(.secondary)
                                        .frame(width: 90, alignment: .trailing)
                                }
                                .font(.callout.monospacedDigit())
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func mbps(_ bitsPerSecond: Double) -> String {
        let value = bitsPerSecond / 1e6
        return value >= 100 ? String(format: "%.0f Mbps", value) : String(format: "%.1f Mbps", value)
    }
}

/// Semicircular gauge on a log scale (1 Mbps … 10 Gbps), with a sweeping arc while testing.
struct SpeedGauge: View {
    var value: Double?
    var running: Bool
    var started: Date?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !running)) { context in
            let fraction = running ? sweep(context.date) : normalized(value)
            ZStack {
                Arc(fraction: 1).stroke(.quaternary, style: StrokeStyle(lineWidth: 18, lineCap: .round))
                Arc(fraction: fraction)
                    .stroke(AngularGradient(colors: [Theme.download.opacity(0.6), Theme.download, .purple], center: .center,
                                            startAngle: .degrees(150), endAngle: .degrees(390)),
                            style: StrokeStyle(lineWidth: 18, lineCap: .round))
                    .animation(running ? nil : .spring(duration: 1.0, bounce: 0.25), value: fraction)
                VStack(spacing: 2) {
                    if running {
                        Text(elapsed(context.date)).font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                        Text("Testing…").font(.callout).foregroundStyle(.secondary)
                    } else if let value {
                        Text(String(format: value >= 1e8 ? "%.0f" : "%.1f", value / 1e6))
                            .font(.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
                            .contentTransition(.numericText())
                        Text("Mbps down").font(.callout).foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "speedometer").font(.system(size: 40)).foregroundStyle(.secondary)
                        Text("No results yet").font(.callout).foregroundStyle(.secondary)
                    }
                }
                .offset(y: 10)
            }
        }
    }

    private func normalized(_ bps: Double?) -> Double {
        guard let bps, bps > 0 else { return 0 }
        return min(max(log10(bps / 1e6) / 4, 0.02), 1) // 1 Mbps → 0, 10 Gbps → 1
    }

    private func sweep(_ date: Date) -> Double {
        let t = date.timeIntervalSince(started ?? date)
        return 0.15 + 0.7 * (0.5 + 0.5 * sin(t * 2.2))
    }

    private func elapsed(_ date: Date) -> String {
        "\(Int(date.timeIntervalSince(started ?? date)))s"
    }

    private struct Arc: Shape {
        var fraction: Double
        var animatableData: Double {
            get { fraction }
            set { fraction = newValue }
        }

        func path(in rect: CGRect) -> Path {
            let radius = min(rect.width, rect.height * 1.25) / 2 - 10
            let center = CGPoint(x: rect.midX, y: rect.midY + radius * 0.25)
            var p = Path()
            p.addArc(center: center, radius: radius, startAngle: .degrees(150),
                     endAngle: .degrees(150 + 240 * max(fraction, 0.0001)), clockwise: false)
            return p
        }
    }
}
