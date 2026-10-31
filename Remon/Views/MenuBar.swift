import SwiftUI

/// The status item: a live mirrored mini-graph and/or stacked rates, rendered to an image
/// (menu bar labels only accept Text/Image).
struct MenuBarLabel: View {
    @Environment(MonitorStore.self) private var store
    @Environment(Preferences.self) private var preferences
    @Environment(SystemMonitor.self) private var system

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
            paused: store.isPaused,
            systemText: preferences.menuBarShowsSystem ? system.latest.map { s in
                ("CPU \(Int(s.cpuTotal * 100))%", s.temperature(.cpu).map { "\(Int($0.rounded()))°C" } ?? "—")
            } : nil
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
    var systemText: (String, String)?

    var body: some View {
        HStack(spacing: 4) {
            if let systemText {
                VStack(alignment: .trailing, spacing: -2) {
                    Text(systemText.0)
                    Text(systemText.1)
                }
                .font(.system(size: 8.5, weight: .medium).monospacedDigit())
                .foregroundStyle(.black)
                .frame(width: 44, alignment: .trailing)
            }
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
    @State private var panelWindow: NSWindow?
    @State private var escapeMonitor: Any?

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

            SystemStrip()
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
                .accessibilityLabel("Floating Monitor")
                Button {
                    store.section = .speedTest
                    showMainWindow()
                    store.runSpeedTest()
                } label: {
                    Image(systemName: "speedometer")
                }
                .help("Run a speed test")
                .accessibilityLabel("Run Speed Test")
                .disabled(store.speedTestRunning)
                Button {
                    store.togglePause()
                } label: {
                    Image(systemName: store.isPaused ? "play.fill" : "pause.fill")
                }
                .help(store.isPaused ? "Resume" : "Pause")
                .accessibilityLabel(store.isPaused ? "Resume Live Updates" : "Pause Live Updates")
                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
                .accessibilityLabel("Settings")
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .help("Quit Remon")
                .accessibilityLabel("Quit Remon")
                .keyboardShortcut("q")
            }
            .buttonStyle(.borderless)
        }
        .padding(16)
        .frame(width: 340)
        // Escape closes the panel, like the system's menu bar extras. The window-style MenuBarExtra
        // never becomes key, so responder-based handling (onExitCommand) can't see the key; watch
        // Remon's key events while the panel is on screen instead.
        .background(WindowReader { panelWindow = $0 })
        .onAppear {
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.keyCode == 53, let window = panelWindow, window.isVisible else { return event }
                Self.dismissPanel(fallback: window)
                return nil
            }
        }
        .onDisappear {
            if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
            escapeMonitor = nil
        }
    }

    /// Closes the panel the way a click on the menu bar item does, so MenuBarExtra's own
    /// open/closed state stays in sync (closing the window directly made the next click a no-op).
    static func dismissPanel(fallback window: NSWindow) {
        func statusButton(in view: NSView?) -> NSStatusBarButton? {
            guard let view else { return nil }
            if let button = view as? NSStatusBarButton { return button }
            for sub in view.subviews { if let hit = statusButton(in: sub) { return hit } }
            return nil
        }
        let button = NSApp.windows.lazy.compactMap { statusButton(in: $0.contentView) }.first
        if let button { button.performClick(nil) } else { window.close() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.path.ecg")
                .font(.headline)
                .foregroundStyle(LinearGradient(colors: [.blue, .purple], startPoint: .leading, endPoint: .trailing))
                .accessibilityHidden(true)
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

/// CPU / GPU / memory / temperature at a glance (menu bar panel and floating monitor).
struct SystemStrip: View {
    @Environment(SystemMonitor.self) private var system

    var body: some View {
        if let s = system.latest {
            HStack(spacing: 0) {
                metric("CPU", percent(s.cpuTotal), s.cpuTotal, .blue)
                metric("GPU", s.gpuUtilization.map(percent) ?? "—", s.gpuUtilization ?? 0, .purple)
                metric("MEM", percent(s.memory.fraction), s.memory.fraction, .green)
                let temp = s.temperature(.cpu)
                metric("TEMP", temp.map(celsius) ?? "—", min((temp ?? 0) / 100, 1), temperatureTint(temp))
            }
        }
    }

    private func metric(_ label: String, _ value: String, _ fraction: Double, _ tint: Color) -> some View {
        VStack(spacing: 3) {
            Text(label).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.semibold).monospacedDigit())
            ProgressView(value: min(max(fraction, 0), 1)).tint(tint).controlSize(.mini)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 4)
    }
}

/// Reports the NSWindow hosting a SwiftUI view (each time it's attached to one).
struct WindowReader: NSViewRepresentable {
    var onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView { Reader(onWindow: onWindow) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Reader: NSView {
        let onWindow: (NSWindow?) -> Void
        init(onWindow: @escaping (NSWindow?) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let window = self.window
            DispatchQueue.main.async { self.onWindow(window) }
        }
    }
}
