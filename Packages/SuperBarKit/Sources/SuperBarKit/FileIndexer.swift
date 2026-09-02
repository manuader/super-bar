import Foundation

/// A directory to crawl and how deep, derived from how much the user works in it.
public struct IndexRoot: Hashable, Sendable {
    public var path: String
    public var maxDepth: Int
    /// Heat at the time the plan was made (used for ordering, not for matching).
    public var heat: Double

    public init(path: String, maxDepth: Int, heat: Double = 0) {
        self.path = path
        self.maxDepth = maxDepth
        self.heat = heat
    }
}

/// Builds the crawl plan and walks it. Pure enough to unit-test against a
/// temporary directory tree.
public enum FileIndexer {
    /// File extensions that are really bundles: indexed as files, never entered.
    public static let bundleExtensions: Set<String> = [
        "app", "xcodeproj", "xcworkspace", "framework", "bundle", "photoslibrary",
        "rtfd", "scptd", "pkg", "playground", "sparklebundle", "kext", "docset",
    ]

    /// Total entries kept in memory. ~200k paths is roughly 25 MB.
    public static let defaultBudget = 200_000

    /// Where to start when the user has no history yet.
    public static func seedRoots(home: String = NSHomeDirectory(), fileManager: FileManager = .default) -> [IndexRoot] {
        let names = ["Desktop", "Documents", "Downloads", "Developer", "Projects", "Code", "Sites", "repos", "src", "Movies", "Music", "Pictures"]
        var roots: [IndexRoot] = [IndexRoot(path: home, maxDepth: 2)]
        for name in names {
            let path = (home as NSString).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            roots.append(IndexRoot(path: path, maxDepth: 4))
        }
        return roots
    }

    /// Merges the seeds with the user's hot directories. Hot roots are crawled
    /// deeply; everything else stays shallow, which is what keeps the index
    /// small and the crawl short.
    public static func plan(heat: WorkspaceHeat, home: String = NSHomeDirectory(), extraRoots: [String] = [], ignore: IgnoreList = .default, fileManager: FileManager = .default) -> [IndexRoot] {
        var byPath: [String: IndexRoot] = [:]
        func add(_ root: IndexRoot) {
            if let existing = byPath[root.path], existing.maxDepth >= root.maxDepth {
                byPath[root.path] = IndexRoot(path: root.path, maxDepth: existing.maxDepth, heat: max(existing.heat, root.heat))
            } else {
                byPath[root.path] = root
            }
        }
        func isIgnored(_ path: String) -> Bool {
            ignore.ignores(path: path, name: (path as NSString).lastPathComponent, isDirectory: true)
        }
        for seed in seedRoots(home: home, fileManager: fileManager) where !isIgnored(seed.path) { add(seed) }
        for path in extraRoots {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            // An explicitly added root is indexed even if a pattern would hide it.
            add(IndexRoot(path: path, maxDepth: 8, heat: heat.score(for: path)))
        }
        let scores = heat.allScores()
        for path in heat.hotDirectories() where !isIgnored(path) {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            let score = scores[path] ?? 0
            // The hotter a directory, the deeper it is worth crawling.
            let depth = score >= 150 ? 10 : (score >= 80 ? 6 : 4)
            add(IndexRoot(path: path, maxDepth: depth, heat: score))
        }
        // Drop roots contained in a hotter ancestor that is already crawled deeper.
        let all = byPath.values.sorted { $0.path.count < $1.path.count }
        var kept: [IndexRoot] = []
        for root in all {
            if let parent = kept.first(where: { root.path.hasPrefix($0.path + "/") }) {
                let remaining = parent.maxDepth - depthBetween(parent.path, root.path)
                if remaining >= root.maxDepth { continue }
            }
            kept.append(root)
        }
        return kept.sorted { a, b in a.heat == b.heat ? a.path < b.path : a.heat > b.heat }
    }

    static func depthBetween(_ ancestor: String, _ descendant: String) -> Int {
        guard descendant.hasPrefix(ancestor) else { return 0 }
        return descendant.dropFirst(ancestor.count).split(separator: "/").count
    }

    public struct Result: Sendable {
        public var directories: [FileEntry]
        public var files: [FileEntry]
        public var hitBudget: Bool
    }

    /// Cancellation flag shared with the caller's thread.
    public final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        public init() {}
        public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    }

    /// Breadth-first crawl so that, when the budget runs out, what survives is
    /// the shallow (and therefore most useful) part of every root.
    ///
    /// Directory contents are listed with their resource keys prefetched, so
    /// each directory costs one bulk syscall instead of one `stat` per child.
    public static func crawl(roots: [IndexRoot],
                             budget: Int = defaultBudget,
                             includeHidden: Bool = false,
                             ignore: IgnoreList = .default,
                             fileManager: FileManager = .default,
                             cancellation: Cancellation? = nil) -> Result {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .nameKey]
        let keySet = Set(keys)
        let options: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]

        var directories: [FileEntry] = []
        var files: [FileEntry] = []
        var seen = Set<String>()
        var hitBudget = false
        var frontier: [(url: URL, path: String, depth: Int, maxDepth: Int)] = []
        for root in roots where seen.insert(root.path).inserted {
            directories.append(FileEntry(path: root.path, isDirectory: true, depth: 0))
            frontier.append((URL(fileURLWithPath: root.path, isDirectory: true), root.path, 0, root.maxDepth))
        }

        var level = 0
        outer: while !frontier.isEmpty {
            var next: [(url: URL, path: String, depth: Int, maxDepth: Int)] = []
            for item in frontier {
                if cancellation?.isCancelled == true { break outer }
                if directories.count + files.count >= budget { hitBudget = true; break outer }
                guard let contents = try? fileManager.contentsOfDirectory(at: item.url, includingPropertiesForKeys: keys, options: options) else { continue }
                for child in contents {
                    if directories.count + files.count >= budget { hitBudget = true; break outer }
                    let values = try? child.resourceValues(forKeys: keySet)
                    if values?.isSymbolicLink == true { continue }        // never follow links: cycles
                    let name = values?.name ?? child.lastPathComponent
                    // `.skipsHiddenFiles` misses dot files such as .DS_Store.
                    if !includeHidden && name.hasPrefix(".") { continue }
                    let path = item.path == "/" ? "/" + name : item.path + "/" + name
                    guard seen.insert(path).inserted else { continue }
                    let isDirectory = values?.isDirectory ?? false
                    let isPackage = (values?.isPackage ?? false) || bundleExtensions.contains((name as NSString).pathExtension.lowercased())
                    // Dependency and build folders are skipped entirely: not
                    // listed as results and never descended into.
                    if ignore.ignores(path: path, name: name, isDirectory: isDirectory && !isPackage) { continue }
                    if isDirectory && !isPackage {
                        directories.append(FileEntry(path: path, isDirectory: true, depth: item.depth + 1))
                        if item.depth + 1 < item.maxDepth {
                            next.append((child, path, item.depth + 1, item.maxDepth))
                        }
                    } else {
                        files.append(FileEntry(path: path, isDirectory: false, depth: item.depth + 1))
                    }
                }
            }
            frontier = next
            level += 1
            if level > 24 { break }
        }
        return Result(directories: directories, files: files, hitBudget: hitBudget)
    }
}
