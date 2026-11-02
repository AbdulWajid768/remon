import SwiftUI

struct MainView: View {
    @Environment(MonitorStore.self) private var store
    @Environment(Preferences.self) private var preferences

    private var inspectorBinding: Binding<Bool> {
        Binding(get: { store.showInspector && store.section.hasInspector },
                set: { if store.section.hasInspector { store.showInspector = $0 } })
    }

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            // One inspector for the whole detail column. Per-section inspectors were recreated on every
            // section switch and could come back hidden while the toggle still said "shown"; attaching
            // it to the split view itself instead caused a constraint-update loop on macOS 26.
            // Measured: the detail column's effective minimum is this value plus ~220 pt. At 560 it
            // was ~780 pt, wider than a 900-pt window leaves, so AppKit laid the split view out wider
            // than the window and clipped the sidebar (and the inspector). The E2E `layout` scenario
            // checks this.
            Group { detail }
                .modifier(SectionSearch())
                .frame(minWidth: 340)
                .inspector(isPresented: inspectorBinding) {
                    SectionInspector()
                        .inspectorColumnWidth(min: 280, ideal: 320, max: 440)
                }
        }
        .toolbar { MainToolbar() }
        .sheet(isPresented: $store.showOnboarding) {
            OnboardingView()
                .interactiveDismissDisabled()
        }
        .sheet(isPresented: $store.isQuickOpenPresented) {
            QuickOpenView()
        }
        .navigationTitle(store.section.rawValue)
        .navigationSubtitle(subtitle)
        .modifier(DemoLaunchHooks())
    }

    @ViewBuilder private var detail: some View {
        switch store.section {
        case .overview: OverviewView()
        case .system: SystemView()
        case .apps: AppsView()
        case .connections: ConnectionsView()
        case .map: MapView()
        case .history: HistoryView()
        case .log: ConnectionLogView()
        case .speedTest: SpeedTestView()
        case .alerts: AlertsView()
        case .rules: RulesView()
        }
    }

    private var subtitle: String {
        if store.isPaused { return "Paused" }
        switch store.sourceStatus {
        case .starting: return "Starting…"
        case .failed: return "Per-app data unavailable"
        case .running: return "\(store.activeConnectionCount) connections · \(store.onlineAppCount) apps online"
        }
    }
}

struct Sidebar: View {
    @Environment(MonitorStore.self) private var store

    var body: some View {
        @Bindable var store = store
        List(selection: Binding(get: { store.section }, set: { if let s = $0 { store.section = s } })) {
            Section("Monitor") {
                ForEach(SidebarSection.monitorSections) { section in
                    row(section)
                }
            }
            Section("Tools") {
                ForEach(SidebarSection.toolSections) { section in
                    row(section)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { SidebarFooter().padding(12) }
    }

    private func row(_ section: SidebarSection) -> some View {
        let count = badge(for: section)
        return Label(section.rawValue, systemImage: section.symbol)
            .badge(count)
            // With a badge, macOS exposes only the number to VoiceOver; name the row explicitly.
            .accessibilityLabel(section.rawValue)
            .accessibilityValue(count > 0 ? "\(count)" : "")
            .tag(section)
    }

    private func badge(for section: SidebarSection) -> Int {
        switch section {
        case .apps: store.onlineAppCount
        case .connections: store.activeConnectionCount
        case .alerts: min(store.alerts.events.count, 99)
        default: 0
        }
    }
}

/// Compact live readout pinned at the bottom of the sidebar.
struct SidebarFooter: View {
    @Environment(MonitorStore.self) private var store
    @Environment(Preferences.self) private var preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                // Same meaning as everywhere else (Overview, menu bar panel, floating monitor):
                // green online, red offline. Expensive / Low Data Mode are shown as words in Overview.
                StatusDot(color: store.path.snapshot.isConnected ? .green : .red)
                Text(store.path.statusText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
            }
            ThroughputChart(points: Array(store.throughput.suffix(60)), window: 60, showsAxes: false, interactive: false)
                .frame(height: 36)
            HStack {
                Label(preferences.rate(store.currentIn), systemImage: "arrow.down")
                    .foregroundStyle(Theme.download)
                Spacer()
                Label(preferences.rate(store.currentOut), systemImage: "arrow.up")
                    .foregroundStyle(Theme.upload)
            }
            .font(.caption.monospacedDigit())
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10, style: .continuous))
    }
}

struct MainToolbar: ToolbarContent {
    @Environment(MonitorStore.self) private var store

    var body: some ToolbarContent {
        // App-wide actions, always in the same order and in one glass group. A menu's indicator
        // gets a capsule of its own on macOS 26, so Export hides it to stay in the group.
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                store.togglePause()
            } label: {
                Label(store.isPaused ? "Resume" : "Pause", systemImage: store.isPaused ? "play.fill" : "pause.fill")
            }
            .help(store.isPaused ? "Resume live updates (⇧⌘P)" : "Pause live updates (⇧⌘P)")

            Button {
                store.toggleHUD?()
            } label: {
                Label("Floating Monitor", systemImage: "pip")
            }
            .help("Show or hide the floating monitor (⌥⌘M)")

            Menu {
                Button("Connections as CSV…") { ExportService.export(.connections, format: .csv, store: store) }
                Button("Connections as JSON…") { ExportService.export(.connections, format: .json, store: store) }
                Divider()
                Button("App Usage as CSV…") { ExportService.export(.apps, format: .csv, store: store) }
                Button("App Usage as JSON…") { ExportService.export(.apps, format: .json, store: store) }
                Divider()
                Button("History (30 days) as CSV…") { ExportService.export(.history, format: .csv, store: store) }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .menuIndicator(.hidden)
            .help("Export data")
        }

        if store.section.hasInspector {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation(.snappy) { store.showInspector.toggle() }
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .help("Toggle inspector (⌥⌘I)")
            }
        }
    }
}

/// The toolbar search field, shown only on sections whose content it filters.
private struct SectionSearch: ViewModifier {
    @Environment(MonitorStore.self) private var store
    @FocusState private var searchFocused: Bool
    @State private var handledFocusRequest = 0

    func body(content: Content) -> some View {
        @Bindable var store = store
        if store.section.hasSearch {
            content
                .searchable(text: $store.searchText, placement: .toolbar, prompt: prompt)
                .searchFocused($searchFocused)
                // `initial`: ⌘F on a section without search switches here first, so the request
                // arrives with this view, before the toolbar has built the field; focus it a moment later.
                .onChange(of: store.focusSearchRequest, initial: true) { old, new in
                    guard new != handledFocusRequest else { return }
                    handledFocusRequest = new
                    if old != new { searchFocused = true; return }
                    Task {
                        try? await Task.sleep(for: .milliseconds(150))
                        searchFocused = true
                    }
                }
                .searchSuggestions { SearchSuggestions() }
        } else {
            content
        }
    }

    private var prompt: String {
        switch store.section {
        case .apps: "Search apps, hosts, countries…"
        case .history: "Search apps"
        case .log: "Search app, host, IP, country, organisation"
        case .map: "Filter destinations"
        default: "Search — try app:Safari port:443 -cat:apple"
        }
    }
}

struct SearchSuggestions: View {
    @Environment(MonitorStore.self) private var store

    var body: some View {
        let text = store.searchText.trimmingCharacters(in: .whitespaces)
        if text.count >= 1, !text.contains(":") {
            let apps = store.apps.filter { $0.name.localizedStandardContains(text) }.prefix(4)
            ForEach(Array(apps)) { app in
                Label { Text("app:\(app.name)") } icon: { AppIcon(identity: app.identity, size: 14) }
                    .searchCompletion("app:\"\(app.name)\" ")
            }
            let hosts = Set(store.connections.compactMap(\.hostname).filter { $0.localizedStandardContains(text) }).sorted().prefix(4)
            ForEach(Array(hosts), id: \.self) { host in
                Label("host:\(host)", systemImage: "globe").searchCompletion("host:\(host) ")
            }
            let countries = Set(store.connections.compactMap { c -> String? in
                guard let name = c.geo?.country, name.localizedStandardContains(text) else { return nil }
                return c.geo?.countryCode
            }).sorted().prefix(3)
            ForEach(Array(countries), id: \.self) { code in
                Label("country:\(code)", systemImage: "flag").searchCompletion("country:\(code) ")
            }
        } else if text.isEmpty {
            ForEach(["proto:udp", "port:443", "cat:telemetry", "state:established", "-cat:apple"], id: \.self) { token in
                Label(token, systemImage: "line.3.horizontal.decrease.circle").searchCompletion(token + " ")
            }
        }
    }
}

/// Launch arguments used for unattended screenshots and demos:
/// `-openSettings YES`, `-quickOpen YES`, `-previewMenuPanel YES`.
private struct DemoLaunchHooks: ViewModifier {
    @Environment(MonitorStore.self) private var store
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.task {
            let defaults = UserDefaults.standard
            try? await Task.sleep(for: .seconds(2))
            if defaults.bool(forKey: "openSettings") { openSettings() }
            if defaults.bool(forKey: "quickOpen") { store.isQuickOpenPresented = true }
            if defaults.bool(forKey: "previewMenuPanel") { openWindow(id: "menu-preview") }
        }
    }
}

/// Inspector content for the current section.
struct SectionInspector: View {
    @Environment(MonitorStore.self) private var store

    var body: some View {
        switch store.section {
        case .apps:
            if let app = store.app(id: store.selectedAppID) {
                AppInspector(app: app)
            } else {
                ContentUnavailableView("No Selection", systemImage: "app.dashed",
                                       description: Text("Select an app to see its traffic, connections and history."))
            }
        case .connections:
            if let c = store.connection(id: store.selectedConnectionID) {
                ConnectionInspector(connection: c)
            } else {
                ContentUnavailableView("No Selection", systemImage: "cursorarrow.click",
                                       description: Text("Select a connection to see its endpoints, owner and location."))
            }
        default:
            EmptyView()
        }
    }
}
