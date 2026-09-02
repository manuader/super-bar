import XCTest
@testable import SuperBarKit

final class FuzzyTests: XCTestCase {
    func q(_ s: String) -> FuzzyMatcher.Query { FuzzyMatcher.Query(s) }

    func testSubsequenceMatchesAndNonMatches() {
        XCTAssertNotNil(FuzzyMatcher.match(q("bld"), in: SearchText("Bold")))
        XCTAssertNotNil(FuzzyMatcher.match(q("nn"), in: SearchText("New Note")))
        XCTAssertNil(FuzzyMatcher.match(q("xyz"), in: SearchText("Bold")))
        XCTAssertNil(FuzzyMatcher.match(q("boldx"), in: SearchText("Bold")))
        XCTAssertEqual(FuzzyMatcher.match(q(""), in: SearchText("Bold"))?.score, 0)
    }

    func testCaseAndDiacriticsFolding() {
        XCTAssertNotNil(FuzzyMatcher.match(q("SETTINGS"), in: SearchText("Settings…")))
        XCTAssertNotNil(FuzzyMatcher.match(q("émoji"), in: SearchText("Émoji & Symbols")))
    }

    func testRangesUnderlineMatchedCharacters() throws {
        let m = try XCTUnwrap(FuzzyMatcher.match(q("nn"), in: SearchText("New Note")))
        XCTAssertEqual(m.positions, [0, 4])
        XCTAssertEqual(m.ranges, [NSRange(location: 0, length: 1), NSRange(location: 4, length: 1)])

        let c = try XCTUnwrap(FuzzyMatcher.match(q("bold"), in: SearchText("Bold")))
        XCTAssertEqual(c.ranges, [NSRange(location: 0, length: 4)])
    }

    func testWordBoundaryAndPrefixBeatScatteredMatches() throws {
        let prefix = try XCTUnwrap(FuzzyMatcher.match(q("bold"), in: SearchText("Bold")))
        let inside = try XCTUnwrap(FuzzyMatcher.match(q("bold"), in: SearchText("Unbolded text")))
        XCTAssertGreaterThan(prefix.score, inside.score)

        let initials = try XCTUnwrap(FuzzyMatcher.match(q("nn"), in: SearchText("New Note")))
        let scattered = try XCTUnwrap(FuzzyMatcher.match(q("nn"), in: SearchText("Unknown banner")))
        XCTAssertGreaterThan(initials.score, scattered.score)
    }

    func testConsecutiveRunsPreferred() throws {
        // "sel" in "Select All" should be contiguous 0...2, not s-e-l scattered.
        let m = try XCTUnwrap(FuzzyMatcher.match(q("sel"), in: SearchText("Select All")))
        XCTAssertEqual(m.positions, [0, 1, 2])
        let m2 = try XCTUnwrap(FuzzyMatcher.match(q("fnd"), in: SearchText("Find and Replace…")))
        XCTAssertEqual(m2.positions.first, 0)
    }

    func testListSearchOrdersByScoreThenFrecencyThenLength() {
        let roots = FixtureMenuSource.notesLike()
        let candidates = roots.flattened.filter { $0.kind != .menuBarItem }.enumerated().map { i, n in
            SearchCandidate(payload: n, title: n.displayTitle, pathText: n.breadcrumb, frecency: n.title == "Bulleted List" ? 200 : 0, originalOrder: i)
        }
        let hits = ListSearch.search(q("bld"), in: candidates)
        XCTAssertFalse(hits.isEmpty)
        let titles = hits.map(\.payload.title)
        XCTAssertTrue(titles.contains("Bold"))
        XCTAssertTrue(titles.contains("Bulleted List"))
        // Bold is the best textual match; the strongly-used Bulleted List overtakes it thanks to frecency.
        XCTAssertEqual(titles.first, "Bulleted List")
        XCTAssertEqual(titles[1], "Bold")
        // Every hit has underline ranges inside its title.
        for hit in hits where hit.score > 0 {
            for r in hit.titleRanges { XCTAssertLessThanOrEqual(r.location + r.length, hit.payload.displayTitle.utf16.count) }
        }
    }

    func testListSearchFallsBackToPathWithPenalty() throws {
        let roots = FixtureMenuSource.notesLike()
        let candidates = roots.flattened.filter { $0.kind != .menuBarItem }.enumerated().map { i, n in
            SearchCandidate(payload: n, title: n.displayTitle, pathText: n.breadcrumb, originalOrder: i)
        }
        // "format bold" only matches through the path "Format › Font › Bold".
        let hits = ListSearch.search(q("formatbold"), in: candidates)
        let bold = try XCTUnwrap(hits.first { $0.payload.title == "Bold" })
        XCTAssertFalse(bold.titleRanges.isEmpty)
        XCTAssertTrue(bold.titleRanges.allSatisfy { $0.location >= 0 })
    }

    func testOutlineSearchKeepsHierarchyAndExpandsContainersWithMatches() throws {
        let roots = FixtureMenuSource.notesLike()
        let result = OutlineSearch.search(q("bold"), in: roots)
        XCTAssertEqual(result.roots.map(\.title), ["Format"])
        let format = result.roots[0]
        XCTAssertEqual(format.children.map(\.title), ["Font"])
        XCTAssertEqual(format.children[0].children.map(\.title), ["Bold"])
        XCTAssertTrue(result.expanded.contains(format.id))
        XCTAssertTrue(result.expanded.contains(format.children[0].id))
        XCTAssertEqual(result.bestMatch, format.children[0].children[0].id)
        XCTAssertEqual(result.ranges[format.children[0].children[0].id], [NSRange(location: 0, length: 4)])
    }

    func testOutlineSearchMatchingParentKeepsAllChildrenButStaysCollapsed() throws {
        let roots = FixtureMenuSource.notesLike()
        let result = OutlineSearch.search(q("kern"), in: roots)
        let format = try XCTUnwrap(result.roots.first { $0.title == "Format" })
        let font = try XCTUnwrap(format.children.first { $0.title == "Font" })
        let kern = try XCTUnwrap(font.children.first { $0.title == "Kern" })
        XCTAssertEqual(kern.children.count, 4)
        XCTAssertFalse(result.expanded.contains(kern.id))
        XCTAssertTrue(result.expanded.contains(font.id))
        XCTAssertEqual(result.bestMatch, kern.id)
    }

    func testOutlineSearchEmptyQueryReturnsEverything() {
        let roots = FixtureMenuSource.notesLike()
        let result = OutlineSearch.search(q(""), in: roots)
        XCTAssertEqual(result.roots.count, roots.count)
        XCTAssertTrue(result.expanded.isEmpty)
    }

    func testPerformanceOnLargeMenu() {
        // 6 000 synthetic rows must filter in well under a frame.
        var candidates: [SearchCandidate<Int>] = []
        for i in 0..<6000 {
            candidates.append(SearchCandidate(payload: i, title: "Menu Item Number \(i) With Some Extra Words", pathText: "Top › Sub \(i % 17) › Menu Item Number \(i) With Some Extra Words", originalOrder: i))
        }
        let query = q("num3")
        let start = Date()
        let hits = ListSearch.search(query, in: candidates)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertFalse(hits.isEmpty)
        // Unoptimised (Debug) budget; Release builds run this in ~15 ms.
        XCTAssertLessThan(elapsed, 0.6, "search took \(elapsed)s")
    }
}
