import Foundation

struct NettopConnectionRow: Sendable, Equatable {
    var proto: TransportProtocol
    var family: IPFamily
    var local: Endpoint
    var remote: Endpoint
    var state: String
    var interface: String
    var bytesIn: UInt64
    var bytesOut: UInt64
    var rttMs: Double?
}

struct NettopProcessRow: Sendable, Equatable {
    var name: String
    var pid: Int32
    var bytesIn: UInt64
    var bytesOut: UInt64
    var connections: [NettopConnectionRow] = []
}

struct NettopFrame: Sendable {
    var timestamp: Date
    var processes: [NettopProcessRow]
}

/// Incremental parser for `nettop -L 0 -x -n -J …` CSV output.
///
/// Each sample starts with a header line (`,interface,state,bytes_in,…`). Process rows
/// (`name.pid,…`) are followed by their socket rows (`tcp4 a:p<->b:q,…`). A frame is
/// complete when the next header arrives.
struct NettopParser {
    private var columns: [String: Int] = [:]
    private var processes: [NettopProcessRow] = []
    private var inFrame = false

    /// Feeds one line; returns the previous frame when this line starts a new one.
    mutating func consume(_ line: Substring, now: Date = Date()) -> NettopFrame? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let fields = trimmed.split(separator: ",", omittingEmptySubsequences: false).map(String.init)

        if fields.first == "", fields.contains("bytes_in") {
            let finished = inFrame ? NettopFrame(timestamp: now, processes: processes) : nil
            columns = Dictionary(uniqueKeysWithValues: fields.enumerated().compactMap { idx, name in
                name.isEmpty ? nil : (name, idx)
            })
            processes = []
            inFrame = true
            return finished
        }
        guard inFrame, let ident = fields.first, !ident.isEmpty else { return nil }

        if ident.contains("<->") {
            guard !processes.isEmpty,
                  let (proto, family, local, remote) = Self.parseSocket(ident) else { return nil }
            // Fully unbound sockets (`*:*<->*:*`) carry no information.
            if local.isWildcardAddress && local.port == nil && remote.isWildcardAddress { return nil }
            let row = NettopConnectionRow(
                proto: proto, family: family, local: local, remote: remote,
                state: field("state", fields),
                interface: field("interface", fields),
                bytesIn: UInt64(field("bytes_in", fields)) ?? 0,
                bytesOut: UInt64(field("bytes_out", fields)) ?? 0,
                rttMs: Self.parseRTT(field("rtt_avg", fields))
            )
            processes[processes.count - 1].connections.append(row)
        } else if let dot = ident.lastIndex(of: "."), let pid = Int32(ident[ident.index(after: dot)...]) {
            processes.append(NettopProcessRow(
                name: String(ident[..<dot]),
                pid: pid,
                bytesIn: UInt64(field("bytes_in", fields)) ?? 0,
                bytesOut: UInt64(field("bytes_out", fields)) ?? 0
            ))
        }
        return nil
    }

    mutating func consume(_ line: String, now: Date = Date()) -> NettopFrame? {
        consume(Substring(line), now: now)
    }

    /// Returns the in-progress frame (used when the stream ends).
    mutating func flush(now: Date = Date()) -> NettopFrame? {
        guard inFrame, !processes.isEmpty else { return nil }
        defer { processes = []; inFrame = false }
        return NettopFrame(timestamp: now, processes: processes)
    }

    private func field(_ name: String, _ fields: [String]) -> String {
        guard let idx = columns[name], idx < fields.count else { return "" }
        return fields[idx]
    }

    static func parseRTT(_ s: String) -> Double? {
        let number = s.prefix { $0.isNumber || $0 == "." }
        return number.isEmpty ? nil : Double(number)
    }

    /// Parses `tcp4 10.0.0.2:5432<->1.2.3.4:443` or `udp6 fe80::1%en0.5353<->*.*`.
    static func parseSocket(_ s: String) -> (TransportProtocol, IPFamily, Endpoint, Endpoint)? {
        guard let space = s.firstIndex(of: " ") else { return nil }
        let kind = s[..<space]
        let family: IPFamily = kind.hasSuffix("6") ? .v6 : .v4
        let proto: TransportProtocol
        switch kind.dropLast() {
        case "tcp": proto = .tcp
        case "udp": proto = .udp
        case "quic": proto = .quic
        default: return nil
        }
        let pair = s[s.index(after: space)...].components(separatedBy: "<->")
        guard pair.count == 2,
              let local = parseEndpoint(pair[0], family: family),
              let remote = parseEndpoint(pair[1], family: family) else { return nil }
        return (proto, family, local, remote)
    }

    static func parseEndpoint(_ s: String, family: IPFamily) -> Endpoint? {
        // IPv4 uses ':' as the port separator, IPv6 uses '.'.
        let separator: Character = family == .v4 ? ":" : "."
        guard let idx = s.lastIndex(of: separator) else { return nil }
        let address = String(s[..<idx])
        let portString = s[s.index(after: idx)...]
        return Endpoint(address: address, port: portString == "*" ? nil : UInt16(portString))
    }
}
