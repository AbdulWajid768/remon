import Foundation

/// A small Spotlight-style query language:
///
/// - free terms match anywhere (app, process, host, IP, port, service, country, city, org, category)
/// - all terms must match; `-term` excludes
/// - `key:value` filters: `app:`, `host:`, `ip:`, `port:`, `proto:`, `country:`, `state:`, `iface:`, `pid:`, `cat:`
/// - double quotes group words: `app:"Google Chrome"`
struct SearchQuery: Equatable, Sendable {
    struct Term: Equatable, Sendable {
        var key: String?
        var value: String
        var negated: Bool
    }

    var terms: [Term]
    var isEmpty: Bool { terms.isEmpty }

    static let keys = ["app", "host", "ip", "port", "proto", "country", "state", "iface", "pid", "cat"]

    init(_ text: String) {
        terms = Self.tokenize(text).compactMap { token in
            var token = token
            var negated = false
            if token.hasPrefix("-"), token.count > 1 { negated = true; token.removeFirst() }
            if let colon = token.firstIndex(of: ":") {
                let key = token[..<colon].lowercased()
                let value = String(token[token.index(after: colon)...])
                if Self.keys.contains(key) {
                    return value.isEmpty ? nil : Term(key: key, value: value, negated: negated)
                }
            }
            return Term(key: nil, value: token, negated: negated)
        }
    }

    static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for ch in text {
            if ch == "\"" { inQuotes.toggle(); continue }
            if ch.isWhitespace && !inQuotes {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    func matches(_ c: ConnectionInfo) -> Bool {
        terms.allSatisfy { term in
            let hit: Bool
            switch term.key {
            case "app": hit = c.appName.localizedStandardContains(term.value) || c.processName.localizedStandardContains(term.value)
            case "host": hit = c.displayHost.localizedStandardContains(term.value)
            case "ip": hit = c.remote.address.localizedStandardContains(term.value) || c.local.address.localizedStandardContains(term.value)
            case "port": hit = c.remote.port.map(String.init) == term.value || c.local.port.map(String.init) == term.value
                || (c.service?.localizedCaseInsensitiveCompare(term.value) == .orderedSame)
            case "proto": hit = c.proto.rawValue.localizedCaseInsensitiveCompare(term.value) == .orderedSame
                || c.family.rawValue.localizedCaseInsensitiveCompare(term.value) == .orderedSame
            case "country": hit = (c.geo?.countryCode?.localizedCaseInsensitiveCompare(term.value) == .orderedSame)
                || (c.geo?.country?.localizedStandardContains(term.value) ?? false)
            case "state": hit = c.displayState.localizedStandardContains(term.value)
            case "iface": hit = c.interface.localizedStandardContains(term.value)
            case "pid": hit = String(c.pid) == term.value
            case "cat": hit = c.category.rawValue.localizedStandardContains(term.value)
            default: hit = haystack(c).contains { $0.localizedStandardContains(term.value) }
            }
            return hit != term.negated
        }
    }

    func matches(_ app: AppTraffic, connections: [ConnectionInfo] = []) -> Bool {
        terms.allSatisfy { term in
            let hit: Bool
            switch term.key {
            case "app": hit = app.name.localizedStandardContains(term.value)
            case "pid": hit = app.pids.contains { String($0) == term.value }
            case nil:
                hit = app.name.localizedStandardContains(term.value)
                    || (app.identity.bundleID?.localizedStandardContains(term.value) ?? false)
                    || connections.contains { SearchQuery(quoting: term.value).matches($0) }
            default:
                // Connection-level filters match an app if any of its connections match.
                hit = connections.contains { SearchQuery(terms: [Term(key: term.key, value: term.value, negated: false)]).matches($0) }
            }
            return hit != term.negated
        }
    }

    private init(terms: [Term]) { self.terms = terms }
    private init(quoting value: String) { self.terms = [Term(key: nil, value: value, negated: false)] }

    private func haystack(_ c: ConnectionInfo) -> [String] {
        var fields = [c.appName, c.processName, c.displayHost, c.remote.address, c.local.address, c.proto.rawValue,
                      c.displayState, c.interface, c.category.rawValue, String(c.pid)]
        if let port = c.remote.port { fields.append(String(port)) }
        if let service = c.service { fields.append(service) }
        if let geo = c.geo {
            fields += [geo.country, geo.countryCode, geo.city, geo.region, geo.org].compactMap { $0 }
        }
        return fields
    }
}
