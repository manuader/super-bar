import Foundation

/// A menu item's keyboard shortcut, rendered the way the menu bar does
/// ("⌃⌥⇧⌘K").
public struct KeyEquivalent: Hashable, Sendable, Codable {
    public struct Modifiers: OptionSet, Hashable, Sendable, Codable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)

        /// Menu bar display order: ⌃ ⌥ ⇧ ⌘.
        public var symbols: String {
            var out = ""
            if contains(.control) { out += "⌃" }
            if contains(.option) { out += "⌥" }
            if contains(.shift) { out += "⇧" }
            if contains(.command) { out += "⌘" }
            return out
        }
    }

    public var modifiers: Modifiers
    /// The key as displayed: "K", "↩", "F5", "␣".
    public var key: String

    public init(modifiers: Modifiers, key: String) {
        self.modifiers = modifiers
        self.key = key
    }

    public var display: String { modifiers.symbols + key }

    // MARK: Decoding from Accessibility attributes

    /// Builds a key equivalent from the raw `AXMenuItemCmd*` attributes.
    /// - Parameters:
    ///   - cmdChar: `AXMenuItemCmdChar`, a printable or function-key character.
    ///   - modifierMask: `AXMenuItemCmdModifiers` (Carbon mask: 0 = ⌘, +1 ⇧, +2 ⌥, +4 ⌃, +8 no ⌘).
    ///   - virtualKey: `AXMenuItemCmdVirtualKey`.
    ///   - glyph: `AXMenuItemCmdGlyph` (Carbon glyph id).
    public init?(cmdChar: String?, modifierMask: Int?, virtualKey: Int?, glyph: Int?) {
        let keyText: String?
        if let glyph, glyph != 0, let symbol = KeyEquivalent.glyphSymbols[glyph] {
            keyText = symbol
        } else if let cmdChar, !cmdChar.isEmpty, let symbol = KeyEquivalent.symbol(forCmdChar: cmdChar) {
            keyText = symbol
        } else if let virtualKey, let symbol = KeyEquivalent.virtualKeySymbols[virtualKey] {
            keyText = symbol
        } else {
            keyText = nil
        }
        guard let key = keyText else { return nil }
        self.init(modifiers: Modifiers(carbonMask: modifierMask ?? 0), key: key)
    }

    /// Maps a raw `AXMenuItemCmdChar` value to a display symbol.
    static func symbol(forCmdChar raw: String) -> String? {
        guard let scalar = raw.unicodeScalars.first else { return nil }
        if let special = cmdCharSymbols[scalar.value] { return special }
        if scalar.value < 0x20 { return nil }
        return raw.uppercased()
    }

    static let cmdCharSymbols: [UInt32: String] = [
        0x0003: "⌤", 0x0008: "⌫", 0x007F: "⌫", 0x0009: "⇥", 0x0019: "⇤", 0x000D: "↩",
        0x001B: "⎋", 0x0020: "␣",
        0xF700: "↑", 0xF701: "↓", 0xF702: "←", 0xF703: "→",
        0xF704: "F1", 0xF705: "F2", 0xF706: "F3", 0xF707: "F4", 0xF708: "F5", 0xF709: "F6",
        0xF70A: "F7", 0xF70B: "F8", 0xF70C: "F9", 0xF70D: "F10", 0xF70E: "F11", 0xF70F: "F12",
        0xF710: "F13", 0xF711: "F14", 0xF712: "F15", 0xF713: "F16", 0xF714: "F17",
        0xF715: "F18", 0xF716: "F19", 0xF717: "F20",
        0xF728: "⌦", 0xF729: "↖", 0xF72B: "↘", 0xF72C: "⇞", 0xF72D: "⇟", 0xF72E: "⌧",
        0xF735: "⏏", 0xF746: "?⃝",
    ]

    /// Carbon `kMenu*Glyph` identifiers.
    static let glyphSymbols: [Int: String] = [
        2: "⇥", 3: "⇤", 4: "⌤", 5: "⇧", 6: "⌃", 7: "⌥", 9: "␣", 10: "⌦", 11: "↩",
        12: "↪", 17: "⌘", 18: "✓", 19: "◊", 23: "⌫", 24: "⇠", 25: "⇡", 26: "⇢",
        27: "⎋", 28: "⌧", 98: "⇞", 99: "⇟", 100: "⇪", 101: "←", 102: "→", 103: "↑", 104: "↓",
        110: "⌽", 111: "F1", 112: "F2", 113: "F3", 114: "F4", 115: "F5", 116: "F6",
        117: "F7", 118: "F8", 119: "F9", 120: "F10", 121: "F11", 122: "F12", 123: "F13",
        124: "F14", 125: "F15", 140: "⏏", 143: "F16", 144: "F17", 145: "F18", 146: "F19",
    ]

    /// Fallback from hardware virtual key codes.
    static let virtualKeySymbols: [Int: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        117: "⌦", 53: "⎋", 48: "⇥", 49: "␣", 36: "↩", 51: "⌫", 76: "⌤", 71: "⌧", 57: "⇪",
    ]
}

public extension KeyEquivalent.Modifiers {
    /// Decodes the Carbon menu modifier mask used by `AXMenuItemCmdModifiers`.
    init(carbonMask mask: Int) {
        var mods: KeyEquivalent.Modifiers = []
        if mask & 1 != 0 { mods.insert(.shift) }
        if mask & 2 != 0 { mods.insert(.option) }
        if mask & 4 != 0 { mods.insert(.control) }
        if mask & 8 == 0 { mods.insert(.command) }
        self = mods
    }
}
