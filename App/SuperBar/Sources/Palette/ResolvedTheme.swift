import AppKit
import SuperBarKit

/// A theme resolved into AppKit colours for the current appearance.
struct ResolvedTheme {
    let theme: Theme
    let usesMaterial: Bool
    let appearance: NSAppearance?
    let background: NSColor
    let text: NSColor
    let secondaryText: NSColor
    let selection: NSColor
    let selectionText: NSColor
    let badgeBackground: NSColor
    let badgeText: NSColor
    let accent: NSColor
    let separator: NSColor

    static func resolve(_ theme: Theme) -> ResolvedTheme {
        if theme.usesSystemColors {
            return ResolvedTheme(
                theme: theme, usesMaterial: true,
                appearance: NSAppearance(named: theme.isDark ? .darkAqua : .aqua),
                background: .clear,
                text: .labelColor,
                secondaryText: .secondaryLabelColor,
                selection: .controlAccentColor,
                selectionText: .alternateSelectedControlTextColor,
                badgeBackground: .quaternaryLabelColor,
                badgeText: .secondaryLabelColor,
                accent: .controlAccentColor,
                separator: .separatorColor)
        }
        return ResolvedTheme(
            theme: theme, usesMaterial: false,
            appearance: NSAppearance(named: theme.isDark ? .darkAqua : .aqua),
            background: NSColor(theme.background),
            text: NSColor(theme.text),
            secondaryText: NSColor(theme.secondaryText),
            selection: NSColor(theme.selection),
            selectionText: NSColor(theme.selectionText),
            badgeBackground: NSColor(theme.badgeBackground),
            badgeText: NSColor(theme.badgeText),
            accent: NSColor(theme.accent),
            separator: NSColor(theme.separator))
    }

    /// Picks the theme for the current system appearance from preferences.
    static func current(preferences: Preferences, isDarkAppearance: Bool) -> ResolvedTheme {
        let id = isDarkAppearance ? preferences.selectedDarkTheme : preferences.selectedLightTheme
        let theme = preferences.theme(id: id) ?? (isDarkAppearance ? BuiltInThemes.systemDark : BuiltInThemes.systemLight)
        return resolve(theme)
    }

    /// True when the selection colour is light enough that white badges would vanish.
    var selectionIsLight: Bool { theme.usesSystemColors ? false : theme.selection.luminance > 0.6 }
}

extension NSColor {
    convenience init(_ c: ThemeColor) {
        self.init(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
    }

    var themeColor: ThemeColor {
        let c = usingColorSpace(.sRGB) ?? self
        return ThemeColor(red: Double(c.redComponent), green: Double(c.greenComponent), blue: Double(c.blueComponent), alpha: Double(c.alphaComponent))
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}
