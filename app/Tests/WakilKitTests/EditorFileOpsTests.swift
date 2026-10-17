import Foundation
import Testing
@testable import WakilKit

private func tab(_ path: String, text: String = "t", saved: String = "t") -> EditorTab {
    var t = EditorTab.file(path: path, root: "/p/api", text: saved, mtime: 1, language: editorLanguage(forPath: path))
    t.text = text
    return t
}

@Test func repointMovesAFileTabAndRemembersItsKey() {
    let out = editorRepointTabs([tab("/p/api/a.go")], from: "/p/api/a.go", to: "/p/api/b.go", root: "/p/api")
    #expect(out[0].path == "/p/api/b.go")
    #expect(out[0].formerKeys == ["file:/p/api/a.go"])
}

@Test func repointMovesEveryTabUnderAFolderAndKeepsEdits() {
    let tabs = [tab("/p/api/d/x.go", text: "dirty"), tab("/p/api/dx.go"), tab("/p/api/d/e/y.go")]
    let out = editorRepointTabs(tabs, from: "/p/api/d", to: "/p/web/z", root: "/p/web")
    #expect(out.map(\.path) == ["/p/web/z/x.go", "/p/api/dx.go", "/p/web/z/e/y.go"])
    #expect(out[0].text == "dirty" && out[0].dirty)
    var root0: String?
    if case .file(_, let root) = out[0].subject { root0 = root }
    #expect(root0 == "/p/web")
}

@Test func repointRelabelsTheLanguageOnlyWhenItWasDerived() {
    var manual = tab("/p/api/a.txt")
    manual.language = "sql"
    let out = editorRepointTabs([tab("/p/api/a.txt"), manual], from: "/p/api/a.txt", to: "/p/api/a.go", root: "/p/api")
    #expect(out[0].language == "go")
    // The second tab shares the path only in this test; a real pane never holds two.
    #expect(out[1].language == "sql")
}

@Test func repointDropsDiffTabsAtOrUnder() {
    let diff = EditorTab.diff(root: "/p/api", path: "d/x.go", group: .changed)
    let out = editorRepointTabs([diff, tab("/p/api/k.go")], from: "/p/api/d", to: "/p/api/e", root: "/p/api")
    #expect(out.map(\.path) == ["/p/api/k.go"])
}

@Test func trashClosesCleanTabsAndMarksDirtyOnesDeleted() {
    let tabs = [tab("/p/api/d/a.go"), tab("/p/api/d/b.go", text: "edit"), tab("/p/api/c.go")]
    let out = editorTabsAfterTrash(tabs, path: "/p/api/d")
    #expect(out.map(\.path) == ["/p/api/d/b.go", "/p/api/c.go"])
    #expect(out[0].diskState == .deleted && out[0].text == "edit")
}

@Test func activeFollowsItsTabOrFallsToANeighbour() {
    let old = [tab("/p/api/a.go"), tab("/p/api/b.go"), tab("/p/api/c.go")]
    let gone = editorTabsAfterTrash(old, path: "/p/api/b.go")
    #expect(editorActiveAfter(old, active: 1, new: gone) == 1)   // c.go, the neighbour
    #expect(editorActiveAfter(old, active: 2, new: gone) == 1)   // c.go itself
    let moved = editorRepointTabs(old, from: "/p/api/c.go", to: "/p/api/z.go", root: "/p/api")
    #expect(editorActiveAfter(old, active: 2, new: moved) == 2)
    #expect(editorActiveAfter(old, active: 0, new: []) == nil)
}

@Test func renameTargetResolvesAgainstTheItemsFolder() {
    #expect(editorRenameTarget(of: "/p/api/d/a.go", typed: "b.go") == "/p/api/d/b.go")
    #expect(editorRenameTarget(of: "/p/api/d/a.go", typed: "sub/b.go") == "/p/api/d/sub/b.go")
    #expect(editorRenameTarget(of: "/p/api/d/a.go", typed: "../b.go") == "/p/api/b.go")
    #expect(editorRenameTarget(of: "/p/api/d/a.go", typed: "/b.go") == "/p/api/d/b.go")
}

@Test func aDoubleRepointKeepsBothFormerKeysOldestFirst() {
    let once = editorRepointTabs([tab("/p/api/a.go")], from: "/p/api/a.go", to: "/p/api/b.go", root: "/p/api")
    let twice = editorRepointTabs(once, from: "/p/api/b.go", to: "/p/api/c.go", root: "/p/api")
    #expect(twice[0].formerKeys == ["file:/p/api/a.go", "file:/p/api/b.go"])
}

@Test func activeAfterIgnoresAFormerKeyWhoseOldTabStillExists() {
    // old: a.go and b.go; a.go renamed to c.go then b.go renamed to a.go would leave stale keys, but a
    // tab whose own key is still in `new` is matched by that key only.
    let old = [tab("/p/api/a.go"), tab("/p/api/b.go")]
    var moved = tab("/p/api/c.go")
    moved.formerKeys = ["file:/p/api/b.go"]
    let new = [tab("/p/api/b.go"), moved]
    #expect(editorActiveAfter(old, active: 1, new: new) == 0)
}

@Test func renameRepointsTheTabInEveryPaneAndJournalsIt() async throws {
    let f = try await editorFixture()
    await f.files.put("/p/api/a.go", "v0")
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
    await f.panes.editorBufferDidChange(paneId: f.pane, tab: 0, text: "v1", basis: 0)
    let other = await f.layout.open(kind: "editor", title: "Editor").id
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go"), "pane": .string(other)])
    try await f.dispatch("editor_rename", ["path": .string("/p/api/a.go"), "to": .string("/p/api/sub/b.go")])
    #expect(await f.files.calls.contains("files_move /p/api/a.go -> /p/api/sub/b.go"))
    let mine = await f.snapshot().tabs[0]
    #expect(mine.path == "/p/api/sub/b.go" && mine.text == "v1" && mine.dirty)
    #expect(await f.panes.editorSnapshot(paneId: other).tabs[0].path == "/p/api/sub/b.go")
}

@Test func aRefusedRenameLeavesTabsAndSaysWhy() async throws {
    let f = try await editorFixture()
    await f.files.put("/p/api/a.go", "v0")
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
    await f.files.setMoveError("/p/api/b.go already exists")
    await #expect(throws: (any Error).self) {
        try await f.dispatch("editor_rename", ["path": .string("/p/api/a.go"), "to": .string("/p/api/b.go")])
    }
    #expect(await f.snapshot().tabs[0].path == "/p/api/a.go")
}

@Test func renameOutsideTheRootsIsRefusedBeforeAnyCall() async throws {
    let f = try await editorFixture()
    await f.files.put("/p/api/a.go", "v0")
    await #expect(throws: (any Error).self) {
        try await f.dispatch("editor_rename", ["path": .string("/p/api/a.go"), "to": .string("/etc/a.go")])
    }
    #expect(await !f.files.calls.contains { $0.hasPrefix("files_move") })
}

@Test func trashClosesACleanTabAndKeepsADirtyOne() async throws {
    let f = try await editorFixture()
    await f.files.put("/p/api/d/a.go", "a")
    await f.files.put("/p/api/d/b.go", "b")
    try await f.dispatch("editor_open", ["path": .string("/p/api/d/a.go")])
    try await f.dispatch("editor_open", ["path": .string("/p/api/d/b.go")])
    await f.panes.editorBufferDidChange(paneId: f.pane, tab: 1, text: "b!", basis: 0)
    try await f.dispatch("editor_trash", ["path": .string("/p/api/d")])
    let tabs = await f.snapshot().tabs
    #expect(tabs.map(\.path) == ["/p/api/d/b.go"])
    #expect(tabs[0].diskState == .deleted && tabs[0].text == "b!")
    #expect(await f.snapshot().active == 0)
}

@Test func aDirtyTabLeftByTrashRecreatesItsFileOnSave() async throws {
    let f = try await editorFixture()
    await f.files.put("/p/api/a.go", "a")
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
    await f.panes.editorBufferDidChange(paneId: f.pane, tab: 0, text: "a!", basis: 0)
    try await f.dispatch("editor_trash", ["path": .string("/p/api/a.go")])
    try await f.dispatch("editor_save")
    #expect(await f.files.text(of: "/p/api/a.go") == "a!")
}

@Test func createAFileOpensItPinned() async throws {
    let f = try await editorFixture()
    try await f.dispatch("editor_create", ["path": .string("/p/api/n/new.ts"), "kind": .string("file")])
    let s = await f.snapshot()
    #expect(s.tabs.map(\.path) == ["/p/api/n/new.ts"] && s.active == 0 && !s.tabs[0].preview)
}

@Test func createAnExistingNameIsRefusedWhole() async throws {
    let f = try await editorFixture()
    await f.files.put("/p/api/a.go", "a")
    do {
        try await f.dispatch("editor_create", ["path": .string("/p/api/a.go"), "kind": .string("file")])
        Issue.record("created over a file")
    } catch {
        #expect(String(describing: error).contains("/p/api/a.go already exists"))
    }
}

@Test func theThreeActionsAreAllowedInProductionForTheAgent() async throws {
    let f = try await editorFixture()
    await f.files.put("/p/api/a.go", "a")
    try await f.dispatch("editor_create", ["path": .string("/p/api/b.go"), "kind": .string("file")], origin: .agent, environment: "production")
    try await f.dispatch("editor_rename", ["path": .string("/p/api/b.go"), "to": .string("/p/api/c.go")], origin: .agent, environment: "production")
    try await f.dispatch("editor_trash", ["path": .string("/p/api/c.go")], origin: .agent, environment: "production")
}

// Review Focus 1. Autosave arms by path (EditorAutosave.observe); a renamed dirty tab must be armed
// under its new path, or its pending save would name a tab that no longer exists.
@Test func aRenamedDirtyTabIsArmedUnderItsNewPath() {
    var a = EditorAutosave()
    var clean = EditorTab.file(path: "/p/a", root: "/p", text: "x", mtime: 1, language: "go")
    _ = a.observe(pane: "e1", snapshot: EditorSnapshot(tabs: [clean], active: 0), mode: .pause)
    clean.text = "y"; clean.edits = 1
    let typed = EditorSnapshot(tabs: [clean], active: 0)
    #expect(a.observe(pane: "e1", snapshot: typed, mode: .pause).arm == ["/p/a"])
    let moved = EditorSnapshot(tabs: editorRepointTabs(typed.tabs, from: "/p/a", to: "/p/b", root: "/p"), active: 0)
    #expect(a.observe(pane: "e1", snapshot: moved, mode: .pause).arm == ["/p/b"])
}

// Review Focus 2: a tab open in another conversation's pane (a scope not on screen) follows too.
@Test func aTabInAHiddenScopeIsRepointedToo() async throws {
    let f = try await editorFixture()
    await f.files.put("/p/api/a.go", "v0")
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
    let home = await f.panes.activeScope
    await f.panes.switchScope(to: LayoutScope(organization: home.organization, project: home.project, lineageRoot: "conv-2"))
    try await f.dispatch("editor_rename", ["path": .string("/p/api/a.go"), "to": .string("/p/api/b.go")])
    #expect(await f.panes.editorSnapshot(in: home, paneId: f.pane).tabs[0].path == "/p/api/b.go")
}

// Ruling R4: a rename to the same name changes nothing — no move, no tab re-pointed, no diff tab closed.
@Test func aSameNameRenameChangesNothing() async throws {
    let f = try await changesFixture()
    await f.files.put("/p/api/a.go", "v0")
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
    try await f.dispatch("editor_changes_select", ["root": .string("/p/api"), "path": .string("a.go"),
                                                  "group": .string("changed"), "pin": .bool(true)])
    let before = await f.snapshot().tabs
    #expect(before.count == 2)
    try await f.dispatch("editor_rename", ["path": .string("/p/api/a.go"), "to": .string("/p/api/a.go")])
    let after = await f.snapshot().tabs
    #expect(after.map(\.subject) == before.map(\.subject))
    #expect(after.allSatisfy { $0.formerKeys.isEmpty })
    #expect(await !f.files.calls.contains { $0.hasPrefix("files_move") })
}

// A rename while a save is in flight re-points the tab; the save's release still finds it by the
// claimed subject's former key, so `saving` never sticks (final review I2).
@Test func aRenameDuringAnInFlightSaveStillReleasesTheTab() async throws {
    let f = try await editorFixture()
    await f.files.put("/p/api/a.go", "v0")
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
    await f.panes.editorBufferDidChange(paneId: f.pane, tab: 0, text: "v1", basis: 0)
    await f.files.setSlowWrite(true)
    let save = Task { try await f.dispatch("editor_save", origin: .ui) }
    while !(await f.snapshot().tabs[0].saving) { await Task.yield() }
    try await f.dispatch("editor_rename", ["path": .string("/p/api/a.go"), "to": .string("/p/api/b.go")])
    await f.files.releaseWrite()
    // The fake parks before writing, so the write lands after the move and finds a.go gone: the
    // save fails, says so on the re-pointed tab, and keeps its edit unsaved.
    await #expect(throws: (any Error).self) { _ = try await save.value }
    let t = await f.snapshot().tabs[0]
    #expect(t.path == "/p/api/b.go" && t.text == "v1")
    #expect(!t.saving)
    #expect(t.notice?.contains("does not exist") == true)
    // Not stuck: the next save runs (no busy) and writes b.go.
    await f.files.setSlowWrite(false)
    try await f.dispatch("editor_save", origin: .ui)
    let after = await f.snapshot().tabs[0]
    #expect(!after.saving && !after.dirty)
    #expect(await f.files.text(of: "/p/api/b.go") == "v1")
}
