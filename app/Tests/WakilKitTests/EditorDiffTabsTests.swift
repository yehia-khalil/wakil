import Foundation
import Testing
@testable import WakilKit

private func select(_ f: EditorFixture, _ root: String, _ path: String, _ group: String, pin: Bool = false) async throws {
    var p: [String: JSONValue] = ["root": .string(root), "path": .string(path), "group": .string(group)]
    if pin { p["pin"] = .bool(true) }
    try await f.dispatch("editor_changes_select", p)
}

@Suite struct EditorDiffTabsTests {
    @Test func selectOpensAPreviewDiffTabWithBothSides() async throws {
        let f = try await changesFixture()
        await f.git.set(show: "/p/api|b.go|index", "old\n")
        await f.git.set(show: "/p/api|b.go|worktree", "new\n")
        try await select(f, "/p/api", "b.go", "changed")
        let s = await f.snapshot()
        let t = try #require(s.tabs.first)
        #expect(t.subject == .diff(root: "/p/api", path: "b.go", group: .changed))
        #expect(t.preview && t.readOnly && !t.dirty)
        #expect(t.diffState?.original == "old\n" && t.diffState?.modified == "new\n" && t.diffState?.loading == false)
        #expect(editorTabTitles(s.tabs) == ["b.go (Changes)"])
    }

    @Test func theSameFilesTwoGroupsAreTwoTabs() async throws {
        let f = try await changesFixture()
        await f.git.set(status: "/p/api", files: [("x.go", "staged", "M"), ("x.go", "changed", "M")])
        await f.status.refresh(only: "/p/api")
        try await select(f, "/p/api", "x.go", "staged", pin: true)
        try await select(f, "/p/api", "x.go", "changed", pin: true)
        #expect(editorTabTitles(await f.snapshot().tabs) == ["x.go (Staged)", "x.go (Changes)"])
    }

    @Test func theNextSingleClickReplacesThePreviewAndADoubleClickPins() async throws {
        let f = try await changesFixture()
        try await select(f, "/p/api", "a.go", "staged")
        try await select(f, "/p/api", "b.go", "changed")
        #expect(await f.snapshot().tabs.count == 1)
        try await select(f, "/p/api", "b.go", "changed", pin: true)
        try await select(f, "/p/web", "i.ts", "changed")
        let tabs = await f.snapshot().tabs
        #expect(tabs.count == 2 && !tabs[0].preview && tabs[1].preview)
    }

    @Test func eachGroupDiffsTheRevisionsTheSpecNames() {
        #expect(editorDiffRevs(.staged, status: "M") == ("HEAD", "index"))
        #expect(editorDiffRevs(.changed, status: "M") == ("index", "worktree"))
        #expect(editorDiffRevs(.untracked, status: "?") == (nil, "worktree"))
        #expect(editorDiffRevs(.changed, status: "D") == ("index", nil))
        #expect(editorDiffRevs(.staged, status: "D") == ("HEAD", nil))
        #expect(editorDiffRevs(.changed, status: "U") == ("HEAD", "worktree"))
    }

    @Test func aSecondSelectOfTheSameRowDoesNotFetchTwice() async throws {
        let f = try await changesFixture()
        try await select(f, "/p/api", "b.go", "changed")
        let shows = await f.git.calls.filter { $0.hasPrefix("git_show") }.count
        try await select(f, "/p/api", "b.go", "changed")
        #expect(await f.git.calls.filter { $0.hasPrefix("git_show") }.count == shows)
    }

    // Rules 4 and 5: the preview slot taken by another diff cancels the first one's fetch.
    @Test(.timeLimit(.minutes(1))) func aPreviewReplacedWhileItsDiffLoadsNeverReceivesThatDiff() async throws {
        let f = try await changesFixture()
        await f.git.set(show: "/p/api|a.go|index", "A-staged\n")
        await f.git.setSlowShow(true)
        let first = Task { try await select(f, "/p/api", "a.go", "staged") }
        while await !f.git.calls.contains(where: { $0.hasPrefix("git_show /p/api a.go") }) { await Task.yield() }
        await f.git.release(path: "b.go")
        try await select(f, "/p/api", "b.go", "changed")
        await f.git.release()
        _ = try? await first.value
        let t = try #require(await f.snapshot().tabs.first)
        #expect(t.subject == .diff(root: "/p/api", path: "b.go", group: .changed))
        #expect(t.diffState?.original != "A-staged\n" && t.diffState?.modified != "A-staged\n")
    }

    // Rule 7: a path no longer changed opens, and says so.
    @Test func aRowNoLongerInItsGroupOpensReadingNoLongerChanged() async throws {
        let f = try await changesFixture()
        try await select(f, "/p/api", "gone.go", "changed")
        let d = try #require(await f.snapshot().tabs.first?.diffState)
        #expect(d.noLongerChanged && !d.loading)
        #expect(await !f.git.calls.contains { $0.contains("gone.go") })
    }

    @Test func aWakeReReadsEveryOpenDiffTabUnderItsRoot() async throws {
        let f = try await changesFixture()
        await f.git.set(show: "/p/api|b.go|worktree", "one\n")
        try await select(f, "/p/api", "b.go", "changed", pin: true)
        try await select(f, "/p/web", "i.ts", "changed", pin: true)
        await f.git.set(show: "/p/api|b.go|worktree", "two\n")
        try await f.dispatch("editor_refresh", ["root": .string("/p/api"), "what": .string("git")])
        let tabs = await f.snapshot().tabs
        #expect(tabs[0].diffState?.modified == "two\n")
        #expect(!tabs[1].diffState!.loading)
    }

    @Test func aDiffWhoseFileLeftItsGroupSaysNoLongerChangedAndStaysOpen() async throws {
        let f = try await changesFixture()
        await f.git.set(show: "/p/api|b.go|worktree", "kept\n")
        try await select(f, "/p/api", "b.go", "changed")
        await f.git.set(status: "/p/api", files: [("b.go", "staged", "M")])
        await f.status.refresh(only: "/p/api")
        try await f.dispatch("editor_refresh", ["root": .string("/p/api"), "what": .string("git")])
        let t = try #require(await f.snapshot().tabs.first)
        #expect(t.diffState?.noLongerChanged == true && t.diffState?.modified == "kept\n")
    }

    @Test func stepMovesTheHighlightAndOpensItsPreviewDiff() async throws {
        let f = try await changesFixture()
        try await f.dispatch("editor_changes_step", ["delta": .integer(1)])
        try await f.dispatch("editor_changes_step", ["delta": .integer(1)])
        let s = await f.snapshot()
        #expect(s.tabs.count == 1 && s.tabs[0].subject == .diff(root: "/p/api", path: "b.go", group: .changed))
    }

    @Test func aFailedSideShowsItsErrorWhole() async throws {
        let f = try await changesFixture()
        await f.git.set(showError: "/p/api|b.go|index", "fatal: bad object\nmore")
        try await select(f, "/p/api", "b.go", "changed")
        #expect(await f.snapshot().tabs.first?.diffState?.error == "fatal: bad object\nmore")
    }

    @Test func openFileOpensTheFileAtTheDiffCursorsLine() async throws {
        let f = try await changesFixture()
        await f.files.put("/p/api/b.go", "1\n2\n3\n4\n")
        try await select(f, "/p/api", "b.go", "changed")
        let subject = await f.snapshot().tabs[0].subject
        await f.panes.editorViewDidReport(paneId: f.pane, subject: subject, cursor: EditorPosition(line: 3, column: 2),
                                          selection: nil, visibleRange: nil, scrollTop: 0)
        try await f.dispatch("editor_open_file")
        let s = await f.snapshot()
        #expect(s.tabs.count == 2, "the diff tab stays open beside it (Rule 6)")
        #expect(s.tabs[s.active!].path == "/p/api/b.go" && s.tabs[s.active!].cursor.line == 3)
    }

    @Test func openFileIsRefusedOnADeletedFilesDiff() async throws {
        let f = try await changesFixture()
        await f.git.set(status: "/p/api", files: [("b.go", "changed", "D")])
        await f.status.refresh(only: "/p/api")
        try await select(f, "/p/api", "b.go", "changed")
        await #expect(throws: EditorActionError.fileGone(path: "/p/api/b.go")) { try await f.dispatch("editor_open_file") }
    }

    @Test func openFileIsRefusedOnAStagedDiffWhoseFileIsGoneFromTheWorkingTree() {
        let roots = [GitRootState(root: "/p/api", name: "api", branch: "main", detached: "", ahead: 0, behind: 0,
                                  files: [GitFileRow(path: "x", origPath: nil, group: .staged, status: "M"),
                                          GitFileRow(path: "x", origPath: nil, group: .changed, status: "D")],
                                  error: nil, loading: false)]
        #expect(!editorDiffOpensFile(root: "/p/api", path: "x", group: .staged, roots: roots))
        #expect(editorDiffOpensFile(root: "/p/api", path: "y", group: .staged, roots: roots))
    }

    @Test func openFileOnAFileTabIsRefused() async throws {
        let f = try await changesFixture()
        await f.files.put("/p/api/b.go", "x\n")
        try await f.dispatch("editor_open", ["path": .string("/p/api/b.go")])
        await #expect(throws: EditorActionError.notADiff(action: "editor_open_file")) { try await f.dispatch("editor_open_file") }
    }

    @Test func closeAddressesADiffTabBySubject() async throws {
        let f = try await changesFixture()
        try await select(f, "/p/api", "b.go", "changed", pin: true)
        try await f.dispatch("editor_close", ["diff": .object(["root": .string("/p/api"), "path": .string("b.go"),
                                                               "group": .string("changed")])])
        #expect(await f.snapshot().tabs.isEmpty)
    }

    @Test func diffTabsAreNotSavedWithTheLayout() async throws {
        let f = try await changesFixture()
        try await select(f, "/p/api", "b.go", "changed", pin: true)
        #expect(editorSavedTabs(await f.snapshot()).isEmpty)
    }

    @Test func readPaneCarriesADiffTabsFactsNotItsTexts() async throws {
        let f = try await changesFixture()
        try await select(f, "/p/api", "b.go", "changed")
        guard case .object(let o) = await f.panes.readPane(paneId: f.pane, kind: "editor"),
              case .array(let tabs)? = o["tabs"], case .object(let t)? = tabs.first,
              case .object(let d)? = t["diff"] else { Issue.record("no diff"); return }
        #expect(d["root"] == .string("/p/api") && d["path"] == .string("b.go") && d["group"] == .string("changed"))
        #expect(d["loading"] == .bool(false) && d["no_longer_changed"] == .bool(false) && d["original"] == nil)
    }

    @Test func cmdReturnOpensTheFileOnlyFromADiffThatMay() {
        let ok = EditorSnapshot(tabs: [.diff(root: "/p/api", path: "b.go", group: .changed)], active: 0)
        #expect(editorCommandReturnOpensFile(ok, roots: []))
        #expect(!editorCommandReturnOpensFile(EditorSnapshot(tabs: [.scratch(number: 1, language: "plaintext")], active: 0), roots: []))
        #expect(!editorCommandReturnOpensFile(nil, roots: []))
    }
}
