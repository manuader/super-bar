import XCTest
import SuperBarKit
@testable import SuperBar

@MainActor
final class SearchSessionTests: XCTestCase {
    private func makeSession() -> SearchSession {
        let defaults = UserDefaults(suiteName: "SearchSessionTests-\(UUID().uuidString)")!
        let session = SearchSession(preferences: Preferences(defaults: defaults), recents: RecentsStore())
        session.app = AppInfo(pid: 1, bundleIdentifier: "com.apple.Notes", name: "Notes")
        session.roots = FixtureMenuSource.notesLike()
        session.loadState = .ready
        session.scripts = [ScriptItem(url: URL(fileURLWithPath: "/tmp/Duplicate Tab.sh"), title: "Duplicate Tab", scope: nil)]
        return session
    }

    func testRootScreenHasMenuItemsAndScriptsSections() {
        let session = makeSession()
        let content = session.build()
        let headers = content.rows.compactMap { row -> String? in if case .header(let t) = row.kind { return t } else { return nil } }
        XCTAssertEqual(headers, ["Menu Items", "Scripts"])
        XCTAssertEqual(content.rows.filter { $0.menuNode?.depth == 0 }.count, 8)
        XCTAssertTrue(content.rows.contains { $0.scriptItem?.title == "Duplicate Tab" })
        XCTAssertGreaterThan(content.itemCount, 100)
        XCTAssertFalse(content.isSearching)
    }

    func testRecentsAppearFirstWhenPresent() {
        let session = makeSession()
        session.recents.record(appKey: "com.apple.Notes", titlePath: ["Format", "Font", "Bold"], indexPath: [4, 18, 1])
        let content = session.build()
        if case .header(let title) = content.rows[0].kind { XCTAssertEqual(title, "Recents") } else { XCTFail("expected Recents header") }
        XCTAssertEqual(content.rows[1].menuNode?.title, "Bold")
        XCTAssertTrue(content.rows[1].isRecent)
    }

    func testListSearchProducesRankedRowsWithUnderlines() {
        let session = makeSession()
        session.mode = .list
        session.query = "bld"
        let content = session.build()
        XCTAssertTrue(content.isSearching)
        XCTAssertEqual(content.rows.first?.title, "Search")
        let first = content.rows[1]
        XCTAssertEqual(first.menuNode?.title, "Bold")
        XCTAssertFalse(first.ranges.isEmpty)
        XCTAssertEqual(content.preferredSelection, first.id)
    }

    func testOutlineSearchExpandsPathToBestMatch() {
        let session = makeSession()
        session.mode = .outline
        session.query = "bold"
        let content = session.build()
        XCTAssertEqual(content.rows.count, 2) // header + Format
        let format = content.rows[1]
        XCTAssertEqual(format.menuNode?.title, "Format")
        XCTAssertTrue(content.expanded.contains(format.id))
        let font = format.children[0]
        XCTAssertEqual(font.menuNode?.title, "Font")
        XCTAssertEqual(content.preferredSelection, font.children[0].id)
    }

    func testScopeLimitsSearchAndHidesScripts() {
        let session = makeSession()
        session.scope = session.roots.flattened.first { $0.title == "Format" }
        session.mode = .list
        session.query = "text"
        let content = session.build()
        XCTAssertTrue(content.rows.dropFirst().allSatisfy { $0.menuNode?.path.first == "Format" })
        XCTAssertFalse(content.rows.contains { $0.scriptItem != nil })
        session.query = ""
        let browse = session.build()
        if case .header(let title) = browse.rows[0].kind { XCTAssertEqual(title, "Format") } else { XCTFail() }
    }

    func testNoResultsOffersHelpSearchAndPermissionStateIsActionable() {
        let session = makeSession()
        session.query = "zzzzzz"
        let none = session.build()
        if case .message(let m) = none.rows[0].kind { XCTAssertEqual(m.action, .searchHelp) } else { XCTFail() }
        session.isTrusted = false
        let perm = session.build()
        if case .message(let m) = perm.rows[0].kind { XCTAssertEqual(m.action, .grantAccessibility) } else { XCTFail() }
    }

    func testQuickIndicesFollowVisibleOrder() {
        let content = makeSession().build()
        let selectable = content.visibleRows().filter(\.isSelectable)
        XCTAssertEqual(selectable.first?.menuNode?.title, "Apple")
    }
}
