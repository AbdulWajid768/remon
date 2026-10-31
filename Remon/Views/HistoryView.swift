import Charts
import SwiftUI

enum HistoryRange: String, CaseIterable, Identifiable {
    case today = "Today"
    case week = "7 Days"
    case month = "30 Days"
    var id: String { rawValue }

    var start: Date {
        let startOfDay = Calendar.current.startOfDay(for: Date())
        switch self {
        case .today: return startOfDay
        case .week: return Calendar.current.date(byAdding: .day, value: -6, to: startOfDay)!
        case .month: return Calendar.current.date(byAdding: .day, value: -29, to: startOfDay)!
        }
    }

    var unit: Calendar.Component { self == .today ? .hour : .day }
}

struct HistoryView: View {
    @Environment(MonitorStore.self) private var store
    @State private var range: HistoryRange = .today
    @State private var points: [UsagePoint] = []
    @State private var topApps: [AppUsage] = []
    @State private var hovered: Date?
    @State private var loading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Picker("Range", selection: $range) {
                        ForEach(HistoryRange.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                    if let write = store.lastHistoryWrite {
                        Text("Saved \(write.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
                    }
                }

                if store.history == nil {
                    SourceFailureBanner(message: store.historyError ?? "History database unavailable.")
                }

                let totalIn = points.reduce(0) { $0 + $1.bytesIn }
                let totalOut = points.reduce(0) { $0 + $1.bytesOut }
                let peak = points.max { $0.total < $1.total }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 14)], spacing: 14) {
                    StatTile(title: "Downloaded", value: ByteFormat.bytes(totalIn), symbol: "arrow.down.circle.fill", tint: Theme.download)
                    StatTile(title: "Uploaded", value: ByteFormat.bytes(totalOut), symbol: "arrow.up.circle.fill", tint: Theme.upload)
                    StatTile(title: range == .today ? "Busiest Hour" : "Busiest Day",
                             value: peak.map { ByteFormat.bytes($0.total) } ?? "—",
                             detail: peak.map { label(for: $0.start) },
                             symbol: "chart.bar.fill", tint: .purple)
                }

                Card(range == .today ? "Usage by Hour" : "Usage by Day", symbol: "chart.bar.xaxis") {
                    if points.isEmpty && !loading {
                        ContentUnavailableView("No History Yet", systemImage: "chart.bar",
                                               description: Text("Remon records usage every minute while it runs."))
                            .frame(height: 220)
                    } else {
                        usageChart.frame(height: 240)
                    }
                }

                Card("Top Apps", symbol: "trophy") {
                    let query = SearchQuery(store.searchText)
                    let apps = topApps.filter { query.isEmpty || $0.name.localizedStandardContains(store.searchText) }
                    if apps.isEmpty {
                        Text(loading ? "Loading…" : "No app usage recorded for this range.").foregroundStyle(.secondary)
                    } else {
                        TopAppsChart(apps: Array(apps.prefix(12)))
                    }
                }
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: range) { await load() }
        .task {
            // Refresh periodically so "Today" fills in while the window is open.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await load()
            }
        }
    }

    private var usageChart: some View {
        Chart {
            ForEach(points) { p in
                BarMark(x: .value("Time", p.start, unit: range.unit), y: .value("Bytes", p.bytesIn))
                    .foregroundStyle(by: .value("Direction", "Download"))
                BarMark(x: .value("Time", p.start, unit: range.unit), y: .value("Bytes", p.bytesOut))
                    .foregroundStyle(by: .value("Direction", "Upload"))
            }
            if let hovered, let p = points.first(where: { Calendar.current.isDate($0.start, equalTo: hovered, toGranularity: range.unit) }) {
                RuleMark(x: .value("Selected", p.start, unit: range.unit))
                    .foregroundStyle(.gray.opacity(0.15))
                    .lineStyle(StrokeStyle(lineWidth: 24))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(label(for: p.start)).font(.caption2).foregroundStyle(.secondary)
                            Text("↓ \(ByteFormat.bytes(p.bytesIn))").foregroundStyle(Theme.download)
                            Text("↑ \(ByteFormat.bytes(p.bytesOut))").foregroundStyle(Theme.upload)
                        }
                        .font(.caption.monospacedDigit())
                        .padding(8)
                        .background(.regularMaterial, in: .rect(cornerRadius: 8))
                    }
            }
        }
        .chartForegroundStyleScale(["Download": Theme.download, "Upload": Theme.upload])
        .chartXSelection(value: $hovered)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                AxisValueLabel { if let v = value.as(Double.self) { Text(ByteFormat.bytes(v)).font(.caption2) } }
            }
        }
        .chartXScale(domain: range.start...(range == .today ? Calendar.current.date(byAdding: .day, value: 1, to: range.start)! : Date()))
        .animation(.smooth, value: points)
    }

    private func label(for date: Date) -> String {
        range == .today ? date.formatted(date: .omitted, time: .shortened) : date.formatted(.dateTime.weekday(.abbreviated).month().day())
    }

    private func load() async {
        guard let history = store.history else { loading = false; return }
        await store.flushHistory()
        let start = range.start
        let end = Date().addingTimeInterval(3600)
        let hourly = await history.totals(from: start, to: end)
        let apps = await history.topApps(from: start, to: end, limit: 25)
        let result: [UsagePoint]
        if range == .today {
            result = hourly
        } else {
            let calendar = Calendar.current
            let grouped = Dictionary(grouping: hourly) { calendar.startOfDay(for: $0.start) }
            result = grouped.map { day, items in
                UsagePoint(start: day, bytesIn: items.reduce(0) { $0 + $1.bytesIn }, bytesOut: items.reduce(0) { $0 + $1.bytesOut })
            }.sorted { $0.start < $1.start }
        }
        withAnimation(.smooth) {
            points = result
            topApps = apps
            loading = false
        }
    }
}

struct TopAppsChart: View {
    var apps: [AppUsage]

    var body: some View {
        let maxTotal = max(apps.map(\.total).max() ?? 1, 1)
        VStack(spacing: 8) {
            ForEach(apps) { app in
                HStack(spacing: 10) {
                    Image(nsImage: IconCache.shared.icon(forAppID: app.appID, name: app.name))
                        .resizable().frame(width: 20, height: 20)
                    Text(app.name).lineLimit(1).frame(width: 160, alignment: .leading)
                    GeometryReader { geo in
                        HStack(spacing: 1) {
                            Rectangle().fill(Theme.download).frame(width: geo.size.width * Double(app.bytesIn) / Double(maxTotal))
                            Rectangle().fill(Theme.upload).frame(width: geo.size.width * Double(app.bytesOut) / Double(maxTotal))
                        }
                        .clipShape(.rect(cornerRadius: 3))
                    }
                    .frame(height: 10)
                    Text(ByteFormat.bytes(app.total)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .trailing)
                }
            }
        }
    }
}
