import SwiftUI

/// Compact always-on-top monitor (⌥⌘M), for keeping an eye on traffic while working.
struct FloatingMonitor: View {
    @Environment(MonitorStore.self) private var store
    @Environment(Preferences.self) private var preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                rate(store.currentIn, "arrow.down", Theme.download)
                rate(store.currentOut, "arrow.up", Theme.upload)
                Spacer(minLength: 0)
                StatusDot(color: store.path.snapshot.isConnected ? .green : .red)
            }
            ThroughputChart(points: Array(store.throughput.suffix(90)), window: 90, showsAxes: false, interactive: false)
                .frame(height: 46)
            SystemStrip()
            if let top = store.apps.first(where: { $0.totalRate > 0 }) {
                HStack(spacing: 6) {
                    AppIcon(identity: top.identity, size: 14)
                    Text(top.name).lineLimit(1)
                    Spacer()
                    Text(preferences.rate(top.totalRate)).monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text("Quiet").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(width: 250)
        .background(.regularMaterial)
    }

    private func rate(_ value: Double, _ symbol: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.caption.weight(.bold)).foregroundStyle(color)
            Text(preferences.rate(value)).font(.system(.title3, design: .rounded).weight(.semibold).monospacedDigit())
        }
    }
}
