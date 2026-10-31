import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            MonitoringSettings().tabItem { Label("Monitoring", systemImage: "waveform.path.ecg") }
            DataPlanSettings().tabItem { Label("Data Plan", systemImage: "chart.pie") }
            PrivacySettings().tabItem { Label("Privacy", systemImage: "hand.raised") }
            NotificationSettings().tabItem { Label("Notifications", systemImage: "bell.badge") }
            AdvancedSettings().tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 540)
        .scenePadding()
    }
}

private struct GeneralSettings: View {
    @Environment(Preferences.self) private var preferences
    @State private var launchAtLogin = false
    @State private var loginError: String?

    var body: some View {
        @Bindable var preferences = preferences
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        guard enabled != preferences.launchAtLogin else { return }
                        loginError = preferences.setLaunchAtLogin(enabled)
                        if loginError != nil { launchAtLogin = preferences.launchAtLogin }
                    }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                Toggle("Show Remon in the Dock", isOn: $preferences.showDockIcon)
                Picker("Appearance", selection: $preferences.appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Color theme", selection: $preferences.colorTheme) {
                    ForEach(ColorTheme.allCases) { theme in
                        let colors = Theme.colors(for: theme)
                        HStack {
                            Image(systemName: "circle.fill").foregroundStyle(colors.download)
                            Image(systemName: "circle.fill").foregroundStyle(colors.upload)
                            Text(theme.rawValue)
                        }
                        .tag(theme)
                    }
                }
                Toggle(isOn: $preferences.hotKeyEnabled) {
                    Text("Global shortcut ⌃⌥⌘R")
                    Text("Brings up Remon from anywhere.")
                }
            }
            Section("Menu Bar") {
                Toggle("Show in menu bar", isOn: $preferences.showMenuBarItem)
                Picker("Style", selection: $preferences.menuBarStyle) {
                    ForEach(MenuBarStyle.allCases) { Text($0.rawValue).tag($0) }
                }
                .disabled(!preferences.showMenuBarItem)
                Toggle("Also show CPU load and temperature", isOn: $preferences.menuBarShowsSystem)
                    .disabled(!preferences.showMenuBarItem)
                Toggle("Colored graph", isOn: $preferences.coloredMenuBarGraph)
                    .disabled(!preferences.showMenuBarItem || preferences.menuBarStyle == .rates || preferences.menuBarStyle == .icon)
                LabeledContent("Preview") { MenuBarLabel() }
            }
            Section("Units") {
                Picker("Show rates in", selection: $preferences.useBits) {
                    Text("Bytes (MB/s)").tag(false)
                    Text("Bits (Mbps)").tag(true)
                }
                .pickerStyle(.radioGroup)
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin = preferences.launchAtLogin }
    }
}

private struct MonitoringSettings: View {
    @Environment(Preferences.self) private var preferences
    @Environment(MonitorStore.self) private var store

    var body: some View {
        @Bindable var preferences = preferences
        Form {
            Section {
                Picker("Update every", selection: $preferences.sampleInterval) {
                    Text("1 second").tag(1)
                    Text("2 seconds").tag(2)
                    Text("5 seconds").tag(5)
                }
                Toggle(isOn: $preferences.groupHelpers) {
                    Text("Group helper processes under their app")
                    Text("e.g. “Google Chrome Helper” is counted as Google Chrome.")
                }
                Toggle(isOn: $preferences.includeLoopback) {
                    Text("Include loopback traffic")
                    Text("Traffic between processes on this Mac (127.0.0.1, ::1).")
                }
            }
            Section("Data Source") {
                LabeledContent("Per-app statistics") {
                    switch store.sourceStatus {
                    case .running: Label("nettop · running", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .starting: Text("Starting…")
                    case .failed(let message): Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
                LabeledContent("Interface counters", value: "Interface MIB (exact 64-bit)")
                LabeledContent("Connectivity", value: "NWPathMonitor")
            }
        }
        .formStyle(.grouped)
        .onChange(of: preferences.sampleInterval) { store.restartMonitoring() }
        .onChange(of: preferences.groupHelpers) { store.restartMonitoring() }
        .onChange(of: preferences.includeLoopback) { store.restartMonitoring() }
    }
}

private struct PrivacySettings: View {
    @Environment(Preferences.self) private var preferences
    @Environment(MonitorStore.self) private var store

    var body: some View {
        @Bindable var preferences = preferences
        Form {
            Section {
                Toggle(isOn: $preferences.resolveHostnames) {
                    Text("Resolve hostnames (reverse DNS)")
                    Text("Uses your system resolver, like any app would.")
                }
                Toggle(isOn: $preferences.geoLookups) {
                    Text("Look up locations and network owners")
                    Text("Sends public IP addresses to ipwho.is over HTTPS. Local addresses never leave your Mac. Results are cached for 30 days.")
                }
            } footer: {
                Text("Remon never inspects packet contents. All history stays in ~/Library/Application Support/Remon.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: preferences.geoLookups) { store.resetResolution() }
        .onChange(of: preferences.resolveHostnames) { store.resetResolution() }
    }
}

private struct NotificationSettings: View {
    @Environment(Preferences.self) private var preferences
    @Environment(MonitorStore.self) private var store

    var body: some View {
        @Bindable var preferences = preferences
        Form {
            Section {
                Toggle("Deliver alerts as macOS notifications", isOn: $preferences.notificationsEnabled)
                LabeledContent("Permission") {
                    switch store.alerts.authorization {
                    case .authorized, .provisional: Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .denied:
                        Button("Open System Settings…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                        }
                    default: Button("Request Permission…") { Task { await store.alerts.requestAuthorization() } }
                    }
                }
            }
            Section("Daily Digest") {
                Toggle("Send a daily summary of usage and top apps", isOn: $preferences.digestEnabled)
                Picker("Deliver at", selection: $preferences.digestHour) {
                    ForEach(6..<24) { hour in
                        Text(Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date())?
                                .formatted(date: .omitted, time: .shortened) ?? "\(hour):00").tag(hour)
                    }
                }
                .disabled(!preferences.digestEnabled)
            }
            Section("Rules") {
                ForEach(store.alerts.rules) { rule in
                    LabeledContent(rule.name) {
                        Text(rule.isEnabled ? "On" : "Off").foregroundStyle(rule.isEnabled ? .primary : .secondary)
                    }
                }
                Text("Edit rules in the Alerts section of the main window.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await store.alerts.refreshAuthorization() }
    }
}

private struct AdvancedSettings: View {
    @Environment(Preferences.self) private var preferences
    @Environment(MonitorStore.self) private var store
    @State private var dbSize: Int64 = 0
    @State private var confirmClear = false

    var body: some View {
        @Bindable var preferences = preferences
        Form {
            Section("History") {
                Picker("Keep history for", selection: $preferences.retentionDays) {
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("1 year").tag(365)
                }
                LabeledContent("Database size", value: ByteFormat.bytes(UInt64(max(dbSize, 0))))
                HStack {
                    Button("Show in Finder") {
                        if let url = store.history?.url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                    Spacer()
                    Button("Clear History…", role: .destructive) { confirmClear = true }
                }
            }
            Section("Setup") {
                Button("Show Welcome Screen Again") {
                    preferences.hasCompletedOnboarding = false
                    store.showOnboarding = true
                }
            }
        }
        .formStyle(.grouped)
        .task { dbSize = await store.history?.databaseSize() ?? 0 }
        .confirmationDialog("Clear all recorded history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) {
                Task {
                    await store.clearHistory()
                    dbSize = await store.history?.databaseSize() ?? 0
                }
            }
        } message: {
            Text("This deletes per-app and total usage history, the known-apps list and the location cache. This can't be undone.")
        }
    }
}

private struct DataPlanSettings: View {
    @Environment(Preferences.self) private var preferences
    @Environment(MonitorStore.self) private var store
    @State private var limitText = ""

    var body: some View {
        @Bindable var preferences = preferences
        Form {
            Section {
                Toggle("Track a monthly data plan", isOn: $preferences.dataPlanEnabled)
                LabeledContent("Monthly limit") {
                    TextField("", text: $limitText, prompt: Text("e.g. 100 GB"))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 140)
                        .onSubmit(applyLimit)
                }
                Picker("Cycle resets on day", selection: $preferences.billingResetDay) {
                    ForEach(1...28, id: \.self) { Text("\($0)").tag($0) }
                }
                Toggle("Count uploads toward the limit", isOn: $preferences.dataPlanCountsUpload)
            } footer: {
                Text("Usage is measured from the whole-machine interface counters stored in Remon's history. Alerts at 80% and 100% can be adjusted in Alerts.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(false)
            Section("This Cycle") {
                LabeledContent("Period", value: "\(store.billingCycle.start.formatted(date: .abbreviated, time: .omitted)) – \(store.billingCycle.end.formatted(date: .abbreviated, time: .omitted))")
                LabeledContent("Used so far", value: ByteFormat.bytes(store.cycleUsage))
                LabeledContent("Projected", value: ByteFormat.bytes(store.billingCycle.projectedUsage(used: store.cycleUsage, at: Date())))
            }
        }
        .formStyle(.grouped)
        .onAppear { limitText = ByteFormat.bytes(preferences.dataPlanLimit) }
        .onDisappear(perform: applyLimit)
        .onChange(of: preferences.billingResetDay) { Task { await store.runInsights(checkAnomalies: false) } }
        .onChange(of: preferences.dataPlanCountsUpload) { Task { await store.runInsights(checkAnomalies: false) } }
    }

    private func applyLimit() {
        if let value = ByteFormat.parse(limitText), value > 0 { preferences.dataPlanLimit = value }
        limitText = ByteFormat.bytes(preferences.dataPlanLimit)
    }
}
