import AppKit
import Foundation
import Observation

/// A block rule: a domain (enforced through `/etc/hosts`) or a server address (enforced with `pf`).
struct PolicyRule: Identifiable, Codable, Hashable, Sendable {
    enum Target: Codable, Hashable, Sendable {
        case domain(String)
        case address(String)
    }

    var id = UUID()
    var target: Target
    /// Where the rule came from ("WhatsApp", "macOS Software Update preset", …).
    var note: String?
    var isEnabled = true
    var createdAt = Date()

    var value: String {
        switch target {
        case .domain(let d): d
        case .address(let a): a
        }
    }

    var isDomain: Bool {
        if case .domain = target { return true }
        return false
    }
}

struct BlockPreset: Identifiable, Sendable {
    var id: String { name }
    var name: String
    var symbol: String
    var detail: String
    var domains: [String]

    static let all: [BlockPreset] = [
        BlockPreset(name: "macOS Software Update", symbol: "gear.badge",
                    detail: "Stops macOS from checking for and downloading system updates (also blocks Rapid Security Responses).",
                    domains: ["swscan.apple.com", "swcdn.apple.com", "swdist.apple.com", "mesu.apple.com",
                              "updates.cdn-apple.com", "gdmf.apple.com"]),
        BlockPreset(name: "Google Chrome updates", symbol: "arrow.triangle.2.circlepath",
                    detail: "Blocks Google's updater (Keystone / GoogleUpdater).",
                    domains: ["update.googleapis.com", "tools.google.com"]),
        BlockPreset(name: "Microsoft AutoUpdate", symbol: "square.grid.2x2",
                    detail: "Blocks Microsoft Office / Edge update downloads on Mac.",
                    domains: ["officecdnmac.microsoft.com", "officecdn.microsoft.com"]),
    ]
}

enum PolicyEnforcementError: LocalizedError {
    case cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: "Authentication was cancelled — changes were not applied."
        case .failed(let message): message
        }
    }
}

/// Applies block rules system-wide.
@MainActor
protocol ConnectionPolicyEnforcer {
    func apply(domains: [String], addresses: [String], kill: [String]) async throws
}

/// Builds the root shell script that installs the rules. Kept pure so it can be unit-tested
/// against a scratch hosts file.
enum FirewallScript {
    static let anchor = "com.apple/remon"
    static let beginMarker = "# BEGIN REMON BLOCKLIST"
    static let endMarker = "# END REMON BLOCKLIST"

    static func normalizedDomain(_ input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let range = text.range(of: "://") { text = String(text[range.upperBound...]) }
        text = String(text.prefix { $0 != "/" && $0 != ":" && $0 != "?" })
        if text.hasPrefix("*.") { text.removeFirst(2) }
        if text.hasSuffix(".") { text.removeLast() }
        let labels = text.split(separator: ".", omittingEmptySubsequences: false)
        guard text.count <= 253, labels.count >= 2,
              labels.allSatisfy({ (1...63).contains($0.count) && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
                                  && !$0.hasPrefix("-") && !$0.hasSuffix("-") }),
              labels.last?.allSatisfy(\.isLetter) == true else { return nil }
        return text
    }

    static func normalizedAddress(_ input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, text, &v4) == 1 || inet_pton(AF_INET6, text, &v6) == 1 { return text.lowercased() }
        return nil
    }

    static func isIPv6(_ address: String) -> Bool { address.contains(":") }

    static func pfRules(addresses: [String]) -> [String] {
        addresses.flatMap { address -> [String] in
            let family = isIPv6(address) ? "inet6" : "inet"
            return ["block drop out quick \(family) from any to \(address)",
                    "block drop in quick \(family) from \(address) to any"]
        }
    }

    static func hostsLines(domains: [String]) -> [String] {
        guard !domains.isEmpty else { return [] }
        return ["\(beginMarker) — managed by Remon, edits here are overwritten"]
            + domains.flatMap { ["0.0.0.0 \($0)", ":: \($0)"] }
            + [endMarker]
    }

    /// Domains currently present in Remon's managed block of a hosts file.
    static func activeDomains(inHosts text: String) -> Set<String> {
        var inBlock = false
        var result = Set<String>()
        for line in text.split(separator: "\n") {
            if line.hasPrefix(beginMarker) { inBlock = true; continue }
            if line.hasPrefix(endMarker) { inBlock = false; continue }
            if inBlock, let name = line.split(separator: " ").last { result.insert(String(name)) }
        }
        return result
    }

    /// Inputs must already be normalized (validated) — they are embedded in single quotes.
    static func shell(domains: [String], addresses: [String], kill: [String],
                      hostsPath: String = "/etc/hosts", pfctl: String? = "/sbin/pfctl") -> String {
        precondition(domains.allSatisfy { normalizedDomain($0) == $0 } && (addresses + kill).allSatisfy { normalizedAddress($0) == $0 })
        func quote(_ s: String) -> String { "'" + s + "'" }
        var lines = [
            "set -e",
            "umask 022",
            "H=\(quote(hostsPath))",
            "[ -f \"$H.remon-backup\" ] || cp \"$H\" \"$H.remon-backup\"",
            "T=$(mktemp /tmp/remon.XXXXXX)",
            "sed '/^\(beginMarker)/,/^\(endMarker)/d' \"$H\" > \"$T\"",
        ]
        let hosts = hostsLines(domains: domains)
        if !hosts.isEmpty {
            lines.append("printf '%s\\n' " + hosts.map(quote).joined(separator: " ") + " >> \"$T\"")
        }
        lines += [
            "cat \"$T\" > \"$H\"",
            "rm -f \"$T\"",
            "dscacheutil -flushcache 2>/dev/null || true",
            "killall -HUP mDNSResponder 2>/dev/null || true",
        ]
        if let pfctl {
            let rules = pfRules(addresses: addresses)
            lines.append("P=$(mktemp /tmp/remon.XXXXXX)")
            lines.append(rules.isEmpty ? ": > \"$P\"" : "printf '%s\\n' " + rules.map(quote).joined(separator: " ") + " > \"$P\"")
            lines.append("\(pfctl) -q -a \(quote(anchor)) -f \"$P\"")
            lines.append("rm -f \"$P\"")
            if !addresses.isEmpty { lines.append("\(pfctl) -q -e 2>/dev/null || true") }
            for address in kill {
                let any = isIPv6(address) ? "::/0" : "0.0.0.0/0"
                lines.append("\(pfctl) -q -k \(any) -k \(address) 2>/dev/null || true")
                lines.append("\(pfctl) -q -k \(address) 2>/dev/null || true")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func appleScriptEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// Runs the firewall script as root through the standard macOS administrator prompt
/// (`do shell script … with administrator privileges`). The user authenticates; macOS caches
/// the authorization for a few minutes, so consecutive changes don't re-prompt.
struct PrivilegedFirewallEnforcer: ConnectionPolicyEnforcer {
    func apply(domains: [String], addresses: [String], kill: [String]) async throws {
        let script = FirewallScript.shell(domains: domains, addresses: addresses, kill: kill)
        let source = "do shell script \"\(FirewallScript.appleScriptEscaped(script))\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            if (error[NSAppleScript.errorNumber] as? Int) == -128 { throw PolicyEnforcementError.cancelled }
            throw PolicyEnforcementError.failed((error[NSAppleScript.errorMessage] as? String) ?? "The firewall update failed.")
        }
    }
}

/// Owns block rules, applies them, and tracks whether what's on disk/in pf matches.
@MainActor @Observable
final class PolicyCenter {
    private(set) var rules: [PolicyRule]
    private(set) var isApplying = false
    private(set) var lastError: String?
    private(set) var lastApplied: Date?
    private(set) var activeDomains: Set<String> = []

    @ObservationIgnored private let enforcer: ConnectionPolicyEnforcer
    @ObservationIgnored private var appliedAddresses: Set<String>
    @ObservationIgnored private var appliedBoot: Int
    @ObservationIgnored private var applyTask: Task<Void, Never>?

    static let perAppNote = """
    Blocking a whole app (every destination it might use) needs a Network Extension content filter, \
    which requires a Developer ID–signed build with Apple's Network Extension entitlement. Remon instead \
    blocks the domains and servers you choose, for every app on this Mac.
    """

    init(enforcer: ConnectionPolicyEnforcer = PrivilegedFirewallEnforcer()) {
        self.enforcer = enforcer
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: "blockRules"), let decoded = try? JSONDecoder().decode([PolicyRule].self, from: data) {
            rules = decoded
        } else {
            rules = []
        }
        appliedAddresses = Set(defaults.stringArray(forKey: "appliedBlockAddresses") ?? [])
        appliedBoot = defaults.integer(forKey: "appliedBlockBoot")
        lastApplied = defaults.object(forKey: "lastBlockApply") as? Date
        refreshActiveDomains()
    }

    // MARK: State

    var enabledDomains: [String] { rules.filter { $0.isEnabled && $0.isDomain }.map(\.value).sorted() }
    var enabledAddresses: [String] { rules.filter { $0.isEnabled && !$0.isDomain }.map(\.value).sorted() }

    /// Server rules live in pf, which forgets them on restart.
    var addressRulesActive: Bool {
        appliedBoot == SystemSampler.bootTime() && appliedAddresses == Set(enabledAddresses)
    }

    var needsApply: Bool {
        Set(enabledDomains) != activeDomains || (!(enabledAddresses.isEmpty && appliedAddresses.isEmpty) && !addressRulesActive)
    }

    func isBlocked(address: String) -> Bool {
        rules.contains { $0.isEnabled && $0.target == .address(address.lowercased()) }
    }

    func rule(forAddress address: String) -> PolicyRule? {
        rules.first { $0.target == .address(address.lowercased()) }
    }

    func isActive(_ preset: BlockPreset) -> Bool {
        preset.domains.allSatisfy { d in rules.contains { $0.isEnabled && $0.target == .domain(d) } }
    }

    func refreshActiveDomains() {
        let text = (try? String(contentsOfFile: "/etc/hosts", encoding: .utf8)) ?? ""
        activeDomains = FirewallScript.activeDomains(inHosts: text)
    }

    // MARK: Mutations (each schedules an apply)

    @discardableResult
    func block(domain input: String, note: String? = nil) -> Bool {
        guard let domain = FirewallScript.normalizedDomain(input) else { return false }
        upsert(.domain(domain), note: note)
        return true
    }

    @discardableResult
    func block(address input: String, note: String? = nil) -> Bool {
        guard let address = FirewallScript.normalizedAddress(input) else { return false }
        upsert(.address(address), note: note)
        return true
    }

    func block(addresses: [String], note: String?) {
        for case let address? in addresses.map(FirewallScript.normalizedAddress) {
            if let i = rules.firstIndex(where: { $0.target == .address(address) }) {
                rules[i].isEnabled = true
            } else {
                rules.append(PolicyRule(target: .address(address), note: note))
            }
        }
        changed()
    }

    func unblock(address: String) {
        rules.removeAll { $0.target == .address(address.lowercased()) }
        changed()
    }

    func toggle(_ preset: BlockPreset) {
        if isActive(preset) {
            rules.removeAll { rule in preset.domains.contains { rule.target == .domain($0) } }
        } else {
            for domain in preset.domains where !rules.contains(where: { $0.target == .domain(domain) }) {
                rules.append(PolicyRule(target: .domain(domain), note: preset.name))
            }
            for i in rules.indices where preset.domains.contains(rules[i].value) { rules[i].isEnabled = true }
        }
        changed()
    }

    func setEnabled(_ id: PolicyRule.ID, _ enabled: Bool) {
        guard let i = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[i].isEnabled = enabled
        changed()
    }

    func remove(_ ids: Set<PolicyRule.ID>) {
        rules.removeAll { ids.contains($0.id) }
        changed()
    }

    func removeAll() {
        rules.removeAll()
        changed()
    }

    private func upsert(_ target: PolicyRule.Target, note: String?) {
        if let i = rules.firstIndex(where: { $0.target == target }) {
            rules[i].isEnabled = true
        } else {
            rules.append(PolicyRule(target: target, note: note))
        }
        changed()
    }

    private func changed() {
        if let data = try? JSONEncoder().encode(rules) { UserDefaults.standard.set(data, forKey: "blockRules") }
        // Debounce so several quick edits cost one password prompt.
        applyTask?.cancel()
        applyTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.apply()
        }
    }

    // MARK: Apply

    func apply() async {
        guard !isApplying else { return }
        refreshActiveDomains()
        // Nothing to change (e.g. a block was switched on, the password prompt cancelled, then switched
        // back off): don't ask for an administrator password just to re-apply the current state.
        guard needsApply else {
            lastError = nil
            return
        }
        isApplying = true
        defer { isApplying = false }
        let domains = enabledDomains, addresses = enabledAddresses
        let kill = addresses.filter { !appliedAddresses.contains($0) || !addressRulesActive }
        do {
            try await enforcer.apply(domains: domains, addresses: addresses, kill: kill)
            lastError = nil
            appliedAddresses = Set(addresses)
            appliedBoot = SystemSampler.bootTime()
            lastApplied = Date()
            let defaults = UserDefaults.standard
            defaults.set(Array(appliedAddresses), forKey: "appliedBlockAddresses")
            defaults.set(appliedBoot, forKey: "appliedBlockBoot")
            defaults.set(lastApplied, forKey: "lastBlockApply")
        } catch {
            lastError = error.localizedDescription
        }
        refreshActiveDomains()
    }
}
