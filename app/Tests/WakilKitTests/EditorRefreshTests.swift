import Foundation
import Testing
@testable import WakilKit

private func openA(_ f: EditorFixture, _ text: String = "a") async throws {
    await f.files.put("/p/api/a.go", text)
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
}

@Test func aCleanTabReloadsInPlaceKeepingCursorAndScroll() async throws {
    let f = try await editorFixture()
    try await openA(f, "one\ntwo")
    await f.panes.editorViewDidReport(paneId: f.pane, tab: 0, cursor: EditorPosition(line: 2, column: 2),
                                      selection: nil, visibleRange: 1...2, scrollTop: 40)
    await f.files.put("/p/api/a.go", "one\ntwo\nthree")
    try await f.dispatch("editor_refresh", origin: .ui)
    let t = await f.snapshot().tabs[0]
    #expect(t.text == "one\ntwo\nthree" && !t.dirty && t.diskState == .inSync)
    #expect(t.cursor == EditorPosition(line: 2, column: 2) && t.scrollTop == 40)
}

@Test func aDirtyTabKeepsTheOperatorsTextAndIsMarkedChangedOnDisk() async throws {
    let f = try await editorFixture()
    try await openA(f)
    await f.panes.editorBufferDidChange(paneId: f.pane, tab: 0, text: "mine", basis: 0)
    await f.files.put("/p/api/a.go", "theirs")
    try await f.dispatch("editor_refresh", origin: .ui)
    let t = await f.snapshot().tabs[0]
    #expect(t.text == "mine" && t.diskState == .changedOnDisk)
}

@Test func aDiskChangeMatchingTheBufferMarksTheTabClean() async throws {
    let f = try await editorFixture()
    try await openA(f)
    await f.panes.editorBufferDidChange(paneId: f.pane, tab: 0, text: "same", basis: 0)
    await f.files.put("/p/api/a.go", "same")
    try await f.dispatch("editor_refresh", origin: .ui)
    let t = await f.snapshot().tabs[0]
    #expect(!t.dirty && t.diskState == .inSync && t.savedText == "same")
}

@Test func aDeletedFileKeepsItsTabAndTextMarkedDeletedAndSaveRecreatesIt() async throws {
    let f = try await editorFixture()
    try await openA(f, "keep me")
    await f.files.remove("/p/api/a.go")
    try await f.dispatch("editor_refresh", origin: .ui)
    var t = await f.snapshot().tabs[0]
    #expect(t.text == "keep me" && t.diskState == .deleted)
    try await f.dispatch("editor_save", origin: .ui)
    t = await f.snapshot().tabs[0]
    #expect(await f.files.text(of: "/p/api/a.go") == "keep me" && t.diskState == .inSync)
}

@Test func anUnchangedMtimeChangesNothing() async throws {
    let f = try await editorFixture()
    try await openA(f)
    let before = await f.snapshot()
    try await f.dispatch("editor_refresh", origin: .ui)
    #expect(await f.snapshot() == before)
}

@Test func refreshOfOneRootLeavesOtherRootsTabsUnread() async throws {
    let f = try await editorFixture()
    try await openA(f)
    await f.files.put("/p/web/b.ts", "b")
    try await f.dispatch("editor_open", ["path": .string("/p/web/b.ts")])
    let reads = await f.files.calls.count
    try await f.dispatch("editor_refresh", ["root": .string("/p/web")], origin: .ui)
    #expect(await f.files.calls.suffix(from: reads) == ["files_read /p/web/b.ts"])
}

@Test func savingOverAChangedOnDiskFileWritesTheBuffer() async throws {
    let f = try await editorFixture()
    try await openA(f)
    await f.panes.editorBufferDidChange(paneId: f.pane, tab: 0, text: "mine", basis: 0)
    await f.files.put("/p/api/a.go", "theirs")
    try await f.dispatch("editor_refresh", origin: .ui)
    try await f.dispatch("editor_save", origin: .ui)
    #expect(await f.files.text(of: "/p/api/a.go") == "mine")
    #expect(await f.snapshot().tabs[0].diskState == .inSync)
}

@Test func aSaveThatLandsDuringARefreshReadIsNotRewoundByTheStaleRead() async throws {
    let f = try await editorFixture()
    try await openA(f, "old")
    await f.panes.editorBufferDidChange(paneId: f.pane, tab: 0, text: "saved", basis: 0)
    await f.files.setSlowRead(true)
    let refresh = Task { try await f.dispatch("editor_refresh", origin: .ui) }
    // The refresh's read has taken the disk's old text and is parked.
    while await f.files.calls.filter({ $0 == "files_read /p/api/a.go" }).count < 2 { await Task.yield() }
    await f.files.setSlowRead(false)
    try await f.dispatch("editor_save", origin: .ui)
    let saved = await f.snapshot().tabs[0]
    await f.files.releaseRead()
    _ = try await refresh.value
    let t = await f.snapshot().tabs[0]
    #expect(t.text == "saved" && t.savedText == "saved" && t.diskState == .inSync)
    #expect(t.mtime == saved.mtime && t.edits == saved.edits)
}

@Test func aRefreshDuringAnInFlightSaveLeavesTheSavingTabUntouched() async throws {
    let f = try await editorFixture()
    try await openA(f, "old")
    await f.panes.editorBufferDidChange(paneId: f.pane, tab: 0, text: "mine", basis: 0)
    await f.files.setSlowWrite(true)
    let save = Task { try await f.dispatch("editor_save", origin: .ui) }
    while !(await f.snapshot().tabs[0].saving) { await Task.yield() }
    await f.files.put("/p/api/a.go", "theirs")
    let before = await f.snapshot()
    try await f.dispatch("editor_refresh", origin: .ui)
    #expect(await f.snapshot() == before)
    await f.files.releaseWrite()
    _ = try await save.value
}

// A refresh with no root (every root) marks any search results changed since; none, nothing.
@Test func aRefreshOfEveryRootMarksAnyResultsChangedSince() async throws {
    let f = try await editorFixture()
    try await f.dispatch("editor_refresh", origin: .ui)
    #expect(await f.snapshot().search.changedSince == false)
    await f.files.setSearch([("/p/web", "r.ts", 1, 1, "x")])
    try await f.dispatch("editor_search", ["query": .string("x")])
    try await f.dispatch("editor_refresh", origin: .ui)
    #expect(await f.snapshot().search.changedSince == true)
}
