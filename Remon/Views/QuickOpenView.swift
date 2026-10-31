import SwiftUI

/// Spotlight-style palette (⌘K): jump to a section, an app or a remote host.
struct QuickOpenView: View {
    @Environment(MonitorStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    private struct Item: Identifiable {
        enum Kind { case section(SidebarSection), app(AppTraffic), host(ConnectionInfo) }
        var id: String
        var title: String
        var subtitle: String
        var kind: Kind
    }

    var body: some View {
        let items = results
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.title2).foregroundStyle(.secondary)
                TextField("Jump to an app, host or section…", text: $text)
                    .textFieldStyle(.plain)
                    .font(.title2)
                    .focused($focused)
                    .onSubmit { choose(items) }
            }
            .padding(16)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            row(item, selected: index == highlighted)
                                .id(index)
                                .onTapGesture { highlighted = index; choose(items) }
                        }
                        if items.isEmpty {
                            Text("No matches").foregroundStyle(.secondary).padding(30)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: highlighted) { _, value in proxy.scrollTo(value) }
            }
            .frame(height: 320)
        }
        .frame(width: 560)
        .onAppear { focused = true }
        .onChange(of: text) { highlighted = 0 }
        .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, max(items.count - 1, 0)); return .handled }
        .onKeyPress(.upArrow) { highlighted = max(highlighted - 1, 0); return .handled }
        .onKeyPress(.escape) { dismiss(); return .handled }
    }

    private func row(_ item: Item, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Group {
                switch item.kind {
                case .section(let s): Image(systemName: s.symbol).frame(width: 22)
                case .app(let a): AppIcon(identity: a.identity, size: 22)
                case .host(let c): Text(c.geo?.flag ?? "🌐").frame(width: 22)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(1)
                Text(item.subtitle).font(.caption).foregroundStyle(selected ? Color.white.opacity(0.8) : .secondary).lineLimit(1)
            }
            Spacer()
            if selected { Image(systemName: "return").font(.caption) }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .foregroundStyle(selected ? Color.white : .primary)
        .background(selected ? Color.accentColor : .clear, in: .rect(cornerRadius: 7))
        .contentShape(.rect)
    }

    private var results: [Item] {
        let q = text.trimmingCharacters(in: .whitespaces)
        func match(_ s: String) -> Bool { q.isEmpty || s.localizedStandardContains(q) }
        var items: [Item] = []
        for s in SidebarSection.allCases where match(s.rawValue) {
            items.append(Item(id: "s:\(s.rawValue)", title: s.rawValue, subtitle: "Section · ⌘\(s.shortcut)", kind: .section(s)))
        }
        for a in store.apps where match(a.name) {
            items.append(Item(id: "a:\(a.id)", title: a.name, subtitle: "App · \(a.connectionCount) connections", kind: .app(a)))
        }
        var seenHosts = Set<String>()
        for c in store.connections where !c.isListening && match(c.displayHost + " " + c.remote.bareAddress + " " + (c.geo?.country ?? "")) {
            guard seenHosts.insert(c.displayHost).inserted else { continue }
            items.append(Item(id: "h:\(c.id)", title: c.displayHost, subtitle: "Host · \(c.appName) · \(c.geo?.placeDescription ?? c.remote.bareAddress)", kind: .host(c)))
        }
        return Array(items.prefix(60))
    }

    private func choose(_ items: [Item]) {
        guard items.indices.contains(highlighted) else { return }
        switch items[highlighted].kind {
        case .section(let s):
            store.section = s
        case .app(let a):
            store.selectedAppID = a.id
            store.section = .apps
            store.showInspector = true
        case .host(let c):
            store.connectionScope = .active
            store.selectedConnectionID = c.id
            store.section = .connections
            store.showInspector = true
        }
        dismiss()
    }
}
