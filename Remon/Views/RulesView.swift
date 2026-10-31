import SwiftUI

/// Firewall-style rules. Enforcement goes through `ConnectionPolicyEnforcer`; this build ships
/// a stub, so the UI states plainly that rules are recorded but not enforced.
struct RulesView: View {
    @Environment(MonitorStore.self) private var store
    @State private var showingAdd = false

    var body: some View {
        let policy = store.policy
        Form {
            if case .unavailable(let reason) = policy.availability {
                Section {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "shield.lefthalf.filled.slash")
                            .font(.title2)
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Rules are not enforced in this build").font(.headline)
                            Text(reason).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section {
                if policy.rules.isEmpty {
                    Text("No rules. Right-click an app in Apps to create one, or use the + button.")
                        .foregroundStyle(.secondary)
                }
                ForEach(policy.rules) { rule in
                    HStack(spacing: 10) {
                        Image(nsImage: IconCache.shared.icon(forAppID: rule.appID, name: rule.appName))
                            .resizable().frame(width: 22, height: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.appName)
                            Text("\(rule.action.rawValue) · \(rule.host ?? "any destination")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(policy.isEnforcing ? "Enforced" : "Not enforced")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(policy.isEnforcing ? .green : .orange)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background((policy.isEnforcing ? Color.green : .orange).opacity(0.15), in: .capsule)
                        Toggle("Enabled", isOn: Binding(
                            get: { rule.isEnabled },
                            set: { v in if let i = policy.rules.firstIndex(where: { $0.id == rule.id }) { policy.rules[i].isEnabled = v } }))
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                    .contextMenu {
                        Button("Delete", role: .destructive) { policy.rules.removeAll { $0.id == rule.id } }
                    }
                }
                .onDelete { policy.rules.remove(atOffsets: $0) }
            } header: {
                HStack {
                    Text("Rules")
                    Spacer()
                    Button { showingAdd = true } label: { Label("Add Rule", systemImage: "plus") }
                        .buttonStyle(.borderless)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingAdd) { AddPolicyRuleSheet() }
    }
}

private struct AddPolicyRuleSheet: View {
    @Environment(MonitorStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var appID = ""
    @State private var action: PolicyRule.Action = .deny
    @State private var host = ""

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Picker("App", selection: $appID) {
                    Text("Choose…").tag("")
                    ForEach(store.apps.sorted { $0.name < $1.name }) { app in
                        Text(app.name).tag(app.id)
                    }
                }
                Picker("Action", selection: $action) {
                    ForEach(PolicyRule.Action.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                TextField("Destination", text: $host, prompt: Text("Any (or a host / IP)"))
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    let name = store.apps.first { $0.id == appID }?.name ?? appID
                    let trimmed = host.trimmingCharacters(in: .whitespaces)
                    store.policy.rules.append(PolicyRule(appID: appID, appName: name, action: action, host: trimmed.isEmpty ? nil : trimmed))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(appID.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 420)
    }
}
