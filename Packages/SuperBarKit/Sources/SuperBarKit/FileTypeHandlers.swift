import Foundation

/// Which application opens a given kind of file. Chosen once, then reused.
public struct FileHandlerChoice: Codable, Hashable, Sendable {
    /// nil means "whatever the system default is at the time".
    public var applicationPath: String?
    public var bundleIdentifier: String?
    public var chosenAt: Date

    public init(applicationPath: String?, bundleIdentifier: String?, chosenAt: Date = Date()) {
        self.applicationPath = applicationPath
        self.bundleIdentifier = bundleIdentifier
        self.chosenAt = chosenAt
    }

    public static let systemDefault = FileHandlerChoice(applicationPath: nil, bundleIdentifier: nil)
    public var usesSystemDefault: Bool { applicationPath == nil }
    public var applicationURL: URL? { applicationPath.map { URL(fileURLWithPath: $0) } }
    public var applicationName: String? {
        applicationPath.map { ($0 as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "") }
    }
}

/// Maps a file to the app that should open it, keyed by extension. Extensions
/// are matched case-insensitively; files without one are keyed by "".
public struct FileTypeHandlers: Codable, Hashable, Sendable {
    public private(set) var choices: [String: FileHandlerChoice]

    public init(choices: [String: FileHandlerChoice] = [:]) {
        self.choices = choices
    }

    /// The key used for a path: its lowercased extension, or "" when it has none.
    public static func key(for path: String) -> String {
        (path as NSString).pathExtension.lowercased()
    }

    public func choice(for path: String) -> FileHandlerChoice? {
        choices[FileTypeHandlers.key(for: path)]
    }

    public func hasChoice(for path: String) -> Bool {
        choices[FileTypeHandlers.key(for: path)] != nil
    }

    public mutating func set(_ choice: FileHandlerChoice, for path: String) {
        choices[FileTypeHandlers.key(for: path)] = choice
    }

    public mutating func remove(for key: String) {
        choices[key.lowercased()] = nil
    }

    public mutating func removeAll() { choices.removeAll() }

    /// Sorted for display: named types first, then the extension-less entry.
    public var sortedKeys: [String] {
        choices.keys.sorted { a, b in
            if a.isEmpty != b.isEmpty { return !a.isEmpty }
            return a < b
        }
    }

    /// How the type is described in the UI ("PDF documents", "Files without an extension").
    public static func describe(_ key: String) -> String {
        key.isEmpty ? "Files without an extension" : ".\(key) files"
    }
}
