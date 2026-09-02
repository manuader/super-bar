import Foundation
import ApplicationServices
import CoreGraphics

/// Reads and drives application menus through the Accessibility API.
/// All methods are synchronous and must be called off the main thread.
public final class AXMenuSource: MenuSource {
    public static let messagingTimeout: Float = 1.5

    private let lock = NSLock()
    /// Per-pid map from positional path to the live element (refreshed on load).
    private var elements: [Int32: [[Int]: AXUIElement]] = [:]
    private var appElements: [Int32: AXUIElement] = [:]

    public init() {}

    public var isTrusted: Bool { AXIsProcessTrusted() }

    /// Prompts the system Accessibility dialog once.
    public static func requestTrust() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    public static let accessibilitySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    // MARK: Loading

    public func loadMenuBar(for app: AppInfo, progress: (MenuNode) -> Void) throws -> [MenuNode] {
        guard isTrusted else { throw MenuSourceError.accessibilityNotTrusted }
        let appElement = self.appElement(for: app.pid)
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(appElement, kAXMenuBarAttribute as CFString, &value)
        switch err {
        case .success: break
        case .apiDisabled: throw MenuSourceError.accessibilityNotTrusted
        case .cannotComplete, .notImplemented: throw MenuSourceError.applicationBusy
        default: throw MenuSourceError.noMenuBar
        }
        guard let menuBar = value, CFGetTypeID(menuBar) == AXUIElementGetTypeID() else { throw MenuSourceError.noMenuBar }
        let bar = menuBar as! AXUIElement
        let barItems = children(of: bar)
        guard !barItems.isEmpty else { throw MenuSourceError.applicationBusy }

        var map: [[Int]: AXUIElement] = [:]
        var roots: [MenuNode] = []
        roots.reserveCapacity(barItems.count)
        for (index, item) in barItems.enumerated() {
            let attrs = attributes(of: item)
            let title = attrs.title
            let node = walkContainer(item, title: title, index: index, path: [title], indexPath: [index], depth: 0, enabled: attrs.enabled, map: &map)
            roots.append(node)
            progress(node)
        }
        lock.lock()
        elements[app.pid] = map
        lock.unlock()
        return roots
    }

    private func walkContainer(_ element: AXUIElement, title: String, index: Int, path: [String], indexPath: [Int], depth: Int, enabled: Bool, map: inout [[Int]: AXUIElement]) -> MenuNode {
        map[indexPath] = element
        // A menu bar item / submenu item owns exactly one AXMenu child.
        let menus = children(of: element)
        var items: [MenuNode] = []
        if let menu = menus.first {
            let entries = children(of: menu)
            items.reserveCapacity(entries.count)
            for (i, entry) in entries.enumerated() {
                items.append(walkItem(entry, index: i, path: path, indexPath: indexPath, depth: depth + 1, map: &map))
            }
        }
        return MenuNode(title: title, path: path, indexPath: indexPath, depth: depth, isEnabled: enabled, kind: depth == 0 ? .menuBarItem : .submenu, children: items)
    }

    private func walkItem(_ element: AXUIElement, index: Int, path: [String], indexPath: [Int], depth: Int, map: inout [[Int]: AXUIElement]) -> MenuNode {
        let a = attributes(of: element)
        let ip = indexPath + [index]
        let p = path + [a.title]
        let hasSubmenu = a.childCount > 0
        if a.title.isEmpty && !hasSubmenu {
            map[ip] = element
            return MenuNode(title: "", path: p, indexPath: ip, depth: depth, isEnabled: false, kind: .separator)
        }
        if hasSubmenu {
            return walkContainer(element, title: a.title, index: index, path: p, indexPath: ip, depth: depth, enabled: a.enabled, map: &map)
        }
        map[ip] = element
        let key = KeyEquivalent(cmdChar: a.cmdChar, modifierMask: a.cmdModifiers, virtualKey: a.cmdVirtualKey, glyph: a.cmdGlyph)
        return MenuNode(title: a.title, path: p, indexPath: ip, depth: depth, isEnabled: a.enabled, mark: a.mark, keyEquivalent: key, kind: .item)
    }

    // MARK: Attribute reading

    private struct Attributes {
        var title = ""
        var enabled = true
        var childCount = 0
        var cmdChar: String?
        var cmdModifiers: Int?
        var cmdVirtualKey: Int?
        var cmdGlyph: Int?
        var mark: String?
    }

    private static let attributeNames: [String] = [
        kAXTitleAttribute, kAXEnabledAttribute, kAXChildrenAttribute,
        kAXMenuItemCmdCharAttribute, kAXMenuItemCmdModifiersAttribute,
        kAXMenuItemCmdVirtualKeyAttribute, kAXMenuItemCmdGlyphAttribute,
        kAXMenuItemMarkCharAttribute,
    ]

    private func attributes(of element: AXUIElement) -> Attributes {
        var values: CFArray?
        let err = AXUIElementCopyMultipleAttributeValues(element, AXMenuSource.attributeNames as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values)
        var out = Attributes()
        guard err == .success, let array = values as? [AnyObject], array.count == AXMenuSource.attributeNames.count else {
            // Fall back to individual reads (older apps).
            out.title = string(element, kAXTitleAttribute) ?? ""
            out.enabled = bool(element, kAXEnabledAttribute) ?? true
            out.childCount = children(of: element).count
            return out
        }
        out.title = (array[0] as? String) ?? ""
        out.enabled = (array[1] as? Bool) ?? true
        out.childCount = (array[2] as? [AnyObject])?.count ?? 0
        out.cmdChar = array[3] as? String
        out.cmdModifiers = (array[4] as? NSNumber)?.intValue
        out.cmdVirtualKey = (array[5] as? NSNumber)?.intValue
        out.cmdGlyph = (array[6] as? NSNumber)?.intValue
        if let mark = array[7] as? String, !mark.isEmpty { out.mark = mark }
        return out
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let array = value as? [AnyObject] else { return [] }
        return array.compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
    }

    private func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? Bool
    }

    private func appElement(for pid: Int32) -> AXUIElement {
        lock.lock(); defer { lock.unlock() }
        if let e = appElements[pid] { return e }
        let e = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(e, AXMenuSource.messagingTimeout)
        appElements[pid] = e
        return e
    }

    /// Drops cached elements for an application that quit.
    public func forget(pid: Int32) {
        lock.lock()
        elements[pid] = nil
        appElements[pid] = nil
        lock.unlock()
    }

    // MARK: Element resolution

    private func element(for node: MenuNode, in app: AppInfo) throws -> AXUIElement {
        lock.lock()
        let cached = elements[app.pid]?[node.indexPath]
        lock.unlock()
        if let cached, isAlive(cached) { return cached }
        // Re-walk by indices from a fresh menu bar.
        let appElement = self.appElement(for: app.pid)
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(appElement, kAXMenuBarAttribute as CFString, &value) == .success,
              let bar = value, CFGetTypeID(bar) == AXUIElementGetTypeID() else { throw MenuSourceError.elementUnavailable }
        var current = bar as! AXUIElement
        for (level, index) in node.indexPath.enumerated() {
            let kids = level == 0 ? children(of: current) : children(of: children(of: current).first ?? current)
            guard index < kids.count else { throw MenuSourceError.elementUnavailable }
            current = kids[index]
        }
        lock.lock()
        elements[app.pid, default: [:]][node.indexPath] = current
        lock.unlock()
        return current
    }

    private func isAlive(_ element: AXUIElement) -> Bool {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success
    }

    // MARK: Actions

    public func press(_ node: MenuNode, in app: AppInfo) throws {
        let element = try element(for: node, in: app)
        let err = AXUIElementPerformAction(element, kAXPressAction as CFString)
        guard err == .success else {
            throw MenuSourceError.actionFailed("Could not click “\(node.title)” (\(err.rawValue)).")
        }
    }

    /// Opens every ancestor menu and highlights the item without activating it.
    public func reveal(_ node: MenuNode, in app: AppInfo) throws {
        var ancestors: [MenuNode] = []
        var prefix: [Int] = []
        // Resolve ancestor elements by index path prefixes.
        for index in node.indexPath.dropLast() {
            prefix.append(index)
            let stub = MenuNode(title: "", path: [], indexPath: prefix, depth: prefix.count - 1, kind: prefix.count == 1 ? .menuBarItem : .submenu)
            ancestors.append(stub)
        }
        for ancestor in ancestors {
            let e = try element(for: ancestor, in: app)
            let err = AXUIElementPerformAction(e, kAXPressAction as CFString)
            guard err == .success else { throw MenuSourceError.actionFailed("Could not open the menu.") }
            Thread.sleep(forTimeInterval: 0.08)
        }
        let leaf = try element(for: node, in: app)
        // Highlighting is best effort: not every app supports AXSelected on menu items.
        AXUIElementSetAttributeValue(leaf, kAXSelectedAttribute as CFString, kCFBooleanTrue)
    }

    /// Presses the Help menu (its search field takes focus) and types the query.
    public func searchHelpMenu(query: String, in app: AppInfo) throws {
        let appElement = self.appElement(for: app.pid)
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(appElement, kAXMenuBarAttribute as CFString, &value) == .success,
              let bar = value, CFGetTypeID(bar) == AXUIElementGetTypeID() else { throw MenuSourceError.noMenuBar }
        let items = children(of: bar as! AXUIElement)
        let help = items.last(where: { string($0, kAXTitleAttribute) == "Help" }) ?? items.last
        guard let helpItem = help else { throw MenuSourceError.noMenuBar }
        guard AXUIElementPerformAction(helpItem, kAXPressAction as CFString) == .success else {
            throw MenuSourceError.actionFailed("Could not open the Help menu.")
        }
        Thread.sleep(forTimeInterval: 0.15)
        AXMenuSource.type(query)
    }

    /// Posts the string as keyboard events to the frontmost app.
    public static func type(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for scalar in text.utf16 {
            var chars = [UniChar(scalar)]
            if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                down.keyboardSetUnicodeString(stringLength: 1, unicodeString: &chars)
                down.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                up.keyboardSetUnicodeString(stringLength: 1, unicodeString: &chars)
                up.post(tap: .cghidEventTap)
            }
        }
    }

    /// Sends Escape to the frontmost app (closes an open menu after a reveal).
    public static func pressEscape() {
        let source = CGEventSource(stateID: .combinedSessionState)
        CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: false)?.post(tap: .cghidEventTap)
    }
}
