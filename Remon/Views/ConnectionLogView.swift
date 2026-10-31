import SwiftUI

/// Persistent log of every connection Remon has seen close (Little Snitch "Network Monitor" style).
struct ConnectionLogView: View {
    @Environment(MonitorStore.self) private var store
    @State private var range: LogRange = .day
    @State private var entries: [ConnectionLogEntry] = []
    @State private var sortOrder = [KeyPathComparator(\ConnectionLogEntry.lastSeen, order: .reverse)]
    @State private var selection: ConnectionLogEntry.ID?
    @State private var loading = true

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
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Ended", value: \.lastSeen) { e in
                Text(e.lastSeen.formatted(date: Calendar.current.isDateInToday(e.lastSeen) ? .omitted : .abbreviated, time: .shortened))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 110)
            TableColumn("App", value: \.appName) { e in
                HStack(spacing: 6) {
                    Image(nsImage: IconCache.shared.icon(forAppID: e.appID, name: e.appName)).resizable().frame(width: 16, height: 16)
                    Text(e.appName).lineLimit(1)
                }
            }
            .width(min: 120, ideal: 150)
            TableColumn("Destination", value: \.displayHost) { e in
                VStack(alignment: .leading, spacing: 0) {
                    Text(e.displayHost).lineLimit(1).truncationMode(.middle)
                    if e.hostname != nil { Text(e.remoteIP).font(.caption2.monospaced()).foregroundStyle(.secondary) }
                }
            }
            .width(min: 160, ideal: 230)
            TableColumn("Location") { e in
                Text("\(e.countryCode.map(GeoInfo.flag(for:)) ?? "") \(e.city ?? e.countryCode ?? "")").lineLimit(1).foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 130)
            TableColumn("Port", value: \.remotePort) { e in
                Text("\(e.proto) \(e.remotePort)").monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 80)
            TableColumn("Category", value: \.category) { e in
                Text(e.category).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 80, ideal: 110)
            TableColumn("Duration", value: \.duration) { e in
                Text(Duration.seconds(e.duration).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2)))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 80)
            TableColumn("Data", value: \.totalBytes) { e in
                Text(ByteFormat.bytes(e.totalBytes)).monospacedDigit()
            }
            .width(min: 60, ideal: 80)
        }
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
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Picker("Range", selection: $range) {
                    ForEach(LogRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                Text("\(rows.count) connections · \(ByteFormat.bytes(rows.reduce(0) { $0 + $1.totalBytes }))")
                    .foregroundStyle(.secondary)
                Button {
                    exportCSV(rows)
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(rows.isEmpty)
            }
            .font(.callout)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.bar)
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
