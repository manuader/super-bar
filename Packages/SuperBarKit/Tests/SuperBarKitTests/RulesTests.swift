import XCTest
@testable import SuperBarKit

final class RulesTests: XCTestCase {
    let app = AppInfo(pid: 1, bundleIdentifier: "com.apple.Notes", name: "Notes")
    let roots = FixtureMenuSource.notesLike()

    func testTitleRuleRemovesNodeAndDescendants() throws {
        let rule = try Rule(name: "No Apple", predicate: NSPredicate(format: "title ==[c] %@", "Apple"))
        let outcome = RuleEngine.apply([rule], to: roots, app: app)
        XCTAssertFalse(outcome.roots.contains { $0.title == "Apple" })
        XCTAssertGreaterThan(outcome.removedCount, 5)
        XCTAssertFalse(outcome.removedEverything)
        XCTAssertTrue(outcome.failedRuleIDs.isEmpty)
    }

    func testPathDepthIndexAndBundleCriteria() throws {
        let path = try Rule(name: "path", predicate: NSPredicate(format: "path BEGINSWITH %@", "Format\\Font"))
        let out1 = RuleEngine.apply([path], to: roots, app: app)
        XCTAssertNil(out1.roots.flattened.first { $0.title == "Font" })
        XCTAssertNotNil(out1.roots.flattened.first { $0.title == "Text" })

        let depth = try Rule(name: "deep", predicate: NSPredicate(format: "depth > 1"))
        let out2 = RuleEngine.apply([depth], to: roots, app: app)
        XCTAssertTrue(out2.roots.flattened.allSatisfy { $0.depth <= 1 })

        let index = try Rule(name: "first", predicate: NSPredicate(format: "depth == 0 AND index == 0"))
        let out3 = RuleEngine.apply([index], to: roots, app: app)
        XCTAssertEqual(out3.roots.first?.title, "Notes")

        let other = try Rule(name: "safari", predicate: NSPredicate(format: "bundleIdentifier == %@ AND title == %@", "com.apple.Safari", "File"))
        let out4 = RuleEngine.apply([other], to: roots, app: app)
        XCTAssertTrue(out4.roots.contains { $0.title == "File" })
    }

    func testDisabledRulesAreIgnoredAndEmptyResultIsFlagged() throws {
        var everything = try Rule(name: "all", predicate: NSPredicate(value: true))
        everything.isEnabled = false
        XCTAssertEqual(RuleEngine.apply([everything], to: roots, app: app).roots.count, roots.count)
        everything.isEnabled = true
        let outcome = RuleEngine.apply([everything], to: roots, app: app)
        XCTAssertTrue(outcome.roots.isEmpty)
        XCTAssertTrue(outcome.removedEverything)
    }

    func testInvalidPredicateFormatThrowsInsteadOfCrashing() {
        XCTAssertThrowsError(try RuleEngine.predicate(fromFormat: "title ==== ((("))
        XCTAssertNoThrow(try RuleEngine.predicate(fromFormat: "title CONTAINS[cd] 'x'"))
    }

    func testInvalidRegexIsReportedAsFailedRule() throws {
        let bad = try Rule(name: "regex", predicate: NSPredicate(format: "title MATCHES %@", "("))
        let outcome = RuleEngine.apply([bad], to: roots, app: app)
        XCTAssertEqual(outcome.failedRuleIDs, [bad.id])
        XCTAssertEqual(outcome.roots.count, roots.count)
    }

    func testRuleCodableRoundTrip() throws {
        let rule = try Rule(name: "r", predicate: NSPredicate(format: "title == %@", "History"))
        let data = try JSONEncoder().encode([rule])
        let decoded = try JSONDecoder().decode([Rule].self, from: data)
        XCTAssertEqual(decoded[0].predicateFormat, rule.predicateFormat)
        XCTAssertEqual(decoded[0].id, rule.id)
    }
}
