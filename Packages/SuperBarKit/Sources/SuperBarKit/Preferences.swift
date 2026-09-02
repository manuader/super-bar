import Foundation
import Combine

public enum BrowsingMode: Int, Codable, CaseIterable, Sendable {
    case list = 0
    case outline = 1
}

public enum PreferredScreen: Int, Codable, CaseIterable, Sendable {
    case withMouse = 0
    case withKeyboardFocus = 1
    case main = 2
}

public enum RowTextSize: Int, Codable, CaseIterable, Sendable {
    case regular = 0
    case large = 1
    case extraLarge = 2

    public var pointDelta: Double {
        switch self {
        case .regular: return 0
        case .large: return 1
        case .extraLarge: return 2
        }
    }
}

public struct HotKey: Codable, Hashable, Sendable {
    public var keyCode: UInt32
    /// Carbon modifier mask (cmdKey 256, shiftKey 512, optionKey 2048, controlKey 4096).
    public var carbonModifiers: UInt32

    public init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    /// ⌃Space
    public static let `default` = HotKey(keyCode: 49, carbonModifiers: 4096)
}

/// Typed, observable access to UserDefaults. UI code binds to it directly.
public final class Preferences: ObservableObject {
    public static let shared = Preferences(defaults: .standard)
    public static let didChangeNotification = Notification.Name("SuperBar.PreferencesDidChange")

    public let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    // MARK: General
    @Stored("hotKey", default: HotKey.default) public var hotKey: HotKey
    @Stored("hotKeyEnabled", default: true) public var hotKeyEnabled: Bool
    @Stored("globalShortcutExcludedApps", default: [String]()) public var globalShortcutExcludedApps: [String]
    @Stored("showMenuBarExtra", default: true) public var showMenuBarExtra: Bool
    @Stored("preferredScreen", default: PreferredScreen.withMouse) public var preferredScreen: PreferredScreen
    @Stored("clearSearchStateImmediately", default: false) public var clearSearchStateImmediately: Bool
    @Stored("didOnboard", default: false) public var didOnboard: Bool

    // MARK: Appearance
    @Stored("selectedLightTheme", default: Theme.systemLightID) public var selectedLightTheme: String
    @Stored("selectedDarkTheme", default: Theme.systemDarkID) public var selectedDarkTheme: String
    @Stored("customThemes", default: [Theme]()) public var customThemes: [Theme]
    @Stored("rowTextSize", default: RowTextSize.regular) public var rowTextSize: RowTextSize
    @Stored("showSubtitles", default: true) public var showSubtitles: Bool
    @Stored("showCountBadge", default: true) public var showCountBadge: Bool
    @Stored("windowWidth", default: 640.0) public var windowWidth: Double
    @Stored("windowOriginXFraction", default: 0.5) public var windowOriginXFraction: Double
    @Stored("windowOriginYFraction", default: 0.22) public var windowOriginYFraction: Double
    @Stored("settingsWindowFloats", default: false) public var settingsWindowFloats: Bool

    // MARK: Behaviour
    @Stored("browsingMode", default: BrowsingMode.list) public var browsingMode: BrowsingMode
    @Stored("menuBarRules", default: [Rule]()) public var rules: [Rule]
    @Stored("recentsLimit", default: 5) public var recentsLimit: Int

    /// All selectable themes: built-ins plus custom ones.
    public var allThemes: [Theme] { BuiltInThemes.all + customThemes }

    public func theme(id: String) -> Theme? { allThemes.first { $0.id == id } }

    public func resetWindowPosition() {
        windowOriginXFraction = 0.5
        windowOriginYFraction = 0.22
    }
}

/// Property wrapper persisting Codable values in UserDefaults and publishing
/// changes through the enclosing `Preferences` object.
@propertyWrapper
public struct Stored<Value: Codable> {
    public let key: String
    private let defaultValue: Value

    public init(_ key: String, default defaultValue: Value) {
        self.key = key
        self.defaultValue = defaultValue
    }

    @available(*, unavailable, message: "Stored is only usable inside Preferences")
    public var wrappedValue: Value {
        get { fatalError() }
        set { fatalError() }
    }

    public static subscript(
        _enclosingInstance instance: Preferences,
        wrapped wrappedKeyPath: ReferenceWritableKeyPath<Preferences, Value>,
        storage storageKeyPath: ReferenceWritableKeyPath<Preferences, Stored<Value>>
    ) -> Value {
        get {
            instance[keyPath: storageKeyPath].read(from: instance.defaults)
        }
        set {
            let wrapper = instance[keyPath: storageKeyPath]
            instance.objectWillChange.send()
            wrapper.write(newValue, to: instance.defaults)
            NotificationCenter.default.post(name: Preferences.didChangeNotification, object: instance, userInfo: ["key": wrapper.key])
        }
    }

    func read(from defaults: UserDefaults) -> Value {
        guard let object = defaults.object(forKey: key) else { return defaultValue }
        if let v = object as? Value, !(object is Data) { return v }
        if let raw = object as? Int, let type = Value.self as? any RawRepresentable.Type,
           let v = Stored.makeRaw(type, raw) as? Value {
            return v
        }
        if let data = object as? Data, let v = try? JSONDecoder().decode(Value.self, from: data) { return v }
        return defaultValue
    }

    func write(_ value: Value, to defaults: UserDefaults) {
        switch value {
        case let v as Bool: defaults.set(v, forKey: key)
        case let v as Int: defaults.set(v, forKey: key)
        case let v as Double: defaults.set(v, forKey: key)
        case let v as String: defaults.set(v, forKey: key)
        case let v as [String]: defaults.set(v, forKey: key)
        default:
            if let raw = value as? any RawRepresentable, let int = raw.rawValue as? Int {
                defaults.set(int, forKey: key)
            } else if let data = try? JSONEncoder().encode(value) {
                defaults.set(data, forKey: key)
            }
        }
    }

    private static func makeRaw(_ type: any RawRepresentable.Type, _ raw: Int) -> Any? {
        func make<T: RawRepresentable>(_: T.Type) -> Any? {
            guard let r = raw as? T.RawValue else { return nil }
            return T(rawValue: r)
        }
        return make(type)
    }
}
