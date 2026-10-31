import MapKit
import SwiftUI

/// World map of live destinations, with geodesic arcs from this Mac's public location.
struct MapView: View {
    @Environment(MonitorStore.self) private var store
    @Environment(Preferences.self) private var preferences
    // Never `.automatic`: that re-frames whenever the content changes, which fought the user's zoom.
    @State private var position: MapCameraPosition = .camera(MapCamera(centerCoordinate: .init(latitude: 25, longitude: 10), distance: 28_000_000))
    @State private var selection: String?
    @State private var destinations: [Destination] = []
    @State private var hasFramed = false
    @State private var framedWithHome = false
    @AppStorage("mapGlobe") private var globe = true

    struct Destination: Identifiable, Hashable {
        var id: String
        var coordinate: CLLocationCoordinate2D
        var place: String
        var flag: String
        var org: String?
        var connections: Int
        var bytes: UInt64
        var rate: Double
        var apps: [String]
        var hosts: [String]

        static func == (a: Self, b: Self) -> Bool { a.id == b.id && a.bytes == b.bytes && a.connections == b.connections }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    var body: some View {
        let home = homeCoordinate
        HStack(spacing: 0) {
            // The default camera bounds stop zooming out at ~24,000 km (about 137° of longitude),
            // which is what made zoom-out feel stuck; allow pulling back to the whole planet.
            Map(position: $position, bounds: MapCameraBounds(minimumDistance: 800, maximumDistance: 90_000_000),
                selection: $selection) {
                if let home {
                    ForEach(destinations) { d in
                        MapPolyline(coordinates: [home, d.coordinate], contourStyle: .geodesic)
                            .stroke(arcColor(d), style: StrokeStyle(lineWidth: d.id == selection ? 2.5 : 1.2, lineCap: .round))
                    }
                    Annotation("You", coordinate: home) {
                        ZStack {
                            Circle().fill(Theme.upload.opacity(0.25)).frame(width: 26, height: 26)
                            Circle().fill(Theme.upload).frame(width: 10, height: 10)
                                .overlay(Circle().stroke(.white, lineWidth: 2))
                        }
                    }
                    .annotationTitles(.hidden)
                }
                ForEach(destinations) { d in
                    Annotation(d.place, coordinate: d.coordinate) {
                        bubble(d)
                    }
                    .tag(d.id)
                }
            }
            // The globe (3D satellite imagery) zooms out to the whole planet. The flat Mercator map can't scroll
            // past the poles, so in a tall window it tops out at roughly 137° of longitude.
            .mapStyle(globe ? .hybrid(elevation: .realistic, pointsOfInterest: .excludingAll)
                            : .standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
            .mapControls {
                MapZoomStepper()
                MapCompass()
                MapScaleView()
            }
            .overlay(alignment: .topLeading) { legend.padding(12) }
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 8) {
                    Picker("Style", selection: $globe) {
                        Label("Flat", systemImage: "map").tag(false)
                        Label("Globe", systemImage: "globe").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Button { fitAll(animated: true) } label: { Label("Fit All", systemImage: "arrow.up.left.and.arrow.down.right") }
                        .disabled(destinations.isEmpty)
                }
                .controlSize(.small)
                .padding(8)
                .background(.regularMaterial, in: .rect(cornerRadius: 10))
                .padding(12)
            }
            .overlay {
                if destinations.isEmpty {
                    ContentUnavailableView("No Located Destinations", systemImage: "map",
                                           description: Text(preferences.geoLookups
                                                             ? "Destinations appear as public addresses are located."
                                                             : "Turn on location lookups in Settings › Privacy to see the map."))
                        .padding()
                        .background(.regularMaterial, in: .rect(cornerRadius: 14))
                        .frame(maxWidth: 420, maxHeight: 220)
                }
            }

            Divider()
            sidePanel(destinations)
                .frame(width: 280)
        }
        .task {
            // Let the map lay out first: a fit computed against a zero-sized map frames the wrong area.
            try? await Task.sleep(for: .milliseconds(700))
            // Refresh pins every few seconds rather than on every live tick.
            while !Task.isCancelled {
                refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .onChange(of: store.searchText) { refresh() }
        .onChange(of: globe) { fitAll(animated: true) }

        .onChange(of: selection) { _, id in
            guard let id, let d = destinations.first(where: { $0.id == id }) else { return }
            withAnimation(.smooth(duration: 0.8)) {
                position = .camera(MapCamera(centerCoordinate: d.coordinate, distance: 4_000_000))
            }
        }
    }

    private func refresh() {
        let next = computeDestinations()
        if next != destinations { destinations = next }
        // Frame once when data arrives, and once more when this Mac's own location becomes known;
        // after that the camera is entirely the user's.
        if (!hasFramed && !next.isEmpty) || (!framedWithHome && homeCoordinate != nil && !next.isEmpty) {
            hasFramed = true
            framedWithHome = homeCoordinate != nil
            fitAll(animated: hasFramed)
        }
    }

    private func fitAll(animated: Bool) {
        var coordinates = destinations.map(\.coordinate)
        if let home = homeCoordinate { coordinates.append(home) }
        guard !coordinates.isEmpty else { return }
        var rect = MKMapRect.null
        for c in coordinates {
            let p = MKMapPoint(c)
            rect = rect.union(MKMapRect(x: p.x, y: p.y, width: 1, height: 1))
        }
        let pad = max(rect.width, rect.height) * 0.15 + 1_500_000
        rect = rect.insetBy(dx: -pad, dy: -pad).intersection(.world)
        let update: () -> Void
        if globe {
            // A globe can show at most a hemisphere: centre on the data and pull back far enough.
            let center = MKMapPoint(x: rect.midX, y: rect.midY).coordinate
            let distance = min(40_000_000, max(3_000_000, rect.width / MKMapPointsPerMeterAtLatitude(center.latitude) * 1.2))
            update = { position = .camera(MapCamera(centerCoordinate: center, distance: distance)) }
        } else {
            update = { position = .rect(rect) }
        }
        if animated { withAnimation(.smooth(duration: 0.8), update) } else { update() }
    }

    private var homeCoordinate: CLLocationCoordinate2D? {
        guard let geo = store.environment.publicGeo, let lat = geo.latitude, let lon = geo.longitude else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    private func arcColor(_ d: Destination) -> Color {
        (d.rate > 0 ? Theme.download : Theme.download.opacity(0.45)).opacity(d.id == selection ? 1 : 0.7)
    }

    private func bubble(_ d: Destination) -> some View {
        let size = 12 + min(26, log10(Double(max(d.bytes, 1000))) * 3)
        return ZStack {
            Circle().fill(Theme.download.opacity(0.22)).frame(width: size + 10, height: size + 10)
            Circle().fill(Theme.download.gradient).frame(width: size, height: size)
                .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 1.5))
            Text("\(d.connections)").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
        }
        .scaleEffect(d.id == selection ? 1.25 : 1)
        .animation(.snappy, value: selection)
    }

    private var legend: some View {
        HStack(spacing: 10) {
            Label("You", systemImage: "circle.fill").foregroundStyle(Theme.upload)
            Label("Destination (connections)", systemImage: "circle.fill").foregroundStyle(Theme.download)
        }
        .font(.caption)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.regularMaterial, in: .capsule)
    }

    private func sidePanel(_ destinations: [Destination]) -> some View {
        List(selection: $selection) {
            if let geo = store.environment.publicGeo {
                Section("This Mac") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.environment.publicIP ?? "—").font(.callout.monospaced())
                        Text("\(geo.flag) \(geo.placeDescription)").font(.caption).foregroundStyle(.secondary)
                        if let org = geo.org { Text(org).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            Section("\(destinations.count) Locations") {
                ForEach(destinations) { d in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(d.flag)
                            Text(d.place).lineLimit(1)
                            Spacer()
                            Text(ByteFormat.bytes(d.bytes)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Text(d.apps.prefix(3).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        if d.id == selection {
                            if let org = d.org { Text(org).font(.caption2).foregroundStyle(.tertiary) }
                            ForEach(d.hosts.prefix(5), id: \.self) { host in
                                Text(host).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .tag(d.id)
                }
            }
        }
        .listStyle(.inset)
    }

    private func computeDestinations() -> [Destination] {
        let query = SearchQuery(store.searchText)
        var byPlace: [String: Destination] = [:]
        for c in store.connections where !c.isListening {
            guard let geo = c.geo, geo.scope == .publicInternet, let lat = geo.latitude, let lon = geo.longitude else { continue }
            if !query.isEmpty && !query.matches(c) { continue }
            let key = String(format: "%.1f,%.1f", lat, lon)
            var d = byPlace[key] ?? Destination(id: key, coordinate: .init(latitude: lat, longitude: lon),
                                                place: geo.placeDescription, flag: geo.flag, org: geo.org,
                                                connections: 0, bytes: 0, rate: 0, apps: [], hosts: [])
            d.connections += 1
            d.bytes += c.totalBytes
            d.rate += c.totalRate
            if !d.apps.contains(c.appName) { d.apps.append(c.appName) }
            if !d.hosts.contains(c.displayHost) { d.hosts.append(c.displayHost) }
            byPlace[key] = d
        }
        return byPlace.values.sorted { $0.bytes > $1.bytes }
    }
}
