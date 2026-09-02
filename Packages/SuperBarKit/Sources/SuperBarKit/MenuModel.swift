import Foundation

/// Identifies a running application whose menu bar is being searched.
public struct AppInfo: Hashable, Sendable, Codable {
    public var pid: Int32
    public var bundleIdentifier: String?
    public var name: String

    public init(pid: Int32, bundleIdentifier: String?, name: String) {
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.name = name
    }

    /// Key used for per-app storage (recents, scripts). Falls back to the name.
    public var storageKey: String { bundleIdentifier ?? "name:\(name)" }
}

/// Stable identity of a menu node inside one snapshot: its positional path.
public struct MenuNodeID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let indexPath: [Int]
    public init(_ indexPath: [Int]) { self.indexPath = indexPath }
    public var description: String { indexPath.map(String.init).joined(separator: ".") }
}

public enum MenuNodeKind: String, Sendable, Codable {
    case menuBarItem   // depth 0: Apple, File, Edit…
    case submenu       // an item that opens another menu
    case item          // a leaf command
    case separator
}

/// An immutable node of an application's menu bar.
public struct MenuNode: Hashable, Sendable, Identifiable {
    public var id: MenuNodeID { MenuNodeID(indexPath) }

    public var title: String
    /// Titles from the menu bar item down to this node, inclusive.
    public var path: [String]
    /// Positional indices (separators count), inclusive.
    public var indexPath: [Int]
    /// 0 for a menu bar item, +1 per level.
    public var depth: Int
    public var isEnabled: Bool
    public var mark: String?
    public var keyEquivalent: KeyEquivalent?
    public var kind: MenuNodeKind
    public var children: [MenuNode]

    public init(title: String,
                path: [String],
                indexPath: [Int],
                depth: Int,
                isEnabled: Bool = true,
                mark: String? = nil,
                keyEquivalent: KeyEquivalent? = nil,
                kind: MenuNodeKind,
                children: [MenuNode] = []) {
        self.title = title
        self.path = path
        self.indexPath = indexPath
        self.depth = depth
        self.isEnabled = isEnabled
        self.mark = mark
        self.keyEquivalent = keyEquivalent
        self.kind = kind
        self.children = children
    }

    public var isSeparator: Bool { kind == .separator }
    public var isContainer: Bool { kind == .menuBarItem || kind == .submenu }
    public var parentPath: [String] { Array(path.dropLast()) }
    public var index: Int { indexPath.last ?? 0 }

    /// Children that are displayed (separators are never displayed).
    public var visibleChildren: [MenuNode] { children.filter { !$0.isSeparator } }

    /// What the count badge shows for a container.
    public var visibleChildCount: Int { visibleChildren.count }

    /// Title shown in list mode: deep items are prefixed by their containing
    /// menu so that "Bold" reads "Font › Bold" (Finbar behaviour).
    public var displayTitle: String {
        guard depth >= 2, let parent = parentPath.last, !parent.isEmpty else { return title }
        return "\(parent) › \(title)"
    }

    /// Path used for subtitles: everything above the display title.
    public var subtitlePath: [String] {
        if depth >= 2 { return Array(path.dropLast(2)) }
        return Array(path.dropLast())
    }

    /// Full breadcrumb "File › Open Recent › Foo".
    public var breadcrumb: String { path.joined(separator: " › ") }

    /// Backslash-separated path used by rules and the CLI ("View\\Translation").
    public var rulePath: String { path.joined(separator: "\\") }

    /// Depth-first traversal of the subtree rooted at this node (self first).
    public func forEachNode(_ body: (MenuNode) -> Void) {
        body(self)
        for child in children { child.forEachNode(body) }
    }

    /// Flattened, separator-free list of self and all descendants.
    public var flattened: [MenuNode] {
        var out: [MenuNode] = []
        out.reserveCapacity(64)
        forEachNode { if !$0.isSeparator { out.append($0) } }
        return out
    }

    /// Returns the node at the given positional path relative to this node's
    /// children (an empty path returns self).
    public func node(at indexPath: ArraySlice<Int>) -> MenuNode? {
        guard let first = indexPath.first else { return self }
        guard let child = children.first(where: { $0.index == first }) else { return nil }
        return child.node(at: indexPath.dropFirst())
    }
}

public extension Array where Element == MenuNode {
    /// Finds a node anywhere in the forest by positional path.
    func node(at indexPath: [Int]) -> MenuNode? {
        guard let head = indexPath.first,
              let root = first(where: { $0.index == head }) else { return nil }
        return root.node(at: indexPath.dropFirst())
    }

    var flattened: [MenuNode] { flatMap { $0.flattened } }

    /// Displayable nodes excluding menu bar items (what the footer counts).
    var searchableCount: Int { flattened.filter { $0.kind != .menuBarItem }.count }
}

/// A complete picture of an app's menu bar at one moment.
public struct MenuSnapshot: Sendable {
    public var app: AppInfo
    public var roots: [MenuNode]
    public var createdAt: Date
    public var isComplete: Bool

    public init(app: AppInfo, roots: [MenuNode], createdAt: Date = Date(), isComplete: Bool = true) {
        self.app = app
        self.roots = roots
        self.createdAt = createdAt
        self.isComplete = isComplete
    }
}
