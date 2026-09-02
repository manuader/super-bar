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

    func testListModeIsFlatAndOutlineModeIsATree() {
        let session = makeSession()
        session.mode = .list
        let list = session.build()
        XCTAssertFalse(list.rows.contains { $0.isExpandable })
        XCTAssertEqual(list.rows.filter { $0.menuNode?.depth == 0 }.count, 8)
        session.mode = .outline
        let outline = session.build()
        XCTAssertTrue(outline.rows.contains { $0.isExpandable })
        // Inside a scope, list mode shows the children flat.
        session.mode = .list
        session.scope = session.roots.flattened.first { $0.title == "Format" }
        let scoped = session.build()
        XCTAssertTrue(scoped.rows.dropFirst().allSatisfy { $0.menuNode?.depth == 1 && !$0.isExpandable })
    }

    func testAppPickerListsAppsAndFiltersThem() {
        let session = makeSession()
        session.runningApps = [
            RunningApp(pid: 10, name: "Finder", bundleIdentifier: "com.apple.finder", icon: nil, isFrontmost: true),
            RunningApp(pid: 1, name: "Notes", bundleIdentifier: "com.apple.Notes", icon: nil, isFrontmost: false),
            RunningApp(pid: 30, name: "Xcode", bundleIdentifier: "com.apple.dt.Xcode", icon: nil, isFrontmost: false),
        ]
        session.isPickingApp = true
        let all = session.build()
        XCTAssertEqual(all.rows.compactMap { $0.runningApp?.name }, ["Finder", "Notes", "Xcode"])
        XCTAssertEqual(all.preferredSelection, "a:1")   // the app currently acted on (pid 1 = Notes)
        XCTAssertEqual(all.itemCount, 3)
        session.query = "xc"
        let filtered = session.build()
        XCTAssertEqual(filtered.rows.compactMap { $0.runningApp?.name }, ["Xcode"])
        XCTAssertFalse(filtered.rows[1].ranges.isEmpty)
        session.query = "zzz"
        if case .message = session.build().rows[0].kind {} else { XCTFail("expected an empty-state message") }
        session.resetSearchState()
        XCTAssertFalse(session.isPickingApp)
    }

    // MARK: The `open` command

    private func openResults(_ session: SearchSession, query: String, folders: [String], files: [String]) {
        let snapshot = FileIndexSnapshot(
            directories: folders.map { FileEntry(path: $0, isDirectory: true, depth: 2) },
            files: files.map { FileEntry(path: $0, isDirectory: false, depth: 3) })
        session.query = "open " + query
        session.fileIndexState = .ready
        session.fileResults = snapshot.search(FileQuery(query))
        session.fileResultsQuery = query
    }

    func testOpenPrefixIsDetectedCaseInsensitively() {
        let session = makeSession()
        session.query = "open notes"
        XCTAssertEqual(session.openQuery, "notes")
        session.query = "OPEN Notes"
        XCTAssertEqual(session.openQuery, "Notes")
        session.query = "open "
        XCTAssertEqual(session.openQuery, "")
        session.query = "opened"                 // a menu item, not the command
        XCTAssertNil(session.openQuery)
        session.query = "open"
        XCTAssertNil(session.openQuery)
        XCTAssertTrue(session.suggestsOpenCommand)
        session.preferences.openCommandEnabled = false
        session.query = "open notes"
        XCTAssertNil(session.openQuery)
    }

    func testOpenListsFoldersBeforeFiles() throws {
        let session = makeSession()
        openResults(session, query: "super",
                    folders: ["/Users/x/Projects/super-bar", "/Users/x/superb"],
                    files: ["/Users/x/Projects/super-bar/README.md", "/Users/x/super.txt"])
        let content = session.build()
        let headers = content.rows.compactMap { row -> String? in if case .header(let t) = row.kind { return t } else { return nil } }
        XCTAssertEqual(headers, ["Folders", "Files"])
        let names = content.rows.compactMap { $0.fileEntry?.name }
        XCTAssertEqual(names.prefix(2).map { $0 }, ["superb", "super-bar"])
        XCTAssertTrue(names.contains("super.txt"))
        XCTAssertEqual(content.itemCount, 3)
        // The first folder is preselected and its match is highlighted.
        XCTAssertEqual(content.preferredSelection, content.rows[1].id)
        XCTAssertFalse(content.rows[1].ranges.isEmpty)
    }

    func testOpenWithoutMatchesOffersSettings() throws {
        let session = makeSession()
        openResults(session, query: "zzzz", folders: [], files: [])
        let content = session.build()
        let message = try XCTUnwrap(content.rows.first?.message)
        XCTAssertEqual(message.action, .openFileSettings)
    }

    func testOpenShowsSkeletonWhileIndexing() {
        let session = makeSession()
        session.query = "open src"
        session.fileIndexState = .indexing
        let content = session.build()
        XCTAssertTrue(content.rows.contains { if case .skeleton = $0.kind { return true } else { return false } })
    }

    func testTypingOpenSuggestsTheCommandRow() throws {
        let session = makeSession()
        session.query = "op"
        let content = session.build()
        let command = try XCTUnwrap(content.rows.first { $0.command != nil })
        XCTAssertEqual(command.command?.keyword, "open")
        XCTAssertEqual(content.preferredSelection, command.id)
    }

    func testHandlerPickerListsCandidatesForTheFileType() throws {
        let session = makeSession()
        let file = FileEntry(path: "/Users/x/report.pdf", isDirectory: false, depth: 2)
        session.pendingFile = file
        session.handlerCandidates = [
            AppHandler(url: URL(fileURLWithPath: "/System/Applications/Preview.app"), isSystemDefault: true),
            AppHandler(url: URL(fileURLWithPath: "/Applications/Safari.app"), isSystemDefault: false),
            .browse,
        ]
        let content = session.build()
        if case .header(let title) = content.rows[0].kind { XCTAssertEqual(title, "Open .pdf files with") } else { XCTFail() }
        XCTAssertEqual(content.rows.compactMap { $0.appHandler?.name }.last, "Choose Another App…")
        XCTAssertEqual(content.preferredSelection, content.rows[1].id)
        XCTAssertTrue(content.rows[1].appHandler?.isSystemDefault ?? false)
        session.resetSearchState()
        XCTAssertNil(session.pendingFile)
    }

    func testQuickIndicesFollowVisibleOrder() {
        let content = makeSession().build()
        let selectable = content.visibleRows().filter(\.isSelectable)
        XCTAssertEqual(selectable.first?.menuNode?.title, "Apple")
    }
}
