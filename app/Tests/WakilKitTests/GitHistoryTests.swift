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
}
