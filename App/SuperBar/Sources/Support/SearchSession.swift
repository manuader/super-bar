import AppKit
import SuperBarKit

/// One row of the palette. Reference type so `NSOutlineView` can use it as an item.
final class PaletteRow {
    enum Kind {
        case header(String)
        case menu(MenuNode)
        case script(ScriptItem)
        case message(Message)
        case skeleton
    }

    struct Message {
        enum Action { case grantAccessibility, retry, searchHelp, openRules, none }
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
    var isExpandable: Bool { !children.isEmpty }

    var title: String {
        switch kind {
        case .header(let t): return t
        case .menu(let n): return n.title
        case .script(let s): return s.title
        case .message(let m): return m.title
        case .skeleton: return ""
        }
    }

    var breadcrumb: String {
        switch kind {
        case .menu(let n): return n.breadcrumb
        case .script(let s): return "Scripts › \(s.title)"
        default: return ""
        }
    }

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
    /// Containers expanded by the user while browsing (root screen).
    var userExpanded: Set<String> = []

    init(preferences: Preferences, recents: RecentsStore) {
        self.preferences = preferences
        self.recents = recents
        self.mode = preferences.browsingMode
    }

    var isSearching: Bool { !FuzzyMatcher.Query(query).isEmpty }

    func resetSearchState() {
        query = ""
        scope = nil
        userExpanded = []
    }

    // MARK: Building rows

    func build() -> PaletteContent {
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
            var rows: [PaletteRow] = [PaletteRow(id: "h:search", kind: .header("Search"))]
            for hit in hits {
                switch hit.payload {
                case .menu(let node):
                    rows.append(PaletteRow(id: PaletteRow.menuID(node), kind: .menu(node), ranges: hit.titleRanges, showsSubtitle: preferences.showSubtitles))
                case .script(let s):
                    rows.append(PaletteRow(id: PaletteRow.scriptID(s), kind: .script(s), ranges: hit.titleRanges, showsSubtitle: preferences.showSubtitles))
                default: break
                }
            }
            if hits.isEmpty { return noResults() }
            return PaletteContent(rows: rows, expanded: [], preferredSelection: rows.dropFirst().first?.id, itemCount: hits.count, isSearching: true)
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
