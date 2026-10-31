import Foundation
import Observation

/// A user-defined allow/deny rule for an app.
struct PolicyRule: Identifiable, Codable, Hashable, Sendable {
    enum Action: String, Codable, CaseIterable, Identifiable, Sendable {
        case deny = "Deny"
        case allow = "Allow"
        var id: String { rawValue }
    }

    var id = UUID()
    var appID: String
    var appName: String
    var action: Action = .deny
    /// `nil` = any destination; otherwise a host name or IP address.
    var host: String?
    var isEnabled = true
    var createdAt = Date()
}

enum EnforcementAvailability: Sendable, Equatable {
    case available
    case unavailable(reason: String)
}

/// Seam for blocking connections. A real implementation needs a Network Extension
/// (`NEFilterDataProvider`) running as a system extension, which in turn requires a
/// Developer ID–signed app, the `com.apple.developer.networking.networkextension`
/// entitlement and explicit user approval in System Settings.
protocol ConnectionPolicyEnforcer: Sendable {
    func availability() async -> EnforcementAvailability
    func apply(_ rules: [PolicyRule]) async throws
}

enum PolicyEnforcementError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self { case .unavailable(let reason): reason }
    }
}

/// The stub shipped in this build: it accepts nothing and explains why.
struct UnavailableNetworkExtensionEnforcer: ConnectionPolicyEnforcer {
    static let reason = """
    Blocking requires Remon's content-filter system extension (NEFilterDataProvider). \
    It isn't included in this build because it needs a Developer ID certificate, the Network \
    Extension entitlement from Apple, and approval in System Settings › General › Login Items & Extensions. \
    Rules are saved and will be enforced once the extension is installed.
    """

    func availability() async -> EnforcementAvailability { .unavailable(reason: Self.reason) }

    func apply(_ rules: [PolicyRule]) async throws {
        throw PolicyEnforcementError.unavailable(Self.reason)
    }
}

/// Owns policy rules and pushes them to the enforcer.
@MainActor @Observable
final class PolicyCenter {
    var rules: [PolicyRule] {
        didSet {
            if let data = try? JSONEncoder().encode(rules) { UserDefaults.standard.set(data, forKey: "policyRules") }
            Task { await push() }
        }
    }
    private(set) var availability: EnforcementAvailability = .unavailable(reason: "Checking…")
    private(set) var lastError: String?
    @ObservationIgnored private let enforcer: ConnectionPolicyEnforcer

    init(enforcer: ConnectionPolicyEnforcer = UnavailableNetworkExtensionEnforcer()) {
        self.enforcer = enforcer
        if let data = UserDefaults.standard.data(forKey: "policyRules"),
           let decoded = try? JSONDecoder().decode([PolicyRule].self, from: data) {
            rules = decoded
        } else {
            rules = []
        }
        Task { availability = await enforcer.availability() }
    }

    var isEnforcing: Bool { availability == .available }

    func rule(for appID: String) -> PolicyRule? { rules.first { $0.appID == appID && $0.host == nil } }

    private func push() async {
        do {
            try await enforcer.apply(rules.filter(\.isEnabled))
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }
}
