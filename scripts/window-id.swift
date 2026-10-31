// Prints the CGWindowID of an on-screen window owned by an app.
// Usage: swift scripts/window-id.swift <owner> [title-substring]   (no title → largest window)
import CoreGraphics
let args = CommandLine.arguments
let owner = args.count > 1 ? args[1] : "Remon"
let title = args.count > 2 ? args[2] : nil
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
var windows = list.filter { ($0[kCGWindowOwnerName as String] as? String) == owner && ($0[kCGWindowLayer as String] as? Int) == 0 }
if let title { windows = windows.filter { ($0[kCGWindowName as String] as? String)?.contains(title) == true } }
func area(_ w: [String: Any]) -> Double {
    let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
    return (b["Width"] ?? 0) * (b["Height"] ?? 0)
}
if let id = windows.max(by: { area($0) < area($1) })?[kCGWindowNumber as String] { print(id) }
