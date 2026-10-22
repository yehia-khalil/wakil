import Foundation
import Testing
@testable import WakilKit

/// /p/api: a.go staged, b.go changed, n untracked; /p/web: i.ts changed. The status read once.
func changesFixture() async throws -> EditorFixture {
    let f = try await editorFixture()
    await f.git.set(status: "/p/api", files: [("a.go", "staged", "A"), ("b.go", "changed", "M"), ("n", "untracked", "?")])
    await f.git.set(status: "/p/web", files: [("i.ts", "changed", "M")])
    await f.status.refresh()
    return f
}

private func highlight(_ f: EditorFixture) async -> EditorChangesRow? { await f.snapshot().column?.changesHighlight }

@Suite struct EditorChangesActionsTests {
    @Test func theTreeShowsTheChangesView() async throws {
        let f = try await changesFixture()
        try await f.dispatch("editor_tree", ["view": .string("changes")])
        let c = try #require(await f.snapshot().column)
        #expect(c.shown && c.view == .changes)
    }

    @Test func selectHighlightsTheRow() async throws {
        let f = try await changesFixture()
        try await f.dispatch("editor_changes_select", ["root": .string("/p/api"), "path": .string("b.go"),
                                                       "group": .string("changed")])
        #expect(await highlight(f) == EditorChangesRow(root: "/p/api", path: "b.go", group: "changed"))
    }

    @Test func selectRefusesARootOutsideTheProjectNamingTheRoots() async throws {
        let f = try await changesFixture()
        await #expect(throws: GitActionError.notAProjectRoot(action: "editor_changes_select", root: "/x",
                                                             roots: ["/p/api", "/p/web"])) {
            try await f.dispatch("editor_changes_select", ["root": .string("/x"), "path": .string("a"),
                                                           "group": .string("changed")])
        }
    }

    @Test func selectRefusesAnUnknownGroup() async throws {
        let f = try await changesFixture()
        await #expect(throws: GitActionError.unknownGroup(action: "editor_changes_select", group: "stash")) {
            try await f.dispatch("editor_changes_select", ["root": .string("/p/api"), "path": .string("a"),
                                                           "group": .string("stash")])
        }
    }

    @Test func stepMovesAcrossGroupsAndRootsAndSkipsACollapsedRoot() async throws {
        let f = try await changesFixture()
        try await f.dispatch("editor_changes_step", ["delta": .integer(1)])
        #expect(await highlight(f)?.path == "a.go")
        try await f.dispatch("editor_changes_step", ["delta": .integer(3)])
        #expect(await highlight(f) == EditorChangesRow(root: "/p/web", path: "i.ts", group: "changed"))
        try await f.dispatch("editor_changes_collapse", ["root": .string("/p/web")])
        #expect(await f.snapshot().column?.changesClosed == ["/p/web"])
        try await f.dispatch("editor_changes_step", ["delta": .integer(-1)])
        // The highlight sat in the root just collapsed, so it is not drawn: a step starts again at the
        // first drawn row, as one with nothing highlighted does (`editorChangesStep`).
        #expect(await highlight(f)?.path == "a.go")
        try await f.dispatch("editor_changes_expand", ["root": .string("/p/web")])
        #expect(await f.snapshot().column?.changesClosed == [])
    }

    // 3a-ii review I2: a group collapses through an action, as a root does, and a step skips it.
    @Test func groupCollapseAndExpandKeepTheGroupAndAStepSkipsIt() async throws {
        let f = try await changesFixture()
        try await f.dispatch("editor_changes_group_collapse", ["root": .string("/p/api"), "group": .string("changed")])
        #expect(await f.snapshot().column?.changesClosedGroups == [EditorChangesGroup(root: "/p/api", group: "changed")])
        try await f.dispatch("editor_changes_step", ["delta": .integer(1)])
        try await f.dispatch("editor_changes_step", ["delta": .integer(1)])
        #expect(await highlight(f) == EditorChangesRow(root: "/p/api", path: "n", group: "untracked"))
        try await f.dispatch("editor_changes_group_collapse", ["root": .string("/p/api"), "group": .string("changed")])
        #expect(await f.snapshot().column?.changesClosedGroups.count == 1, "collapsing twice is collapsing once")
        try await f.dispatch("editor_changes_group_expand", ["root": .string("/p/api"), "group": .string("changed")])
        #expect(await f.snapshot().column?.changesClosedGroups == [])
    }

    @Test func aStepOrASelectionNeverOpensAClosedGroup() async throws {
        let f = try await changesFixture()
        try await f.dispatch("editor_changes_group_collapse", ["root": .string("/p/api"), "group": .string("untracked")])
        try await f.dispatch("editor_changes_step", ["delta": .integer(9)])
        try await f.dispatch("editor_changes_select", ["root": .string("/p/api"), "path": .string("n"),
                                                       "group": .string("untracked")])
        #expect(await f.snapshot().column?.changesClosedGroups == [EditorChangesGroup(root: "/p/api", group: "untracked")])
    }

    @Test func collapsingTheHighlightsGroupMovesTheHighlightToADrawnRow() async throws {
        let f = try await changesFixture()
        try await f.dispatch("editor_changes_select", ["root": .string("/p/api"), "path": .string("b.go"),
                                                       "group": .string("changed")])
        try await f.dispatch("editor_changes_group_collapse", ["root": .string("/p/api"), "group": .string("changed")])
        #expect(await highlight(f) == EditorChangesRow(root: "/p/api", path: "n", group: "untracked"))
    }

    @Test func groupCollapseRefusesAnUnknownGroupAndARootOutsideTheProject() async throws {
        let f = try await changesFixture()
        await #expect(throws: GitActionError.unknownGroup(action: "editor_changes_group_collapse", group: "stash")) {
            try await f.dispatch("editor_changes_group_collapse", ["root": .string("/p/api"), "group": .string("stash")])
        }
        await #expect(throws: GitActionError.self) {
            try await f.dispatch("editor_changes_group_expand", ["root": .string("/x"), "group": .string("staged")])
        }
        await #expect(throws: StandardActionError.self) {
            try await f.dispatch("editor_changes_group_collapse", ["root": .string("/p/api")])
        }
    }

    @Test func collapseRefusesARootOutsideTheProject() async throws {
        let f = try await changesFixture()
        await #expect(throws: GitActionError.self) {
            try await f.dispatch("editor_changes_collapse", ["root": .string("/x")])
        }
    }

    @Test func aGitRefreshMovesAVanishedHighlightToItsNeighbour() async throws {
        let f = try await changesFixture()
        try await f.dispatch("editor_changes_select", ["root": .string("/p/api"), "path": .string("a.go"),
                                                       "group": .string("staged")])
        await f.git.set(status: "/p/api", files: [("b.go", "changed", "M"), ("n", "untracked", "?")])
        await f.status.refresh(only: "/p/api")
        try await f.dispatch("editor_refresh", ["root": .string("/p/api"), "what": .string("git")])
        #expect(await highlight(f)?.path == "b.go")
    }

    @Test func refreshReadsTheStatusOnlyWhenAskedForEverything() async throws {
        let f = try await changesFixture()
        let before = await f.git.statusCount
        try await f.dispatch("editor_refresh", ["what": .string("files")])
        try await f.dispatch("editor_refresh", ["what": .string("git")])
        #expect(await f.git.statusCount == before)
        try await f.dispatch("editor_refresh", [:])
        #expect(await f.git.statusCount == before + 2, "all: one read per root")
    }

    @Test func refreshRefusesAnUnknownWhat() async throws {
        let f = try await changesFixture()
        await #expect(throws: (any Error).self) {
            try await f.dispatch("editor_refresh", ["what": .string("everything")])
        }
    }

    @Test func readPaneCarriesTheClosedGroups() async throws {
        let f = try await changesFixture()
        try await f.dispatch("editor_changes_group_collapse", ["root": .string("/p/web"), "group": .string("changed")])
        try await f.dispatch("editor_changes_group_collapse", ["root": .string("/p/api"), "group": .string("untracked")])
        guard case .object(let o) = await f.panes.readPane(paneId: f.pane, kind: "editor"),
              case .object(let c)? = o["column"] else { Issue.record("no column"); return }
        #expect(c["changes_closed_groups"] == .array([
            .object(["root": .string("/p/api"), "group": .string("untracked")]),
            .object(["root": .string("/p/web"), "group": .string("changed")])]))
    }

    @Test func readPaneCarriesTheHighlightAndTheCollapsedRoots() async throws {
        let f = try await changesFixture()
        try await f.dispatch("editor_changes_collapse", ["root": .string("/p/web")])
        try await f.dispatch("editor_changes_step", ["delta": .integer(1)])
        guard case .object(let o) = await f.panes.readPane(paneId: f.pane, kind: "editor"),
              case .object(let c)? = o["column"] else { Issue.record("no column"); return }
        #expect(c["changes_closed"] == .array([.string("/p/web")]))
        #expect(c["changes_closed_groups"] == .array([]))
        #expect(c["changes_highlight"] == .object(["root": .string("/p/api"), "path": .string("a.go"),
                                                   "group": .string("staged")]))
    }
}
