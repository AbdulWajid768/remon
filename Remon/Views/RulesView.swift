import SwiftUI

/// Block rules: one-click presets (e.g. macOS updates), domains and individual servers.
struct RulesView: View {
    @Environment(MonitorStore.self) private var store
    @State private var showingAdd = false
    @State private var selection = Set<PolicyRule.ID>()
    @State private var confirmClear = false

    var body: some View {
        let policy = store.policy
        Form {
            statusSection(policy)

            Section {
                ForEach(BlockPreset.all) { preset in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: preset.symbol).font(.title3).foregroundStyle(.tint).frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.name)
                            Text(preset.detail).font(.caption).foregroundStyle(.secondary)
                            Text(preset.domains.joined(separator: ", ")).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        AccessibleSwitch(label: "Block \(preset.name)",
                                         isOn: Binding(get: { policy.isActive(preset) }, set: { _ in policy.toggle(preset) }),
                                         small: false)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Quick Blocks")
            }

            ruleSection(title: "Blocked Domains", empty: "No domains blocked. Domains are blocked for every app via /etc/hosts.",
                        rules: policy.rules.filter(\.isDomain), policy: policy)
            ruleSection(title: "Blocked Servers", empty: "No servers blocked. Right-click a connection and choose Block Server.",
                        rules: policy.rules.filter { !$0.isDomain }, policy: policy)

            Section {
                Text(PolicyCenter.perAppNote).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItem {
                Button { showingAdd = true } label: { Label("Add Block Rule", systemImage: "plus") }
                    .help("Block a domain or server address")
            }
        }
        .sheet(isPresented: $showingAdd) { AddBlockRuleSheet() }
        .confirmationDialog("Unblock everything?", isPresented: $confirmClear) {
            Button("Unblock All", role: .destructive) { policy.removeAll() }
        } message: {
            Text("All domain and server rules will be removed from /etc/hosts and the packet filter.")
        }
        .onAppear { policy.refreshActiveDomains() }
    }

    @ViewBuilder
    private func statusSection(_ policy: PolicyCenter) -> some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                let ok = !policy.needsApply && policy.lastError == nil
                Image(systemName: policy.isApplying ? "hourglass" : (ok ? "checkmark.shield.fill" : "exclamationmark.shield.fill"))
                    .font(.title2)
                    .foregroundStyle(policy.isApplying ? Color.secondary : (ok ? Color.green : Color.orange))
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    if policy.isApplying {
                        Text("Applying rules…").font(.headline)
                        Text("macOS will ask for an administrator password.").font(.callout).foregroundStyle(.secondary)
                    } else if let error = policy.lastError {
                        Text("Rules not applied").font(.headline)
                        Text(error).font(.callout).foregroundStyle(.secondary)
                    } else if policy.needsApply {
                        Text("Rules need to be applied").font(.headline)
                        Text(policy.enabledAddresses.isEmpty || policy.addressRulesActive
                             ? "Some rules aren't active yet."
                             : "Server blocks are cleared when the Mac restarts — apply them again.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text(policy.rules.isEmpty ? "Nothing blocked" : "Blocking is active").font(.headline)
                        Text("\(policy.enabledDomains.count) domains · \(policy.enabledAddresses.count) servers"
                             + (policy.lastApplied.map { " · applied \($0.formatted(.relative(presentation: .named)))" } ?? ""))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if policy.needsApply || policy.lastError != nil {
                    Button("Apply Now") { Task { await policy.apply() } }
                        .disabled(policy.isApplying)
                }
                if !policy.rules.isEmpty {
                    Button("Unblock All…", role: .destructive) { confirmClear = true }
                        .disabled(policy.isApplying)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func ruleSection(title: String, empty: String, rules: [PolicyRule], policy: PolicyCenter) -> some View {
        Section(title) {
            if rules.isEmpty {
                Text(empty).foregroundStyle(.secondary)
            }
            ForEach(rules) { rule in
                HStack(spacing: 10) {
                    Image(systemName: rule.isDomain ? "globe" : "server.rack").foregroundStyle(.secondary).frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(rule.value).font(.callout.monospaced()).textSelection(.enabled)
                        Text([rule.note, "added \(rule.createdAt.formatted(date: .abbreviated, time: .omitted))"].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if rule.isEnabled {
                        let active = rule.isDomain ? policy.activeDomains.contains(rule.value) : policy.addressRulesActive
                        Text(active ? "Blocked" : "Pending")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(active ? .red : .orange)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background((active ? Color.red : .orange).opacity(0.12), in: .capsule)
                    }
                    AccessibleSwitch(label: "Block \(rule.value)",
                                     isOn: Binding(get: { rule.isEnabled }, set: { policy.setEnabled(rule.id, $0) }))
                    Button(role: .destructive) { policy.remove([rule.id]) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Unblock and remove")
                }
            }
        }
    }
}

struct AddBlockRuleSheet: View {
    @Environment(MonitorStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var kind = 0
    @State private var text = ""
    @State private var invalid = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Picker("Block", selection: $kind) {
                    Text("Domain").tag(0)
                    Text("Server IP").tag(1)
                }
                .pickerStyle(.segmented)
                TextField(kind == 0 ? "Domain" : "Address", text: $text,
                          prompt: Text(kind == 0 ? "e.g. swscan.apple.com" : "e.g. 17.253.144.10"))
                    .onChange(of: text) { invalid = false }
                if invalid {
                    Text(kind == 0 ? "Enter a domain name like example.com." : "Enter an IPv4 or IPv6 address.")
                        .font(.caption).foregroundStyle(.red)
                }
                Text(kind == 0
                     ? "Domain blocks apply to that exact name for all apps (sub-domains must be added separately). Apps that use their own DNS-over-HTTPS can bypass them."
                     : "Server blocks drop all traffic to and from the address using the macOS packet filter, and close existing connections.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Block") {
                    let ok = kind == 0 ? store.policy.block(domain: text, note: "Added manually")
                                       : store.policy.block(address: text, note: "Added manually")
                    if ok { dismiss() } else { invalid = true }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 440)
    }
}
