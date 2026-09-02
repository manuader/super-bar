import AppKit
import SuperBarKit

/// Owns the palette window: showing/hiding, positioning, theming and the data
/// flow from the menu cache into the outline view.
@MainActor
final class PaletteController: NSObject, NSWindowDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate {
    unowned let app: AppDelegate
    let session: SearchSession
    let panel: PalettePanel

    // Views
    private let backgroundView = NSView()
    private var effectView: NSVisualEffectView?
    private let headerView = NSView()
    private let appIconView = NSImageView()
    private let appIconButton = NSButton()
    let searchField = PaletteSearchField()
    private let clearButton = NSButton()
    private let modeControl = NSSegmentedControl()
    private let optionsButton = NSButton()
    private let scopeBar = ScopeBarView()
    private let topSeparator = SeparatorView()
    private let scrollView = NSScrollView()
    let outlineView = PaletteOutlineView()
    private let bottomSeparator = SeparatorView()
    private let footerView = NSView()
    private let breadcrumbLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")

    // State
    private(set) var content = PaletteContent(rows: [], expanded: [], preferredSelection: nil, itemCount: 0, isSearching: false)
    private var rowsByID: [String: PaletteRow] = [:]
    private var expanded: Set<String> = []
    private var theme: ResolvedTheme
    private var style: RowStyle
    private var currentApp: NSRunningApplication?
    private var isProgrammaticMove = false
    private var isAnimatingFrame = false
    /// Icon of the app the palette acts on; the header shows a neutral glyph while picking an app.
    private var currentAppIcon: NSImage?
    private var lastRawRoots: [MenuNode]?
    private var isVisible: Bool { panel.isVisible }
    private var pendingSelectionID: String?
    private var lastLoadedPID: Int32?

    init(app: AppDelegate) {
        self.app = app
        session = SearchSession(preferences: app.preferences, recents: app.recents)
        let width = CGFloat(app.preferences.windowWidth)
        panel = PalettePanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 400))
        let dark = NSApp.effectiveAppearance.isDark
        theme = ResolvedTheme.current(preferences: app.preferences, isDarkAppearance: dark)
        style = RowStyle(theme: theme, textSizeDelta: CGFloat(app.preferences.rowTextSize.pointDelta), showCountBadge: app.preferences.showCountBadge, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        super.init()
        buildViews()
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.handleEscape() }
        panel.onKeyEquivalent = { [weak self] event in self?.handleKeyEquivalent(event) ?? false }
        app.menuCache.onUpdate = { [weak self] info, entry in self?.cacheDidUpdate(info, entry) }
        applyTheme()
        NSApp.observeAppearance { [weak self] in self?.appearanceChanged() }
    }

    // MARK: Show / hide

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show() {
        let target = app.targetApplication
        Log.palette.notice("show for \(target?.localizedName ?? "nil", privacy: .public) (pid \(target?.processIdentifier ?? 0))")
        let appChanged = target?.processIdentifier != currentApp?.processIdentifier
        currentApp = target
        session.isTrusted = app.menuSource.isTrusted
        if app.preferences.clearSearchStateImmediately || appChanged {
            session.resetSearchState()
        }
        session.mode = app.preferences.browsingMode
        session.scripts = ScriptsLibrary.items(for: target?.bundleIdentifier, in: app.scripts)
        currentAppIcon = target?.icon ?? NSImage(named: NSImage.applicationIconName)
        if let target {
            let info = AppInfo(running: target)
            session.app = info
            let entry = app.menuCache.load(app: info)
            adopt(entry, for: info)
        } else {
            session.app = nil
            session.roots = []
            session.loadState = .failed(.noMenuBar)
        }
        searchField.stringValue = session.query
        updateClearButton()
        modeControl.selectedSegment = session.mode == .list ? 0 : 1
        if session.openQuery != nil { updateFileResults() }
        reload(selectPreferred: true)
        position()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
        searchField.currentEditor()?.selectAll(nil)
    }

    func hide(reason: String = #function) {
        guard isVisible else { return }
        Log.palette.notice("hide (\(reason, privacy: .public))")
        panel.orderOut(nil)
    }

    /// Used by the snapshot harness: session state is pre-filled by the caller.
    func showForSnapshot(icon: NSImage?) {
        currentAppIcon = icon
        backgroundView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        updateClearButton()
        modeControl.selectedSegment = session.mode == .list ? 0 : 1
        reload(selectPreferred: true)
        position()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
        searchField.currentEditor()?.selectedRange = NSRange(location: searchField.stringValue.utf16.count, length: 0)
        if ProcessInfo.processInfo.environment["SUPERBAR_DEBUG"] != nil {
            print("preferred:", content.preferredSelection ?? "nil", "selected:", selectedRow()?.id ?? "nil", "rows:", outlineView.numberOfRows)
        }
    }

    private func handleEscape() {
        if session.pendingFile != nil {
            cancelHandlerPicker()
        } else if !searchField.stringValue.isEmpty {
            setQuery("")
        } else if session.isPickingApp {
            exitAppPicker()
        } else {
            hide()
        }
    }

    func frontmostAppChanged(_ running: NSRunningApplication) {
        // While visible, the panel follows the front app (e.g. the user ⌘-tabbed).
        // Agents and system prompts are ignored: a permission dialog taking
        // focus must not retarget the palette or discard what was typed.
        guard isVisible, running.activationPolicy == .regular,
              running.processIdentifier != currentApp?.processIdentifier else { return }
        // The open command and the pickers are not tied to the target app.
        guard session.openQuery == nil, !session.isPickingApp, session.pendingFile == nil else { return }
        show()
    }

    func scriptsDidChange() {
        guard isVisible, !SnapshotHarness.isEnabled else { return }
        session.scripts = ScriptsLibrary.items(for: currentApp?.bundleIdentifier, in: app.scripts)
        reload(selectPreferred: false)
    }

    /// Applies only what the changed preference affects; a full reload on
    /// every write (window geometry included) used to cause visible stalls.
    func preferencesDidChange(key: String? = nil) {
        let prefs = app.preferences
        switch key {
        case "windowWidth":
            guard abs(panel.frame.width - CGFloat(prefs.windowWidth)) > 1 else { return }
            var frame = panel.frame
            frame.size.width = CGFloat(prefs.windowWidth)
            isProgrammaticMove = true
            panel.setFrame(frame, display: true)
            isProgrammaticMove = false
            if isVisible { position() }
        case "selectedLightTheme", "selectedDarkTheme", "customThemes", nil:
            refreshStyle()
            applyTheme()
        case "rowTextSize", "showSubtitles", "showCountBadge", "recentsLimit", "menuBarRules", "preferredScreen":
            refreshStyle()
            if isVisible { reload(selectPreferred: false) }
        default:
            break
        }
    }

    private func refreshStyle() {
        let prefs = app.preferences
        theme = ResolvedTheme.current(preferences: prefs, isDarkAppearance: NSApp.effectiveAppearance.isDark)
        style = RowStyle(theme: theme, textSizeDelta: CGFloat(prefs.rowTextSize.pointDelta), showCountBadge: prefs.showCountBadge, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    private func appearanceChanged() {
        refreshStyle()
        applyTheme()
    }

    // MARK: Data

    private func adopt(_ entry: MenuCache.Entry, for info: AppInfo) {
        lastLoadedPID = info.pid
        let rawRoots = entry.snapshot?.roots ?? entry.partialRoots
        lastRawRoots = rawRoots
        let outcome = RuleEngine.apply(app.preferences.rules, to: rawRoots, app: info)
        session.roots = outcome.roots
        session.rulesRemovedEverything = outcome.removedEverything
        session.loadState = entry.state
        if let scope = session.scope, session.roots.node(at: scope.indexPath) == nil { session.scope = nil }
        else if let scope = session.scope, let fresh = session.roots.node(at: scope.indexPath) { session.scope = fresh }
    }

    private func cacheDidUpdate(_ info: AppInfo, _ entry: MenuCache.Entry) {
        guard isVisible, info.pid == currentApp?.processIdentifier else { return }
        let hadRows = !session.roots.isEmpty
        // A background refresh that produced the same tree needs no work at all.
        if hadRows, entry.state == .ready, let fresh = entry.snapshot?.roots, fresh == lastRawRoots { return }
        adopt(entry, for: info)
        reload(selectPreferred: !hadRows)
    }

    func retry() {
        guard let info = session.app else { return }
        session.loadState = .loading
        app.menuCache.load(app: info, force: true)
        reload(selectPreferred: false)
    }

    // MARK: Reload

    func reload(selectPreferred: Bool) {
        let previous = selectedRow()?.id
        content = session.build()
        let placeholder: String
        if session.pendingFile != nil { placeholder = "Choose an app" }
        else if session.isPickingApp { placeholder = "Choose an app" }
        else { placeholder = "Search" }
        if searchField.placeholderAttributedString?.string != placeholder {
            searchField.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [.foregroundColor: theme.secondaryText, .font: searchField.font!])
        }
        updateHeaderIcon()
        rowsByID = [:]
        func index(_ row: PaletteRow) { rowsByID[row.id] = row; row.children.forEach(index) }
        content.rows.forEach(index)
        expanded = content.expanded
        outlineView.reloadData()
        expandRows(content.rows)
        assignQuickIndices()
        let target = (selectPreferred ? content.preferredSelection : nil) ?? previous.flatMap { rowsByID[$0] != nil && isRowVisible($0) ? $0 : nil } ?? content.preferredSelection ?? content.firstSelectable()?.id
        if let target, let row = rowsByID[target] { select(row, scroll: true) } else { outlineView.deselectAll(nil) }
        updateFooter()
        updateScopeBar()
        fitHeight()
    }

    /// Expands parents before children (a Set has no order).
    private func expandRows(_ rows: [PaletteRow]) {
        for row in rows where row.isExpandable && expanded.contains(row.id) {
            outlineView.expandItem(row)
            expandRows(row.children)
        }
    }

    /// The app icon while acting on an app; a neutral "apps" glyph while choosing one.
    private func updateHeaderIcon() {
        if let file = session.pendingFile {
            appIconView.image = FileIcons.icon(for: file)
            appIconView.contentTintColor = nil
            appIconButton.toolTip = "Choose which app opens this kind of file"
        } else if session.openQuery != nil {
            appIconView.image = .symbol("folder.fill", pointSize: 20, weight: .medium)
            appIconView.contentTintColor = theme.accent
            appIconButton.toolTip = "Open a folder or file"
        } else if session.isPickingApp {
            appIconView.image = .symbol("square.grid.2x2.fill", pointSize: 20, weight: .medium)
            appIconView.contentTintColor = theme.secondaryText
            appIconButton.toolTip = "Back to the current app (Esc)"
        } else {
            appIconView.image = currentAppIcon
            appIconView.contentTintColor = nil
            appIconButton.toolTip = "Choose the app to act on (⌫ with an empty search)"
        }
    }

    private func isRowVisible(_ id: String) -> Bool {
        guard let row = rowsByID[id] else { return false }
        return outlineView.row(forItem: row) >= 0
    }

    private func assignQuickIndices() {
        var n = 1
        for r in 0..<outlineView.numberOfRows {
            guard let row = outlineView.item(atRow: r) as? PaletteRow else { continue }
            let newIndex: Int? = (row.isSelectable && n <= 9) ? n : nil
            if newIndex != nil { n += 1 }
            let changed = row.quickIndex != newIndex
            row.quickIndex = newIndex
            if changed, let cell = outlineView.view(atColumn: 0, row: r, makeIfNecessary: false) as? MenuRowView {
                cell.updateQuickIndex(newIndex)
            }
        }
    }

    // MARK: Selection helpers

    func selectedRow() -> PaletteRow? {
        let r = outlineView.selectedRow
        guard r >= 0 else { return nil }
        return outlineView.item(atRow: r) as? PaletteRow
    }

    private func select(_ row: PaletteRow, scroll: Bool) {
        let r = outlineView.row(forItem: row)
        guard r >= 0 else { return }
        outlineView.selectRowIndexes(IndexSet(integer: r), byExtendingSelection: false)
        if scroll { outlineView.scrollRowToVisible(r) }
    }

    private func moveSelection(by delta: Int) {
        let count = outlineView.numberOfRows
        guard count > 0 else { return }
        var r = outlineView.selectedRow
        if r < 0 { r = delta > 0 ? -1 : count }
        var next = r + delta
        while next >= 0 && next < count {
            if let row = outlineView.item(atRow: next) as? PaletteRow, row.isSelectable { break }
            next += delta > 0 ? 1 : -1
        }
        guard next >= 0 && next < count else { return }
        outlineView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        outlineView.scrollRowToVisible(next)
    }

    private func selectEdge(first: Bool) {
        let count = outlineView.numberOfRows
        let range = first ? Array(0..<count) : Array((0..<count).reversed())
        for r in range {
            if let row = outlineView.item(atRow: r) as? PaletteRow, row.isSelectable {
                outlineView.selectRowIndexes(IndexSet(integer: r), byExtendingSelection: false)
                outlineView.scrollRowToVisible(r)
                return
            }
        }
    }

    private func pageSelection(down: Bool) {
        let visible = Int(scrollView.contentView.bounds.height / PaletteMetrics.compactRowHeight)
        moveSelection(by: down ? max(1, visible - 1) : -max(1, visible - 1))
    }

    // MARK: Actions

    func activateSelection(reveal: Bool = false, openWith: Bool = false) {
        if let row = selectedRow() {
            activate(row, reveal: reveal, openWith: openWith)
        } else if let message = content.rows.first?.message, message.actionTitle != nil {
            perform(message.action)
        }
    }

    func activate(_ row: PaletteRow, reveal: Bool = false, openWith: Bool = false) {
        switch row.kind {
        case .command(let command):
            setQuery(command.keyword + " ")
        case .file(let entry):
            if entry.isDirectory {
                openFolder(entry)
            } else if let choice = app.preferences.fileTypeHandlers.choice(for: entry.path), !openWith {
                open(entry, with: choice)
            } else {
                askForHandler(entry)
            }
        case .handler(let handler):
            guard let file = session.pendingFile else { return }
            useHandler(handler, for: file)
        case .app(let picked):
            if let running = NSRunningApplication(processIdentifier: picked.pid) { switchTo(running) } else { NSSound.beep() }
        case .menu(let node):
            guard let info = session.app else { return }
            let activateFirst = targetNeedsActivation
            if reveal {
                hide()
                app.activator.reveal(node, app: info, running: activateFirst ? currentApp : nil) { [weak self] error in
                    guard let error else { return }
                    MainActor.assumeIsolated { self?.app.notify(title: "Couldn’t reveal “\(node.title)”", body: error.localizedDescription) }
                }
                return
            }
            if node.isContainer {
                if node.visibleChildren.isEmpty { NSSound.beep(); return }
                enterScope(node)
                return
            }
            hide()
            app.activator.press(node, app: info, running: currentApp, activateFirst: activateFirst) { [weak self] error in
                guard let error else { return }
                MainActor.assumeIsolated {
                    self?.app.notify(title: "Couldn’t select “\(node.title)”", body: (error as? MenuSourceError)?.message ?? error.localizedDescription)
                }
            }
        case .script(let script):
            hide()
            app.activator.run(script, app: session.app) { [weak self] result in
                guard !result.isSuccess else { return }
                let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                MainActor.assumeIsolated {
                    self?.app.notify(title: "“\(script.title)” failed (exit \(result.exitCode))", body: detail.isEmpty ? "The script exited with an error." : detail)
                }
            }
        case .message(let message):
            perform(message.action)
        default:
            break
        }
    }

    func perform(_ action: PaletteRow.Message.Action) {
        switch action {
        case .grantAccessibility:
            hide()
            _ = AXMenuSource.requestTrust()
            NSWorkspace.shared.open(AXMenuSource.accessibilitySettingsURL)
        case .retry:
            retry()
        case .searchHelp:
            searchHelpMenu()
        case .openRules:
            hide()
            app.showSettings(tab: .rules)
        case .rebuildIndex:
            app.fileIndex.rebuild()
            session.fileIndexState = app.fileIndex.state
            reload(selectPreferred: false)
        case .openFileSettings:
            hide()
            app.showSettings(tab: .open)
        case .none:
            break
        }
    }

    func searchHelpMenu() {
        guard let info = session.app else { return }
        let query = session.query
        let running = targetNeedsActivation ? currentApp : nil
        hide()
        app.activator.searchHelp(query: query, app: info, running: running) { [weak self] error in
            guard let error else { return }
            MainActor.assumeIsolated {
                self?.app.notify(title: "Couldn’t open the Help menu", body: (error as? MenuSourceError)?.message ?? error.localizedDescription)
            }
        }
    }

    // MARK: The `open` command

    /// Kicks off a background file search for the current `open` query.
    func updateFileResults() {
        guard let text = session.openQuery else { return }
        app.fileIndex.activate()
        session.fileIndexState = app.fileIndex.state
        app.fileIndex.search(text) { [weak self] query, results in
            guard let self, self.session.openQuery == query else { return }
            self.session.fileResults = results
            self.session.fileResultsQuery = query
            self.session.fileIndexState = self.app.fileIndex.state
            self.reload(selectPreferred: true)
        }
    }

    /// The index finished (re)building: refresh what is on screen.
    func fileIndexDidChange() {
        guard isVisible, session.openQuery != nil else { return }
        session.fileIndexState = app.fileIndex.state
        updateFileResults()
    }

    /// Asks which application should open this kind of file.
    private func askForHandler(_ entry: FileEntry) {
        session.pendingFile = entry
        session.handlerCandidates = app.opener.handlers(for: entry.url)
        reload(selectPreferred: true)
    }

    private func cancelHandlerPicker() {
        guard session.pendingFile != nil else { return }
        session.pendingFile = nil
        session.handlerCandidates = []
        reload(selectPreferred: true)
    }

    /// Remembers the choice for this file type and opens the file with it.
    private func useHandler(_ handler: AppHandler, for entry: FileEntry) {
        if handler.isBrowse {
            browseForApplication(entry)
            return
        }
        var handlers = app.preferences.fileTypeHandlers
        handlers.set(handler.choice ?? .systemDefault, for: entry.path)
        app.preferences.fileTypeHandlers = handlers
        session.pendingFile = nil
        session.handlerCandidates = []
        open(entry, with: handler.choice)
    }

    /// "Choose Another App…": a standard open panel restricted to applications.
    private func browseForApplication(_ entry: FileEntry) {
        hide(reason: "browse for app")
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the application that should open \(FileTypeHandlers.describe(FileTypeHandlers.key(for: entry.path)))."
        guard panel.runModal() == .OK, let url = panel.url else {
            session.pendingFile = nil
            session.handlerCandidates = []
            return
        }
        let handler = AppHandler(url: url, isSystemDefault: false)
        var handlers = app.preferences.fileTypeHandlers
        handlers.set(handler.choice ?? .systemDefault, for: entry.path)
        app.preferences.fileTypeHandlers = handlers
        session.pendingFile = nil
        session.handlerCandidates = []
        open(entry, with: handler.choice)
    }

    private func open(_ entry: FileEntry, with choice: FileHandlerChoice?) {
        hide(reason: "open file")
        app.fileIndex.record(entry)
        app.opener.openFile(entry.url, choice: choice) { [weak self] error in
            guard let error else { return }
            self?.app.notify(title: "Couldn’t open “\(entry.name)”", body: error.localizedDescription)
        }
    }

    private func openFolder(_ entry: FileEntry) {
        hide(reason: "open folder")
        app.fileIndex.record(entry)
        app.opener.openFolder(entry.url, behavior: app.preferences.folderOpenBehavior) { [weak self] error in
            guard let error else { return }
            self?.app.notify(title: "Opened “\(entry.name)”", body: error.localizedDescription)
        }
    }

    // MARK: App picker

    @objc private func appIconClicked() { toggleAppPicker() }

    func toggleAppPicker() {
        if session.isPickingApp { exitAppPicker() } else { enterAppPicker() }
    }

    func enterAppPicker() {
        session.runningApps = app.runningAppsForPicker()
        session.isPickingApp = true
        session.scope = nil
        setQuery("")
    }

    func exitAppPicker() {
        guard session.isPickingApp else { return }
        session.isPickingApp = false
        setQuery("")
    }

    /// Points the palette at another running application.
    func switchTo(_ running: NSRunningApplication) {
        Log.palette.notice("switch to \(running.localizedName ?? "?", privacy: .public) (pid \(running.processIdentifier))")
        currentApp = running
        session.isPickingApp = false
        session.resetSearchState()
        currentAppIcon = running.icon ?? NSImage(named: NSImage.applicationIconName)
        let info = AppInfo(running: running)
        session.app = info
        session.scripts = ScriptsLibrary.items(for: running.bundleIdentifier, in: app.scripts)
        let entry = app.menuCache.load(app: info)
        adopt(entry, for: info)
        setQuery("")
    }

    /// True when the palette acts on an app other than the frontmost one, so
    /// actions must bring it forward first (background apps disable items).
    private var targetNeedsActivation: Bool {
        guard let current = currentApp else { return false }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier != current.processIdentifier
    }

    func enterScope(_ node: MenuNode) {
        session.scope = node
        setQuery("")
    }

    func exitScope() {
        guard session.scope != nil else { return }
        session.scope = nil
        setQuery("")
    }

    func setMode(_ mode: BrowsingMode) {
        guard mode != session.mode else { return }
        session.mode = mode
        app.preferences.browsingMode = mode
        modeControl.selectedSegment = mode == .list ? 0 : 1
        reload(selectPreferred: true)
    }

    private func setQuery(_ text: String) {
        searchField.stringValue = text
        session.query = text
        updateClearButton()
        reload(selectPreferred: true)
    }

    private func toggleExpansion(expand: Bool, recursive: Bool) {
        guard let row = selectedRow() else { return }
        if session.mode == .list {
            // Flat list: → enters a container's scope, ← leaves the current scope.
            if expand, let node = row.menuNode, node.isContainer {
                if node.visibleChildren.isEmpty { NSSound.beep() } else { enterScope(node) }
            } else if !expand {
                exitScope()
            }
            return
        }
        let target: NSOutlineView = style.reduceMotion ? outlineView : outlineView.animator()
        if expand {
            if row.isExpandable {
                target.expandItem(row, expandChildren: recursive)
                expanded.insert(row.id)
                if recursive { row.children.forEach(markExpanded) }
                if !content.isSearching { session.userExpanded.insert(row.id); if recursive { row.children.forEach { session.userExpanded.insert($0.id) } } }
            }
        } else {
            if row.isExpandable && outlineView.isItemExpanded(row) {
                target.collapseItem(row, collapseChildren: recursive)
                expanded.remove(row.id)
                session.userExpanded.remove(row.id)
            } else if let parent = row.parent, parent.isSelectable {
                select(parent, scroll: true)
            }
        }
        assignQuickIndices()
        fitHeight()
    }

    private func markExpanded(_ row: PaletteRow) {
        if row.isExpandable { expanded.insert(row.id); row.children.forEach(markExpanded) }
    }

    func quickSelect(_ n: Int) {
        for r in 0..<outlineView.numberOfRows {
            if let row = outlineView.item(atRow: r) as? PaletteRow, row.quickIndex == n {
                select(row, scroll: false)
                activate(row)
                return
            }
        }
    }

    func centerWindow() {
        app.preferences.resetWindowPosition()
        position()
    }

    // MARK: Positioning

    private func targetScreen() -> NSScreen {
        switch app.preferences.preferredScreen {
        case .withMouse:
            let mouse = NSEvent.mouseLocation
            return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        case .withKeyboardFocus:
            if let window = NSApp.keyWindow, let screen = window.screen { return screen }
            return NSScreen.main ?? NSScreen.screens[0]
        case .main:
            return NSScreen.screens.first ?? NSScreen.main!
        }
    }

    private func position() {
        let screen = targetScreen()
        let visible = screen.visibleFrame
        let prefs = app.preferences
        var frame = panel.frame
        frame.size.width = min(max(CGFloat(prefs.windowWidth), panel.minSize.width), visible.width - 40)
        frame.origin.x = visible.minX + (visible.width - frame.width) * CGFloat(prefs.windowOriginXFraction)
        let top = visible.maxY - visible.height * CGFloat(prefs.windowOriginYFraction)
        frame.origin.y = top - frame.height
        isProgrammaticMove = true
        panel.setFrame(frame, display: true)
        isProgrammaticMove = false
        fitHeight()
    }

    private func desiredHeight() -> CGFloat {
        var h = PaletteMetrics.headerHeight + 1 + PaletteMetrics.footerHeight + 1
        if session.scope != nil { h += PaletteMetrics.scopeBarHeight }
        var rows: CGFloat = 0
        for r in 0..<outlineView.numberOfRows {
            if let item = outlineView.item(atRow: r) { rows += self.outlineView(outlineView, heightOfRowByItem: item) }
        }
        h += rows + 8
        let screen = panel.screen ?? targetScreen()
        let maxHeight = min(screen.visibleFrame.height * 0.7, 820)
        return max(min(h, maxHeight), 120)
    }

    private var targetFrameHeight: CGFloat = 0

    private func fitHeight() {
        var frame = panel.frame
        let newHeight = desiredHeight()
        guard abs(targetFrameHeight - newHeight) > 0.5 || abs(frame.height - newHeight) > 0.5 else { return }
        targetFrameHeight = newHeight
        let top = frame.maxY
        frame.size.height = newHeight
        frame.origin.y = top - newHeight
        if isVisible && !style.reduceMotion {
            // Asynchronous Core Animation resize: never blocks typing.
            isAnimatingFrame = true
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                context.allowsImplicitAnimation = true
                panel.animator().setFrame(frame, display: true)
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // Only clear when no newer animation retargeted the frame.
                    if abs(self.panel.frame.height - self.targetFrameHeight) < 0.5 { self.isAnimatingFrame = false }
                }
            })
        } else {
            isProgrammaticMove = true
            panel.setFrame(frame, display: true)
            isProgrammaticMove = false
        }
    }

    // MARK: NSWindowDelegate

    func windowDidMove(_ notification: Notification) {
        guard !isProgrammaticMove, !isAnimatingFrame, isVisible, let screen = panel.screen else { return }
        let visible = screen.visibleFrame
        let frame = panel.frame
        let xf = Double(min(max((frame.origin.x - visible.minX) / max(visible.width - frame.width, 1), 0), 1))
        let yf = Double(min(max((visible.maxY - frame.maxY) / max(visible.height, 1), 0), 0.9))
        // Height animations keep the top edge fixed, so only real drags change these.
        if abs(app.preferences.windowOriginXFraction - xf) > 0.002 { app.preferences.windowOriginXFraction = xf }
        if abs(app.preferences.windowOriginYFraction - yf) > 0.002 { app.preferences.windowOriginYFraction = yf }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        app.preferences.windowWidth = Double(panel.frame.width)
    }

    func windowDidResignKey(_ notification: Notification) {
        // Clicking elsewhere dismisses the palette, like Spotlight.
        Log.palette.notice("resignKey; keyWindow=\(String(describing: NSApp.keyWindow), privacy: .public) frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?", privacy: .public)")
        if isVisible && !SnapshotHarness.isEnabled { hide(reason: "resignKey") }
    }

    // MARK: Build views

    private func buildViews() {
        let content = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        content.wantsLayer = true
        content.layer?.cornerRadius = PaletteMetrics.cornerRadius
        content.layer?.masksToBounds = true
        content.layer?.cornerCurve = .continuous
        panel.contentView = content

        backgroundView.frame = content.bounds
        backgroundView.autoresizingMask = [.width, .height]
        backgroundView.wantsLayer = true
        content.addSubview(backgroundView)

        let effect = NSVisualEffectView(frame: content.bounds)
        effect.autoresizingMask = [.width, .height]
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        backgroundView.addSubview(effect)
        effectView = effect

        // Header
        headerView.autoresizingMask = [.width, .minYMargin]
        content.addSubview(headerView)
        appIconView.imageScaling = .scaleProportionallyUpOrDown
        headerView.addSubview(appIconView)
        appIconButton.isBordered = false
        appIconButton.title = ""
        appIconButton.imagePosition = .noImage
        appIconButton.isTransparent = true
        appIconButton.target = self
        appIconButton.action = #selector(appIconClicked)
        appIconButton.toolTip = "Choose the app to act on (⌫ with an empty search)"
        headerView.addSubview(appIconButton)
        searchField.delegate = self
        headerView.addSubview(searchField)
        clearButton.isBordered = false
        clearButton.image = .symbol("xmark.circle.fill", pointSize: 14)
        clearButton.imagePosition = .imageOnly
        clearButton.target = self
        clearButton.action = #selector(clearTapped)
        clearButton.isHidden = true
        headerView.addSubview(clearButton)
        modeControl.segmentCount = 2
        modeControl.setImage(.symbol("list.bullet", pointSize: 12, weight: .medium), forSegment: 0)
        modeControl.setImage(.symbol("list.bullet.indent", pointSize: 12, weight: .medium), forSegment: 1)
        modeControl.setToolTip("List mode (⌘L): one flat list ranked by relevance. ↩ or → enters a menu, ⌫ or ← leaves it.", forSegment: 0)
        modeControl.setToolTip("Outline mode (⌘O): the menu hierarchy as a tree. → and ← expand and collapse; only branches with matches stay open while searching.", forSegment: 1)
        modeControl.segmentStyle = .rounded
        modeControl.trackingMode = .selectOne
        modeControl.controlSize = .small
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        headerView.addSubview(modeControl)
        optionsButton.isBordered = false
        optionsButton.image = .symbol("ellipsis.circle", pointSize: 16)
        optionsButton.imagePosition = .imageOnly
        optionsButton.target = self
        optionsButton.action = #selector(showOptions)
        optionsButton.toolTip = "Options"
        headerView.addSubview(optionsButton)

        scopeBar.isHidden = true
        scopeBar.onClear = { [weak self] in self?.exitScope() }
        content.addSubview(scopeBar)
        content.addSubview(topSeparator)

        // List
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScrollElasticity = .allowed
        scrollView.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        let column = NSTableColumn(identifier: .init("main"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.rowSizeStyle = .custom
        outlineView.intercellSpacing = .zero
        outlineView.backgroundColor = .clear
        outlineView.selectionHighlightStyle = .regular
        outlineView.allowsEmptySelection = true
        outlineView.allowsMultipleSelection = false
        outlineView.indentationPerLevel = PaletteMetrics.indentation
        outlineView.indentationMarkerFollowsCell = true
        outlineView.autoresizesOutlineColumn = true
        outlineView.floatsGroupRows = false
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.gridStyleMask = []
        outlineView.style = .plain
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(rowDoubleClicked)
        outlineView.action = #selector(rowClicked)
        outlineView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        scrollView.documentView = outlineView
        content.addSubview(scrollView)

        content.addSubview(bottomSeparator)
        footerView.addSubview(breadcrumbLabel)
        footerView.addSubview(countLabel)
        breadcrumbLabel.font = .systemFont(ofSize: 11)
        breadcrumbLabel.lineBreakMode = .byTruncatingMiddle
        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.alignment = .right
        content.addSubview(footerView)

        layoutViews()
        content.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: content, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layoutViews() }
        }
    }

    private func layoutViews() {
        guard let content = panel.contentView else { return }
        let w = content.bounds.width
        let h = content.bounds.height
        var y = h - PaletteMetrics.headerHeight
        headerView.frame = NSRect(x: 0, y: y, width: w, height: PaletteMetrics.headerHeight)
        appIconView.frame = NSRect(x: 16, y: (PaletteMetrics.headerHeight - 28) / 2, width: 28, height: 28)
        appIconButton.frame = appIconView.frame.insetBy(dx: -4, dy: -4)
        optionsButton.frame = NSRect(x: w - 16 - 24, y: (PaletteMetrics.headerHeight - 24) / 2, width: 24, height: 24)
        modeControl.sizeToFit()
        modeControl.frame = NSRect(x: optionsButton.frame.minX - 8 - modeControl.frame.width, y: (PaletteMetrics.headerHeight - modeControl.frame.height) / 2, width: modeControl.frame.width, height: modeControl.frame.height)
        clearButton.frame = NSRect(x: modeControl.frame.minX - 8 - 20, y: (PaletteMetrics.headerHeight - 20) / 2, width: 20, height: 20)
        let fieldX = appIconView.frame.maxX + 12
        searchField.frame = NSRect(x: fieldX, y: (PaletteMetrics.headerHeight - 22) / 2, width: clearButton.frame.minX - 6 - fieldX, height: 22)

        if !scopeBar.isHidden {
            y -= PaletteMetrics.scopeBarHeight
            scopeBar.frame = NSRect(x: 0, y: y, width: w, height: PaletteMetrics.scopeBarHeight)
        }
        y -= 1
        topSeparator.frame = NSRect(x: 0, y: y, width: w, height: 1)

        footerView.frame = NSRect(x: 0, y: 0, width: w, height: PaletteMetrics.footerHeight)
        breadcrumbLabel.frame = NSRect(x: 18, y: (PaletteMetrics.footerHeight - 16) / 2, width: w * 0.65, height: 16)
        countLabel.frame = NSRect(x: w - 18 - w * 0.3, y: (PaletteMetrics.footerHeight - 16) / 2, width: w * 0.3, height: 16)
        bottomSeparator.frame = NSRect(x: 0, y: PaletteMetrics.footerHeight, width: w, height: 1)

        let listTop = y
        let listBottom = PaletteMetrics.footerHeight + 1
        scrollView.frame = NSRect(x: 0, y: listBottom, width: w, height: max(0, listTop - listBottom))
        outlineView.sizeLastColumnToFit()
        // When everything fits, a stale scroll offset from a smaller frame would clip the first rows.
        if outlineView.numberOfRows > 0, outlineView.frame.height <= scrollView.contentView.bounds.height {
            outlineView.scrollRowToVisible(0)
        }
    }

    private func applyTheme() {
        panel.appearance = theme.appearance
        if theme.usesMaterial {
            effectView?.isHidden = false
            backgroundView.layer?.backgroundColor = NSColor.clear.cgColor
        } else {
            effectView?.isHidden = true
            backgroundView.layer?.backgroundColor = theme.background.cgColor
        }
        searchField.textColor = theme.text
        searchField.placeholderAttributedString = NSAttributedString(string: "Search", attributes: [.foregroundColor: theme.secondaryText, .font: searchField.font!])
        clearButton.contentTintColor = theme.secondaryText
        optionsButton.contentTintColor = theme.secondaryText
        topSeparator.color = theme.separator
        bottomSeparator.color = theme.separator
        breadcrumbLabel.textColor = theme.secondaryText
        countLabel.textColor = theme.secondaryText
        if !theme.usesMaterial {
            modeControl.appearance = theme.appearance
        }
        // Re-render rows with the new colours without losing selection/expansion.
        if !content.rows.isEmpty { reload(selectPreferred: false) }
        updateScopeBar()
    }

    private func updateClearButton() {
        clearButton.isHidden = searchField.stringValue.isEmpty
    }

    private func updateScopeBar() {
        let wasHidden = scopeBar.isHidden
        if let scope = session.scope {
            scopeBar.configure(scopeTitle: scope.title, theme: theme)
            scopeBar.isHidden = false
        } else {
            scopeBar.isHidden = true
        }
        if wasHidden != scopeBar.isHidden { layoutViews() }
    }

    private func updateFooter() {
        if session.pendingFile != nil {
            breadcrumbLabel.stringValue = session.pendingFile.map { FileEntry.abbreviate($0.path) } ?? ""
        } else if session.isPickingApp {
            breadcrumbLabel.stringValue = selectedRow()?.runningApp?.name ?? "Choose an app"
        } else if let row = selectedRow(), !row.breadcrumb.isEmpty {
            breadcrumbLabel.stringValue = row.breadcrumb
        } else if let scope = session.scope {
            breadcrumbLabel.stringValue = scope.breadcrumb
        } else {
            breadcrumbLabel.stringValue = session.app?.name ?? ""
        }
        var n = 0
        for r in 0..<outlineView.numberOfRows where (outlineView.item(atRow: r) as? PaletteRow)?.isSelectable == true { n += 1 }
        let noun = (session.isPickingApp || session.pendingFile != nil) ? "App" : "Item"
        countLabel.stringValue = n == 1 ? "1 \(noun)" : "\(n) \(noun)s"
    }

    // MARK: Header actions

    @objc private func clearTapped() { setQuery("") }

    @objc private func modeChanged() {
        setMode(modeControl.selectedSegment == 0 ? .list : .outline)
    }

    @objc private func showOptions() {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, _ key: String = "", mods: NSEvent.ModifierFlags = .command) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.target = self
            menu.addItem(item)
        }
        add("Find", #selector(menuFind), "f")
        add("Activate", #selector(menuActivate), "\r", mods: [])
        add("Reveal Menu Item", #selector(menuReveal), "\r")
        add("Search Help Menu", #selector(menuHelpSearch))
        add("Choose App…", #selector(menuChooseApp), "\u{08}", mods: [])
        add("Open Folder or File…", #selector(menuOpenCommand))
        if selectedRow()?.fileEntry?.isDirectory == false {
            add("Open With…", #selector(menuOpenWith), "\r", mods: [.option])
        }
        menu.addItem(.separator())
        add("List Mode", #selector(menuListMode), "l")
        add("Outline Mode", #selector(menuOutlineMode), "o")
        menu.addItem(.separator())
        add("Clear Recents for \(session.app?.name ?? "This App")", #selector(menuClearRecents))
        add("Center Window", #selector(menuCenter))
        menu.addItem(.separator())
        add("Settings…", #selector(menuSettings), ",")
        add("Help", #selector(menuHelp))
        menu.addItem(.separator())
        add("Quit SuperBar", #selector(menuQuit))
        menu.popUp(positioning: nil, at: NSPoint(x: optionsButton.bounds.minX, y: optionsButton.bounds.minY - 4), in: optionsButton)
    }

    @objc private func menuFind() { panel.makeFirstResponder(searchField); searchField.currentEditor()?.selectAll(nil) }
    @objc private func menuActivate() { activateSelection() }
    @objc private func menuReveal() { activateSelection(reveal: true) }
    @objc private func menuHelpSearch() { searchHelpMenu() }
    @objc private func menuChooseApp() { toggleAppPicker() }
    @objc private func menuOpenCommand() { setQuery(SearchSession.openKeyword + " ") }
    @objc private func menuOpenWith() { activateSelection(openWith: true) }
    @objc private func menuListMode() { setMode(.list) }
    @objc private func menuOutlineMode() { setMode(.outline) }
    @objc private func menuClearRecents() { if let key = session.app?.storageKey { app.recents.clear(appKey: key); reload(selectPreferred: true) } }
    @objc private func menuCenter() { centerWindow() }
    @objc private func menuSettings() { hide(); app.showSettings() }
    @objc private func menuHelp() { NSWorkspace.shared.open(URL(string: "https://github.com/manuader/super-bar#readme")!) }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    @objc private func rowClicked() {
        updateFooter()
    }

    @objc private func rowDoubleClicked() {
        let r = outlineView.clickedRow
        guard r >= 0, let row = outlineView.item(atRow: r) as? PaletteRow, row.isSelectable else { return }
        activate(row)
    }

    // MARK: Keyboard (search field stays first responder)

    func controlTextDidChange(_ obj: Notification) {
        Log.palette.debug("query=\(self.searchField.stringValue, privacy: .public)")
        session.query = searchField.stringValue
        updateClearButton()
        if session.openQuery != nil { updateFileResults() }
        reload(selectPreferred: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        Log.palette.debug("command \(NSStringFromSelector(selector), privacy: .public)")
        switch selector {
        case #selector(NSResponder.moveUp(_:)): moveSelection(by: -1); updateFooter(); return true
        case #selector(NSResponder.moveDown(_:)): moveSelection(by: 1); updateFooter(); return true
        case #selector(NSResponder.moveToBeginningOfParagraph(_:)), #selector(NSResponder.moveToBeginningOfDocument(_:)), #selector(NSResponder.scrollToBeginningOfDocument(_:)):
            selectEdge(first: true); updateFooter(); return true
        case #selector(NSResponder.moveToEndOfParagraph(_:)), #selector(NSResponder.moveToEndOfDocument(_:)), #selector(NSResponder.scrollToEndOfDocument(_:)):
            selectEdge(first: false); updateFooter(); return true
        case #selector(NSResponder.scrollPageUp(_:)), #selector(NSResponder.pageUp(_:)): pageSelection(down: false); updateFooter(); return true
        case #selector(NSResponder.scrollPageDown(_:)), #selector(NSResponder.pageDown(_:)): pageSelection(down: true); updateFooter(); return true
        case #selector(NSResponder.insertNewline(_:)):
            activateSelection(reveal: flags.contains(.command), openWith: flags.contains(.option)); return true
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            // ⌥↩ opens with a different app; the same selector arrives for ⌃O,
            // which must not activate anything.
            if flags.contains(.option) { activateSelection(openWith: true) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            handleEscape(); return true
        case #selector(NSResponder.insertTab(_:)):
            moveSelection(by: 1); updateFooter(); return true
        case #selector(NSResponder.insertBacktab(_:)):
            moveSelection(by: -1); updateFooter(); return true
        case #selector(NSResponder.deleteBackward(_:)):
            if searchField.stringValue.isEmpty {
                if session.scope != nil { exitScope() } else { toggleAppPicker() }
                return true
            }
            return false
        case #selector(NSResponder.moveRight(_:)), #selector(NSResponder.moveRightAndModifySelection(_:)):
            let atEnd = textView.selectedRange().location >= (textView.string as NSString).length
            if atEnd || flags.contains(.option) { toggleExpansion(expand: true, recursive: flags.contains(.option)); return true }
            return false
        case #selector(NSResponder.moveLeft(_:)), #selector(NSResponder.moveLeftAndModifySelection(_:)):
            let atStart = textView.selectedRange().location == 0
            if atStart || flags.contains(.option) { toggleExpansion(expand: false, recursive: flags.contains(.option)); return true }
            return false
        default:
            return false
        }
    }

    /// Command-key shortcuts that are not text editing commands.
    func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) else { return false }
        let chars = event.charactersIgnoringModifiers ?? ""
        if flags == .command, let n = Int(chars), (1...9).contains(n) { quickSelect(n); return true }
        switch (chars, flags) {
        case ("f", .command): menuFind(); return true
        case ("l", .command): setMode(.list); return true
        case ("o", .command): setMode(.outline); return true
        case ("w", .command), ("h", .command): hide(); return true
        case (",", .command): menuSettings(); return true
        case ("\r", .command): activateSelection(reveal: true); return true
        case ("a", .command): searchField.currentEditor()?.selectAll(nil); return true
        default: return false
        }
    }

    // MARK: NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let row = item as? PaletteRow else { return content.rows.count }
        return row.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let row = item as? PaletteRow else { return content.rows[index] }
        return row.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? PaletteRow)?.isExpandable ?? false
    }

    // MARK: NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let row = item as? PaletteRow else { return PaletteMetrics.compactRowHeight }
        let delta = style.textSizeDelta * 2
        switch row.kind {
        case .header: return PaletteMetrics.sectionHeaderHeight
        case .message: return PaletteMetrics.messageRowHeight
        case .skeleton: return PaletteMetrics.skeletonRowHeight
        default: return (row.showsSubtitle ? PaletteMetrics.subtitledRowHeight : PaletteMetrics.compactRowHeight) + delta
        }
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? PaletteRow)?.isSelectable ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("row")
        let view = outlineView.makeView(withIdentifier: id, owner: nil) as? PaletteRowView ?? {
            let v = PaletteRowView()
            v.identifier = id
            return v
        }()
        view.selectionColor = theme.selection
        return view
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let row = item as? PaletteRow else { return nil }
        let r = outlineView.row(forItem: row)
        let selected = r >= 0 && outlineView.isRowSelected(r)
        switch row.kind {
        case .header(let title):
            let id = NSUserInterfaceItemIdentifier("header")
            let view = outlineView.makeView(withIdentifier: id, owner: nil) as? SectionHeaderView ?? { let v = SectionHeaderView(); v.identifier = id; return v }()
            view.configure(title: title, style: style)
            return view
        case .message(let message):
            let id = NSUserInterfaceItemIdentifier("message")
            let view = outlineView.makeView(withIdentifier: id, owner: nil) as? MessageRowView ?? { let v = MessageRowView(); v.identifier = id; return v }()
            view.configure(message: message, style: style)
            view.onAction = { [weak self] in self?.perform(message.action) }
            return view
        case .skeleton:
            let id = NSUserInterfaceItemIdentifier("skeleton")
            let view = outlineView.makeView(withIdentifier: id, owner: nil) as? SkeletonRowView ?? { let v = SkeletonRowView(); v.identifier = id; return v }()
            view.seed = r
            view.barColor = theme.text.withAlphaComponent(0.08)
            return view
        default:
            let id = NSUserInterfaceItemIdentifier("menu")
            let view = outlineView.makeView(withIdentifier: id, owner: nil) as? MenuRowView ?? { let v = MenuRowView(); v.identifier = id; return v }()
            view.configure(row: row, style: style, selected: selected)
            return view
        }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        for r in 0..<outlineView.numberOfRows {
            if let cell = outlineView.view(atColumn: 0, row: r, makeIfNecessary: false) as? MenuRowView {
                cell.setSelected(outlineView.isRowSelected(r))
            }
        }
        updateFooter()
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        if let row = notification.userInfo?["NSObject"] as? PaletteRow {
            expanded.insert(row.id)
            if !content.isSearching { session.userExpanded.insert(row.id) }
        }
        assignQuickIndices()
        updateFooter()
        fitHeight()
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        if let row = notification.userInfo?["NSObject"] as? PaletteRow {
            expanded.remove(row.id)
            session.userExpanded.remove(row.id)
        }
        assignQuickIndices()
        updateFooter()
        fitHeight()
    }
}

// MARK: - Appearance observation

extension NSApplication {
    private static var appearanceObservers: [NSKeyValueObservation] = []

    func observeAppearance(_ handler: @escaping @MainActor () -> Void) {
        let observation = observe(\.effectiveAppearance, options: [.new]) { _, _ in
            DispatchQueue.main.async { handler() }
        }
        NSApplication.appearanceObservers.append(observation)
    }
}
