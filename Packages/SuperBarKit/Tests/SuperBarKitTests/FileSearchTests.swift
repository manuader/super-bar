import XCTest
@testable import SuperBarKit

final class FileSearchTests: XCTestCase {
    private func entry(_ path: String, dir: Bool = false, depth: Int = 1) -> FileEntry {
        FileEntry(path: path, isDirectory: dir, depth: depth)
    }

    func testEntryDerivesNameAndParent() {
        let e = entry("/Users/x/Projects/super-bar/README.md")
        XCTAssertEqual(e.name, "README.md")
        XCTAssertFalse(e.isDirectory)
        XCTAssertEqual(e.url.path, "/Users/x/Projects/super-bar/README.md")
        XCTAssertEqual(entry("/Users/x", dir: true).name, "x")
    }

    func testMatchKindsAreRankedExactPrefixBoundarySubstringSubsequence() throws {
        let q = FileQuery("src")
        XCTAssertEqual(FileMatcher.match(q, entry("/a/src"))?.kind, .exact)
        XCTAssertEqual(FileMatcher.match(q, entry("/a/srcutils"))?.kind, .prefix)
        XCTAssertEqual(FileMatcher.match(q, entry("/a/my-src-old"))?.kind, .wordBoundary)
        XCTAssertEqual(FileMatcher.match(q, entry("/a/websrc"))?.kind, .substring)
        XCTAssertEqual(FileMatcher.match(q, entry("/a/superconductor"))?.kind, .subsequence)
        XCTAssertNil(FileMatcher.match(q, entry("/a/zzz")))
    }

    func testMatchRangeCoversTheSubstring() throws {
        let hit = try XCTUnwrap(FileMatcher.match(FileQuery("bar"), entry("/x/super-bar")))
        let range = try XCTUnwrap(hit.range)
        let name = hit.entry.name as NSString
        XCTAssertEqual(name.substring(with: range), "bar")
    }

    func testFoldingIgnoresCaseAndAccents() {
        XCTAssertNotNil(FileMatcher.match(FileQuery("MUSICA"), entry("/x/Música", dir: true)))
        XCTAssertNotNil(FileMatcher.match(FileQuery("resume"), entry("/x/Résumé.pdf")))
        let hit = FileMatcher.match(FileQuery("mú"), entry("/x/Música", dir: true))
        XCTAssertNotNil(hit)
    }

    func testCharMaskRejectsWithoutScanning() {
        // A query character absent from the name must be rejected by the mask alone.
        let mask = CharMask.mask(of: FileEntry.fold("report.pdf"))
        XCTAssertTrue(FileQuery("zq").mask & ~mask != 0)
        XCTAssertFalse(FileQuery("rep").mask & ~mask != 0)
    }

    func testSnapshotListsDirectoriesAndFilesSeparatelyAndRanks() throws {
        let snapshot = FileIndexSnapshot(
            directories: [entry("/p/project1/src", dir: true, depth: 2), entry("/p/websrc", dir: true, depth: 1)],
            files: [entry("/p/project1/src/main.swift", depth: 3), entry("/p/srcs.txt", depth: 1)])
        let results = snapshot.search(FileQuery("src"))
        XCTAssertEqual(results.directories.map(\.entry.name), ["src", "websrc"])
        XCTAssertEqual(results.files.first?.entry.name, "srcs.txt")
        XCTAssertFalse(results.isEmpty)
        XCTAssertTrue(snapshot.search(FileQuery("nothinghere")).isEmpty)
    }

    func testHeatBoostsEntriesInsideHotDirectories() throws {
        let hot = entry("/p/project1/no-one-cares", dir: true, depth: 2)
        let cold = entry("/p/project2/no-one-cares", dir: true, depth: 2)
        let snapshot = FileIndexSnapshot(directories: [cold, hot], files: [], heat: ["/p/project1": 300])
        let results = snapshot.search(FileQuery("no-one"))
        XCTAssertEqual(results.directories.map(\.entry.path), [hot.path, cold.path])
        let resolver = HeatResolver(heat: ["/p/project1": 300])
        XCTAssertGreaterThan(resolver.score(for: hot), resolver.score(for: cold))
    }

    func testSearchLimitIsHonouredAndKeepsTheBestHits() {
        var dirs: [FileEntry] = []
        for i in 0..<500 { dirs.append(entry("/p/dir-\(i)-src", dir: true, depth: 3)) }
        dirs.append(entry("/p/src", dir: true, depth: 1))
        let snapshot = FileIndexSnapshot(directories: dirs, files: [])
        let results = snapshot.search(FileQuery("src"), limit: 10)
        XCTAssertEqual(results.directories.count, 10)
        XCTAssertEqual(results.directories.first?.entry.name, "src")
    }

    func testSearchOverALargeIndexStaysFast() {
        var dirs: [FileEntry] = []
        var files: [FileEntry] = []
        dirs.reserveCapacity(60_000)
        files.reserveCapacity(140_000)
        for i in 0..<60_000 { dirs.append(entry("/Users/x/work/module\(i % 400)/component-\(i)", dir: true, depth: 4)) }
        for i in 0..<140_000 { files.append(entry("/Users/x/work/module\(i % 400)/File\(i)Controller.swift", depth: 5)) }
        let snapshot = FileIndexSnapshot(directories: dirs, files: files)
        _ = snapshot.search(FileQuery("warmup"))   // warm the caches, then measure
        let queries = ["comp", "file123", "controller", "modul", "xyzzy"]
        let start = Date()
        for query in queries { _ = snapshot.search(FileQuery(query)) }
        let elapsed = Date().timeIntervalSince(start) / Double(queries.count)
        // Debug builds are unoptimised; Release runs this an order of magnitude faster.
        XCTAssertLessThan(elapsed, 0.35, "average search over 200k entries took \(elapsed)s")
    }
}

final class WorkspaceHeatTests: XCTestCase {
    func testOpeningAFolderHeatsItsAncestors() {
        let heat = WorkspaceHeat()
        heat.record(path: "/Users/x/project1/src/deep", isDirectory: true)
        XCTAssertEqual(heat.score(for: "/Users/x/project1/src/deep"), 100)
        XCTAssertEqual(heat.score(for: "/Users/x/project1/src"), 50)
        XCTAssertEqual(heat.score(for: "/Users/x/project1"), 25)
        XCTAssertEqual(heat.score(for: "/Users/x/project2"), 0)
    }

    func testOpeningAFileCreditsItsFolder() {
        let heat = WorkspaceHeat()
        heat.record(path: "/Users/x/project1/main.swift", isDirectory: false)
        XCTAssertEqual(heat.score(for: "/Users/x/project1"), 100)
        XCTAssertEqual(heat.score(for: "/Users/x/project1/main.swift"), 0)
    }

    func testRepeatedWorkMakesADirectoryHotEnoughToCrawlDeeply() {
        let heat = WorkspaceHeat()
        for _ in 0..<3 { heat.record(path: "/Users/x/project1/src", isDirectory: true) }
        XCTAssertEqual(heat.hotDirectories().first, "/Users/x/project1/src")
        XCTAssertTrue(heat.hotDirectories().contains("/Users/x/project1"))
        XCTAssertFalse(heat.hotDirectories().contains("/Users/x/project2"))
    }

    func testHeatDecaysOverTime() {
        let now = Date()
        let heat = WorkspaceHeat()
        heat.record(path: "/Users/x/project", isDirectory: true, now: now)
        XCTAssertEqual(heat.score(for: "/Users/x/project", now: now), 100, accuracy: 0.5)
        XCTAssertEqual(heat.score(for: "/Users/x/project", now: now.addingTimeInterval(WorkspaceHeat.halfLife)), 50, accuracy: 1)
        XCTAssertEqual(heat.score(for: "/Users/x/project", now: now.addingTimeInterval(3 * WorkspaceHeat.halfLife)), 12.5, accuracy: 1)
    }

    func testPersistenceRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("heat-\(UUID().uuidString).json")
        let heat = WorkspaceHeat(fileURL: url)
        heat.record(path: "/Users/x/project1", isDirectory: true)
        heat.saveNow()
        XCTAssertEqual(WorkspaceHeat(fileURL: url).score(for: "/Users/x/project1"), 100, accuracy: 0.5)
        try? FileManager.default.removeItem(at: url)
    }
}

final class FileIndexerTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sb-index-\(UUID().uuidString)")
        let fm = FileManager.default
        for dir in ["project1/src/deep/deeper", "project1/no-one-cares", "project1/node_modules/pkg", "project2", ".hidden"] {
            try fm.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        try "x".write(to: root.appendingPathComponent("project1/src/main.swift"), atomically: true, encoding: .utf8)
        try "x".write(to: root.appendingPathComponent("project1/README.md"), atomically: true, encoding: .utf8)
        try "x".write(to: root.appendingPathComponent("project1/.DS_Store"), atomically: true, encoding: .utf8)
        try fm.createDirectory(at: root.appendingPathComponent("project1/Thing.app"), withIntermediateDirectories: true)
        try "x".write(to: root.appendingPathComponent("project1/Thing.app/inside.txt"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testCrawlSkipsIgnoredAndHiddenDirectoriesAndTreatsBundlesAsFiles() {
        let result = FileIndexer.crawl(roots: [IndexRoot(path: root.path, maxDepth: 6)])
        let dirs = result.directories.map(\.name)
        XCTAssertTrue(dirs.contains("no-one-cares"))
        XCTAssertTrue(dirs.contains("deeper"))
        XCTAssertFalse(dirs.contains("node_modules"))     // dependency folders never appear
        XCTAssertFalse(dirs.contains("pkg"))              // nor anything inside them
        XCTAssertTrue(dirs.contains("project2"))
        XCTAssertFalse(dirs.contains(".hidden"))
        XCTAssertFalse(result.files.map(\.name).contains(".DS_Store"))
        XCTAssertTrue(result.files.map(\.name).contains("Thing.app"))
        XCTAssertFalse(result.files.map(\.name).contains("inside.txt"))
        XCTAssertFalse(result.hitBudget)
    }

    func testCustomIgnoreListHidesAFolder() {
        let ignore = IgnoreList(text: "no-one-cares/")
        let result = FileIndexer.crawl(roots: [IndexRoot(path: root.path, maxDepth: 6)], ignore: ignore)
        XCTAssertFalse(result.directories.map(\.name).contains("no-one-cares"))
        XCTAssertTrue(result.directories.map(\.name).contains("node_modules"))   // not in this list
    }

    func testCrawlCanBeCancelled() {
        let cancellation = FileIndexer.Cancellation()
        cancellation.cancel()
        let result = FileIndexer.crawl(roots: [IndexRoot(path: root.path, maxDepth: 6)], cancellation: cancellation)
        XCTAssertEqual(result.files.count, 0)
    }

    func testCrawlRespectsDepthAndBudget() {
        let shallow = FileIndexer.crawl(roots: [IndexRoot(path: root.path, maxDepth: 1)])
        XCTAssertFalse(shallow.directories.map(\.name).contains("deep"))
        XCTAssertTrue(shallow.directories.map(\.name).contains("project1"))
        let capped = FileIndexer.crawl(roots: [IndexRoot(path: root.path, maxDepth: 6)], budget: 3)
        XCTAssertTrue(capped.hitBudget)
        XCTAssertLessThanOrEqual(capped.directories.count + capped.files.count, 4)
    }

    func testPlanCrawlsHotDirectoriesDeeperThanSeeds() {
        let heat = WorkspaceHeat()
        for _ in 0..<3 { heat.record(path: root.appendingPathComponent("project1/src").path, isDirectory: true) }
        let plan = FileIndexer.plan(heat: heat, home: root.path, extraRoots: [])
        let hot = plan.first { $0.path.hasSuffix("project1/src") }
        XCTAssertNotNil(hot)
        XCTAssertGreaterThanOrEqual(hot!.maxDepth, 6)
        XCTAssertNil(plan.first { $0.path.hasSuffix("project2") })
        XCTAssertEqual(plan.first?.path, hot?.path)   // hottest first
    }
}

final class IgnoreListTests: XCTestCase {
    func testDefaultsExcludeDependencyAndBuildFolders() {
        let list = IgnoreList.default
        for name in ["node_modules", "Pods", "DerivedData", "__pycache__", ".venv", "target", "build", "vendor", ".git", "Library"] {
            XCTAssertTrue(list.ignores(path: "/p/app/\(name)", name: name, isDirectory: true), "\(name) should be ignored")
        }
        XCTAssertFalse(list.ignores(path: "/p/app/src", name: "src", isDirectory: true))
        XCTAssertFalse(list.ignores(path: "/p/app/main.swift", name: "main.swift", isDirectory: false))
    }

    func testDirectoryOnlyPatternsDoNotHideFiles() {
        let list = IgnoreList(text: "build/")
        XCTAssertTrue(list.ignores(path: "/p/build", name: "build", isDirectory: true))
        XCTAssertFalse(list.ignores(path: "/p/build", name: "build", isDirectory: false))
    }

    func testGlobsAbsolutePathsAndNegation() {
        let list = IgnoreList(text: """
        *.log
        /Users/me/Huge
        node_modules/
        !node_modules
        """)
        XCTAssertTrue(list.ignores(path: "/p/debug.log", name: "debug.log", isDirectory: false))
        XCTAssertFalse(list.ignores(path: "/p/debug.txt", name: "debug.txt", isDirectory: false))
        XCTAssertTrue(list.ignores(path: "/Users/me/Huge", name: "Huge", isDirectory: true))
        XCTAssertTrue(list.ignores(path: "/Users/me/Huge/inside", name: "inside", isDirectory: true))
        XCTAssertFalse(list.ignores(path: "/Users/other/Huge", name: "Huge", isDirectory: true))
        // The later `!node_modules` wins, as in .gitignore.
        XCTAssertFalse(list.ignores(path: "/p/node_modules", name: "node_modules", isDirectory: true))
    }

    func testCommentsAndBlankLinesAreSkipped() {
        let list = IgnoreList(text: "# a comment\n\n  \nsecret\n")
        XCTAssertEqual(list.rules.count, 1)
        XCTAssertTrue(list.ignores(path: "/p/secret", name: "secret", isDirectory: true))
    }
}

final class FileTypeHandlersTests: XCTestCase {
    func testChoicesAreKeyedByLowercasedExtension() {
        var handlers = FileTypeHandlers()
        XCTAssertFalse(handlers.hasChoice(for: "/x/a.PDF"))
        handlers.set(FileHandlerChoice(applicationPath: "/Applications/Preview.app", bundleIdentifier: "com.apple.Preview"), for: "/x/a.PDF")
        XCTAssertTrue(handlers.hasChoice(for: "/y/b.pdf"))
        XCTAssertEqual(handlers.choice(for: "/y/b.pdf")?.applicationName, "Preview")
        XCTAssertNil(handlers.choice(for: "/y/b.md"))
        handlers.set(.systemDefault, for: "/x/noext")
        XCTAssertEqual(handlers.choice(for: "/z/other")?.usesSystemDefault, true)
        XCTAssertEqual(handlers.sortedKeys, ["pdf", ""])
        handlers.remove(for: "PDF")
        XCTAssertFalse(handlers.hasChoice(for: "/x/a.pdf"))
    }

    func testCodableRoundTrip() throws {
        var handlers = FileTypeHandlers()
        handlers.set(FileHandlerChoice(applicationPath: "/Applications/Xcode.app", bundleIdentifier: "com.apple.dt.Xcode"), for: "a.swift")
        let data = try JSONEncoder().encode(handlers)
        XCTAssertEqual(try JSONDecoder().decode(FileTypeHandlers.self, from: data), handlers)
        XCTAssertEqual(FileTypeHandlers.describe("pdf"), ".pdf files")
        XCTAssertEqual(FileTypeHandlers.describe(""), "Files without an extension")
    }
}
