import XCTest
@testable import SuperBarKit

final class MenuModelTests: XCTestCase {
    let roots = FixtureMenuSource.notesLike()

    func testDisplayTitleIsPrefixedByParentForDeepItems() throws {
        let bold = try XCTUnwrap(roots.flattened.first { $0.title == "Bold" })
        XCTAssertEqual(bold.depth, 2)
        XCTAssertEqual(bold.displayTitle, "Font › Bold")
        XCTAssertEqual(bold.subtitlePath, ["Format"])
        XCTAssertEqual(bold.rulePath, "Format\\Font\\Bold")
        XCTAssertEqual(bold.breadcrumb, "Format › Font › Bold")

        let newNote = try XCTUnwrap(roots.flattened.first { $0.title == "New Note" })
        XCTAssertEqual(newNote.displayTitle, "New Note")
        XCTAssertEqual(newNote.subtitlePath, ["File"])
    }

    func testIndexPathsCountSeparatorsAndLookupWorks() throws {
        let apple = roots[0]
        XCTAssertEqual(apple.kind, .menuBarItem)
        XCTAssertEqual(apple.children[1].kind, .separator)
        XCTAssertEqual(apple.children[2].title, "System Settings…")
        XCTAssertEqual(apple.children[2].indexPath, [0, 2])
        let found = try XCTUnwrap(roots.node(at: [0, 2]))
        XCTAssertEqual(found.title, "System Settings…")
        XCTAssertNil(roots.node(at: [0, 99]))
    }

    func testFlattenedExcludesSeparators() {
        XCTAssertFalse(roots.flattened.contains { $0.isSeparator })
        XCTAssertTrue(roots.flattened.contains { $0.title == "Kern" && $0.kind == .submenu })
        XCTAssertEqual(roots[7].visibleChildCount, 2)
    }

    func testKeyEquivalentDecodingFromAXAttributes() {
        XCTAssertEqual(KeyEquivalent(cmdChar: "k", modifierMask: 0, virtualKey: nil, glyph: nil)?.display, "⌘K")
        XCTAssertEqual(KeyEquivalent(cmdChar: "M", modifierMask: 1, virtualKey: nil, glyph: nil)?.display, "⇧⌘M")
        XCTAssertEqual(KeyEquivalent(cmdChar: "h", modifierMask: 2, virtualKey: nil, glyph: nil)?.display, "⌥⌘H")
        XCTAssertEqual(KeyEquivalent(cmdChar: "q", modifierMask: 4, virtualKey: nil, glyph: nil)?.display, "⌃⌘Q")
        XCTAssertEqual(KeyEquivalent(cmdChar: "v", modifierMask: 3, virtualKey: nil, glyph: nil)?.display, "⌥⇧⌘V")
        // "no command" bit
        XCTAssertEqual(KeyEquivalent(cmdChar: "", modifierMask: 8, virtualKey: 96, glyph: nil)?.display, "F5")
        XCTAssertEqual(KeyEquivalent(cmdChar: " ", modifierMask: 4, virtualKey: nil, glyph: nil)?.display, "⌃⌘␣")
        XCTAssertEqual(KeyEquivalent(cmdChar: "\u{F700}", modifierMask: 4, virtualKey: nil, glyph: nil)?.display, "⌃⌘↑")
        XCTAssertEqual(KeyEquivalent(cmdChar: "\u{7F}", modifierMask: 0, virtualKey: nil, glyph: nil)?.display, "⌘⌫")
        // glyph wins over char
        XCTAssertEqual(KeyEquivalent(cmdChar: "\r", modifierMask: 0, virtualKey: nil, glyph: 11)?.display, "⌘↩")
        XCTAssertEqual(KeyEquivalent(cmdChar: nil, modifierMask: 0, virtualKey: 53, glyph: nil)?.display, "⌘⎋")
        XCTAssertNil(KeyEquivalent(cmdChar: "", modifierMask: 0, virtualKey: nil, glyph: nil))
        XCTAssertNil(KeyEquivalent(cmdChar: nil, modifierMask: nil, virtualKey: nil, glyph: nil))
    }
}
