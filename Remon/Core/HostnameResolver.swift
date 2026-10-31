import Darwin
import Foundation

/// Reverse-DNS (PTR) lookups through the system resolver, cached for the session.
actor HostnameResolver {
    private var cache: [String: String?] = [:]
    private var inFlight: [String: Task<String?, Never>] = [:]

    func hostname(for address: String) async -> String? {
        if let cached = cache[address] { return cached }
        if let task = inFlight[address] { return await task.value }
        let task = Task.detached(priority: .utility) { Self.lookup(address) }
        inFlight[address] = task
        let result = await task.value
        inFlight[address] = nil
        cache[address] = result
        return result
    }

    nonisolated static func lookup(_ address: String) -> String? {
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(address, nil, &hints, &info) == 0, let info else { return nil }
        defer { freeaddrinfo(info) }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &host, socklen_t(host.count),
                          nil, 0, NI_NAMEREQD) == 0 else { return nil }
        let name = String(cBuffer: host)
        return name == address ? nil : name
    }
}
