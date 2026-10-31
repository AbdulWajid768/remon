import SwiftUI

struct OverviewView: View {
    @Environment(MonitorStore.self) private var store
    @Environment(Preferences.self) private var preferences

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if case .failed(let message) = store.sourceStatus {
                    SourceFailureBanner(message: message)
                }
                tiles
                if preferences.dataPlanEnabled { DataPlanCard() }
                Card("Live Throughput", symbol: "waveform.path.ecg", accessory: AnyView(legend)) {
                    ThroughputChart(points: store.throughput)
                        .frame(height: 220)
                }
                HStack(alignment: .top, spacing: 16) {
                    TopAppsCard()
                    VStack(spacing: 16) {
                        NetworkCard()
                        DestinationsCard()
                    }
                }
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var tiles: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3), spacing: 14) {
            StatTile(title: "Download", value: preferences.rate(store.currentIn),
                     detail: "Peak \(preferences.rate(store.peakIn))", symbol: "arrow.down.circle.fill", tint: Theme.download)
            StatTile(title: "Upload", value: preferences.rate(store.currentOut),
                     detail: "Peak \(preferences.rate(store.peakOut))", symbol: "arrow.up.circle.fill", tint: Theme.upload)
            StatTile(title: "Today", value: ByteFormat.bytes(store.todayIn + store.todayOut),
                     detail: "↓ \(ByteFormat.bytes(store.todayIn))  ↑ \(ByteFormat.bytes(store.todayOut))",
                     symbol: "calendar", tint: .purple)
            StatTile(title: "This Session", value: ByteFormat.bytes(store.sessionIn + store.sessionOut),
                     detail: "Since \(store.startedAt.formatted(date: .omitted, time: .shortened))",
                     symbol: "clock.arrow.circlepath", tint: .teal)
            StatTile(title: "Connections", value: "\(store.activeConnectionCount)",
                     detail: "\(store.onlineAppCount) apps online", symbol: "point.3.filled.connected.trianglepath.dotted", tint: .green)
            StatTile(title: "Unattributed", value: ByteFormat.bytes(store.unattributedIn + store.unattributedOut),
                     detail: "Kernel total minus per-app", symbol: "questionmark.circle", tint: .gray)
        }
    }

    private var legend: some View {
        HStack(spacing: 12) {
            Label("Download", systemImage: "circle.fill").foregroundStyle(Theme.download)
            Label("Upload", systemImage: "circle.fill").foregroundStyle(Theme.upload)
            Text("Last 5 min").foregroundStyle(.secondary)
        }
        .font(.caption)
        .labelStyle(LegendLabelStyle())
    }
}

private struct LegendLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 7))
            configuration.title.foregroundStyle(.secondary)
        }
    }
}

struct SourceFailureBanner: View {
    var message: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text("Per-app monitoring is unavailable").font(.headline)
                Text("\(message) Whole-machine throughput from interface counters is still live. Remon retries automatically.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.yellow.opacity(0.12), in: .rect(cornerRadius: 10))
    }
}

struct TopAppsCard: View {
    @Environment(MonitorStore.self) private var store
    @Environment(Preferences.self) private var preferences

    var body: some View {
        Card("Top Apps Right Now", symbol: "flame") {
            let top = Array(store.apps.prefix(8))
            if top.isEmpty {
                Text(store.sourceStatus == .running ? "No network activity yet." : "Waiting for data…")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                let maxRate = max(top.map(\.totalRate).max() ?? 1, 1)
                VStack(spacing: 10) {
                    ForEach(top) { app in
                        Button {
                            store.selectedAppID = app.id
                            store.section = .apps
                        } label: {
                            row(app, maxRate: maxRate)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(minWidth: 320)
    }

    private func row(_ app: AppTraffic, maxRate: Double) -> some View {
        HStack(spacing: 10) {
            AppIcon(identity: app.identity, size: 24)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(app.name).lineLimit(1)
                    Spacer()
                    Text(app.totalRate < 1 ? ByteFormat.bytes(app.sessionTotal) : preferences.rate(app.totalRate))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(app.totalRate < 1 ? .secondary : .primary)
                }
                GeometryReader { geo in
                    HStack(spacing: 1) {
                        Capsule().fill(Theme.download).frame(width: geo.size.width * app.rateIn / maxRate)
                        Capsule().fill(Theme.upload).frame(width: geo.size.width * app.rateOut / maxRate)
                    }
                }
                .frame(height: 4)
                .background(.quaternary.opacity(0.6), in: .capsule)
            }
        }
        .contentShape(.rect)
    }
}

struct NetworkCard: View {
    @Environment(MonitorStore.self) private var store
    @Environment(Preferences.self) private var preferences

    var body: some View {
        let snapshot = store.path.snapshot
        Card("Network", symbol: snapshot.primaryKind?.symbol ?? "network") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    StatusDot(color: snapshot.isConnected ? .green : .red)
                    Text(snapshot.isConnected ? "Connected" : "Offline").font(.callout.weight(.medium))
                    if snapshot.isExpensive { pill("Expensive", .orange) }
                    if snapshot.isConstrained { pill("Low Data Mode", .yellow) }
                    Spacer()
                    Text([snapshot.supportsIPv4 ? "IPv4" : nil, snapshot.supportsIPv6 ? "IPv6" : nil].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let ip = store.environment.publicIP {
                    HStack(spacing: 6) {
                        Image(systemName: store.environment.isVPNActive ? "lock.shield.fill" : "globe")
                            .foregroundStyle(store.environment.isVPNActive ? .green : .secondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(ip).font(.callout.monospaced()).textSelection(.enabled)
                            Text([store.environment.publicGeo?.org, store.environment.publicGeo?.placeDescription]
                                    .compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if store.environment.isVPNActive { pill("VPN", .green) }
                    }
                }
                if let wifi = store.environment.wifi {
                    HStack(spacing: 6) {
                        SignalBars(bars: wifi.bars).frame(width: 18, height: 12)
                        Text(wifi.ssid ?? "Wi-Fi").font(.callout)
                        Text("\(wifi.quality) · \(wifi.rssi) dBm · SNR \(wifi.signalToNoise) dB")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text([wifi.band, wifi.channel.map { "ch \($0)" }, "\(Int(wifi.transmitRate)) Mbps"].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Divider()
                ForEach(store.interfaces.prefix(5)) { iface in
                    HStack(spacing: 8) {
                        Image(systemName: iface.kind.symbol).frame(width: 18).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(iface.kind.rawValue) · \(iface.name)").font(.callout)
                            if let address = iface.addresses.first(where: { !$0.contains(":") }) ?? iface.addresses.first {
                                Text(address).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            RateText(rate: iface.rateIn, direction: .down, font: .caption)
                            RateText(rate: iface.rateOut, direction: .up, font: .caption)
                        }
                    }
                }
                if store.interfaces.isEmpty {
                    Text("No active interfaces").foregroundStyle(.secondary)
                }
            }
        }
    }

    private func pill(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2.weight(.semibold)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: .capsule)
    }
}

struct DestinationsCard: View {
    @Environment(MonitorStore.self) private var store

    private struct Bucket: Identifiable {
        var id: String
        var flag: String
        var name: String
        var count: Int
    }

    var body: some View {
        Card("Where Your Traffic Goes", symbol: "globe.europe.africa") {
            let buckets = computeBuckets()
            if buckets.isEmpty {
                Text("Resolving destinations…").foregroundStyle(.secondary)
            } else {
                let total = buckets.reduce(0) { $0 + $1.count }
                VStack(spacing: 6) {
                    ForEach(buckets.prefix(6)) { bucket in
                        HStack {
                            Text(bucket.flag)
                            Text(bucket.name).lineLimit(1)
                            Spacer()
                            Text("\(bucket.count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            ProgressView(value: Double(bucket.count), total: Double(total))
                                .progressViewStyle(.linear)
                                .frame(width: 70)
                        }
                        .font(.callout)
                    }
                }
            }
        }
    }

    private func computeBuckets() -> [Bucket] {
        var counts: [String: Bucket] = [:]
        for c in store.connections where !c.isListening && !c.isClosed {
            guard let geo = c.geo else { continue }
            let key = geo.scope == .publicInternet ? (geo.countryCode ?? "??") : geo.scope.label
            let name = geo.scope == .publicInternet ? (geo.country ?? "Unknown") : geo.scope.label
            counts[key, default: Bucket(id: key, flag: geo.flag, name: name, count: 0)].count += 1
        }
        return counts.values.sorted { $0.count > $1.count }
    }
}

struct SignalBars: View {
    var bars: Int
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i < bars ? AnyShapeStyle(.primary) : AnyShapeStyle(.quaternary))
                    .frame(width: 3, height: CGFloat(4 + i * 3))
            }
        }
    }
}

struct DataPlanCard: View {
    @Environment(MonitorStore.self) private var store
    @Environment(Preferences.self) private var preferences

    var body: some View {
        let limit = max(preferences.dataPlanLimit, 1)
        let fraction = Double(store.cycleUsage) / limit
        let cycle = store.billingCycle
        let projected = cycle.projectedUsage(used: store.cycleUsage, at: Date())
        let tint: Color = fraction >= 1 ? .red : (fraction >= 0.8 ? .orange : .green)
        Card("Data Plan", symbol: "chart.pie") {
            HStack(spacing: 20) {
                ZStack {
                    UsageRing(fraction: fraction, tint: tint, lineWidth: 9)
                    Text("\(Int((fraction * 100).rounded()))%").font(.headline.monospacedDigit())
                }
                .frame(width: 70, height: 70)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(ByteFormat.bytes(store.cycleUsage)) of \(ByteFormat.bytes(limit))")
                        .font(.title3.weight(.semibold).monospacedDigit())
                    Text("Cycle \(cycle.start.formatted(.dateTime.month().day())) – \(cycle.end.formatted(.dateTime.month().day())) · resets in \(daysLeft(cycle)) days")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("Projected \(ByteFormat.bytes(projected)) by cycle end" + (Double(projected) > limit ? " — over your limit" : ""))
                        .font(.callout).foregroundStyle(Double(projected) > limit ? .orange : .secondary)
                }
                Spacer()
                ProgressView(value: cycle.fractionElapsed(at: Date())) {
                    Text("Time elapsed").font(.caption).foregroundStyle(.secondary)
                }
                .frame(width: 160)
            }
        }
    }

    private func daysLeft(_ cycle: BillingCycle) -> Int {
        max(0, Calendar.current.dateComponents([.day], from: Date(), to: cycle.end).day ?? 0)
    }
}
