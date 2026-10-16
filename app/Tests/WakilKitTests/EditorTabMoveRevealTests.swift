import Foundation
import Testing
@testable import WakilKit

private func threeTabs() async throws -> EditorFixture {
    let f = try await editorFixture()
    for p in ["/p/api/a.go", "/p/api/b.go", "/p/web/c.ts"] {
        await f.files.put(p, "x")
        try await f.dispatch("editor_open", ["path": .string(p)])
    }
    return f
}

@Test func moveTabReordersKeepsTheActiveTabAndPersists() async throws {
    let f = try await threeTabs()
    try await f.dispatch("editor_focus_tab", ["index": .integer(1)])
    try await f.dispatch("editor_move_tab", ["from": .integer(0), "to": .integer(2)])
    let s = await f.snapshot()
    #expect(s.tabs.map(\.path) == ["/p/api/b.go", "/p/web/c.ts", "/p/api/a.go"])
    #expect(s.active == 0)
    #expect(await f.layout.editorTabs(id: f.pane)?.map(\.path) == ["/p/api/b.go", "/p/web/c.ts", "/p/api/a.go"])
}

@Test func aMovedOrderComesBackOnRestore() async throws {
    let f = try await threeTabs()
    try await f.dispatch("editor_move_tab", ["from": .integer(2), "to": .integer(0)])
    // A relaunch: the store holds nothing, the layout kept the saved tabs.
    await f.panes.updateEditor(paneId: f.pane) { s in s.tabs = []; s.active = nil }
    try await f.dispatch("editor_restore")
    #expect(await f.snapshot().tabs.map(\.path) == ["/p/web/c.ts", "/p/api/a.go", "/p/api/b.go"])
}

@Test func aMoveOutOfRangeIsRefusedAndMovesNothing() async throws {
    let f = try await threeTabs()
    await #expect(throws: EditorActionError.noTab(action: "editor_move_tab")) {
        try await f.dispatch("editor_move_tab", ["from": .integer(5), "to": .integer(0)])
    }
    #expect(await f.snapshot().tabs.map(\.path) == ["/p/api/a.go", "/p/api/b.go", "/p/web/c.ts"])
}

@Test func revealOpensEveryFolderAboveTheActiveFile() async throws {
    let f = try await editorFixture()
    await f.files.put("/p/api/app/Models/Booking.php", "x")
    try await f.dispatch("editor_open", ["path": .string("/p/api/app/Models/Booking.php")])
    try await f.dispatch("editor_tree_reveal")
    #expect(await f.snapshot().column?.open == ["/p/api", "/p/api/app", "/p/api/app/Models"])
}

@Test func revealTakesAPathAndOpensFoldersOnly() async throws {
    let f = try await editorFixture()
    try await f.dispatch("editor_tree_reveal", ["path": .string("/p/web/src/r.ts")])
    let c = await f.snapshot().column
    #expect(c?.open == ["/p/web", "/p/web/src"])
    #expect(c?.shown == EditorColumnState.initial.shown)      // the operator's view is not moved
}

@Test func revealRefusesAPathOutsideTheRootsAndNeedsAFileTab() async throws {
    let f = try await editorFixture()
    do {
        try await f.dispatch("editor_tree_reveal", ["path": .string("/etc/hosts")])
        Issue.record("expected the refusal")
    } catch { #expect(String(describing: error).contains("Invariant 6")) }
    await #expect(throws: EditorActionError.noTab(action: "editor_tree_reveal")) { try await f.dispatch("editor_tree_reveal") }
    try await f.dispatch("editor_new_scratch")
    await #expect(throws: EditorActionError.notAFile(action: "editor_tree_reveal")) { try await f.dispatch("editor_tree_reveal") }
}
