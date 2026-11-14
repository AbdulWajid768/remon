import AppKit
import SwiftUI

/// Remon's colour palette.
///
/// Every hue in the app comes from here, and nowhere else: no view reaches for `.red`, `.green`,
/// `.blue` and friends. The system colours are tuned to shout — they sit at or near full chroma,
/// and in dark mode AppKit brightens them further, so a window of them reads as a toybox: electric
/// blue beside neon magenta beside traffic-cone orange.
///
/// These are the same hues taken down to a *mid* chroma and held at a steady lightness, the way a
/// printed chart or a well-made instrument panel does it. In light mode each token is a deep jewel
/// tone (luminance ≈ 0.09–0.15, so it clears 3:1 on the light glass and most clear 4.5:1); in dark
/// mode it becomes the dusty pastel of the same hue (luminance ≈ 0.35–0.48, clearing 4.8:1 on the
/// card material). Because the pairs share a hue and a role, a chart keeps its meaning when the
/// appearance flips, and no single series leaps out of the page.
///
/// Tokens are adaptive `NSColor`s, so they resolve per appearance wherever they are used —
/// including inside Swift Charts marks and `Canvas` strokes.
enum Palette {
    // MARK: - Hues

    /// Positive, healthy, online. #0B7A5A / #4FC9A0
    static let jade = adaptive(light: 0x0B7A5A, dark: 0x4FC9A0)
    /// A lighter companion to `jade`, for a second green series. #3F8F74 / #86D3B6
    static let sage = adaptive(light: 0x3F8F74, dark: 0x86D3B6)
    /// Cool, secondary. #0D6E78 / #52B9C4
    static let teal = adaptive(light: 0x0D6E78, dark: 0x52B9C4)
    /// Infrastructure, CDNs. #1A6B94 / #6AAFCE
    static let sky = adaptive(light: 0x1A6B94, dark: 0x6AAFCE)
    /// The workhorse blue: CPU, downloads, reads. #1F5FA8 / #7FA8DC
    static let azure = adaptive(light: 0x1F5FA8, dark: 0x7FA8DC)
    /// Large platforms and other third parties. #3F4C9B / #949BDB
    static let indigo = adaptive(light: 0x3F4C9B, dark: 0x949BDB)
    /// GPU, telemetry, the second series beside `azure`. #6A3FA0 / #B49ADE
    static let violet = adaptive(light: 0x6A3FA0, dark: 0xB49ADE)
    /// A third categorical hue, away from both blue and red. #8E3A6E / #D49BBD
    static let plum = adaptive(light: 0x8E3A6E, dark: 0xD49BBD)
    /// Error, blocked, offline, over limit. #A8243A / #E8818F
    static let garnet = adaptive(light: 0xA8243A, dark: 0xE8818F)
    /// Warning, paused, uploads, writes. #A85122 / #E09A6E
    static let ember = adaptive(light: 0xA85122, dark: 0xE09A6E)
    /// Caution, one step below `ember`. #8A6410 / #D9B46A
    static let amber = adaptive(light: 0x8A6410, dark: 0xD9B46A)
    /// Neutral, unclassified, inert. #5A6472 / #9BA4B0
    static let slate = adaptive(light: 0x5A6472, dark: 0x9BA4B0)

    // MARK: - Chart furniture

    /// Hover rules and selection bands behind chart marks: a neutral veil, never a grey line.
    static let chartHighlight = adaptive(light: 0x5A6472, dark: 0x9BA4B0).opacity(0.14)

    // MARK: - Scales

    /// Load and utilisation, cool → warm. Used for CPU cores, temperatures and percentages, so a
    /// hot core reads the same wherever it appears.
    static func load(_ value: Double?) -> Color {
        guard let value else { return slate }
        switch value {
        case 90...: return garnet
        case 75..<90: return ember
        case 60..<75: return amber
        default: return jade
        }
    }

    /// Quota and budget fill, 0…1+. Jade until it matters, then amber, then garnet.
    static func quota(_ fraction: Double) -> Color {
        switch fraction {
        case 1...: return garnet
        case 0.8..<1: return ember
        default: return jade
        }
    }

    // MARK: - Construction

    /// An `NSColor` that resolves per appearance, as `Color`. The two hexes are the same hue at
    /// the two ends of the lightness range the palette holds to.
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(rgb: dark) : NSColor(rgb: light)
        })
    }
}

extension NSColor {
    /// 0xRRGGBB in sRGB.
    convenience init(rgb: UInt32) {
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                  green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255,
                  alpha: 1)
    }
}
