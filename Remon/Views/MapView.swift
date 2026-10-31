import MapKit
import SwiftUI

/// World map of live destinations, with geodesic arcs from this Mac's public location.
struct MapView: View {
    @Environment(MonitorStore.self) private var store
    @Environment(Preferences.self) private var preferences
    @State private var position: MapCameraPosition = .automatic
    @State private var selection: String?

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
        let destinations = computeDestinations()
        let home = homeCoordinate
        HStack(spacing: 0) {
            Map(position: $position, selection: $selection) {
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
            .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
            .mapControls {
                MapZoomStepper()
                MapCompass()
                MapScaleView()
            }
            .overlay(alignment: .topLeading) { legend.padding(12) }
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
        .onChange(of: selection) { _, id in
            guard let id, let d = destinations.first(where: { $0.id == id }) else { return }
            withAnimation(.smooth(duration: 0.8)) {
                position = .camera(MapCamera(centerCoordinate: d.coordinate, distance: 4_000_000))
            }
        }
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
