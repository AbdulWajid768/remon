import Foundation
import Observation
import UserNotifications

struct AlertRule: Identifiable, Codable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case totalRate = "Total rate above"
        case appRate = "App rate above"
        case dailyTotal = "Daily usage above"
        case newApp = "App uses network for the first time"
        case anomaly = "App uses far more data than usual"
        case dataPlan = "Data plan usage reaches"
        case connectivity = "Connection lost or restored"
        case publicIP = "Public IP address changes"
        case highTemperature = "CPU temperature above"
        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .totalRate: "gauge.with.dots.needle.67percent"
            case .appRate: "app.badge"
            case .dailyTotal: "calendar.badge.exclamationmark"
            case .newApp: "sparkles"
            case .anomaly: "chart.line.uptrend.xyaxis"
            case .dataPlan: "chart.pie"
            case .connectivity: "wifi.exclamationmark"
            case .publicIP: "network.badge.shield.half.filled"
            case .highTemperature: "thermometer.high"
            }
        }
        /// Event-style rules fire on a change rather than a measured value.
        var usesThreshold: Bool { self == .totalRate || self == .appRate || self == .dailyTotal || self == .dataPlan || self == .highTemperature }
        var usesDuration: Bool { self == .totalRate || self == .appRate || self == .highTemperature }
        /// Thresholds that are plain numbers (percent, °C) rather than byte quantities.
        var thresholdUnit: String? {
            switch self {
            case .dataPlan: "%"
            case .highTemperature: "°C"
            default: nil
            }
        }
    }

    var id = UUID()
    var name: String
    var kind: Kind
    var isEnabled = true
    /// Bytes per second for rate rules, bytes for daily rules.
    var threshold: Double = 5_000_000
    var sustainSeconds: Int = 10
    /// `nil` means any app (for `.appRate`).
    var appID: String?
    var appName: String?
    var cooldownMinutes: Int = 15

    var summary: String {
        switch kind {
        case .totalRate: "Total traffic above \(ByteFormat.rate(threshold)) for \(sustainSeconds)s"
        case .appRate: "\(appName ?? "Any app") above \(ByteFormat.rate(threshold)) for \(sustainSeconds)s"
        case .dailyTotal: "Today's usage above \(ByteFormat.bytes(threshold))"
        case .newApp: "Notify when an app connects for the first time"
        case .anomaly: "An app uses 3× its usual daily data (at least 50 MB)"
        case .dataPlan: "Data plan reaches \(Int(threshold))% of its limit"
        case .connectivity: "Notify when the Mac goes offline or comes back"
        case .publicIP: "Notify when your public IP or VPN state changes"
        case .highTemperature: "CPU above \(Int(threshold)) °C for \(sustainSeconds)s"
        }
    }

    static let defaults: [AlertRule] = [
        AlertRule(name: "New app on the network", kind: .newApp),
        AlertRule(name: "Heavy download", kind: .totalRate, threshold: 20_000_000, sustainSeconds: 15),
        AlertRule(name: "Chatty app", kind: .appRate, isEnabled: false, threshold: 5_000_000, sustainSeconds: 30),
        AlertRule(name: "Daily data budget", kind: .dailyTotal, isEnabled: false, threshold: 10_000_000_000),
        AlertRule(name: "Unusual app usage", kind: .anomaly, cooldownMinutes: 240),
        AlertRule(name: "Data plan at 80%", kind: .dataPlan, threshold: 80),
        AlertRule(name: "Data plan used up", kind: .dataPlan, threshold: 100),
        AlertRule(name: "Connectivity changes", kind: .connectivity, cooldownMinutes: 1),
        AlertRule(name: "Public IP / VPN changes", kind: .publicIP, cooldownMinutes: 1),
        AlertRule(name: "Running hot", kind: .highTemperature, threshold: 95, sustainSeconds: 30, cooldownMinutes: 30),
    ]
}

struct AlertEvent: Identifiable, Hashable, Sendable {
    var id = UUID()
    var date: Date
    var title: String
    var message: String
    var symbol: String
    /// App to reveal when the notification is clicked.
    var appID: String?
}

/// Evaluates alert rules each tick and posts notifications.
@MainActor @Observable
final class AlertCenter {
    var rules: [AlertRule] { didSet { save() } }
    private(set) var events: [AlertEvent] = []
    private(set) var authorization: UNAuthorizationStatus = .notDetermined

    @ObservationIgnored private var exceedSince: [String: Date] = [:]
    @ObservationIgnored private var lastFired: [String: Date] = [:]
    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let center: UNUserNotificationCenter? = Bundle.main.bundleIdentifier == nil ? nil : .current()

    init(preferences: Preferences) {
        self.preferences = preferences
        if let data = UserDefaults.standard.data(forKey: "alertRules"),
           let decoded = try? JSONDecoder().decode([AlertRule].self, from: data) {
            // Add rule kinds introduced since the rules were saved.
            let missing = AlertRule.defaults.filter { d in !decoded.contains { $0.kind == d.kind } }
            rules = decoded + missing
        } else {
            rules = AlertRule.defaults
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(rules) { UserDefaults.standard.set(data, forKey: "alertRules") }
    }

    func refreshAuthorization() async {
        guard let center else { return }
        authorization = await center.notificationSettings().authorizationStatus
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        guard let center else { return false }
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        await refreshAuthorization()
        return granted
    }

    func clearEvents() { events.removeAll() }

    // MARK: Evaluation

    struct Tick {
        var now: Date
        var totalRate: Double
        var todayTotal: UInt64
        var apps: [AppTraffic]
        var newApps: [AppIdentity]
    }

    func evaluate(_ tick: Tick) {
        for rule in rules where rule.isEnabled {
            switch rule.kind {
            case .totalRate:
                sustained(rule, key: rule.id.uuidString, exceeded: tick.totalRate > rule.threshold, now: tick.now) {
                    "Total network traffic has been above \(ByteFormat.rate(rule.threshold)) for \(rule.sustainSeconds) seconds (now \(ByteFormat.rate(tick.totalRate)))."
                }
            case .appRate:
                for app in tick.apps where rule.appID == nil || rule.appID == app.id {
                    sustained(rule, key: rule.id.uuidString + app.id, exceeded: app.totalRate > rule.threshold, now: tick.now) {
                        "\(app.name) has been using more than \(ByteFormat.rate(rule.threshold)) for \(rule.sustainSeconds) seconds (now \(ByteFormat.rate(app.totalRate)))."
                    }
                }
            case .dailyTotal:
                if Double(tick.todayTotal) > rule.threshold {
                    // Fire at most once per calendar day.
                    let key = rule.id.uuidString
                    if let last = lastFired[key], Calendar.current.isDate(last, inSameDayAs: tick.now) { continue }
                    fire(rule, key: key, now: tick.now,
                         message: "Today's network usage reached \(ByteFormat.bytes(tick.todayTotal)), above your \(ByteFormat.bytes(rule.threshold)) budget.")
                }
            case .newApp:
                for app in tick.newApps {
                    fire(rule, key: rule.id.uuidString + app.id, now: tick.now,
                         message: "\(app.name) connected to the network for the first time.", respectCooldown: false, appID: app.id)
                }
            case .anomaly, .dataPlan, .connectivity, .publicIP, .highTemperature:
                break // event-driven, see `report(_:)` / `evaluateTemperature(_:)`
            }
        }
    }

    func evaluateTemperature(_ celsius: Double, now: Date = Date()) {
        for rule in rules where rule.isEnabled && rule.kind == .highTemperature {
            sustained(rule, key: rule.id.uuidString, exceeded: celsius > rule.threshold, now: now) {
                "The CPU has been above \(Int(rule.threshold)) °C for \(rule.sustainSeconds) seconds (now \(Int(celsius)) °C)."
            }
        }
    }

    /// Fires every enabled rule of an event-driven kind. `key` de-duplicates within the cooldown.
    func report(_ kind: AlertRule.Kind, key: String, message: String, appID: String? = nil, threshold: Double? = nil) {
        for rule in rules where rule.isEnabled && rule.kind == kind {
            if let threshold, threshold < rule.threshold { continue }
            fire(rule, key: rule.id.uuidString + key, now: Date(), message: message, appID: appID)
        }
    }

    /// Highest enabled data-plan threshold (percent) reached by `percent`, if any.
    func dataPlanThresholds() -> [Double] {
        rules.filter { $0.isEnabled && $0.kind == .dataPlan }.map(\.threshold)
    }

    func postDigest(title: String, body: String) {
        let event = AlertEvent(date: Date(), title: title, message: body, symbol: "newspaper")
        events.insert(event, at: 0)
        post(event)
    }

    private func sustained(_ rule: AlertRule, key: String, exceeded: Bool, now: Date, message: () -> String) {
        guard exceeded else { exceedSince[key] = nil; return }
        let since = exceedSince[key] ?? now
        exceedSince[key] = since
        if now.timeIntervalSince(since) >= Double(rule.sustainSeconds) {
            fire(rule, key: key, now: now, message: message())
        }
    }

    private func fire(_ rule: AlertRule, key: String, now: Date, message: String, respectCooldown: Bool = true, appID: String? = nil) {
        if respectCooldown, let last = lastFired[key], now.timeIntervalSince(last) < Double(rule.cooldownMinutes * 60) { return }
        lastFired[key] = now
        let event = AlertEvent(date: now, title: rule.name, message: message, symbol: rule.kind.symbol, appID: appID)
        events.insert(event, at: 0)
        if events.count > 200 { events.removeLast(events.count - 200) }
        post(event)
    }

    private func post(_ event: AlertEvent) {
        guard preferences.notificationsEnabled, let center else { return }
        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = event.message
        content.sound = .default
        if let appID = event.appID { content.userInfo = ["appID": appID] }
        let request = UNNotificationRequest(identifier: event.id.uuidString, content: content, trigger: nil)
        center.add(request) { _ in }
    }
}
