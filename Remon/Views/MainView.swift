import AppKit
import SwiftUI

struct MainView: View {
    @Environment(MonitorStore.self) private var store
    @Environment(Preferences.self) private var preferences

    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var splitFrame: CGRect = .zero
    @State private var searchUI = SearchUIState()
    @State private var isFullScreen = false

    private var inspectorBinding: Binding<Bool> {
        Binding(get: { store.showInspector && store.section.hasInspector },
                set: { if store.section.hasInspector { store.showInspector = $0 } })
    }

    /// With the sidebar hidden the detail column runs to the window edge. In a window that edge is
    /// rounded and inset from the desktop, so content meeting it reads as deliberate; full screen
    /// puts it flush against the side of the display, where the table headers and the scope picker
    /// sit hard against the bezel. The sidebar is an inset panel with a margin of its own, so
    /// losing it shouldn't lose the margin: put it back on the detail column instead.
    private var collapsedGutter: CGFloat { columnVisibility == .detailOnly ? 14 : 0 }

    var body: some View {
        @Bindable var store = store
        NavigationSplitView(columnVisibility: $columnVisibility) {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
                .toolbar { SidebarToolbar(isFullScreen: isFullScreen) }
        } detail: {
            // One inspector for the whole detail column. Per-section inspectors were recreated on every
            // section switch and could come back hidden while the toggle still said "shown"; attaching
            // it to the split view itself instead caused a constraint-update loop on macOS 26.
            // Measured: the detail column's effective minimum is this value plus ~220 pt. At 560 it
            // was ~780 pt, wider than a 900-pt window leaves, so AppKit laid the split view out wider
            // than the window and clipped the sidebar (and the inspector). The E2E `layout` scenario
            // checks this.
            Group { detail }
                .safeAreaPadding(.leading, collapsedGutter)
                .animation(.snappy(duration: 0.25), value: collapsedGutter)
                .frame(minWidth: 340)
                // The translucent window body every section sits on; see `WindowGlass`.
                .background(WindowGlass(isFullScreen: isFullScreen).ignoresSafeArea())
                .inspector(isPresented: inspectorBinding) {
                    SectionInspector()
                        .inspectorColumnWidth(min: 280, ideal: 320, max: 440)
                }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { splitFrame = $0 }
        // `-sidebarCollapsed YES|NO`, for demos and for capturing either sidebar layout. Only
        // honoured when the argument is actually present, so an ordinary launch keeps whatever
        // the window restored.
        .task {
            guard UserDefaults.standard.object(forKey: "sidebarCollapsed") != nil else { return }
            columnVisibility = UserDefaults.standard.bool(forKey: "sidebarCollapsed") ? .detailOnly : .all
        }
        // The suggestion panel hangs off the toolbar field. A popover would take key focus away
        // from the field mid-typing, so it is an overlay in this window, positioned under the
        // field's measured frame.
        .overlay(alignment: .topLeading) {
            if searchUI.showingSuggestions, store.section.hasSearch, searchUI.fieldFrame != .zero {
                SearchSuggestionPanel { completion in
                    store.searchText = completion
                }
                .offset(x: searchUI.fieldFrame.minX - splitFrame.minX,
                        y: searchUI.fieldFrame.maxY - splitFrame.minY + 6)
                .transaction { $0.animation = nil }
            }
        }
        .environment(searchUI)
        .background { FullScreenReporter(isFullScreen: $isFullScreen) }
        .toolbar { MainToolbar() }
        // In a window the title bar is transparent and the glass body runs up to the top edge. In
        // full screen AppKit gives the toolbar a material of its own, a darker strip across the
        // detail column with a grey slab over the sidebar, and the window reads as three panels
        // stacked at the top. Nothing scrolls under the toolbar that needs separating, so keep the
        // body continuous.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
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
    /// Groups the user has folded away, by title. Kept in defaults, so the sidebar comes back the
    /// way it was left.
    @State private var collapsed = Set(UserDefaults.standard.stringArray(forKey: Sidebar.defaultsKey) ?? [])

    private static let defaultsKey = "sidebarCollapsedGroups"

    var body: some View {
        @Bindable var store = store
        List(selection: Binding(get: { store.section }, set: { if let s = $0 { store.section = s } })) {
            ForEach(SidebarSection.groups) { group in
                // Hovering a group header shows macOS's own Show/Hide control, as in Finder and Mail.
                Section(group.title, isExpanded: expansion(of: group)) {
                    ForEach(group.sections) { section in
                        row(section)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        // The current section has to stay visible, whether it was chosen here or from somewhere else
        // (⌘1…⌘9, Quick Open, a click in Overview), so open its group if it was folded. `initial`
        // covers launching straight into a section inside a folded group.
        .onChange(of: store.section, initial: true) { _, section in
            guard let group = SidebarSection.group(containing: section), collapsed.contains(group.id) else { return }
            withAnimation(.snappy) { setCollapsed(group.id, false) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { SidebarFooter() }
    }

    private func expansion(of group: SidebarGroup) -> Binding<Bool> {
        Binding(get: { !collapsed.contains(group.id) }, set: { setCollapsed(group.id, !$0) })
    }

    private func setCollapsed(_ id: String, _ isCollapsed: Bool) {
        if isCollapsed { collapsed.insert(id) } else { collapsed.remove(id) }
        UserDefaults.standard.set(collapsed.sorted(), forKey: Self.defaultsKey)
    }

    private func row(_ section: SidebarSection) -> some View {
        // Only Alerts carries a badge: new alerts are worth a glance, while live app and connection
        // counts changed every second and made the list busy (they're in the window subtitle).
        let count = section == .alerts ? min(store.alerts.events.count, 99) : 0
        return Label(section.rawValue, systemImage: section.symbol)
            .badge(count)
            // With a badge, macOS exposes only the number to VoiceOver; name the row explicitly.
            .accessibilityLabel(section.rawValue)
            .accessibilityValue(count > 0 ? "\(count)" : "")
            .tag(section)
    }
}

/// Compact live readout pinned at the bottom of the sidebar: connection state, a one-minute
/// trace and the current rates.
struct SidebarFooter: View {
    @Environment(MonitorStore.self) private var store
    @Environment(Preferences.self) private var preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack(spacing: 6) {
                // Same meaning as everywhere else (Overview, menu bar panel, floating monitor):
                // green online, red offline. Expensive / Low Data Mode are shown as words in Overview.
                StatusDot(color: store.path.snapshot.isConnected ? Palette.jade : Palette.garnet)
                Text(store.path.statusText).font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if store.isPaused {
                    Image(systemName: "pause.circle.fill").font(.caption).foregroundStyle(Palette.ember)
                        .help("Live updates are paused")
                }
            }
            .padding(.top, 4)
            ThroughputChart(points: Array(store.throughput.suffix(60)), window: 60, showsAxes: false, interactive: false)
                .frame(height: 34)
            HStack {
                Label(preferences.rate(store.currentIn), systemImage: "arrow.down")
                    .foregroundStyle(Theme.download)
                Spacer()
                Label(preferences.rate(store.currentOut), systemImage: "arrow.up")
                    .foregroundStyle(Theme.upload)
            }
            .font(.caption.monospacedDigit())
        }
        .padding(.horizontal, 14).padding(.bottom, 12)
    }
}

/// The sidebar column's share of the toolbar. Full screen strips the window of its traffic
/// lights, which leaves the sidebar's top block empty and the top of the window with no sign of
/// which app it is. The toolbar strip is the only thing that can draw in that band — a SwiftUI
/// overlay is clipped to the column's frame, which starts below it — so the wordmark goes here,
/// where the traffic lights were. It stays out of the detail column so the section title keeps
/// its place over the content.
struct SidebarToolbar: ToolbarContent {
    var isFullScreen = false

    private var logo: some View {
        RemonLogo()
            .frame(height: 15)
            .padding(.leading, 4)
            .accessibilityHidden(true)
    }

    var body: some ToolbarContent {
        if isFullScreen {
            if #available(macOS 26, *) {
                // macOS 26 gives every toolbar item a glass capsule, which would make the logo
                // look like a button you can press. The mark is decoration, so drop it.
                ToolbarItem(placement: .principal) { logo }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .principal) { logo }
            }
        }
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

        // Always in the same place; dimmed where the section has nothing to inspect, so the
        // toolbar doesn't reshuffle when switching sections.
        ToolbarItem(placement: .primaryAction) {
            Button {
                withAnimation(.snappy) { store.showInspector.toggle() }
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .disabled(!store.section.hasInspector)
            .help(store.section.hasInspector ? "Toggle inspector (⌥⌘I)" : "This section has no inspector")
        }
    }
}

/// Launch arguments used for unattended screenshots and demos:
/// `-openSettings YES`, `-quickOpen YES`, `-previewMenuPanel YES`, `-fullScreen YES`.
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
            // `-fullScreen YES`: the window's chrome differs in full screen (no traffic lights, no
            // title bar), so the screenshots cover it too.
            if defaults.bool(forKey: "fullScreen"),
               let window = NSApp.windows.first(where: { $0.isVisible && $0.collectionBehavior.contains(.fullScreenPrimary) }),
               !window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            }
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


/// Reports whether the window this view lives in is full screen. The sidebar's top block is only
/// dead space there, so the chrome needs to know.
private struct FullScreenReporter: NSViewRepresentable {
    @Binding var isFullScreen: Bool

    func makeNSView(context: Context) -> NSView { Reporter(isFullScreen: $isFullScreen) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Reporter: NSView {
        private let isFullScreen: Binding<Bool>
        private var observers: [NSObjectProtocol] = []

        init(isFullScreen: Binding<Bool>) {
            self.isFullScreen = isFullScreen
            super.init(frame: .zero)
        }

        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Re-registered rather than torn down in deinit: the observers are scoped to one
            // window, and this view outlives none of them.
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            report(window)
            let center = NotificationCenter.default
            for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report(window) }
                })
            }
        }

        private func report(_ window: NSWindow) {
            let full = window.styleMask.contains(.fullScreen)
            if isFullScreen.wrappedValue != full { isFullScreen.wrappedValue = full }
        }
    }
}
