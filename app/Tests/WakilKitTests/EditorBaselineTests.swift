import Foundation
import Testing
@testable import WakilKit

// A baseline lands after the action that opened its tab returns (final review 2): tests wait for it
// (`baselineLands`), so every one is bounded.
@Suite(.timeLimit(.minutes(1))) struct EditorBaselineTests {
    @Test func anOpenedTrackedFileGetsItsIndexTextAsItsBaseline() async throws {
        let f = try await changesFixture()
        await f.files.put("/p/api/b.go", "new\n")
        await f.git.set(show: "/p/api|b.go|index", "old\n")
        try await f.dispatch("editor_open", ["path": .string("/p/api/b.go")])
        await f.baselineLands("/p/api/b.go", "old\n")
        #expect(await f.git.calls.contains("git_show /p/api b.go"))
    }

    @Test func aFileGitCannotShowFromTheIndexHasNoBaseline() async throws {
        let f = try await changesFixture()
        await f.files.put("/p/api/n", "untracked\n")
        await f.git.set(showError: "/p/api|n|index", "fatal: path 'n' exists on disk, but not in the index")
        await f.git.setSlowShow(true)
        try await f.dispatch("editor_open", ["path": .string("/p/api/n")])
        // A stand-in the parked reply must clear, so its nil is seen landing rather than assumed.
        await f.panes.updateEditor(paneId: f.pane) { s in s.tabs[0].baseline = "stand-in" }
        await f.git.release()
        await f.baselineLands("/p/api/n", nil)
    }

    /// wakil-git answers an untracked file's index side with empty text and `absent`, not an error;
    /// read as an empty file, every line was marked added (3b-iii Cover).
    @Test func aFileAbsentFromTheIndexHasNoBaseline() async throws {
        let f = try await changesFixture()
        await f.files.put("/p/api/n", "untracked\n")
        await f.git.set(showAbsent: "/p/api|n|index")
        await f.git.setSlowShow(true)
        try await f.dispatch("editor_open", ["path": .string("/p/api/n")])
        await f.panes.updateEditor(paneId: f.pane) { s in s.tabs[0].baseline = "stand-in" }
        await f.git.release()
        await f.baselineLands("/p/api/n", nil)
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
        await f.baselineLands("/p/api/b.go", "old\n")
        await f.git.set(show: "/p/api|b.go|index", "new\n")          // staged in a terminal
        try await f.dispatch("editor_refresh", ["root": .string("/p/api"), "what": .string("git")])
        #expect(await f.snapshot().tabs[0].baseline == "new\n")
    }

    @Test func aDiskReloadKeepsTheBaseline() async throws {
        let f = try await changesFixture()
        await f.files.put("/p/api/b.go", "new\n")
        await f.git.set(show: "/p/api|b.go|index", "old\n")
        try await f.dispatch("editor_open", ["path": .string("/p/api/b.go")])
        await f.baselineLands("/p/api/b.go", "old\n")
        await f.files.put("/p/api/b.go", "newer\n")
        try await f.dispatch("editor_refresh", ["root": .string("/p/api"), "what": .string("files")])
        try await f.dispatch("editor_reload", ["path": .string("/p/api/b.go")])
        #expect(await f.snapshot().tabs[0].baseline == "old\n")
    }

    // Review Focus 4, fix round 1: a late reply from before the tab was closed and reopened must not
    // write its stale text into the reopened tab, nor into another tab.
    @Test func aBaselineLandingAfterItsTabWasReopenedWritesNothingStale() async throws {
        let f = try await changesFixture()
        await f.files.put("/p/api/b.go", "new\n")
        await f.files.put("/p/api/a.go", "a\n")
        await f.git.set(show: "/p/api|b.go|index", "old\n")
        await f.git.set(show: "/p/api|a.go|index", "a-index\n")
        try await f.dispatch("editor_open", ["path": .string("/p/api/b.go")])
        try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
        await f.baselineLands("/p/api/b.go", "old\n")      // the opens' own shows, before indexing starts
        await f.baselineLands("/p/api/a.go", "a-index\n")
        await f.git.setIndexedShow(true)
        let wake = Task { try await f.dispatch("editor_refresh", ["root": .string("/p/api"), "what": .string("git")]) }
        while await f.git.calls.filter({ $0.hasPrefix("git_show") }).count < 4 { await Task.yield() }   // 2 on open + 2 wake
        await f.git.set(show: "/p/api|b.go|index", "fresh\n")
        try await f.dispatch("editor_close", ["path": .string("/p/api/b.go")])
        let reopen = Task { try await f.dispatch("editor_open", ["path": .string("/p/api/b.go")]) }
        while await f.git.calls.filter({ $0.hasPrefix("git_show") }).count < 5 { await Task.yield() }
        await f.git.releaseShow(2)           // the reopen's reply (the wake's two are calls 0 and 1)
        _ = try await reopen.value
        await f.git.releaseShow(0)
        await f.git.releaseShow(1)
        _ = try await wake.value
        await f.baselineLands("/p/api/b.go", "fresh\n")   // the reopen's own fetch, not awaited by its open
        let tabs = await f.snapshot().tabs
        #expect(tabs.first { $0.path == "/p/api/b.go" }?.baseline == "fresh\n")
        #expect(tabs.first { $0.path == "/p/api/a.go" }?.baseline == "a-index\n")
    }

    // Fix round 1, finding 2: replies for one path land out of order; the newest fetch wins.
    @Test func anOlderBaselineReplyLandingLastDoesNotWin() async throws {
        let f = try await changesFixture()
        await f.files.put("/p/api/b.go", "new\n")
        await f.git.set(show: "/p/api|b.go|index", "first\n")
        try await f.dispatch("editor_open", ["path": .string("/p/api/b.go")])
        await f.baselineLands("/p/api/b.go", "first\n")
        await f.git.setIndexedShow(true)
        await f.git.set(show: "/p/api|b.go|index", "A-older\n")
        let a = Task { try await f.dispatch("editor_refresh", ["root": .string("/p/api"), "what": .string("git")]) }
        while await f.git.calls.filter({ $0.hasPrefix("git_show") }).count < 2 { await Task.yield() }
        await f.git.set(show: "/p/api|b.go|index", "B-newer\n")
        let b = Task { try await f.dispatch("editor_refresh", ["root": .string("/p/api"), "what": .string("git")]) }
        while await f.git.calls.filter({ $0.hasPrefix("git_show") }).count < 3 { await Task.yield() }
        await f.git.releaseShow(1)
        _ = try await b.value
        await f.git.releaseShow(0)
        _ = try await a.value
        #expect(await f.snapshot().tabs[0].baseline == "B-newer\n")
    }

    // Fix round 1, finding 3.
    @Test func aTabThatTurnsReadOnlyLosesItsBaselineAndItsHunks() async throws {
        let f = try await changesFixture()
        await f.files.put("/p/api/b.go", "new\n")
        await f.git.set(show: "/p/api|b.go|index", "old\n")
        try await f.dispatch("editor_open", ["path": .string("/p/api/b.go")])
        await f.files.putOverCap("/p/api/b.go", size: 3_000_000)
        try await f.dispatch("editor_refresh", ["root": .string("/p/api"), "what": .string("files")])
        let t = await f.snapshot().tabs[0]
        #expect(t.readOnly && t.baseline == nil)
        guard case .object(let o) = await f.panes.readPane(paneId: f.pane, kind: "editor") else { return }
        #expect(o["hunks"] == .null)
    }

    @Test func aReadOnlyTabReportsNoHunksEvenWithABaseline() async throws {
        let f = try await changesFixture()
        await f.files.put("/p/api/b.go", "new\n")
        await f.git.set(show: "/p/api|b.go|index", "old\n")
        try await f.dispatch("editor_open", ["path": .string("/p/api/b.go")])
        await f.panes.updateEditor(paneId: f.pane) { s in s.tabs[0].readOnly = true }
        guard case .object(let o) = await f.panes.readPane(paneId: f.pane, kind: "editor") else { return }
        #expect(o["hunks"] == .null)
    }

    @Test func aTabThatTurnsWritableFetchesItsBaselineAgain() async throws {
        let f = try await changesFixture()
        await f.files.putOverCap("/p/api/b.go", size: 3_000_000)
        await f.git.set(show: "/p/api|b.go|index", "old\n")
        try await f.dispatch("editor_open", ["path": .string("/p/api/b.go")])
        #expect(await f.snapshot().tabs[0].baseline == nil)
        await f.files.put("/p/api/b.go", "new\n")
        try await f.dispatch("editor_refresh", ["root": .string("/p/api"), "what": .string("files")])
        await f.baselineLands("/p/api/b.go", "old\n")
        await f.files.putOverCap("/p/api/b.go", size: 3_000_000)
        try await f.dispatch("editor_refresh", ["root": .string("/p/api"), "what": .string("files")])
        await f.files.put("/p/api/b.go", "newer\n")
        try await f.dispatch("editor_reload", ["path": .string("/p/api/b.go")])
        await f.baselineLands("/p/api/b.go", "old\n")
    }

    // Final review 2: a baseline is best-effort and never holds up the action that opens the tab (Rule 8).
    @Test func openReturnsWithItsTabWhileTheBaselineIsStillParked() async throws {
        let f = try await changesFixture()
        await f.files.put("/p/api/b.go", "new\n")
        await f.git.set(show: "/p/api|b.go|index", "old\n")
        await f.git.setSlowShow(true)
        try await f.dispatch("editor_open", ["path": .string("/p/api/b.go")])
        let t = try #require(await f.snapshot().tabs.first)
        #expect(t.path == "/p/api/b.go" && t.baseline == nil)
        await f.git.release()
        await f.baselineLands("/p/api/b.go", "old\n")
    }

    @Test func restoreStartsEveryTabsBaselineAtOnce() async throws {
        let f = try await changesFixture()
        await f.files.put("/p/api/a.go", "a\n")
        await f.files.put("/p/api/b.go", "b\n")
        await f.git.set(show: "/p/api|a.go|index", "A\n")
        await f.git.set(show: "/p/api|b.go|index", "B\n")
        await f.layout.setEditorTabs(id: f.pane, to: [
            EditorSavedTab(path: "/p/api/a.go", cursor: EditorPosition(line: 1, column: 1), scrollTop: 0),
            EditorSavedTab(path: "/p/api/b.go", cursor: EditorPosition(line: 1, column: 1), scrollTop: 0),
        ])
        await f.git.setSlowShow(true)
        try await f.dispatch("editor_restore", origin: .ui)
        #expect(await f.snapshot().tabs.map(\.path) == ["/p/api/a.go", "/p/api/b.go"])
        // Both shows are in flight before either has landed: the second never waited on the first.
        while await f.git.calls.filter({ $0.hasPrefix("git_show") }).count < 2 { try await Task.sleep(for: .milliseconds(1)) }
        #expect(await f.snapshot().tabs.allSatisfy { $0.baseline == nil })
        await f.git.release()
        await f.baselineLands("/p/api/a.go", "A\n")
        await f.baselineLands("/p/api/b.go", "B\n")
    }

    // The window redraws on `editorChanges()`: a baseline landing after its action returned must wake it.
    @Test func aBaselineWriteWakesTheEditorChangesStream() async throws {
        let f = try await changesFixture()
        await f.files.put("/p/api/b.go", "new\n")
        try await f.dispatch("editor_open", ["path": .string("/p/api/b.go")])
        await f.baselineLands("/p/api/b.go", "")
        var changes = await f.panes.editorChanges().makeAsyncIterator()
        await f.panes.updateEditor(paneId: f.pane) { s in s.tabs[0].baseline = "old\n" }
        #expect(await changes.next() == f.pane)
    }

    @Test func readPaneListsTheActiveTabsHunks() async throws {
        let f = try await changesFixture()
        await f.files.put("/p/api/b.go", "a\nB\nc\n")
        await f.git.set(show: "/p/api|b.go|index", "a\nb\nc\n")
        try await f.dispatch("editor_open", ["path": .string("/p/api/b.go")])
        await f.baselineLands("/p/api/b.go", "a\nb\nc\n")
        guard case .object(let o) = await f.panes.readPane(paneId: f.pane, kind: "editor") else { return }
        #expect(o["hunks"] == .array([.object(["kind": .string("changed"), "line": .number(2), "count": .number(1)])]))
    }
}
