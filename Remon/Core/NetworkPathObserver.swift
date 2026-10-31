import Foundation
import Network
import Observation

/// Connectivity state from `NWPathMonitor`.
@MainActor @Observable
final class NetworkPathObserver {
    struct Snapshot: Sendable, Equatable {
        var isConnected = true
        var isExpensive = false
        var isConstrained = false
        var primaryKind: InterfaceKind?
        var primaryName: String?
        var kinds: [String: InterfaceKind] = [:]
        var supportsIPv4 = true
        var supportsIPv6 = false
    }

    private(set) var snapshot = Snapshot()
    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored var onConnectivityChange: ((Bool) -> Void)?
    @ObservationIgnored private var hasInitialPath = false

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let snap = Self.makeSnapshot(path)
            Task { @MainActor in self?.apply(snap) }
        }
        monitor.start(queue: DispatchQueue(label: "remon.path-monitor", qos: .utility))
    }

    private func apply(_ new: Snapshot) {
        let changed = new.isConnected != snapshot.isConnected
        snapshot = new
        if hasInitialPath, changed { onConnectivityChange?(new.isConnected) }
        hasInitialPath = true
    }

    var statusText: String {
        guard snapshot.isConnected else { return "Offline" }
        var text = snapshot.primaryKind?.rawValue ?? "Connected"
        if let name = snapshot.primaryName { text += " · \(name)" }
        return text
    }

    nonisolated private static func makeSnapshot(_ path: NWPath) -> Snapshot {
        var kinds: [String: InterfaceKind] = [:]
        for interface in path.availableInterfaces {
            kinds[interface.name] = kind(interface.type)
        }
        let primary = path.availableInterfaces.first { path.usesInterfaceType($0.type) }
        return Snapshot(
            isConnected: path.status == .satisfied,
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained,
            primaryKind: primary.map { kind($0.type) },
            primaryName: primary?.name,
            kinds: kinds,
            supportsIPv4: path.supportsIPv4,
            supportsIPv6: path.supportsIPv6
        )
    }

    nonisolated private static func kind(_ type: NWInterface.InterfaceType) -> InterfaceKind {
        switch type {
        case .wifi: .wifi
        case .wiredEthernet: .ethernet
        case .cellular: .cellular
        case .loopback: .loopback
        case .other: .other
        @unknown default: .other
        }
    }
}
