import CoreWLAN
import Foundation
import Observation

struct WiFiDetails: Equatable, Sendable {
    var ssid: String?
    var rssi: Int
    var noise: Int
    var transmitRate: Double
    var channel: Int?
    var band: String?
    var security: String?

    var signalToNoise: Int { rssi - noise }

    /// 0…4 bars, using the usual RSSI cut-offs.
    var bars: Int {
        if rssi >= -55 { return 4 }
        if rssi >= -65 { return 3 }
        if rssi >= -75 { return 2 }
        if rssi >= -85 { return 1 }
        return 0
    }

    var quality: String {
        switch bars {
        case 4: "Excellent"
        case 3: "Good"
        case 2: "Fair"
        default: "Poor"
        }
    }
}

/// Public IP, ISP, VPN state and Wi-Fi radio details.
@MainActor @Observable
final class NetworkEnvironment {
    private(set) var publicIP: String?
    private(set) var publicGeo: GeoInfo?
    private(set) var lastPublicIPCheck: Date?
    private(set) var wifi: WiFiDetails?
    private(set) var vpnInterfaces: [String] = []

    var isVPNActive: Bool { !vpnInterfaces.isEmpty }

    @ObservationIgnored private let locator = IPWhoIsGeoLocator()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored var onPublicIPChange: ((String?, String) -> Void)?

    func start(lookupsEnabled: @escaping @MainActor () -> Bool) {
        guard task == nil else { return }
        task = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                guard let self else { return }
                self.refreshWiFi()
                // Public IP every 15 minutes (or when asked via refreshPublicIP()).
                if ticks % 180 == 0, lookupsEnabled() { await self.refreshPublicIP() }
                ticks += 1
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func refreshPublicIP() async {
        guard let result = await locator.lookupSelf() else { return }
        let previous = publicIP
        publicIP = result.ip
        publicGeo = result.info
        lastPublicIPCheck = Date()
        if let previous, previous != result.ip { onPublicIPChange?(previous, result.ip) }
    }

    func updateVPN(addresses: [String: [String]]) {
        vpnInterfaces = addresses.keys.filter { name in
            (name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp"))
                && (addresses[name] ?? []).contains { !$0.hasPrefix("fe80") }
        }.sorted()
    }

    private func refreshWiFi() {
        guard let interface = CWWiFiClient.shared().interface(), interface.powerOn(), interface.rssiValue() != 0 else {
            wifi = nil
            return
        }
        let channel = interface.wlanChannel()
        let band: String? = switch channel?.channelBand {
        case .band2GHz: "2.4 GHz"
        case .band5GHz: "5 GHz"
        case .band6GHz: "6 GHz"
        default: nil
        }
        wifi = WiFiDetails(ssid: interface.ssid(), rssi: interface.rssiValue(), noise: interface.noiseMeasurement(),
                           transmitRate: interface.transmitRate(), channel: channel?.channelNumber, band: band,
                           security: Self.securityName(interface.security()))
    }

    private static func securityName(_ security: CWSecurity) -> String? {
        switch security {
        case .none: "Open"
        case .WEP: "WEP"
        case .wpaPersonal, .wpaPersonalMixed: "WPA"
        case .wpa2Personal: "WPA2"
        case .wpa3Personal, .wpa3Transition: "WPA3"
        case .wpaEnterprise, .wpaEnterpriseMixed, .wpa2Enterprise, .wpa3Enterprise: "Enterprise"
        default: nil
        }
    }
}
