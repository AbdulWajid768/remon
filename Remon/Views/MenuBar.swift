import SwiftUI

/// The status item: a live mirrored mini-graph and/or stacked rates, rendered to an image
/// (menu bar labels only accept Text/Image).
struct MenuBarLabel: View {
    @Environment(MonitorStore.self) private var store
    @Environment(Preferences.self) private var preferences

    var body: some View {
        switch preferences.menuBarStyle {
        case .icon:
            Image(systemName: "waveform.path.ecg")
        default:
            Image(nsImage: renderImage())
        }
    }

    private func renderImage() -> NSImage {
        let style = preferences.menuBarStyle
        let colored = preferences.coloredMenuBarGraph
        let samples = Array(store.throughput.suffix(24))
        let content = MenuBarGlyph(
            samples: samples,
            down: preferences.compactRate(store.currentIn),
            up: preferences.compactRate(store.currentOut),
            showGraph: style == .graph || style == .graphAndRates,
            showRates: style == .rates || style == .graphAndRates,
            colored: colored,
            paused: store.isPaused
        )
        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "Remon")!
        image.isTemplate = !colored
        image.accessibilityDescription = "Remon: download \(preferences.rate(store.currentIn)), upload \(preferences.rate(store.currentOut))"
        return image
    }
}

private struct MenuBarGlyph: View {
    var samples: [ThroughputPoint]
    var down: String
    var up: String
    var showGraph: Bool
    var showRates: Bool
    var colored: Bool
    var paused: Bool

    var body: some View {
        HStack(spacing: 4) {
            if showGraph {
                Canvas { context, size in
                    let mid = size.height / 2
                    let peak = max(samples.map { max($0.rateIn, $0.rateOut) }.max() ?? 0, 4_000)
                    let barWidth = size.width / 24
                    for (i, s) in samples.enumerated() {
                        let x = size.width - CGFloat(samples.count - i) * barWidth
                        let hIn = max(0.5, CGFloat(s.rateIn / peak) * (mid - 0.5))
                        let hOut = max(0.5, CGFloat(s.rateOut / peak) * (mid - 0.5))
                        let downRect = CGRect(x: x, y: mid - hIn, width: barWidth - 0.4, height: hIn)
                        let upRect = CGRect(x: x, y: mid + 0.5, width: barWidth - 0.4, height: hOut)
                        context.fill(Path(downRect), with: .color(colored ? Theme.download : .black))
                        context.fill(Path(upRect), with: .color(colored ? Theme.upload : .black.opacity(0.55)))
                    }
                }
                .frame(width: 30, height: 16)
                .opacity(paused ? 0.4 : 1)
            }
            if showRates {
                VStack(alignment: .trailing, spacing: -2) {
                    Text("↓ " + down)
                    Text("↑ " + up)
                }
                .font(.system(size: 8.5, weight: .medium).monospacedDigit())
                .foregroundStyle(.black)
                .frame(width: 52, alignment: .trailing)
            }
        }
        .frame(height: 18)
    }
}

/// Popover shown when clicking the status item.
struct MenuBarPanel: View {
    @Environment(MonitorStore.self) private var store
    @Environment(Preferences.self) private var preferences
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            HStack(spacing: 10) {
                bigRate("Download", store.currentIn, Theme.download, "arrow.down")
                bigRate("Upload", store.currentOut, Theme.upload, "arrow.up")
            }
            ThroughputChart(points: Array(store.throughput.suffix(60)), window: 60, showsAxes: false, interactive: true, animated: true)
                .frame(height: 70)
            HStack {
                Text("Today").foregroundStyle(.secondary)
                Spacer()
                Text("↓ \(ByteFormat.bytes(store.todayIn))").foregroundStyle(Theme.download)
                Text("↑ \(ByteFormat.bytes(store.todayOut))").foregroundStyle(Theme.upload)
            }
            .font(.callout.monospacedDigit())
            if preferences.dataPlanEnabled {
                let fraction = Double(store.cycleUsage) / max(preferences.dataPlanLimit, 1)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Data plan").foregroundStyle(.secondary)
                        Spacer()
                        Text("\(ByteFormat.bytes(store.cycleUsage)) / \(ByteFormat.bytes(preferences.dataPlanLimit))").monospacedDigit()
                    }
                    ProgressView(value: min(fraction, 1))
                        .tint(fraction >= 1 ? .red : (fraction >= 0.8 ? .orange : .green))
                }
                .font(.callout)
            }
            if let ip = store.environment.publicIP {
                HStack(spacing: 6) {
                    Image(systemName: store.environment.isVPNActive ? "lock.shield.fill" : "globe")
                        .foregroundStyle(store.environment.isVPNActive ? .green : .secondary)
                    Text(ip).monospaced()
                    Spacer()
                    Text(store.environment.publicGeo.map { "\($0.flag) \($0.org ?? $0.placeDescription)" } ?? "")
                        .foregroundStyle(.secondary).lineLimit(1)
                }
                .font(.caption)
            }

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Top Apps").font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                let top = store.apps.filter { $0.totalRate > 0 || $0.connectionCount > 0 }.prefix(5)
                if top.isEmpty {
                    Text("Quiet right now").foregroundStyle(.secondary).font(.callout)
                }
                ForEach(Array(top)) { app in
                    Button {
                        store.selectedAppID = app.id
                        store.section = .apps
                        showMainWindow()
                    } label: {
                        HStack(spacing: 8) {
                            AppIcon(identity: app.identity, size: 18)
                            Text(app.name).lineLimit(1)
                            Spacer()
                            RateText(rate: app.rateIn, direction: .down, font: .caption)
                            RateText(rate: app.rateOut, direction: .up, font: .caption)
                                .frame(minWidth: 64, alignment: .trailing)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
            .animation(.snappy, value: store.apps.prefix(5).map(\.id))

            Divider()
            HStack(spacing: 12) {
                Button {
                    showMainWindow()
                } label: {
                    Label("Open Remon", systemImage: "macwindow")
                }
                .keyboardShortcut("o")
                Spacer()
                Button {
                    store.toggleHUD?()
                } label: {
                    Image(systemName: "pip")
                }
                .help("Floating monitor")
                Button {
                    store.section = .speedTest
                    showMainWindow()
                    store.runSpeedTest()
                } label: {
                    Image(systemName: "speedometer")
                }
                .help("Run a speed test")
                .disabled(store.speedTestRunning)
                Button {
                    store.togglePause()
                } label: {
                    Image(systemName: store.isPaused ? "play.fill" : "pause.fill")
                }
                .help(store.isPaused ? "Resume" : "Pause")
                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .help("Quit Remon")
                .keyboardShortcut("q")
            }
            .buttonStyle(.borderless)
        }
        .padding(16)
        .frame(width: 340)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.path.ecg")
                .font(.headline)
                .foregroundStyle(LinearGradient(colors: [.blue, .purple], startPoint: .leading, endPoint: .trailing))
            Text("Remon").font(.headline)
            Spacer()
            HStack(spacing: 5) {
                StatusDot(color: store.path.snapshot.isConnected ? .green : .red)
                Text(store.path.statusText)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.quaternary.opacity(0.6), in: .capsule)
        }
    }

    private func bigRate(_ title: String, _ rate: Double, _ color: Color, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(color)
            Text(preferences.rate(rate))
                .font(.title2.weight(.semibold).monospacedDigit())
                .contentTransition(.numericText(value: rate))
                .animation(.snappy, value: rate)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.1), in: .rect(cornerRadius: 10, style: .continuous))
    }

    private func showMainWindow() {
        openWindow(id: "main")
        NSApp.activate()
    }
}
