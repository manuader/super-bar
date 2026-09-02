import Foundation

public enum MenuSourceError: Error, Equatable, Sendable {
    case accessibilityNotTrusted
    case applicationBusy
    case noMenuBar
    case elementUnavailable
    case actionFailed(String)

    public var message: String {
        switch self {
        case .accessibilityNotTrusted: return "SuperBar needs Accessibility access to read menus."
        case .applicationBusy: return "The application is busy and did not respond."
        case .noMenuBar: return "This application has no menu bar."
        case .elementUnavailable: return "The menu item is no longer available."
        case .actionFailed(let reason): return reason
        }
    }
}

/// Provides menu trees and performs actions on them. Implementations: the
/// Accessibility-backed `AXMenuSource` and the deterministic
/// `FixtureMenuSource` used by tests and the snapshot harness.
public protocol MenuSource: AnyObject, Sendable {
    /// Whether the process may read other apps' menus.
    var isTrusted: Bool { get }
    /// Synchronously loads the menu bar. Called from a background queue.
    /// `progress` is invoked with each top-level menu as soon as it is complete.
    func loadMenuBar(for app: AppInfo, progress: (MenuNode) -> Void) throws -> [MenuNode]
    /// Clicks a menu item.
    func press(_ node: MenuNode, in app: AppInfo) throws
    /// Opens the real menus and highlights the item without activating it.
    func reveal(_ node: MenuNode, in app: AppInfo) throws
    /// Opens the Help menu of the app and types the query into its search field.
    func searchHelpMenu(query: String, in app: AppInfo) throws
}

/// A menu tree built from a compact description. Used by unit tests and by
/// the visual snapshot harness (no Accessibility permission required).
public final class FixtureMenuSource: MenuSource, @unchecked Sendable {
    public var isTrusted: Bool = true
    public private(set) var pressed: [MenuNodeID] = []
    public private(set) var revealed: [MenuNodeID] = []
    public private(set) var helpQueries: [String] = []
    public var roots: [MenuNode]
    public var loadDelay: TimeInterval = 0

    public init(roots: [MenuNode]) { self.roots = roots }

    public func loadMenuBar(for app: AppInfo, progress: (MenuNode) -> Void) throws -> [MenuNode] {
        for root in roots {
            if loadDelay > 0 { Thread.sleep(forTimeInterval: loadDelay) }
            progress(root)
        }
        return roots
    }

    public func press(_ node: MenuNode, in app: AppInfo) throws { pressed.append(node.id) }
    public func reveal(_ node: MenuNode, in app: AppInfo) throws { revealed.append(node.id) }
    public func searchHelpMenu(query: String, in app: AppInfo) throws { helpQueries.append(query) }

    // MARK: Builder

    /// Item description used by `build`.
    public indirect enum Spec {
        case item(String, key: String? = nil, mark: String? = nil, enabled: Bool = true)
        case menu(String, [Spec])
        case separator
    }

    /// Builds a forest from specs; the top level are menu bar items.
    public static func build(_ menus: [(String, [Spec])]) -> [MenuNode] {
        func node(_ spec: Spec, index: Int, path: [String], indexPath: [Int], depth: Int) -> MenuNode {
            switch spec {
            case .separator:
                return MenuNode(title: "", path: path + [""], indexPath: indexPath + [index], depth: depth, isEnabled: false, kind: .separator)
            case .item(let title, let key, let mark, let enabled):
                let ke = key.flatMap(parseKey)
                return MenuNode(title: title, path: path + [title], indexPath: indexPath + [index], depth: depth, isEnabled: enabled, mark: mark, keyEquivalent: ke, kind: .item)
            case .menu(let title, let children):
                let p = path + [title], ip = indexPath + [index]
                let kids = children.enumerated().map { node($0.element, index: $0.offset, path: p, indexPath: ip, depth: depth + 1) }
                return MenuNode(title: title, path: p, indexPath: ip, depth: depth, kind: depth == 0 ? .menuBarItem : .submenu, children: kids)
            }
        }
        return menus.enumerated().map { node(.menu($0.element.0, $0.element.1), index: $0.offset, path: [], indexPath: [], depth: 0) }
    }

    /// Parses "⇧⌘M" / "⌘," / "F5" style strings.
    static func parseKey(_ text: String) -> KeyEquivalent? {
        var mods: KeyEquivalent.Modifiers = []
        var rest = Substring(text)
        while let first = rest.first {
            switch first {
            case "⌃": mods.insert(.control)
            case "⌥": mods.insert(.option)
            case "⇧": mods.insert(.shift)
            case "⌘": mods.insert(.command)
            default:
                return KeyEquivalent(modifiers: mods, key: String(rest))
            }
            rest = rest.dropFirst()
        }
        return nil
    }

    /// A Notes-like menu bar used for snapshots and tests.
    public static func notesLike() -> [MenuNode] {
        build([
            ("Apple", [
                .item("About This Mac"), .separator,
                .item("System Settings…"), .item("App Store…"), .separator,
                .menu("Recent Items", [.item("MenuBarRuleDialogFeature.swift"), .item("BarberPoleView.swift"), .separator, .item("Clear Menu")]),
                .separator, .item("Force Quit…", key: "⌥⌘⎋"), .separator,
                .item("Sleep"), .item("Restart…"), .item("Shut Down…"), .separator,
                .item("Lock Screen", key: "⌃⌘Q"), .item("Log Out Manu…", key: "⇧⌘Q"),
            ]),
            ("Notes", [
                .item("About Notes"), .separator, .item("Settings…", key: "⌘,"), .separator,
                .menu("Services", [.item("Open man Page in Terminal"), .item("Search man Page Index in Terminal")]),
                .separator, .item("Hide Notes", key: "⌘H"), .item("Hide Others", key: "⌥⌘H"), .item("Show All"), .separator,
                .item("Quit Notes", key: "⌘Q"),
            ]),
            ("File", [
                .item("New Note", key: "⌘N"), .item("New Folder", key: "⇧⌘N"), .item("New Smart Folder"), .separator,
                .menu("Open Recent", [.item("Groceries"), .item("Ideas"), .separator, .item("Clear Menu")]),
                .item("Close", key: "⌘W"), .separator,
                .menu("Share", [.item("Mail"), .item("Messages"), .item("AirDrop")]),
                .menu("Export", [.item("Export as PDF…"), .item("Export as Markdown…")]),
                .separator, .item("Import to Notes…"), .item("Pin Note", key: "⇧⌘P"), .item("Duplicate Note", key: "⌘D"), .separator,
                .item("Lock Note"), .separator, .item("Print…", key: "⌘P"),
            ]),
            ("Edit", [
                .item("Undo Typing", key: "⌘Z"), .item("Redo", key: "⇧⌘Z", enabled: false), .separator,
                .item("Cut", key: "⌘X"), .item("Copy", key: "⌘C"), .item("Paste", key: "⌘V"),
                .item("Paste and Match Style", key: "⌥⇧⌘V"), .item("Delete"), .item("Select All", key: "⌘A"), .separator,
                .item("Attach File…"), .item("Add Link…", key: "⌘K"), .separator,
                .menu("Find", [.item("Find…", key: "⌘F"), .item("Find and Replace…", key: "⌥⌘F"), .item("Find Next", key: "⌘G"), .item("Find Previous", key: "⇧⌘G")]),
                .menu("Spelling and Grammar", [.item("Show Spelling and Grammar", key: "⌘:"), .item("Check Document Now", key: "⌘;"), .separator, .item("Check Spelling While Typing", mark: "✓"), .item("Check Grammar With Spelling"), .item("Correct Spelling Automatically", mark: "✓")]),
                .menu("Substitutions", [.item("Show Substitutions"), .separator, .item("Smart Copy/Paste", mark: "✓"), .item("Smart Quotes", mark: "✓"), .item("Smart Dashes", mark: "✓"), .item("Smart Links", mark: "✓"), .item("Text Replacement", mark: "✓")]),
                .menu("Transformations", [.item("Make Upper Case"), .item("Make Lower Case"), .item("Capitalize")]),
                .menu("Speech", [.item("Start Speaking"), .item("Stop Speaking", enabled: false)]),
                .separator, .item("Start Dictation…", key: "F5"), .item("Emoji & Symbols", key: "⌃⌘␣"),
            ]),
            ("Format", [
                .item("Title", key: "⇧⌘T"), .item("Heading", key: "⇧⌘H"), .item("Subheading", key: "⇧⌘J"), .item("Body", key: "⇧⌘B", mark: "✓"),
                .item("Monostyled", key: "⇧⌘M"), .item("Bulleted List", key: "⇧⌘7"), .item("Dashed List", key: "⇧⌘8"), .item("Numbered List", key: "⇧⌘9"),
                .item("Block Quote", key: "⌘'"), .item("Checklist", key: "⇧⌘L"), .item("Mark as Checked", key: "⇧⌘U", enabled: false), .separator,
                .menu("More", [.item("Increase Indent"), .item("Decrease Indent"), .item("Move List Item Up"), .item("Move List Item Down")]),
                .menu("Move Item", [.item("Up", key: "⌃⌘↑"), .item("Down", key: "⌃⌘↓")]),
                .item("Table", key: "⌥⌘T"), .item("Convert to Text", enabled: false), .item("Reverse Table Direction", enabled: false), .separator,
                .menu("Font", [
                    .item("Show Fonts", key: "⌘T"), .item("Bold", key: "⌘B"), .item("Italic", key: "⌘I"), .item("Underline", key: "⌘U"), .item("Strikethrough"), .separator,
                    .item("Bigger", key: "⌘+"), .item("Smaller", key: "⌘-"), .separator,
                    .menu("Kern", [.item("Use Default"), .item("Use None"), .item("Tighten"), .item("Loosen")]),
                    .menu("Ligatures", [.item("Use Default"), .item("Use None"), .item("Use All")]),
                    .menu("Baseline", [.item("Use Default"), .item("Superscript"), .item("Subscript"), .item("Raise"), .item("Lower")]),
                    .separator, .item("Show Colors", key: "⇧⌘C"), .separator, .item("Copy Style", key: "⌥⌘C"), .item("Paste Style", key: "⌥⌘V"),
                ]),
                .menu("Text", [
                    .item("Align Left", key: "⌘{", mark: "✓"), .item("Center", key: "⌘|"), .item("Justify"), .item("Align Right", key: "⌘}"), .separator,
                    .menu("Writing Direction", [.item("Default", mark: "✓"), .item("Left to Right"), .item("Right to Left")]),
                    .separator, .item("Show Ruler"), .separator, .item("Copy Ruler"), .item("Paste Ruler"),
                ]),
                .menu("Indentation", [.item("Increase", key: "⌘]"), .item("Decrease", key: "⌘[")]),
                .menu("Math Results", [.item("Insert Result"), .item("Copy Result"), .item("Show Math Results", mark: "✓")]),
            ]),
            ("View", [
                .item("as List", key: "⌘1", mark: "✓"), .item("as Gallery", key: "⌘2"), .separator,
                .item("Show Folders", key: "⌥⌘S"), .item("Show Note Count"), .separator,
                .item("Zoom In", key: "⌘+"), .item("Zoom Out", key: "⌘-"), .item("Actual Size", key: "⌘0"), .separator,
                .item("Show Attachments Browser", key: "⌘3"), .item("Show Note in Window"), .separator,
                .item("Enter Full Screen", key: "⌃⌘F"),
            ]),
            ("Window", [
                .item("Minimize", key: "⌘M"), .item("Zoom"), .item("Fill"), .item("Center"), .separator,
                .menu("Move & Resize", [.item("Left"), .item("Right"), .item("Top"), .item("Bottom")]),
                .item("Keep on Top"), .separator, .item("Bring All to Front"), .separator, .item("Notes", mark: "✓"),
            ]),
            ("Help", [.item("Notes Help"), .item("Notes User Guide")]),
        ])
    }
}
