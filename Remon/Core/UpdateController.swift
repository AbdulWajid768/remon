import Foundation
import Observation
import Sparkle

/// Automatic updates, backed by Sparkle.
///
/// Remon ships outside the App Store, so it updates itself from a signed appcast
/// (`SUFeedURL` in Info.plist). Every download is verified twice before it's installed: an EdDSA
/// signature made with the private key that never leaves the release machine, and a check that the
/// new build carries the same Developer ID signature as the running one. See docs/RELEASING.md.
///
/// The updater only starts in a build that has both a feed URL and a public key, so ad-hoc local
/// builds (and the E2E harness) don't talk to the network or raise Sparkle's configuration alert.
@MainActor @Observable
final class UpdateController {
    static let shared = UpdateController()

    /// Whether this build is set up to update itself at all.
    let isConfigured: Bool
    /// False while a check is already running, so the menu item and button can dim.
    private(set) var canCheck = false
    private(set) var lastCheck: Date?

    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?

    private init() {
        let info = Bundle.main.infoDictionary
        let feed = (info?["SUFeedURL"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let key = (info?["SUPublicEDKey"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        isConfigured = !feed.isEmpty && !key.isEmpty

        guard isConfigured else {
            controller = nil
            return
        }
        // Starting the updater also schedules the background checks (SUScheduledCheckInterval).
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        canCheck = controller.updater.canCheckForUpdates
        lastCheck = controller.updater.lastUpdateCheckDate
        // The KVO callback is nonisolated, and SPUUpdater is main-actor isolated, so read the
        // new value out of the change and go back to the main actor for the rest.
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, change in
            guard let canCheck = change.newValue else { return }
            Task { @MainActor in self?.refresh(canCheck: canCheck) }
        }
    }

    private func refresh(canCheck: Bool) {
        self.canCheck = canCheck
        lastCheck = controller?.updater.lastUpdateCheckDate
    }

    /// The feed Remon checks, for display in Settings.
    var feedHost: String? {
        guard let feed = Bundle.main.infoDictionary?["SUFeedURL"] as? String else { return nil }
        return URL(string: feed)?.host
    }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloads: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set { controller?.updater.automaticallyDownloadsUpdates = newValue }
    }

    /// Shows Sparkle's own progress and release-notes UI, including "you're up to date".
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// `1.0 (12)`, the way the About box and Settings show it.
    static var versionDescription: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }
}
