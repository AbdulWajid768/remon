import SwiftUI

struct ConnectionsView: View {
    @Environment(MonitorStore.self) private var store
    @Environment(Preferences.self) private var preferences
    @State private var sortOrder = [KeyPathComparator(\ConnectionInfo.totalRate, order: .reverse)]
    @State private var tableWidth: CGFloat = 1_000

    var body: some View {
        @Bindable var store = store
        let query = SearchQuery(store.searchText)
        let rows = store.connections
            .filter { c in
                switch store.connectionScope {
                case .active: !c.isListening
                case .listening: c.isListening
                case .all: true
                }
            }
            .filter { query.isEmpty || query.matches($0) }
            .sorted(using: sortOrder)

        // Show only the columns that fit. A Table lays columns out at their ideal widths and scrolls
        // sideways rather than shrinking them (the extra columns ended up hidden under the inspector),
        // and it can't shrink below the sum of their minimums at all. Each threshold is the sum of
        // (ideal width + 17 pt cell spacing) of the columns shown at that width.
        let columns = (service: tableWidth >= 655, location: tableWidth >= 792, state: tableWidth >= 889,
                       total: tableWidth >= 976, rtt: tableWidth >= 1_049)
        Table(rows, selection: $store.selectedConnectionID, sortOrder: $sortOrder) {
            TableColumn("App", value: \.appName) { c in
                HStack(spacing: 6) {
                    AppIcon(identity: AppIdentity(id: c.appID, name: c.appName, bundlePath: c.appID.hasSuffix(".app") ? c.appID : nil,
                                                  executablePath: c.appID.hasPrefix("/") ? c.appID : nil, isSystem: false), size: 16)
                    Text(c.appName).lineLimit(1)
                }
                .opacity(c.isClosed ? 0.45 : 1)
            }
            .width(min: 80, ideal: 120)
            TableColumn("Remote Host", value: \.displayHost) { c in
                // Always two lines, so every row has the same height (rows whose hostname resolved
                // later used to keep a one-line height and clip the address).
                VStack(alignment: .leading, spacing: 0) {
                    Text(c.displayHost).lineLimit(1).truncationMode(.middle)
                    Text(c.hostname != nil ? c.remote.bareAddress : (c.geo?.org ?? " "))
                        .font(c.hostname != nil ? .caption2.monospaced() : .caption2)
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
                .opacity(c.isClosed ? 0.45 : 1)
            }
            .width(min: 100, ideal: 180)
            if columns.location {
                TableColumn("Location", value: \.locationSort) { c in
                    HStack(spacing: 4) {
                        Text(c.geo?.flag ?? "")
                        Text(c.geo?.placeDescription ?? (c.isListening ? "" : "…"))
                            .lineLimit(1).foregroundStyle(.secondary)
                    }
                }
                .width(min: 70, ideal: 120)
            }
            if columns.service {
                TableColumn("Service", value: \.remotePortSort) { c in
                    HStack(spacing: 4) {
                        Text(c.proto.rawValue).font(.caption2.weight(.semibold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(protoColor(c.proto).opacity(0.15), in: .rect(cornerRadius: 3))
                            .foregroundStyle(protoColor(c.proto))
                        Text(serviceText(c)).lineLimit(1).monospacedDigit()
                    }
                }
                .width(min: 64, ideal: 120)
            }
            if columns.state {
                TableColumn("State", value: \.state) { c in
                    if store.policy.isBlocked(address: c.remote.bareAddress) {
                        Label("Blocked", systemImage: "hand.raised.fill").foregroundStyle(Palette.garnet)
                    } else {
                        Text(c.isClosed ? "Closed" : c.displayState).foregroundStyle(c.isClosed ? .tertiary : .secondary)
                    }
                }
                .width(min: 60, ideal: 80)
            }
            TableColumn("↓ Rate", value: \.rateIn) { c in RateText(rate: c.rateIn, direction: .down) }
                .width(min: 50, ideal: 72)
            TableColumn("↑ Rate", value: \.rateOut) { c in RateText(rate: c.rateOut, direction: .up) }
                .width(min: 50, ideal: 72)
            if columns.total {
                TableColumn("Total", value: \.totalBytes) { c in
                    Text(ByteFormat.bytes(c.totalBytes)).monospacedDigit().foregroundStyle(.secondary)
                }
                .width(min: 50, ideal: 70)
            }
            if columns.rtt {
                TableColumn("RTT", value: \.rttSort) { c in
                    Text(c.rttMs.map { String(format: "%.0f ms", $0) } ?? "—").monospacedDigit().foregroundStyle(.secondary)
                }
                .width(min: 40, ideal: 56)
            }
        }
        // A new column set gets a fresh table: inserting a column into the live one made AppKit
        // rescale the others past the table's width.
        .id([columns.service, columns.location, columns.state, columns.total, columns.rtt])
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { tableWidth = $0 }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let c = store.connection(id: id) {
                ConnectionContextMenu(connection: c)
            }
        }
        .overlay {
            if rows.isEmpty {
                if store.searchText.isEmpty {
                    ContentUnavailableView("No Connections", systemImage: "point.3.connected.trianglepath.dotted",
                                           description: Text(store.sourceStatus == .running ? "Nothing matches this filter right now." : "Waiting for nettop…"))
                } else {
                    ContentUnavailableView.search(text: store.searchText)
                }
            }
        }
        // A frosted panel behind the rows: with nothing behind them, AppKit renders the cells with
        // vibrancy and the coloured rates and protocol badges wash out. Stripes on glass were too dark.
        .scrollContentBackground(.hidden)
        .alternatingRowBackgrounds(.disabled)
        .background(.thinMaterial)
        .safeAreaInset(edge: .top, spacing: 0) {
            PageBar {
                Picker("Scope", selection: $store.connectionScope) {
                    ForEach(ConnectionScope.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            } trailing: {
                if store.isPaused {
                    Label("Paused", systemImage: "pause.circle.fill").foregroundStyle(Palette.ember)
                }
                Text("\(rows.count) shown").foregroundStyle(.secondary)
            }
        }
    }

    private func serviceText(_ c: ConnectionInfo) -> String {
        let port = c.isListening ? c.local.port : c.remote.port
        let portText = port.map(String.init) ?? "*"
        if let name = PortNames.fullName(for: port, proto: c.proto) { return "\(name) (\(portText))" }
        return portText
    }

    private func protoColor(_ p: TransportProtocol) -> Color {
        switch p {
        case .tcp: Palette.azure
        case .udp: Palette.violet
        case .quic: Palette.plum
        }
    }
}

struct ConnectionContextMenu: View {
    var connection: ConnectionInfo
    @Environment(MonitorStore.self) private var store

    var body: some View {
        Button("Copy Remote Address") { copy(connection.remote.bareAddress) }
        if let host = connection.hostname { Button("Copy Hostname") { copy(host) } }
        Button("Copy Summary") {
            copy("\(connection.appName) \(connection.proto.rawValue) \(connection.local.display) → \(connection.remote.display) \(connection.displayState)")
        }
        Divider()
        Button("Show \(connection.appName)") {
            store.selectedAppID = connection.appID
            store.section = .apps
        }
        Button("Filter by This Host") { store.searchText = "ip:\(connection.remote.bareAddress) " }
        if !connection.isListening {
            Divider()
            BlockServerButton(connection: connection)
        }
        if IPClassifier.scope(of: connection.remote.bareAddress) == .publicInternet,
           let url = URL(string: "https://ipinfo.io/\(connection.remote.bareAddress)") {
            Button("Look Up on ipinfo.io") { NSWorkspace.shared.open(url) }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct ConnectionInspector: View {
    var connection: ConnectionInfo
    @Environment(MonitorStore.self) private var store
    @Environment(Preferences.self) private var preferences

    var body: some View {
        let c = connection
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Text(c.geo?.flag ?? "🌐").font(.system(size: 36))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.displayHost).font(.title3.weight(.semibold)).lineLimit(2).textSelection(.enabled)
                        Text(c.geo?.placeDescription ?? (c.isListening ? "Listening socket" : "Locating…"))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                if !c.isListening {
                    HStack {
                        CategoryBadge(category: c.category)
                        Spacer()
                        BlockServerButton(connection: c)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }

                HStack(spacing: 10) {
                    block("Download", c.rateIn, Theme.download)
                    block("Upload", c.rateOut, Theme.upload)
                }

                GroupBox("Endpoints") {
                    VStack(spacing: 6) {
                        DetailRow(label: "Remote", value: c.remote.display, monospaced: true)
                        DetailRow(label: "Local", value: c.local.display, monospaced: true)
                        DetailRow(label: "Protocol", value: "\(c.proto.rawValue) / \(c.family.rawValue)")
                        DetailRow(label: "Service", value: PortNames.fullName(for: c.isListening ? c.local.port : c.remote.port, proto: c.proto) ?? "Unknown")
                        DetailRow(label: "State", value: c.isClosed ? "Closed" : c.displayState)
                        DetailRow(label: "Interface", value: c.interface.isEmpty ? "—" : c.interface)
                        DetailRow(label: "RTT", value: c.rttMs.map { String(format: "%.1f ms", $0) } ?? "—")
                    }
                }
                GroupBox("Owner") {
                    VStack(spacing: 6) {
                        DetailRow(label: "App", value: c.appName)
                        DetailRow(label: "Process", value: "\(c.processName) (\(c.pid))")
                    }
                }
                if let geo = c.geo, geo.scope == .publicInternet {
                    GroupBox("Network Owner") {
                        VStack(spacing: 6) {
                            DetailRow(label: "Organisation", value: geo.org ?? "—")
                            DetailRow(label: "ASN", value: geo.asn.map { "AS\($0)" } ?? "—")
                            DetailRow(label: "Region", value: [geo.region, geo.country].compactMap { $0 }.joined(separator: ", "))
                        }
                    }
                }
                GroupBox("Traffic") {
                    VStack(spacing: 6) {
                        DetailRow(label: "Received", value: ByteFormat.bytes(c.totalIn))
                        DetailRow(label: "Sent", value: ByteFormat.bytes(c.totalOut))
                        DetailRow(label: "First seen", value: c.firstSeen.formatted(date: .omitted, time: .standard))
                    }
                }
            }
            .padding(16)
        }
    }

    private func block(_ title: String, _ rate: Double, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(color)
            Text(preferences.rate(rate)).font(.headline.monospacedDigit()).contentTransition(.numericText())
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.1), in: .rect(cornerRadius: 10, style: .continuous))
    }
}

/// Blocks or unblocks the connection's remote server (pf, system-wide).
struct BlockServerButton: View {
    var connection: ConnectionInfo
    @Environment(MonitorStore.self) private var store

    var body: some View {
        let address = connection.remote.bareAddress
        if store.policy.isBlocked(address: address) {
            Button {
                store.policy.unblock(address: address)
            } label: {
                Label("Unblock Server", systemImage: "hand.raised.slash")
            }
        } else {
            Button(role: .destructive) {
                store.policy.block(address: address, note: "\(connection.appName) → \(connection.displayHost)")
            } label: {
                Label("Block Server", systemImage: "hand.raised.fill")
            }
            .disabled(connection.remote.isWildcardAddress)
        }
    }
}

