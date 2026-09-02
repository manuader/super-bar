import AppKit
import SuperBarKit

/// A running application offered by the app picker.
struct RunningApp: Hashable, Sendable {
    let pid: pid_t
    let name: String
    let bundleIdentifier: String?
    let icon: NSImage?
    let isFrontmost: Bool

    static func == (a: RunningApp, b: RunningApp) -> Bool { a.pid == b.pid }
    func hash(into hasher: inout Hasher) { hasher.combine(pid) }

    init(pid: pid_t, name: String, bundleIdentifier: String?, icon: NSImage?, isFrontmost: Bool) {
        self.pid = pid; self.name = name; self.bundleIdentifier = bundleIdentifier; self.icon = icon; self.isFrontmost = isFrontmost
    }

    init(_ app: NSRunningApplication, isFrontmost: Bool) {
        self.init(pid: app.processIdentifier, name: app.localizedName ?? app.bundleIdentifier ?? "App", bundleIdentifier: app.bundleIdentifier, icon: RunningApp.rasterize(app.icon), isFrontmost: isFrontmost)
    }

    /// App icons are decoded lazily by IconServices; drawing them once into a
    /// small bitmap makes them render immediately (and cheaply) in rows.
    static func rasterize(_ image: NSImage?, size: CGFloat = 32) -> NSImage? {
        guard let image else { return nil }
        let out = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        // Force the drawing block to run now and cache the result as a bitmap.
        guard let tiff = out.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return image }
        let bitmap = NSImage(size: NSSize(width: size, height: size))
        bitmap.addRepresentation(rep)
        return bitmap
    }
}

/// One row of the palette. Reference type so `NSOutlineView` can use it as an item.
final class PaletteRow {
    enum Kind {
        case header(String)
        case menu(MenuNode)
        case script(ScriptItem)
        case app(RunningApp)
        case file(FileEntry)
        case handler(AppHandler)
        case command(Command)
        case message(Message)
        case skeleton
    }

    /// A palette command typed as a word, currently just `open`.
    struct Command: Hashable {
        var keyword: String
        var title: String
        var subtitle: String
        var symbol: String
        static let open = Command(keyword: "open", title: "Open…", subtitle: "Search folders and files, then open them", symbol: "folder")
    }

    struct Message {
        enum Action { case grantAccessibility, retry, searchHelp, openRules, rebuildIndex, openFileSettings, none }
        var symbol: String
        var title: String
        var subtitle: String?
        var actionTitle: String?
        var action: Action
    }

    let id: String
    let kind: Kind
    var ranges: [NSRange]
    var isRecent: Bool
    var showsSubtitle: Bool
    var children: [PaletteRow]
    weak var parent: PaletteRow?
    var quickIndex: Int? = nil

    init(id: String, kind: Kind, ranges: [NSRange] = [], isRecent: Bool = false, showsSubtitle: Bool = false, children: [PaletteRow] = []) {
        self.id = id
        self.kind = kind
        self.ranges = ranges
        self.isRecent = isRecent
        self.showsSubtitle = showsSubtitle
        self.children = children
        for child in children { child.parent = self }
    }

    var isHeader: Bool { if case .header = kind { return true } else { return false } }
    var isSelectable: Bool {
        switch kind {
        case .header, .skeleton, .message: return false
        default: return true
        }
    }
    var message: Message? { if case .message(let m) = kind { return m } else { return nil } }
    var menuNode: MenuNode? { if case .menu(let n) = kind { return n } else { return nil } }
    var scriptItem: ScriptItem? { if case .script(let s) = kind { return s } else { return nil } }
    var runningApp: RunningApp? { if case .app(let a) = kind { return a } else { return nil } }
    var fileEntry: FileEntry? { if case .file(let f) = kind { return f } else { return nil } }
    var appHandler: AppHandler? { if case .handler(let h) = kind { return h } else { return nil } }
    var command: Command? { if case .command(let c) = kind { return c } else { return nil } }
    var isExpandable: Bool { !children.isEmpty }

    var title: String {
        switch kind {
        case .header(let t): return t
        case .menu(let n): return n.title
        case .script(let s): return s.title
        case .app(let a): return a.name
        case .file(let f): return f.name
        case .handler(let h): return h.name
        case .command(let c): return c.title
        case .message(let m): return m.title
        case .skeleton: return ""
        }
    }

    var breadcrumb: String {
        switch kind {
        case .menu(let n): return n.breadcrumb
        case .script(let s): return "Scripts › \(s.title)"
        case .app(let a): return a.bundleIdentifier ?? a.name
        case .file(let f): return FileEntry.abbreviate(f.path)
        case .handler(let h): return h.url?.path ?? ""
        case .command(let c): return c.subtitle
        default: return ""
        }
    }

    static func appID(_ app: RunningApp) -> String { "a:\(app.pid)" }
    static func fileID(_ entry: FileEntry) -> String { "f:" + entry.path }
    static func handlerID(_ handler: AppHandler) -> String { "w:" + (handler.url?.path ?? "browse") }

    static func menuID(_ node: MenuNode) -> String { "m:" + node.id.description }
    static func scriptID(_ item: ScriptItem) -> String { "s:" + item.id }
}

/// Everything needed to render the list for one state of the palette.
struct PaletteContent {
    var rows: [PaletteRow]
    var expanded: Set<String>
    var preferredSelection: String?
    var itemCount: Int
    var isSearching: Bool

    /// Flat list in display order given the expansion set (headers included).
    func visibleRows() -> [PaletteRow] {
        var out: [PaletteRow] = []
        func walk(_ row: PaletteRow) {
            out.append(row)
            if expanded.contains(row.id) { row.children.forEach(walk) }
        }
        rows.forEach(walk)
        return out
    }

    func firstSelectable() -> PaletteRow? { visibleRows().first { $0.isSelectable } }
}

/// Pure state of the palette (mode, query, scope) and the rows derived from it.
@MainActor
final class SearchSession {
    let preferences: Preferences
    let recents: RecentsStore

    var app: AppInfo?
    var roots: [MenuNode] = [] { didSet { rootsToken &+= 1 } }
    private var rootsToken = 0
    private var candidateCache: (token: Int, scope: MenuNodeID?, scripts: [String], recents: Int, mode: BrowsingMode, value: [SearchCandidate<PaletteRow.Kind>])?
    var loadState: MenuCache.State = .idle
    var isTrusted = true
    var rulesRemovedEverything = false
    var scripts: [ScriptItem] = []
    var query = ""
    var mode: BrowsingMode
    var scope: MenuNode?
    /// App picker: choose which running app the palette acts on.
    var isPickingApp = false
    var runningApps: [RunningApp] = []
    /// `open` command: file search results, kept in sync by the controller.
    var fileResults: FileIndexSnapshot.Results?
    var fileResultsQuery: String?
    var fileIndexState: FileIndexService.State = .idle
    /// Set while asking which app should open a file of this type.
    var pendingFile: FileEntry?
    var handlerCandidates: [AppHandler] = []
    /// Containers expanded by the user while browsing (root screen).
    var userExpanded: Set<String> = []

    init(preferences: Preferences, recents: RecentsStore) {
        self.preferences = preferences
        self.recents = recents
        self.mode = preferences.browsingMode
    }

    var isSearching: Bool { !FuzzyMatcher.Query(query).isEmpty }

    // MARK: The `open` command

    static let openKeyword = "open"

    /// The text after `open `, or nil when the palette is not in open mode.
    var openQuery: String? {
        guard preferences.openCommandEnabled else { return nil }
        let prefix = SearchSession.openKeyword + " "
        guard query.count >= prefix.count,
              query.prefix(prefix.count).lowercased() == prefix else { return nil }
        return String(query.dropFirst(prefix.count))
    }

    var isOpenMode: Bool { openQuery != nil }
    /// True while the user has typed a prefix of `open` but not the space yet.
    var suggestsOpenCommand: Bool {
        guard preferences.openCommandEnabled, !query.isEmpty, openQuery == nil, pendingFile == nil else { return false }
        return SearchSession.openKeyword.hasPrefix(query.lowercased())
    }

    func resetSearchState() {
        query = ""
        scope = nil
        userExpanded = []
        isPickingApp = false
        pendingFile = nil
        handlerCandidates = []
        fileResults = nil
        fileResultsQuery = nil
    }

    // MARK: Building rows

    func build() -> PaletteContent {
        if pendingFile != nil { return buildHandlerPicker() }
        if isPickingApp { return buildAppPicker() }
        if let openQuery { return buildOpen(openQuery) }
        if !isTrusted {
            return message(.init(symbol: "hand.raised.fill", title: "Accessibility access required", subtitle: "SuperBar reads menus through the Accessibility API. Grant access in System Settings to get started.", actionTitle: "Open System Settings", action: .grantAccessibility))
        }
        if case .failed(let error) = loadState, roots.isEmpty {
            switch error {
            case .accessibilityNotTrusted:
                return message(.init(symbol: "hand.raised.fill", title: "Accessibility access required", subtitle: error.message, actionTitle: "Open System Settings", action: .grantAccessibility))
            default:
                return message(.init(symbol: "exclamationmark.triangle.fill", title: "\(app?.name ?? "The app") didn’t respond", subtitle: error.message, actionTitle: "Try Again", action: .retry))
            }
        }
        if roots.isEmpty {
            if loadState == .loading {
                let rows = (0..<6).map { PaletteRow(id: "skeleton\($0)", kind: .skeleton) }
                return PaletteContent(rows: [PaletteRow(id: "h:loading", kind: .header("Menu Items"))] + rows, expanded: [], preferredSelection: nil, itemCount: 0, isSearching: false)
            }
            if rulesRemovedEverything {
                return message(.init(symbol: "line.3.horizontal.decrease.circle", title: "Your rules exclude every menu item", subtitle: "Adjust or disable a rule to see items again.", actionTitle: "Edit Rules…", action: .openRules))
            }
        }
        return isSearching ? buildSearch() : buildBrowse()
    }

    /// Running apps, filtered by the query, most recently used first.
    private func buildAppPicker() -> PaletteContent {
        let q = FuzzyMatcher.Query(query)
        var rows: [PaletteRow] = [PaletteRow(id: "h:apps", kind: .header(q.isEmpty ? "Open Apps" : "Apps"))]
        let currentPID = app?.pid
        if q.isEmpty {
            for a in runningApps { rows.append(PaletteRow(id: PaletteRow.appID(a), kind: .app(a))) }
        } else {
            let candidates = runningApps.enumerated().map { SearchCandidate(payload: $0.element, title: $0.element.name, pathText: $0.element.bundleIdentifier, originalOrder: $0.offset) }
            for hit in ListSearch.search(q, in: candidates) {
                rows.append(PaletteRow(id: PaletteRow.appID(hit.payload), kind: .app(hit.payload), ranges: hit.titleRanges))
            }
            if rows.count == 1 {
                let m = PaletteRow.Message(symbol: "app.dashed", title: "No app matches “\(query)”", subtitle: "Only apps with a menu bar are listed.", actionTitle: nil, action: .none)
                return PaletteContent(rows: [PaletteRow(id: "x:noapps", kind: .message(m))], expanded: [], preferredSelection: nil, itemCount: 0, isSearching: true)
            }
        }
        // Preselect the app the palette is acting on when not searching.
        let preferred = q.isEmpty ? rows.first(where: { $0.runningApp?.pid == currentPID })?.id : rows.dropFirst().first?.id
        return PaletteContent(rows: rows, expanded: [], preferredSelection: preferred, itemCount: rows.count - 1, isSearching: !q.isEmpty)
    }

    /// Folders first, then files, exactly as typed after `open `.
    private func buildOpen(_ text: String) -> PaletteContent {
        var rows: [PaletteRow] = []
        var count = 0
        let subtitles = true
        // Results for the previous keystroke stay on screen until the new ones
        // arrive (a few milliseconds later), which avoids flicker while typing.
        let results = fileResults

        if let results, !results.isEmpty {
            if !results.directories.isEmpty {
                rows.append(PaletteRow(id: "h:folders", kind: .header("Folders")))
                for hit in results.directories {
                    rows.append(PaletteRow(id: PaletteRow.fileID(hit.entry), kind: .file(hit.entry), ranges: hit.range.map { [$0] } ?? [], showsSubtitle: subtitles))
                }
                count += results.directories.count
            }
            if !results.files.isEmpty {
                rows.append(PaletteRow(id: "h:files", kind: .header("Files")))
                for hit in results.files {
                    rows.append(PaletteRow(id: PaletteRow.fileID(hit.entry), kind: .file(hit.entry), ranges: hit.range.map { [$0] } ?? [], showsSubtitle: subtitles))
                }
                count += results.files.count
            }
            let preferred = rows.first(where: { $0.isSelectable })?.id
            return PaletteContent(rows: rows, expanded: [], preferredSelection: preferred, itemCount: count, isSearching: true)
        }

        switch fileIndexState {
        case .idle, .indexing:
            let skeletons = (0..<5).map { PaletteRow(id: "skeleton\($0)", kind: .skeleton) }
            return PaletteContent(rows: [PaletteRow(id: "h:folders", kind: .header("Indexing your folders…"))] + skeletons, expanded: [], preferredSelection: nil, itemCount: 0, isSearching: true)
        case .unavailable(let reason):
            let m = PaletteRow.Message(symbol: "folder.badge.questionmark", title: "Nothing to search", subtitle: reason, actionTitle: "Rebuild Index", action: .rebuildIndex)
            return PaletteContent(rows: [PaletteRow(id: "x:noindex", kind: .message(m))], expanded: [], preferredSelection: nil, itemCount: 0, isSearching: true)
        case .ready:
            if text.trimmingCharacters(in: .whitespaces).isEmpty {
                let m = PaletteRow.Message(symbol: "folder", title: "Open a folder or file", subtitle: "Type part of a name. Folders are listed first, then files.", actionTitle: nil, action: .none)
                return PaletteContent(rows: [PaletteRow(id: "x:openhint", kind: .message(m))], expanded: [], preferredSelection: nil, itemCount: 0, isSearching: true)
            }
            let m = PaletteRow.Message(symbol: "magnifyingglass", title: "No folder or file matches “\(text)”", subtitle: "Only indexed folders are searched. Add more in Settings › Open.", actionTitle: "Open Settings", action: .openFileSettings)
            return PaletteContent(rows: [PaletteRow(id: "x:nofiles", kind: .message(m))], expanded: [], preferredSelection: nil, itemCount: 0, isSearching: true)
        }
    }

    /// Which app should open this kind of file, asked once per file type.
    private func buildHandlerPicker() -> PaletteContent {
        guard let file = pendingFile else { return message(.init(symbol: "questionmark", title: "Nothing to open", subtitle: nil, actionTitle: nil, action: .none)) }
        let type = FileTypeHandlers.key(for: file.path)
        let title = type.isEmpty ? "Open “\(file.name)” with" : "Open .\(type) files with"
        var rows: [PaletteRow] = [PaletteRow(id: "h:handlers", kind: .header(title))]
        for handler in handlerCandidates {
            rows.append(PaletteRow(id: PaletteRow.handlerID(handler), kind: .handler(handler), showsSubtitle: false))
        }
        return PaletteContent(rows: rows, expanded: [], preferredSelection: rows.dropFirst().first?.id, itemCount: handlerCandidates.count, isSearching: false)
    }

    private func message(_ m: PaletteRow.Message) -> PaletteContent {
        PaletteContent(rows: [PaletteRow(id: "x:" + m.title, kind: .message(m))], expanded: [], preferredSelection: nil, itemCount: 0, isSearching: false)
    }

    private var scopedRoots: [MenuNode] {
        if let scope { return scope.children }
        return roots
    }

    private var appKey: String { app?.storageKey ?? "" }

    private func buildBrowse() -> PaletteContent {
        var rows: [PaletteRow] = []
        var expanded = Set<String>()
        var count = 0

        if scope == nil {
            let recentRows = recentRows()
            if !recentRows.isEmpty {
                rows.append(PaletteRow(id: "h:recents", kind: .header("Recents")))
                rows.append(contentsOf: recentRows)
            }
        }

        let source = scopedRoots.filter { !$0.isSeparator }
        if !source.isEmpty {
            rows.append(PaletteRow(id: "h:menu", kind: .header(scope == nil ? "Menu Items" : scope!.title)))
            for node in source {
                switch mode {
                case .list:
                    // List mode is flat: containers are entered with ↩ / → (scoping).
                    rows.append(PaletteRow(id: PaletteRow.menuID(node), kind: .menu(node)))
                case .outline:
                    rows.append(tree(node, ranges: [:], userExpansion: true, expanded: &expanded))
                }
            }
            count += scope == nil ? roots.searchableCount : scope!.flattened.count - 1
        } else if scope != nil {
            rows.append(PaletteRow(id: "x:empty", kind: .message(.init(symbol: "tray", title: "\(scope!.title) is empty", subtitle: "This menu has no items right now.", actionTitle: nil, action: .none))))
        }

        if scope == nil {
            let scriptRows = scripts.map { PaletteRow(id: PaletteRow.scriptID($0), kind: .script($0)) }
            if !scriptRows.isEmpty {
                rows.append(PaletteRow(id: "h:scripts", kind: .header("Scripts")))
                rows.append(contentsOf: scriptRows)
                count += scriptRows.count
            }
        }
        // Skip recents by default: the first menu item is the natural target (Finbar selects the first row).
        let content = PaletteContent(rows: rows, expanded: expanded, preferredSelection: nil, itemCount: count, isSearching: false)
        return content
    }

    private func recentRows() -> [PaletteRow] {
        guard !roots.isEmpty else { return [] }
        let limit = max(0, preferences.recentsLimit)
        guard limit > 0 else { return [] }
        var rows: [PaletteRow] = []
        for entry in recents.top(appKey: appKey, limit: limit * 3) where rows.count < limit {
            if entry.isScript {
                if let s = scripts.first(where: { $0.title == entry.titlePath.first }) {
                    rows.append(PaletteRow(id: "r:" + PaletteRow.scriptID(s), kind: .script(s), isRecent: true))
                }
                continue
            }
            if let node = resolve(entry) {
                rows.append(PaletteRow(id: "r:" + PaletteRow.menuID(node), kind: .menu(node), isRecent: true, showsSubtitle: preferences.showSubtitles))
            }
        }
        return rows
    }

    /// Finds a remembered item in the current tree by title path, falling back
    /// to its positional path under the same menu bar item.
    private func resolve(_ entry: RecentEntry) -> MenuNode? {
        if let byIndex = roots.node(at: entry.indexPath), byIndex.path == entry.titlePath { return byIndex }
        var candidates = roots
        var node: MenuNode?
        for title in entry.titlePath {
            guard let next = candidates.first(where: { $0.title == title }) else { node = nil; break }
            node = next
            candidates = next.children
        }
        if let node { return node }
        if let byIndex = roots.node(at: entry.indexPath), byIndex.path.first == entry.titlePath.first, !byIndex.isSeparator { return byIndex }
        return nil
    }

    private func tree(_ node: MenuNode, ranges: [MenuNodeID: [NSRange]], userExpansion: Bool, expanded: inout Set<String>) -> PaletteRow {
        let id = PaletteRow.menuID(node)
        let children = node.children.filter { !$0.isSeparator }.map { tree($0, ranges: ranges, userExpansion: userExpansion, expanded: &expanded) }
        if userExpansion && userExpanded.contains(id) && !children.isEmpty { expanded.insert(id) }
        return PaletteRow(id: id, kind: .menu(node), ranges: ranges[node.id] ?? [], children: children)
    }

    /// Candidates are expensive to build (folded search text per node), so they
    /// are cached until the menu tree, scope, scripts or recents change.
    private func listCandidates() -> [SearchCandidate<PaletteRow.Kind>] {
        let scriptIDs = scripts.map(\.id)
        if let cache = candidateCache, cache.token == rootsToken, cache.scope == scope?.id, cache.scripts == scriptIDs, cache.recents == recents.version, cache.mode == mode {
            return cache.value
        }
        let frecency = recents.index(appKey: appKey)
        var candidates: [SearchCandidate<PaletteRow.Kind>] = []
        var order = 0
        let nodes = scopedRoots.flattened
        candidates.reserveCapacity(nodes.count + scripts.count)
        for node in nodes {
            candidates.append(SearchCandidate(payload: .menu(node), title: node.displayTitle, pathText: node.breadcrumb, frecency: frecency.score(titlePath: node.path, indexPath: node.indexPath), originalOrder: order))
            order += 1
        }
        if scope == nil {
            for s in scripts {
                candidates.append(SearchCandidate(payload: .script(s), title: s.title, pathText: nil, frecency: frecency.scriptScore(title: s.title), originalOrder: order))
                order += 1
            }
        }
        candidateCache = (rootsToken, scope?.id, scriptIDs, recents.version, mode, candidates)
        return candidates
    }

    private func buildSearch() -> PaletteContent {
        let q = FuzzyMatcher.Query(query)
        let applicable = scripts
        switch mode {
        case .list:
            let hits = ListSearch.search(q, in: listCandidates())
            var rows: [PaletteRow] = []
            if suggestsOpenCommand {
                rows.append(PaletteRow(id: "h:commands", kind: .header("Command")))
                rows.append(PaletteRow(id: "c:open", kind: .command(.open), showsSubtitle: true))
            }
            rows.append(PaletteRow(id: "h:search", kind: .header("Search")))
            for hit in hits {
                switch hit.payload {
                case .menu(let node):
                    rows.append(PaletteRow(id: PaletteRow.menuID(node), kind: .menu(node), ranges: hit.titleRanges, showsSubtitle: preferences.showSubtitles))
                case .script(let s):
                    rows.append(PaletteRow(id: PaletteRow.scriptID(s), kind: .script(s), ranges: hit.titleRanges, showsSubtitle: preferences.showSubtitles))
                default: break
                }
            }
            if hits.isEmpty && !suggestsOpenCommand { return noResults() }
            let preferred = rows.first(where: { $0.isSelectable })?.id
            return PaletteContent(rows: rows, expanded: [], preferredSelection: preferred, itemCount: hits.count, isSearching: true)
        case .outline:
            let result = OutlineSearch.search(q, in: scopedRoots)
            var expanded = Set<String>()
            var rows: [PaletteRow] = []
            if !result.roots.isEmpty {
                rows.append(PaletteRow(id: "h:search", kind: .header("Search")))
                for node in result.roots where !node.isSeparator {
                    rows.append(tree(node, ranges: result.ranges, userExpansion: false, expanded: &expanded))
                }
                for id in result.expanded { expanded.insert("m:" + id.description) }
            }
            if suggestsOpenCommand {
                rows.insert(PaletteRow(id: "c:open", kind: .command(.open), showsSubtitle: true), at: 0)
                rows.insert(PaletteRow(id: "h:commands", kind: .header("Command")), at: 0)
            }
            var scriptHits: [PaletteRow] = []
            if scope == nil {
                let candidates = applicable.enumerated().map { SearchCandidate(payload: $0.element, title: $0.element.title, frecency: 0, originalOrder: $0.offset) }
                scriptHits = ListSearch.search(q, in: candidates).map { PaletteRow(id: PaletteRow.scriptID($0.payload), kind: .script($0.payload), ranges: $0.titleRanges) }
                if !scriptHits.isEmpty {
                    rows.append(PaletteRow(id: "h:scripts", kind: .header("Scripts")))
                    rows.append(contentsOf: scriptHits)
                }
            }
            if rows.isEmpty { return noResults() }
            let count = result.ranges.count + scriptHits.count
            let preferred = result.bestMatch.map { "m:" + $0.description } ?? scriptHits.first?.id
            return PaletteContent(rows: rows, expanded: expanded, preferredSelection: preferred, itemCount: count, isSearching: true)
        }
    }

    private func noResults() -> PaletteContent {
        let m = PaletteRow.Message(symbol: "magnifyingglass", title: "No Results for “\(query)”", subtitle: scope == nil ? "Try a different search, or look it up in the Help menu." : "Nothing in \(scope!.title) matches. Press ⌫ to search everything.", actionTitle: scope == nil ? "Search Help Menu" : nil, action: scope == nil ? .searchHelp : .none)
        return PaletteContent(rows: [PaletteRow(id: "x:noresults", kind: .message(m))], expanded: [], preferredSelection: nil, itemCount: 0, isSearching: true)
    }
}
