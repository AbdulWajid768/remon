import SwiftUI

/// The "remon" wordmark: one continuous ECG trace that spells the name — the line runs in from the
/// left, draws r·e·m·o·n in a single monoline stroke whose "m" is the pulse spike and dip, and runs
/// out to the right.
///
/// This is the same geometry the app icon is drawn from, so the Dock tile, the welcome screen and
/// the menu bar panel all show one mark. `scripts/make-icon.swift` renders the icon set from the
/// identical construction; keep the two in step if the letterforms ever change.
///
/// Coordinates are *letter units*: the baseline is y = 0 and the x-height is y = 1, y up. The path
/// is then fitted into the view's rect, flipped into SwiftUI's y-down space and centred.
struct RemonWordmark: Shape {
    /// How far the trace runs past the first and last letter, in letter units, so the line enters
    /// and leaves the mark rather than starting at a letter.
    var lead: CGFloat = 0.55

    /// The word's width in letter units, without the leads.
    static let wordWidth: CGFloat = 7.2
    /// The m's spike and dip, which set the vertical extent.
    static let unitTop: CGFloat = 1.28
    static let unitBottom: CGFloat = -0.26

    /// Width ÷ height for a given lead, so callers can size by one dimension.
    static func aspectRatio(lead: CGFloat = 0.55) -> CGFloat {
        (wordWidth + 2 * lead) / (unitTop - unitBottom)
    }

    func path(in rect: CGRect) -> Path {
        let p = CGMutablePath()
        let pi = CGFloat.pi

        // r: stem and a hooked arm.
        let xr: CGFloat = 0
        p.move(to: CGPoint(x: xr - lead, y: 0))
        p.addLine(to: CGPoint(x: xr, y: 0))
        p.addLine(to: CGPoint(x: xr, y: 0.52))
        p.addArc(center: CGPoint(x: xr + 0.48, y: 0.52), radius: 0.48,
                 startAngle: pi, endAngle: pi * 0.33, clockwise: true)

        // e: bowl with a crossbar, the tail opening toward the "m".
        let xe: CGFloat = 1.15
        p.move(to: CGPoint(x: xr, y: 0))
        p.addLine(to: CGPoint(x: xe + 0.5, y: 0))
        p.move(to: CGPoint(x: xe, y: 0.5))
        p.addLine(to: CGPoint(x: xe + 1.0, y: 0.5))
        p.addArc(center: CGPoint(x: xe + 0.5, y: 0.5), radius: 0.5,
                 startAngle: 0, endAngle: -pi * 0.22, clockwise: false)

        // m: the pulse. Spike, dip, second peak.
        let xm: CGFloat = 2.6
        p.move(to: CGPoint(x: xe + 0.5, y: 0))
        p.addLine(to: CGPoint(x: xm, y: 0))
        p.addLine(to: CGPoint(x: xm + 0.42, y: 1.28))
        p.addLine(to: CGPoint(x: xm + 0.84, y: -0.26))
        p.addLine(to: CGPoint(x: xm + 1.26, y: 1.0))
        p.addLine(to: CGPoint(x: xm + 1.68, y: 0))

        // o: a circle resting on the line.
        let xo: CGFloat = 4.75
        p.addLine(to: CGPoint(x: xo + 0.5, y: 0))
        p.addArc(center: CGPoint(x: xo + 0.5, y: 0.5), radius: 0.5,
                 startAngle: -pi / 2, endAngle: pi * 1.5, clockwise: false)

        // n: stem, arch, stem — and the trace runs out of the second stem.
        let xn: CGFloat = 6.2
        p.move(to: CGPoint(x: xo + 0.5, y: 0))
        p.addLine(to: CGPoint(x: xn, y: 0))
        p.addLine(to: CGPoint(x: xn, y: 0.5))
        p.addArc(center: CGPoint(x: xn + 0.5, y: 0.5), radius: 0.5,
                 startAngle: pi, endAngle: 0, clockwise: true)
        p.addLine(to: CGPoint(x: xn + 1.0, y: 0))
        p.addLine(to: CGPoint(x: xn + 1.0 + lead, y: 0))

        // Fit the letter-unit drawing into the rect: scale to whichever axis binds, flip y, centre.
        let unit = Self.unit(for: rect.size, lead: lead)
        var transform = CGAffineTransform(translationX: rect.midX, y: rect.midY)
            .scaledBy(x: unit, y: -unit)
            .translatedBy(x: -Self.wordWidth / 2, y: -(Self.unitTop + Self.unitBottom) / 2)
        return Path(p.copy(using: &transform) ?? p)
    }

    /// Points per letter unit when the mark is fitted to `size`.
    static func unit(for size: CGSize, lead: CGFloat) -> CGFloat {
        min(size.width / (wordWidth + 2 * lead), size.height / (unitTop - unitBottom))
    }
}

/// The wordmark as a finished mark: the trace stroked in the brand's mint→teal, at the icon's
/// stroke weight. Size it by height; the width follows.
struct RemonLogo: View {
    var lead: CGFloat = 0.55
    /// Stroke weight as a fraction of the letter unit — the icon's ratio.
    var weight: CGFloat = 0.24
    var style: AnyShapeStyle = AnyShapeStyle(
        LinearGradient(colors: [Accent.base, Palette.teal], startPoint: .leading, endPoint: .trailing))

    var body: some View {
        GeometryReader { geo in
            let unit = RemonWordmark.unit(for: geo.size, lead: lead)
            RemonWordmark(lead: lead)
                .stroke(style, style: StrokeStyle(lineWidth: unit * weight, lineCap: .round, lineJoin: .round))
        }
        .aspectRatio(RemonWordmark.aspectRatio(lead: lead), contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel("Remon")
        .accessibilityAddTraits(.isImage)
    }
}

#Preview("Wordmark") {
    VStack(spacing: 24) {
        RemonLogo().frame(height: 64)
        RemonLogo().frame(height: 28)
        RemonLogo().frame(height: 14)
    }
    .padding(40)
}
