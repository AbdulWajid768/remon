import SwiftUI

struct OnboardingView: View {
    @Environment(MonitorStore.self) private var store
    @Environment(Preferences.self) private var preferences
    @State private var page = 0
    @State private var launchAtLogin = false
    @State private var loginError: String?

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch page {
                case 0: welcome.transition(.push(from: .trailing))
                case 1: privacy.transition(.push(from: .trailing))
                default: finish.transition(.push(from: .trailing))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            Divider()
            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<3) { i in
                        Capsule()
                            .fill(i == page ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: i == page ? 18 : 7, height: 7)
                    }
                }
                Spacer()
                if page > 0 {
                    Button("Back") { withAnimation(.snappy) { page -= 1 } }
                }
                Button(page == 2 ? "Start Monitoring" : "Continue") {
                    if page == 2 {
                        preferences.hasCompletedOnboarding = true
                        store.showOnboarding = false
                    } else {
                        withAnimation(.snappy) { page += 1 }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(width: 600, height: 500)
        .animation(.snappy, value: page)
        .onAppear { launchAtLogin = preferences.launchAtLogin }
    }

    private var welcome: some View {
        VStack(spacing: 18) {
            Image(systemName: "waveform.path.ecg.rectangle.fill")
                .font(.system(size: 64, weight: .regular))
                .foregroundStyle(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                .symbolEffect(.pulse, options: .repeating)
            Text("Welcome to Remon").font(.largeTitle.weight(.bold))
            Text("See every app talking to the network — how much, to whom, and where in the world — right from your menu bar.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440)
            VStack(alignment: .leading, spacing: 14) {
                feature("chart.xyaxis.line", .blue, "Live per-app bandwidth", "Download and upload for every process, updated every second.")
                feature("globe.americas.fill", .green, "Every connection, explained", "Hostnames, countries, owners and a label for what each destination is.")
                feature("bell.badge.fill", .orange, "Calm, useful alerts", "Know when something unusual happens — without a prompt for every packet.")
            }
            .padding(.top, 8)
        }
        .padding(32)
    }

    private var privacy: some View {
        @Bindable var preferences = preferences
        return VStack(spacing: 18) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 52))
                .foregroundStyle(.teal)
                .symbolEffect(.bounce, value: page)
            Text("Your data stays on your Mac").font(.title.weight(.bold))
            Text("Remon reads traffic statistics from macOS. It never inspects the contents of your traffic, and history is stored only on this Mac.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 460)
            Form {
                Toggle(isOn: $preferences.resolveHostnames) {
                    Text("Resolve hostnames")
                    Text("Reverse DNS through your normal resolver.")
                }
                Toggle(isOn: $preferences.geoLookups) {
                    Text("Look up locations")
                    Text("Sends public IP addresses (never local ones) to ipwho.is to find country, city and network owner. Results are cached for 30 days.")
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(maxWidth: 480, maxHeight: 190)
        }
        .padding(32)
    }

    private var finish: some View {
        @Bindable var preferences = preferences
        return VStack(spacing: 18) {
            Image(systemName: "menubar.arrow.up.rectangle")
                .font(.system(size: 52))
                .foregroundStyle(.indigo)
                .symbolEffect(.bounce, value: page)
            Text("Always one glance away").font(.title.weight(.bold))
            Text("Remon lives in your menu bar with a live graph. Close the window any time — monitoring continues.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 460)
            Form {
                Toggle("Show in menu bar", isOn: $preferences.showMenuBarItem)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        loginError = preferences.setLaunchAtLogin(enabled)
                        if loginError != nil { launchAtLogin = preferences.launchAtLogin }
                    }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Text("Notifications")
                    Spacer()
                    switch store.alerts.authorization {
                    case .authorized, .provisional:
                        Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .denied:
                        Text("Turned off in System Settings").foregroundStyle(.secondary)
                    default:
                        Button("Allow Notifications…") { Task { await store.alerts.requestAuthorization() } }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(maxWidth: 480, maxHeight: 200)
        }
        .padding(32)
    }

    private func feature(_ symbol: String, _ color: Color, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.title2).foregroundStyle(color).frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 440, alignment: .leading)
    }
}
