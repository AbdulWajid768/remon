import SwiftUI
import UserNotifications

struct AlertsView: View {
    @Environment(MonitorStore.self) private var store
    @Environment(Preferences.self) private var preferences
    @State private var editing: AlertRule?

    var body: some View {
        let alerts = store.alerts
        Form {
            if preferences.notificationsEnabled && alerts.authorization != .authorized && alerts.authorization != .provisional {
                Section {
                    HStack {
                        Image(systemName: "bell.slash").foregroundStyle(.orange)
                        Text(alerts.authorization == .denied
                             ? "Notifications are turned off for Remon in System Settings. Alerts will still appear in the log below."
                             : "Allow notifications so alerts reach you while Remon is in the background.")
                        Spacer()
                        if alerts.authorization == .denied {
                            Button("Open Settings") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                            }
                        } else {
                            Button("Allow…") { Task { await alerts.requestAuthorization() } }
                        }
                    }
                }
            }

            Section {
                ForEach(alerts.rules) { rule in
                    RuleRow(rule: rule, onEdit: { editing = rule })
                }
                .onDelete { alerts.rules.remove(atOffsets: $0) }
            } header: {
                HStack {
                    Text("Rules")
                    Spacer()
                    Button {
                        editing = AlertRule(name: "New Rule", kind: .totalRate)
                    } label: {
                        Label("Add Rule", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                }
            }

            Section {
                if alerts.events.isEmpty {
                    Text("No alerts yet. Triggered alerts are logged here.").foregroundStyle(.secondary)
                }
                ForEach(alerts.events) { event in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: event.symbol).foregroundStyle(.tint).frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(event.title).font(.headline)
                                Spacer()
                                Text(event.date.formatted(date: .omitted, time: .standard)).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(event.message).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                HStack {
                    Text("Recent Alerts")
                    Spacer()
                    if !alerts.events.isEmpty {
                        Button("Clear") { alerts.clearEvents() }.buttonStyle(.borderless)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { rule in
            AlertRuleEditor(rule: rule) { saved in
                if let index = alerts.rules.firstIndex(where: { $0.id == saved.id }) {
                    alerts.rules[index] = saved
                } else {
                    alerts.rules.append(saved)
                }
            }
        }
        .task { await alerts.refreshAuthorization() }
    }
}

private struct RuleRow: View {
    var rule: AlertRule
    var onEdit: () -> Void
    @Environment(MonitorStore.self) private var store

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: rule.kind.symbol)
                .foregroundStyle(rule.isEnabled ? Color.accentColor : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name)
                Text(rule.summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Edit…", action: onEdit).buttonStyle(.borderless)
            AccessibleSwitch(label: "\(rule.name) enabled", isOn: Binding(
                get: { rule.isEnabled },
                set: { newValue in
                    if let i = store.alerts.rules.firstIndex(where: { $0.id == rule.id }) { store.alerts.rules[i].isEnabled = newValue }
                }))
        }
        .contextMenu {
            Button("Edit…", action: onEdit)
            Button("Delete", role: .destructive) { store.alerts.rules.removeAll { $0.id == rule.id } }
        }
    }
}

struct AlertRuleEditor: View {
    @State var rule: AlertRule
    var onSave: (AlertRule) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(MonitorStore.self) private var store
    @State private var thresholdText = ""

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Name", text: $rule.name)
                Picker("Trigger", selection: $rule.kind) {
                    ForEach(AlertRule.Kind.allCases) { kind in
                        Label(kind.rawValue, systemImage: kind.symbol).tag(kind)
                    }
                }
                if rule.kind == .appRate {
                    Picker("App", selection: Binding(get: { rule.appID ?? "" }, set: { id in
                        rule.appID = id.isEmpty ? nil : id
                        rule.appName = store.apps.first { $0.id == id }?.name ?? rule.appName
                    })) {
                        Text("Any app").tag("")
                        if let id = rule.appID, !store.apps.contains(where: { $0.id == id }) {
                            Text(rule.appName ?? id).tag(id)
                        }
                        ForEach(store.apps.sorted { $0.name < $1.name }) { app in
                            Text(app.name).tag(app.id)
                        }
                    }
                }
                if rule.kind.usesThreshold {
                    LabeledContent(rule.kind == .dailyTotal ? "Budget" : "Threshold") {
                        HStack {
                            TextField("", text: $thresholdText, prompt: Text("e.g. 5 MB"))
                                .frame(width: 120)
                                .multilineTextAlignment(.trailing)
                            Text(rule.kind.thresholdUnit ?? (rule.kind == .dailyTotal ? "" : "per second")).foregroundStyle(.secondary)
                        }
                    }
                }
                if rule.kind.usesDuration {
                    Stepper("Sustained for \(rule.sustainSeconds) s", value: $rule.sustainSeconds, in: 1...600, step: 5)
                }
                if rule.kind != .newApp {
                    Picker("Don't repeat for", selection: $rule.cooldownMinutes) {
                        ForEach([1, 5, 15, 30, 60, 240], id: \.self) { Text("\($0) min").tag($0) }
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    if rule.kind.thresholdUnit != nil {
                        if let value = Double(thresholdText.filter { $0.isNumber || $0 == "." }) { rule.threshold = value }
                    } else if let value = ByteFormat.parse(thresholdText) {
                        rule.threshold = value
                    }
                    onSave(rule)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(rule.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 460)
        .onAppear {
            thresholdText = rule.kind.thresholdUnit != nil ? String(Int(rule.threshold)) : ByteFormat.bytes(rule.threshold)
        }
        .onChange(of: rule.kind) { _, kind in
            // Switching kinds changes the threshold's unit; start from a sensible default.
            switch kind {
            case .dataPlan: rule.threshold = 80
            case .highTemperature: rule.threshold = 90
            case .dailyTotal: rule.threshold = 10_000_000_000
            default: rule.threshold = 5_000_000
            }
            thresholdText = kind.thresholdUnit != nil ? String(Int(rule.threshold)) : ByteFormat.bytes(rule.threshold)
        }
    }
}
