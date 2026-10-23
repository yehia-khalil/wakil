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
}
