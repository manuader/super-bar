import AppKit
import SuperBarKit

/// DEBUG-only visual verification: renders the palette from fixture data to a
/// PNG without needing Accessibility permission or a human at the keyboard.
///
/// Environment: `SUPERBAR_SNAPSHOT=/path/out.png` (enables the harness),
/// `SUPERBAR_QUERY`, `SUPERBAR_MODE=list|outline`, `SUPERBAR_SCOPE=Format`,
/// `SUPERBAR_APPEARANCE=light|dark`, `SUPERBAR_THEME=<theme id>`,
/// `SUPERBAR_STATE=permission|busy|loading|norules`.
enum SnapshotHarness {
    static var isEnabled: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["SUPERBAR_SNAPSHOT"] != nil
        #else
        return false
        #endif
    }

    @MainActor
    static func run(app: AppDelegate) {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        guard let output = env["SUPERBAR_SNAPSHOT"] else { return }
        let prefs = app.preferences
        let dark = env["SUPERBAR_APPEARANCE"] == "dark"
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        if let themeID = env["SUPERBAR_THEME"] {
            if dark { prefs.selectedDarkTheme = themeID } else { prefs.selectedLightTheme = themeID }
        } else {
            prefs.selectedLightTheme = Theme.systemLightID
            prefs.selectedDarkTheme = Theme.systemDarkID
        }
        prefs.browsingMode = env["SUPERBAR_MODE"] == "outline" ? .outline : .list
        prefs.clearSearchStateImmediately = true

        if let tabName = env["SUPERBAR_SNAPSHOT_SETTINGS"] {
            renderSettings(app: app, tab: SettingsTab.allCases.first { $0.title.lowercased() == tabName.lowercased() } ?? .general, output: output)
            return
        }
        let palette = app.palette
        if let realID = env["SUPERBAR_REAL_APP"] {
            renderRealApp(app: app, bundleID: realID, env: env, output: output)
            return
        }
        // Seed recents so the root screen shows the Recents section.
        let info = AppInfo(pid: 4242, bundleIdentifier: "com.apple.Notes", name: "Notes")
        app.recents.clear()
        app.recents.record(appKey: info.storageKey, titlePath: ["Window", "Keep on Top"], indexPath: [6, 6])
        app.recents.record(appKey: info.storageKey, titlePath: ["Format", "Font", "Bold"], indexPath: [4, 18, 1])

        palette.session.isTrusted = env["SUPERBAR_STATE"] != "permission"
        palette.session.app = info
        palette.session.scripts = [
            ScriptItem(url: URL(fileURLWithPath: "/tmp/Duplicate Tab.sh"), title: "Duplicate Tab", scope: nil),
            ScriptItem(url: URL(fileURLWithPath: "/tmp/Invert Selection.applescript"), title: "Invert Selection", scope: nil),
        ]
        var roots = FixtureMenuSource.notesLike()
        switch env["SUPERBAR_STATE"] {
        case "busy": roots = []; palette.session.loadState = .failed(.applicationBusy)
        case "loading": roots = []; palette.session.loadState = .loading
        case "norules": roots = []; palette.session.rulesRemovedEverything = true; palette.session.loadState = .ready
        default: palette.session.loadState = .ready
        }
        palette.session.roots = roots
        palette.session.mode = prefs.browsingMode
        if let scopeTitle = env["SUPERBAR_SCOPE"], let node = roots.flattened.first(where: { $0.title == scopeTitle && $0.isContainer }) {
            palette.session.scope = node
        }
        palette.session.query = env["SUPERBAR_QUERY"] ?? ""
        palette.searchField.stringValue = palette.session.query
        palette.showForSnapshot(icon: NSWorkspace.shared.icon(forFile: "/System/Applications/Notes.app"))

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard let view = palette.panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(2) }
            if env["SUPERBAR_DEBUG"] != nil, let scroll = palette.outlineView.enclosingScrollView {
                var rows: CGFloat = 0
                for r in 0..<palette.outlineView.numberOfRows { rows += palette.outlineView.rect(ofRow: r).height }
                print("doc height:", palette.outlineView.frame.height, "sum rows:", rows, "clip:", scroll.contentView.bounds.height, "scroll origin:", scroll.contentView.bounds.origin.y, "panel:", palette.panel.frame.height)
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: output))
                print("snapshot written to \(output) (\(Int(view.bounds.width))×\(Int(view.bounds.height)))")
            }
            exit(0)
        }
        #endif
    }

    #if DEBUG
    /// Renders the palette with the real menu bar of a running app (needs Accessibility).
    @MainActor
    private static func renderRealApp(app: AppDelegate, bundleID: String, env: [String: String], output: String) {
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { print("app not running: \(bundleID)"); exit(3) }
        let info = AppInfo(running: running)
        let palette = app.palette
        let source = app.menuSource
        DispatchQueue.global(qos: .userInitiated).async {
            let start = Date()
            let result = Result { try source.loadMenuBar(for: info) { _ in } }
            let elapsed = Date().timeIntervalSince(start)
            DispatchQueue.main.async {
                switch result {
                case .success(let roots):
                    let outcome = RuleEngine.apply(app.preferences.rules, to: roots, app: info)
                    palette.session.roots = outcome.roots
                    palette.session.loadState = .ready
                    print("loaded \(roots.flattened.count) nodes from \(info.name) in \(Int(elapsed * 1000)) ms")
                case .failure(let error):
                    palette.session.roots = []
                    palette.session.loadState = .failed((error as? MenuSourceError) ?? .actionFailed(error.localizedDescription))
                    print("load failed: \(error)")
                }
                palette.session.isTrusted = source.isTrusted
                palette.session.app = info
                palette.session.scripts = []
                palette.session.mode = env["SUPERBAR_MODE"] == "outline" ? .outline : .list
                if let scopeTitle = env["SUPERBAR_SCOPE"], let node = palette.session.roots.flattened.first(where: { $0.title == scopeTitle && $0.isContainer }) {
                    palette.session.scope = node
                }
                palette.session.query = env["SUPERBAR_QUERY"] ?? ""
                palette.searchField.stringValue = palette.session.query
                palette.showForSnapshot(icon: running.icon)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    guard let view = palette.panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(2) }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    if let data = rep.representation(using: .png, properties: [:]) {
                        try? data.write(to: URL(fileURLWithPath: output))
                        print("snapshot written to \(output)")
                    }
                    exit(0)
                }
            }
        }
    }

    @MainActor
    private static func renderSettings(app: AppDelegate, tab: SettingsTab, output: String) {
        app.settings.show(tab: tab)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard let window = app.settings.window, let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(2) }
            view.cacheDisplay(in: view.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: output))
                print("settings snapshot written to \(output) (\(Int(view.bounds.width))×\(Int(view.bounds.height)))")
            }
            exit(0)
        }
    }
    #endif
}
