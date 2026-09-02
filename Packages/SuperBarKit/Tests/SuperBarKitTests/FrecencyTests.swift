import XCTest
@testable import SuperBarKit

final class FrecencyTests: XCTestCase {
    func testRecentUsesWeighMoreThanOldOnes() {
        let now = Date()
        let store = RecentsStore()
        store.record(appKey: "app", titlePath: ["Format", "Bold"], indexPath: [4, 1], at: now.addingTimeInterval(-40 * 86_400))
        store.record(appKey: "app", titlePath: ["Format", "Italic"], indexPath: [4, 2], at: now.addingTimeInterval(-60))
        let top = store.top(appKey: "app", now: now)
        XCTAssertEqual(top.map { $0.titlePath.last }, ["Italic", "Bold"])
        XCTAssertEqual(store.score(appKey: "app", titlePath: ["Format", "Italic"], indexPath: [4, 2], now: now), 100)
        XCTAssertEqual(store.score(appKey: "app", titlePath: ["Format", "Bold"], indexPath: [4, 1], now: now), 10)
        XCTAssertEqual(store.score(appKey: "other", titlePath: ["Format", "Bold"], indexPath: [4, 1], now: now), 0)
    }

    func testRepeatedUseAccumulatesAndIsCapped() {
        let now = Date()
        let store = RecentsStore()
        for i in 0..<30 { store.record(appKey: "app", titlePath: ["Edit", "Copy"], indexPath: [3, 4], at: now.addingTimeInterval(Double(-i))) }
        let entry = store.allEntries[0]
        XCTAssertEqual(entry.uses.count, RecentsStore.maxUsesPerEntry)
        XCTAssertEqual(store.allEntries.count, 1)
    }

    func testDynamicTitlesFallBackToIndexPath() {
        let now = Date()
        let store = RecentsStore()
        store.record(appKey: "app", titlePath: ["Edit", "Undo Typing"], indexPath: [3, 0], at: now)
        // Later the same item is titled differently.
        XCTAssertEqual(store.score(appKey: "app", titlePath: ["Edit", "Undo Paste"], indexPath: [3, 0], now: now), 100)
        // A different menu bar item with the same indices does not match.
        XCTAssertEqual(store.score(appKey: "app", titlePath: ["File", "Undo Paste"], indexPath: [3, 0], now: now), 0)
        // Recording under the new title merges into the same entry and adopts it.
        store.record(appKey: "app", titlePath: ["Edit", "Undo Paste"], indexPath: [3, 0], at: now)
        XCTAssertEqual(store.allEntries.count, 1)
        XCTAssertEqual(store.allEntries[0].titlePath, ["Edit", "Undo Paste"])
    }

    func testIndexMatchesStoreScoring() {
        let now = Date()
        let store = RecentsStore()
        store.record(appKey: "app", titlePath: ["Edit", "Undo Typing"], indexPath: [3, 0], at: now)
        store.record(appKey: "app", titlePath: ["Run"], indexPath: [], isScript: true, at: now)
        let index = store.index(appKey: "app", now: now)
        XCTAssertEqual(index.score(titlePath: ["Edit", "Undo Typing"], indexPath: [3, 0]), 100)
        XCTAssertEqual(index.score(titlePath: ["Edit", "Undo Paste"], indexPath: [3, 0]), 100)
        XCTAssertEqual(index.score(titlePath: ["File", "Undo Paste"], indexPath: [3, 0]), 0)
        XCTAssertEqual(index.scriptScore(title: "Run"), 100)
        XCTAssertTrue(store.index(appKey: "other").isEmpty)
    }

    func testScriptsAreTrackedSeparatelyAndClearWorks() {
        let store = RecentsStore()
        store.record(appKey: "app", titlePath: ["Duplicate Tab"], indexPath: [], isScript: true)
        XCTAssertGreaterThan(store.scriptScore(appKey: "app", title: "Duplicate Tab"), 0)
        XCTAssertEqual(store.score(appKey: "app", titlePath: ["Duplicate Tab"], indexPath: [], now: Date()), 0)
        store.clear(appKey: "app")
        XCTAssertTrue(store.allEntries.isEmpty)
    }

    func testPersistenceRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recents-\(UUID().uuidString).json")
        let store = RecentsStore(fileURL: url)
        store.record(appKey: "app", titlePath: ["File", "New Note"], indexPath: [2, 0])
        store.saveNow()
        let reloaded = RecentsStore(fileURL: url)
        XCTAssertEqual(reloaded.allEntries.count, 1)
        XCTAssertEqual(reloaded.allEntries[0].titlePath, ["File", "New Note"])
        try? FileManager.default.removeItem(at: url)
    }
}
