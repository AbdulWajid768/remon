import Foundation

struct SpeedTestResult: Identifiable, Hashable, Sendable, Codable {
    var id = UUID()
    var date: Date
    /// Bits per second.
    var download: Double
    var upload: Double
    /// Round trips per minute under load (Apple's "responsiveness").
    var responsivenessRPM: Double?
    var baseRTTms: Double?
    var interface: String?

    var responsivenessRating: String {
        guard let rpm = responsivenessRPM else { return "—" }
        switch rpm {
        case ..<200: return "Low"
        case ..<800: return "Medium"
        default: return "High"
        }
    }
}

enum SpeedTestError: LocalizedError {
    case unavailable
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: "networkQuality isn't available on this Mac."
        case .failed(let message): message
        }
    }
}

/// Runs Apple's built-in `networkQuality` tool (the same test as System Settings › Wi-Fi ›
/// Details) and parses its machine-readable output. No third-party speed-test servers.
enum SpeedTestRunner {
    static let executable = URL(fileURLWithPath: "/usr/bin/networkQuality")

    static func run(maxSeconds: Int = 25) async throws -> SpeedTestResult {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw SpeedTestError.unavailable }
        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = executable
            process.arguments = ["-c", "-M", String(maxSeconds)]
            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.standardInput = FileHandle.nullDevice
            try process.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let errorText = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw SpeedTestError.failed(errorText.isEmpty ? "networkQuality exited with status \(process.terminationStatus)." : errorText)
            }
            return try parse(data)
        }.value
    }

    static func parse(_ data: Data, now: Date = Date()) throws -> SpeedTestResult {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SpeedTestError.failed("Unexpected networkQuality output.")
        }
        func number(_ key: String) -> Double? {
            if let n = json[key] as? NSNumber { return n.doubleValue }
            if let s = json[key] as? String { return Double(s) }
            return nil
        }
        guard let download = number("dl_throughput"), let upload = number("ul_throughput") else {
            throw SpeedTestError.failed((json["error_code"] as? String) ?? "networkQuality returned no throughput.")
        }
        return SpeedTestResult(date: now, download: download, upload: upload,
                               responsivenessRPM: number("responsiveness") ?? number("dl_responsiveness"),
                               baseRTTms: number("base_rtt"), interface: json["interface_name"] as? String)
    }
}
