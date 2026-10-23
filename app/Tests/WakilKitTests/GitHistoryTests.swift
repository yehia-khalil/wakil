import Foundation
import Testing
@testable import WakilKit

@Suite struct GitHistoryTests {
    private let now = ISO8601DateFormatter().date(from: "2026-10-23T12:00:00Z")!
    private func ago(_ s: TimeInterval) -> String { ISO8601DateFormatter().string(from: now.addingTimeInterval(-s)) }

    @Test func relativeAges() {
        let day: TimeInterval = 86_400
        #expect(editorRelativeAge(ago(30), now: now) == "just now")
        #expect(editorRelativeAge(ago(61), now: now) == "1 minute ago")
        #expect(editorRelativeAge(ago(3 * 3600), now: now) == "3 hours ago")
        #expect(editorRelativeAge(ago(3 * day), now: now) == "3 days ago")
        #expect(editorRelativeAge(ago(20 * day), now: now) == "2 weeks ago")
        #expect(editorRelativeAge(ago(90 * day), now: now) == "3 months ago")
        #expect(editorRelativeAge(ago(800 * day), now: now) == "2 years ago")
    }

    @Test func blameTextReadsLikeVSCode() {
        let b = GitBlameInfo(line: 2, id: String(repeating: "a", count: 40), author: "Ada Lovelace",
                             date: ago(3 * 86_400), subject: "Seed the search page")
        #expect(editorBlameText(b, now: now) == "Ada Lovelace, 3 days ago • Seed the search page")
    }

    @Test func anUncommittedLineSaysSo() {
        let b = GitBlameInfo(line: 1, id: String(repeating: "0", count: 40), author: "Not Committed Yet",
                             date: ago(10), subject: "")
        #expect(b.uncommitted && editorBlameText(b, now: now) == "Not committed yet")
    }

    @Test func commitDiffSides() {
        let id = String(repeating: "c", count: 40)
        #expect(editorCommitDiffRevs(GitCommitRef(id: id, path: "a.txt")) == ("commit-parent:\(id)", "commit:\(id)"))
        #expect(editorCommitDiffRevs(GitCommitRef(id: id, path: "new.txt", parentPath: "old name.txt"))
            == ("commit-parent:\(id):old name.txt", "commit:\(id)"))
    }

    @Test func aCommitTabHasItsOwnKeyAndTitle() {
        let a = GitCommitRef(id: "abc1234" + String(repeating: "0", count: 33), path: "src/a.txt")
        let b = GitCommitRef(id: "def5678" + String(repeating: "0", count: 33), path: "src/a.txt")
        let ta = EditorTab.diff(root: "/p/api", path: "src/a.txt", group: .changed, source: .commit(a))
        let tb = EditorTab.diff(root: "/p/api", path: "src/a.txt", group: .changed, source: .commit(b))
        #expect(editorTabKey(ta) != editorTabKey(tb))
        #expect(editorTabTitles([ta]) == ["a.txt (abc1234)"])
    }

    @Test func openCommitDiffFocusesAnOpenTab() async throws {
        let f = try await changesFixture()
        let id = String(repeating: "e", count: 40)
        await f.git.set(show: "/p/api|b.go|commit-parent:\(id)", "before\n")
        await f.git.set(show: "/p/api|b.go|commit:\(id)", "after\n")
        let p: [String: JSONValue] = ["root": .string("/p/api"), "path": .string("b.go"), "commit": .string(id)]
        try await f.dispatch("editor_open_commit_diff", p)
        try await f.dispatch("editor_open_commit_diff", p)
        let s = await f.snapshot()
        #expect(s.tabs.count == 1)
        let t = try #require(s.tabs.first)
        #expect(t.readOnly && t.diffState?.original == "before\n" && t.diffState?.modified == "after\n")
        #expect(editorTabTitles(s.tabs) == ["b.go (eeeeeee)"])
    }

    // Review Focus 3: the commit that added the file has nothing on the left.
    @Test func theAddingCommitHasAnEmptyLeftSide() async throws {
        let f = try await changesFixture()
        let id = String(repeating: "f", count: 40)
        await f.git.set(show: "/p/api|b.go|commit:\(id)", "after\n")
        await f.git.set(showAbsent: "/p/api|b.go|commit-parent:\(id)")
        try await f.dispatch("editor_open_commit_diff", ["root": .string("/p/api"), "path": .string("b.go"), "commit": .string(id)])
        let t = try #require(await f.snapshot().tabs.first)
        #expect(t.diffState?.error == nil && t.diffState?.original == "" && t.diffState?.modified == "after\n")
    }

    @Test func inlineBlameDecodesAndDefaultsOn() throws {
        let off = try JSONDecoder().decode(SettingsEditor.self, from: Data(#"{"fontSize":12,"inlineBlame":false}"#.utf8))
        let absent = try JSONDecoder().decode(SettingsEditor.self, from: Data(#"{"fontSize":12}"#.utf8))
        #expect(!off.inlineBlame && absent.inlineBlame && SettingsEditor.defaults.inlineBlame)
    }

    private func blame(_ n: Int, _ who: String) -> GitBlameInfo {
        GitBlameInfo(line: n, id: String(repeating: "a", count: 40), author: who, date: "2026-10-20T12:00:00Z", subject: "s")
    }

    @Test func aBlameLandsForItsTab() {
        var c = EditorBlameCache()
        let g = c.begin(key: "file:/p/a.txt")
        let landed = c.land(key: "file:/p/a.txt", gen: g, lines: [blame(1, "Ada")])
        #expect(landed)
        #expect(c.line(key: "file:/p/a.txt", 1)?.author == "Ada")
        #expect(c.line(key: "file:/p/a.txt", 2) == nil)
    }

    // Review Focus 5: a reply that lands after a newer fetch began for its tab writes nothing.
    @Test func aLateBlameForAnotherTabIsDropped() {
        var c = EditorBlameCache()
        let old = c.begin(key: "file:/p/a.txt")
        _ = c.begin(key: "file:/p/b.txt")
        let newer = c.begin(key: "file:/p/a.txt")
        let stale = c.land(key: "file:/p/a.txt", gen: old, lines: [blame(1, "Old")])
        #expect(!stale)
        #expect(c.line(key: "file:/p/a.txt", 1) == nil)
        let fresh = c.land(key: "file:/p/a.txt", gen: newer, lines: [blame(1, "New")])
        #expect(fresh)
        #expect(c.line(key: "file:/p/a.txt", 1)?.author == "New")
    }

    @Test func theBlameHoverNamesTheCommitAndItsActions() {
        let b = GitBlameInfo(line: 2, id: "abc1234" + String(repeating: "0", count: 33), author: "Ada Lovelace",
                             date: ago(3 * 86_400), subject: "Fix [search] *now*")
        let h = editorBlameHover(b, now: now) ?? ""
        #expect(h.hasPrefix("**Fix \\[search\\] \\*now\\***"))
        #expect(h.contains("Ada Lovelace · 3 days ago · `abc1234`"))
        #expect(h.contains("[Open Changes](command:wakil.blame.open)") && h.contains("[Copy Commit ID](command:wakil.blame.copy)"))
        #expect(editorBlameHover(GitBlameInfo(line: 1, id: String(repeating: "0", count: 40), author: "", date: "", subject: "")) == nil)
    }

    @Test func timelineFollowsFileAndDiffTabs() {
        let id = String(repeating: "c", count: 40)
        let file = EditorTab.file(path: "/p/api/src/a.txt", root: "/p/api", text: "x", mtime: 0, language: "plaintext")
        #expect(editorTimelineSubject(file).map { [$0.root, $0.path] } == ["/p/api", "src/a.txt"])
        for source: EditorDiffSource? in [nil, .stash(id), .commit(GitCommitRef(id: id, path: "src/a.txt"))] {
            let d = EditorTab.diff(root: "/p/api", path: "src/a.txt", group: .changed, source: source)
            #expect(editorTimelineSubject(d).map { [$0.root, $0.path] } == ["/p/api", "src/a.txt"])
        }
        #expect(editorTimelineSubject(EditorTab.scratch(number: 1, language: "plaintext")) == nil)
        #expect(editorTimelineSubject(nil) == nil)
    }

    private func commit(_ n: Int) -> GitCommitInfo {
        GitCommitInfo(id: String(repeating: "\(n)", count: 40), author: "Ada", date: ago(Double(n) * 60), subject: "c\(n)", path: "a.txt")
    }

    @Test func timelineRowsPutUncommittedFirstAndMoreLast() {
        let rows = editorTimelineRows([commit(1), commit(2)], uncommitted: true, more: true)
        #expect(rows == [.uncommitted, .commit(commit(1)), .commit(commit(2)), .more])
        #expect(editorTimelineRows([commit(1)], uncommitted: false, more: false) == [.commit(commit(1))])
    }

    @Test func fiftyMeansThereMayBeMore() {
        #expect(editorTimelineHasMore(pageCount: 50))
        #expect(!editorTimelineHasMore(pageCount: 49))
    }

    // Review Focus 1: a row older than a rename opens under its own name, with the name before it.
    @Test func aRowBeforeARenameNamesBothPaths() {
        var newer = commit(1); newer.path = "new.txt"
        var older = commit(2); older.path = "old name.txt"
        #expect(editorTimelineCommitRef(newer, older: older) == GitCommitRef(id: newer.id, path: "new.txt", parentPath: "old name.txt"))
        #expect(editorTimelineCommitRef(older, older: nil) == GitCommitRef(id: older.id, path: "old name.txt"))
    }

    @Test func theUncommittedRowOpensTheFilesChanges() {
        let rows = [GitFileRow(path: "a.txt", origPath: nil, group: .staged, status: "M"),
                    GitFileRow(path: "b.txt", origPath: nil, group: .staged, status: "M"),
                    GitFileRow(path: "b.txt", origPath: nil, group: .changed, status: "M")]
        #expect(editorTimelineUncommittedGroup(rows, path: "a.txt", dirty: false) == .staged)
        #expect(editorTimelineUncommittedGroup(rows, path: "b.txt", dirty: false) == .changed)
        #expect(editorTimelineUncommittedGroup(rows, path: "c.txt", dirty: true) == .changed)
        #expect(editorTimelineUncommittedGroup(rows, path: "c.txt", dirty: false) == nil)
    }

    // Final review I2: the same commit opened with and without its old name is two subjects, so two keys —
    // one key for both cancelled the first tab's fetch and left it loading.
    @Test func aCommitTabsKeyCarriesItsParentPath() {
        let id = String(repeating: "c", count: 40)
        let a = EditorTab.diff(root: "/p", path: "new.txt", group: .changed, source: .commit(GitCommitRef(id: id, path: "new.txt", parentPath: "old.txt")))
        let b = EditorTab.diff(root: "/p", path: "new.txt", group: .changed, source: .commit(GitCommitRef(id: id, path: "new.txt")))
        #expect(editorTabKey(a) != editorTabKey(b))
    }

    // Final review I3: a fetch in flight for this text is not restarted by the next snapshot.
    @Test func aBlameInFlightForTheSameTextIsNotFetchedAgain() {
        var c = EditorBlameCache()
        #expect(c.needsFetch(key: "k", text: "a"))
        let g = c.begin(key: "k", text: "a")
        #expect(!c.needsFetch(key: "k", text: "a"))
        #expect(c.needsFetch(key: "k", text: "b"))
        c.abandon(key: "k", gen: g)
        #expect(c.needsFetch(key: "k", text: "a"))
    }

    // Final review I4: a landed blame stands until the root's status moves, then it is fetched again; a
    // reopened tab is fetched again.
    @Test func aStatusChangeOrAReopenFetchesAgain() {
        var c = EditorBlameCache()
        let g = c.begin(key: "k", text: "a")
        c.land(key: "k", gen: g, lines: [blame(1, "Ada")])
        #expect(!c.needsFetch(key: "k", text: "a") && c.fetched(key: "k"))
        c.invalidate()
        #expect(c.needsFetch(key: "k", text: "a") && c.line(key: "k", 1)?.author == "Ada")
        c.forget(key: "k")
        #expect(c.needsFetch(key: "k", text: "a") && !c.fetched(key: "k") && c.line(key: "k", 1) == nil)
    }
}
