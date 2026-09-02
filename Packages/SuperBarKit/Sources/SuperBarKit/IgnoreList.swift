import Foundation

/// Folders and files the index never looks at, written like a `.gitignore`.
///
/// Syntax, one pattern per line:
/// - `name` matches any file or folder with that name, at any depth
/// - `name/` matches folders only
/// - `*.log` glob patterns (fnmatch) are supported
/// - `/Users/me/big` matches one exact location and everything inside it
/// - `!pattern` puts something back that an earlier line excluded
/// - `#` starts a comment
///
/// Later lines win, as in `.gitignore`.
public struct IgnoreList: Sendable, Equatable {
    public struct Rule: Sendable, Equatable {
        public var pattern: String
        public var isNegated: Bool
        public var directoriesOnly: Bool
        /// Absolute patterns match a full path (and its descendants), not a name.
        public var isAbsolute: Bool
    }

    public private(set) var rules: [Rule]
    public var isEmpty: Bool { rules.isEmpty }

    public init(text: String) {
        var rules: [Rule] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            var negated = false
            if line.hasPrefix("!") {
                negated = true
                line.removeFirst()
                line = line.trimmingCharacters(in: .whitespaces)
            }
            var directoriesOnly = false
            while line.hasSuffix("/") {
                directoriesOnly = true
                line.removeLast()
            }
            guard !line.isEmpty else { continue }
            var absolute = false
            if line.hasPrefix("~/") {
                line = NSHomeDirectory() + line.dropFirst(1)
                absolute = true
            } else if line.hasPrefix("/") {
                absolute = true
            }
            rules.append(Rule(pattern: line, isNegated: negated, directoriesOnly: directoriesOnly, isAbsolute: absolute))
        }
        self.rules = rules
    }

    public static let `default` = IgnoreList(text: defaultText)

    /// Whether this path is excluded. Later rules win.
    public func ignores(path: String, name: String, isDirectory: Bool) -> Bool {
        var ignored = false
        for rule in rules {
            if rule.directoriesOnly && !isDirectory { continue }
            let matches: Bool
            if rule.isAbsolute {
                matches = path == rule.pattern || path.hasPrefix(rule.pattern + "/")
            } else if rule.pattern.contains("*") || rule.pattern.contains("?") || rule.pattern.contains("[") {
                matches = fnmatch(rule.pattern, name, 0) == 0
            } else {
                matches = name == rule.pattern
            }
            if matches { ignored = !rule.isNegated }
        }
        return ignored
    }

    /// The list shipped with SuperBar: dependency folders, build output and caches.
    public static let defaultText = """
    # Folders and files SuperBar never indexes, written like a .gitignore.
    #   name        any file or folder with that name, at any depth
    #   name/       folders only
    #   *.log       glob patterns
    #   /full/path  one exact location
    #   !pattern    puts something back
    # Later lines win.

    # Version control
    .git/
    .svn/
    .hg/
    .jj/

    # JavaScript and TypeScript dependencies
    node_modules/
    bower_components/
    .yarn/
    .pnpm-store/
    .next/
    .nuxt/
    .svelte-kit/
    .turbo/
    .parcel-cache/
    .angular/

    # Apple and Swift
    DerivedData/
    .build/
    .swiftpm/
    Pods/
    Carthage/
    *.xcuserdatad

    # Java, Kotlin, Android
    .gradle/
    .m2/
    target/
    .idea/
    captures/

    # Python
    __pycache__/
    .venv/
    venv/
    .virtualenvs/
    site-packages/
    .tox/
    .mypy_cache/
    .pytest_cache/
    .ruff_cache/
    .ipynb_checkpoints/

    # Rust, Go, Ruby, PHP, Elixir
    .cargo/
    .rustup/
    vendor/
    Godeps/
    .bundle/
    _build/
    deps/

    # Build output and caches
    build/
    dist/
    out/
    .cache/
    .caches/
    .terraform/
    .docker/
    .gem/
    .npm/
    .nvm/
    .pub-cache/
    .nuget/
    .cocoapods/
    .sonar/

    # Big or private system folders
    Library/
    .Trash/
    .local/
    .cursor/
    .vscode-server/
    .DS_Store
    """
}
