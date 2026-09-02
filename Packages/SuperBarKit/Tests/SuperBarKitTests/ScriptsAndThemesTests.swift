import XCTest
@testable import SuperBarKit

final class ScriptsTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sb-scripts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("com.apple.Safari"), withIntermediateDirectories: true)
        try "#!/bin/zsh\necho hi".write(to: root.appendingPathComponent("Global Thing.sh"), atomically: true, encoding: .utf8)
        try "".write(to: root.appendingPathComponent(".hidden"), atomically: true, encoding: .utf8)
        try "tell app \"Safari\" to activate".write(to: root.appendingPathComponent("com.apple.Safari/Close Tabs to the Left.applescript"), atomically: true, encoding: .utf8)
        try "#!/usr/bin/env python3 -u\nprint(1)".write(to: root.appendingPathComponent("com.apple.Safari/Open as Private Tab"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testScanFindsGlobalAndScopedScriptsWithTitles() {
        let items = ScriptsLibrary.scan(root: root)
        XCTAssertEqual(items.map(\.title), ["Global Thing", "Close Tabs to the Left", "Open as Private Tab"])
        XCTAssertEqual(items.map(\.scope), [nil, "com.apple.Safari", "com.apple.Safari"])
        XCTAssertEqual(ScriptsLibrary.items(for: "com.apple.Notes", in: items).map(\.title), ["Global Thing"])
        XCTAssertEqual(ScriptsLibrary.items(for: "com.apple.Safari", in: items).count, 3)
    }

    func testLaunchSelection() throws {
        let sh = root.appendingPathComponent("Global Thing.sh")
        XCTAssertEqual(ScriptRunner.launch(for: sh), .init(executable: "/bin/zsh", arguments: [sh.path]))
        let scpt = root.appendingPathComponent("com.apple.Safari/Close Tabs to the Left.applescript")
        XCTAssertEqual(ScriptRunner.launch(for: scpt).executable, "/usr/bin/osascript")
        let py = root.appendingPathComponent("com.apple.Safari/Open as Private Tab")
        XCTAssertEqual(ScriptRunner.launch(for: py), .init(executable: "/usr/bin/env", arguments: ["python3", "-u", py.path]))
        let exe = root.appendingPathComponent("bin")
        try "#!/bin/sh\necho".write(to: exe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        XCTAssertEqual(ScriptRunner.launch(for: exe), .init(executable: exe.path, arguments: []))
        let noShebang = root.appendingPathComponent("plain.py")
        try "print(1)".write(to: noShebang, atomically: true, encoding: .utf8)
        XCTAssertEqual(ScriptRunner.launch(for: noShebang).arguments.first, "python3")
    }

    func testRunReportsExitCodeAndOutput() {
        let url = root.appendingPathComponent("fail.sh")
        try? "#!/bin/sh\necho out; echo err 1>&2; exit 3".write(to: url, atomically: true, encoding: .utf8)
        let exp = expectation(description: "run")
        ScriptRunner.run(ScriptItem(url: url, title: "fail", scope: nil), app: AppInfo(pid: 1, bundleIdentifier: "x", name: "X")) { result in
            XCTAssertEqual(result.exitCode, 3)
            XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "out")
            XCTAssertEqual(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines), "err")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
    }
}

final class ThemesTests: XCTestCase {
    func testHexRoundTrip() {
        XCTAssertEqual(ThemeColor(hex: "#1E1E2E")?.hex, "#1E1E2E")
        XCTAssertEqual(ThemeColor(hex: "1E1E2E80")?.hex, "#1E1E2E80")
        XCTAssertEqual(ThemeColor(hex: "#FFF")?.hex, "#FFFFFF")
        XCTAssertNil(ThemeColor(hex: "nope"))
    }

    func testBuiltInsAreUniqueAndCodable() throws {
        let ids = BuiltInThemes.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(BuiltInThemes.all.count, 8)
        let data = ThemeCodec.encode(BuiltInThemes.all)
        XCTAssertEqual(ThemeCodec.decode(data), BuiltInThemes.all)
        let custom = BuiltInThemes.dracula.customCopy(named: "Mine")
        XCTAssertFalse(custom.isBuiltIn)
        XCTAssertFalse(custom.usesSystemColors)
        XCTAssertNotEqual(custom.id, BuiltInThemes.dracula.id)
    }
}

final class PreferencesTests: XCTestCase {
    func testStoredValuesRoundTrip() throws {
        let suite = "sb-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = Preferences(defaults: defaults)
        XCTAssertEqual(prefs.hotKey, .default)
        XCTAssertEqual(prefs.browsingMode, .list)
        prefs.browsingMode = .outline
        prefs.windowWidth = 720
        prefs.hotKey = HotKey(keyCode: 49, carbonModifiers: 2048)
        prefs.globalShortcutExcludedApps = ["com.apple.Terminal"]
        prefs.customThemes = [BuiltInThemes.monokai.customCopy(named: "Mono 2")]
        let again = Preferences(defaults: defaults)
        XCTAssertEqual(again.browsingMode, .outline)
        XCTAssertEqual(again.windowWidth, 720)
        XCTAssertEqual(again.hotKey.carbonModifiers, 2048)
        XCTAssertEqual(again.globalShortcutExcludedApps, ["com.apple.Terminal"])
        XCTAssertEqual(again.customThemes.first?.name, "Mono 2")
        XCTAssertEqual(again.allThemes.count, 9)
    }
}
