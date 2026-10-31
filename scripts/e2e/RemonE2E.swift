// End-to-end UI test for Remon, driven through the macOS Accessibility API like a user would:
// pressing buttons, selecting sidebar rows, typing real keystrokes, using menus and the menu bar item.
//
//   swiftc -O -o build/remon-e2e scripts/e2e/RemonE2E.swift && build/remon-e2e [scenario…]
//
// Requires Accessibility permission for the terminal that runs it. Remon must already be running.
// Screenshots of each step go to build/e2e/.

import AppKit
import ApplicationServices

setvbuf(stdout, nil, _IOLBF, 0)

// MARK: - AX wrapper

struct AX: CustomStringConvertible {
    let element: AXUIElement

    func attr(_ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    var role: String { attr(kAXRoleAttribute) as? String ?? "" }
    var subrole: String { attr(kAXSubroleAttribute) as? String ?? "" }
    var title: String { attr(kAXTitleAttribute) as? String ?? "" }
    var desc: String { attr(kAXDescriptionAttribute) as? String ?? "" }
    var identifier: String { attr("AXIdentifier") as? String ?? "" }
    var value: String {
        if let s = attr(kAXValueAttribute) as? String { return s }
        if let n = attr(kAXValueAttribute) as? NSNumber { return n.stringValue }
        return ""
    }
    var label: String { [title, desc, value].first { !$0.isEmpty } ?? "" }
    var children: [AX] { (attr(kAXChildrenAttribute) as? [AXUIElement] ?? []).map(AX.init) }
    var enabled: Bool { (attr(kAXEnabledAttribute) as? Bool) ?? true }
    var frame: CGRect {
        var p = CGPoint.zero, s = CGSize.zero
        if let pv = attr(kAXPositionAttribute) { AXValueGetValue(pv as! AXValue, .cgPoint, &p) }
        if let sv = attr(kAXSizeAttribute) { AXValueGetValue(sv as! AXValue, .cgSize, &s) }
        return CGRect(origin: p, size: s)
    }
    var description: String { "\(role)[\(label)]" }

    @discardableResult func press() -> Bool { AXUIElementPerformAction(element, kAXPressAction as CFString) == .success }
    @discardableResult func set(_ name: String, _ value: AnyObject) -> Bool {
        AXUIElementSetAttributeValue(element, name as CFString, value) == .success
    }

    func all(maxDepth: Int = 40, _ match: (AX) -> Bool) -> [AX] {
        var out: [AX] = []
        func walk(_ e: AX, _ d: Int) {
            if match(e) { out.append(e) }
            guard d < maxDepth else { return }
            for c in e.children { walk(c, d + 1) }
        }
        walk(self, 0)
        return out
    }

    func first(maxDepth: Int = 40, _ match: (AX) -> Bool) -> AX? {
        func walk(_ e: AX, _ d: Int) -> AX? {
            if match(e) { return e }
            guard d < maxDepth else { return nil }
            for c in e.children { if let hit = walk(c, d + 1) { return hit } }
            return nil
        }
        return walk(self, 0)
    }

    /// Static texts and labelled elements, skipping table bodies (their AX trees are huge and slow).
    func texts(includeTables: Bool = false) -> [String] {
        var out: [String] = []
        func walk(_ e: AX, _ d: Int) {
            guard d < 30 else { return }
            let r = e.role
            if r == "AXStaticText" { if !e.value.isEmpty { out.append(e.value) } }
            else if !e.desc.isEmpty, r != "AXButton" { out.append(e.desc) }
            if !includeTables && (r == "AXTable" || (r == "AXOutline" && e.desc != "Sidebar")) { return }
            for c in e.children { walk(c, d + 1) }
        }
        walk(self, 0)
        return out
    }
    var rows: [AX] { (attr("AXRows") as? [AXUIElement] ?? []).map(AX.init) }
    func button(_ label: String) -> AX? { first { $0.role == "AXButton" && ($0.desc == label || $0.title == label) } }
}

// MARK: - Harness

let remonPID: pid_t = {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.remon.Remon").first else {
        print("Remon is not running."); exit(2)
    }
    return app.processIdentifier
}()
let app = AX(element: AXUIElementCreateApplication(remonPID))
AXUIElementSetMessagingTimeout(app.element, 5)

var failures: [String] = []
var passes = 0
let shotDir = URL(fileURLWithPath: "build/e2e", isDirectory: true)
try? FileManager.default.createDirectory(at: shotDir, withIntermediateDirectories: true)

func check(_ condition: Bool, _ message: String) {
    if condition { passes += 1; print("  ✔ \(message)") } else { failures.append(message); print("  ✘ \(message)") }
}

func wait(_ seconds: Double = 0.6) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

@discardableResult
func waitFor(_ timeout: Double = 6, _ condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end { if condition() { return true }; wait(0.25) }
    return condition()
}

var windows: [AX] { (app.attr(kAXWindowsAttribute) as? [AXUIElement] ?? []).map(AX.init) }
var mainWindow: AX? { windows.first { $0.title.contains("connections") || $0.title.contains("Starting") || $0.title.contains("Paused") || $0.subrole == "AXStandardWindow" && $0.frame.width > 800 } }
func window(titled prefix: String) -> AX? { windows.first { $0.title.hasPrefix(prefix) } }
func sheet(of w: AX?) -> AX? { w?.children.first { $0.role == "AXSheet" } }

var remonIsFrontmost: Bool { NSWorkspace.shared.frontmostApplication?.processIdentifier == remonPID }

/// Brings Remon forward the way System Events does (AXFrontmost), and confirms it.
@discardableResult
func activate() -> Bool {
    if remonIsFrontmost { return true }
    app.set(kAXFrontmostAttribute, kCFBooleanTrue)
    return waitFor(3) { remonIsFrontmost }
}

var skippedKeys = 0

/// Sends a key event to Remon only — posted to its process, and only while it is frontmost — so a
/// focus change can never redirect test keystrokes into someone else's app.
/// `requireFrontmost: false` is for Remon's own non-activating menu bar panel; the event is still
/// posted to Remon's process only, so it can't reach another app.
func key(_ code: CGKeyCode, _ flags: CGEventFlags = [], requireFrontmost: Bool = true) {
    if !requireFrontmost {
        let src = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)!
            e.flags = flags
            e.postToPid(remonPID)
            wait(0.03)
        }
        wait(0.5)
        return
    }
    guard activate() else { skippedKeys += 1; print("    (skipped key: Remon is not frontmost)"); return }
    let src = CGEventSource(stateID: .combinedSessionState)
    for down in [true, false] {
        guard remonIsFrontmost else { skippedKeys += 1; return }
        let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)!
        e.flags = flags
        e.postToPid(remonPID)
        wait(0.03)
    }
    wait(0.5)
}

func type(_ text: String) {
    guard activate() else { skippedKeys += 1; print("    (skipped typing: Remon is not frontmost)"); return }
    let src = CGEventSource(stateID: .combinedSessionState)
    for scalar in text.utf16 {
        var c = scalar
        for down in [true, false] {
            guard remonIsFrontmost else { skippedKeys += 1; return }
            let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)!
            e.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c)
            e.postToPid(remonPID)
        }
        wait(0.02)
    }
    wait(0.5)
}

/// Escape to the macOS authorization dialog only (never a password).
func cancelAuthorizationDialog() {
    guard let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.SecurityAgent").first else { return }
    let src = CGEventSource(stateID: .combinedSessionState)
    for down in [true, false] { CGEvent(keyboardEventSource: src, virtualKey: Key.escape, keyDown: down)?.postToPid(agent.processIdentifier) }
}

enum Key {
    static let ret: CGKeyCode = 36, escape: CGKeyCode = 53, tab: CGKeyCode = 48, down: CGKeyCode = 125, delete: CGKeyCode = 51
    static func digit(_ n: Int) -> CGKeyCode { [29, 18, 19, 20, 21, 23, 22, 26, 28, 25][n] }
    static let a: CGKeyCode = 0, e: CGKeyCode = 14, f: CGKeyCode = 3, i: CGKeyCode = 34, k: CGKeyCode = 40, m: CGKeyCode = 46
    static let p: CGKeyCode = 35, q: CGKeyCode = 12, comma: CGKeyCode = 43, w: CGKeyCode = 13
}

func screenshot(_ name: String) {
    let ids = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    guard let id = ids.first(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == remonPID && ($0[kCGWindowLayer as String] as? Int) == 0 })?[kCGWindowNumber as String] else { return }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-o", "-x", "-l", "\(id)", shotDir.appendingPathComponent("\(name).png").path]
    try? p.run(); p.waitUntilExit()
}

/// Presses a menu item through AX (works even if a previous step closed the window).
@discardableResult
func pressMenu(_ menu: String, _ item: String) -> Bool {
    guard let bar = app.attr(kAXMenuBarAttribute).map({ AX(element: $0 as! AXUIElement) }),
          let top = bar.children.first(where: { $0.title == menu }),
          let list = top.children.first,
          let entry = list.children.first(where: { $0.title == item }) else { return false }
    return entry.press()
}

/// Makes sure the main window is open and Remon is in front before a scenario starts.
func ensureMainWindow() {
    activate()
    if mainWindow == nil { pressMenu("File", "Show Main Window") }
    _ = waitFor(4) { mainWindow != nil }
    activate()
}

func sidebarRow(_ name: String) -> AX? {
    mainWindow?.first(maxDepth: 8, { $0.role == "AXOutline" && $0.desc == "Sidebar" })?.rows.first { row in
        row.first(maxDepth: 4) { ($0.role == "AXStaticText" && $0.value == name) || $0.desc == name || $0.title == name } != nil
    }
}

/// The section's data table. SwiftUI `Table` reports itself as AXOutline on macOS 26 (AXTable on
/// older systems). Breadth-first, so it never wanders into a 2,000-row table's cells.
func findTable() -> AX? {
    guard let w = mainWindow else { return nil }
    var queue: [(AX, Int)] = [(w, 0)]
    while !queue.isEmpty {
        let (e, d) = queue.removeFirst()
        let r = e.role
        if r == "AXTable" || (r == "AXOutline" && e.desc != "Sidebar") { return e }
        if r == "AXOutline" || d > 12 { continue }
        queue += e.children.map { ($0, d + 1) }
    }
    return nil
}

func sectionTitle() -> String { mainWindow.map { String($0.title.split(separator: "–").first ?? "").trimmingCharacters(in: .whitespaces) } ?? "" }

// MARK: - Scenarios

func onboarding() {
    print("Onboarding")
    guard let w = mainWindow, let s = sheet(of: w) else { check(false, "onboarding sheet is shown on first launch"); return }
    check(true, "onboarding sheet is shown on first launch")
    check(s.texts().contains("Welcome to Remon"), "welcome page has a title")
    screenshot("01-onboarding-welcome")
    s.button("Continue")?.press(); wait(0.8)
    check(sheet(of: w)?.texts().contains("Your data stays on your Mac") == true, "Continue goes to the privacy page")
    let toggles = sheet(of: w)?.all { $0.role == "AXCheckBox" || $0.subrole == "AXSwitch" || $0.role == "AXSwitch" } ?? []
    check(toggles.count >= 2, "privacy page has hostname and location toggles (found \(toggles.count))")
    screenshot("02-onboarding-privacy")
    sheet(of: w)?.button("Back")?.press(); wait(0.6)
    check(sheet(of: w)?.texts().contains("Welcome to Remon") == true, "Back returns to the welcome page")
    sheet(of: w)?.button("Continue")?.press(); wait(0.6)
    sheet(of: w)?.button("Continue")?.press(); wait(0.8)
    check(sheet(of: w)?.button("Start Monitoring") != nil, "last page offers Start Monitoring")
    screenshot("03-onboarding-finish")
    sheet(of: w)?.button("Start Monitoring")?.press()
    check(waitFor(3) { sheet(of: mainWindow) == nil }, "Start Monitoring dismisses onboarding")
    let done = UserDefaults(suiteName: "com.remon.Remon")?.bool(forKey: "hasCompletedOnboarding") ?? false
    check(done, "completion is remembered")
}

func navigation() {
    print("Sidebar + keyboard navigation")
    let sections = ["Overview", "System", "Apps", "Connections", "Map", "History", "Log", "Speed Test", "Alerts"]
    for (i, name) in sections.enumerated() {
        key(Key.digit(i + 1), .maskCommand)
        check(waitFor(3) { sectionTitle() == name }, "⌘\(i + 1) opens \(name) (title: \(sectionTitle()))")
    }
    if let row = sidebarRow("Rules") {
        row.set(kAXSelectedAttribute, kCFBooleanTrue)
        check(waitFor(3) { sectionTitle() == "Rules" }, "clicking the Rules sidebar row opens Rules")
    } else { check(false, "Rules sidebar row exists") }
    // Badged rows must still be labelled for VoiceOver.
    check(sidebarRow("Connections") != nil, "badged sidebar rows are named for VoiceOver (“Connections”)")
}

func overview() {
    print("Overview")
    key(Key.digit(1), .maskCommand)
    wait(2)
    guard let w = mainWindow else { return }
    let texts = w.texts()
    for title in ["Download", "Upload", "Today", "This Session", "Connections", "Live Throughput", "Top Apps Right Now", "Network"] {
        check(texts.contains(title), "Overview shows “\(title)”")
    }
    check(texts.contains { $0.hasSuffix("/s") }, "live rate values are readable")
    screenshot("10-overview")
}

func system() {
    print("System")
    key(Key.digit(2), .maskCommand)
    check(waitFor(6) { mainWindow?.texts().contains("CPU Temperature") == true }, "System view renders")
    let texts = mainWindow?.texts() ?? []
    check(texts.contains { $0.hasSuffix("%") }, "CPU/GPU/memory percentages shown")
    check(texts.contains { $0.contains("°C") }, "temperatures shown")
    check(texts.contains("Maximum capacity") || texts.contains("Battery") == false, "battery health uses macOS's Maximum capacity")
    if let i = texts.firstIndex(of: "Maximum capacity") { print("    battery: \(texts[i + 1])") }
    screenshot("11-system")
}

func connectionsSearch() {
    print("Connections + search")
    key(Key.digit(4), .maskCommand)
    wait(1.5)
    guard let table = findTable() else {
        check(false, "connections table exists"); return
    }
    let before = table.rows.count
    check(before > 0, "connections table has rows (\(before))")
    key(Key.f, .maskCommand)
    let field = mainWindow?.first(maxDepth: 8, { $0.subrole == "AXSearchField" })
    let focused = app.attr(kAXFocusedUIElementAttribute).map { AX(element: $0 as! AXUIElement) }
    check(focused?.subrole == "AXSearchField" || focused?.role == "AXTextField", "⌘F focuses the search field (focused: \(focused?.description ?? "nothing"))")
    type("proto:tcp ")
    wait(1.2)
    let rows = table.rows
    let protocols = rows.prefix(25).flatMap { $0.texts(includeTables: true) }.filter { ["TCP", "UDP", "QUIC"].contains($0) }
    check(!rows.isEmpty && protocols.allSatisfy { $0 == "TCP" }, "proto:tcp leaves only TCP rows (\(rows.count) rows)")
    screenshot("12-connections-search")
    // Clear the query.
    if let field { field.set(kAXFocusedAttribute, kCFBooleanTrue); key(Key.a, .maskCommand); key(Key.delete) }
    wait(1)
    let after = table.rows.count
    check(after > rows.count, "clearing search restores the other rows (\(rows.count) → \(after))")
}

func quickOpen() {
    print("Quick Open")
    key(Key.k, .maskCommand)
    check(waitFor(3) { sheet(of: mainWindow) != nil }, "⌘K opens Quick Open")
    type("speed")
    key(Key.ret)
    check(waitFor(3) { sectionTitle() == "Speed Test" }, "typing “speed” + Return jumps to Speed Test")
    check(sheet(of: mainWindow) == nil, "Quick Open closes after choosing")
    key(Key.k, .maskCommand)
    _ = waitFor(2) { sheet(of: mainWindow) != nil }
    key(Key.escape)
    check(waitFor(2) { sheet(of: mainWindow) == nil }, "Escape closes Quick Open")
}

func pauseAndInspector() {
    print("Pause / inspector")
    key(Key.digit(4), .maskCommand)
    key(Key.p, [.maskCommand, .maskShift])
    check(waitFor(3) { mainWindow?.title.contains("Paused") == true }, "⇧⌘P pauses (subtitle says Paused)")
    key(Key.p, [.maskCommand, .maskShift])
    check(waitFor(3) { mainWindow?.title.contains("Paused") == false }, "⇧⌘P resumes")
    let hadInspector = mainWindow?.texts().contains("Endpoints") == true || mainWindow?.texts().contains("No Selection") == true
    key(Key.i, [.maskCommand, .maskAlternate])
    wait(0.8)
    let hasInspector = mainWindow?.texts().contains("Endpoints") == true || mainWindow?.texts().contains("No Selection") == true
    check(hadInspector != hasInspector, "⌥⌘I toggles the inspector")
    key(Key.i, [.maskCommand, .maskAlternate])
}

func appsInspector() {
    print("Apps + inspector")
    key(Key.digit(3), .maskCommand)
    wait(1.5)
    guard let table = findTable(), let row = table.rows.first else {
        check(false, "apps table has rows"); return
    }
    row.set(kAXSelectedAttribute, kCFBooleanTrue)
    wait(1.2)
    let texts = mainWindow?.texts() ?? []
    check(texts.contains("Last 2 Minutes"), "selecting an app shows its inspector")
    check(texts.contains("Connections") || texts.contains { $0.hasPrefix("Connections (") }, "inspector lists the app's connections")
    screenshot("13-apps-inspector")
}

func historyAndLog() {
    print("History / Log")
    key(Key.digit(6), .maskCommand)
    wait(1.5)
    let seg = mainWindow?.first { $0.role == "AXRadioButton" && $0.label == "7 Days" }
    seg?.press()
    wait(1.2)
    check(mainWindow?.texts().contains("Usage by Day") == true, "7 Days switches History to daily bars")
    screenshot("14-history-week")
    key(Key.digit(7), .maskCommand)
    wait(1.5)
    let rows = findTable()?.rows.count ?? 0
    check(rows > 0, "connection log has entries (\(rows))")
    screenshot("15-log")
}

func alertsEditor() {
    print("Alerts")
    key(Key.digit(9), .maskCommand)
    wait(1)
    guard let add = mainWindow?.button("Add Rule") else { check(false, "Add Rule button exists"); return }
    add.press()
    check(waitFor(3) { sheet(of: mainWindow) != nil }, "Add Rule opens the editor")
    screenshot("16-alert-editor")
    sheet(of: mainWindow)?.button("Cancel")?.press()
    check(waitFor(2) { sheet(of: mainWindow) == nil }, "Cancel closes the editor")
}

func settingsWindow() {
    print("Settings")
    key(Key.comma, .maskCommand)
    check(waitFor(4) { window(titled: "General") != nil }, "⌘, opens Settings")
    if let settings = window(titled: "General") {
        for tab in ["Monitoring", "Data Plan", "Privacy", "Notifications", "Advanced", "General"] {
            let button = settings.first { ($0.role == "AXButton" || $0.role == "AXRadioButton") && $0.label == tab }
            button?.press()
            check(waitFor(2) { window(titled: tab) != nil }, "Settings tab “\(tab)” opens")
        }
        screenshot("17-settings")
        // Close via its close button rather than ⌘W, so a focus mix-up can't close the main window.
        settings.first(maxDepth: 2) { $0.subrole == "AXCloseButton" }?.press()
        check(waitFor(2) { window(titled: "General") == nil }, "Settings closes")
    }
}

func floatingMonitor() {
    print("Floating monitor")
    key(Key.m, [.maskCommand, .maskAlternate])
    check(waitFor(3) { window(titled: "Floating Monitor") != nil || windows.contains { $0.frame.width < 300 && $0.frame.width > 200 } }, "⌥⌘M shows the floating monitor")
    key(Key.m, [.maskCommand, .maskAlternate])
    check(waitFor(3) { !windows.contains { $0.frame.width < 300 && $0.frame.width > 200 } }, "⌥⌘M hides it again")
}

func menuBarItem() {
    print("Menu bar")
    guard let extras = app.attr("AXExtrasMenuBar").map({ AX(element: $0 as! AXUIElement) }),
          let item = extras.children.first else { check(false, "status item exists"); return }
    check(item.label.contains("Remon") || !item.label.isEmpty, "status item has an accessible label (\(item.label.prefix(60)))")
    item.press()
    let isPanel: (AX) -> Bool = { $0.subrole == "AXSystemDialog" || $0.texts().contains { $0.caseInsensitiveCompare("Top Apps") == .orderedSame } }
    check(waitFor(3) { windows.contains(where: isPanel) }, "clicking the status item opens the panel")
    if let panel = windows.first(where: isPanel) {
        let t = panel.texts()
        check(t.contains("Download") && t.contains("Upload") && t.contains("Today"), "panel shows rates and today's totals")
        check(t.contains("CPU") && t.contains("TEMP"), "panel shows the system strip")
        let unlabeled = panel.all { $0.role == "AXButton" && ["pip", "gearshape", "Power", "Speed"].contains($0.desc) }
        check(unlabeled.isEmpty, "panel buttons have spoken labels (\(unlabeled.map(\.desc)))")
    }
    key(Key.escape, requireFrontmost: false)
    check(waitFor(2) { !windows.contains(where: isPanel) }, "Escape closes the panel")
    item.press()
    check(waitFor(3) { windows.contains(where: isPanel) }, "the status item reopens the panel after Escape")
    item.press()
    _ = waitFor(2) { !windows.contains(where: isPanel) }
}

func export() {
    print("Export")
    let name = "remon-e2e-\(Int(Date().timeIntervalSince1970))"
    pressMenu("View", "Connections")
    key(Key.e, .maskCommand)
    let panel = { windows.first { $0.title.hasPrefix("Export") } }
    check(waitFor(4) { panel() != nil }, "⌘E opens the export save panel")
    guard let p = panel() else { return }
    let folder = p.first(maxDepth: 20, { $0.role == "AXPopUpButton" })?.value ?? "Documents"
    // Set the file name the way a user's typing would end up, then press Save.
    p.first(maxDepth: 20, { $0.role == "AXTextField" && $0.desc != "tag editor" })?.set(kAXValueAttribute, name as CFString)
    wait(0.3)
    p.first(maxDepth: 20, { $0.role == "AXButton" && $0.title == "Save" })?.press()
    let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("\(folder)/\(name).csv")
    check(waitFor(4) { FileManager.default.fileExists(atPath: file.path) }, "export wrote \(folder)/\(name).csv")
    if let text = try? String(contentsOf: file, encoding: .utf8) {
        check(text.hasPrefix("app,process,pid,protocol"), "export has the CSV header")
        check(text.split(separator: "\n").count > 1, "export has data rows (\(text.split(separator: "\n").count - 1))")
        try? FileManager.default.removeItem(at: file)
    }
}

var authDialogOnScreen: Bool {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.contains { ($0[kCGWindowOwnerName as String] as? String) == "SecurityAgent" }
}

func blockingCancel() {
    print("Blocking (cancel at the admin prompt — never types a password)")
    pressMenu("View", "Rules")
    _ = waitFor(3) { sectionTitle() == "Rules" }
    let switchNamed = { (name: String) in mainWindow?.first(maxDepth: 30, { $0.role == "AXCheckBox" && $0.desc == name }) }
    guard let toggle = switchNamed("Block macOS Software Update") else { check(false, "“Block macOS Software Update” switch is reachable"); return }
    check(toggle.enabled, "“Block macOS Software Update” switch is reachable and labelled")
    toggle.press()
    let appeared = waitFor(8) { authDialogOnScreen }
    check(appeared, "turning on a block asks for an administrator password")
    if appeared {
        wait(0.8)
        cancelAuthorizationDialog()
        check(waitFor(5) { !authDialogOnScreen }, "the password prompt can be cancelled")
    }
    check(waitFor(5) { mainWindow?.texts().contains("Rules not applied") == true }, "cancelling shows “Rules not applied”")
    screenshot("18-rules-cancelled")
    // Switching it back off restores the original state, which needs no password.
    switchNamed("Block macOS Software Update")?.press()
    let prompted = waitFor(3) { authDialogOnScreen }
    if prompted { cancelAuthorizationDialog() }
    check(!prompted, "switching the block back off doesn't ask for a password again")
    check(waitFor(4) { mainWindow?.texts().contains("Nothing blocked") == true }, "status returns to “Nothing blocked”")
    let hosts = (try? String(contentsOfFile: "/etc/hosts", encoding: .utf8)) ?? ""
    check(!hosts.contains("BEGIN REMON"), "/etc/hosts untouched")
}

func quit() {
    print("Quit")
    key(Key.q, .maskCommand)
    let gone = waitFor(6) { NSRunningApplication(processIdentifier: remonPID) == nil || NSRunningApplication(processIdentifier: remonPID)!.isTerminated }
    check(gone, "⌘Q quits")
    wait(1)
    let ps = Process()
    ps.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    ps.arguments = ["-f", "nettop -L 0"]
    ps.standardOutput = FileHandle.nullDevice
    try? ps.run(); ps.waitUntilExit()
    check(ps.terminationStatus != 0, "no nettop left behind")
}

// MARK: - Run

let scenarios: [(String, () -> Void)] = [
    ("onboarding", onboarding), ("navigation", navigation), ("overview", overview), ("system", system),
    ("connections", connectionsSearch), ("quickopen", quickOpen), ("pause", pauseAndInspector), ("apps", appsInspector),
    ("history", historyAndLog), ("alerts", alertsEditor), ("settings", settingsWindow), ("hud", floatingMonitor),
    ("menubar", menuBarItem), ("export", export), ("blocking", blockingCancel), ("quit", quit),
]
let requested = Set(CommandLine.arguments.dropFirst())
/// Remon's physical memory footprint (what Activity Monitor calls "Memory").
func footprintMB() -> Double {
    var info = rusage_info_v4()
    let ok = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(remonPID, RUSAGE_INFO_V4, $0) }
    }
    return ok == 0 ? Double(info.ri_phys_footprint) / 1_048_576 : -1
}

let startFootprint = footprintMB()
print(String(format: "Remon footprint at start: %.0f MB", startFootprint))
for (name, run) in scenarios where requested.isEmpty || requested.contains(name) {
    if name != "onboarding" && name != "quit" { ensureMainWindow() }
    run()
    if name != "quit" { print(String(format: "    footprint after %@: %.0f MB", name, footprintMB())) }
}
if requested.isEmpty || !requested.contains("quit") {
    let growth = footprintMB() - startFootprint
    check(growth < 400, String(format: "memory stays bounded during the run (+%.0f MB)", growth))
}
print("\n\(passes) passed, \(failures.count) failed" + (skippedKeys > 0 ? ", \(skippedKeys) keystrokes skipped because Remon wasn't frontmost" : ""))
for f in failures { print("  ✘ \(f)") }
exit(failures.isEmpty ? 0 : 1)
