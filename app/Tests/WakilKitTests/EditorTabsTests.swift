import Foundation
import Testing
@testable import WakilKit

private func fileTab(_ path: String, root: String = "/p/api") -> EditorTab {
    EditorTab.file(path: path, root: root, text: "", mtime: 1, language: editorLanguage(forPath: path))
}

@Test func titlesAreFileNames() {
    #expect(editorTabTitles([fileTab("/p/api/a.go"), fileTab("/p/api/b.go")]) == ["a.go", "b.go"])
}

@Test func titlesOfTwoSameNamedFilesNameTheirFolders() {
    let tabs = [fileTab("/p/api/src/config.go"), fileTab("/p/web/lib/config.go", root: "/p/web")]
    #expect(editorTabTitles(tabs) == ["src/config.go", "lib/config.go"])
}

@Test func scratchTitlesAreUntitledN() {
    #expect(editorTabTitles([EditorTab.scratch(number: 2, language: "plaintext")]) == ["Untitled-2"])
}

@Test func theNextScratchNumberIsOneAboveTheHighestOpen() {
    #expect(editorNextScratchNumber([]) == 1)
    #expect(editorNextScratchNumber([.scratch(number: 1, language: "sql"), .scratch(number: 3, language: "sql")]) == 4)
}

@Test func languageComesFromTheExtension() {
    #expect(editorLanguage(forPath: "/a/b.go") == "go")
    #expect(editorLanguage(forPath: "/a/b.tsx") == "typescript")
    #expect(editorLanguage(forPath: "/a/Dockerfile") == "dockerfile")
    #expect(editorLanguage(forPath: "/a/.env") == "ini")
    #expect(editorLanguage(forPath: "/a/b.unknown") == "plaintext")
}

@Test func glyphsFollowTheLanguage() {
    let cases: [(String, Character)] = [
        ("/a/main.go", "\u{E03A}"), ("/a/App.swift", "\u{E092}"), ("/a/index.php", "\u{E070}"),
        ("/a/app.test.tsx", "\u{E099}"), ("/a/b.mjs", "\u{E051}"), ("/a/package.json", "\u{E055}"),
        ("/a/ci.yml", "\u{E0A7}"), ("/a/q.sql", "\u{E022}"), ("/a/README.MD", "\u{E060}"),
        ("/a/x.vue", "\u{E048}"), ("/a/s.css", "\u{E01D}"), ("/a/s.scss", "\u{E084}"),
        ("/a/run.py", "\u{E07B}"), ("/a/go.sh", "\u{E089}"), ("/a/pom.xml", "\u{E0A5}"),
        ("/a/Dockerfile", "\u{E025}"),
    ]
    for (path, glyph) in cases { #expect(editorFileGlyph(forPath: path) == glyph, "\(path)") }
}

@Test func filesWithNoGlyphShowThePage() {
    #expect(editorFileGlyph(forPath: "/a/.env") == "\u{E023}")      // ini
    #expect(editorFileGlyph(forPath: "/a/Makefile") == "\u{E023}")  // plaintext
    #expect(editorFileGlyph(forPath: "/a/LICENSE") == "\u{E023}")
    #expect(editorFileGlyph(forPath: "/a/b.unknown") == "\u{E023}")
}

@Test func aFileTabShowsItsFilesGlyph() {
    #expect(editorTabGlyph(fileTab("/p/api/main.go")) == "\u{E03A}")
}

@Test func aDiffTabShowsItsFilesGlyph() {
    #expect(editorTabGlyph(.diff(root: "/p/api", path: "cmd/main.go", group: .changed)) == "\u{E03A}")
}

@Test func aScratchTabShowsThePage() {
    #expect(editorTabGlyph(.scratch(number: 1, language: "sql")) == "\u{E023}")
}

@Test func commandWClosesATabWhileAnyIsOpenThenThePane() {
    #expect(editorCloseTarget(tabs: 2) == .tab)
    #expect(editorCloseTarget(tabs: 0) == .pane)
}

@Test func closingATabFocusesItsNeighbourNotTheFirst() {
    #expect(editorTabAfterClosing(2, count: 4) == 2)   // the tab that slid into its place
    #expect(editorTabAfterClosing(3, count: 4) == 2)   // the last tab: its left neighbour
    #expect(editorTabAfterClosing(0, count: 1) == nil)
}

@Test func savedTabsKeepFilesAndDropScratch() {
    var a = fileTab("/p/api/a.go"); a.cursor = EditorPosition(line: 40, column: 3); a.scrollTop = 120
    let s = EditorSnapshot(tabs: [a, .scratch(number: 1, language: "sql")], active: 0)
    #expect(editorSavedTabs(s) == [EditorSavedTab(path: "/p/api/a.go", cursor: EditorPosition(line: 40, column: 3), scrollTop: 120)])
}

@Test func replacingARangeUsesOneBasedUTF16Positions() {
    let r = EditorRange(start: EditorPosition(line: 2, column: 1), end: EditorPosition(line: 2, column: 3))
    #expect(editorReplacing("ab\ncdé\n", r, with: "X") == "ab\nXé\n")
    #expect(editorText("ab\ncdé\n", in: r) == "cd")
}

// Review Focus 5.
@Test func movingATabKeepsTheActiveTabTheSameTab() throws {
    let s = EditorSnapshot(tabs: [.scratch(number: 1, language: "sql"), .scratch(number: 2, language: "sql"),
                                  .scratch(number: 3, language: "sql")], active: 1)
    let moved = try #require(editorMovingTab(s, from: 0, to: 2))
    #expect(moved.tabs.map(\.subject) == [.scratch(number: 2), .scratch(number: 3), .scratch(number: 1)])
    #expect(moved.active == 0)                     // Untitled-2 is still the active tab
    let back = try #require(editorMovingTab(moved, from: 2, to: 0))
    #expect(back.tabs.map(\.subject) == s.tabs.map(\.subject) && back.active == 1)
    #expect(editorMovingTab(s, from: 1, to: 1) == nil)
    #expect(editorMovingTab(s, from: 3, to: 0) == nil)
    #expect(editorMovingTab(s, from: 0, to: 3) == nil)
}

@Test func aDropOverATabMovesTheDraggedTabToThatTabsIndexWhereverOnItTheDropLands() {
    let spans: [ClosedRange<Double>] = [0...100, 102...202, 204...304]
    for x in [204.0, 254, 255, 303] {                                     // any point of tab 2, centre or not
        #expect(editorTabDropTarget(from: 0, x: x, y: 15, spans: spans, height: 36) == 2)
    }
    #expect(editorTabDropTarget(from: 0, x: 60, y: 15, spans: spans, height: 36) == nil)    // its own place
    #expect(editorTabDropTarget(from: 2, x: 10, y: 15, spans: spans, height: 36) == 0)
    #expect(editorTabDropTarget(from: 0, x: 150, y: 15, spans: spans, height: 36) == 1)
    #expect(editorTabDropTarget(from: 1, x: 150, y: 15, spans: spans, height: 36) == nil)
    #expect(editorTabDropTarget(from: 0, x: 60, y: 80, spans: spans, height: 36) == nil)    // off the strip
    #expect(editorTabDropTarget(from: 2, x: 10, y: -4, spans: spans, height: 36) == nil)
}

@Test func aDropInAGapOrPastAnEndTakesTheSlotThere() {
    let spans: [ClosedRange<Double>] = [0...100, 102...202, 204...304]
    #expect(editorTabDropTarget(from: 2, x: 101, y: 15, spans: spans, height: 36) == 1)     // gap before tab 1
    #expect(editorTabDropTarget(from: 0, x: 203, y: 15, spans: spans, height: 36) == 1)     // gap before tab 2
    #expect(editorTabDropTarget(from: 0, x: 101, y: 15, spans: spans, height: 36) == nil)   // before its next: own place
    #expect(editorTabDropTarget(from: 0, x: 900, y: 15, spans: spans, height: 36) == 2)     // past the end
    #expect(editorTabDropTarget(from: 2, x: -5, y: 15, spans: spans, height: 36) == 0)      // before the first
    #expect(editorTabDropTarget(from: 2, x: 900, y: 15, spans: spans, height: 36) == nil)   // after itself, last
}

@Test func theDropLineDrawsOnTheSideAwayFromTheDraggedTab() {
    let spans: [ClosedRange<Double>] = [0...100, 102...202, 204...304]
    #expect(editorTabDropX(EditorTabDrop(from: 0, to: 2), spans: spans) == 305)             // moving right: after it
    #expect(editorTabDropX(EditorTabDrop(from: 2, to: 0), spans: spans) == -1)              // moving left: before it
    #expect(editorTabDropX(EditorTabDrop(from: 0, to: 1), spans: spans) == 203)
    #expect(editorTabDropX(EditorTabDrop(from: 2, to: 1), spans: spans) == 101)
}

@Test func aDiffTabsTitleNamesItsGroupAndItsKeyIsItsOwn() {
    let t = EditorTab.diff(root: "/p/api", path: "app/User.php", group: .staged)
    #expect(editorTabTitles([t]) == ["User.php (Staged)"])
    #expect(editorTabKey(t) == "diff:staged:/p/api/app/User.php")
    #expect(editorTabParams(t.subject) == ["diff": .object(["root": .string("/p/api"), "path": .string("app/User.php"),
                                                            "group": .string("staged")])])
}
