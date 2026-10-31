// Renders Remon's app icon at 1024 px. Usage: swift scripts/make-icon.swift <out.png>
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// Big Sur–style tile: 824 pt rounded rect centred on a 1024 canvas.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
ctx.addPath(tilePath)
ctx.setFillColor(NSColor.black.cgColor)
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let colors = [NSColor(srgbRed: 0.07, green: 0.10, blue: 0.30, alpha: 1).cgColor,
              NSColor(srgbRed: 0.16, green: 0.30, blue: 0.85, alpha: 1).cgColor,
              NSColor(srgbRed: 0.45, green: 0.30, blue: 0.95, alpha: 1).cgColor] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 0.6, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 100, y: 100), end: CGPoint(x: 924, y: 924), options: [])

// Subtle grid.
ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.07).cgColor)
ctx.setLineWidth(3)
for i in 1..<6 {
    let y = 100 + CGFloat(i) * 824 / 6
    ctx.move(to: CGPoint(x: 100, y: y)); ctx.addLine(to: CGPoint(x: 924, y: y))
}
ctx.strokePath()

// Mirrored traffic bars (download up, upload down).
let mid: CGFloat = 470
let heights: [CGFloat] = [40, 70, 55, 110, 90, 160, 120, 210, 150, 260, 190, 140, 230, 170, 100, 60]
let barWidth: CGFloat = 34
for (i, h) in heights.enumerated() {
    let x = 170 + CGFloat(i) * 44
    ctx.setFillColor(NSColor(srgbRed: 0.45, green: 0.80, blue: 1.0, alpha: 0.85).cgColor)
    ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: mid + 8, width: barWidth, height: h), cornerWidth: 10, cornerHeight: 10, transform: nil))
    ctx.fillPath()
    ctx.setFillColor(NSColor(srgbRed: 1.0, green: 0.62, blue: 0.25, alpha: 0.85).cgColor)
    ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: mid - 8 - h * 0.55, width: barWidth, height: h * 0.55), cornerWidth: 10, cornerHeight: 10, transform: nil))
    ctx.fillPath()
}

// Pulse line with glow.
let pulse = CGMutablePath()
let pts: [(CGFloat, CGFloat)] = [(150, 470), (330, 470), (390, 600), (450, 300), (520, 760), (590, 380), (640, 470), (874, 470)]
pulse.move(to: CGPoint(x: pts[0].0, y: pts[0].1))
for p in pts.dropFirst() { pulse.addLine(to: CGPoint(x: p.0, y: p.1)) }
ctx.setLineJoin(.round); ctx.setLineCap(.round)
ctx.setShadow(offset: .zero, blur: 30, color: NSColor.white.withAlphaComponent(0.9).cgColor)
ctx.setStrokeColor(NSColor.white.cgColor)
ctx.setLineWidth(30)
ctx.addPath(pulse)
ctx.strokePath()
ctx.restoreGState()

// Top highlight.
ctx.saveGState()
ctx.addPath(tilePath)
ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.18).cgColor)
ctx.setLineWidth(4)
ctx.strokePath()
ctx.restoreGState()
image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
