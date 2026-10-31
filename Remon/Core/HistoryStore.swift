import Foundation
import SQLite3

struct UsagePoint: Identifiable, Hashable, Sendable {
    var start: Date
    var bytesIn: UInt64
    var bytesOut: UInt64
    var id: Date { start }
    var total: UInt64 { bytesIn + bytesOut }
}

struct AppUsage: Identifiable, Hashable, Sendable {
    var appID: String
    var name: String
    var bytesIn: UInt64
    var bytesOut: UInt64
    var id: String { appID }
    var total: UInt64 { bytesIn + bytesOut }
}

struct ConnectionLogEntry: Identifiable, Hashable, Sendable {
    var id: Int64 = 0
    var appID: String
    var appName: String
    var proto: String
    var remoteIP: String
    var remotePort: Int
    var hostname: String?
    var countryCode: String?
    var city: String?
    var org: String?
    var category: String
    var firstSeen: Date
    var lastSeen: Date
    var bytesIn: UInt64
    var bytesOut: UInt64

    var totalBytes: UInt64 { bytesIn + bytesOut }
    var displayHost: String { hostname ?? remoteIP }
    var duration: TimeInterval { lastSeen.timeIntervalSince(firstSeen) }
}

struct UsageDelta: Sendable {
    var appID: String
    var name: String
    var bytesIn: UInt64
    var bytesOut: UInt64
}

enum HistoryError: LocalizedError {
    case sqlite(String)
    var errorDescription: String? {
        switch self { case .sqlite(let message): "History database error: \(message)" }
    }
}

/// Per-minute usage history in SQLite (`~/Library/Application Support/Remon/history.sqlite`).
actor HistoryStore {
    nonisolated(unsafe) private var db: OpaquePointer?
    let url: URL

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw HistoryError.sqlite(message)
        }
        db = handle
        let schema = """
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=NORMAL;
        CREATE TABLE IF NOT EXISTS app_usage (
            app_id TEXT NOT NULL, bucket INTEGER NOT NULL, name TEXT NOT NULL,
            bytes_in INTEGER NOT NULL DEFAULT 0, bytes_out INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (app_id, bucket)) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS app_usage_bucket ON app_usage(bucket);
        CREATE TABLE IF NOT EXISTS totals (
            bucket INTEGER PRIMARY KEY, bytes_in INTEGER NOT NULL DEFAULT 0, bytes_out INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS known_apps (app_id TEXT PRIMARY KEY, name TEXT NOT NULL, first_seen INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS geo_cache (ip TEXT PRIMARY KEY, json BLOB NOT NULL, fetched INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS connection_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT, app_id TEXT NOT NULL, app_name TEXT NOT NULL, proto TEXT NOT NULL,
            remote_ip TEXT NOT NULL, remote_port INTEGER NOT NULL, hostname TEXT, country_code TEXT, city TEXT, org TEXT,
            category TEXT NOT NULL, first_seen INTEGER NOT NULL, last_seen INTEGER NOT NULL,
            bytes_in INTEGER NOT NULL, bytes_out INTEGER NOT NULL);
        CREATE INDEX IF NOT EXISTS connection_log_last_seen ON connection_log(last_seen);
        CREATE TABLE IF NOT EXISTS speed_tests (date INTEGER PRIMARY KEY, json BLOB NOT NULL);
        """
        guard sqlite3_exec(handle, schema, nil, nil, nil) == SQLITE_OK else {
            throw HistoryError.sqlite(String(cString: sqlite3_errmsg(handle)))
        }
    }

    deinit { sqlite3_close(db) }

    // MARK: Writes

    func record(bucket: Date, apps: [UsageDelta], totalIn: UInt64, totalOut: UInt64) {
        let b = Int64(bucket.timeIntervalSince1970)
        exec("BEGIN")
        if !apps.isEmpty {
            let sql = """
            INSERT INTO app_usage (app_id, bucket, name, bytes_in, bytes_out) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(app_id, bucket) DO UPDATE SET bytes_in = bytes_in + excluded.bytes_in,
                bytes_out = bytes_out + excluded.bytes_out, name = excluded.name
            """
            withStatement(sql) { stmt in
                for app in apps where app.bytesIn + app.bytesOut > 0 {
                    sqlite3_bind_text(stmt, 1, app.appID, -1, Self.transient)
                    sqlite3_bind_int64(stmt, 2, b)
                    sqlite3_bind_text(stmt, 3, app.name, -1, Self.transient)
                    sqlite3_bind_int64(stmt, 4, Int64(clamping: app.bytesIn))
                    sqlite3_bind_int64(stmt, 5, Int64(clamping: app.bytesOut))
                    sqlite3_step(stmt)
                    sqlite3_reset(stmt)
                }
            }
        }
        if totalIn + totalOut > 0 {
            withStatement("""
            INSERT INTO totals (bucket, bytes_in, bytes_out) VALUES (?, ?, ?)
            ON CONFLICT(bucket) DO UPDATE SET bytes_in = bytes_in + excluded.bytes_in, bytes_out = bytes_out + excluded.bytes_out
            """) { stmt in
                sqlite3_bind_int64(stmt, 1, b)
                sqlite3_bind_int64(stmt, 2, Int64(clamping: totalIn))
                sqlite3_bind_int64(stmt, 3, Int64(clamping: totalOut))
                sqlite3_step(stmt)
            }
        }
        exec("COMMIT")
    }

    func markKnown(_ apps: [(id: String, name: String)]) {
        guard !apps.isEmpty else { return }
        let now = Int64(Date().timeIntervalSince1970)
        exec("BEGIN")
        withStatement("INSERT OR IGNORE INTO known_apps (app_id, name, first_seen) VALUES (?, ?, ?)") { stmt in
            for app in apps {
                sqlite3_bind_text(stmt, 1, app.id, -1, Self.transient)
                sqlite3_bind_text(stmt, 2, app.name, -1, Self.transient)
                sqlite3_bind_int64(stmt, 3, now)
                sqlite3_step(stmt)
                sqlite3_reset(stmt)
            }
        }
        exec("COMMIT")
    }

    func saveGeo(_ ip: String, _ info: GeoInfo) {
        guard let data = try? JSONEncoder().encode(info) else { return }
        withStatement("INSERT OR REPLACE INTO geo_cache (ip, json, fetched) VALUES (?, ?, ?)") { stmt in
            sqlite3_bind_text(stmt, 1, ip, -1, Self.transient)
            _ = data.withUnsafeBytes { sqlite3_bind_blob(stmt, 2, $0.baseAddress, Int32($0.count), Self.transient) }
            sqlite3_bind_int64(stmt, 3, Int64(Date().timeIntervalSince1970))
            sqlite3_step(stmt)
        }
    }

    func logConnections(_ entries: [ConnectionLogEntry]) {
        guard !entries.isEmpty else { return }
        exec("BEGIN")
        withStatement("""
        INSERT INTO connection_log (app_id, app_name, proto, remote_ip, remote_port, hostname, country_code, city, org,
            category, first_seen, last_seen, bytes_in, bytes_out) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """) { stmt in
            for e in entries {
                bindText(stmt, 1, e.appID); bindText(stmt, 2, e.appName); bindText(stmt, 3, e.proto)
                bindText(stmt, 4, e.remoteIP); sqlite3_bind_int64(stmt, 5, Int64(e.remotePort))
                bindText(stmt, 6, e.hostname); bindText(stmt, 7, e.countryCode); bindText(stmt, 8, e.city)
                bindText(stmt, 9, e.org); bindText(stmt, 10, e.category)
                sqlite3_bind_int64(stmt, 11, Int64(e.firstSeen.timeIntervalSince1970))
                sqlite3_bind_int64(stmt, 12, Int64(e.lastSeen.timeIntervalSince1970))
                sqlite3_bind_int64(stmt, 13, Int64(clamping: e.bytesIn))
                sqlite3_bind_int64(stmt, 14, Int64(clamping: e.bytesOut))
                sqlite3_step(stmt)
                sqlite3_reset(stmt)
            }
        }
        exec("COMMIT")
    }

    /// Most recent connections first. `search` matches app, host, IP, country, city or organisation.
    func connectionLog(search: String?, since: Date, limit: Int = 2000) -> [ConnectionLogEntry] {
        var result: [ConnectionLogEntry] = []
        let pattern = search.flatMap { $0.isEmpty ? nil : "%\($0)%" }
        let filter = pattern == nil ? "" : """
         AND (app_name LIKE ?2 OR hostname LIKE ?2 OR remote_ip LIKE ?2 OR country_code LIKE ?2
              OR city LIKE ?2 OR org LIKE ?2 OR category LIKE ?2)
        """
        withStatement("SELECT id, app_id, app_name, proto, remote_ip, remote_port, hostname, country_code, city, org, category, first_seen, last_seen, bytes_in, bytes_out FROM connection_log WHERE last_seen >= ?1\(filter) ORDER BY last_seen DESC LIMIT ?3") { stmt in
            sqlite3_bind_int64(stmt, 1, Int64(since.timeIntervalSince1970))
            if let pattern { bindText(stmt, 2, pattern) }
            sqlite3_bind_int64(stmt, 3, Int64(limit))
            while sqlite3_step(stmt) == SQLITE_ROW {
                result.append(ConnectionLogEntry(
                    id: sqlite3_column_int64(stmt, 0), appID: text(stmt, 1), appName: text(stmt, 2), proto: text(stmt, 3),
                    remoteIP: text(stmt, 4), remotePort: Int(sqlite3_column_int64(stmt, 5)), hostname: optionalText(stmt, 6),
                    countryCode: optionalText(stmt, 7), city: optionalText(stmt, 8), org: optionalText(stmt, 9),
                    category: text(stmt, 10), firstSeen: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 11))),
                    lastSeen: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 12))),
                    bytesIn: UInt64(sqlite3_column_int64(stmt, 13)), bytesOut: UInt64(sqlite3_column_int64(stmt, 14))))
            }
        }
        return result
    }

    func saveSpeedTest(_ result: SpeedTestResult) {
        guard let data = try? JSONEncoder().encode(result) else { return }
        withStatement("INSERT OR REPLACE INTO speed_tests (date, json) VALUES (?, ?)") { stmt in
            sqlite3_bind_int64(stmt, 1, Int64(result.date.timeIntervalSince1970))
            _ = data.withUnsafeBytes { sqlite3_bind_blob(stmt, 2, $0.baseAddress, Int32($0.count), Self.transient) }
            sqlite3_step(stmt)
        }
    }

    func speedTests(limit: Int = 50) -> [SpeedTestResult] {
        var result: [SpeedTestResult] = []
        let decoder = JSONDecoder()
        withStatement("SELECT json FROM speed_tests ORDER BY date DESC LIMIT ?") { stmt in
            sqlite3_bind_int64(stmt, 1, Int64(limit))
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let blob = sqlite3_column_blob(stmt, 0) else { continue }
                let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 0)))
                if let r = try? decoder.decode(SpeedTestResult.self, from: data) { result.append(r) }
            }
        }
        return result
    }

    /// Sum of machine totals in a range.
    func totalBytes(from: Date, to: Date) -> (bytesIn: UInt64, bytesOut: UInt64) {
        var result: (UInt64, UInt64) = (0, 0)
        withStatement("SELECT COALESCE(SUM(bytes_in),0), COALESCE(SUM(bytes_out),0) FROM totals WHERE bucket >= ? AND bucket < ?") { stmt in
            sqlite3_bind_int64(stmt, 1, Int64(from.timeIntervalSince1970))
            sqlite3_bind_int64(stmt, 2, Int64(to.timeIntervalSince1970))
            if sqlite3_step(stmt) == SQLITE_ROW {
                result = (UInt64(sqlite3_column_int64(stmt, 0)), UInt64(sqlite3_column_int64(stmt, 1)))
            }
        }
        return result
    }

    /// Per-app hourly totals in a range (callers group into local days).
    func appHourlyTotals(from: Date, to: Date) -> [(appID: String, name: String, hour: Date, bytes: UInt64)] {
        var result: [(String, String, Date, UInt64)] = []
        withStatement("""
        SELECT app_id, MAX(name), (bucket / 3600) * 3600, SUM(bytes_in + bytes_out) FROM app_usage
        WHERE bucket >= ? AND bucket < ? GROUP BY app_id, 3
        """) { stmt in
            sqlite3_bind_int64(stmt, 1, Int64(from.timeIntervalSince1970))
            sqlite3_bind_int64(stmt, 2, Int64(to.timeIntervalSince1970))
            while sqlite3_step(stmt) == SQLITE_ROW {
                result.append((text(stmt, 0), text(stmt, 1), Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 2))),
                               UInt64(sqlite3_column_int64(stmt, 3))))
            }
        }
        return result
    }

    func prune(retentionDays: Int) {
        let cutoff = Int64(Date().addingTimeInterval(-Double(retentionDays) * 86_400).timeIntervalSince1970)
        let geoCutoff = Int64(Date().addingTimeInterval(-30 * 86_400).timeIntervalSince1970)
        exec("DELETE FROM app_usage WHERE bucket < \(cutoff)")
        exec("DELETE FROM totals WHERE bucket < \(cutoff)")
        exec("DELETE FROM geo_cache WHERE fetched < \(geoCutoff)")
        exec("DELETE FROM connection_log WHERE last_seen < \(cutoff)")
    }

    func clearAll() {
        exec("DELETE FROM app_usage; DELETE FROM totals; DELETE FROM known_apps; DELETE FROM geo_cache; DELETE FROM connection_log; DELETE FROM speed_tests;")
        exec("VACUUM")
    }

    // MARK: Reads

    func knownAppIDs() -> Set<String> {
        var result = Set<String>()
        withStatement("SELECT app_id FROM known_apps") { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW { result.insert(text(stmt, 0)) }
        }
        return result
    }

    func allGeo() -> [String: GeoInfo] {
        var result: [String: GeoInfo] = [:]
        let decoder = JSONDecoder()
        withStatement("SELECT ip, json FROM geo_cache") { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                let ip = text(stmt, 0)
                if let blob = sqlite3_column_blob(stmt, 1) {
                    let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 1)))
                    if let info = try? decoder.decode(GeoInfo.self, from: data) { result[ip] = info }
                }
            }
        }
        return result
    }

    /// Machine totals bucketed by hour (or by `bucketSeconds`).
    func totals(from: Date, to: Date, bucketSeconds: Int = 3600) -> [UsagePoint] {
        var result: [UsagePoint] = []
        withStatement("""
        SELECT (bucket / ?) * ?, SUM(bytes_in), SUM(bytes_out) FROM totals
        WHERE bucket >= ? AND bucket < ? GROUP BY 1 ORDER BY 1
        """) { stmt in
            sqlite3_bind_int64(stmt, 1, Int64(bucketSeconds))
            sqlite3_bind_int64(stmt, 2, Int64(bucketSeconds))
            sqlite3_bind_int64(stmt, 3, Int64(from.timeIntervalSince1970))
            sqlite3_bind_int64(stmt, 4, Int64(to.timeIntervalSince1970))
            while sqlite3_step(stmt) == SQLITE_ROW {
                result.append(UsagePoint(start: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 0))),
                                         bytesIn: UInt64(sqlite3_column_int64(stmt, 1)),
                                         bytesOut: UInt64(sqlite3_column_int64(stmt, 2))))
            }
        }
        return result
    }

    func topApps(from: Date, to: Date, limit: Int = 25) -> [AppUsage] {
        var result: [AppUsage] = []
        withStatement("""
        SELECT app_id, MAX(name), SUM(bytes_in), SUM(bytes_out) FROM app_usage
        WHERE bucket >= ? AND bucket < ? GROUP BY app_id ORDER BY SUM(bytes_in) + SUM(bytes_out) DESC LIMIT ?
        """) { stmt in
            sqlite3_bind_int64(stmt, 1, Int64(from.timeIntervalSince1970))
            sqlite3_bind_int64(stmt, 2, Int64(to.timeIntervalSince1970))
            sqlite3_bind_int64(stmt, 3, Int64(limit))
            while sqlite3_step(stmt) == SQLITE_ROW {
                result.append(AppUsage(appID: text(stmt, 0), name: text(stmt, 1),
                                       bytesIn: UInt64(sqlite3_column_int64(stmt, 2)),
                                       bytesOut: UInt64(sqlite3_column_int64(stmt, 3))))
            }
        }
        return result
    }

    func appSeries(appID: String, from: Date, to: Date, bucketSeconds: Int = 3600) -> [UsagePoint] {
        var result: [UsagePoint] = []
        withStatement("""
        SELECT (bucket / ?) * ?, SUM(bytes_in), SUM(bytes_out) FROM app_usage
        WHERE app_id = ? AND bucket >= ? AND bucket < ? GROUP BY 1 ORDER BY 1
        """) { stmt in
            sqlite3_bind_int64(stmt, 1, Int64(bucketSeconds))
            sqlite3_bind_int64(stmt, 2, Int64(bucketSeconds))
            sqlite3_bind_text(stmt, 3, appID, -1, Self.transient)
            sqlite3_bind_int64(stmt, 4, Int64(from.timeIntervalSince1970))
            sqlite3_bind_int64(stmt, 5, Int64(to.timeIntervalSince1970))
            while sqlite3_step(stmt) == SQLITE_ROW {
                result.append(UsagePoint(start: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 0))),
                                         bytesIn: UInt64(sqlite3_column_int64(stmt, 1)),
                                         bytesOut: UInt64(sqlite3_column_int64(stmt, 2))))
            }
        }
        return result
    }

    func databaseSize() -> Int64 {
        let paths = [url.path, url.path + "-wal"]
        return paths.reduce(0) { sum, path in
            sum + ((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0)
        }
    }

    // MARK: Helpers

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func withStatement(_ sql: String, _ body: (OpaquePointer) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        body(stmt)
    }

    private func optionalText(_ stmt: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_type(stmt, column) == SQLITE_NULL ? nil : text(stmt, column)
    }

    private func bindText(_ stmt: OpaquePointer, _ index: Int32, _ value: String?) {
        if let value { sqlite3_bind_text(stmt, index, value, -1, Self.transient) } else { sqlite3_bind_null(stmt, index) }
    }

    private func text(_ stmt: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(stmt, column).map { String(cString: $0) } ?? ""
    }
}
