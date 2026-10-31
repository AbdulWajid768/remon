import AppIntents
import Foundation

/// Shortcuts / Spotlight actions. They run inside the app process and read live state.
struct GetThroughputIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Network Throughput"
    static let description = IntentDescription("Returns Remon's current download and upload rates.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let store = MonitorStore.shared, prefs = Preferences.shared
        let text = "Download \(prefs.rate(store.currentIn)), upload \(prefs.rate(store.currentOut))"
        return .result(value: text, dialog: "\(text)")
    }
}

struct GetTodayUsageIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Today's Data Usage"
    static let description = IntentDescription("Returns how much data this Mac has transferred today.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let store = MonitorStore.shared
        let total = store.todayIn + store.todayOut
        return .result(value: Int(clamping: total),
                       dialog: "Today: \(ByteFormat.bytes(total)) (↓ \(ByteFormat.bytes(store.todayIn)), ↑ \(ByteFormat.bytes(store.todayOut)))")
    }
}

struct GetTopAppIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Busiest App"
    static let description = IntentDescription("Returns the app using the most bandwidth right now.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let app = MonitorStore.shared.apps.first(where: { $0.totalRate > 0 }) else {
            return .result(value: "", dialog: "No app is using the network right now.")
        }
        return .result(value: app.name, dialog: "\(app.name) is using \(Preferences.shared.rate(app.totalRate)).")
    }
}

struct SetMonitoringPausedIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause or Resume Live Updates"
    static let description = IntentDescription("Freezes or resumes Remon's live app and connection lists.")

    @Parameter(title: "Paused", default: true)
    var paused: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = MonitorStore.shared
        if store.isPaused != paused { store.togglePause() }
        return .result(dialog: paused ? "Remon live updates paused." : "Remon live updates resumed.")
    }
}

struct RunSpeedTestIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Network Speed Test"
    static let description = IntentDescription("Measures download, upload and responsiveness with Apple's networkQuality.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let result = try await SpeedTestRunner.run()
        await MonitorStore.shared.history?.saveSpeedTest(result)
        let text = String(format: "Download %.0f Mbps, upload %.0f Mbps", result.download / 1e6, result.upload / 1e6)
            + (result.responsivenessRPM.map { ", responsiveness \(Int($0)) RPM" } ?? "")
        return .result(value: text, dialog: "\(text)")
    }
}

struct RemonShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: GetThroughputIntent(), phrases: ["How fast is my network in \(.applicationName)",
                                                             "Get throughput from \(.applicationName)"],
                    shortTitle: "Throughput", systemImageName: "arrow.up.arrow.down")
        AppShortcut(intent: GetTodayUsageIntent(), phrases: ["How much data did I use today in \(.applicationName)"],
                    shortTitle: "Today's Usage", systemImageName: "calendar")
        AppShortcut(intent: GetTopAppIntent(), phrases: ["Which app is using the network in \(.applicationName)"],
                    shortTitle: "Busiest App", systemImageName: "flame")
        AppShortcut(intent: RunSpeedTestIntent(), phrases: ["Run a speed test in \(.applicationName)"],
                    shortTitle: "Speed Test", systemImageName: "speedometer")
    }
}
