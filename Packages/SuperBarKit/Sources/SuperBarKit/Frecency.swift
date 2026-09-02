import Foundation

/// One remembered activation target.
public struct RecentEntry: Codable, Hashable, Sendable {
    public var appKey: String
    public var titlePath: [String]
    public var indexPath: [Int]
    /// Most recent uses, newest first (capped).
    public var uses: [Date]
    public var isScript: Bool

    public init(appKey: String, titlePath: [String], indexPath: [Int], uses: [Date], isScript: Bool = false) {
        self.appKey = appKey
        self.titlePath = titlePath
        self.indexPath = indexPath
        self.uses = uses
        self.isScript = isScript
    }

    /// Frecency: recent uses weigh more than old ones.
    public func score(now: Date = Date()) -> Double {
        var total = 0.0
        for date in uses {
            let age = now.timeIntervalSince(date)
            switch age {
            case ..<3_600: total += 100
            case ..<86_400: total += 80
            case ..<604_800: total += 60
            case ..<2_592_000: total += 30
            default: total += 10
            }
        }
        return total
    }
}

/// Remembers activated items per application and ranks them by frecency.
/// Thread-safe; persistence is debounced.
public final class RecentsStore: @unchecked Sendable {
    public static let maxUsesPerEntry = 20
    public static let maxEntriesPerApp = 200

    private let lock = NSLock()
    private var entries: [RecentEntry]
    private let fileURL: URL?
    private var saveWorkItem: DispatchWorkItem?
    private let queue = DispatchQueue(label: "com.manuader.SuperBar.recents", qos: .utility)

    public init(fileURL: URL?) {
        self.fileURL = fileURL
        if let url = fileURL, let data = try? Data(contentsOf: url), !data.isEmpty {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            entries = (try? decoder.decode([RecentEntry].self, from: data)) ?? []
        } else {
            entries = []
        }
    }

    /// In-memory store for tests.
    public convenience init() { self.init(fileURL: nil) }

    public static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("SuperBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("recents.json")
    }

    // MARK: Recording

    public func record(appKey: String, titlePath: [String], indexPath: [Int], isScript: Bool = false, at date: Date = Date()) {
        lock.lock()
        if let i = entries.firstIndex(where: { e in
            e.appKey == appKey && e.isScript == isScript &&
                (e.titlePath == titlePath || (!isScript && e.indexPath == indexPath && e.titlePath.first == titlePath.first))
        }) {
            var e = entries[i]
            e.titlePath = titlePath      // adopt the current (possibly dynamic) title
            e.indexPath = indexPath
            e.uses.insert(date, at: 0)
            if e.uses.count > RecentsStore.maxUsesPerEntry {
                e.uses.removeLast(e.uses.count - RecentsStore.maxUsesPerEntry)
            }
            entries[i] = e
        } else {
            entries.append(RecentEntry(appKey: appKey, titlePath: titlePath, indexPath: indexPath, uses: [date], isScript: isScript))
            let forApp = entries.enumerated().filter { $0.element.appKey == appKey }
            if forApp.count > RecentsStore.maxEntriesPerApp,
               let victim = forApp.min(by: { $0.element.score(now: date) < $1.element.score(now: date) }) {
                entries.remove(at: victim.offset)
            }
        }
        lock.unlock()
        scheduleSave()
    }

    public func clear(appKey: String? = nil) {
        lock.lock()
        if let key = appKey { entries.removeAll { $0.appKey == key } } else { entries.removeAll() }
        lock.unlock()
        scheduleSave()
    }

    // MARK: Querying

    /// Frecency score of a menu node (0 when never used). Matches by title
    /// path, falling back to index path under the same menu bar item so that
    /// items with dynamic titles ("Undo Typing") keep their history.
    public func score(appKey: String, titlePath: [String], indexPath: [Int], now: Date = Date()) -> Double {
        lock.lock(); defer { lock.unlock() }
        if let e = entries.first(where: { $0.appKey == appKey && !$0.isScript && $0.titlePath == titlePath }) {
            return e.score(now: now)
        }
        if let e = entries.first(where: { $0.appKey == appKey && !$0.isScript && $0.indexPath == indexPath && $0.titlePath.first == titlePath.first }) {
            return e.score(now: now)
        }
        return 0
    }

    public func scriptScore(appKey: String, title: String, now: Date = Date()) -> Double {
        lock.lock(); defer { lock.unlock() }
        return entries.first(where: { $0.appKey == appKey && $0.isScript && $0.titlePath == [title] })?.score(now: now) ?? 0
    }

    /// Entries for an app ordered by frecency, best first.
    public func top(appKey: String, limit: Int = 8, now: Date = Date()) -> [RecentEntry] {
        lock.lock(); defer { lock.unlock() }
        return entries
            .filter { $0.appKey == appKey }
            .sorted { a, b in
                let sa = a.score(now: now), sb = b.score(now: now)
                if sa != sb { return sa > sb }
                return (a.uses.first ?? .distantPast) > (b.uses.first ?? .distantPast)
            }
            .prefix(limit)
            .map { $0 }
    }

    /// Precomputed scores for one app, for hot search paths.
    public func index(appKey: String, now: Date = Date()) -> FrecencyIndex {
        lock.lock(); defer { lock.unlock() }
        var byTitle: [[String]: Double] = [:]
        var byIndex: [FrecencyIndex.IndexKey: Double] = [:]
        var scripts: [String: Double] = [:]
        for e in entries where e.appKey == appKey {
            let score = e.score(now: now)
            if e.isScript {
                if let title = e.titlePath.first { scripts[title] = score }
            } else {
                byTitle[e.titlePath] = score
                if let top = e.titlePath.first { byIndex[FrecencyIndex.IndexKey(top: top, indexPath: e.indexPath)] = score }
            }
        }
        return FrecencyIndex(byTitle: byTitle, byIndex: byIndex, scripts: scripts)
    }

    public var allEntries: [RecentEntry] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }

    // MARK: Persistence

    private func scheduleSave() {
        guard fileURL != nil else { return }
        lock.lock()
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWorkItem = item
        lock.unlock()
        queue.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    public func saveNow() {
        guard let url = fileURL else { return }
        lock.lock()
        let snapshot = entries
        lock.unlock()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(snapshot) {
            try? data.write(to: url, options: .atomic)
        }
    }
}


/// Immutable lookup table of frecency scores for one application.
public struct FrecencyIndex: Sendable {
    public struct IndexKey: Hashable, Sendable {
        public var top: String
        public var indexPath: [Int]
    }
    public static let empty = FrecencyIndex(byTitle: [:], byIndex: [:], scripts: [:])

    var byTitle: [[String]: Double]
    var byIndex: [IndexKey: Double]
    var scripts: [String: Double]

    public var isEmpty: Bool { byTitle.isEmpty && scripts.isEmpty }

    /// Same fallback rule as `RecentsStore.score`: title path, then index path
    /// under the same menu bar item.
    public func score(titlePath: [String], indexPath: [Int]) -> Double {
        if let s = byTitle[titlePath] { return s }
        if let top = titlePath.first, let s = byIndex[IndexKey(top: top, indexPath: indexPath)] { return s }
        return 0
    }

    public func scriptScore(title: String) -> Double { scripts[title] ?? 0 }
}
