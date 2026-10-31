import Darwin
import Foundation
import IOKit
import IOKit.ps

struct TemperatureSensor: Identifiable, Hashable, Sendable {
    var name: String
    var celsius: Double
    var group: Group
    var id: String { name }

    enum Group: String, Sendable, CaseIterable {
        case cpu = "CPU"
        case gpu = "GPU"
        case battery = "Battery"
        case storage = "Storage"
        case other = "Other"
    }
}

struct FanReading: Identifiable, Hashable, Sendable {
    var index: Int
    var rpm: Double
    var minRPM: Double
    var maxRPM: Double
    var id: Int { index }
    var fraction: Double { maxRPM > minRPM ? min(max((rpm - minRPM) / (maxRPM - minRPM), 0), 1) : 0 }
}

struct BatteryReading: Hashable, Sendable {
    var percent: Double
    var isCharging: Bool
    var onAC: Bool
    var minutesRemaining: Int?
    var cycleCount: Int?
    /// "Maximum Capacity" exactly as macOS reports it (System Settings › Battery › Battery Health).
    var maximumCapacity: Double?
    /// "Normal" / "Service Recommended", as macOS reports it.
    var condition: String?
    /// Raw gauge figures (mAh): what the cells hold now vs. when new. Apple's figure above is normalized
    /// by powerd and is usually a few points higher than raw/design.
    var rawCapacity: Int?
    var designCapacity: Int?
    var temperature: Double?

    var rawHealth: Double? {
        guard let raw = rawCapacity, let design = designCapacity, design > 0 else { return nil }
        return min(Double(raw) / Double(design), 1)
    }
}

/// macOS's own battery-health numbers. powerd computes "Maximum Capacity" itself and doesn't publish
/// it in the IORegistry, so read it the documented way (`system_profiler SPPowerDataType -json`,
/// ~0.1 s) and cache it — it changes over weeks, not seconds.
enum BatteryHealthReader {
    struct Health: Sendable { var maximumCapacity: Double?; var condition: String? }

    static func read() -> Health? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPPowerDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parse(data)
    }

    static func parse(_ data: Data) -> Health? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["SPPowerDataType"] as? [[String: Any]],
              let info = items.lazy.compactMap({ $0["sppower_battery_health_info"] as? [String: Any] }).first else { return nil }
        let percent = (info["sppower_battery_health_maximum_capacity"] as? String)
            .flatMap { Double($0.filter { $0.isNumber || $0 == "." }) }.map { $0 / 100 }
        let condition = (info["sppower_battery_health"] as? String).map { raw -> String in
            switch raw.lowercased() {
            case "good": "Normal"
            case "fair", "poor", "check battery", "service recommended": "Service Recommended"
            default: raw
            }
        }
        return Health(maximumCapacity: percent, condition: condition)
    }
}

struct MemoryReading: Hashable, Sendable {
    var total: UInt64
    var app: UInt64
    var wired: UInt64
    var compressed: UInt64
    var cached: UInt64
    var free: UInt64
    var swapUsed: UInt64
    var pressure: Pressure

    var used: UInt64 { app + wired + compressed }
    var fraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    enum Pressure: String, Sendable { case normal = "Normal", warning = "Warning", critical = "Critical" }
}

struct SystemSnapshot: Sendable {
    var date: Date
    var cpuUser: Double
    var cpuSystem: Double
    var perCore: [Double]
    var performanceCores: Int
    var efficiencyCores: Int
    var loadAverage: [Double]
    var memory: MemoryReading
    var gpuUtilization: Double?
    var gpuMemory: UInt64?
    var sensors: [TemperatureSensor]
    var gpuTemperatureSMC: Double?
    var fans: [FanReading]
    var systemPowerWatts: Double?
    var battery: BatteryReading?
    var diskReadRate: Double
    var diskWriteRate: Double
    var diskFree: UInt64?
    var diskTotal: UInt64?
    var thermalState: ProcessInfo.ThermalState
    var uptime: TimeInterval

    var cpuTotal: Double { cpuUser + cpuSystem }

    func temperature(_ group: TemperatureSensor.Group) -> Double? {
        let values = sensors.filter { $0.group == group }.map(\.celsius)
        guard !values.isEmpty else { return group == .gpu ? gpuTemperatureSMC : nil }
        return values.reduce(0, +) / Double(values.count)
    }

    func hottest(_ group: TemperatureSensor.Group) -> Double? {
        sensors.filter { $0.group == group }.map(\.celsius).max() ?? (group == .gpu ? gpuTemperatureSMC : nil)
    }
}

/// Samples CPU, GPU, memory, sensors, fans, power, battery and disk using public Mach/IOKit APIs,
/// plus the IOHIDEventSystem temperature sensors (resolved at runtime) and read-only SMC keys.
/// None of this needs root.
actor SystemSampler {
    private var previousTicks: [[UInt32]] = []
    private var previousDisk: (read: UInt64, write: UInt64, date: Date)?
    private var batteryHealth: (value: BatteryHealthReader.Health?, date: Date)?
    private let hid = HIDTemperatureReader()
    private let smc = SMCReader()
    private let coreLayout = SystemSampler.readCoreLayout()

    func sample() -> SystemSnapshot {
        let now = Date()
        let (user, system, perCore) = cpuLoad()
        let disk = diskCounters()
        var readRate = 0.0, writeRate = 0.0
        if let prev = previousDisk {
            let dt = max(now.timeIntervalSince(prev.date), 0.1)
            readRate = Double(disk.read &- prev.read) / dt
            writeRate = Double(disk.write &- prev.write) / dt
            if disk.read < prev.read || disk.write < prev.write { readRate = 0; writeRate = 0 }
        }
        previousDisk = (disk.read, disk.write, now)
        let gpu = Self.gpuStats()
        let volume = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])

        return SystemSnapshot(
            date: now, cpuUser: user, cpuSystem: system, perCore: perCore,
            performanceCores: coreLayout.performance, efficiencyCores: coreLayout.efficiency,
            loadAverage: Self.loadAverage(), memory: Self.memory(),
            gpuUtilization: gpu.utilization, gpuMemory: gpu.memory,
            sensors: hid?.read() ?? [], gpuTemperatureSMC: smc?.gpuTemperature(),
            fans: smc?.fans() ?? [], systemPowerWatts: smc?.systemPower(),
            battery: battery(), diskReadRate: readRate, diskWriteRate: writeRate,
            diskFree: volume?.volumeAvailableCapacityForImportantUsage.map { UInt64(max($0, 0)) },
            diskTotal: volume?.volumeTotalCapacity.map { UInt64(max($0, 0)) },
            thermalState: ProcessInfo.processInfo.thermalState, uptime: Self.uptime())
    }

    // MARK: CPU

    private func cpuLoad() -> (user: Double, system: Double, perCore: [Double]) {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return (0, 0, []) }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        var ticks: [[UInt32]] = []
        for cpu in 0..<Int(count) {
            let base = cpu * Int(CPU_STATE_MAX)
            ticks.append((0..<Int(CPU_STATE_MAX)).map { UInt32(bitPattern: info[base + $0]) })
        }
        defer { previousTicks = ticks }
        guard previousTicks.count == ticks.count else { return (0, 0, Array(repeating: 0, count: ticks.count)) }

        var totalUser = 0.0, totalSystem = 0.0, totalAll = 0.0
        var perCore: [Double] = []
        for (now, prev) in zip(ticks, previousTicks) {
            let d = zip(now, prev).map { Double($0 &- $1) }
            let user = d[Int(CPU_STATE_USER)] + d[Int(CPU_STATE_NICE)]
            let system = d[Int(CPU_STATE_SYSTEM)]
            let all = d.reduce(0, +)
            perCore.append(all > 0 ? (user + system) / all : 0)
            totalUser += user
            totalSystem += system
            totalAll += all
        }
        return totalAll > 0 ? (totalUser / totalAll, totalSystem / totalAll, perCore) : (0, 0, perCore)
    }

    private static func readCoreLayout() -> (performance: Int, efficiency: Int) {
        func int(_ name: String) -> Int {
            var value: Int32 = 0
            var size = MemoryLayout<Int32>.size
            return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : 0
        }
        let levels = int("hw.nperflevels")
        if levels >= 2 { return (int("hw.perflevel0.logicalcpu"), int("hw.perflevel1.logicalcpu")) }
        return (int("hw.logicalcpu"), 0)
    }

    private static func loadAverage() -> [Double] {
        var loads = [Double](repeating: 0, count: 3)
        return getloadavg(&loads, 3) == 3 ? loads : []
    }

    private static func uptime() -> TimeInterval {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &boot, &size, nil, 0) == 0 else { return 0 }
        return Date().timeIntervalSince1970 - Double(boot.tv_sec)
    }

    static func bootTime() -> Int {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        return sysctl(&mib, 2, &boot, &size, nil, 0) == 0 ? Int(boot.tv_sec) : 0
    }

    // MARK: Memory

    private static func memory() -> MemoryReading {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        var total: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &total, &size, nil, 0)
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)
        var level: Int32 = 1
        var levelSize = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0)
        let pressure: MemoryReading.Pressure = level >= 4 ? .critical : (level >= 2 ? .warning : .normal)
        guard result == KERN_SUCCESS else {
            return MemoryReading(total: total, app: 0, wired: 0, compressed: 0, cached: 0, free: total, swapUsed: swap.xsu_used, pressure: pressure)
        }
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let page = UInt64(pageSize)
        let internalPages = UInt64(stats.internal_page_count), purgeable = UInt64(stats.purgeable_count)
        let app = (internalPages > purgeable ? internalPages - purgeable : 0) * page
        let wired = UInt64(stats.wire_count) * page
        let compressed = UInt64(stats.compressor_page_count) * page
        let cached = (UInt64(stats.external_page_count) + purgeable) * page
        let used = app + wired + compressed
        let free = total > used + cached ? total - used - cached : 0
        return MemoryReading(total: total, app: app, wired: wired, compressed: compressed, cached: cached,
                             free: free, swapUsed: swap.xsu_used, pressure: pressure)
    }

    // MARK: GPU

    private static func gpuStats() -> (utilization: Double?, memory: UInt64?) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return (nil, nil)
        }
        defer { IOObjectRelease(iterator) }
        var best: (Double?, UInt64?) = (nil, nil)
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let stats = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { continue }
            let utilization = (stats["Device Utilization %"] as? NSNumber)?.doubleValue
            let memory = (stats["In use system memory"] as? NSNumber)?.uint64Value
            if let utilization, utilization >= (best.0 ?? -1) { best = (utilization / 100, memory) }
        }
        return best
    }

    // MARK: Disk

    private func diskCounters() -> (read: UInt64, write: UInt64) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else {
            return (0, 0)
        }
        defer { IOObjectRelease(iterator) }
        var read: UInt64 = 0, write: UInt64 = 0
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let stats = IORegistryEntryCreateCFProperty(entry, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { continue }
            read += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            write += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        return (read, write)
    }

    // MARK: Battery

    private func battery() -> BatteryReading? {
        guard var reading = Self.batteryBasics() else { return nil }
        if batteryHealth == nil || Date().timeIntervalSince(batteryHealth!.date) > 600 {
            batteryHealth = (BatteryHealthReader.read(), Date())
        }
        reading.maximumCapacity = batteryHealth?.value?.maximumCapacity
        reading.condition = batteryHealth?.value?.condition
        return reading
    }

    private static func batteryBasics() -> BatteryReading? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let current = (desc[kIOPSCurrentCapacityKey] as? Double) ?? 0
            let max = (desc[kIOPSMaxCapacityKey] as? Double) ?? 100
            let charging = (desc[kIOPSIsChargingKey] as? Bool) ?? false
            let onAC = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let minutes = (charging ? desc[kIOPSTimeToFullChargeKey] : desc[kIOPSTimeToEmptyKey]) as? Int
            var reading = BatteryReading(percent: max > 0 ? current / max : 0, isCharging: charging, onAC: onAC,
                                         minutesRemaining: (minutes ?? -1) > 0 ? minutes : nil)
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
            if service != 0 {
                defer { IOObjectRelease(service) }
                func prop(_ key: String) -> NSNumber? {
                    IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber
                }
                reading.cycleCount = prop("CycleCount")?.intValue
                reading.rawCapacity = prop("AppleRawMaxCapacity")?.intValue
                reading.designCapacity = prop("DesignCapacity")?.intValue
                if let temp = prop("Temperature")?.doubleValue { reading.temperature = temp / 100 }
            }
            return reading
        }
        return nil
    }
}

// MARK: - IOHIDEventSystem temperature sensors

/// Reads die/battery/NAND temperature sensors through IOHIDEventSystemClient. The functions are
/// exported by IOKit but not declared in the SDK headers, so they're resolved with `dlsym`;
/// if any is missing the reader simply isn't created.
private final class HIDTemperatureReader: @unchecked Sendable {
    private typealias CreateFn = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatchingFn = @convention(c) (AnyObject, CFDictionary) -> Int32
    private typealias CopyServicesFn = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyPropertyFn = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?
    private typealias CopyEventFn = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias GetFloatFn = @convention(c) (AnyObject, Int32) -> Double

    private let client: AnyObject
    private let copyServices: CopyServicesFn
    private let copyProperty: CopyPropertyFn
    private let copyEvent: CopyEventFn
    private let getFloat: GetFloatFn
    private static let temperatureEvent: Int64 = 15

    init?() {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let create = dlsym(handle, "IOHIDEventSystemClientCreate"),
              let setMatching = dlsym(handle, "IOHIDEventSystemClientSetMatching"),
              let copyServices = dlsym(handle, "IOHIDEventSystemClientCopyServices"),
              let copyProperty = dlsym(handle, "IOHIDServiceClientCopyProperty"),
              let copyEvent = dlsym(handle, "IOHIDServiceClientCopyEvent"),
              let getFloat = dlsym(handle, "IOHIDEventGetFloatValue"),
              let client = unsafeBitCast(create, to: CreateFn.self)(kCFAllocatorDefault)?.takeRetainedValue() else { return nil }
        // Apple vendor page 0xff00, usage 5 = temperature sensors.
        _ = unsafeBitCast(setMatching, to: SetMatchingFn.self)(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        self.client = client
        self.copyServices = unsafeBitCast(copyServices, to: CopyServicesFn.self)
        self.copyProperty = unsafeBitCast(copyProperty, to: CopyPropertyFn.self)
        self.copyEvent = unsafeBitCast(copyEvent, to: CopyEventFn.self)
        self.getFloat = unsafeBitCast(getFloat, to: GetFloatFn.self)
    }

    func read() -> [TemperatureSensor] {
        guard let services = copyServices(client)?.takeRetainedValue() as? [AnyObject] else { return [] }
        var byName: [String: TemperatureSensor] = [:]
        for service in services {
            guard let name = copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String,
                  let event = copyEvent(service, Self.temperatureEvent, 0, 0)?.takeRetainedValue() else { continue }
            let value = getFloat(event, Int32(Self.temperatureEvent << 16))
            guard value > 0, value < 130, !name.contains("tcal") else { continue }
            let key = byName[name] == nil ? name : "\(name) #\(byName.count)"
            byName[key] = TemperatureSensor(name: key, celsius: value, group: Self.group(for: name))
        }
        return byName.values.sorted { ($0.group.rawValue, $0.name) < ($1.group.rawValue, $1.name) }
    }

    static func group(for name: String) -> TemperatureSensor.Group {
        let lower = name.lowercased()
        if lower.contains("battery") || lower.contains("gas gauge") { return .battery }
        if lower.contains("nand") || lower.contains("ssd") { return .storage }
        if lower.contains("gpu") { return .gpu }
        if lower.contains("tdie") || lower.contains("cpu") || lower.contains("soc") || lower.contains("pacc") || lower.contains("eacc") { return .cpu }
        return .other
    }
}

// MARK: - SMC (fans, power, GPU temperature)

private struct SMCParam {
    struct Version { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0; var release: UInt16 = 0 }
    struct PLimit { var version: UInt16 = 0, length: UInt16 = 0; var cpu: UInt32 = 0, gpu: UInt32 = 0, mem: UInt32 = 0 }
    struct KeyInfo { var dataSize: UInt32 = 0; var dataType: UInt32 = 0; var attributes: UInt8 = 0 }
    var key: UInt32 = 0
    var version = Version()
    var pLimit = PLimit()
    var keyInfo = KeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

/// Read-only access to the System Management Controller through the public `AppleSMC` user client.
private final class SMCReader: @unchecked Sendable {
    private var connection: io_connect_t = 0
    private var gpuKeys: [String]?

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else { return nil }
    }

    deinit { IOServiceClose(connection) }

    func fans() -> [FanReading] {
        guard let count = value("FNum"), count > 0 else { return [] }
        return (0..<min(Int(count), 4)).compactMap { i in
            guard let rpm = value("F\(i)Ac") else { return nil }
            return FanReading(index: i, rpm: rpm, minRPM: value("F\(i)Mn") ?? 0, maxRPM: value("F\(i)Mx") ?? 0)
        }
    }

    func systemPower() -> Double? {
        guard let watts = value("PSTR"), watts > 0, watts < 1000 else { return nil }
        return watts
    }

    func gpuTemperature() -> Double? {
        let candidates = ["Tg05", "Tg0D", "Tg0L", "Tg0T", "Tg0f", "Tg0j", "Tg0P", "Tg0X", "Tg0b", "Tg1k", "Tf14", "Tf18", "Tf19", "Tf24"]
        if gpuKeys == nil {
            gpuKeys = candidates.filter { key in value(key).map { $0 > 5 && $0 < 130 } ?? false }
        }
        let readings = (gpuKeys ?? []).compactMap { value($0) }.filter { $0 > 5 && $0 < 130 }
        return readings.isEmpty ? nil : readings.reduce(0, +) / Double(readings.count)
    }

    private func call(_ input: inout SMCParam) -> SMCParam? {
        var output = SMCParam()
        var size = MemoryLayout<SMCParam>.stride
        let status = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<SMCParam>.stride, &output, &size)
        return status == kIOReturnSuccess && output.result == 0 ? output : nil
    }

    func value(_ key: String) -> Double? {
        let code = key.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        var infoRequest = SMCParam()
        infoRequest.key = code
        infoRequest.data8 = 9 // kSMCGetKeyInfo
        guard let info = call(&infoRequest) else { return nil }
        var readRequest = SMCParam()
        readRequest.key = code
        readRequest.keyInfo.dataSize = info.keyInfo.dataSize
        readRequest.data8 = 5 // kSMCReadKey
        guard let output = call(&readRequest) else { return nil }
        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(Int(info.keyInfo.dataSize))) }
        switch info.keyInfo.dataType {
        case 0x666C_7420 where bytes.count == 4: // "flt "
            return Double(Float(bitPattern: UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24))
        case 0x6670_6532 where bytes.count == 2: // "fpe2"
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case 0x7370_3738 where bytes.count == 2: // "sp78"
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        case 0x7569_3820 where bytes.count == 1: // "ui8 "
            return Double(bytes[0])
        case 0x7569_3136 where bytes.count == 2: // "ui16"
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        default:
            return nil
        }
    }
}
