import Foundation
import SwiftUI

/// Heuristic label for what a remote endpoint *is*, from its PTR name and ASN owner.
enum DestinationCategory: String, CaseIterable, Sendable {
    case local = "Local Network"
    case apple = "Apple"
    case google = "Google"
    case microsoft = "Microsoft"
    case amazon = "Amazon / AWS"
    case cloudflare = "Cloudflare"
    case akamai = "Akamai"
    case fastly = "Fastly"
    case meta = "Meta"
    case telemetry = "Analytics / Telemetry"
    case advertising = "Advertising"
    case update = "Software Update"
    case cdn = "CDN"
    case unknown = "Other"

    var symbol: String {
        switch self {
        case .local: "house"
        case .apple: "apple.logo"
        case .google, .microsoft, .amazon, .meta: "building.2"
        case .cloudflare, .akamai, .fastly, .cdn: "cloud"
        case .telemetry: "chart.bar.doc.horizontal"
        case .advertising: "megaphone"
        case .update: "arrow.down.app"
        case .unknown: "globe"
        }
    }

    var tint: Color {
        switch self {
        case .local: .green
        case .apple: .gray
        case .telemetry: .purple
        case .advertising: .red
        case .update: .teal
        case .cloudflare, .akamai, .fastly, .cdn: .cyan
        case .unknown: .secondary
        default: .indigo
        }
    }

    static func classify(host: String?, org: String?, scope: AddressScope) -> DestinationCategory {
        switch scope {
        case .privateNetwork, .linkLocal, .loopback, .multicast: return .local
        default: break
        }
        let h = (host ?? "").lowercased()
        let o = (org ?? "").lowercased()

        let telemetryHints = ["telemetry", "analytics", "metrics", "crashlytics", "sentry", "segment.io", "mixpanel",
                              "amplitude", "app-measurement", "datadoghq", "newrelic", "bugsnag", "appcenter", "events."]
        if telemetryHints.contains(where: h.contains) { return .telemetry }
        let adHints = ["doubleclick", "googlesyndication", "adservice", "adsrvr", "adnxs", "criteo", "taboola", "outbrain", "moatads"]
        if adHints.contains(where: h.contains) { return .advertising }
        let updateHints = ["swcdn", "swscan", "softwareupdate", "update.", "updates.", "mesu.apple", "download.", "dl."]
        if updateHints.contains(where: h.contains) { return .update }

        if h.hasSuffix("apple.com") || h.hasSuffix("icloud.com") || h.hasSuffix("aaplimg.com") || h.hasSuffix("apple-dns.net")
            || o.contains("apple") { return .apple }
        if h.hasSuffix("1e100.net") || h.contains("google") || o.contains("google") { return .google }
        if h.contains("microsoft") || h.contains("msedge") || h.contains("azure") || o.contains("microsoft") { return .microsoft }
        if h.contains("amazonaws") || h.contains("cloudfront") || o.contains("amazon") { return .amazon }
        if h.contains("cloudflare") || o.contains("cloudflare") { return .cloudflare }
        if h.contains("akamai") || o.contains("akamai") { return .akamai }
        if h.contains("fastly") || o.contains("fastly") { return .fastly }
        if h.contains("facebook") || h.contains("fbcdn") || o.contains("facebook") || o.contains("meta platforms") { return .meta }
        if ["cdn", "edgecast", "limelight", "bunny", "edgekey", "edgesuite"].contains(where: { h.contains($0) || o.contains($0) }) { return .cdn }
        return .unknown
    }
}

enum PortNames {
    private static let known: [UInt16: String] = [
        20: "FTP-Data", 21: "FTP", 22: "SSH", 23: "Telnet", 25: "SMTP", 53: "DNS", 67: "DHCP", 68: "DHCP",
        80: "HTTP", 88: "Kerberos", 110: "POP3", 123: "NTP", 137: "NetBIOS", 138: "NetBIOS", 139: "SMB",
        143: "IMAP", 389: "LDAP", 443: "HTTPS", 445: "SMB", 465: "SMTPS", 500: "IKE", 514: "Syslog",
        548: "AFP", 587: "Submission", 631: "IPP", 853: "DNS-over-TLS", 993: "IMAPS", 995: "POP3S",
        1194: "OpenVPN", 1900: "SSDP", 3283: "ARD", 3306: "MySQL", 3389: "RDP", 3478: "STUN", 3722: "DeviceLink",
        4500: "IPsec NAT-T", 5000: "AirPlay", 5223: "APNs", 5228: "Google Push", 5353: "mDNS", 5432: "PostgreSQL",
        5900: "VNC", 6379: "Redis", 7000: "AirPlay", 8080: "HTTP-Alt", 8443: "HTTPS-Alt", 9418: "Git",
        11211: "Memcached", 27017: "MongoDB", 51820: "WireGuard",
    ]

    @MainActor private static var cache: [String: String?] = [:]

    static func name(for port: UInt16?, proto: TransportProtocol) -> String? {
        guard let port else { return nil }
        if port == 443 && proto == .quic { return "QUIC" }
        return known[port]
    }

    /// Falls back to `/etc/services` for less common ports. Main-actor only (getservbyport isn't thread-safe).
    @MainActor static func fullName(for port: UInt16?, proto: TransportProtocol) -> String? {
        if let name = name(for: port, proto: proto) { return name }
        guard let port else { return nil }
        let key = "\(port)/\(proto.rawValue)"
        if let cached = cache[key] { return cached }
        let protoName = proto == .tcp ? "tcp" : "udp"
        let entry = getservbyport(Int32(UInt16(port).bigEndian), protoName)
        let value = entry.flatMap { $0.pointee.s_name.map { String(cString: $0).uppercased() } }
        cache[key] = value
        return value
    }
}
