// Brings an app's windows forward and parks the mouse out of the way, so a screenshot shows the
// window as the user sees it: key appearance, no hover tooltip under the cursor.
// Usage: swift scripts/focus.swift <owner>
import AppKit

let owner = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Remon"
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.remon.Remon").first
        ?? NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == owner }) else {
    FileHandle.standardError.write(Data("focus: \(owner) is not running\n".utf8))
    exit(1)
}

// Park the cursor in the bottom-left of the main display, away from any chart or row.
if let screen = NSScreen.screens.first {
    CGWarpMouseCursorPosition(CGPoint(x: screen.frame.minX + 8, y: screen.frame.maxY - 8))
    CGAssociateMouseAndMouseCursorPosition(1)
}

app.activate(options: [.activateAllWindows])
// Give AppKit a moment to redraw the window in its key appearance: materials and accent colours
// are noticeably greyer while a window is inactive.
Thread.sleep(forTimeInterval: 1.2)
print(app.isActive ? "active" : "not active")
