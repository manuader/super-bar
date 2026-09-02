import Foundation

/// One indexed path. Plain value: the bytes used for matching live in the
/// `FileTable` columns, not here, so iterating the index never touches ARC.
public struct FileEntry: Hashable, Sendable {
    public let path: String
    public let isDirectory: Bool
    public let depth: Int32

    public init(path: String, isDirectory: Bool, depth: Int) {
        self.path = path
        self.isDirectory = isDirectory
        self.depth = Int32(depth)
    }

    public var name: String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        let start = path.index(after: slash)
        return start < path.endIndex ? String(path[start...]) : path
    }

    public var url: URL { URL(fileURLWithPath: path, isDirectory: isDirectory) }

    /// Containing directory with the home folder abbreviated, for subtitles.
    public var displayParent: String { FileEntry.abbreviate((path as NSString).deletingLastPathComponent) }

    public static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// Lowercases ASCII and strips common Latin diacritics, one byte per scalar
    /// so that a byte offset maps to a scalar offset.
    public static func fold<S: StringProtocol>(_ text: S) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if v < 0x80 {
                out.append(UInt8(v >= 65 && v <= 90 ? v + 32 : v))
            } else if let ascii = FileEntry.latinFolding[v] {
                out.append(ascii)
            } else {
                out.append(0x80 | UInt8(truncatingIfNeeded: v))
            }
        }
        return out
    }

    static let latinFolding: [UInt32: UInt8] = {
        var map: [UInt32: UInt8] = [:]
        let groups: [(String, UInt8)] = [
            ("àáâãäåāăą", 97), ("çćĉċč", 99), ("èéêëēĕėęě", 101), ("ìíîïĩīĭįı", 105),
            ("ñńņňŉ", 110), ("òóôõöøōŏő", 111), ("ùúûüũūŭůűų", 117), ("ýÿŷ", 121),
            ("ĝğġģ", 103), ("ĥħ", 104), ("ĵ", 106), ("ķĸ", 107), ("ĺļľŀł", 108),
            ("ŕŗř", 114), ("śŝşš", 115), ("ţťŧ", 116), ("ŵ", 119), ("źżž", 122), ("ďđ", 100),
        ]
        for (letters, ascii) in groups {
            for scalar in letters.unicodeScalars {
                map[scalar.value] = ascii
                for upper in String(scalar).uppercased().unicodeScalars { map[upper.value] = ascii }
            }
        }
        return map
    }()
}

/// A 32-bit presence filter over folded bytes. Rejecting a candidate costs one
/// AND, which is what keeps substring search over 200k entries in single-digit
/// milliseconds.
public enum CharMask {
    /// bits 0–25: a–z · 26: digits · 27: `.` · 28: `-`/`_`/space · 29: everything else.
    @inline(__always)
    public static func bit(_ byte: UInt8) -> UInt32 {
        switch byte {
        case 97...122: return 1 << UInt32(byte - 97)
        case 48...57: return 1 << 26
        case 46: return 1 << 27
        case 45, 95, 32: return 1 << 28
        default: return 1 << 29
        }
    }

    @inline(__always)
    public static func mask<C: Collection>(of bytes: C) -> UInt32 where C.Element == UInt8 {
        var m: UInt32 = 0
        for b in bytes { m |= bit(b) }
        return m
    }
}

/// A query prepared once per keystroke.
public struct FileQuery: Sendable {
    public let text: String
    public let folded: [UInt8]
    public let mask: UInt32

    public init(_ text: String) {
        self.text = text
        folded = FileEntry.fold(text.trimmingCharacters(in: .whitespaces))
        mask = CharMask.mask(of: folded)
    }

    public var isEmpty: Bool { folded.isEmpty }
}

/// How a name matched, best first. The kind dominates the score, so ordering
/// stays easy to reason about and to test.
public enum FileMatchKind: Int, Sendable, Comparable {
    case exact = 0
    case prefix = 1
    case wordBoundary = 2
    case substring = 3
    case subsequence = 4

    public static func < (a: FileMatchKind, b: FileMatchKind) -> Bool { a.rawValue < b.rawValue }
}

public struct FileHit: Sendable {
    public let entry: FileEntry
    public let kind: FileMatchKind
    public let score: Int
    /// UTF-16 range of the matched run inside `entry.name`, when contiguous.
    public let range: NSRange?
}

/// Columnar store of indexed paths: names, presence masks, depths and heat live
/// in flat arrays so the search loop touches only contiguous plain data.
public struct FileTable: Sendable {
    public private(set) var entries: [FileEntry] = []
    /// All folded names concatenated.
    private var folded: [UInt8] = []
    private var offsets: [Int32] = []
    private var lengths: [Int32] = []
    private var masks: [UInt32] = []
    private var heat: [Float] = []

    public init() {}

    public init(entries: [FileEntry]) {
        reserveCapacity(entries.count)
        for entry in entries { append(entry) }
    }

    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }

    public mutating func reserveCapacity(_ n: Int) {
        entries.reserveCapacity(n)
        folded.reserveCapacity(n * 14)
        offsets.reserveCapacity(n)
        lengths.reserveCapacity(n)
        masks.reserveCapacity(n)
        heat.reserveCapacity(n)
    }

    public mutating func append(_ entry: FileEntry) {
        let bytes = FileEntry.fold(entry.name)
        offsets.append(Int32(folded.count))
        lengths.append(Int32(bytes.count))
        masks.append(CharMask.mask(of: bytes))
        folded.append(contentsOf: bytes)
        heat.append(0)
        entries.append(entry)
    }

    /// Recomputes the heat column. Called on the indexing queue whenever the
    /// user's workspace scores change, so searching never walks ancestors.
    public mutating func applyHeat(_ score: (FileEntry) -> Double) {
        guard !entries.isEmpty else { return }
        for i in 0..<entries.count { heat[i] = Float(score(entries[i])) }
    }

    /// Ranked matches, best first. `limit` bounds both the work and the result.
    public func search(_ query: FileQuery, limit: Int = 25) -> [FileHit] {
        guard limit > 0, !entries.isEmpty else { return [] }
        if query.isEmpty { return topByHeat(limit: limit) }

        var best: [FileHit] = []
        best.reserveCapacity(limit + 1)
        var cutoff = Int.min
        let queryMask = query.mask
        let queryCount = query.folded.count

        folded.withUnsafeBufferPointer { name in
            masks.withUnsafeBufferPointer { mask in
                query.folded.withUnsafeBufferPointer { needle in
                    for i in 0..<entries.count {
                        // One AND rejects the vast majority of entries.
                        if queryMask & ~mask[i] != 0 { continue }
                        let length = Int(lengths[i])
                        if length < queryCount { continue }
                        let start = Int(offsets[i])

                        var kind: FileMatchKind
                        var at = -1
                        if let found = FileTable.firstIndex(of: needle, in: name, start: start, length: length) {
                            at = found
                            if found == 0 {
                                kind = length == queryCount ? .exact : .prefix
                            } else {
                                let previous = name[start + found - 1]
                                kind = (previous == 45 || previous == 95 || previous == 46 || previous == 32) ? .wordBoundary : .substring
                            }
                        } else if FileTable.isSubsequence(needle, in: name, start: start, length: length) {
                            kind = .subsequence
                        } else {
                            continue
                        }

                        var score = 10_000
                        score += Int(min(heat[i], 400)) * 6
                        score -= Int(min(entries[i].depth, 12)) * 25
                        score -= kind.rawValue * 1_000
                        score -= min(length - queryCount, 40) * 4
                        if at > 0 { score -= min(at, 20) * 3 }
                        if best.count == limit && score <= cutoff { continue }

                        let entry = entries[i]
                        let range = at < 0 ? nil : FileTable.utf16Range(of: at, count: queryCount, in: entry, foldedLength: length)
                        let hit = FileHit(entry: entry, kind: kind, score: score, range: range)
                        // Insertion into a short sorted buffer beats sorting everything.
                        var j = best.count
                        best.append(hit)
                        while j > 0 && FileTable.precedes(best[j], best[j - 1]) {
                            best.swapAt(j, j - 1)
                            j -= 1
                        }
                        if best.count > limit { best.removeLast() }
                        cutoff = best.count == limit ? best[best.count - 1].score : Int.min
                    }
                }
            }
        }
        return best
    }

    /// What to show for an empty query: the hottest, shallowest entries.
    private func topByHeat(limit: Int) -> [FileHit] {
        var best: [FileHit] = []
        best.reserveCapacity(limit + 1)
        for i in 0..<entries.count {
            guard heat[i] > 0 else { continue }
            let score = 10_000 + Int(min(heat[i], 400)) * 6 - Int(min(entries[i].depth, 12)) * 25
            if best.count == limit, let last = best.last, score <= last.score { continue }
            let hit = FileHit(entry: entries[i], kind: .prefix, score: score, range: nil)
            var j = best.count
            best.append(hit)
            while j > 0 && FileTable.precedes(best[j], best[j - 1]) {
                best.swapAt(j, j - 1)
                j -= 1
            }
            if best.count > limit { best.removeLast() }
        }
        return best
    }

    static func precedes(_ a: FileHit, _ b: FileHit) -> Bool {
        if a.score != b.score { return a.score > b.score }
        if a.entry.depth != b.entry.depth { return a.entry.depth < b.entry.depth }
        return a.entry.path < b.entry.path
    }

    @inline(__always)
    static func firstIndex(of needle: UnsafeBufferPointer<UInt8>, in haystack: UnsafeBufferPointer<UInt8>, start: Int, length: Int) -> Int? {
        guard let first = needle.first else { return 0 }
        let limit = length - needle.count
        if limit < 0 { return nil }
        var i = 0
        while i <= limit {
            if haystack[start + i] == first {
                var j = 1
                while j < needle.count && haystack[start + i + j] == needle[j] { j += 1 }
                if j == needle.count { return i }
            }
            i += 1
        }
        return nil
    }

    @inline(__always)
    static func isSubsequence(_ needle: UnsafeBufferPointer<UInt8>, in haystack: UnsafeBufferPointer<UInt8>, start: Int, length: Int) -> Bool {
        guard !needle.isEmpty else { return true }
        var n = 0
        var i = 0
        while i < length {
            if haystack[start + i] == needle[n] {
                n += 1
                if n == needle.count { return true }
            }
            i += 1
        }
        return false
    }

    /// Folded bytes are one per scalar; for pure-ASCII names that is also the
    /// UTF-16 offset, otherwise the offset is recomputed exactly.
    static func utf16Range(of foldedIndex: Int, count: Int, in entry: FileEntry, foldedLength: Int) -> NSRange {
        let name = entry.name
        if name.utf16.count == foldedLength { return NSRange(location: foldedIndex, length: count) }
        var scalarIndex = 0
        var location = 0
        var length = 0
        for scalar in name.unicodeScalars {
            let width = scalar.utf16.count
            if scalarIndex < foldedIndex { location += width }
            else if scalarIndex < foldedIndex + count { length += width }
            scalarIndex += 1
        }
        return NSRange(location: location, length: length)
    }
}

/// Convenience wrapper for matching a single entry (used by tests and for
/// ad-hoc paths that are not in the index).
public enum FileMatcher {
    public static func match(_ query: FileQuery, _ entry: FileEntry, heat: Double = 0) -> FileHit? {
        var table = FileTable()
        table.append(entry)
        table.applyHeat { _ in heat }
        return table.search(query, limit: 1).first
    }
}

/// An immutable, searchable snapshot of the index. Directories and files are
/// separate tables because the palette always lists folders before files.
public struct FileIndexSnapshot: Sendable {
    public var directories: FileTable
    public var files: FileTable
    public var createdAt: Date
    public var isPartial: Bool

    public init(directories: FileTable = FileTable(), files: FileTable = FileTable(), createdAt: Date = Date(), isPartial: Bool = false) {
        self.directories = directories
        self.files = files
        self.createdAt = createdAt
        self.isPartial = isPartial
    }

    public init(directories: [FileEntry], files: [FileEntry], heat: [String: Double] = [:]) {
        var dirTable = FileTable(entries: directories)
        var fileTable = FileTable(entries: files)
        let resolver = HeatResolver(heat: heat)
        dirTable.applyHeat { resolver.score(for: $0) }
        fileTable.applyHeat { resolver.score(for: $0) }
        self.init(directories: dirTable, files: fileTable)
    }

    public var count: Int { directories.count + files.count }

    public struct Results: Sendable {
        public var directories: [FileHit]
        public var files: [FileHit]
        public var isEmpty: Bool { directories.isEmpty && files.isEmpty }
    }

    /// Ranked directories, then ranked files. `limit` applies to each list.
    public func search(_ query: FileQuery, limit: Int = 25) -> Results {
        Results(directories: directories.search(query, limit: limit), files: files.search(query, limit: limit))
    }
}

/// Turns the workspace heat map into a per-entry score: a path inherits its
/// ancestors' heat, decayed per level, so a rarely visited folder inside a hot
/// project still outranks unrelated ones.
public struct HeatResolver: Sendable {
    public let heat: [String: Double]
    public static let levelDecay = 0.6
    public static let maxLevels = 6

    public init(heat: [String: Double]) { self.heat = heat }

    public func score(for entry: FileEntry) -> Double { score(forPath: entry.path) }

    public func score(forPath path: String) -> Double {
        guard !heat.isEmpty else { return 0 }
        if let own = heat[path] { return own }
        var current = (path as NSString).deletingLastPathComponent
        var decay = HeatResolver.levelDecay
        var levels = 0
        while levels < HeatResolver.maxLevels && current.count > 1 {
            if let value = heat[current] { return value * decay }
            current = (current as NSString).deletingLastPathComponent
            decay *= HeatResolver.levelDecay
            levels += 1
        }
        return 0
    }
}
