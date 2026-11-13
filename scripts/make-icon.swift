// Renders Remon's app icon: a mint→teal screen (Accent.base #00C9A7 → .teal) on a deep-teal tile
// (#042F2E, the Accent.label shade), with the word "remon" cut out of the screen as a single ECG trace —
// the line runs in from the left edge, spells r·e·m·o·n in one monoline stroke (the "m" is the pulse's
// sharp spike and dip), and runs out the right edge.
//
// The same wordmark is drawn at every size, so the Dock, Finder and the menu bar all show one mark;
// at 16 and 32 px it reads as the familiar pulse line through a mint screen.
//
//   swift scripts/make-icon.swift <out.png> [size]        one PNG, default 1024
//   swift scripts/make-icon.swift --appiconset <dir>      every size the Mac icon set needs
//
// Each size is rendered from the vector symbol rather than downscaled, so 16 pt stays crisp.
import AppKit

// MARK: - Brand

/// Accent.base — #00C9A7.
let mint = NSColor(srgbRed: 0.000, green: 0.788, blue: 0.655, alpha: 1)
/// SwiftUI's `.teal`, the far end of the welcome screen's gradient.
let teal = NSColor(srgbRed: 0.188, green: 0.651, blue: 0.710, alpha: 1)
/// Accent.label — #042F2E, lightened a touch so the tile isn't flat black.
let tileTop = NSColor(srgbRed: 0.043, green: 0.231, blue: 0.220, alpha: 1)
/// The dark end of the tile, just below #042F2E.
let tileBottom = NSColor(srgbRed: 0.008, green: 0.086, blue: 0.086, alpha: 1)

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func gradient(_ colors: [NSColor], _ locations: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: sRGB, colors: colors.map(\.cgColor) as CFArray, locations: locations)!
}

// MARK: - Render

/// Draws the icon at `size` px square. Every measurement is a fraction of the canvas, so the
/// proportions hold from 16 px to 1024 px.
///
/// The drawing goes into a bitmap of exactly `size` pixels rather than through `NSImage.lockFocus`,
/// which would back the image at the main display's scale and silently double every file.
func icon(size S: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: S, height: S)
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    defer { NSGraphicsContext.restoreGraphicsState() }
    let ctx = graphics.cgContext
    ctx.setShouldAntialias(true)

    // Big Sur tile: 824/1024 of the canvas, with the standard corner radius.
    let inset = S * 100 / 1024
    let tile = CGRect(x: inset, y: inset, width: S - 2 * inset, height: S - 2 * inset)
    let radius = tile.width * 185 / 824
    let tilePath = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Tile shadow. Only worth drawing where there are pixels to spare.
    if S >= 128 {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.012), blur: S * 0.028,
                      color: NSColor.black.withAlphaComponent(0.38).cgColor)
        ctx.addPath(tilePath)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
    }

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()

    // Tile gradient, top-leading to bottom-trailing like the welcome screen's.
    ctx.drawLinearGradient(gradient([tileTop, tileBottom]),
                           start: CGPoint(x: tile.minX, y: tile.maxY),
                           end: CGPoint(x: tile.maxX, y: tile.minY), options: [])

    // A mint glow behind the mark, so the tile reads as lit rather than painted.
    if S >= 64 {
        ctx.drawRadialGradient(gradient([mint.withAlphaComponent(0.26), mint.withAlphaComponent(0)]),
                               startCenter: CGPoint(x: S / 2, y: S * 0.52), startRadius: 0,
                               endCenter: CGPoint(x: S / 2, y: S * 0.52), endRadius: S * 0.42,
                               options: [])
    }

    drawWordmark(in: ctx, size: S)

    ctx.restoreGState()

    // Hairline rim, the usual macOS tile highlight.
    if S >= 64 {
        ctx.saveGState()
        ctx.addPath(tilePath)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.16).cgColor)
        ctx.setLineWidth(max(1, S * 0.004))
        ctx.strokePath()
        ctx.restoreGState()
    }

    return rep
}

// MARK: - Marks

/// "remon" as one ECG trace, in letter units: baseline y = 0, x-height y = 1, y up. The path starts
/// `lead` units left of the "r" and ends `lead` units right of the "n", so it can run off both edges
/// of the screen. Returns the stroke centreline and the word's width (without the leads).
///
/// Every letter sits on the baseline, which the trace follows between letters, so the whole word is
/// a single connected line. The "m" is the pulse: a tall sharp spike, a dip below the baseline, a
/// second peak at x-height. The rest are plain geometric monoline letters.
func wordmarkPath(lead: CGFloat) -> (path: CGMutablePath, width: CGFloat) {
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

    return (p, xn + 1.0)
}

/// The full-size mark: the screen (a rounded rectangle filled with the mint→teal gradient) with the
/// "remon" trace knocked out of it, so the tile shows through the word just as it does through the
/// ECG line of the small-size symbol.
func drawWordmark(in ctx: CGContext, size S: CGFloat) {
    // The screen. Wider than the symbol's so the word has room, same corner treatment.
    let screen = CGRect(x: S * 0.11, y: S * 0.30, width: S * 0.78, height: S * 0.40)
    let screenRadius = screen.height * 0.19
    let screenPath = CGPath(roundedRect: screen, cornerWidth: screenRadius, cornerHeight: screenRadius,
                            transform: nil)

    // Letter unit: fit the word to the screen with equal side margins; the pulse peaks set the height.
    let lead: CGFloat = 4
    let (word, wordWidth) = wordmarkPath(lead: lead)
    let unit = screen.width * 0.84 / wordWidth
    let strokeWidth = unit * 0.24
    let top: CGFloat = 1.28, bottom: CGFloat = -0.26   // the m's extremes, in units
    let baseline = screen.midY - (top + bottom) / 2 * unit
    var transform = CGAffineTransform(translationX: screen.midX - wordWidth / 2 * unit, y: baseline)
        .scaledBy(x: unit, y: unit)
    let trace = word.copy(using: &transform)!

    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.addPath(screenPath)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillPath()

    // Punch the trace out of the screen.
    ctx.setBlendMode(.destinationOut)
    ctx.addPath(trace)
    ctx.setStrokeColor(NSColor.black.cgColor)
    ctx.setLineWidth(strokeWidth)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()

    ctx.setBlendMode(.sourceIn)
    ctx.drawLinearGradient(gradient([mint, teal]),
                           start: CGPoint(x: screen.minX, y: screen.maxY),
                           end: CGPoint(x: screen.maxX, y: screen.minY), options: [])
    ctx.setBlendMode(.normal)
    ctx.endTransparencyLayer()
}

func write(_ rep: NSBitmapImageRep, to path: String) {
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

// MARK: - Entry point

let args = Array(CommandLine.arguments.dropFirst())

if args.first == "--appiconset" {
    let dir = args[1]
    // point size, scale — the ten images a `mac` idiom icon set asks for.
    let wanted: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                                (256, 1), (256, 2), (512, 1), (512, 2)]
    for (points, scale) in wanted {
        let pixels = points * scale
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        write(icon(size: CGFloat(pixels)), to: "\(dir)/\(name)")
        print("\(name)  \(pixels)×\(pixels)")
    }
} else {
    let out = args.first ?? "icon.png"
    let size = args.count > 1 ? CGFloat(Int(args[1])!) : 1024
    write(icon(size: size), to: out)
    print("\(out)  \(Int(size))×\(Int(size))")
}
