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
