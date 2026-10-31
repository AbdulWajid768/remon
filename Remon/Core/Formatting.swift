import Foundation

/// Fast, allocation-light byte and rate formatting (decimal units, like Activity Monitor).
enum ByteFormat {
    private static let byteUnits = ["B", "KB", "MB", "GB", "TB", "PB"]
    private static let bitUnits = ["b", "Kb", "Mb", "Gb", "Tb", "Pb"]

    static func bytes(_ value: UInt64) -> String { scaled(Double(value), units: byteUnits) }
    static func bytes(_ value: Double) -> String { scaled(max(0, value), units: byteUnits) }

    static func rate(_ bytesPerSecond: Double, bits: Bool = false) -> String {
        let value = max(0, bytesPerSecond) * (bits ? 8 : 1)
        return scaled(value, units: bits ? bitUnits : byteUnits) + (bits ? "ps" : "/s")
    }

    /// Compact form for the menu bar: "1.2M", "820K".
    static func compactRate(_ bytesPerSecond: Double, bits: Bool = false) -> String {
        let value = max(0, bytesPerSecond) * (bits ? 8 : 1)
        let units = ["", "K", "M", "G", "T"]
        var v = value, i = 0
        while v >= 1000 && i < units.count - 1 { v /= 1000; i += 1 }
        let suffix = units[i] + (bits ? "b" : "B")
        if i == 0 { return "\(Int(v)) \(suffix)" }
        return (v < 10 ? String(format: "%.1f", v) : String(format: "%.0f", v)) + " " + suffix
    }

    private static func scaled(_ value: Double, units: [String]) -> String {
        var v = value, i = 0
        while v >= 1000 && i < units.count - 1 { v /= 1000; i += 1 }
        if i == 0 { return "\(Int(v.rounded())) \(units[0])" }
        let format = v < 10 ? "%.2f" : (v < 100 ? "%.1f" : "%.0f")
        return String(format: format, v) + " " + units[i]
    }

    /// Parses "10MB", "1.5 GB", "500k" into bytes. Used by the alert editor.
    static func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).uppercased()
        let number = trimmed.prefix { $0.isNumber || $0 == "." }
        guard let value = Double(number) else { return nil }
        let unit = trimmed.dropFirst(number.count).trimmingCharacters(in: .whitespaces)
        let multiplier: Double = switch unit.first {
        case "K": 1e3
        case "M": 1e6
        case "G": 1e9
        case "T": 1e12
        default: 1
        }
        return value * multiplier
    }
}

extension Date {
    var shortTime: String { formatted(date: .omitted, time: .standard) }
}

extension String {
    /// Decodes a NUL-terminated C buffer (replacement for the deprecated `String(cString: [CChar])`).
    init(cBuffer: [CChar]) {
        self = String(decoding: cBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
