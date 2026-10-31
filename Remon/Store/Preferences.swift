import AppKit
import Observation
import ServiceManagement

enum MenuBarStyle: String, CaseIterable, Identifiable {
    case graphAndRates = "Graph & Rates"
    case graph = "Graph"
    case rates = "Rates"
    case icon = "Icon Only"
    var id: String { rawValue }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
    var id: String { rawValue }
}

enum ColorTheme: String, CaseIterable, Identifiable {
    case classic = "Classic"
    case ocean = "Ocean"
    case sunset = "Sunset"
    case forest = "Forest"
    case graphite = "Graphite"
    var id: String { rawValue }
}

/// User preferences, persisted to `UserDefaults` and observable by SwiftUI and the store.
@MainActor @Observable
final class Preferences {
    static let shared = Preferences()

    @ObservationIgnored private let defaults: UserDefaults

    var hasCompletedOnboarding: Bool { didSet { defaults.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding") } }
    var sampleInterval: Int { didSet { defaults.set(sampleInterval, forKey: "sampleInterval") } }
    var includeLoopback: Bool { didSet { defaults.set(includeLoopback, forKey: "includeLoopback") } }
    var groupHelpers: Bool { didSet { defaults.set(groupHelpers, forKey: "groupHelpers") } }
    var resolveHostnames: Bool { didSet { defaults.set(resolveHostnames, forKey: "resolveHostnames") } }
    var geoLookups: Bool { didSet { defaults.set(geoLookups, forKey: "geoLookups") } }
    var useBits: Bool { didSet { defaults.set(useBits, forKey: "useBits") } }
    var retentionDays: Int { didSet { defaults.set(retentionDays, forKey: "retentionDays") } }
    var notificationsEnabled: Bool { didSet { defaults.set(notificationsEnabled, forKey: "notificationsEnabled") } }
    var showMenuBarItem: Bool { didSet { defaults.set(showMenuBarItem, forKey: "showMenuBarItem") } }
    var coloredMenuBarGraph: Bool { didSet { defaults.set(coloredMenuBarGraph, forKey: "coloredMenuBarGraph") } }
    var showDockIcon: Bool {
        didSet {
            defaults.set(showDockIcon, forKey: "showDockIcon")
            applyActivationPolicy()
        }
    }
    var colorTheme: ColorTheme { didSet { defaults.set(colorTheme.rawValue, forKey: "colorTheme") } }
    var dataPlanEnabled: Bool { didSet { defaults.set(dataPlanEnabled, forKey: "dataPlanEnabled") } }
    /// Bytes per billing cycle.
    var dataPlanLimit: Double { didSet { defaults.set(dataPlanLimit, forKey: "dataPlanLimit") } }
    var billingResetDay: Int { didSet { defaults.set(billingResetDay, forKey: "billingResetDay") } }
    var dataPlanCountsUpload: Bool { didSet { defaults.set(dataPlanCountsUpload, forKey: "dataPlanCountsUpload") } }
    var digestEnabled: Bool { didSet { defaults.set(digestEnabled, forKey: "digestEnabled") } }
    var digestHour: Int { didSet { defaults.set(digestHour, forKey: "digestHour") } }
    var hotKeyEnabled: Bool {
        didSet {
            defaults.set(hotKeyEnabled, forKey: "hotKeyEnabled")
            GlobalHotKey.shared.setEnabled(hotKeyEnabled)
        }
    }
    var menuBarShowsSystem: Bool { didSet { defaults.set(menuBarShowsSystem, forKey: "menuBarShowsSystem") } }
    var lastDigestDay: String { didSet { defaults.set(lastDigestDay, forKey: "lastDigestDay") } }

    var menuBarStyle: MenuBarStyle { didSet { defaults.set(menuBarStyle.rawValue, forKey: "menuBarStyle") } }
    var appearance: AppearanceMode {
        didSet {
            defaults.set(appearance.rawValue, forKey: "appearance")
            applyAppearance()
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            "sampleInterval": 1, "includeLoopback": false, "groupHelpers": true, "resolveHostnames": true,
            "geoLookups": true, "useBits": false, "retentionDays": 90, "notificationsEnabled": true,
            "showMenuBarItem": true, "coloredMenuBarGraph": false, "showDockIcon": true,
            "dataPlanEnabled": false, "dataPlanLimit": 100_000_000_000.0, "billingResetDay": 1, "dataPlanCountsUpload": true,
            "digestEnabled": true, "digestHour": 20, "hotKeyEnabled": true,
        ])
        hasCompletedOnboarding = defaults.bool(forKey: "hasCompletedOnboarding")
        sampleInterval = defaults.integer(forKey: "sampleInterval")
        includeLoopback = defaults.bool(forKey: "includeLoopback")
        groupHelpers = defaults.bool(forKey: "groupHelpers")
        resolveHostnames = defaults.bool(forKey: "resolveHostnames")
        geoLookups = defaults.bool(forKey: "geoLookups")
        useBits = defaults.bool(forKey: "useBits")
        retentionDays = defaults.integer(forKey: "retentionDays")
        notificationsEnabled = defaults.bool(forKey: "notificationsEnabled")
        showMenuBarItem = defaults.bool(forKey: "showMenuBarItem")
        coloredMenuBarGraph = defaults.bool(forKey: "coloredMenuBarGraph")
        showDockIcon = defaults.bool(forKey: "showDockIcon")
        menuBarStyle = MenuBarStyle(rawValue: defaults.string(forKey: "menuBarStyle") ?? "") ?? .graphAndRates
        appearance = AppearanceMode(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        colorTheme = ColorTheme(rawValue: defaults.string(forKey: "colorTheme") ?? "") ?? .classic
        dataPlanEnabled = defaults.bool(forKey: "dataPlanEnabled")
        dataPlanLimit = defaults.double(forKey: "dataPlanLimit")
        billingResetDay = defaults.integer(forKey: "billingResetDay")
        dataPlanCountsUpload = defaults.bool(forKey: "dataPlanCountsUpload")
        digestEnabled = defaults.bool(forKey: "digestEnabled")
        digestHour = defaults.integer(forKey: "digestHour")
        hotKeyEnabled = defaults.bool(forKey: "hotKeyEnabled")
        lastDigestDay = defaults.string(forKey: "lastDigestDay") ?? ""
        menuBarShowsSystem = defaults.bool(forKey: "menuBarShowsSystem")
    }

    func applyAppearance() {
        NSApp?.appearance = switch appearance {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    func applyActivationPolicy() {
        NSApp?.setActivationPolicy(showDockIcon ? .regular : .accessory)
    }

    // MARK: Launch at login

    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    /// Returns an error message if registration failed (e.g. when running from DerivedData).
    func setLaunchAtLogin(_ enabled: Bool) -> String? {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func rate(_ bytesPerSecond: Double) -> String { ByteFormat.rate(bytesPerSecond, bits: useBits) }
    func compactRate(_ bytesPerSecond: Double) -> String { ByteFormat.compactRate(bytesPerSecond, bits: useBits) }
}
