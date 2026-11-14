import AppKit
import SwiftUI

/// Remon's search control, in place of the stock `.searchable` toolbar field.
///
/// The system field is one wide glass slab with a long prompt ("Search — try app:Safari port:443
/// -cat:app") that has to carry the whole query language in placeholder text. This one gives the
/// language somewhere better to live:
///
/// - **Idle** it is a quiet capsule carrying a ⌘F hint, sitting with the section's own filters
///   rather than dominating the toolbar.
/// - **Focused** a mint ring and a soft glow mark it as the active control.
/// - **With a query** a row of dots appears, one per parsed filter, each in the colour its key is
///   drawn in everywhere else — two dots mean two filters, and their hues say which kinds.
/// - **Suggestions** drop into a frosted panel below, where keys are coloured chips rather than
///   prose. It is the query language shown rather than described.
///
/// The field holds the whole query as plain text. Tokens are *rendered* as chips in the panel, not
/// committed into the field, so ⌘A and Delete behave the way they do in any text field.
///
/// It lives in `PageBar` rather than the window toolbar. A custom view inside a SwiftUI
/// `ToolbarItem` is not published to the accessibility tree at all on macOS 26 — the toolbar
/// reports no children — which costs VoiceOver the field, breaks programmatic focus for ⌘F, and
/// hides it from the end-to-end harness. In the page it is an ordinary view: focusable, reachable
/// and able to anchor its own panel.
struct RemonSearchField: View {
    @Environment(MonitorStore.self) private var store
    @Environment(SearchUIState.self) private var ui
    @FocusState private var focused: Bool

    private var terms: [SearchQuery.Term] { SearchQuery(store.searchText).terms }
    private var isEmpty: Bool { store.searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        HStack(spacing: 6) {
            icon
            field
            trailing
        }
        .padding(.leading, 9).padding(.trailing, 7)
        .padding(.vertical, 5)
        // Flexible rather than fixed: the page bar also carries the section's filters and its
        // count, and a fixed width (or one that grew on focus) pushed the count into a wrapped
        // column on narrower windows. Focus is signalled by the ring and glow instead.
        .frame(minWidth: 150, idealWidth: 260, maxWidth: 300)
        .background { capsule }
        .background { DeclineInitialFocus() }
        .animation(.easeOut(duration: 0.16), value: focused)
        .animation(.snappy(duration: 0.18), value: isEmpty)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { ui.fieldFrame = $0 }
        .onChange(of: focused) { _, now in
            // Let a click on a suggestion land before the panel goes away.
            if now { ui.showingSuggestions = true }
            else { Task { try? await Task.sleep(for: .milliseconds(150)); ui.showingSuggestions = focused } }
        }
        .onChange(of: store.searchText) { _, _ in
            if focused { ui.showingSuggestions = true }
        }
        // ⌘F may arrive before this view exists (it switches section first), so retry once on
        // appearance. The marker for "already handled" lives in `ui`, not in this view: the field
        // belongs to the page bar and is rebuilt on every section change, and view-local state
        // would reset with it and replay a stale request — stealing focus whenever you came back
        // to a searchable section.
        .onChange(of: store.focusSearchRequest, initial: true) { old, new in
            guard new != ui.handledFocusRequest else { return }
            ui.handledFocusRequest = new
            if old != new { focused = true; return }
            Task {
                try? await Task.sleep(for: .milliseconds(150))
                focused = true
            }
        }
        .onExitCommand {
            if isEmpty { focused = false } else { store.searchText = "" }
        }
        .onDisappear { ui.showingSuggestions = false }
    }

    private var icon: some View {
        Image(systemName: "magnifyingglass")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(focused ? AnyShapeStyle(Accent.base) : AnyShapeStyle(.secondary))
            .accessibilityHidden(true)
    }

    private var field: some View {
        @Bindable var store = store
        return TextField(prompt, text: $store.searchText)
            .textFieldStyle(.plain)
            .font(.callout)
            .focused($focused)
            .accessibilityAddTraits(.isSearchField)
            .accessibilityLabel("Search")
            .onSubmit { ui.showingSuggestions = false }
    }

    @ViewBuilder private var trailing: some View {
        if !isEmpty {
            FilterDots(terms: terms)
            Button {
                store.searchText = ""
                focused = true
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Clear the search")
            .accessibilityLabel("Clear the search")
        } else if !focused {
            Text("\u{2318}F")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(.primary.opacity(0.06), in: .rect(cornerRadius: 4, style: .continuous))
                .accessibilityHidden(true)
        }
    }

    private var capsule: some View {
        Capsule(style: .continuous)
            .fill(.thinMaterial)
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(focused ? Accent.base.opacity(0.75) : Color.primary.opacity(0.10),
                                  lineWidth: focused ? 1.5 : 1)
            }
            .shadow(color: Accent.base.opacity(focused ? 0.22 : 0), radius: 7, y: 1)
    }

    private var prompt: String {
        switch store.section {
        case .apps: "Search apps"
        case .history: "Search apps"
        case .log: "Search the log"
        case .map: "Filter destinations"
        default: "Search connections"
        }
    }
}

/// One dot per parsed filter, in that key's colour. A quiet read on how many filters are live and
/// what kinds they are, without spelling the query out twice.
private struct FilterDots: View {
    var terms: [SearchQuery.Term]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(terms.prefix(6).enumerated()), id: \.offset) { _, term in
                Circle()
                    .fill(SearchToken.color(for: term))
                    .frame(width: 5, height: 5)
            }
            if terms.count > 6 {
                Text("+\(terms.count - 6)").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(terms.count) active \(terms.count == 1 ? "filter" : "filters")")
    }
}

/// Colour and iconography for the query language, shared by the dots and the suggestion chips so a
/// key looks the same wherever it appears.
enum SearchToken {
    static func color(for term: SearchQuery.Term) -> Color {
        term.negated ? Palette.garnet : color(forKey: term.key)
    }

    static func color(forKey key: String?) -> Color {
        switch key {
        case "app": Palette.azure
        case "host": Palette.teal
        case "ip": Palette.sky
        case "port": Palette.indigo
        case "proto": Palette.violet
        case "country": Palette.plum
        case "state": Palette.amber
        case "cat": Palette.jade
        case "iface", "pid": Palette.slate
        default: Palette.slate
        }
    }

    static func symbol(forKey key: String?) -> String {
        switch key {
        case "app": "app.badge"
        case "host": "globe"
        case "ip": "number"
        case "port": "bolt.horizontal"
        case "proto": "arrow.left.arrow.right"
        case "country": "flag"
        case "state": "circle.dotted"
        case "cat": "tag"
        case "iface": "cable.connector"
        case "pid": "number.square"
        default: "magnifyingglass"
        }
    }
}

/// A `key:value` chip, coloured by its key.
struct SearchChip: View {
    var key: String?
    var value: String
    var negated = false

    var body: some View {
        let tint = negated ? Palette.garnet : SearchToken.color(forKey: key)
        HStack(spacing: 4) {
            Image(systemName: negated ? "minus.circle" : SearchToken.symbol(forKey: key))
                .font(.system(size: 9, weight: .semibold))
            Text(key.map { "\($0):" } ?? "")
                .fontWeight(.semibold)
                + Text(value)
        }
        .font(.caption.monospaced())
        .foregroundStyle(tint)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(tint.opacity(0.14), in: .rect(cornerRadius: 5, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(tint.opacity(0.25), lineWidth: 0.5)
        }
    }
}

/// The panel under the field. Frosted, like every other surface in the app, and built from chips
/// rather than sentences: each row is the token it will insert.
struct SearchSuggestionPanel: View {
    @Environment(MonitorStore.self) private var store
    var onPick: (String) -> Void

    var body: some View {
        let text = store.searchText.trimmingCharacters(in: .whitespaces)
        let groups = suggestions(for: text)
        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(groups) { group in
                    if group.title != groups.first?.title {
                        Divider().padding(.vertical, 3)
                    }
                    Text(group.title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)
                        .padding(.horizontal, 12).padding(.top, 7).padding(.bottom, 3)
                    ForEach(group.items) { item in
                        SuggestionRow(item: item, onPick: onPick)
                    }
                }
            }
            .padding(.vertical, 5)
            .frame(width: 340, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(.primary.opacity(0.08), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.22), radius: 16, y: 7)
            }
            .transition(.opacity.combined(with: .offset(y: -4)))
        }
    }

    struct Item: Identifiable {
        var id: String { completion }
        var key: String?
        var value: String
        var completion: String
        var icon: AppIdentity?
        var note: String?
    }

    struct Group: Identifiable {
        var id: String { title }
        var title: String
        var items: [Item]
    }

    private func suggestions(for text: String) -> [Group] {
        var groups: [Group] = []
        if text.isEmpty || text.hasSuffix(":") == false && !text.contains(":") && text.count >= 1 {
            var matches: [Item] = []
            if !text.isEmpty {
                for app in store.apps.filter({ $0.name.localizedStandardContains(text) }).prefix(4) {
                    matches.append(Item(key: "app", value: app.name, completion: "app:\"\(app.name)\" ",
                                        icon: app.identity))
                }
                let hosts = Set(store.connections.compactMap(\.hostname)
                    .filter { $0.localizedStandardContains(text) }).sorted().prefix(3)
                for host in hosts {
                    matches.append(Item(key: "host", value: host, completion: "host:\(host) "))
                }
                let countries = Set(store.connections.compactMap { c -> String? in
                    guard let name = c.geo?.country, name.localizedStandardContains(text) else { return nil }
                    return c.geo?.countryCode
                }).sorted().prefix(2)
                for code in countries {
                    matches.append(Item(key: "country", value: code, completion: "country:\(code) "))
                }
            }
            if !matches.isEmpty { groups.append(Group(title: "Matches", items: matches)) }
        }
        if text.isEmpty {
            groups.append(Group(title: "Filters", items: [
                Item(key: "proto", value: "udp", completion: "proto:udp ", note: "Transport"),
                Item(key: "port", value: "443", completion: "port:443 ", note: "Port or service"),
                Item(key: "cat", value: "telemetry", completion: "cat:telemetry ", note: "Destination kind"),
                Item(key: "state", value: "established", completion: "state:established ", note: "TCP state"),
                Item(key: nil, value: "-cat:apple", completion: "-cat:apple ", note: "Exclude with a minus"),
            ]))
        }
        return groups
    }
}

private struct SuggestionRow: View {
    var item: SearchSuggestionPanel.Item
    var onPick: (String) -> Void
    @State private var hovering = false

    var body: some View {
        Button {
            onPick(item.completion)
        } label: {
            HStack(spacing: 8) {
                if let identity = item.icon {
                    AppIcon(identity: identity, size: 14)
                }
                if item.key == nil {
                    SearchChip(key: "cat", value: "apple", negated: true)
                } else {
                    SearchChip(key: item.key, value: item.value)
                }
                Spacer(minLength: 6)
                if let note = item.note {
                    Text(note).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? Accent.base.opacity(0.16) : .clear,
                        in: .rect(cornerRadius: 7, style: .continuous))
            .padding(.horizontal, 5)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}


/// Where the search field is on screen and whether its panel is up. The panel is drawn by
/// `MainView` over the whole detail column, so it can overflow the page bar it belongs to; this
/// carries the field's frame up to it.
@MainActor @Observable
final class SearchUIState {
    var fieldFrame: CGRect = .zero
    var showingSuggestions = false
    /// The last `focusSearchRequest` acted on, kept here so it survives the field being rebuilt.
    var handledFocusRequest = 0
}


/// AppKit hands first responder to the first text field in a window as it opens. Remon opens on a
/// section, not in a text box, so the search field must decline it: otherwise every launch starts
/// with the field ringed in mint and its suggestion panel covering the table. `.searchable` used
/// to decline this for us, since `NSSearchToolbarItem` never takes initial focus.
private struct DeclineInitialFocus: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.initialFirstResponder = nil
            // A focused SwiftUI text field holds the window's field editor, an NSTextView.
            if window.firstResponder is NSTextView { window.makeFirstResponder(nil) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
