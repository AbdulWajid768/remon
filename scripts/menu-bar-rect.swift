// Prints "<x> <y> <w> <h>" for the right-hand strip of the menu bar on the main display,
// in the points screencapture -R expects. Used by scripts/screenshots.sh.
import AppKit
guard let screen = NSScreen.main else { exit(1) }
let full = screen.frame
// `visibleFrame` starts below the menu bar, so the gap at the top is the menu bar's height.
let barHeight = full.maxY - screen.visibleFrame.maxY
let width: CGFloat = 512
print("\(Int(full.maxX - width)) 0 \(Int(width)) \(Int(barHeight.rounded()))")
