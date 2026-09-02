import Foundation

/// A colour independent from AppKit so the kit stays UI-free. Hex round-trips.
public struct ThemeColor: Hashable, Sendable, Codable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }

    /// Accepts "#RGB", "#RRGGBB" or "#RRGGBBAA".
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard let value = UInt64(s, radix: 16) else { return nil }
        switch s.count {
        case 3:
            red = Double((value >> 8) & 0xF) / 15; green = Double((value >> 4) & 0xF) / 15; blue = Double(value & 0xF) / 15; alpha = 1
        case 6:
            red = Double((value >> 16) & 0xFF) / 255; green = Double((value >> 8) & 0xFF) / 255; blue = Double(value & 0xFF) / 255; alpha = 1
        case 8:
            red = Double((value >> 24) & 0xFF) / 255; green = Double((value >> 16) & 0xFF) / 255; blue = Double((value >> 8) & 0xFF) / 255; alpha = Double(value & 0xFF) / 255
        default:
            return nil
        }
    }

    public var hex: String {
        func c(_ v: Double) -> String { String(format: "%02X", Int((min(max(v, 0), 1) * 255).rounded())) }
        return alpha >= 0.999 ? "#\(c(red))\(c(green))\(c(blue))" : "#\(c(red))\(c(green))\(c(blue))\(c(alpha))"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let color = ThemeColor(hex: string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid colour \(string)")
        }
        self = color
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }

    public func withAlpha(_ a: Double) -> ThemeColor { ThemeColor(red: red, green: green, blue: blue, alpha: a) }

    /// Perceived luminance (0 = black, 1 = white).
    public var luminance: Double { 0.2126 * red + 0.7152 * green + 0.0722 * blue }
}

/// Palette colours. System themes use dynamic colours and a material; the
/// classic palettes are opaque.
public struct Theme: Hashable, Sendable, Codable, Identifiable {
    public var id: String
    public var name: String
    public var isBuiltIn: Bool
    /// When true the app uses `NSVisualEffectView` + system dynamic colours and
    /// ignores the colour fields below.
    public var usesSystemColors: Bool
    public var isDark: Bool
    public var background: ThemeColor
    public var text: ThemeColor
    public var secondaryText: ThemeColor
    public var selection: ThemeColor
    public var selectionText: ThemeColor
    public var badgeBackground: ThemeColor
    public var badgeText: ThemeColor
    public var accent: ThemeColor
    public var separator: ThemeColor

    public init(id: String, name: String, isBuiltIn: Bool, usesSystemColors: Bool, isDark: Bool,
                background: ThemeColor, text: ThemeColor, secondaryText: ThemeColor, selection: ThemeColor,
                selectionText: ThemeColor, badgeBackground: ThemeColor, badgeText: ThemeColor,
                accent: ThemeColor, separator: ThemeColor) {
        self.id = id; self.name = name; self.isBuiltIn = isBuiltIn; self.usesSystemColors = usesSystemColors
        self.isDark = isDark; self.background = background; self.text = text; self.secondaryText = secondaryText
        self.selection = selection; self.selectionText = selectionText; self.badgeBackground = badgeBackground
        self.badgeText = badgeText; self.accent = accent; self.separator = separator
    }

    public static let systemLightID = "system-light"
    public static let systemDarkID = "system-dark"

    /// Copy suitable as a starting point for a custom theme.
    public func customCopy(named name: String) -> Theme {
        var copy = self
        copy.id = "custom-" + UUID().uuidString
        copy.name = name
        copy.isBuiltIn = false
        copy.usesSystemColors = false
        return copy
    }
}

public enum BuiltInThemes {
    private static func c(_ hex: String) -> ThemeColor { ThemeColor(hex: hex)! }

    public static let systemLight = Theme(
        id: Theme.systemLightID, name: "System Light", isBuiltIn: true, usesSystemColors: true, isDark: false,
        background: c("#ECECEC"), text: c("#000000"), secondaryText: c("#00000080"), selection: c("#0A60FF"),
        selectionText: c("#FFFFFF"), badgeBackground: c("#0000001A"), badgeText: c("#000000B3"),
        accent: c("#0A60FF"), separator: c("#0000001A"))

    public static let systemDark = Theme(
        id: Theme.systemDarkID, name: "System Dark", isBuiltIn: true, usesSystemColors: true, isDark: true,
        background: c("#1E1E1E"), text: c("#FFFFFF"), secondaryText: c("#FFFFFF8C"), selection: c("#0A60FF"),
        selectionText: c("#FFFFFF"), badgeBackground: c("#FFFFFF1F"), badgeText: c("#FFFFFFD9"),
        accent: c("#3B82F7"), separator: c("#FFFFFF1A"))

    public static let catppuccin = Theme(
        id: "catppuccin", name: "Catppuccin", isBuiltIn: true, usesSystemColors: false, isDark: true,
        background: c("#1E1E2E"), text: c("#CDD6F4"), secondaryText: c("#A6ADC8"), selection: c("#45475A"),
        selectionText: c("#CDD6F4"), badgeBackground: c("#313244"), badgeText: c("#BAC2DE"),
        accent: c("#CBA6F7"), separator: c("#313244"))

    public static let dracula = Theme(
        id: "dracula", name: "Dracula", isBuiltIn: true, usesSystemColors: false, isDark: true,
        background: c("#282A36"), text: c("#F8F8F2"), secondaryText: c("#6272A4"), selection: c("#44475A"),
        selectionText: c("#F8F8F2"), badgeBackground: c("#383A4A"), badgeText: c("#F8F8F2"),
        accent: c("#BD93F9"), separator: c("#3B3D4C"))

    public static let gruvbox = Theme(
        id: "gruvbox", name: "Gruvbox", isBuiltIn: true, usesSystemColors: false, isDark: true,
        background: c("#282828"), text: c("#EBDBB2"), secondaryText: c("#A89984"), selection: c("#504945"),
        selectionText: c("#FBF1C7"), badgeBackground: c("#3C3836"), badgeText: c("#D5C4A1"),
        accent: c("#FABD2F"), separator: c("#3C3836"))

    public static let solarizedDark = Theme(
        id: "solarized-dark", name: "Solarized Dark", isBuiltIn: true, usesSystemColors: false, isDark: true,
        background: c("#002B36"), text: c("#93A1A1"), secondaryText: c("#586E75"), selection: c("#073642"),
        selectionText: c("#EEE8D5"), badgeBackground: c("#073642"), badgeText: c("#839496"),
        accent: c("#268BD2"), separator: c("#073642"))

    public static let solarizedLight = Theme(
        id: "solarized-light", name: "Solarized Light", isBuiltIn: true, usesSystemColors: false, isDark: false,
        background: c("#FDF6E3"), text: c("#586E75"), secondaryText: c("#93A1A1"), selection: c("#EEE8D5"),
        selectionText: c("#073642"), badgeBackground: c("#EEE8D5"), badgeText: c("#657B83"),
        accent: c("#268BD2"), separator: c("#EEE8D5"))

    public static let monokai = Theme(
        id: "monokai", name: "Monokai", isBuiltIn: true, usesSystemColors: false, isDark: true,
        background: c("#272822"), text: c("#F8F8F2"), secondaryText: c("#75715E"), selection: c("#49483E"),
        selectionText: c("#F8F8F2"), badgeBackground: c("#3E3D32"), badgeText: c("#E6DB74"),
        accent: c("#A6E22E"), separator: c("#3E3D32"))

    public static let all: [Theme] = [systemLight, systemDark, catppuccin, dracula, gruvbox, solarizedDark, solarizedLight, monokai]

    public static func theme(id: String) -> Theme? { all.first { $0.id == id } }
}

/// Encodes/decodes the user's custom themes.
public enum ThemeCodec {
    public static func encode(_ themes: [Theme]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(themes)) ?? Data("[]".utf8)
    }

    public static func decode(_ data: Data) -> [Theme] {
        (try? JSONDecoder().decode([Theme].self, from: data)) ?? []
    }
}
