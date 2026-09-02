import AppKit
@preconcurrency import UserNotifications
import SuperBarKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let preferences: Preferences
    let menuSource: MenuSource
    let recents: RecentsStore
    let scriptsRoot = ScriptsLibrary.defaultRoot(bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.manuader.SuperBar")
    @Published private(set) var scripts: [ScriptItem] = []
    @Published private(set) var hotKeyRegistrationError: String?
    private var scriptsWatcher: ScriptsWatcher?

    lazy var menuCache = MenuCache(source: menuSource)
    lazy var activator = Activator(source: menuSource, recents: recents)
    lazy var palette = PaletteController(app: self)
    lazy var settings = SettingsWindowController(app: self)
    lazy var hotKeys = HotKeyCenter()
    lazy var statusItem = StatusItemController(app: self)
    private var permissionWindow: PermissionWindowController?

    /// The application that was frontmost before SuperBar's own windows.
    private(set) var lastFrontmostApp: NSRunningApplication?
    /// Most recently activated apps first (for the app picker).
    private var activationOrder: [pid_t] = []
    private var observers: [Any] = []

    static var isRunningTests: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }

    override init() {
        let env = ProcessInfo.processInfo.environment
        if (SnapshotHarness.isEnabled && env["SUPERBAR_REAL_APP"] == nil) || env["SUPERBAR_FIXTURE"] == "1" {
            menuSource = FixtureMenuSource(roots: FixtureMenuSource.notesLike())
        } else {
            menuSource = AXMenuSource()
        }
        if SnapshotHarness.isEnabled || AppDelegate.isRunningTests || Diagnostics.isEnabled {
            // Never touch the real preferences or recents from the harness/tests/diagnostics
            // (a second instance saving its stale copy would clobber the installed app's file).
            let suite = UserDefaults(suiteName: "com.manuader.SuperBar.harness")!
            suite.removePersistentDomain(forName: "com.manuader.SuperBar.harness")
            preferences = Preferences(defaults: suite)
            recents = RecentsStore()
        } else {
            preferences = Preferences.shared
            recents = RecentsStore(fileURL: RecentsStore.defaultFileURL())
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        if AppDelegate.isRunningTests { return }
        if Diagnostics.isEnabled { Diagnostics.run(app: self); return }
        enforceSingleInstance()
        reloadScripts()
        scriptsWatcher = ScriptsWatcher(root: scriptsRoot) { [weak self] in self?.reloadScripts() }
        scriptsWatcher?.start()

        registerHotKey()
        statusItem.isVisible = preferences.showMenuBarExtra
        observeWorkspace()
        observePreferences()

        if SnapshotHarness.isEnabled {
            SnapshotHarness.run(app: self)
            return
        }
        if !menuSource.isTrusted {
            showPermissionWindow()
        } else if !preferences.didOnboard {
            preferences.didOnboard = true
            palette.show()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // `open -ga SuperBar` toggles the palette without stealing focus.
        palette.toggle()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        recents.saveNow()
        hotKeys.unregisterAll()
    }

    // MARK: Wiring

    /// A minimal main menu so that ⌘C/⌘V/⌘Z work inside the search field
    /// (accessory apps have no menu bar but key equivalents still route here).
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettingsAction), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit SuperBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.mainMenu = main
    }

    @objc private func showSettingsAction() { showSettings() }

    private func enforceSingleInstance() {
        let mine = Bundle.main.bundleIdentifier ?? ""
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: mine).filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !others.isEmpty && !SnapshotHarness.isEnabled && !Diagnostics.isEnabled {
            others.first?.activate(options: [])
            NSApp.terminate(nil)
        }
    }

    func reloadScripts() {
        scripts = ScriptsLibrary.scan(root: scriptsRoot)
        palette.scriptsDidChange()
    }

    func registerHotKey() {
        hotKeys.unregisterAll()
        hotKeyRegistrationError = nil
        guard preferences.hotKeyEnabled else { return }
        if let front = NSWorkspace.shared.frontmostApplication, isExcluded(front) { return }
        do {
            try hotKeys.register(preferences.hotKey) { [weak self] in
                Log.hotkey.notice("hot key fired")
                self?.palette.toggle()
            }
            Log.hotkey.notice("registered \(self.preferences.hotKey.display, privacy: .public)")
        } catch {
            hotKeyRegistrationError = error.localizedDescription
            Log.hotkey.error("registration failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Temporarily releases the hot key (while the recorder captures a new one).
    func suspendHotKey(_ suspended: Bool) {
        if suspended { hotKeys.unregisterAll() } else { registerHotKey() }
    }

    func isExcluded(_ app: NSRunningApplication) -> Bool {
        guard let id = app.bundleIdentifier else { return false }
        return preferences.globalShortcutExcludedApps.contains(id)
    }

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated {
                if app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                    self.lastFrontmostApp = app
                    self.activationOrder.removeAll { $0 == app.processIdentifier }
                    self.activationOrder.insert(app.processIdentifier, at: 0)
                    self.palette.frontmostAppChanged(app)
                }
                if self.preferences.hotKeyEnabled {
                    if self.isExcluded(app) { self.hotKeys.unregisterAll() } else if !self.hotKeys.isRegistered { self.registerHotKey() }
                }
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated {
                self.menuCache.forget(pid: app.processIdentifier)
                (self.menuSource as? AXMenuSource)?.forget(pid: app.processIdentifier)
            }
        })
        lastFrontmostApp = NSWorkspace.shared.frontmostApplication
    }

    private func observePreferences() {
        observers.append(NotificationCenter.default.addObserver(forName: Preferences.didChangeNotification, object: preferences, queue: .main) { [weak self] note in
            guard let self, let key = note.userInfo?["key"] as? String else { return }
            MainActor.assumeIsolated {
                switch key {
                case "hotKey", "hotKeyEnabled", "globalShortcutExcludedApps": self.registerHotKey()
                case "showMenuBarExtra": self.statusItem.isVisible = self.preferences.showMenuBarExtra
                case "menuBarRules": self.menuCache.invalidateAll(); self.palette.preferencesDidChange(key: key)
                case "settingsWindowFloats": self.settings.updateLevel()
                case "windowOriginXFraction", "windowOriginYFraction", "didOnboard", "browsingMode": break
                default: self.palette.preferencesDidChange(key: key)
                }
            }
        })
    }

    // MARK: Windows

    func showPermissionWindow() {
        if permissionWindow == nil { permissionWindow = PermissionWindowController(app: self) }
        permissionWindow?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showSettings(tab: SettingsTab? = nil) {
        settings.show(tab: tab)
    }

    /// Regular apps with a menu bar, most recently used first, then by name.
    func runningAppsForPicker() -> [RunningApp] {
        let me = ProcessInfo.processInfo.processIdentifier
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != me }
        func rank(_ app: NSRunningApplication) -> Int { activationOrder.firstIndex(of: app.processIdentifier) ?? Int.max }
        return apps.sorted { a, b in
            let ra = rank(a), rb = rank(b)
            if ra != rb { return ra < rb }
            return (a.localizedName ?? "").localizedCaseInsensitiveCompare(b.localizedName ?? "") == .orderedAscending
        }.map { RunningApp($0, isFrontmost: $0.processIdentifier == front) }
    }

    /// Target application for the palette: the frontmost app that is not us.
    var targetApplication: NSRunningApplication? {
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            return front
        }
        return lastFrontmostApp
    }

    func notify(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        // Ask lazily, the first time something actually needs to be reported.
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
