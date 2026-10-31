// Paints over a rectangle of a PNG (for redacting personal data from screenshots).
// Usage: swift scripts/redact.swift <in.png> <out.png> <x> <y> <w> <h> [label]   (pixels, top-left origin)
import AppKit
let a = CommandLine.arguments
guard a.count >= 7, let image = NSImage(contentsOfFile: a[1]),
      let rep = image.representations.first as? NSBitmapImageRep ?? NSBitmapImageRep(data: image.tiffRepresentation!) else { exit(1) }
let (x, y, w, h) = (Double(a[3])!, Double(a[4])!, Double(a[5])!, Double(a[6])!)
let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
rep.draw(in: NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
let rect = NSRect(x: x, y: Double(rep.pixelsHigh) - y - h, width: w, height: h)
NSColor(white: 0.16, alpha: 1).setFill()
NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
if a.count > 7 {
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 26, weight: .medium), .foregroundColor: NSColor(white: 0.6, alpha: 1)]
    let text = NSAttributedString(string: a[7], attributes: attrs)
    text.draw(at: NSPoint(x: rect.minX + 24, y: rect.midY - 15))
}
NSGraphicsContext.restoreGraphicsState()
try! out.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
