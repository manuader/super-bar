import AppKit
import SuperBarKit

/// Real-world Accessibility diagnostics, driven by environment variables so
/// the app can be exercised from a script while it runs as a trusted process
/// (launched through LaunchServices with `open --env`).
///
///   SUPERBAR_DIAG=<output dir>              enables the mode; writes one file per app + summary.txt + done
///   SUPERBAR_DIAG_APPS=<bundle ids, comma>  default: every running regular app except SuperBar
///   SUPERBAR_DIAG_QUERY=<text>              also dumps top list/outline results for the query
///   SUPERBAR_DIAG_PRESS=<bundle id>:<i.j.k> presses that item (index path) after loading
///   SUPERBAR_DIAG_REVEAL=<bundle id>:<i.j>  reveals that item, then sends Escape
///   SUPERBAR_DIAG_HELP=<bundle id>:<query>  opens the Help menu with the query, then Escape
///   SUPERBAR_DIAG_E2E=<item title>          drives the *installed* SuperBar instance end to end:
///                                           activates Finder, presses the global hot key, types the
///                                           title, presses Return, and checks the recents file.
final class DiagnosticsLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ line: String) { lock.lock(); storage.append(line); lock.unlock() }
    func append(contentsOf lines: [String]) { lock.lock(); storage.append(contentsOf: lines); lock.unlock() }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return storage }
}

enum Diagnostics {
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["SUPERBAR_DIAG"] != nil }

    @MainActor
    static func run(app: AppDelegate) {
        let env = ProcessInfo.processInfo.environment
        guard let dirPath = env["SUPERBAR_DIAG"] else { return }
        let dir = URL(fileURLWithPath: dirPath)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let summary = DiagnosticsLog()
        let source = AXMenuSource()
        summary.append("trusted: \(source.isTrusted)")

        let me = ProcessInfo.processInfo.processIdentifier
        let targets: [NSRunningApplication]
        if let list = env["SUPERBAR_DIAG_APPS"] {
            let ids = list.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            targets = ids.compactMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }
        } else {
            targets = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != me }
        }
        let query = env["SUPERBAR_DIAG_QUERY"]
        let hotKey = app.preferences.hotKey

        DispatchQueue.global(qos: .userInitiated).async {
            for running in targets {
                let info = AppInfo(running: running)
                let start = Date()
                var lines: [String] = ["# \(info.name) (\(info.bundleIdentifier ?? "-")) pid \(info.pid)"]
                var progressCount = 0
                do {
                    let roots = try source.loadMenuBar(for: info) { _ in progressCount += 1 }
                    let elapsed = Date().timeIntervalSince(start)
                    let flat = roots.flattened
                    let items = flat.filter { $0.kind == .item }
                    let withKeys = items.filter { $0.keyEquivalent != nil }
                    let disabled = items.filter { !$0.isEnabled }
                    let marks = items.filter { $0.mark != nil }
                    summary.append(String(format: "%@: %d nodes, %d items, %d with shortcuts, %d disabled, %d marked, %d menus, %.0f ms", info.name, flat.count, items.count, withKeys.count, disabled.count, marks.count, roots.count, elapsed * 1000))
                    lines.append("loaded in \(Int(elapsed * 1000)) ms, \(roots.count) menu bar items (progress callbacks: \(progressCount))")
                    for root in roots {
                        root.forEachNode { node in
                            if node.isSeparator { return }
                            let indent = String(repeating: "  ", count: node.depth)
                            var attrs: [String] = []
                            if node.isContainer { attrs.append("[\(node.visibleChildCount)]") }
                            if let k = node.keyEquivalent { attrs.append(k.display) }
                            if let m = node.mark { attrs.append("mark=\(m)") }
                            if !node.isEnabled { attrs.append("disabled") }
                            lines.append("\(indent)\(node.title.isEmpty ? "<untitled>" : node.title)  \(attrs.joined(separator: " "))  @\(node.id)")
                        }
                    }
                    if let query, !query.isEmpty {
                        let q = FuzzyMatcher.Query(query)
                        let candidates = flat.enumerated().map { SearchCandidate(payload: $0.element, title: $0.element.displayTitle, pathText: $0.element.breadcrumb, originalOrder: $0.offset) }
                        let hits = ListSearch.search(q, in: candidates)
                        lines.append("\n## list search '\(query)': \(hits.count) hits")
                        for hit in hits.prefix(12) { lines.append("  \(hit.score)  \(hit.payload.breadcrumb)") }
                        let outline = OutlineSearch.search(q, in: roots)
                        lines.append("## outline search '\(query)': \(outline.ranges.count) matches, \(outline.expanded.count) expanded, best=\(outline.bestMatch.map { $0.description } ?? "nil")")
                    }
                } catch {
                    let msg = (error as? MenuSourceError)?.message ?? error.localizedDescription
                    summary.append("\(info.name): ERROR \(msg)")
                    lines.append("ERROR: \(msg)")
                }
                let name = (info.bundleIdentifier ?? info.name).replacingOccurrences(of: "/", with: "_")
                try? lines.joined(separator: "\n").write(to: dir.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
            }

            // Actions
            func target(_ spec: String) -> (AppInfo, [Int], String)? {
                let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2, let running = NSRunningApplication.runningApplications(withBundleIdentifier: parts[0]).first else { return nil }
                let indices = parts[1].split(separator: ".").compactMap { Int($0) }
                return (AppInfo(running: running), indices, parts[1])
            }
            func node(for info: AppInfo, at indices: [Int]) -> MenuNode? {
                guard let roots = try? source.loadMenuBar(for: info, progress: { _ in }) else { return nil }
                return roots.node(at: indices)
            }
            if let spec = env["SUPERBAR_DIAG_PRESS"], let (info, indices, _) = target(spec) {
                if let n = node(for: info, at: indices) {
                    do { try source.press(n, in: info); summary.append("press \(info.name) \(n.breadcrumb): ok") }
                    catch { summary.append("press \(info.name) \(n.breadcrumb): ERROR \((error as? MenuSourceError)?.message ?? error.localizedDescription)") }
                } else { summary.append("press: no node at \(indices)") }
            }
            if let spec = env["SUPERBAR_DIAG_REVEAL"], let (info, indices, _) = target(spec) {
                if let n = node(for: info, at: indices) {
                    do {
                        try source.reveal(n, in: info)
                        summary.append("reveal \(info.name) \(n.breadcrumb): ok (menu opened)")
                        Thread.sleep(forTimeInterval: 1.2)
                        AXMenuSource.pressEscape(); Thread.sleep(forTimeInterval: 0.2); AXMenuSource.pressEscape()
                    } catch { summary.append("reveal \(info.name) \(n.breadcrumb): ERROR \((error as? MenuSourceError)?.message ?? error.localizedDescription)") }
                } else { summary.append("reveal: no node at \(indices)") }
            }
            if let spec = env["SUPERBAR_DIAG_HELP"], let (info, _, q) = target(spec) {
                do {
                    try source.searchHelpMenu(query: q, in: info)
                    summary.append("help search \(info.name) '\(q)': ok")
                    Thread.sleep(forTimeInterval: 1.5)
                    AXMenuSource.pressEscape(); Thread.sleep(forTimeInterval: 0.2); AXMenuSource.pressEscape()
                } catch { summary.append("help search \(info.name): ERROR \((error as? MenuSourceError)?.message ?? error.localizedDescription)") }
            }

            if let title = env["SUPERBAR_DIAG_E2E"] {
                summary.append(contentsOf: endToEnd(title: title, hotKey: hotKey))
            }

            try? summary.lines.joined(separator: "\n").write(to: dir.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8)
            try? "done".write(to: dir.appendingPathComponent("done"), atomically: true, encoding: .utf8)
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    // MARK: End-to-end against the installed instance

    /// Posts a key press. Session-level (HID tap) events reach the *active*
    /// application; to drive a non-activating panel owned by another process
    /// the events must be delivered to that process directly (`toPid`).
    private static func post(keyCode: CGKeyCode, flags: CGEventFlags = [], toPid pid: pid_t? = nil) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        down?.flags = flags; up?.flags = flags
        if let pid { down?.postToPid(pid) } else { down?.post(tap: .cghidEventTap) }
        usleep(30_000)
        if let pid { up?.postToPid(pid) } else { up?.post(tap: .cghidEventTap) }
    }

    private static func type(_ text: String, toPid pid: pid_t) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for scalar in text.utf16 {
            var chars = [UniChar(scalar)]
            if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                down.keyboardSetUnicodeString(stringLength: 1, unicodeString: &chars)
                down.postToPid(pid)
            }
            if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                up.keyboardSetUnicodeString(stringLength: 1, unicodeString: &chars)
                up.postToPid(pid)
            }
            usleep(15_000)
        }
    }

    private static func windowCount(of pid: pid_t) -> Int {
        let app = AXUIElementCreateApplication(pid)
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success else { return -1 }
        return (value as? [AnyObject])?.count ?? 0
    }

    /// Describes the focused element of a process: role, value and window title.
    private static func focusDescription(of pid: pid_t) -> String {
        let app = AXUIElementCreateApplication(pid)
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success, let el = focused else { return "no focused element" }
        let element = el as! AXUIElement
        func attr(_ name: String) -> String {
            var v: AnyObject?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &v) == .success, let v else { return "-" }
            return String(describing: v)
        }
        return "role=\(attr(kAXRoleAttribute)) value=\(attr(kAXValueAttribute))"
    }

    private static func endToEnd(title: String, hotKey: HotKey) -> [String] {
        var out: [String] = []
        let me = ProcessInfo.processInfo.processIdentifier
        guard let target = NSRunningApplication.runningApplications(withBundleIdentifier: "com.manuader.SuperBar").first(where: { $0.processIdentifier != me }) else {
            return ["e2e: no other SuperBar instance is running"]
        }
        out.append("e2e: target instance pid \(target.processIdentifier) at \(target.bundleURL?.path ?? "?")")
        // Bring Finder to the front so it owns the menu bar.
        let finderURL = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        let group = DispatchGroup(); group.enter()
        NSWorkspace.shared.openApplication(at: finderURL, configuration: config) { _, _ in group.leave() }
        group.wait()
        Thread.sleep(forTimeInterval: 0.8)
        out.append("e2e: frontmost = \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
        var flags: CGEventFlags = []
        if hotKey.carbonModifiers & 4096 != 0 { flags.insert(.maskControl) }
        if hotKey.carbonModifiers & 2048 != 0 { flags.insert(.maskAlternate) }
        if hotKey.carbonModifiers & 512 != 0 { flags.insert(.maskShift) }
        if hotKey.carbonModifiers & 256 != 0 { flags.insert(.maskCommand) }
        // Reset: make sure no palette is showing (a previous run may have left it open).
        var before = windowCount(of: target.processIdentifier)
        if before > 0 {
            post(keyCode: CGKeyCode(hotKey.keyCode), flags: flags); Thread.sleep(forTimeInterval: 0.6)
            before = windowCount(of: target.processIdentifier)
            if before > 0 { post(keyCode: 53); Thread.sleep(forTimeInterval: 0.3); post(keyCode: 53); Thread.sleep(forTimeInterval: 0.5); before = windowCount(of: target.processIdentifier) }
            out.append("e2e: reset → windows \(before)")
        }
        // Global hot key.
        post(keyCode: CGKeyCode(hotKey.keyCode), flags: flags)
        Thread.sleep(forTimeInterval: 0.8)
        var after = windowCount(of: target.processIdentifier)
        out.append("e2e: windows before/after hot key: \(before)/\(after)")
        if after <= before {
            // Fallback path: `open -ga SuperBar` (reopen) toggles the palette.
            let cfg = NSWorkspace.OpenConfiguration(); cfg.activates = false
            let g = DispatchGroup(); g.enter()
            NSWorkspace.shared.openApplication(at: target.bundleURL!, configuration: cfg) { _, _ in g.leave() }
            g.wait()
            Thread.sleep(forTimeInterval: 0.8)
            after = windowCount(of: target.processIdentifier)
            out.append("e2e: windows after reopen fallback: \(after) (hot key did not open the palette)")
        }
        guard after > before else {
            out.append("e2e: ABORT — palette not visible, not typing")
            return out
        }
        out.append("e2e: focus before typing: \(focusDescription(of: target.processIdentifier)); frontmost = \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
        type(title, toPid: target.processIdentifier)
        Thread.sleep(forTimeInterval: 0.8)
        out.append("e2e: focus after typing: \(focusDescription(of: target.processIdentifier))")
        post(keyCode: 36, toPid: target.processIdentifier) // Return
        Thread.sleep(forTimeInterval: 2.0)
        let closed = windowCount(of: target.processIdentifier)
        out.append("e2e: windows after Return: \(closed)")
        let recents = RecentsStore.defaultFileURL()
        let text = (try? String(contentsOf: recents, encoding: .utf8)) ?? ""
        out.append(text.localizedCaseInsensitiveContains(title) ? "e2e: recents.json records “\(title)” ✓" : "e2e: recents.json does NOT contain “\(title)” ✗")
        return out
    }
}
