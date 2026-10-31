import Charts
import SwiftUI

/// iStat-style system metrics: CPU (per core), GPU, memory, temperatures, fans, power, battery and disk.
struct SystemView: View {
    @Environment(SystemMonitor.self) private var system

    var body: some View {
        ScrollView {
            if let s = system.latest {
                VStack(alignment: .leading, spacing: 16) {
                    tiles(s)
                    HStack(alignment: .top, spacing: 16) {
                        Card("CPU & GPU Load", symbol: "cpu", accessory: AnyView(legend([("CPU", .blue), ("GPU", .purple)]))) {
                            loadChart.frame(height: 170)
                        }
                        Card("Temperatures", symbol: "thermometer.medium", accessory: AnyView(legend([("CPU", .orange), ("GPU", .pink)]))) {
                            temperatureChart.frame(height: 170)
                        }
                    }
                    CoresCard(snapshot: s)
                    HStack(alignment: .top, spacing: 16) {
                        MemoryCard(memory: s.memory)
                        VStack(spacing: 16) {
                            if !s.fans.isEmpty || s.systemPowerWatts != nil { FansPowerCard(snapshot: s) }
                            DiskCard(snapshot: s)
                        }
                    }
                    HStack(alignment: .top, spacing: 16) {
                        SensorsCard(sensors: s.sensors)
                        VStack(spacing: 16) {
                            if let battery = s.battery { BatteryCard(battery: battery) }
                            SystemInfoCard(snapshot: s)
                        }
                    }
                }
                .padding(20)
            } else {
                ProgressView("Reading sensors…").frame(maxWidth: .infinity, minHeight: 300)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func tiles(_ s: SystemSnapshot) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3), spacing: 14) {
            StatTile(title: "CPU", value: percent(s.cpuTotal),
                     detail: "User \(percent(s.cpuUser)) · System \(percent(s.cpuSystem))", symbol: "cpu", tint: .blue)
            StatTile(title: "GPU", value: s.gpuUtilization.map(percent) ?? "—",
                     detail: s.gpuMemory.map { "\(ByteFormat.bytes($0)) in use" }, symbol: "cube.transparent", tint: .purple)
            StatTile(title: "Memory", value: percent(s.memory.fraction),
                     detail: "\(ByteFormat.bytes(s.memory.used)) of \(ByteFormat.bytes(s.memory.total)) · \(s.memory.pressure.rawValue) pressure",
                     symbol: "memorychip", tint: s.memory.pressure == .normal ? .green : (s.memory.pressure == .warning ? .yellow : .red))
            StatTile(title: "CPU Temperature", value: s.temperature(.cpu).map(celsius) ?? "—",
                     detail: s.hottest(.cpu).map { "Hottest \(celsius($0)) · peak \(celsius(system.peakCPUTemperature))" },
                     symbol: "thermometer.medium", tint: temperatureTint(s.temperature(.cpu)))
            StatTile(title: "GPU Temperature", value: s.temperature(.gpu).map(celsius) ?? "—",
                     detail: thermalText(s.thermalState), symbol: "thermometer.variable", tint: temperatureTint(s.temperature(.gpu)))
            StatTile(title: "Power", value: s.systemPowerWatts.map { String(format: "%.1f W", $0) } ?? "—",
                     detail: s.battery.map { battery in
                         "\(Int(battery.percent * 100))% · \(battery.isCharging ? "charging" : (battery.onAC ? "on AC" : "on battery"))"
                     }, symbol: "bolt.fill", tint: .orange)
        }
    }

    private var loadChart: some View {
        Chart {
            ForEach(system.history) { p in
                AreaMark(x: .value("Time", p.date), y: .value("Load", p.cpu * 100), series: .value("Series", "CPU"))
                    .foregroundStyle(LinearGradient(colors: [.blue.opacity(0.35), .blue.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", p.date), y: .value("Load", p.cpu * 100), series: .value("Series", "CPU"))
                    .foregroundStyle(.blue)
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", p.date), y: .value("Load", p.gpu * 100), series: .value("Series", "GPU"))
                    .foregroundStyle(.purple)
                    .interpolationMethod(.monotone)
            }
        }
        .chartYScale(domain: 0...100)
        .chartYAxis { AxisMarks(values: [0, 25, 50, 75, 100]) { v in AxisGridLine(); AxisValueLabel { Text("\(v.as(Int.self) ?? 0)%") } } }
        .chartXAxis(.hidden)
        .chartLegend(.hidden)
    }

    private var temperatureChart: some View {
        let values = system.history.flatMap { [$0.cpuTemperature, $0.gpuTemperature].compactMap { $0 } }
        let low = max(0, (values.min() ?? 30) - 5), high = (values.max() ?? 60) + 5
        return Chart {
            ForEach(system.history) { p in
                if let t = p.cpuTemperature {
                    LineMark(x: .value("Time", p.date), y: .value("°C", t), series: .value("Series", "CPU"))
                        .foregroundStyle(.orange).interpolationMethod(.monotone)
                }
                if let t = p.gpuTemperature {
                    LineMark(x: .value("Time", p.date), y: .value("°C", t), series: .value("Series", "GPU"))
                        .foregroundStyle(.pink).interpolationMethod(.monotone)
                }
            }
        }
        .chartYScale(domain: low...high)
        .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { Text("\(v.as(Int.self) ?? 0)°") } } }
        .chartXAxis(.hidden)
    }

    private func legend(_ items: [(String, Color)]) -> some View {
        HStack(spacing: 8) {
            ForEach(items, id: \.0) { item in
                HStack(spacing: 3) { Circle().fill(item.1).frame(width: 6, height: 6); Text(item.0) }
            }
        }
        .font(.caption2).foregroundStyle(.secondary)
    }

    private func thermalText(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "Thermal state: nominal"
        case .fair: "Thermal state: fair"
        case .serious: "Thermal state: serious — throttling"
        case .critical: "Thermal state: critical"
        @unknown default: "Thermal state: unknown"
        }
    }
}

func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }
func celsius(_ value: Double) -> String { "\(Int(value.rounded())) °C" }

func temperatureTint(_ value: Double?) -> Color {
    guard let value else { return .gray }
    if value >= 90 { return .red }
    if value >= 75 { return .orange }
    if value >= 60 { return .yellow }
    return .green
}

private struct CoresCard: View {
    var snapshot: SystemSnapshot

    var body: some View {
        let cores = snapshot.perCore
        let perf = snapshot.performanceCores
        Card("\(cores.count) Cores", symbol: "square.grid.3x3.fill",
             accessory: AnyView(Text(perf > 0 && snapshot.efficiencyCores > 0 ? "\(perf) performance · \(snapshot.efficiencyCores) efficiency" : "")
                .font(.caption).foregroundStyle(.secondary))) {
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(Array(cores.enumerated()), id: \.offset) { index, load in
                    // macOS numbers efficiency cores first on Apple silicon.
                    let isEfficiency = snapshot.efficiencyCores > 0 && index < snapshot.efficiencyCores
                    VStack(spacing: 4) {
                        GeometryReader { geo in
                            ZStack(alignment: .bottom) {
                                RoundedRectangle(cornerRadius: 4).fill(.quaternary.opacity(0.6))
                                RoundedRectangle(cornerRadius: 4)
                                    .fill((isEfficiency ? Color.teal : Color.blue).gradient)
                                    .frame(height: max(2, geo.size.height * load))
                            }
                        }
                        .frame(height: 70)
                        Text(isEfficiency ? "E" : "P").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        Text("\(Int(load * 100))").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

private struct MemoryCard: View {
    var memory: MemoryReading

    var body: some View {
        let parts: [(String, UInt64, Color)] = [("App", memory.app, .blue), ("Wired", memory.wired, .orange),
                                                 ("Compressed", memory.compressed, .purple), ("Cached", memory.cached, .gray)]
        Card("Memory", symbol: "memorychip") {
            VStack(alignment: .leading, spacing: 10) {
                GeometryReader { geo in
                    HStack(spacing: 1) {
                        ForEach(parts, id: \.0) { part in
                            Rectangle().fill(part.2.gradient)
                                .frame(width: geo.size.width * Double(part.1) / Double(max(memory.total, 1)))
                        }
                        Spacer(minLength: 0)
                    }
                    .clipShape(.rect(cornerRadius: 5))
                    .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 5))
                }
                .frame(height: 14)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    ForEach(parts, id: \.0) { part in
                        GridRow {
                            HStack(spacing: 5) { Circle().fill(part.2).frame(width: 7, height: 7); Text(part.0) }
                            Text(ByteFormat.bytes(part.1)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    GridRow {
                        Text("Free")
                        Text(ByteFormat.bytes(memory.free)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    GridRow {
                        Text("Swap used")
                        Text(ByteFormat.bytes(memory.swapUsed)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    GridRow {
                        Text("Pressure")
                        Text(memory.pressure.rawValue)
                            .foregroundStyle(memory.pressure == .normal ? .green : (memory.pressure == .warning ? .yellow : .red))
                    }
                }
                .font(.callout)
            }
        }
    }
}

private struct FansPowerCard: View {
    var snapshot: SystemSnapshot

    var body: some View {
        Card("Fans & Power", symbol: "fan") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(snapshot.fans) { fan in
                    HStack {
                        Image(systemName: "fan").foregroundStyle(.secondary)
                        Text("Fan \(fan.index + 1)")
                        Spacer()
                        Text(fan.rpm < 1 ? "Off" : "\(Int(fan.rpm)) rpm").monospacedDigit()
                        ProgressView(value: fan.rpm < 1 ? 0 : fan.fraction).frame(width: 90)
                    }
                }
                if let watts = snapshot.systemPowerWatts {
                    HStack {
                        Image(systemName: "bolt.fill").foregroundStyle(.orange)
                        Text("System power")
                        Spacer()
                        Text(String(format: "%.1f W", watts)).monospacedDigit()
                    }
                }
            }
            .font(.callout)
        }
    }
}

private struct DiskCard: View {
    var snapshot: SystemSnapshot

    var body: some View {
        Card("Disk", symbol: "internaldrive") {
            VStack(alignment: .leading, spacing: 8) {
                if let free = snapshot.diskFree, let total = snapshot.diskTotal, total > 0 {
                    ProgressView(value: Double(total - min(free, total)), total: Double(total)) {
                        Text("\(ByteFormat.bytes(free)) available of \(ByteFormat.bytes(total))").font(.callout)
                    }
                }
                HStack {
                    Label(ByteFormat.rate(snapshot.diskReadRate), systemImage: "arrow.down.doc").foregroundStyle(.blue)
                    Spacer()
                    Label(ByteFormat.rate(snapshot.diskWriteRate), systemImage: "arrow.up.doc").foregroundStyle(.orange)
                }
                .font(.callout.monospacedDigit())
            }
        }
    }
}

private struct SensorsCard: View {
    var sensors: [TemperatureSensor]

    var body: some View {
        Card("Sensors (\(sensors.count))", symbol: "sensor") {
            if sensors.isEmpty {
                Text("No temperature sensors are readable on this Mac.").foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(TemperatureSensor.Group.allCases, id: \.self) { group in
                        let items = sensors.filter { $0.group == group }
                        if !items.isEmpty {
                            DisclosureGroup {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], alignment: .leading, spacing: 4) {
                                    ForEach(items) { sensor in
                                        HStack {
                                            Text(sensor.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                            Spacer()
                                            Text(celsius(sensor.celsius)).font(.caption.monospacedDigit())
                                                .foregroundStyle(temperatureTint(sensor.celsius))
                                        }
                                    }
                                }
                                .padding(.top, 4)
                            } label: {
                                HStack {
                                    Text(group.rawValue).font(.callout.weight(.medium))
                                    Spacer()
                                    let avg = items.map(\.celsius).reduce(0, +) / Double(items.count)
                                    Text("avg \(celsius(avg)) · max \(celsius(items.map(\.celsius).max() ?? 0))")
                                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct BatteryCard: View {
    var battery: BatteryReading

    var body: some View {
        Card("Battery", symbol: battery.isCharging ? "battery.100.bolt" : "battery.75") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("\(Int(battery.percent * 100))%").font(.title3.weight(.semibold).monospacedDigit())
                    Text(battery.isCharging ? "Charging" : (battery.onAC ? "On power adapter" : "On battery")).foregroundStyle(.secondary)
                    Spacer()
                    if let minutes = battery.minutesRemaining {
                        Text("\(minutes / 60)h \(minutes % 60)m \(battery.isCharging ? "to full" : "left")").foregroundStyle(.secondary)
                    }
                }
                ProgressView(value: battery.percent).tint(battery.percent < 0.2 ? .red : .green)
                if let health = battery.healthPercent { DetailRow(label: "Health", value: "\(Int(health * 100))% of design capacity") }
                if let cycles = battery.cycleCount { DetailRow(label: "Cycle count", value: "\(cycles)") }
                if let temp = battery.temperature { DetailRow(label: "Temperature", value: String(format: "%.1f °C", temp)) }
            }
        }
    }
}

private struct SystemInfoCard: View {
    var snapshot: SystemSnapshot
    private static let chip: String = {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        return String(cBuffer: buffer)
    }()

    var body: some View {
        Card("This Mac", symbol: "laptopcomputer") {
            VStack(spacing: 6) {
                DetailRow(label: "Chip", value: Self.chip)
                DetailRow(label: "macOS", value: ProcessInfo.processInfo.operatingSystemVersionString)
                DetailRow(label: "Uptime", value: Duration.seconds(snapshot.uptime).formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated, maximumUnitCount: 2)))
                DetailRow(label: "Load average", value: snapshot.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: "  "))
            }
        }
    }
}
