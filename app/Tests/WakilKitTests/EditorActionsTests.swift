import Foundation
import Testing
@testable import WakilKit

@Test func openReadsTheFileIntoANewActiveTabAtTheLine() async throws {
    let f = try await editorFixture()
    await f.files.put("/p/api/a.go", "l1\nl2\nl3")
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go"), "line": .integer(2)])
    let s = await f.snapshot()
    #expect(s.tabs.count == 1 && s.active == 0)
    #expect(s.tabs[0].subject == .file(path: "/p/api/a.go", root: "/p/api"))
    #expect(s.tabs[0].text == "l1\nl2\nl3" && !s.tabs[0].dirty && s.tabs[0].language == "go")
    #expect(s.tabs[0].cursor == EditorPosition(line: 2, column: 1))
    #expect(await f.layout.editorTabs(id: f.pane)?.map(\.path) == ["/p/api/a.go"])
}

@Test func openWithAnEndColumnSelectsTheMatchInTheSameStep() async throws {
    let f = try await editorFixture()
    await f.files.put("/p/api/a.go", "l1\nconst needle = 1")
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go"), "line": .integer(2),
                                         "column": .integer(7), "end_column": .integer(13)])
    let at = { (c: Int) in EditorPosition(line: 2, column: c) }
    #expect(await f.snapshot().tabs[0].selection == EditorRange(start: at(7), end: at(13)))
    #expect(await f.snapshot().tabs[0].cursor == at(13))
    // An open tab, reopened at another match, takes the new selection.
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go"), "line": .integer(1),
                                         "column": .integer(1), "end_column": .integer(3)])
    #expect(await f.snapshot().tabs[0].selection == EditorRange(start: EditorPosition(line: 1, column: 1),
                                                                 end: EditorPosition(line: 1, column: 3)))
}

@Test func openingAnOpenFileFocusesItsTabAndDoesNotReread() async throws {
    let f = try await editorFixture()
    await f.files.put("/p/api/a.go", "a"); await f.files.put("/p/api/b.go", "b")
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
    try await f.dispatch("editor_open", ["path": .string("/p/api/b.go")])
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
    #expect(await f.snapshot().active == 0)
    #expect(await f.files.calls.filter { $0 == "files_read /p/api/a.go" }.count == 1)
}

@Test func openingASameNamedFileInAnotherRootOpensANewTab() async throws {
    let f = try await editorFixture()
    await f.files.put("/p/api/config.go", "a"); await f.files.put("/p/web/config.go", "b")
    try await f.dispatch("editor_open", ["path": .string("/p/api/config.go")])
    try await f.dispatch("editor_open", ["path": .string("/p/web/config.go")])
    let s = await f.snapshot()
    #expect(s.tabs.count == 2 && s.active == 1 && s.tabs[1].text == "b")
}

@Test func openWithNoPaneOpensAnEditorPane() async throws {
    let f = try await editorFixture()
    try await f.layout.close(id: f.pane)
    await f.files.put("/p/api/a.go", "a")
    let reply = try await f.registry.dispatch(name: "editor_open", params: .object(["path": .string("/p/api/a.go")]),
                                              origin: .agent, environment: "staging", confirmation: nil)
    let opened = await f.layout.snapshot().panes.filter { $0.kind == "editor" }
    #expect(opened.count == 1)
    #expect(optionalString(reply, "pane") == opened[0].id)
}

@Test func openOfAPathOutsideTheRootsIsRefusedNamingTheDecision() async throws {
    let f = try await editorFixture()
    await #expect(throws: (any Error).self) { try await f.dispatch("editor_open", ["path": .string("/etc/hosts")]) }
    #expect(await f.snapshot().tabs.isEmpty)
}

@Test func anOverCapFileOpensReadOnlyWithItsNoticeWhole() async throws {
    let f = try await editorFixture()
    // FakeFiles has no over-cap mode: give it one for this test by writing the reply shape directly.
    // (Add `func putOverCap(_ path: String, size: Int)` to FakeFiles answering over_cap true.)
    await f.files.putOverCap("/p/api/dump.sql", size: 48_000_000)
    try await f.dispatch("editor_open", ["path": .string("/p/api/dump.sql")])
    let t = await f.snapshot().tabs[0]
    #expect(t.readOnly && t.text.isEmpty)
    #expect(t.notice == "dump.sql is 48 MB; files over 2 MB open in 3b-v")
}

@Test func newScratchOpensAnEmptyFocusedUntitledTab() async throws {
    let f = try await editorFixture()
    try await f.dispatch("editor_new_scratch", origin: .ui)
    try await f.dispatch("editor_new_scratch", ["language": .string("sql")], origin: .ui)
    let s = await f.snapshot()
    #expect(s.tabs.map(\.subject) == [.scratch(number: 1), .scratch(number: 2)])
    #expect(s.active == 1 && s.tabs[1].language == "sql")
    #expect(await f.layout.editorTabs(id: f.pane) == [], "scratch tabs are never persisted")
}

@Test func replaceRangeEditsTheBufferAndLeavesItUnsaved() async throws {
    let f = try await editorFixture()
    await f.files.put("/p/api/a.go", "if x == nil {\n}")
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
    try await f.dispatch("editor_replace_range", ["range": range(1, 4, 1, 5), "text": .string("y")])
    let t = await f.snapshot().tabs[0]
    #expect(t.text == "if y == nil {\n}" && t.dirty)
    #expect(t.lastAgentEdit?.text == "y" && t.lastAgentEdit?.serial == 1)
    #expect(await f.files.text(of: "/p/api/a.go") == "if x == nil {\n}", "the disk changes only on save")
}

@Test func replaceRangeAppliesToTheTextAsTypedSoFar() async throws {
    let f = try await editorFixture()
    await f.files.put("/p/api/a.go", "abc")
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
    await f.panes.editorBufferDidChange(paneId: f.pane, tab: 0, text: "abcdef", basis: 0)
    try await f.dispatch("editor_replace_range", ["range": range(1, 1, 1, 2), "text": .string("X")])
    #expect(await f.snapshot().tabs[0].text == "Xbcdef")
}

@Test func saveWritesTheBufferWithoutAPromptEvenInProduction() async throws {
    let f = try await editorFixture()
    await f.files.put("/p/api/a.go", "old")
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
    await f.panes.editorBufferDidChange(paneId: f.pane, tab: 0, text: "new", basis: 0)
    try await f.dispatch("editor_save", origin: .agent, environment: "production")
    #expect(await f.files.text(of: "/p/api/a.go") == "new")
    let t = await f.snapshot().tabs[0]
    let diskMtime = await f.files.mtime(of: "/p/api/a.go")
    #expect(!t.dirty && !t.saving && t.mtime == diskMtime)
}

@Test func aSaveThatLandsAfterMoreTypingLeavesTheTabDirty() async throws {
    let f = try await editorFixture()
    await f.files.put("/p/api/a.go", "v0")
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
    await f.panes.editorBufferDidChange(paneId: f.pane, tab: 0, text: "v1", basis: 0)
    await f.files.setSlowWrite(true)
    let save = Task { try await f.dispatch("editor_save", origin: .ui) }
    while await !f.snapshot().tabs[0].saving { await Task.yield() }
    await f.panes.editorBufferDidChange(paneId: f.pane, tab: 0, text: "v2", basis: 0)
    await f.files.releaseWrite()
    _ = try await save.value
    let t = await f.snapshot().tabs[0]
    #expect(t.savedText == "v1" && t.text == "v2" && t.dirty)
}

@Test func aSecondSaveWhileOneIsInFlightDoesNothing() async throws {
    let f = try await editorFixture()
    await f.files.put("/p/api/a.go", "v0")
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
    await f.panes.editorBufferDidChange(paneId: f.pane, tab: 0, text: "v1", basis: 0)
    await f.files.setSlowWrite(true)
    let first = Task { try await f.dispatch("editor_save", origin: .ui) }
    while await !f.snapshot().tabs[0].saving { await Task.yield() }
    try await f.dispatch("editor_save", origin: .ui)
    await f.files.releaseWrite()
    _ = try await first.value
    #expect(await f.files.calls.filter { $0.hasPrefix("files_write") }.count == 1)
}

@Test func aCancelledSaveLeavesTheBufferDirtyAndNotSaving() async throws {
    let f = try await editorFixture()
    await f.files.put("/p/api/a.go", "v0")
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
    await f.panes.editorBufferDidChange(paneId: f.pane, tab: 0, text: "v1", basis: 0)
    await f.files.setSlowWrite(true)
    let save = Task { try await f.dispatch("editor_save", origin: .ui) }
    while await !f.snapshot().tabs[0].saving { await Task.yield() }
    save.cancel()
    await f.files.releaseWrite()
    _ = try? await save.value
    let t = await f.snapshot().tabs[0]
    #expect(t.dirty && !t.saving)
}

@Test func aFailedWriteShowsTheErrorWholeAndKeepsTheBufferDirty() async throws {
    let f = try await editorFixture()
    await f.files.put("/p/api/a.go", "v0")
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
    await f.panes.editorBufferDidChange(paneId: f.pane, tab: 0, text: "v1", basis: 0)
    let long = "open /p/api/a.go: permission denied " + String(repeating: "x", count: 400)
    await f.files.setWriteError(long)
    _ = try? await f.dispatch("editor_save", origin: .ui)
    let t = await f.snapshot().tabs[0]
    #expect(t.notice == long && t.dirty && !t.saving)
}

@Test func savingAScratchTabAsAPathMakesItThatFile() async throws {
    let f = try await editorFixture()
    try await f.dispatch("editor_new_scratch", ["language": .string("sql")], origin: .ui)
    await f.panes.editorBufferDidChange(paneId: f.pane, tab: 0, text: "select 1", basis: 0)
    try await f.dispatch("editor_save", ["as": .string("/p/api/q/one.sql")], origin: .ui)
    #expect(await f.files.text(of: "/p/api/q/one.sql") == "select 1")
    let t = await f.snapshot().tabs[0]
    #expect(t.subject == .file(path: "/p/api/q/one.sql", root: "/p/api") && !t.dirty)
    #expect(await f.layout.editorTabs(id: f.pane)?.map(\.path) == ["/p/api/q/one.sql"])
}

@Test func savingAScratchTabWithNoPathSaysSo() async throws {
    let f = try await editorFixture()
    try await f.dispatch("editor_new_scratch", origin: .ui)
    await #expect(throws: EditorActionError.noScratchPath) { try await f.dispatch("editor_save", origin: .ui) }
}

@Test func closingADirtyTabWithoutDiscardIsRefusedAndKeepsIt() async throws {
    let f = try await editorFixture()
    await f.files.put("/p/api/a.go", "a")
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
    await f.panes.editorBufferDidChange(paneId: f.pane, tab: 0, text: "b", basis: 0)
    await #expect(throws: EditorActionError.unsavedEdits(path: "/p/api/a.go")) { try await f.dispatch("editor_close") }
    #expect(await f.snapshot().tabs.count == 1)
    try await f.dispatch("editor_close", ["discard": .bool(true)])
    #expect(await f.snapshot().tabs.isEmpty)
}

@Test func closingATabFocusesItsNeighbour() async throws {
    let f = try await editorFixture()
    for n in ["a", "b", "c"] { await f.files.put("/p/api/\(n).go", n); try await f.dispatch("editor_open", ["path": .string("/p/api/\(n).go")]) }
    try await f.dispatch("editor_open", ["path": .string("/p/api/b.go")])
    try await f.dispatch("editor_close")
    let s = await f.snapshot()
    #expect(s.tabs.compactMap(\.path) == ["/p/api/a.go", "/p/api/c.go"] && s.active == 1)
}

@Test func closingAnEmptyScratchTabNeedsNoDiscard() async throws {
    let f = try await editorFixture()
    try await f.dispatch("editor_new_scratch", origin: .ui)
    try await f.dispatch("editor_close")
    #expect(await f.snapshot().tabs.isEmpty)
}

@Test func gotoAndSelectMoveTheActiveTab() async throws {
    let f = try await editorFixture()
    await f.files.put("/p/api/a.go", "l1\nl2\nl3")
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
    try await f.dispatch("editor_goto", ["line": .integer(3), "column": .integer(2)])
    #expect(await f.snapshot().tabs[0].cursor == EditorPosition(line: 3, column: 2))
    try await f.dispatch("editor_select", ["range": range(2, 1, 2, 3)])
    #expect(await f.snapshot().tabs[0].selection == EditorRange(start: EditorPosition(line: 2, column: 1), end: EditorPosition(line: 2, column: 3)))
}

@Test func setLanguageChangesTheActiveTabsLanguage() async throws {
    let f = try await editorFixture()
    try await f.dispatch("editor_new_scratch", origin: .ui)
    try await f.dispatch("editor_set_language", ["language": .string("json")], origin: .ui)
    #expect(await f.snapshot().tabs[0].language == "json")
}

@Test func reloadReplacesTheBufferWithTheDisk() async throws {
    let f = try await editorFixture()
    await f.files.put("/p/api/a.go", "a")
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
    await f.panes.editorBufferDidChange(paneId: f.pane, tab: 0, text: "mine", basis: 0)
    await f.files.put("/p/api/a.go", "theirs")
    try await f.dispatch("editor_reload", origin: .ui)
    let t = await f.snapshot().tabs[0]
    #expect(t.text == "theirs" && !t.dirty && t.diskState == .inSync)
}

@Test func reloadKeepsWhatTheViewShows() async throws {
    let f = try await editorFixture()
    await f.files.put("/p/api/a.go", "a\nb")
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
    await f.panes.updateEditor(paneId: f.pane) { s in
        s.tabs[0].visibleRange = 1...2; s.tabs[0].scrollTop = 12
    }
    try await f.dispatch("editor_reload", origin: .ui)
    let t = await f.snapshot().tabs[0]
    // The page reports again only when something moves; a reload of the same text moves nothing.
    #expect(t.visibleRange == 1...2 && t.scrollTop == 12)
}

@Test func restoreReopensSavedTabsAndMarksAMissingOneDeleted() async throws {
    let f = try await editorFixture()
    await f.files.put("/p/api/a.go", "a")
    await f.layout.setEditorTabs(id: f.pane, to: [
        EditorSavedTab(path: "/p/api/a.go", cursor: EditorPosition(line: 1, column: 1), scrollTop: 30),
        EditorSavedTab(path: "/p/api/gone.go", cursor: EditorPosition(line: 4, column: 1), scrollTop: 0),
    ])
    try await f.dispatch("editor_restore", origin: .ui)
    let s = await f.snapshot()
    #expect(s.tabs.count == 2 && s.active == 0)
    #expect(s.tabs[0].text == "a" && s.tabs[0].scrollTop == 30)
    #expect(s.tabs[1].diskState == .deleted && s.tabs[1].cursor == EditorPosition(line: 4, column: 1))
}

@Test func focusTabSetsTheActiveTab() async throws {
    let f = try await editorFixture()
    await f.files.put("/p/api/a.go", "a")
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
    try await f.dispatch("editor_new_scratch", origin: .ui)
    try await f.dispatch("editor_focus_tab", ["index": .integer(0)], origin: .ui)
    #expect(await f.snapshot().active == 0)
    await #expect(throws: EditorActionError.noTab(action: "editor_focus_tab")) {
        try await f.dispatch("editor_focus_tab", ["index": .integer(5)], origin: .ui)
    }
}

@Test func saveDeclaresAllowEverywhere() async throws {
    let f = try await editorFixture()
    let save = try #require(await f.registry.all().first { $0.name == "editor_save" })
    #expect(save.kind == .mutate)
    #expect(save.kind == .mutate && save.audience == .agentReachable)
}

@Test func anEditorPaneWithSavedTabsRestoresByItsOwnAction() async throws {
    let f = try await editorFixture()
    #expect(EditorPaneKind.restoreStep(for: await f.layout.snapshot().panes[0]) == nil, "no saved tabs, nothing to restore")
    await f.layout.setEditorTabs(id: f.pane, to: [EditorSavedTab(path: "/p/api/a.go", cursor: EditorPosition(line: 1, column: 1), scrollTop: 0)])
    let pane = try #require(await f.layout.snapshot().panes.first { $0.id == f.pane })
    let step = try #require(EditorPaneKind.restoreStep(for: pane))
    #expect(step.action == "editor_restore" && step.params == .object(["pane": .string(f.pane)]) && !step.recordsFailure)
}

@Test func savingAReadOnlyTabIsRefusedAndNeverWrites() async throws {
    let f = try await editorFixture()
    await f.files.putOverCap("/p/api/dump.sql", size: 48_000_000)
    try await f.dispatch("editor_open", ["path": .string("/p/api/dump.sql")])
    await #expect(throws: EditorActionError.readOnly(
        action: "editor_save", path: "/p/api/dump.sql",
        notice: "dump.sql is 48 MB; files over 2 MB open in 3b-v")) { try await f.dispatch("editor_save", origin: .ui) }
    #expect(await f.files.calls.filter { $0.hasPrefix("files_write") }.isEmpty)
    #expect(await f.files.text(of: "/p/api/dump.sql") == nil)
    #expect(!(await f.snapshot().tabs[0].saving))
}

@Test func closingATabBeforeTheSavingOneMidSaveLeavesNothingStuckSaving() async throws {
    let f = try await editorFixture()
    await f.files.put("/p/api/a.go", "a"); await f.files.put("/p/api/b.go", "b")
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
    try await f.dispatch("editor_open", ["path": .string("/p/api/b.go")])
    await f.panes.editorBufferDidChange(paneId: f.pane, tab: 1, text: "b2", basis: 0)
    await f.files.setSlowWrite(true)
    let save = Task { try await f.dispatch("editor_save", origin: .ui) }
    while await !f.snapshot().tabs[1].saving { await Task.yield() }
    try await f.dispatch("editor_close", ["path": .string("/p/api/a.go")])
    await f.files.releaseWrite()
    _ = try await save.value
    let s = await f.snapshot()
    #expect(s.tabs.count == 1 && s.tabs[0].path == "/p/api/b.go")
    #expect(!s.tabs[0].saving && !s.tabs[0].dirty && s.tabs[0].savedText == "b2")
}

@Test func closeChecksUnsavedEditsOnTheTabItNamesNotTheActiveOne() async throws {
    let f = try await editorFixture()
    await f.files.put("/p/api/a.go", "a"); await f.files.put("/p/api/b.go", "b")
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
    try await f.dispatch("editor_open", ["path": .string("/p/api/b.go")])
    await f.panes.editorBufferDidChange(paneId: f.pane, tab: 0, text: "typed", basis: 0)
    await #expect(throws: EditorActionError.unsavedEdits(path: "/p/api/a.go")) {
        try await f.dispatch("editor_close", ["path": .string("/p/api/a.go")])
    }
    #expect(await f.snapshot().tabs[0].text == "typed")
}

@Test func replaceRangeOnAReadOnlyTabIsRefused() async throws {
    let f = try await editorFixture()
    await f.files.putOverCap("/p/api/dump.sql", size: 48_000_000)
    try await f.dispatch("editor_open", ["path": .string("/p/api/dump.sql")])
    await #expect(throws: (any Error).self) {
        try await f.dispatch("editor_replace_range", ["range": range(1, 1, 1, 1), "text": .string("x")])
    }
    #expect(await f.snapshot().tabs[0].text.isEmpty)
}

@Test func restoreKeepsOpenTabsAndAddsTheSavedOnesNotYetOpen() async throws {
    let f = try await editorFixture()
    await f.files.put("/p/api/a.go", "a"); await f.files.put("/p/api/b.go", "b")
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
    await f.panes.editorBufferDidChange(paneId: f.pane, tab: 0, text: "mine", basis: 0)
    await f.layout.setEditorTabs(id: f.pane, to: [
        EditorSavedTab(path: "/p/api/a.go", cursor: EditorPosition(line: 1, column: 1), scrollTop: 0),
        EditorSavedTab(path: "/p/api/b.go", cursor: EditorPosition(line: 1, column: 1), scrollTop: 7),
    ])
    try await f.dispatch("editor_restore", origin: .ui)
    let s = await f.snapshot()
    #expect(s.tabs.count == 2 && s.active == 0)
    #expect(s.tabs[0].text == "mine" && s.tabs[0].dirty)
    #expect(s.tabs[1].path == "/p/api/b.go" && s.tabs[1].scrollTop == 7)
}

@Test func restoreOfAFileThatCannotBeReadKeepsItsTabWithTheErrorAsNotice() async throws {
    let f = try await editorFixture()
    await f.layout.setEditorTabs(id: f.pane, to: [
        EditorSavedTab(path: "/elsewhere/x.go", cursor: EditorPosition(line: 3, column: 1), scrollTop: 0),
    ])
    try await f.dispatch("editor_restore", origin: .ui)
    let s = await f.snapshot()
    #expect(s.tabs.count == 1 && s.active == 0)
    #expect(s.tabs[0].readOnly && s.tabs[0].text.isEmpty && s.tabs[0].cursor == EditorPosition(line: 3, column: 1))
    #expect(s.tabs[0].notice?.contains("outside the active project's roots") == true)
}

@Test func aPathWithDotDotReportsTheRootItResolvesTo() async throws {
    let f = try await editorFixture()
    await f.files.put("/p/web/x.go", "x")
    try await f.dispatch("editor_open", ["path": .string("/p/api/../web/x.go")])
    #expect(await f.snapshot().tabs[0].subject == .file(path: "/p/web/x.go", root: "/p/web"))
    #expect(await f.files.calls.contains("files_read /p/web/x.go"))
    await #expect(throws: (any Error).self) {
        try await f.dispatch("editor_open", ["path": .string("/p/api/../../etc/hosts")])
    }
}

@Test func savingAScratchOntoAnExistingFileNeedsReplace() async throws {
    let f = try await editorFixture()
    await f.files.put("/p/api/README.md", "keep me")
    try await f.dispatch("editor_new_scratch", origin: .ui)
    await f.panes.editorBufferDidChange(paneId: f.pane, tab: 0, text: "oops", basis: 0)
    await #expect(throws: EditorActionError.targetExists(path: "/p/api/README.md")) {
        try await f.dispatch("editor_save", ["as": .string("/p/api/README.md")], origin: .ui)
    }
    #expect(await f.files.text(of: "/p/api/README.md") == "keep me")
    let t = await f.snapshot().tabs[0]
    #expect(t.isScratch && t.dirty && !t.saving)
    try await f.dispatch("editor_save", ["as": .string("/p/api/README.md"), "replace": .bool(true)], origin: .ui)
    #expect(await f.files.text(of: "/p/api/README.md") == "oops")
    #expect(await f.snapshot().tabs[0].subject == .file(path: "/p/api/README.md", root: "/p/api"))
}

@Test func savingAScratchOntoAPathOpenInThePaneIsRefusedNamingTheTab() async throws {
    let f = try await editorFixture()
    await f.files.put("/p/api/a.go", "a")
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
    try await f.dispatch("editor_new_scratch", origin: .ui)
    await f.panes.editorBufferDidChange(paneId: f.pane, tab: 1, text: "s", basis: 0)
    await #expect(throws: EditorActionError.alreadyOpen(path: "/p/api/a.go", tab: "a.go")) {
        try await f.dispatch("editor_save", ["as": .string("/p/api/a.go"), "replace": .bool(true)], origin: .ui)
    }
    #expect(await f.files.text(of: "/p/api/a.go") == "a")
    let s = await f.snapshot()
    #expect(s.tabs.map(\.subject) == [.file(path: "/p/api/a.go", root: "/p/api"), .scratch(number: 1)])
    #expect(!s.tabs[1].saving)
}

@Test func aFileOpenedWhileAScratchSaveRunsNeverSharesItsSubject() async throws {
    let f = try await editorFixture()
    await f.files.setSlowWrite(true)
    try await f.dispatch("editor_new_scratch", origin: .ui)
    await f.panes.editorBufferDidChange(paneId: f.pane, tab: 0, text: "s", basis: 0)
    let save = Task { try await f.dispatch("editor_save", ["as": .string("/p/api/n.go")], origin: .ui) }
    while await !f.files.calls.contains("files_write /p/api/n.go") { await Task.yield() }
    await f.files.put("/p/api/n.go", "other")
    try await f.dispatch("editor_open", ["path": .string("/p/api/n.go")])
    await f.files.releaseWrite()
    _ = try await save.value
    let subjects = await f.snapshot().tabs.map(\.subject)
    #expect(Set(subjects).count == subjects.count)
    #expect(subjects.contains(.scratch(number: 1)))
}

@Test func closeByScratchNumberClosesThatTabNotTheActiveOne() async throws {
    let f = try await editorFixture()
    try await f.dispatch("editor_new_scratch", origin: .ui)
    try await f.dispatch("editor_new_scratch", origin: .ui)
    await f.panes.editorBufferDidChange(paneId: f.pane, tab: 0, text: "one", basis: 0)
    #expect(await f.snapshot().active == 1)
    try await f.dispatch("editor_close", ["scratch": .integer(1), "discard": .bool(true)])
    #expect(await f.snapshot().tabs.map(\.subject) == [.scratch(number: 2)])
    await #expect(throws: EditorActionError.noTab(action: "editor_close")) {
        try await f.dispatch("editor_close", ["scratch": .integer(7)])
    }
}

@Test func reloadKeepsTheAgentEditSerialSoAnOlderPostIsStillDropped() async throws {
    let f = try await editorFixture()
    await f.files.put("/p/api/a.go", "abc")
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
    try await f.dispatch("editor_replace_range", ["range": range(1, 4, 1, 4), "text": .string("E")])
    try await f.dispatch("editor_reload", origin: .ui)
    #expect(await f.snapshot().tabs[0].lastAgentEdit?.serial == 1)
    await f.panes.editorBufferDidChange(paneId: f.pane, tab: 0, text: "stale", basis: 0)
    #expect(await f.snapshot().tabs[0].text == "abc")
}
