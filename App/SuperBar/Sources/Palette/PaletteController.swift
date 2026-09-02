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
        let appChanged = target?.processIdentifier != currentApp?.processIdentifier
        currentApp = target
        session.isTrusted = app.menuSource.isTrusted
        if app.preferences.clearSearchStateImmediately || appChanged {
            session.resetSearchState()
        }
        session.mode = app.preferences.browsingMode
        session.scripts = ScriptsLibrary.items(for: target?.bundleIdentifier, in: app.scripts)
        appIconView.image = target?.icon ?? NSImage(named: NSImage.applicationIconName)
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
        reload(selectPreferred: true)
        position()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
        searchField.currentEditor()?.selectAll(nil)
    }

    func hide() {
        guard isVisible else { return }
        panel.orderOut(nil)
    }

    /// Used by the snapshot harness: session state is pre-filled by the caller.
    func showForSnapshot(icon: NSImage?) {
        appIconView.image = icon
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
        if !searchField.stringValue.isEmpty {
            setQuery("")
        } else {
            hide()
        }
    }

    func frontmostAppChanged(_ running: NSRunningApplication) {
        // While visible, the panel follows the front app (e.g. the user ⌘-tabbed).
        guard isVisible, running.processIdentifier != currentApp?.processIdentifier else { return }
        show()
    }

    func scriptsDidChange() {
        guard isVisible, !SnapshotHarness.isEnabled else { return }
        session.scripts = ScriptsLibrary.items(for: currentApp?.bundleIdentifier, in: app.scripts)
        reload(selectPreferred: false)
    }

    func preferencesDidChange() {
        let prefs = app.preferences
        theme = ResolvedTheme.current(preferences: prefs, isDarkAppearance: NSApp.effectiveAppearance.isDark)
        style = RowStyle(theme: theme, textSizeDelta: CGFloat(prefs.rowTextSize.pointDelta), showCountBadge: prefs.showCountBadge, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        applyTheme()
        if abs(panel.frame.width - CGFloat(prefs.windowWidth)) > 1 {
            var frame = panel.frame
            frame.size.width = CGFloat(prefs.windowWidth)
            isProgrammaticMove = true
            panel.setFrame(frame, display: true)
            isProgrammaticMove = false
        }
        if isVisible { reload(selectPreferred: false); position() }
    }

    private func appearanceChanged() {
        preferencesDidChange()
    }

    // MARK: Data

    private func adopt(_ entry: MenuCache.Entry, for info: AppInfo) {
        lastLoadedPID = info.pid
        let rawRoots = entry.snapshot?.roots ?? entry.partialRoots
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
        rowsByID = [:]
        func index(_ row: PaletteRow) { rowsByID[row.id] = row; row.children.forEach(index) }
        content.rows.forEach(index)
        expanded = content.expanded
        outlineView.reloadData()
        for id in expanded { if let row = rowsByID[id] { outlineView.expandItem(row) } }
        assignQuickIndices()
        let target = (selectPreferred ? content.preferredSelection : nil) ?? previous.flatMap { rowsByID[$0] != nil && isRowVisible($0) ? $0 : nil } ?? content.preferredSelection ?? content.firstSelectable()?.id
        if let target, let row = rowsByID[target] { select(row, scroll: true) } else { outlineView.deselectAll(nil) }
        updateFooter()
        updateScopeBar()
        fitHeight()
    }

    private func isRowVisible(_ id: String) -> Bool {
        guard let row = rowsByID[id] else { return false }
        return outlineView.row(forItem: row) >= 0
    }

    private func assignQuickIndices() {
        var n = 1
        for r in 0..<outlineView.numberOfRows {
            guard let row = outlineView.item(atRow: r) as? PaletteRow else { continue }
            if row.isSelectable, n <= 9 {
                row.quickIndex = n
                n += 1
            } else {
                row.quickIndex = nil
            }
            if let cell = outlineView.view(atColumn: 0, row: r, makeIfNecessary: false) as? MenuRowView {
                cell.configure(row: row, style: style, selected: outlineView.isRowSelected(r))
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

    func activateSelection(reveal: Bool = false) {
        if let row = selectedRow() {
            activate(row, reveal: reveal)
        } else if let message = content.rows.first?.message, message.actionTitle != nil {
            perform(message.action)
        }
    }

    func activate(_ row: PaletteRow, reveal: Bool = false) {
        switch row.kind {
        case .menu(let node):
            guard let info = session.app else { return }
            if reveal {
                hide()
                app.activator.reveal(node, app: info) { [weak self] error in
                    if let error { self?.app.notify(title: "Couldn’t reveal “\(node.title)”", body: error.localizedDescription) }
                }
                return
            }
            if node.isContainer {
                if node.visibleChildren.isEmpty { NSSound.beep(); return }
                enterScope(node)
                return
            }
            hide()
            app.activator.press(node, app: info, running: currentApp) { [weak self] error in
                if let error {
                    self?.app.notify(title: "Couldn’t select “\(node.title)”", body: (error as? MenuSourceError)?.message ?? error.localizedDescription)
                }
            }
        case .script(let script):
            hide()
            app.activator.run(script, app: session.app) { [weak self] result in
                if !result.isSuccess {
                    let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
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
        case .none:
            break
        }
    }

    func searchHelpMenu() {
        guard let info = session.app else { return }
        let query = session.query
        hide()
        app.activator.searchHelp(query: query, app: info) { [weak self] error in
            if let error { self?.app.notify(title: "Couldn’t open the Help menu", body: (error as? MenuSourceError)?.message ?? error.localizedDescription) }
        }
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
        if expand {
            if row.isExpandable {
                outlineView.expandItem(row, expandChildren: recursive)
                expanded.insert(row.id)
                if recursive { row.children.forEach(markExpanded) }
                if !content.isSearching { session.userExpanded.insert(row.id); if recursive { row.children.forEach { session.userExpanded.insert($0.id) } } }
            }
        } else {
            if row.isExpandable && outlineView.isItemExpanded(row) {
                outlineView.collapseItem(row, collapseChildren: recursive)
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

    private func fitHeight() {
        var frame = panel.frame
        let newHeight = desiredHeight()
        guard abs(frame.height - newHeight) > 0.5 else { return }
        let top = frame.maxY
        frame.size.height = newHeight
        frame.origin.y = top - newHeight
        isProgrammaticMove = true
        panel.setFrame(frame, display: true, animate: isVisible && !style.reduceMotion)
        isProgrammaticMove = false
    }

    // MARK: NSWindowDelegate

    func windowDidMove(_ notification: Notification) {
        guard !isProgrammaticMove, isVisible, let screen = panel.screen else { return }
        let visible = screen.visibleFrame
        let frame = panel.frame
        let xf = (frame.origin.x - visible.minX) / max(visible.width - frame.width, 1)
        let yf = (visible.maxY - frame.maxY) / max(visible.height, 1)
        app.preferences.windowOriginXFraction = Double(min(max(xf, 0), 1))
        app.preferences.windowOriginYFraction = Double(min(max(yf, 0), 0.9))
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        app.preferences.windowWidth = Double(panel.frame.width)
    }

    func windowDidResignKey(_ notification: Notification) {
        // Clicking elsewhere dismisses the palette, like Spotlight.
        if isVisible && !SnapshotHarness.isEnabled { hide() }
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
        modeControl.setToolTip("List mode (⌘L)", forSegment: 0)
        modeControl.setToolTip("Outline mode (⌘O)", forSegment: 1)
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
        outlineView.reloadData()
        for id in expanded { if let row = rowsByID[id] { outlineView.expandItem(row) } }
        assignQuickIndices()
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
        if let row = selectedRow(), !row.breadcrumb.isEmpty {
            breadcrumbLabel.stringValue = row.breadcrumb
        } else if let scope = session.scope {
            breadcrumbLabel.stringValue = scope.breadcrumb
        } else {
            breadcrumbLabel.stringValue = session.app?.name ?? ""
        }
        let n = content.itemCount
        countLabel.stringValue = n == 1 ? "1 Item" : "\(n) Items"
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
        session.query = searchField.stringValue
        updateClearButton()
        reload(selectPreferred: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
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
            activateSelection(reveal: flags.contains(.command)); return true
        case #selector(NSResponder.cancelOperation(_:)):
            handleEscape(); return true
        case #selector(NSResponder.insertTab(_:)):
            moveSelection(by: 1); updateFooter(); return true
        case #selector(NSResponder.insertBacktab(_:)):
            moveSelection(by: -1); updateFooter(); return true
        case #selector(NSResponder.deleteBackward(_:)):
            if searchField.stringValue.isEmpty && session.scope != nil { exitScope(); return true }
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
        fitHeight()
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        if let row = notification.userInfo?["NSObject"] as? PaletteRow {
            expanded.remove(row.id)
            session.userExpanded.remove(row.id)
        }
        assignQuickIndices()
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
