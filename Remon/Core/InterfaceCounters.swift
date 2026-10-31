import Darwin
import Foundation

struct InterfaceCounter: Sendable, Equatable {
    var name: String
    var bytesIn: UInt64
    var bytesOut: UInt64
    var isUp: Bool
    var type: UInt8
}

/// Reads exact 64-bit per-interface byte counters.
///
/// `getifaddrs` and `sysctl(NET_RT_IFLIST2)` report counters rounded to 1 KiB for
/// unprivileged processes (and `getifaddrs` wraps at 4 GB), which makes low rates jump
/// between 0 and 1 KB/s. The interface MIB (`net.link.generic.ifdata.<index>.general`) is exact.
enum InterfaceCounters {
    static func read() -> [InterfaceCounter] {
        var countMIB: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_SYSTEM, IFMIB_IFCOUNT]
        var count: Int32 = 0
        var countLength = MemoryLayout<Int32>.size
        guard sysctl(&countMIB, 5, &count, &countLength, nil, 0) == 0, count > 0 else { return [] }

        var result: [InterfaceCounter] = []
        for index in 1...count {
            var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, index, IFDATA_GENERAL]
            var data = ifmibdata()
            var length = MemoryLayout<ifmibdata>.size
            guard sysctl(&mib, 6, &data, &length, nil, 0) == 0 else { continue }
            let name = withUnsafeBytes(of: data.ifmd_name) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            guard !name.isEmpty else { continue }
            result.append(InterfaceCounter(
                name: name,
                bytesIn: data.ifmd_data.ifi_ibytes,
                bytesOut: data.ifmd_data.ifi_obytes,
                isUp: data.ifmd_flags & UInt32(IFF_UP) != 0,
                type: data.ifmd_data.ifi_type
            ))
        }
        return result
    }

    /// IPv4/IPv6 addresses per interface name.
    static func addresses() -> [String: [String]] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [:] }
        defer { freeifaddrs(head) }
        var result: [String: [String]] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor?.pointee {
            defer { cursor = entry.ifa_next }
            guard let addr = entry.ifa_addr else { continue }
            let family = Int32(addr.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let len = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            if getnameinfo(addr, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                result[String(cString: entry.ifa_name), default: []].append(String(cBuffer: host))
            }
        }
        return result
    }

    /// Classifies an interface by BSD name, using the NWPathMonitor-reported type when known.
    static func kind(for name: String, pathHint: InterfaceKind?) -> InterfaceKind {
        if let pathHint, pathHint != .other { return pathHint }
        if name.hasPrefix("lo") { return .loopback }
        if name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp") || name.hasPrefix("tun") { return .vpn }
        if name.hasPrefix("bridge") { return .bridge }
        if name.hasPrefix("pdp_ip") { return .cellular }
        if name.hasPrefix("en") { return .ethernet }
        return .other
    }

    /// Interfaces that carry real off-machine traffic. Tunnels are excluded to avoid
    /// double-counting VPN traffic that also crosses the physical interface.
    static func countsTowardTotal(_ name: String) -> Bool {
        name.hasPrefix("en") || name.hasPrefix("pdp_ip")
    }
}
