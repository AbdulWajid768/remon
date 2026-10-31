import Foundation
import Security

enum SigningStatus: String, Codable, Sendable, CaseIterable {
    case apple = "Apple"
    case appStore = "App Store"
    case developerID = "Developer ID"
    case development = "Development"
    case adHoc = "Ad-hoc"
    case unsigned = "Unsigned"
    case invalid = "Invalid"
    case unknown = "Unknown"

    var symbol: String {
        switch self {
        case .apple: "apple.logo"
        case .appStore: "bag.fill"
        case .developerID: "checkmark.seal.fill"
        case .development: "hammer.fill"
        case .adHoc: "signature"
        case .unsigned: "exclamationmark.shield.fill"
        case .invalid: "xmark.shield.fill"
        case .unknown: "questionmark.circle"
        }
    }

    /// Whether this signature should draw attention in the UI.
    var isConcerning: Bool { self == .unsigned || self == .invalid || self == .adHoc }
}

struct SigningInfo: Hashable, Sendable {
    var status: SigningStatus
    var teamID: String?
    var signingID: String?
}

/// Static code-signature check of an app bundle or executable (Little Snitch–style provenance).
///
/// Resource sealing isn't re-hashed (`kSecCSDoNotValidateResources`) so large bundles like Chrome
/// verify in milliseconds; the executable's signature and certificate chain are still checked.
enum CodeSignatureInspector {
    private static let requirements: [(SigningStatus, String)] = [
        (.apple, "anchor apple"),
        (.appStore, "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9] exists"),
        (.developerID, "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"),
        (.development, "anchor apple generic"),
    ]

    static func inspect(path: String) -> SigningInfo {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else {
            return SigningInfo(status: .unknown)
        }
        let flags = SecCSFlags(rawValue: kSecCSDoNotValidateResources)
        let basic = SecStaticCodeCheckValidity(code, flags, nil)
        if basic == errSecCSUnsigned { return SigningInfo(status: .unsigned) }

        var infoRef: CFDictionary?
        SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &infoRef)
        let info = infoRef as? [String: Any] ?? [:]
        let teamID = info[kSecCodeInfoTeamIdentifier as String] as? String
        let signingID = info[kSecCodeInfoIdentifier as String] as? String

        guard basic == errSecSuccess else { return SigningInfo(status: .invalid, teamID: teamID, signingID: signingID) }

        for (status, text) in requirements {
            var requirement: SecRequirement?
            guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { continue }
            if SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess {
                return SigningInfo(status: status, teamID: teamID, signingID: signingID)
            }
        }
        let codeFlags = (info[kSecCodeInfoFlags as String] as? UInt32) ?? 0
        let isAdHoc = codeFlags & UInt32(SecCodeSignatureFlags.adhoc.rawValue) != 0
        return SigningInfo(status: isAdHoc ? .adHoc : .unknown, teamID: teamID, signingID: signingID)
    }
}

/// Caches signature checks per path and runs them off the main thread.
actor SignatureCache {
    private var cache: [String: SigningInfo] = [:]

    func info(for path: String) async -> SigningInfo {
        if let cached = cache[path] { return cached }
        let result = await Task.detached(priority: .utility) { CodeSignatureInspector.inspect(path: path) }.value
        cache[path] = result
        return result
    }
}
