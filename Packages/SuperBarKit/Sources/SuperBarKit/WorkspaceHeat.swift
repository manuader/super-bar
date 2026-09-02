import Foundation

/// Tracks which directories the user actually works in, so the indexer can
/// spend its budget where it pays off: a folder the user opens raises the heat
/// of its whole ancestor chain, which is what makes a rarely-visited
/// subdirectory of a hot project rank (and stay indexed) while an untouched
/// sibling project does not.
public final class WorkspaceHeat: @unchecked Sendable {
    /// Points added to the directory that was opened.
    public static let directHeat = 100.0
    /// Each ancestor level receives this fraction of the level below it.
    public static let ancestorDecay = 0.5
    /// Heat halves every two weeks of disuse.
    public static let halfLife: TimeInterval = 14 * 86_400
    public static let maxEntries = 400

    private let lock = NSLock()
    private var scores: [String: Double] = [:]
    private var updatedAt = Date()
    private let fileURL: URL?
    private var saveWorkItem: DispatchWorkItem?
    private let queue = DispatchQueue(label: "com.manuader.SuperBar.heat", qos: .utility)
    public private(set) var version = 0

    public init(fileURL: URL?) {
        self.fileURL = fileURL
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        scores = stored.scores
        updatedAt = stored.updatedAt
        applyDecay(now: Date())
    }

    public convenience init() { self.init(fileURL: nil) }

    public static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("SuperBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("workspaces.json")
    }

    private struct Stored: Codable {
        var scores: [String: Double]
        var updatedAt: Date
    }

    // MARK: Recording

    /// Records that the user opened `path`. Files credit their parent folder.
    public func record(path: String, isDirectory: Bool, now: Date = Date()) {
        let directory = isDirectory ? path : (path as NSString).deletingLastPathComponent
        guard directory.count > 1 else { return }
        lock.lock()
        applyDecayLocked(now: now)
        var current = directory
        var points = WorkspaceHeat.directHeat
        let home = NSHomeDirectory()
        var levels = 0
        while current.count > 1 && levels < 8 {
            scores[current, default: 0] += points
            if current == home { break }
            current = (current as NSString).deletingLastPathComponent
            points *= WorkspaceHeat.ancestorDecay
            levels += 1
            if points < 1 { break }
        }
        evictLocked()
        version &+= 1
        lock.unlock()
        scheduleSave()
    }

    public func clear() {
        lock.lock()
        scores.removeAll()
        version &+= 1
        lock.unlock()
        scheduleSave()
    }

    public func forget(path: String) {
        lock.lock()
        scores[path] = nil
        version &+= 1
        lock.unlock()
        scheduleSave()
    }

    // MARK: Reading

    public func allScores(now: Date = Date()) -> [String: Double] {
        lock.lock(); defer { lock.unlock() }
        applyDecayLocked(now: now)
        return scores
    }

    /// Reading applies any pending time decay first, so scores are current even
    /// if the app has been running for days.
    public func score(for path: String, now: Date = Date()) -> Double {
        lock.lock(); defer { lock.unlock() }
        applyDecayLocked(now: now)
        return scores[path] ?? 0
    }

    /// Directories worth crawling deeply, hottest first.
    public func hotDirectories(minimum: Double = 40, limit: Int = 12, now: Date = Date()) -> [String] {
        lock.lock(); defer { lock.unlock() }
        applyDecayLocked(now: now)
        return scores
            .filter { $0.value >= minimum }
            .sorted { a, b in a.value == b.value ? a.key < b.key : a.value > b.value }
            .prefix(limit)
            .map(\.key)
    }

    // MARK: Decay and persistence

    private func applyDecay(now: Date) {
        lock.lock(); applyDecayLocked(now: now); lock.unlock()
    }

    private func applyDecayLocked(now: Date) {
        let elapsed = now.timeIntervalSince(updatedAt)
        guard elapsed > 3_600 else { return }
        let factor = pow(0.5, elapsed / WorkspaceHeat.halfLife)
        guard factor < 0.999 else { updatedAt = now; return }
        for (key, value) in scores {
            let decayed = value * factor
            if decayed < 1 { scores[key] = nil } else { scores[key] = decayed }
        }
        updatedAt = now
    }

    private func evictLocked() {
        guard scores.count > WorkspaceHeat.maxEntries else { return }
        let keep = scores.sorted { $0.value > $1.value }.prefix(WorkspaceHeat.maxEntries)
        scores = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }

    private func scheduleSave() {
        guard fileURL != nil else { return }
        lock.lock()
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWorkItem = item
        lock.unlock()
        queue.asyncAfter(deadline: .now() + 1, execute: item)
    }

    public func saveNow() {
        guard let fileURL else { return }
        lock.lock()
        let stored = Stored(scores: scores, updatedAt: updatedAt)
        lock.unlock()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(stored) { try? data.write(to: fileURL, options: .atomic) }
    }
}
