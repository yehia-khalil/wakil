import Foundation
import Testing
@testable import WakilKit

@Suite struct EditorBaselineTests {
    @Test func anOpenedTrackedFileGetsItsIndexTextAsItsBaseline() async throws {
        let f = try await changesFixture()
        await f.files.put("/p/api/b.go", "new\n")
        await f.git.set(show: "/p/api|b.go|index", "old\n")
        try await f.dispatch("editor_open", ["path": .string("/p/api/b.go")])
        #expect(await f.snapshot().tabs[0].baseline == "old\n")
        #expect(await f.git.calls.contains("git_show /p/api b.go"))
    }

    @Test func aFileGitCannotShowFromTheIndexHasNoBaseline() async throws {
        let f = try await changesFixture()
        await f.files.put("/p/api/n", "untracked\n")
        await f.git.set(showError: "/p/api|n|index", "fatal: path 'n' exists on disk, but not in the index")
        try await f.dispatch("editor_open", ["path": .string("/p/api/n")])
        #expect(await f.snapshot().tabs[0].baseline == nil)
    }

    @Test func aReadOnlyTabAndAScratchTabFetchNoBaseline() async throws {
        let f = try await changesFixture()
        await f.files.putOverCap("/p/api/big.go", size: 3_000_000)
        try await f.dispatch("editor_open", ["path": .string("/p/api/big.go")])
        try await f.dispatch("editor_new_scratch")
        #expect(await !f.git.calls.contains { $0.contains("big.go") })
        #expect(await f.snapshot().tabs.allSatisfy { $0.baseline == nil })
    }

    @Test func aGitWakeRefetchesTheBaselineOfTabsUnderItsRoot() async throws {
        let f = try await changesFixture()
        await f.files.put("/p/api/b.go", "new\n")
        await f.git.set(show: "/p/api|b.go|index", "old\n")
        try await f.dispatch("editor_open", ["path": .string("/p/api/b.go")])
        await f.git.set(show: "/p/api|b.go|index", "new\n")          // staged in a terminal
        try await f.dispatch("editor_refresh", ["root": .string("/p/api"), "what": .string("git")])
        #expect(await f.snapshot().tabs[0].baseline == "new\n")
    }

    @Test func aDiskReloadKeepsTheBaseline() async throws {
        let f = try await changesFixture()
        await f.files.put("/p/api/b.go", "new\n")
        await f.git.set(show: "/p/api|b.go|index", "old\n")
        try await f.dispatch("editor_open", ["path": .string("/p/api/b.go")])
        await f.files.put("/p/api/b.go", "newer\n")
        try await f.dispatch("editor_refresh", ["root": .string("/p/api"), "what": .string("files")])
        try await f.dispatch("editor_reload", ["path": .string("/p/api/b.go")])
        #expect(await f.snapshot().tabs[0].baseline == "old\n")
    }

    // Review Focus 4.
    @Test(.timeLimit(.minutes(1))) func aBaselineLandingAfterItsTabClosedWritesNothing() async throws {
        let f = try await changesFixture()
        await f.files.put("/p/api/b.go", "new\n")
        await f.git.set(show: "/p/api|b.go|worktree", "")
        try await f.dispatch("editor_open", ["path": .string("/p/api/b.go")])
        await f.git.setSlowShow(true)
        let wake = Task { try await f.dispatch("editor_refresh", ["root": .string("/p/api"), "what": .string("git")]) }
        while await f.git.calls.filter({ $0 == "git_show /p/api b.go" }).count < 2 { await Task.yield() }
        try await f.dispatch("editor_close", ["path": .string("/p/api/b.go")])
        await f.git.release()
        _ = try await wake.value
        #expect(await f.snapshot().tabs.isEmpty)
    }

    @Test func readPaneListsTheActiveTabsHunks() async throws {
        let f = try await changesFixture()
        await f.files.put("/p/api/b.go", "a\nB\nc\n")
        await f.git.set(show: "/p/api|b.go|index", "a\nb\nc\n")
        try await f.dispatch("editor_open", ["path": .string("/p/api/b.go")])
        guard case .object(let o) = await f.panes.readPane(paneId: f.pane, kind: "editor") else { return }
        #expect(o["hunks"] == .array([.object(["kind": .string("changed"), "line": .number(2), "count": .number(1)])]))
    }
}
