import SwiftUI

/// Persistent log of every connection Remon has seen close (Little Snitch "Network Monitor" style).
struct ConnectionLogView: View {
    @Environment(MonitorStore.self) private var store
    @State private var range: LogRange = .day
    @State private var entries: [ConnectionLogEntry] = []
    @State private var sortOrder = [KeyPathComparator(\ConnectionLogEntry.lastSeen, order: .reverse)]
    @State private var selection: ConnectionLogEntry.ID?
    @State private var loading = true
    @State private var tableWidth: CGFloat = 1_000

    enum LogRange: String, CaseIterable, Identifiable {
        case hour = "Last Hour"
        case day = "24 Hours"
        case week = "7 Days"
        case all = "All"
        var id: String { rawValue }
        var since: Date {
            switch self {
            case .hour: Date().addingTimeInterval(-3600)
            case .day: Date().addingTimeInterval(-86_400)
            case .week: Date().addingTimeInterval(-7 * 86_400)
            case .all: .distantPast
            }
        }
    }

    private struct LoadKey: Equatable { var range: LogRange; var search: String; var revision: Int }

    var body: some View {
        let rows = entries.sorted(using: sortOrder)
        // Show only the columns that fit at their ideal widths; see ConnectionsView for why.
        let columns = (port: tableWidth >= 635, location: tableWidth >= 762, duration: tableWidth >= 845, category: tableWidth >= 945)
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Ended", value: \.lastSeen) { e in
                Text(e.lastSeen.formatted(date: Calendar.current.isDateInToday(e.lastSeen) ? .omitted : .abbreviated, time: .shortened))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 84)
            TableColumn("App", value: \.appName) { e in
                HStack(spacing: 6) {
                    Image(nsImage: IconCache.shared.icon(forAppID: e.appID, name: e.appName)).resizable().frame(width: 16, height: 16)
                    Text(e.appName).lineLimit(1)
                }
            }
            .width(min: 90, ideal: 120)
            TableColumn("Destination", value: \.displayHost) { e in
                // Always two lines so rows have one height (matches Connections).
                VStack(alignment: .leading, spacing: 0) {
                    Text(e.displayHost).lineLimit(1).truncationMode(.middle)
                    Text(e.hostname != nil ? e.remoteIP : (e.org ?? " "))
                        .font(e.hostname != nil ? .caption2.monospaced() : .caption2)
                        .foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .width(min: 110, ideal: 200)
            if columns.location {
                TableColumn("Location") { e in
                    if let place = e.city ?? e.countryCode {
                        Text("\(e.countryCode.map(GeoInfo.flag(for:)) ?? "") \(place)").lineLimit(1).foregroundStyle(.secondary)
                    } else {
                        Text("—").foregroundStyle(.tertiary)
                    }
                }
                .width(min: 70, ideal: 110)
            }
            if columns.port {
                TableColumn("Port", value: \.remotePort) { e in
                    Text("\(e.proto) \(e.remotePort)").monospacedDigit().foregroundStyle(.secondary)
                }
                .width(min: 56, ideal: 70)
            }
            if columns.category {
                TableColumn("Category", value: \.category) { e in
                    Text(e.category).foregroundStyle(.secondary).lineLimit(1)
                }
                .width(min: 64, ideal: 84)
            }
            if columns.duration {
                TableColumn("Duration", value: \.duration) { e in
                    Text(Duration.seconds(e.duration).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2)))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                .width(min: 50, ideal: 64)
            }
            TableColumn("Data", value: \.totalBytes) { e in
                Text(ByteFormat.bytes(e.totalBytes)).monospacedDigit()
            }
            .width(min: 50, ideal: 70)
        }
        .id([columns.port, columns.location, columns.duration, columns.category])  // see ConnectionsView
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { tableWidth = $0 }
        .contextMenu(forSelectionType: ConnectionLogEntry.ID.self) { ids in
            if let id = ids.first, let e = entries.first(where: { $0.id == id }) {
                Button("Copy Destination") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(e.hostname ?? e.remoteIP, forType: .string)
                }
                Button("Show Other Connections to \(e.displayHost)") { store.searchText = e.remoteIP }
                Button("Show \(e.appName)") { store.show(appID: e.appID) }
            }
        }
        .overlay {
            if rows.isEmpty && !loading {
                ContentUnavailableView(store.searchText.isEmpty ? "No Logged Connections" : "No Matches",
                                       systemImage: "list.bullet.rectangle",
                                       description: Text("Connections are logged here when they close. Open connections are in Connections."))
            }
        }
        // A frosted panel behind the rows: with nothing behind them, AppKit renders the cells with
        // vibrancy and the coloured rates and protocol badges wash out. Stripes on glass were too dark.
        .scrollContentBackground(.hidden)
        .alternatingRowBackgrounds(.disabled)
        .background(.thinMaterial)
        .safeAreaInset(edge: .top, spacing: 0) {
            PageBar {
                Picker("Range", selection: $range) {
                    ForEach(LogRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            } trailing: {
                Text("\(rows.count) connections · \(ByteFormat.bytes(rows.reduce(0) { $0 + $1.totalBytes }))")
                    .foregroundStyle(.secondary)
                Button {
                    exportCSV(rows)
                } label: {
                    Label("Export Log", systemImage: "square.and.arrow.up")
                }
                .disabled(rows.isEmpty)
            }
        }
        .task(id: LoadKey(range: range, search: store.searchText, revision: store.logRevision)) {
            try? await Task.sleep(for: .milliseconds(150)) // debounce typing
            guard let history = store.history else { loading = false; return }
            let text = store.searchText.trimmingCharacters(in: .whitespaces)
            entries = await history.connectionLog(search: text, since: range.since)
            loading = false
        }
    }

    private func exportCSV(_ rows: [ConnectionLogEntry]) {
        let iso = ISO8601DateFormatter()
        let data = rows.map { e -> [String: String] in
            ["first_seen": iso.string(from: e.firstSeen), "last_seen": iso.string(from: e.lastSeen), "app": e.appName,
             "protocol": e.proto, "remote_ip": e.remoteIP, "remote_port": String(e.remotePort), "hostname": e.hostname ?? "",
             "country": e.countryCode ?? "", "city": e.city ?? "", "organisation": e.org ?? "", "category": e.category,
             "bytes_in": String(e.bytesIn), "bytes_out": String(e.bytesOut)]
        }
        let columns = ["first_seen", "last_seen", "app", "protocol", "remote_ip", "remote_port", "hostname", "country",
                       "city", "organisation", "category", "bytes_in", "bytes_out"]
        ExportService.save(try? ExportService.encode(data, columns: columns, format: .csv), suggestedName: "Remon Connection Log", ext: "csv")
    }
}
