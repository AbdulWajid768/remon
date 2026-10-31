import SwiftUI
import UserNotifications

@main
struct RemonApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = MonitorStore.shared
    @State private var preferences = Preferences.shared

    var body: some Scene {
        @Bindable var preferences = preferences

        Window("Remon", id: "main") {
            MainView()
                .environment(store)
                .environment(preferences)
                .modifier(WindowActionInstaller(store: store))
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1200, height: 780)
        .commands { RemonCommands(store: store) }

        MenuBarExtra(isInserted: $preferences.showMenuBarItem) {
            MenuBarPanel()
                .environment(store)
                .environment(preferences)
        } label: {
            MenuBarLabel()
                .environment(store)
                .environment(preferences)
                .modifier(WindowActionInstaller(store: store))
        }
        .menuBarExtraStyle(.window)

        Window("Floating Monitor", id: "hud") {
            FloatingMonitor()
                .environment(store)
                .environment(preferences)
                .onAppear { store.isHUDVisible = true }
                .onDisappear { store.isHUDVisible = false }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .windowLevel(.floating)
        .windowBackgroundDragBehavior(.enabled)
        .defaultPosition(.topTrailing)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        // The menu bar popover hosted in a plain window; only opened via `-previewMenuPanel YES`.
        Window("Menu Bar Preview", id: "menu-preview") {
            MenuBarPanel()
                .environment(store)
                .environment(preferences)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        Settings {
            SettingsView()
                .environment(store)
                .environment(preferences)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            Preferences.shared.applyAppearance()
            Preferences.shared.applyActivationPolicy()
            MonitorStore.shared.start()
        }
        UNUserNotificationCenter.current().delegate = self
        MainActor.assumeIsolated {
            GlobalHotKey.shared.action = { MonitorStore.shared.show(appID: nil) }
            GlobalHotKey.shared.setEnabled(Preferences.shared.hotKeyEnabled)
        }

        // `kill`/`pkill` send SIGTERM, which bypasses applicationShouldTerminate; flush
        // buffered history before exiting.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            // Don't route through NSApp.terminate: AppKit can refuse while a sheet is up.
            self?.flushHistorySynchronously()
            exit(0)
        }
        source.resume()
        sigtermSource = source
    }

    private var sigtermSource: DispatchSourceSignal?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        flushHistorySynchronously()
        return .terminateNow
    }

    /// Main-actor tasks don't run while AppKit waits on `.terminateLater` (or while a signal
    /// handler is quitting), so write the buffered minute from a detached task with a bounded wait.
    private func flushHistorySynchronously() {
        let (history, pending) = MainActor.assumeIsolated {
            MonitorStore.shared.stop()
            return (MonitorStore.shared.history, MonitorStore.shared.takePendingHistory(includeOpenConnections: true))
        }
        guard let history else { return }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await history.record(bucket: pending.bucket, apps: pending.apps, totalIn: pending.totalIn, totalOut: pending.totalOut)
            await history.logConnections(pending.log)
            done.signal()
        }
        _ = done.wait(timeout: .now() + 2)
    }

    // Show alert banners even while Remon is frontmost.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    // Clicking an alert opens Remon on the app it's about.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let appID = response.notification.request.content.userInfo["appID"] as? String
        await MainActor.run { MonitorStore.shared.show(appID: appID) }
    }
}

/// Gives the store window actions (it has no `openWindow` environment of its own).
struct WindowActionInstaller: ViewModifier {
    var store: MonitorStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    func body(content: Content) -> some View {
        content.onAppear {
            store.openMainWindow = { openWindow(id: "main") }
            store.toggleHUD = {
                if store.isHUDVisible { dismissWindow(id: "hud") } else { openWindow(id: "hud") }
            }
        }
    }
}

struct RemonCommands: Commands {
    var store: MonitorStore
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Show Main Window") {
                openWindow(id: "main")
                NSApp.activate()
            }
            .keyboardShortcut("0")
        }
        CommandGroup(after: .newItem) {
            Divider()
            Button("Export Connections…") { ExportService.export(.connections, format: .csv, store: store) }
                .keyboardShortcut("e")
            Button("Export App Usage…") { ExportService.export(.apps, format: .csv, store: store) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Button("Export History…") { ExportService.export(.history, format: .csv, store: store) }
        }
        CommandGroup(before: .sidebar) {
            ForEach(SidebarSection.allCases) { section in
                Button(section.rawValue) { store.section = section }
                    .keyboardShortcut(KeyEquivalent(section.shortcut))
            }
            Divider()
            Button(store.showInspector ? "Hide Inspector" : "Show Inspector") {
                withAnimation(.snappy) { store.showInspector.toggle() }
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
        }
        CommandMenu("Monitor") {
            Button("Quick Open…") { store.isQuickOpenPresented = true }
                .keyboardShortcut("k")
            Divider()
            Button(store.isPaused ? "Resume Live Updates" : "Pause Live Updates") { store.togglePause() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button(store.isHUDVisible ? "Hide Floating Monitor" : "Show Floating Monitor") { store.toggleHUD?() }
                .keyboardShortcut("m", modifiers: [.command, .option])
            Button("Run Speed Test") {
                store.section = .speedTest
                store.runSpeedTest()
            }
            .disabled(store.speedTestRunning)
            Divider()
            Picker("Connections", selection: Binding(get: { store.connectionScope }, set: { store.connectionScope = $0 })) {
                ForEach(ConnectionScope.allCases) { Text($0.rawValue).tag($0) }
            }
        }
    }
}
