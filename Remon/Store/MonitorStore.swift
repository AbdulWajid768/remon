import AppKit
import Foundation
import Observation

enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case overview = "Overview"
    case system = "System"
    case apps = "Apps"
    case connections = "Connections"
    case map = "Map"
    case history = "History"
    case log = "Log"
    case speedTest = "Speed Test"
    case alerts = "Alerts"
    case rules = "Rules"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .system: "cpu"
        case .apps: "square.grid.2x2"
        case .connections: "point.3.filled.connected.trianglepath.dotted"
        case .map: "map"
        case .history: "chart.bar.xaxis"
        case .log: "list.bullet.rectangle"
        case .speedTest: "speedometer"
        case .alerts: "bell.badge"
        case .rules: "hand.raised"
        }
    }

    var shortcut: Character? {
        switch self {
        case .overview: "1"
        case .system: "2"
        case .apps: "3"
        case .connections: "4"
        case .map: "5"
        case .history: "6"
        case .log: "7"
        case .speedTest: "8"
        case .alerts: "9"
        case .rules: nil
        }
    }

    var hasInspector: Bool { self == .apps || self == .connections }

    static let monitorSections: [SidebarSection] = [.overview, .system, .apps, .connections, .map, .history, .log]
    static let toolSections: [SidebarSection] = [.speedTest, .alerts, .rules]
}

/// Central live state. Consumes the traffic source and interface counters, computes rates,
/// resolves names, writes history, and drives alerts.
@MainActor @Observable
final class MonitorStore {
    static let shared = MonitorStore()

    let preferences: Preferences
    let path = NetworkPathObserver()
    let alerts: AlertCenter
    let policy = PolicyCenter()
    let environment = NetworkEnvironment()
    @ObservationIgnored let history: HistoryStore?
    @ObservationIgnored private let source: TrafficSource
    @ObservationIgnored private let resolver = ProcessResolver()
    @ObservationIgnored private let hostResolver = HostnameResolver()
    @ObservationIgnored private let onlineGeo = IPWhoIsGeoLocator()
    @ObservationIgnored private let signatureCache = SignatureCache()
    /// Opens (or focuses) the main window; installed by a view that has `openWindow`.
    @ObservationIgnored var openMainWindow: (() -> Void)?
    /// Shows/hides the floating HUD window; installed alongside `openMainWindow`.
    @ObservationIgnored var toggleHUD: (() -> Void)?

    // MARK: Published live state
    private(set) var apps: [AppTraffic] = []
    private(set) var connections: [ConnectionInfo] = []
    private(set) var interfaces: [InterfaceStats] = []
    private(set) var throughput: [ThroughputPoint] = []
    private(set) var currentIn: Double = 0
    private(set) var currentOut: Double = 0
    private(set) var sessionIn: UInt64 = 0
    private(set) var sessionOut: UInt64 = 0
    private(set) var attributedIn: UInt64 = 0
    private(set) var attributedOut: UInt64 = 0
    private(set) var todayIn: UInt64 = 0
    private(set) var todayOut: UInt64 = 0
    private(set) var peakIn: Double = 0
    private(set) var peakOut: Double = 0
    private(set) var sourceStatus: SourceStatus = .starting
    private(set) var startedAt = Date()
    private(set) var historyError: String?
    private(set) var lastHistoryWrite: Date?
    private(set) var signing: [String: SigningInfo] = [:]
    private(set) var billingCycle = BillingCycle.current(containing: Date(), resetDay: 1)
    private(set) var cycleUsage: UInt64 = 0
    private(set) var speedTestRunning = false
    private(set) var speedTestStarted: Date?
    private(set) var speedTestResults: [SpeedTestResult] = []
    private(set) var speedTestError: String?
    private(set) var logRevision = 0

    // MARK: UI state shared with commands and the menu bar
    var isPaused = false
    var section: SidebarSection = .overview
    var searchText = ""
    var showInspector = true
    var isQuickOpenPresented = false
    var selectedAppID: String?
    var selectedConnectionID: String?
    var connectionScope: ConnectionScope = .active
    var showOnboarding = false
    var isHUDVisible = false
    /// Bumped by the Find command (⌘F) to move focus into the toolbar search field.
    var focusSearchRequest = 0

    static let throughputWindow = 300
    static let appHistoryLength = 120

    // MARK: Internal bookkeeping
    private struct ProcessCounter { var name: String; var bytesIn: UInt64; var bytesOut: UInt64; var lastSeen: Date }
    private struct IfaceCounter { var bytesIn: UInt64; var bytesOut: UInt64 }

    @ObservationIgnored private var hostnames: [String: String] = [:]
    @ObservationIgnored private var geo: [String: GeoInfo] = [:]
    @ObservationIgnored private var requested: Set<String> = []
    @ObservationIgnored private var prevProcess: [Int32: ProcessCounter] = [:]
    @ObservationIgnored private var connState: [String: ConnectionInfo] = [:]
    @ObservationIgnored private var appState: [String: AppTraffic] = [:]
    @ObservationIgnored private var prevIface: [String: IfaceCounter] = [:]
    @ObservationIgnored private var lastFrameDate: Date?
    @ObservationIgnored private var lastIfaceDate: Date?
    @ObservationIgnored private var frameCount = 0
    @ObservationIgnored private var ifaceTicks = 0
    @ObservationIgnored private var addressCache: [String: [String]] = [:]
    @ObservationIgnored private var pendingApps: [String: UsageDelta] = [:]
    @ObservationIgnored private var pendingTotalIn: UInt64 = 0
    @ObservationIgnored private var pendingTotalOut: UInt64 = 0
    @ObservationIgnored private var pendingBucket = MonitorStore.minuteStart(Date())
    @ObservationIgnored private var knownApps: Set<String> = []
    @ObservationIgnored private var learningUntil: Date?
    @ObservationIgnored private var knownAppsLoaded = false
    @ObservationIgnored private var pendingNewApps: [AppIdentity] = []
    @ObservationIgnored private var pipelineTask: Task<Void, Never>?
    @ObservationIgnored private var interfaceTask: Task<Void, Never>?
    @ObservationIgnored private var housekeepingTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var started = false
    @ObservationIgnored private var autoSelectTop = false
    @ObservationIgnored private var pendingLog: [ConnectionLogEntry] = []
    @ObservationIgnored private var signingRequested: Set<String> = []
    @ObservationIgnored private var insightTicks = 0
    @ObservationIgnored private var firedPlanKeys = Set(UserDefaults.standard.stringArray(forKey: "firedDataPlanKeys") ?? [])
    @ObservationIgnored private var lastVPNState: Bool?

    init(preferences: Preferences = .shared, source: TrafficSource = NettopTrafficSource()) {
        self.preferences = preferences
        self.source = source
        self.alerts = AlertCenter(preferences: preferences)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Remon", isDirectory: true)
        do {
            history = try HistoryStore(url: support.appendingPathComponent("history.sqlite"))
        } catch {
            history = nil
            historyError = error.localizedDescription
        }
        showOnboarding = !preferences.hasCompletedOnboarding
        // Launch arguments for demos/screenshots, e.g. `-initialSection connections`.
        if let raw = UserDefaults.standard.string(forKey: "initialSection"),
           let section = SidebarSection.allCases.first(where: { $0.rawValue.lowercased() == raw.lowercased() }) {
            self.section = section
        }
        if UserDefaults.standard.bool(forKey: "skipOnboarding") { showOnboarding = false }
        autoSelectTop = UserDefaults.standard.bool(forKey: "selectTop")
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        NettopTrafficSource.reapOrphans()
        startedAt = Date()
        Task {
            if let history {
                knownApps = await history.knownAppIDs()
                if knownApps.isEmpty { learningUntil = Date().addingTimeInterval(60) }
                knownAppsLoaded = true
                let cached = await history.allGeo()
                geo.merge(cached) { current, _ in current }
                let startOfDay = Calendar.current.startOfDay(for: Date())
                let today = await history.totals(from: startOfDay, to: Date().addingTimeInterval(3600))
                todayIn += today.reduce(0) { $0 + $1.bytesIn }
                todayOut += today.reduce(0) { $0 + $1.bytesOut }
                await history.prune(retentionDays: preferences.retentionDays)
            } else {
                learningUntil = Date().addingTimeInterval(60)
                knownAppsLoaded = true
            }
            await alerts.refreshAuthorization()
        }
        startPipelines()
        environment.start { [weak self] in self?.preferences.geoLookups ?? false }
        environment.onPublicIPChange = { [weak self] old, new in
            self?.alerts.report(.publicIP, key: "ip-\(new)", message: "Your public IP changed from \(old ?? "unknown") to \(new).")
        }
        path.onConnectivityChange = { [weak self] connected in
            guard let self else { return }
            self.alerts.report(.connectivity, key: connected ? "up" : "down",
                               message: connected ? "This Mac is back online (\(self.path.statusText))." : "This Mac lost its network connection.")
            if connected, self.preferences.geoLookups { Task { await self.environment.refreshPublicIP() } }
        }
        housekeepingTask = Task { [weak self] in
            var minutes = 0
            while !Task.isCancelled {
                guard let self else { return }
                await self.runInsights(checkAnomalies: minutes % 10 == 0)
                if minutes % 10 == 0, let history = self.history {
                    await history.prune(retentionDays: self.preferences.retentionDays)
                }
                minutes += 1
                try? await Task.sleep(for: .seconds(60))
            }
        }
        Task {
            if let history { speedTestResults = await history.speedTests() }
        }
    }

    /// Stops sampling and terminates the nettop child.
    func stop() {
        pipelineTask?.cancel()
        interfaceTask?.cancel()
        housekeepingTask?.cancel()
    }

    /// Restarts sampling after a preference change (interval, loopback, grouping).
    func restartMonitoring() {
        pipelineTask?.cancel()
        interfaceTask?.cancel()
        prevProcess.removeAll()
        connState.removeAll()
        lastFrameDate = nil
        frameCount = 0
        // Identities change shape when helper grouping toggles; rebuild app aggregates.
        appState.removeAll()
        startPipelines()
    }

    private func startPipelines() {
        generation += 1
        let gen = generation
        pipelineTask = Task { [weak self] in await self?.runPipeline(generation: gen) }
        interfaceTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.sampleInterfaces()
                let interval = self.preferences.sampleInterval
                try? await Task.sleep(for: .seconds(max(1, interval)))
            }
        }
    }

    private func runPipeline(generation gen: Int) async {
        var attempt = 0
        while !Task.isCancelled && gen == generation {
            sourceStatus = .starting
            do {
                let stream = source.frames(interval: preferences.sampleInterval, includeLoopback: preferences.includeLoopback)
                for try await frame in stream {
                    guard gen == generation else { return }
                    if sourceStatus != .running { sourceStatus = .running; attempt = 0 }
                    await ingest(frame, generation: gen)
                }
                if Task.isCancelled { return }
                sourceStatus = .failed("nettop stopped unexpectedly; restarting…")
            } catch {
                if Task.isCancelled { return }
                sourceStatus = .failed(error.localizedDescription)
            }
            attempt += 1
            try? await Task.sleep(for: .seconds(min(30, 1 << min(attempt, 5))))
        }
    }

    struct PendingHistory: Sendable {
        var bucket: Date
        var apps: [UsageDelta]
        var totalIn: UInt64
        var totalOut: UInt64
        var log: [ConnectionLogEntry]
    }

    /// Hands over buffered (not yet written) usage and resets the buffer. When quitting, still-open
    /// connections are logged too.
    func takePendingHistory(includeOpenConnections: Bool = false) -> PendingHistory {
        var log = pendingLog
        if includeOpenConnections {
            log += connState.values.filter { !$0.isListening && !$0.isClosed }.map(Self.logEntry)
        }
        let pending = PendingHistory(bucket: pendingBucket, apps: Array(pendingApps.values),
                                     totalIn: pendingTotalIn, totalOut: pendingTotalOut, log: log)
        pendingLog.removeAll()
        pendingApps.removeAll()
        pendingTotalIn = 0
        pendingTotalOut = 0
        pendingBucket = Self.minuteStart(Date())
        return pending
    }

    /// Writes buffered history to disk.
    func flushHistory() async {
        guard let history else { return }
        let pending = takePendingHistory()
        await history.record(bucket: pending.bucket, apps: pending.apps, totalIn: pending.totalIn, totalOut: pending.totalOut)
        await history.logConnections(pending.log)
        lastHistoryWrite = Date()
        if !pending.log.isEmpty { logRevision += 1 }
    }

    static func logEntry(_ c: ConnectionInfo) -> ConnectionLogEntry {
        ConnectionLogEntry(appID: c.appID, appName: c.appName, proto: c.proto.rawValue, remoteIP: c.remote.bareAddress,
                           remotePort: Int(c.remote.port ?? 0), hostname: c.hostname, countryCode: c.geo?.countryCode,
                           city: c.geo?.city, org: c.geo?.org, category: c.category.rawValue, firstSeen: c.firstSeen,
                           lastSeen: c.lastSeen, bytesIn: c.totalIn, bytesOut: c.totalOut)
    }

    func clearHistory() async {
        await history?.clearAll()
        todayIn = 0
        todayOut = 0
        knownApps.removeAll()
    }

    // MARK: Frame ingestion (per-process / per-socket)

    private func ingest(_ frame: NettopFrame, generation gen: Int) async {
        let now = frame.timestamp
        let dt = max(0.25, lastFrameDate.map { now.timeIntervalSince($0) } ?? Double(preferences.sampleInterval))
        let isFirst = frameCount == 0
        let identities = await resolver.identities(for: frame.processes.map { ($0.pid, $0.name) },
                                                   groupHelpers: preferences.groupHelpers)
        guard gen == generation else { return }
        lastFrameDate = now
        frameCount += 1

        var deltaIn: [String: UInt64] = [:]
        var deltaOut: [String: UInt64] = [:]
        var pidsByApp: [String: Set<Int32>] = [:]
        var connCount: [String: Int] = [:]
        var identityByID: [String: AppIdentity] = [:]
        var seen = Set<String>()

        for process in frame.processes {
            guard let identity = identities[process.pid] else { continue }
            identityByID[identity.id] = identity
            pidsByApp[identity.id, default: []].insert(process.pid)

            var dIn: UInt64 = 0, dOut: UInt64 = 0
            if let prev = prevProcess[process.pid], prev.name == process.name {
                dIn = process.bytesIn >= prev.bytesIn ? process.bytesIn - prev.bytesIn : 0
                dOut = process.bytesOut >= prev.bytesOut ? process.bytesOut - prev.bytesOut : 0
            } else if !isFirst {
                dIn = process.bytesIn
                dOut = process.bytesOut
            }
            prevProcess[process.pid] = ProcessCounter(name: process.name, bytesIn: process.bytesIn,
                                                      bytesOut: process.bytesOut, lastSeen: now)
            deltaIn[identity.id, default: 0] += dIn
            deltaOut[identity.id, default: 0] += dOut

            for row in process.connections {
                let key = "\(process.pid)|\(row.proto.rawValue)|\(row.local.display)|\(row.remote.display)"
                seen.insert(key)
                let address = row.remote.bareAddress
                if var existing = connState[key] {
                    let ci = row.bytesIn >= existing.totalIn ? row.bytesIn - existing.totalIn : 0
                    let co = row.bytesOut >= existing.totalOut ? row.bytesOut - existing.totalOut : 0
                    existing.rateIn = Double(ci) / dt
                    existing.rateOut = Double(co) / dt
                    existing.totalIn = row.bytesIn
                    existing.totalOut = row.bytesOut
                    existing.state = row.state
                    existing.rttMs = row.rttMs ?? existing.rttMs
                    if !row.interface.isEmpty { existing.interface = row.interface }
                    existing.lastSeen = now
                    existing.isClosed = false
                    existing.appName = identity.name
                    existing.hostname = hostnames[address]
                    existing.geo = geo[address]
                    connState[key] = existing
                } else {
                    var info = ConnectionInfo(
                        id: key, pid: process.pid, processName: process.name, appID: identity.id, appName: identity.name,
                        proto: row.proto, family: row.family, local: row.local, remote: row.remote,
                        state: row.state, interface: row.interface, firstSeen: now, lastSeen: now)
                    info.totalIn = row.bytesIn
                    info.totalOut = row.bytesOut
                    info.rateIn = isFirst ? 0 : Double(row.bytesIn) / dt
                    info.rateOut = isFirst ? 0 : Double(row.bytesOut) / dt
                    info.rttMs = row.rttMs
                    info.hostname = hostnames[address]
                    info.geo = geo[address]
                    connState[key] = info
                    if !row.remote.isWildcardAddress { requestResolution(address) }
                }
                if !row.remote.isWildcardAddress { connCount[identity.id, default: 0] += 1 }
            }
        }

        // Recently closed sockets linger briefly, dimmed.
        for (key, var conn) in connState where !seen.contains(key) {
            if now.timeIntervalSince(conn.lastSeen) > 8 {
                if !conn.isListening { pendingLog.append(Self.logEntry(conn)) }
                connState[key] = nil
            } else if !conn.isClosed {
                conn.isClosed = true
                conn.rateIn = 0
                conn.rateOut = 0
                connState[key] = conn
            }
        }
        prevProcess = prevProcess.filter { now.timeIntervalSince($0.value.lastSeen) < 300 }
        if frameCount % 30 == 0 { await resolver.prune(keeping: Set(prevProcess.keys)) }

        // Per-app aggregates.
        var newlyKnown: [(id: String, name: String)] = []
        for (id, identity) in identityByID {
            var app = appState[id] ?? AppTraffic(identity: identity)
            app.identity = identity
            if !signingRequested.contains(id), let path = identity.bundlePath ?? identity.executablePath {
                signingRequested.insert(id)
                Task { [weak self] in
                    guard let self else { return }
                    let info = await self.signatureCache.info(for: path)
                    self.signing[id] = info
                }
            }
            let dIn = deltaIn[id] ?? 0, dOut = deltaOut[id] ?? 0
            app.rateIn = Double(dIn) / dt
            app.rateOut = Double(dOut) / dt
            app.sessionIn += dIn
            app.sessionOut += dOut
            app.pids = pidsByApp[id] ?? []
            app.connectionCount = connCount[id] ?? 0
            Self.appendCapped(&app.historyIn, app.rateIn)
            Self.appendCapped(&app.historyOut, app.rateOut)
            if dIn + dOut > 0 { app.lastActive = now }
            appState[id] = app

            attributedIn += dIn
            attributedOut += dOut
            if dIn + dOut > 0 {
                var pending = pendingApps[id] ?? UsageDelta(appID: id, name: identity.name, bytesIn: 0, bytesOut: 0)
                pending.bytesIn += dIn
                pending.bytesOut += dOut
                pending.name = identity.name
                pendingApps[id] = pending

                if knownAppsLoaded, !knownApps.contains(id) {
                    knownApps.insert(id)
                    newlyKnown.append((id, identity.name))
                    // First-ever run: learn silently instead of alerting about every app.
                    if let until = learningUntil, now < until { continue }
                    pendingNewApps.append(identity)
                }
            }
        }
        for (id, var app) in appState where identityByID[id] == nil {
            app.rateIn = 0
            app.rateOut = 0
            app.connectionCount = 0
            app.pids = []
            Self.appendCapped(&app.historyIn, 0)
            Self.appendCapped(&app.historyOut, 0)
            appState[id] = app
        }
        if let history, !newlyKnown.isEmpty {
            Task { await history.markKnown(newlyKnown) }
        }

        if !isPaused { publishLists() }
    }

    private func publishLists() {
        apps = appState.values.sorted {
            $0.totalRate != $1.totalRate ? $0.totalRate > $1.totalRate : $0.sessionTotal > $1.sessionTotal
        }
        connections = connState.values.sorted { $0.totalRate != $1.totalRate ? $0.totalRate > $1.totalRate : $0.id < $1.id }
        if autoSelectTop, frameCount > 3 {
            if selectedAppID == nil { selectedAppID = apps.first?.id }
            if selectedConnectionID == nil { selectedConnectionID = connections.first { !$0.isListening && $0.hostname != nil }?.id }
        }
    }

    func togglePause() {
        isPaused.toggle()
        if !isPaused { publishLists() }
    }

    // MARK: Interface counters (whole-machine throughput)

    private func sampleInterfaces() {
        let now = Date()
        let counters = InterfaceCounters.read()
        let dt = max(0.25, lastIfaceDate.map { now.timeIntervalSince($0) } ?? 1)
        let isFirst = lastIfaceDate == nil
        lastIfaceDate = now
        if ifaceTicks % 5 == 0 {
            addressCache = InterfaceCounters.addresses()
            environment.updateVPN(addresses: addressCache)
            let vpn = environment.isVPNActive
            if let last = lastVPNState, last != vpn {
                alerts.report(.publicIP, key: vpn ? "vpn-up" : "vpn-down",
                              message: vpn ? "A VPN tunnel came up (\(environment.vpnInterfaces.joined(separator: ", ")))."
                                           : "Your VPN disconnected — traffic now leaves through \(path.statusText).")
                if preferences.geoLookups { Task { await environment.refreshPublicIP() } }
            }
            lastVPNState = vpn
        }
        ifaceTicks += 1

        var totalIn: UInt64 = 0, totalOut: UInt64 = 0
        var stats: [InterfaceStats] = []
        var next: [String: IfaceCounter] = [:]
        for c in counters {
            let prev = prevIface[c.name]
            let dIn = prev.map { c.bytesIn >= $0.bytesIn ? c.bytesIn - $0.bytesIn : 0 } ?? 0
            let dOut = prev.map { c.bytesOut >= $0.bytesOut ? c.bytesOut - $0.bytesOut : 0 } ?? 0
            next[c.name] = IfaceCounter(bytesIn: c.bytesIn, bytesOut: c.bytesOut)
            if InterfaceCounters.countsTowardTotal(c.name) {
                totalIn += dIn
                totalOut += dOut
            }
            let addresses = addressCache[c.name] ?? []
            guard c.isUp, Self.isInterestingInterface(c, addresses: addresses, includeLoopback: preferences.includeLoopback) else { continue }
            let kind = InterfaceCounters.kind(for: c.name, pathHint: path.snapshot.kinds[c.name])
            stats.append(InterfaceStats(name: c.name, kind: kind, rateIn: Double(dIn) / dt, rateOut: Double(dOut) / dt,
                                        totalIn: c.bytesIn, totalOut: c.bytesOut, addresses: addresses, isUp: c.isUp))
        }
        prevIface = next
        guard !isFirst else { return }

        // Day rollover.
        if let last = throughput.last?.date, !Calendar.current.isDate(last, inSameDayAs: now) {
            todayIn = 0
            todayOut = 0
        }
        currentIn = Double(totalIn) / dt
        currentOut = Double(totalOut) / dt
        peakIn = max(peakIn, currentIn)
        peakOut = max(peakOut, currentOut)
        sessionIn += totalIn
        sessionOut += totalOut
        todayIn += totalIn
        todayOut += totalOut
        pendingTotalIn += totalIn
        pendingTotalOut += totalOut
        interfaces = stats.sorted { ($0.rateIn + $0.rateOut, $1.name) > ($1.rateIn + $1.rateOut, $0.name) }

        throughput.append(ThroughputPoint(date: now, rateIn: currentIn, rateOut: currentOut))
        if throughput.count > Self.throughputWindow { throughput.removeFirst(throughput.count - Self.throughputWindow) }

        if Self.minuteStart(now) != pendingBucket {
            Task { await flushHistory() }
        }

        alerts.evaluate(AlertCenter.Tick(now: now, totalRate: currentIn + currentOut, todayTotal: todayIn + todayOut,
                                         apps: Array(appState.values), newApps: pendingNewApps))
        pendingNewApps.removeAll()
    }

    // MARK: Name and geo resolution

    private func requestResolution(_ address: String) {
        guard !address.isEmpty, !requested.contains(address) else { return }
        requested.insert(address)
        let scope = IPClassifier.scope(of: address)
        let missingCoordinates = scope == .publicInternet && geo[address]?.countryCode != nil && geo[address]?.latitude == nil
        if geo[address] == nil || (missingCoordinates && preferences.geoLookups) {
            if scope != .publicInternet || !preferences.geoLookups {
                geo[address] = GeoInfo(scope: scope)
            } else {
                Task { [weak self] in
                    guard let self, let info = await self.onlineGeo.locate(address) else { return }
                    self.geo[address] = info
                    await self.history?.saveGeo(address, info)
                }
            }
        }
        if preferences.resolveHostnames, scope != .multicast, scope != .unspecified {
            Task { [weak self] in
                guard let self, let name = await self.hostResolver.hostname(for: address) else { return }
                self.hostnames[address] = name
            }
        }
    }

    /// Forgets negative/disabled lookups so they're retried (after a privacy setting change).
    func resetResolution() {
        requested.removeAll()
        geo = geo.filter { $0.value.countryCode != nil || $0.value.scope != .publicInternet }
        for key in connState.keys { connState[key]?.geo = nil }
    }

    // MARK: Insights (data plan, anomalies, digest)

    func runInsights(checkAnomalies: Bool) async {
        guard let history else { return }
        let now = Date()
        let calendar = Calendar.current

        let cycle = BillingCycle.current(containing: now, resetDay: preferences.billingResetDay)
        let totals = await history.totalBytes(from: cycle.start, to: now.addingTimeInterval(3600))
        let countsUp = preferences.dataPlanCountsUpload
        billingCycle = cycle
        cycleUsage = totals.bytesIn + pendingTotalIn + (countsUp ? totals.bytesOut + pendingTotalOut : 0)
        if preferences.dataPlanEnabled, preferences.dataPlanLimit > 0 {
            let percent = Double(cycleUsage) / preferences.dataPlanLimit * 100
            for threshold in alerts.dataPlanThresholds() where percent >= threshold {
                let key = "\(Int(cycle.start.timeIntervalSince1970))-\(Int(threshold))"
                guard firedPlanKeys.insert(key).inserted else { continue }
                UserDefaults.standard.set(Array(firedPlanKeys), forKey: "firedDataPlanKeys")
                alerts.report(.dataPlan, key: key, message: "You've used \(ByteFormat.bytes(cycleUsage)) of your \(ByteFormat.bytes(preferences.dataPlanLimit)) plan (\(Int(percent))%). The cycle resets \(cycle.end.formatted(date: .abbreviated, time: .omitted)).", threshold: percent)
            }
        }

        let startOfToday = calendar.startOfDay(for: now)
        let todayKey = startOfToday.formatted(.iso8601.year().month().day())
        if checkAnomalies, let weekAgo = calendar.date(byAdding: .day, value: -7, to: startOfToday) {
            let hourly = await history.appHourlyTotals(from: weekAgo, to: now.addingTimeInterval(3600))
            var perApp: [String: (name: String, days: [Date: UInt64])] = [:]
            for row in hourly {
                let day = calendar.startOfDay(for: row.hour)
                perApp[row.appID, default: (row.name, [:])].days[day, default: 0] += row.bytes
            }
            for (appID, entry) in perApp {
                let today = entry.days[startOfToday] ?? 0
                let previous = entry.days.filter { $0.key < startOfToday && $0.value > 0 }.map(\.value)
                if let ratio = UsageAnomaly.ratio(today: today, history: previous) {
                    alerts.report(.anomaly, key: appID + todayKey,
                                  message: "\(entry.name) has used \(ByteFormat.bytes(today)) today — \(String(format: "%.1f", ratio))× its usual daily average.",
                                  appID: appID)
                }
            }
        }

        if preferences.digestEnabled, calendar.component(.hour, from: now) >= preferences.digestHour,
           preferences.lastDigestDay != todayKey, todayIn + todayOut > 0 {
            preferences.lastDigestDay = todayKey
            let top = await history.topApps(from: startOfToday, to: now.addingTimeInterval(3600), limit: 3)
            let topText = top.map { "\($0.name) \(ByteFormat.bytes($0.total))" }.joined(separator: ", ")
            alerts.postDigest(title: "Today's network summary",
                              body: "↓ \(ByteFormat.bytes(todayIn))  ↑ \(ByteFormat.bytes(todayOut))" + (topText.isEmpty ? "" : ". Top: \(topText)."))
        }
    }

    // MARK: Speed test

    func runSpeedTest() {
        guard !speedTestRunning else { return }
        speedTestRunning = true
        speedTestStarted = Date()
        speedTestError = nil
        Task {
            defer { speedTestRunning = false; speedTestStarted = nil }
            do {
                let result = try await SpeedTestRunner.run()
                speedTestResults.insert(result, at: 0)
                await history?.saveSpeedTest(result)
            } catch {
                speedTestError = error.localizedDescription
            }
        }
    }

    // MARK: Navigation

    func show(appID: String?) {
        if let appID {
            selectedAppID = appID
            section = .apps
            showInspector = true
        }
        openMainWindow?()
        NSApp.activate()
    }

    // MARK: Derived

    var activeConnectionCount: Int { connections.lazy.filter { !$0.isListening && !$0.isClosed }.count }
    var onlineAppCount: Int { apps.lazy.filter { $0.connectionCount > 0 }.count }
    var unattributedIn: UInt64 { sessionIn > attributedIn ? sessionIn - attributedIn : 0 }
    var unattributedOut: UInt64 { sessionOut > attributedOut ? sessionOut - attributedOut : 0 }

    func app(id: String?) -> AppTraffic? {
        guard let id else { return nil }
        return apps.first { $0.id == id }
    }

    func connection(id: String?) -> ConnectionInfo? {
        guard let id else { return nil }
        return connections.first { $0.id == id }
    }

    func connections(forApp id: String) -> [ConnectionInfo] {
        connections.filter { $0.appID == id }
    }

    func reveal(_ app: AppIdentity) {
        guard let path = app.bundlePath ?? app.executablePath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func runningApplication(for app: AppTraffic) -> NSRunningApplication? {
        app.pids.lazy.compactMap { NSRunningApplication(processIdentifier: $0) }.first { $0.activationPolicy == .regular }
    }

    // MARK: Helpers

    /// Hides system plumbing (AWDL, low-latency WLAN, Apple internal NICs, link-local-only tunnels).
    private static func isInterestingInterface(_ c: InterfaceCounter, addresses: [String], includeLoopback: Bool) -> Bool {
        if c.name.hasPrefix("lo") { return includeLoopback }
        let plumbing = ["awdl", "llw", "anpi", "ap", "gif", "stf", "XHC", "vmenet"]
        if plumbing.contains(where: { c.name.hasPrefix($0) }) { return false }
        let hasRoutable = addresses.contains { !$0.hasPrefix("fe80") }
        if c.name.hasPrefix("utun") || c.name.hasPrefix("ipsec") { return hasRoutable }
        return hasRoutable || (c.name.hasPrefix("en") && c.bytesIn + c.bytesOut > 0 && !addresses.isEmpty)
    }

    private static func appendCapped(_ array: inout [Double], _ value: Double) {
        array.append(value)
        if array.count > appHistoryLength { array.removeFirst(array.count - appHistoryLength) }
    }

    nonisolated static func minuteStart(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
    }
}
