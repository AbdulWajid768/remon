import Charts
import SwiftUI

struct AppsView: View {
    @Environment(MonitorStore.self) private var store
    @Environment(Preferences.self) private var preferences
    @State private var sortOrder = [KeyPathComparator(\AppTraffic.totalRate, order: .reverse)]
    @State private var onlyActive = false
    @State private var onlyUnsigned = false

    var body: some View {
        @Bindable var store = store
        let query = SearchQuery(store.searchText)
        let rows = store.apps
            .filter { !onlyActive || $0.connectionCount > 0 || $0.totalRate > 0 }
            .filter { !onlyUnsigned || (store.signing[$0.id]?.status.isConcerning ?? false) }
            .filter { query.isEmpty || query.matches($0, connections: store.connections(forApp: $0.id)) }
            .sorted(using: sortOrder)

        Table(rows, selection: $store.selectedAppID, sortOrder: $sortOrder) {
            TableColumn("App", value: \.name) { app in
                AppLabel(identity: app.identity)
            }
            .width(min: 180, ideal: 240)
            TableColumn("Signed") { app in
                SignatureBadge(info: store.signing[app.id], compact: true)
            }
            .width(min: 36, ideal: 44, max: 60)
            TableColumn("Download", value: \.rateIn) { app in
                RateText(rate: app.rateIn, direction: .down)
            }
            .width(min: 80, ideal: 100)
            TableColumn("Upload", value: \.rateOut) { app in
                RateText(rate: app.rateOut, direction: .up)
            }
            .width(min: 80, ideal: 100)
            TableColumn("Activity") { app in
                Sparkline(values: Array(app.sparkline.suffix(60)))
                    .frame(height: 18)
            }
            .width(min: 80, ideal: 120)
            TableColumn("Session ↓", value: \.sessionIn) { app in
                Text(ByteFormat.bytes(app.sessionIn)).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 85)
            TableColumn("Session ↑", value: \.sessionOut) { app in
                Text(ByteFormat.bytes(app.sessionOut)).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 85)
            TableColumn("Conns", value: \.connectionCount) { app in
                Text(app.connectionCount == 0 ? "—" : "\(app.connectionCount)").monospacedDigit()
                    .foregroundStyle(app.connectionCount == 0 ? .tertiary : .primary)
            }
            .width(min: 44, ideal: 54)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let app = store.app(id: id) {
                AppContextMenu(app: app)
            }
        } primaryAction: { ids in
            if let id = ids.first {
                store.searchText = "app:\"\(store.app(id: id)?.name ?? "")\" "
                store.section = .connections
            }
        }
        .overlay {
            if rows.isEmpty {
                if store.searchText.isEmpty {
                    ContentUnavailableView("No Apps Yet", systemImage: "square.grid.2x2",
                                           description: Text("Apps appear here as soon as they open a network socket."))
                } else {
                    ContentUnavailableView.search(text: store.searchText)
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Toggle("Only apps with open connections", isOn: $onlyActive)
                    .toggleStyle(.checkbox)
                Toggle("Only unsigned or ad-hoc", isOn: $onlyUnsigned)
                    .toggleStyle(.checkbox)
                Spacer()
                Text("\(rows.count) apps").foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.bar)
        }
    }
}

struct AppContextMenu: View {
    var app: AppTraffic
    @Environment(MonitorStore.self) private var store

    var body: some View {
        Button("Show Connections") {
            store.searchText = "app:\"\(app.name)\" "
            store.section = .connections
        }
        Button("Reveal in Finder") { store.reveal(app.identity) }
            .disabled(app.identity.executablePath == nil)
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(app.identity.bundlePath ?? app.identity.executablePath ?? app.name, forType: .string)
        }
        Divider()
        Button("Alert When Above 5 MB/s…") {
            store.alerts.rules.append(AlertRule(name: "\(app.name) heavy traffic", kind: .appRate, threshold: 5_000_000,
                                                sustainSeconds: 10, appID: app.id, appName: app.name))
            store.section = .alerts
        }
        let servers = Array(Set(store.connections(forApp: app.id)
            .filter { !$0.isListening && IPClassifier.scope(of: $0.remote.bareAddress) == .publicInternet }
            .map(\.remote.bareAddress))).sorted()
        Button("Block \(app.name)'s Current Servers (\(servers.count))") {
            store.policy.block(addresses: servers, note: app.name)
            store.section = .rules
        }
        .disabled(servers.isEmpty)
        if let running = store.runningApplication(for: app) {
            Divider()
            Button("Quit \(app.name)") { running.terminate() }
        }
    }
}

struct AppInspector: View {
    var app: AppTraffic
    @Environment(MonitorStore.self) private var store
    @Environment(Preferences.self) private var preferences
    @State private var today: [UsagePoint] = []
    @State private var week: [UsagePoint] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    AppIcon(identity: app.identity, size: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name).font(.title3.weight(.semibold)).lineLimit(2)
                        Text(app.identity.bundleID ?? (app.identity.isSystem ? "System process" : "Command-line process"))
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        SignatureBadge(info: store.signing[app.id])
                    }
                }

                HStack(spacing: 10) {
                    rateBlock("Download", app.rateIn, Theme.download, "arrow.down")
                    rateBlock("Upload", app.rateOut, Theme.upload, "arrow.up")
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Last 2 Minutes").font(.subheadline.weight(.semibold))
                    ThroughputChart(points: chartPoints, window: Double(MonitorStore.appHistoryLength) * Double(preferences.sampleInterval),
                                    showsAxes: true, interactive: true)
                        .frame(height: 120)
                }

                GroupBox {
                    VStack(spacing: 6) {
                        DetailRow(label: "Session ↓", value: ByteFormat.bytes(app.sessionIn))
                        DetailRow(label: "Session ↑", value: ByteFormat.bytes(app.sessionOut))
                        DetailRow(label: "Today", value: ByteFormat.bytes(today.reduce(0) { $0 + $1.total }))
                        if let team = store.signing[app.id]?.teamID {
                            DetailRow(label: "Team ID", value: team, monospaced: true)
                        }
                        DetailRow(label: "Processes", value: app.pids.isEmpty ? "Not running" : app.pids.sorted().map(String.init).joined(separator: ", "))
                        if let path = app.identity.bundlePath ?? app.identity.executablePath {
                            DetailRow(label: "Path", value: path, monospaced: true)
                        }
                    }
                }

                if week.contains(where: { $0.total > 0 }) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Last 7 Days").font(.subheadline.weight(.semibold))
                        Chart(week) { p in
                            BarMark(x: .value("Day", p.start, unit: .day), y: .value("Bytes", p.bytesIn))
                                .foregroundStyle(Theme.download)
                            BarMark(x: .value("Day", p.start, unit: .day), y: .value("Bytes", p.bytesOut))
                                .foregroundStyle(Theme.upload)
                        }
                        .chartYAxis {
                            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                                AxisGridLine()
                                AxisValueLabel { if let v = value.as(Double.self) { Text(ByteFormat.bytes(v)).font(.caption2) } }
                            }
                        }
                        .chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.narrow)) } }
                        .frame(height: 90)
                    }
                }

                let conns = store.connections(forApp: app.id).filter { !$0.isListening }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Connections (\(conns.count))").font(.subheadline.weight(.semibold))
                    if conns.isEmpty {
                        Text("No open connections").foregroundStyle(.secondary).font(.callout)
                    }
                    ForEach(conns.prefix(12)) { c in
                        Button {
                            store.selectedConnectionID = c.id
                            store.section = .connections
                        } label: {
                            HStack(spacing: 6) {
                                Text(c.geo?.flag ?? "🌐")
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(c.displayHost).lineLimit(1).truncationMode(.middle)
                                    Text("\(c.proto.rawValue) · \(c.service ?? String(c.remote.port ?? 0))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                RateText(rate: c.totalRate, direction: .down, font: .caption)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .font(.callout)
                    }
                }

                HStack {
                    Button("Reveal in Finder") { store.reveal(app.identity) }
                        .disabled(app.identity.executablePath == nil)
                    Spacer()
                    if let running = store.runningApplication(for: app) {
                        Button("Quit App", role: .destructive) { running.terminate() }
                    }
                }
                .controlSize(.small)
            }
            .padding(16)
        }
        .task(id: app.id) {
            guard let history = store.history else { return }
            let calendar = Calendar.current
            let startOfToday = calendar.startOfDay(for: Date())
            today = await history.appSeries(appID: app.id, from: startOfToday, to: Date().addingTimeInterval(60))
            let weekStart = calendar.date(byAdding: .day, value: -6, to: startOfToday) ?? startOfToday
            let hourly = await history.appSeries(appID: app.id, from: weekStart, to: Date().addingTimeInterval(3600))
            let byDay = Dictionary(grouping: hourly) { calendar.startOfDay(for: $0.start) }
            week = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart) }.map { day in
                let items = byDay[day] ?? []
                return UsagePoint(start: day, bytesIn: items.reduce(0) { $0 + $1.bytesIn }, bytesOut: items.reduce(0) { $0 + $1.bytesOut })
            }
        }
    }

    private var chartPoints: [ThroughputPoint] {
        let step = Double(preferences.sampleInterval)
        let count = app.historyIn.count
        let now = Date()
        return app.historyIn.indices.map { i in
            ThroughputPoint(date: now.addingTimeInterval(-Double(count - 1 - i) * step), rateIn: app.historyIn[i], rateOut: app.historyOut[i])
        }
    }

    private func rateBlock(_ title: String, _ rate: Double, _ color: Color, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(color)
            Text(preferences.rate(rate)).font(.title3.weight(.semibold).monospacedDigit())
                .contentTransition(.numericText())
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.1), in: .rect(cornerRadius: 10, style: .continuous))
    }
}
