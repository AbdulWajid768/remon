import Foundation
import Testing
@testable import Remon

@Suite("nettop parser")
struct NettopParserTests {
    static let sample = """
    ,interface,state,bytes_in,bytes_out,rtt_avg,
    apsd.370,,,218633,46251,,
    tcp4 172.20.10.2:55157<->17.188.185.135:5223,en0,Established,218633,46251,435.62 ms,
    mDNSResponder.513,,,10836091,10148512,,
    udp6 *.5353<->*.*,en0,,5267198,5154320,,
    udp4 *:*<->*:*,,,,,,
    Google Chrome H.26068,,,100,200,,
    quic4 172.20.10.2:61002<->8.8.4.4:443,en0,,40960,22867,,
    tcp6 fe80::a995:4944:ce22:723d%utun4.1025<->fe80::12c5:2265:fe77:eacf%utun4.1026,utun4,Established,969,973,259.84 ms,
    ,interface,state,bytes_in,bytes_out,rtt_avg,
    """

    @Test func parsesFrameOnNextHeader() throws {
        var parser = NettopParser()
        var frames: [NettopFrame] = []
        for line in Self.sample.split(separator: "\n") {
            if let frame = parser.consume(String(line)) { frames.append(frame) }
        }
        #expect(frames.count == 1)
        let frame = try #require(frames.first)
        #expect(frame.processes.map(\.name) == ["apsd", "mDNSResponder", "Google Chrome H"])
        #expect(frame.processes.map(\.pid) == [370, 513, 26068])

        let apsd = frame.processes[0]
        #expect(apsd.bytesIn == 218633)
        #expect(apsd.connections.count == 1)
        let conn = apsd.connections[0]
        #expect(conn.proto == .tcp)
        #expect(conn.family == .v4)
        #expect(conn.local == Endpoint(address: "172.20.10.2", port: 55157))
        #expect(conn.remote == Endpoint(address: "17.188.185.135", port: 5223))
        #expect(conn.state == "Established")
        #expect(conn.interface == "en0")
        #expect(conn.rttMs == 435.62)

        // Fully wildcard UDP sockets are dropped; bound ones are kept.
        #expect(frame.processes[1].connections.count == 1)
        #expect(frame.processes[1].connections[0].local == Endpoint(address: "*", port: 5353))
        #expect(frame.processes[1].connections[0].remote.isWildcardAddress)

        let chrome = frame.processes[2]
        #expect(chrome.connections.first?.proto == .quic)
        let v6 = try #require(chrome.connections.last)
        #expect(v6.family == .v6)
        #expect(v6.local.port == 1025)
        #expect(v6.local.bareAddress == "fe80::a995:4944:ce22:723d")
    }

    @Test func handlesReorderedColumns() {
        var parser = NettopParser()
        _ = parser.consume(",bytes_out,bytes_in,")
        _ = parser.consume("proc.1,5,7,")
        let frame = parser.flush()
        #expect(frame?.processes.first?.bytesIn == 7)
        #expect(frame?.processes.first?.bytesOut == 5)
    }

    @Test func processNamesWithDots() {
        var parser = NettopParser()
        _ = parser.consume(",bytes_in,bytes_out,")
        _ = parser.consume("com.apple.WebKit.42,1,2,")
        #expect(parser.flush()?.processes.first?.name == "com.apple.WebKit")
    }
}

@Suite("search query")
struct SearchQueryTests {
    func connection(app: String = "Google Chrome", host: String? = "lhr25s34-in-f14.1e100.net", port: UInt16 = 443,
                    proto: TransportProtocol = .tcp, country: String = "GB") -> ConnectionInfo {
        var c = ConnectionInfo(id: "x", pid: 42, processName: "Google Chrome H", appID: "/Applications/Google Chrome.app",
                               appName: app, proto: proto, family: .v4, local: Endpoint(address: "10.0.0.2", port: 50000),
                               remote: Endpoint(address: "142.250.180.14", port: port), state: "Established",
                               interface: "en0", firstSeen: .now, lastSeen: .now)
        c.hostname = host
        c.geo = GeoInfo(scope: .publicInternet, countryCode: country, country: "United Kingdom", city: "London", org: "Google LLC")
        return c
    }

    @Test func tokenizesQuotes() {
        #expect(SearchQuery.tokenize("app:\"Google Chrome\" port:443") == ["app:Google Chrome", "port:443"])
    }

    @Test func filters() {
        let c = connection()
        #expect(SearchQuery("chrome").matches(c))
        #expect(SearchQuery("app:\"google chrome\" port:443").matches(c))
        #expect(SearchQuery("port:https").matches(c))
        #expect(!SearchQuery("port:80").matches(c))
        #expect(SearchQuery("country:gb").matches(c))
        #expect(SearchQuery("london").matches(c))
        #expect(SearchQuery("proto:tcp").matches(c))
        #expect(!SearchQuery("proto:udp").matches(c))
        #expect(SearchQuery("cat:google").matches(c))
        #expect(!SearchQuery("-chrome").matches(c))
        #expect(SearchQuery("-cat:apple").matches(c))
        #expect(SearchQuery("pid:42").matches(c))
    }

    @Test func unknownKeyIsFreeText() {
        let q = SearchQuery("foo:bar")
        #expect(q.terms == [SearchQuery.Term(key: nil, value: "foo:bar", negated: false)])
    }
}

@Suite("classification")
struct ClassificationTests {
    @Test(arguments: [
        ("10.1.2.3", AddressScope.privateNetwork), ("192.168.0.1", .privateNetwork), ("172.20.10.2", .privateNetwork),
        ("172.32.0.1", .publicInternet), ("127.0.0.1", .loopback), ("169.254.1.1", .linkLocal), ("100.64.0.1", .carrierNAT),
        ("224.0.0.251", .multicast), ("8.8.8.8", .publicInternet), ("::1", .loopback), ("fe80::1%en0", .linkLocal),
        ("fd00::1", .privateNetwork), ("ff02::fb", .multicast), ("2606:4700::1111", .publicInternet),
        ("::ffff:192.168.1.1", .privateNetwork), ("*", .unspecified),
    ])
    func scopes(address: String, expected: AddressScope) {
        #expect(IPClassifier.scope(of: address) == expected)
    }

    @Test func categories() {
        #expect(DestinationCategory.classify(host: "gateway.icloud.com", org: nil, scope: .publicInternet) == .apple)
        #expect(DestinationCategory.classify(host: "app-measurement.com", org: "Google LLC", scope: .publicInternet) == .telemetry)
        #expect(DestinationCategory.classify(host: nil, org: "Cloudflare, Inc.", scope: .publicInternet) == .cloudflare)
        #expect(DestinationCategory.classify(host: "x.1e100.net", org: nil, scope: .publicInternet) == .google)
        #expect(DestinationCategory.classify(host: nil, org: nil, scope: .privateNetwork) == .local)
        #expect(DestinationCategory.classify(host: nil, org: nil, scope: .publicInternet) == .unknown)
    }

    @Test func flags() {
        #expect(GeoInfo.flag(for: "US") == "🇺🇸")
        #expect(GeoInfo.flag(for: "") == "🌐")
    }

    @Test func helperGrouping() {
        let path = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"
        #expect(ProcessResolver.enclosingBundle(of: path, outermost: true) == "/Applications/Google Chrome.app")
        #expect(ProcessResolver.enclosingBundle(of: path, outermost: false)?.hasSuffix("Google Chrome Helper.app") == true)
        #expect(ProcessResolver.enclosingBundle(of: "/usr/sbin/mDNSResponder", outermost: true) == nil)
    }
}

@Suite("formatting")
struct FormattingTests {
    @Test func bytes() {
        #expect(ByteFormat.bytes(UInt64(0)) == "0 B")
        #expect(ByteFormat.bytes(UInt64(999)) == "999 B")
        #expect(ByteFormat.bytes(UInt64(1_500)) == "1.50 KB")
        #expect(ByteFormat.bytes(UInt64(25_300_000)) == "25.3 MB")
        #expect(ByteFormat.bytes(UInt64(512_000_000_000)) == "512 GB")
    }

    @Test func rates() {
        #expect(ByteFormat.rate(1_250_000) == "1.25 MB/s")
        #expect(ByteFormat.rate(1_250_000, bits: true) == "10.0 Mbps")
        #expect(ByteFormat.compactRate(820_000) == "820 KB")
    }

    @Test func parse() {
        #expect(ByteFormat.parse("5 MB") == 5_000_000)
        #expect(ByteFormat.parse("1.5g") == 1_500_000_000)
        #expect(ByteFormat.parse("abc") == nil)
    }

    @Test func exportEncoding() throws {
        let rows = [["app": "Google Chrome", "bytes": "10"], ["app": "Say \"hi\", ok", "bytes": "2"]]
        let csv = String(decoding: try ExportService.encode(rows, columns: ["app", "bytes"], format: .csv), as: UTF8.self)
        #expect(csv == "app,bytes\nGoogle Chrome,10\n\"Say \"\"hi\"\", ok\",2\n")
        let json = try ExportService.encode(rows, columns: ["app", "bytes"], format: .json)
        let decoded = try JSONDecoder().decode([[String: String]].self, from: json)
        #expect(decoded == rows)
    }

    @Test func csvEscape() {
        #expect(ExportService.csvEscape("plain") == "plain")
        #expect(ExportService.csvEscape("a,b") == "\"a,b\"")
        #expect(ExportService.csvEscape("say \"hi\"") == "\"say \"\"hi\"\"\"")
    }
}

@Suite("history store")
struct HistoryStoreTests {
    @Test func roundTrip() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("remon-test-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try HistoryStore(url: url)
        let now = Date()
        let bucket = MonitorStore.minuteStart(now)
        await store.record(bucket: bucket, apps: [UsageDelta(appID: "a", name: "Alpha", bytesIn: 100, bytesOut: 10),
                                                  UsageDelta(appID: "b", name: "Beta", bytesIn: 5, bytesOut: 5)],
                           totalIn: 200, totalOut: 20)
        // Upserts accumulate within the same bucket.
        await store.record(bucket: bucket, apps: [UsageDelta(appID: "a", name: "Alpha", bytesIn: 50, bytesOut: 0)], totalIn: 50, totalOut: 0)

        let top = await store.topApps(from: now.addingTimeInterval(-3600), to: now.addingTimeInterval(3600))
        #expect(top.map(\.appID) == ["a", "b"])
        #expect(top.first?.bytesIn == 150)

        let totals = await store.totals(from: now.addingTimeInterval(-7200), to: now.addingTimeInterval(3600))
        #expect(totals.reduce(0) { $0 + $1.bytesIn } == 250)

        await store.markKnown([("a", "Alpha")])
        #expect(await store.knownAppIDs() == ["a"])

        await store.saveGeo("8.8.8.8", GeoInfo(scope: .publicInternet, countryCode: "US", country: "United States"))
        #expect(await store.allGeo()["8.8.8.8"]?.countryCode == "US")

        await store.clearAll()
        #expect(await store.topApps(from: .distantPast, to: .distantFuture).isEmpty)
    }
}

@Suite("system counters")
struct SystemCounterTests {
    @Test func interfaceCountersAreReadable() {
        let counters = InterfaceCounters.read()
        #expect(counters.contains { $0.name == "lo0" })
        #expect(counters.contains { $0.bytesIn > 0 })
    }

    @Test func ownExecutableResolves() {
        let identity = ProcessResolver.resolve(pid: getpid(), comm: "Remon", groupHelpers: true)
        #expect(identity.executablePath != nil)
    }
}

@Suite("insights")
struct InsightsTests {
    let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    @Test func cycleAfterResetDay() {
        let cycle = BillingCycle.current(containing: date(2026, 10, 20), resetDay: 15, calendar: calendar)
        #expect(cycle.start == calendar.startOfDay(for: date(2026, 10, 15)))
        #expect(cycle.end == calendar.startOfDay(for: date(2026, 11, 15)))
    }

    @Test func cycleBeforeResetDayWrapsToPreviousMonth() {
        let cycle = BillingCycle.current(containing: date(2026, 1, 3), resetDay: 15, calendar: calendar)
        #expect(cycle.start == calendar.startOfDay(for: date(2025, 12, 15)))
        #expect(cycle.end == calendar.startOfDay(for: date(2026, 1, 15)))
    }

    @Test func resetDayIsClamped() {
        let cycle = BillingCycle.current(containing: date(2026, 2, 28), resetDay: 31, calendar: calendar)
        #expect(cycle.start == calendar.startOfDay(for: date(2026, 2, 28)))
    }

    @Test func projection() {
        let cycle = BillingCycle(start: date(2026, 10, 1, 0), end: date(2026, 10, 31, 0))
        #expect(cycle.projectedUsage(used: 10_000, at: date(2026, 10, 16, 0)) == 20_000)
    }

    @Test func anomalies() {
        let mb: UInt64 = 1_000_000
        #expect(UsageAnomaly.ratio(today: 600 * mb, history: [100 * mb, 100 * mb, 100 * mb]) == 6)
        #expect(UsageAnomaly.ratio(today: 200 * mb, history: [100 * mb, 100 * mb, 100 * mb]) == nil) // only 2×
        #expect(UsageAnomaly.ratio(today: 40 * mb, history: [1 * mb, 1 * mb, 1 * mb]) == nil)       // too small
        #expect(UsageAnomaly.ratio(today: 600 * mb, history: [100 * mb]) == nil)                   // too little history
    }

    @Test func speedTestParsing() throws {
        let json = #"{"dl_throughput": 245000000, "ul_throughput": 41000000, "responsiveness": 1520.5, "base_rtt": 18.2, "interface_name": "en0"}"#
        let result = try SpeedTestRunner.parse(Data(json.utf8))
        #expect(result.download == 245_000_000)
        #expect(result.upload == 41_000_000)
        #expect(result.responsivenessRPM == 1520.5)
        #expect(result.responsivenessRating == "High")
        #expect(result.interface == "en0")
        #expect(throws: SpeedTestError.self) { try SpeedTestRunner.parse(Data(#"{"error_code": "x"}"#.utf8)) }
    }

    @Test func codeSignatures() {
        #expect(CodeSignatureInspector.inspect(path: "/System/Applications/Calculator.app").status == .apple)
        #expect(CodeSignatureInspector.inspect(path: "/usr/sbin/mDNSResponder").status == .apple)
        let unsigned = FileManager.default.temporaryDirectory.appendingPathComponent("remon-unsigned-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: unsigned.path, contents: Data("#!/bin/sh\necho hi\n".utf8))
        defer { try? FileManager.default.removeItem(at: unsigned) }
        #expect(CodeSignatureInspector.inspect(path: unsigned.path).status == .unsigned)
    }

    @Test func connectionLogRoundTrip() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("remon-log-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try HistoryStore(url: url)
        let now = Date()
        let entry = ConnectionLogEntry(appID: "/Applications/Safari.app", appName: "Safari", proto: "TCP", remoteIP: "17.253.144.10",
                                       remotePort: 443, hostname: "www.apple.com", countryCode: "US", city: "Cupertino",
                                       org: "Apple Inc.", category: "Apple", firstSeen: now.addingTimeInterval(-30), lastSeen: now,
                                       bytesIn: 1000, bytesOut: 200)
        var other = entry
        other.appName = "Mail"
        other.hostname = nil
        other.countryCode = "IE"
        await store.logConnections([entry, other])
        #expect(await store.connectionLog(search: nil, since: .distantPast).count == 2)
        let hits = await store.connectionLog(search: "apple.com", since: .distantPast)
        #expect(hits.map(\.appName) == ["Safari"])
        #expect(hits.first?.totalBytes == 1200)
        #expect(await store.connectionLog(search: "IE", since: .distantPast).map(\.appName) == ["Mail"])
        #expect(await store.connectionLog(search: nil, since: now.addingTimeInterval(60)).isEmpty)
    }
}

@Suite("blocking")
struct BlockingTests {
    @Test func domainNormalization() {
        #expect(FirewallScript.normalizedDomain("  SWSCAN.apple.com ") == "swscan.apple.com")
        #expect(FirewallScript.normalizedDomain("https://updates.cdn-apple.com/path?x=1") == "updates.cdn-apple.com")
        #expect(FirewallScript.normalizedDomain("*.example.org") == "example.org")
        #expect(FirewallScript.normalizedDomain("localhost") == nil)
        #expect(FirewallScript.normalizedDomain("bad domain.com") == nil)
        #expect(FirewallScript.normalizedDomain("evil.com'; rm -rf /") == nil)
        #expect(FirewallScript.normalizedDomain("-x.com") == nil)
    }

    @Test func addressNormalization() {
        #expect(FirewallScript.normalizedAddress("17.253.144.10") == "17.253.144.10")
        #expect(FirewallScript.normalizedAddress("2606:4700::1111") == "2606:4700::1111")
        #expect(FirewallScript.normalizedAddress("1.2.3") == nil)
        #expect(FirewallScript.normalizedAddress("1.2.3.4; reboot") == nil)
    }

    @Test func pfRules() {
        #expect(FirewallScript.pfRules(addresses: ["1.2.3.4", "2001:db8::1"]) == [
            "block drop out quick inet from any to 1.2.3.4", "block drop in quick inet from 1.2.3.4 to any",
            "block drop out quick inet6 from any to 2001:db8::1", "block drop in quick inet6 from 2001:db8::1 to any",
        ])
    }

    @Test func pfAcceptsGeneratedRules() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("remon-pf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        let rules = FirewallScript.pfRules(addresses: ["17.253.144.10", "2606:4700::1111"]).joined(separator: "\n") + "\n"
        try rules.write(to: file, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/sbin/pfctl")
        p.arguments = ["-n", "-f", file.path] // parse only; no root needed
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
    }

    @Test func hostsScriptRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("remon-hosts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let hosts = dir.appendingPathComponent("hosts")
        let original = "127.0.0.1\tlocalhost\n255.255.255.255\tbroadcasthost\n::1             localhost\n"
        try original.write(to: hosts, atomically: true, encoding: .utf8)

        func run(_ domains: [String]) throws -> String {
            let script = FirewallScript.shell(domains: domains, addresses: [], kill: [], hostsPath: hosts.path, pfctl: nil)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", script]
            try p.run()
            p.waitUntilExit()
            #expect(p.terminationStatus == 0)
            return try String(contentsOf: hosts, encoding: .utf8)
        }

        let blocked = try run(["swscan.apple.com", "mesu.apple.com"])
        #expect(blocked.hasPrefix(original))
        #expect(blocked.contains("0.0.0.0 swscan.apple.com\n:: swscan.apple.com"))
        #expect(FirewallScript.activeDomains(inHosts: blocked) == ["swscan.apple.com", "mesu.apple.com"])

        // Re-applying replaces the managed block instead of appending another one.
        let replaced = try run(["mesu.apple.com"])
        #expect(FirewallScript.activeDomains(inHosts: replaced) == ["mesu.apple.com"])
        #expect(replaced.components(separatedBy: FirewallScript.beginMarker).count == 2)

        // Unblocking everything restores the original file exactly.
        #expect(try run([]) == original)
        #expect(FileManager.default.fileExists(atPath: hosts.path + ".remon-backup"))
    }

    @Test func appleScriptEscaping() {
        let script = FirewallScript.shell(domains: ["a.com"], addresses: ["1.2.3.4"], kill: ["1.2.3.4"])
        let escaped = FirewallScript.appleScriptEscaped(script)
        #expect(!escaped.contains("\\n'") || escaped.contains("\\\\n"))
        #expect(!escaped.replacingOccurrences(of: "\\\"", with: "").contains("\""))
        #expect(script.contains("/sbin/pfctl -q -a 'com.apple/remon' -f \"$P\""))
        #expect(script.contains("/sbin/pfctl -q -k 0.0.0.0/0 -k 1.2.3.4"))
    }
}

@Suite("system metrics")
struct SystemMetricsTests {
    @Test func samplerReadsLiveValues() async {
        let sampler = SystemSampler()
        _ = await sampler.sample()
        try? await Task.sleep(for: .milliseconds(300))
        let s = await sampler.sample()
        #expect(!s.perCore.isEmpty)
        #expect(s.perCore.allSatisfy { (0...1).contains($0) })
        #expect(s.memory.total > 0 && s.memory.used > 0 && s.memory.used <= s.memory.total)
        #expect(s.uptime > 0)
        #expect(s.loadAverage.count == 3)
    }
}

@Suite("battery health")
struct BatteryHealthTests {
    @Test func parsesSystemProfilerJSON() {
        let json = #"{"SPPowerDataType":[{"_name":"spbattery_information","sppower_battery_health_info":{"sppower_battery_cycle_count":66,"sppower_battery_health":"Good","sppower_battery_health_maximum_capacity":"99%"}}]}"#
        let health = BatteryHealthReader.parse(Data(json.utf8))
        #expect(health?.maximumCapacity == 0.99)
        #expect(health?.condition == "Normal")
    }

    @Test func noBatteryMeansNil() {
        #expect(BatteryHealthReader.parse(Data(#"{"SPPowerDataType":[{"_name":"sppower_ac_charger_information"}]}"#.utf8)) == nil)
    }

    @Test func matchesSystemInformationOnThisMac() throws {
        // On a Mac with a battery, Remon must show exactly what System Information shows.
        guard let health = BatteryHealthReader.read() else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        p.arguments = ["SPPowerDataType"]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        if let max = health.maximumCapacity {
            #expect(text.contains("Maximum Capacity: \(Int((max * 100).rounded()))%"))
        }
    }
}
