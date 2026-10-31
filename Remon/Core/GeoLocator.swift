import Foundation

struct GeoInfo: Hashable, Sendable, Codable {
    var scope: AddressScope
    var countryCode: String?
    var country: String?
    var region: String?
    var city: String?
    var org: String?
    var asn: Int?
    var latitude: Double?
    var longitude: Double?
    var fetchedAt: Date = Date()

    var flag: String {
        switch scope {
        case .publicInternet: countryCode.map(Self.flag(for:)) ?? "🌐"
        case .loopback: "🔁"
        case .multicast: "📡"
        default: "🏠"
        }
    }

    var placeDescription: String {
        guard scope == .publicInternet else { return scope.label }
        let parts = [city, country].compactMap { $0?.isEmpty == false ? $0 : nil }
        return parts.isEmpty ? "Internet" : parts.joined(separator: ", ")
    }

    var sortKey: String { scope == .publicInternet ? (country ?? "~") + (city ?? "") : "~" + scope.label }

    static func flag(for code: String) -> String {
        let base: UInt32 = 0x1F1E6 - 65
        var result = ""
        for scalar in code.uppercased().unicodeScalars where (65...90).contains(scalar.value) {
            if let flagScalar = Unicode.Scalar(base + scalar.value) { result.unicodeScalars.append(flagScalar) }
        }
        return result.isEmpty ? "🌐" : result
    }
}

enum AddressScope: String, Sendable, Codable {
    case publicInternet
    case privateNetwork
    case linkLocal
    case loopback
    case multicast
    case carrierNAT
    case unspecified

    var label: String {
        switch self {
        case .publicInternet: "Internet"
        case .privateNetwork: "Local network"
        case .linkLocal: "Link-local"
        case .loopback: "This Mac"
        case .multicast: "Multicast"
        case .carrierNAT: "Carrier NAT"
        case .unspecified: "Unspecified"
        }
    }
}

/// Classifies addresses locally — nothing here touches the network.
enum IPClassifier {
    static func scope(of rawAddress: String) -> AddressScope {
        let address = rawAddress.split(separator: "%").first.map(String.init) ?? rawAddress
        if address.isEmpty || address == "*" { return .unspecified }
        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 {
            return scope(ipv4: UInt32(bigEndian: v4.s_addr))
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, address, &v6) == 1 else { return .unspecified }
        let bytes = withUnsafeBytes(of: v6) { Array($0) }
        if bytes.allSatisfy({ $0 == 0 }) { return .unspecified }
        if bytes[0..<15].allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return .loopback }
        // IPv4-mapped ::ffff:a.b.c.d
        if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xFF && bytes[11] == 0xFF {
            let v = UInt32(bytes[12]) << 24 | UInt32(bytes[13]) << 16 | UInt32(bytes[14]) << 8 | UInt32(bytes[15])
            return scope(ipv4: v)
        }
        if bytes[0] == 0xFF { return .multicast }
        if bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80 { return .linkLocal }
        if bytes[0] & 0xFE == 0xFC { return .privateNetwork }
        return .publicInternet
    }

    static func scope(ipv4 v: UInt32) -> AddressScope {
        let a = v >> 24, b = (v >> 16) & 0xFF
        switch a {
        case 0: return .unspecified
        case 10: return .privateNetwork
        case 127: return .loopback
        case 169 where b == 254: return .linkLocal
        case 172 where (16...31).contains(b): return .privateNetwork
        case 192 where b == 168: return .privateNetwork
        case 100 where (64...127).contains(b): return .carrierNAT
        case 224...239: return .multicast
        case 255: return .multicast
        default: return .publicInternet
        }
    }
}

/// Resolves geography/ownership for public IP addresses.
protocol GeoLocating: Sendable {
    func locate(_ address: String) async -> GeoInfo?
}

/// Used when the user disables online lookups: only local classification.
struct OfflineGeoLocator: GeoLocating {
    func locate(_ address: String) async -> GeoInfo? {
        GeoInfo(scope: IPClassifier.scope(of: address))
    }
}

/// Looks up public addresses via ipwho.is (HTTPS, no key). Requests are serialized and
/// spaced out to stay well under the free-tier limits; callers cache results on disk.
actor IPWhoIsGeoLocator: GeoLocating {
    private let session: URLSession
    private var nextSlot = ContinuousClock.now
    private let spacing: Duration = .milliseconds(350)
    private var backoffUntil = ContinuousClock.now

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.httpAdditionalHeaders = ["User-Agent": "Remon/1.0 (macOS network monitor)"]
        session = URLSession(configuration: config)
    }

    func locate(_ address: String) async -> GeoInfo? {
        let bare = address.split(separator: "%").first.map(String.init) ?? address
        let scope = IPClassifier.scope(of: bare)
        guard scope == .publicInternet else { return GeoInfo(scope: scope) }

        let now = ContinuousClock.now
        guard now >= backoffUntil else { return nil }
        let slot = max(now, nextSlot)
        nextSlot = slot + spacing
        try? await Task.sleep(until: slot, clock: .continuous)

        var components = URLComponents(string: "https://ipwho.is/")!
        components.path = "/" + bare
        components.queryItems = [URLQueryItem(name: "fields", value: Self.fields)]
        guard let url = components.url else { return nil }
        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode == 429 {
                backoffUntil = .now + .seconds(300)
                return nil
            }
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            guard decoded.success else { return GeoInfo(scope: .publicInternet) }
            return decoded.geoInfo
        } catch {
            return nil
        }
    }

    static let fields = "success,message,ip,country,country_code,region,city,latitude,longitude,connection"

    /// Looks up this Mac's own public address (no IP in the path).
    func lookupSelf() async -> (ip: String, info: GeoInfo)? {
        guard let url = URL(string: "https://ipwho.is/?fields=\(Self.fields)") else { return nil }
        guard let (data, _) = try? await session.data(from: url),
              let decoded = try? JSONDecoder().decode(Response.self, from: data),
              decoded.success, let ip = decoded.ip else { return nil }
        return (ip, decoded.geoInfo)
    }

    struct Response: Decodable {
        var success: Bool
        var ip: String?
        var country: String?
        var country_code: String?
        var region: String?
        var city: String?
        var latitude: Double?
        var longitude: Double?
        var connection: Connection?
        struct Connection: Decodable {
            var asn: Int?
            var org: String?
            var isp: String?
        }

        var geoInfo: GeoInfo {
            GeoInfo(scope: .publicInternet, countryCode: country_code, country: country, region: region, city: city,
                    org: connection?.org ?? connection?.isp, asn: connection?.asn, latitude: latitude, longitude: longitude)
        }
    }
}
