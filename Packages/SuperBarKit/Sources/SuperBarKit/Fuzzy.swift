import Foundation

/// Pre-folded text ready for fuzzy matching. Built once per row.
public struct SearchText: Hashable, Sendable {
    public let original: String
    /// Case-folded scalars.
    let scalars: [UInt32]
    /// UTF-16 offset of each scalar in `original` (plus a trailing end offset).
    let utf16Offsets: [Int]
    /// Positional bonus of each scalar (word start, camel hump, …).
    let bonuses: [Int8]

    enum CharClass { case nonWord, lower, upper, digit, other }

    public init(_ text: String) {
        original = text
        var scalars: [UInt32] = []
        var offsets: [Int] = []
        var bonuses: [Int8] = []
        let count = text.unicodeScalars.count
        scalars.reserveCapacity(count)
        offsets.reserveCapacity(count + 1)
        bonuses.reserveCapacity(count)
        var utf16 = 0
        var prevClass = CharClass.nonWord
        for scalar in text.unicodeScalars {
            let cls = CharClass(scalar)
            scalars.append(SearchText.fold(scalar))
            offsets.append(utf16)
            bonuses.append(SearchText.bonus(prev: prevClass, current: cls))
            prevClass = cls
            utf16 += scalar.utf16.count
        }
        offsets.append(utf16)
        self.scalars = scalars
        self.utf16Offsets = offsets
        self.bonuses = bonuses
    }

    public var count: Int { scalars.count }

    static func fold(_ s: Unicode.Scalar) -> UInt32 {
        if s.value < 0x80 {
            if s.value >= 65 && s.value <= 90 { return s.value + 32 }
            return s.value
        }
        return s.properties.lowercaseMapping.unicodeScalars.first?.value ?? s.value
    }

    static func bonus(prev: CharClass, current: CharClass) -> Int8 {
        switch (prev, current) {
        case (.nonWord, .lower), (.nonWord, .upper), (.nonWord, .digit), (.nonWord, .other):
            return FuzzyMatcher.bonusBoundary
        case (.lower, .upper):
            return FuzzyMatcher.bonusCamel
        case (.lower, .digit), (.upper, .digit), (.other, .digit):
            return FuzzyMatcher.bonusCamel
        default:
            return 0
        }
    }

    /// Converts scalar indices into merged UTF-16 ranges in `original`.
    func utf16Ranges(forScalarIndices indices: [Int]) -> [NSRange] {
        var out: [NSRange] = []
        var runStart = -1
        var runEnd = -1
        for i in indices {
            if runStart >= 0 && i == runEnd + 1 {
                runEnd = i
            } else {
                if runStart >= 0 {
                    out.append(NSRange(location: utf16Offsets[runStart], length: utf16Offsets[runEnd + 1] - utf16Offsets[runStart]))
                }
                runStart = i
                runEnd = i
            }
        }
        if runStart >= 0 {
            out.append(NSRange(location: utf16Offsets[runStart], length: utf16Offsets[runEnd + 1] - utf16Offsets[runStart]))
        }
        return out
    }
}

extension SearchText.CharClass {
    init(_ s: Unicode.Scalar) {
        switch s.properties.generalCategory {
        case .lowercaseLetter: self = .lower
        case .uppercaseLetter, .titlecaseLetter: self = .upper
        case .decimalNumber, .letterNumber, .otherNumber: self = .digit
        case .otherLetter, .modifierLetter: self = .other
        default: self = .nonWord
        }
    }
}

/// A single fuzzy match result.
public struct FuzzyMatch: Hashable, Sendable {
    public var score: Int
    /// Scalar indices of the matched characters.
    public var positions: [Int]
    /// UTF-16 ranges in the original string, suitable for `NSAttributedString`.
    public var ranges: [NSRange]
}

/// Reusable DP buffers so that scoring thousands of candidates does not
/// allocate. Not thread-safe: use one per search.
public final class FuzzyScratch {
    fileprivate var capacity = 0
    fileprivate var M: UnsafeMutablePointer<Int>
    fileprivate var H: UnsafeMutablePointer<Int>
    fileprivate var from: UnsafeMutablePointer<Bool>

    public init() {
        capacity = 64 * 8
        M = .allocate(capacity: capacity)
        H = .allocate(capacity: capacity)
        from = .allocate(capacity: capacity)
    }

    deinit {
        M.deallocate(); H.deallocate(); from.deallocate()
    }

    fileprivate func ensure(_ size: Int) {
        guard size > capacity else { return }
        M.deallocate(); H.deallocate(); from.deallocate()
        capacity = max(size, capacity * 2)
        M = .allocate(capacity: capacity)
        H = .allocate(capacity: capacity)
        from = .allocate(capacity: capacity)
    }
}

/// fzf-style fuzzy matcher: Smith–Waterman with affine gaps and positional
/// bonuses. Deterministic and cheap for menu-sized strings.
public enum FuzzyMatcher {
    static let scoreMatch = 16
    static let scoreGapStart = -3
    static let scoreGapExtension = -1
    static let bonusBoundary: Int8 = 8
    static let bonusCamel: Int8 = 7
    static let bonusConsecutive = 4
    static let bonusFirstCharMultiplier = 2
    static let maxTextLength = 512
    static let negInf = Int.min / 4

    public struct Query: Hashable, Sendable {
        let scalars: [UInt32]
        public let original: String
        public init(_ text: String) {
            original = text
            scalars = text.unicodeScalars.filter { !$0.properties.isWhitespace }.map(SearchText.fold)
        }
        public var isEmpty: Bool { scalars.isEmpty }
    }

    /// Returns the best match of `query` in `text`, or nil when the query is
    /// not an ordered subsequence of the text.
    public static func match(_ query: Query, in text: SearchText, scratch: FuzzyScratch? = nil) -> FuzzyMatch? {
        let m = query.scalars.count
        let n = min(text.scalars.count, maxTextLength)
        if m == 0 { return FuzzyMatch(score: 0, positions: [], ranges: []) }
        if m > n { return nil }

        return query.scalars.withUnsafeBufferPointer { q -> FuzzyMatch? in
            text.scalars.withUnsafeBufferPointer { t -> FuzzyMatch? in
                text.bonuses.withUnsafeBufferPointer { bonuses -> FuzzyMatch? in
                    // Cheap subsequence pre-check.
                    var qi = 0
                    for j in 0..<n where t[j] == q[qi] {
                        qi += 1
                        if qi == m { break }
                    }
                    guard qi == m else { return nil }
                    let scratch = scratch ?? FuzzyScratch()
                    scratch.ensure(m * n)
                    let positions = score(q: q, t: t, bonuses: bonuses, m: m, n: n, scratch: scratch)
                    guard let (bestScore, pos) = positions else { return nil }
                    let finalScore = bestScore - min(n, 64) / 8
                    return FuzzyMatch(score: finalScore, positions: pos, ranges: text.utf16Ranges(forScalarIndices: pos))
                }
            }
        }
    }

    private static func score(q: UnsafeBufferPointer<UInt32>, t: UnsafeBufferPointer<UInt32>, bonuses: UnsafeBufferPointer<Int8>, m: Int, n: Int, scratch: FuzzyScratch) -> (Int, [Int])? {
        let M = scratch.M, H = scratch.H, from = scratch.from
        let width = n
        for i in 0..<m {
            let qc = q[i]
            let rowBase = i * width
            let prevBase = (i - 1) * width
            var runningH = negInf
            var runningGapLength = 0
            for j in 0..<n {
                let idx = rowBase + j
                var score = negInf
                var consecutive = false
                if t[j] == qc && j >= i {
                    let bonus = Int(bonuses[j])
                    if i == 0 {
                        score = scoreMatch + bonus * bonusFirstCharMultiplier
                        if j == 0 { score += Int(bonusBoundary) }
                    } else {
                        let cont = M[prevBase + j - 1]
                        if cont > negInf {
                            score = cont + scoreMatch + max(bonus, bonusConsecutive)
                            consecutive = true
                        }
                        let gapped = H[prevBase + j - 1]
                        if gapped > negInf {
                            let s2 = gapped + scoreMatch + bonus
                            if s2 > score { score = s2; consecutive = false }
                        }
                    }
                }
                M[idx] = score
                from[idx] = consecutive
                var h = negInf
                if runningH > negInf {
                    h = runningH + (runningGapLength == 0 ? scoreGapStart : scoreGapExtension)
                    runningGapLength += 1
                }
                if score >= h {
                    h = score
                    if score > negInf { runningGapLength = 0 }
                }
                H[idx] = h
                runningH = h
            }
        }

        let lastBase = (m - 1) * width
        var bestScore = negInf
        var bestJ = -1
        for j in 0..<n where M[lastBase + j] > bestScore {
            bestScore = M[lastBase + j]
            bestJ = j
        }
        guard bestJ >= 0 else { return nil }

        var positions = [Int](repeating: 0, count: m)
        var j = bestJ
        var i = m - 1
        while i >= 0 {
            positions[i] = j
            if i == 0 { break }
            if from[i * width + j] {
                j -= 1
            } else {
                let prevBase = (i - 1) * width
                let target = H[prevBase + j - 1]
                var k = j - 1
                var chosen = j - 1
                while k >= 0 {
                    let v = M[prevBase + k]
                    if v > negInf {
                        let gap = (j - 1) - k
                        let penalised = gap == 0 ? v : v + scoreGapStart + scoreGapExtension * (gap - 1)
                        if penalised == target { chosen = k; break }
                    }
                    k -= 1
                }
                j = chosen
            }
            i -= 1
        }
        return (bestScore, positions)
    }
}

// MARK: - Candidates and list search

/// Something the palette can search: a menu item or a script.
public struct SearchCandidate<Payload: Sendable>: Sendable {
    public var payload: Payload
    /// Primary text (display title, e.g. "Font › Bold").
    public var title: SearchText
    /// Optional full path text used as a fallback ("Format › Font › Bold").
    public var pathText: SearchText?
    public var frecency: Double
    public var originalOrder: Int

    public init(payload: Payload, title: String, pathText: String? = nil, frecency: Double = 0, originalOrder: Int) {
        self.payload = payload
        self.title = SearchText(title)
        self.pathText = pathText.map(SearchText.init)
        self.frecency = frecency
        self.originalOrder = originalOrder
    }
}

public struct SearchHit<Payload: Sendable>: Sendable {
    public var payload: Payload
    public var score: Int
    /// UTF-16 ranges in the candidate's title to underline.
    public var titleRanges: [NSRange]
    public var frecency: Double
}

public enum ListSearch {
    static let pathPenalty = 24
    static let frecencyWeight = 0.35

    /// Fuzzy-filters candidates and sorts them by relevance: score, then
    /// frecency, then title length, then original order.
    public static func search<P>(_ query: FuzzyMatcher.Query, in candidates: [SearchCandidate<P>]) -> [SearchHit<P>] {
        if query.isEmpty {
            return candidates.map { SearchHit(payload: $0.payload, score: 0, titleRanges: [], frecency: $0.frecency) }
        }
        var hits: [(hit: SearchHit<P>, length: Int, order: Int)] = []
        hits.reserveCapacity(candidates.count / 4 + 1)
        let scratch = FuzzyScratch()
        for c in candidates {
            if let m = FuzzyMatcher.match(query, in: c.title, scratch: scratch) {
                hits.append((SearchHit(payload: c.payload, score: m.score, titleRanges: m.ranges, frecency: c.frecency), c.title.count, c.originalOrder))
            } else if let path = c.pathText, let m = FuzzyMatcher.match(query, in: path, scratch: scratch) {
                let offset = path.original.utf16.count - c.title.original.utf16.count
                let ranges = m.ranges.compactMap { r -> NSRange? in
                    guard r.location >= offset else { return nil }
                    return NSRange(location: r.location - offset, length: r.length)
                }
                hits.append((SearchHit(payload: c.payload, score: m.score - pathPenalty, titleRanges: ranges, frecency: c.frecency), c.title.count, c.originalOrder))
            }
        }
        hits.sort { a, b in
            let sa = Double(a.hit.score) + a.hit.frecency * frecencyWeight
            let sb = Double(b.hit.score) + b.hit.frecency * frecencyWeight
            if sa != sb { return sa > sb }
            if a.length != b.length { return a.length < b.length }
            return a.order < b.order
        }
        return hits.map(\.hit)
    }
}

// MARK: - Outline search

public struct OutlineSearchResult: Sendable {
    /// Pruned copy of the menu forest containing only relevant nodes.
    public var roots: [MenuNode]
    /// Containers that should be expanded because they hold matches.
    public var expanded: Set<MenuNodeID>
    /// Node that should be selected initially (best score).
    public var bestMatch: MenuNodeID?
    /// Underline ranges per matched node (UTF-16, in `title`).
    public var ranges: [MenuNodeID: [NSRange]]
}

public enum OutlineSearch {
    /// Filters a menu forest keeping the hierarchy: a node survives when it
    /// matches, or when any descendant matches. Children of a matching
    /// container are all kept (so "Font" shows everything inside Font) but
    /// only containers holding matches are expanded.
    public static func search(_ query: FuzzyMatcher.Query, in roots: [MenuNode]) -> OutlineSearchResult {
        if query.isEmpty {
            return OutlineSearchResult(roots: roots, expanded: [], bestMatch: nil, ranges: [:])
        }
        var expanded = Set<MenuNodeID>()
        var ranges: [MenuNodeID: [NSRange]] = [:]
        var best: (id: MenuNodeID, score: Int)? = nil
        let scratch = FuzzyScratch()

        func visit(_ node: MenuNode, ancestorMatched: Bool) -> MenuNode? {
            if node.isSeparator { return ancestorMatched ? node : nil }
            let selfMatch = FuzzyMatcher.match(query, in: SearchText(node.title), scratch: scratch)
            if let m = selfMatch {
                ranges[node.id] = m.ranges
                let effective = node.isContainer ? m.score - 8 : m.score
                if best == nil || effective > best!.score { best = (node.id, effective) }
            }
            if node.children.isEmpty {
                return (selfMatch != nil || ancestorMatched) ? node : nil
            }
            let keepAll = selfMatch != nil || ancestorMatched
            var kept: [MenuNode] = []
            var containsMatch = false
            for child in node.children {
                if let c = visit(child, ancestorMatched: keepAll) {
                    kept.append(c)
                    if ranges[c.id] != nil || expanded.contains(c.id) { containsMatch = true }
                }
            }
            if !keepAll && !containsMatch && kept.isEmpty { return nil }
            var copy = node
            copy.children = kept
            if containsMatch { expanded.insert(node.id) }
            return copy
        }

        let pruned = roots.compactMap { visit($0, ancestorMatched: false) }
        return OutlineSearchResult(roots: pruned, expanded: expanded, bestMatch: best?.id, ranges: ranges)
    }
}
