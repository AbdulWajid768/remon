import Foundation

enum TransportProtocol: String, Sendable, Codable, CaseIterable, Comparable {
    case tcp = "TCP"
    case udp = "UDP"
    case quic = "QUIC"

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

enum IPFamily: String, Sendable, Codable {
    case v4 = "IPv4"
    case v6 = "IPv6"
}

/// One side of a socket. `address == "*"` / `port == nil` mean wildcard.
struct Endpoint: Hashable, Sendable, Codable {
    var address: String
    var port: UInt16?

    var isWildcardAddress: Bool { address == "*" || address.isEmpty }

    /// Address without an IPv6 scope suffix (`fe80::1%en0` → `fe80::1`).
    var bareAddress: String {
        if let idx = address.firstIndex(of: "%") { return String(address[..<idx]) }
        return address
    }

    var display: String {
        let port = port.map(String.init) ?? "*"
        if address.contains(":") { return "[\(address)]:\(port)" }
        return "\(address):\(port)"
    }
}

/// Identity of the app a socket belongs to. Helpers can be folded into their parent bundle.
struct AppIdentity: Hashable, Sendable, Identifiable, Codable {
    /// Grouping key: bundle path, executable path, or `proc:<name>` when the path is unknown.
    var id: String
    var name: String
    var bundleID: String?
    var bundlePath: String?
    var executablePath: String?
    var isSystem: Bool
}

/// Live, per-app aggregate.
struct AppTraffic: Identifiable, Hashable, Sendable {
    var identity: AppIdentity
    var id: String { identity.id }
    var name: String { identity.name }
    var pids: Set<Int32> = []
    var rateIn: Double = 0
    var rateOut: Double = 0
    var sessionIn: UInt64 = 0
    var sessionOut: UInt64 = 0
    var connectionCount: Int = 0
    var historyIn: [Double] = []
    var historyOut: [Double] = []
    var lastActive: Date = .distantPast

    var totalRate: Double { rateIn + rateOut }
    var sessionTotal: UInt64 { sessionIn + sessionOut }
    var sparkline: [Double] { zip(historyIn, historyOut).map { $0 + $1 } }
}

enum ConnectionScope: String, CaseIterable, Identifiable, Sendable {
    case active = "Active"
    case listening = "Listening"
    case all = "All"
    var id: String { rawValue }
}

/// Live state of a single socket.
struct ConnectionInfo: Identifiable, Hashable, Sendable {
    let id: String
    var pid: Int32
    var processName: String
    var appID: String
    var appName: String
    var proto: TransportProtocol
    var family: IPFamily
    var local: Endpoint
    var remote: Endpoint
    var state: String
    var interface: String
    var rateIn: Double = 0
    var rateOut: Double = 0
    var totalIn: UInt64 = 0
    var totalOut: UInt64 = 0
    var rttMs: Double?
    var firstSeen: Date
    var lastSeen: Date
    var isClosed = false
    var hostname: String?
    var geo: GeoInfo?

    var isListening: Bool { remote.isWildcardAddress }
    var totalRate: Double { rateIn + rateOut }
    var totalBytes: UInt64 { totalIn + totalOut }
    var displayHost: String { hostname ?? (remote.isWildcardAddress ? "—" : remote.bareAddress) }
    var displayState: String { state.isEmpty ? (proto == .tcp ? "—" : "Stateless") : state }
    var remotePortSort: Int { Int(remote.port ?? local.port ?? 0) }
    var rttSort: Double { rttMs ?? .infinity }
    var locationSort: String { geo?.sortKey ?? "~" }
    var category: DestinationCategory { DestinationCategory.classify(host: hostname, org: geo?.org, scope: geo?.scope ?? IPClassifier.scope(of: remote.bareAddress)) }
    var service: String? { PortNames.name(for: remote.port ?? local.port, proto: proto) }
}

struct ThroughputPoint: Identifiable, Hashable, Sendable {
    var date: Date
    var rateIn: Double
    var rateOut: Double
    var id: Date { date }
}

struct InterfaceStats: Identifiable, Hashable, Sendable {
    var name: String
    var kind: InterfaceKind
    var rateIn: Double
    var rateOut: Double
    var totalIn: UInt64
    var totalOut: UInt64
    var addresses: [String]
    var isUp: Bool
    var id: String { name }
}

enum InterfaceKind: String, Sendable {
    case wifi = "Wi-Fi"
    case ethernet = "Ethernet"
    case cellular = "Cellular"
    case vpn = "VPN / Tunnel"
    case loopback = "Loopback"
    case bridge = "Bridge"
    case other = "Other"

    var symbol: String {
        switch self {
        case .wifi: "wifi"
        case .ethernet: "cable.connector"
        case .cellular: "antenna.radiowaves.left.and.right"
        case .vpn: "lock.shield"
        case .loopback: "arrow.triangle.2.circlepath"
        case .bridge: "point.3.connected.trianglepath.dotted"
        case .other: "network"
        }
    }
}

enum SourceStatus: Equatable, Sendable {
    case starting
    case running
    case failed(String)
}
