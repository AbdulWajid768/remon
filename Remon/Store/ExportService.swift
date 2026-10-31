import AppKit
import UniformTypeIdentifiers

/// CSV / JSON export through a native save panel.
@MainActor
enum ExportService {
    enum Kind: String { case connections = "Connections", apps = "App Usage", history = "History" }
    nonisolated enum Format: Sendable { case csv, json }

    static func export(_ kind: Kind, format: Format, store: MonitorStore) {
        let panel = NSSavePanel()
        let stamp = Date().formatted(.iso8601.year().month().day())
        panel.nameFieldStringValue = "Remon \(kind.rawValue) \(stamp).\(format == .csv ? "csv" : "json")"
        panel.allowedContentTypes = [format == .csv ? .commaSeparatedText : .json]
        panel.canCreateDirectories = true
        panel.title = "Export \(kind.rawValue)"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            do {
                let data = try await makeData(kind, format: format, store: store)
                try data.write(to: url, options: .atomic)
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }
    }

    /// Saves already-encoded data through a save panel.
    static func save(_ data: Data?, suggestedName: String, ext: String) {
        guard let data else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(suggestedName) \(Date().formatted(.iso8601.year().month().day())).\(ext)"
        panel.allowedContentTypes = [ext == "json" ? .json : .commaSeparatedText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url, options: .atomic) } catch { NSAlert(error: error).runModal() }
    }

    static func makeData(_ kind: Kind, format: Format, store: MonitorStore) async throws -> Data {
        switch kind {
        case .connections:
            let rows = store.connections.map { c -> [String: String] in
                [
                    "app": c.appName, "process": c.processName, "pid": String(c.pid), "protocol": c.proto.rawValue,
                    "family": c.family.rawValue, "local": c.local.display, "remote": c.remote.display,
                    "hostname": c.hostname ?? "", "country": c.geo?.countryCode ?? "", "city": c.geo?.city ?? "",
                    "organisation": c.geo?.org ?? "", "category": c.category.rawValue, "state": c.isClosed ? "Closed" : c.displayState,
                    "interface": c.interface, "bytes_in": String(c.totalIn), "bytes_out": String(c.totalOut),
                    "rate_in_bps": String(format: "%.0f", c.rateIn), "rate_out_bps": String(format: "%.0f", c.rateOut),
                    "rtt_ms": c.rttMs.map { String(format: "%.2f", $0) } ?? "",
                ]
            }
            return try encode(rows, columns: ["app", "process", "pid", "protocol", "family", "local", "remote", "hostname", "country",
                                              "city", "organisation", "category", "state", "interface", "bytes_in", "bytes_out",
                                              "rate_in_bps", "rate_out_bps", "rtt_ms"], format: format)
        case .apps:
            let rows = store.apps.map { a -> [String: String] in
                [
                    "app": a.name, "bundle_id": a.identity.bundleID ?? "", "path": a.identity.bundlePath ?? a.identity.executablePath ?? "",
                    "session_bytes_in": String(a.sessionIn), "session_bytes_out": String(a.sessionOut),
                    "rate_in_bps": String(format: "%.0f", a.rateIn), "rate_out_bps": String(format: "%.0f", a.rateOut),
                    "connections": String(a.connectionCount), "pids": a.pids.sorted().map(String.init).joined(separator: " "),
                ]
            }
            return try encode(rows, columns: ["app", "bundle_id", "path", "session_bytes_in", "session_bytes_out", "rate_in_bps",
                                              "rate_out_bps", "connections", "pids"], format: format)
        case .history:
            guard let history = store.history else { return Data() }
            await store.flushHistory()
            let start = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
            let points = await history.totals(from: start, to: Date().addingTimeInterval(3600))
            let iso = ISO8601DateFormatter()
            let rows = points.map { ["hour_start": iso.string(from: $0.start), "bytes_in": String($0.bytesIn), "bytes_out": String($0.bytesOut)] }
            return try encode(rows, columns: ["hour_start", "bytes_in", "bytes_out"], format: format)
        }
    }

    nonisolated static func encode(_ rows: [[String: String]], columns: [String], format: Format) throws -> Data {
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(rows)
        case .csv:
            var lines = [columns.joined(separator: ",")]
            for row in rows {
                lines.append(columns.map { csvEscape(row[$0] ?? "") }.joined(separator: ","))
            }
            return Data((lines.joined(separator: "\n") + "\n").utf8)
        }
    }

    nonisolated static func csvEscape(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
