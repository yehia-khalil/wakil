import Foundation
import Testing
@testable import WakilKit

private func root(_ r: String, _ files: [(String, GitGroup, String)], loading: Bool = false) -> GitRootState {
    GitRootState(root: r, name: (r as NSString).lastPathComponent, branch: "main", detached: "", ahead: 0,
                 behind: 0, files: files.map { GitFileRow(path: $0.0, origPath: nil, group: $0.1, status: $0.2) },
                 error: nil, loading: loading)
}
private func row(_ r: String, _ p: String, _ g: GitGroup) -> EditorChangesRow {
    EditorChangesRow(root: r, path: p, group: g.rawValue)
}

private let two = [
    root("/p/api", [("z.go", .changed, "M"), ("a.go", .staged, "A"), ("n", .untracked, "?"), ("b.go", .changed, "M")]),
    root("/p/web", [("i.ts", .changed, "M")]),
]

@Suite struct EditorChangesTests {
    @Test func rowsAreRootsInOrderThenStagedChangesUntrackedThenPath() {
        #expect(editorChangesRows(two, closed: []) == [
            row("/p/api", "a.go", .staged), row("/p/api", "b.go", .changed), row("/p/api", "z.go", .changed),
            row("/p/api", "n", .untracked), row("/p/web", "i.ts", .changed)])
    }

    @Test func aCollapsedRootsRowsAreLeftOut() {
        #expect(editorChangesRows(two, closed: ["/p/api"]) == [row("/p/web", "i.ts", .changed)])
    }

    @Test func aStepCrossesGroupsAndRootsAndStopsAtEitherEnd() {
        let from = row("/p/api", "n", .untracked)
        #expect(editorChangesStep(two, closed: [], from: from, by: 1) == row("/p/web", "i.ts", .changed))
        #expect(editorChangesStep(two, closed: [], from: from, by: 9) == row("/p/web", "i.ts", .changed))
        #expect(editorChangesStep(two, closed: [], from: from, by: -9) == row("/p/api", "a.go", .staged))
    }

    @Test func aStepWithNothingHighlightedStartsAtTheFirstRow() {
        #expect(editorChangesStep(two, closed: [], from: nil, by: 1) == row("/p/api", "a.go", .staged))
        #expect(editorChangesStep([], closed: [], from: nil, by: 1) == nil)
    }

    @Test func aStepSkipsACollapsedRoot() {
        let roots = two + [root("/p/zed", [("q", .changed, "M")])]
        #expect(editorChangesStep(roots, closed: ["/p/web"], from: row("/p/api", "n", .untracked), by: 1)
            == row("/p/zed", "q", .changed))
    }

    @Test func aHighlightStillListedStays() {
        let h = row("/p/api", "b.go", .changed)
        #expect(editorChangesResolve(h, roots: two) == h)
    }

    // 3a-i: `git add` moved the file from Changes to Staged; the highlight follows it.
    @Test func aHighlightWhoseFileMovedGroupFollowsIt() {
        let after = [root("/p/api", [("b.go", .staged, "M")])]
        #expect(editorChangesResolve(row("/p/api", "b.go", .changed), roots: after) == row("/p/api", "b.go", .staged))
    }

    // Rule 6: a vanished row hands the highlight to its neighbour, not to the top (R6).
    @Test func aVanishedHighlightMovesToTheRowAfterIt() {
        let after = [root("/p/api", [("a.go", .staged, "A"), ("z.go", .changed, "M"), ("n", .untracked, "?")])]
        #expect(editorChangesResolve(row("/p/api", "b.go", .changed), roots: after) == row("/p/api", "z.go", .changed))
    }

    @Test func aVanishedHighlightMovesToTheLastWhenNothingFollows() {
        let after = [root("/p/api", [("a.go", .staged, "A"), ("b.go", .changed, "M")])]
        #expect(editorChangesResolve(row("/p/api", "n", .untracked), roots: after) == row("/p/api", "b.go", .changed))
    }

    @Test func aVanishedHighlightMovesToNothingWhenTheRootEmptied() {
        let after = [root("/p/api", []), root("/p/web", [("i.ts", .changed, "M")])]
        #expect(editorChangesResolve(row("/p/api", "n", .untracked), roots: after) == nil)
    }

    @Test func aRootNotReadYetKeepsTheHighlight() {
        let h = row("/p/api", "n", .untracked)
        #expect(editorChangesResolve(h, roots: [root("/p/api", [], loading: true)]) == h)
        #expect(editorChangesResolve(h, roots: []) == h)
    }

    @Test func aFileStagedAndChangedShowsItsWorkingTreeLetter() {
        let r = [root("/p/api", [("x.go", .staged, "A"), ("x.go", .changed, "M"), ("n", .untracked, "?")])]
        #expect(editorTreeStatus(root: "/p/api", relative: "x.go", roots: r) == "M")
        #expect(editorTreeStatus(root: "/p/api", relative: "n", roots: r) == "?")
        #expect(editorTreeStatus(root: "/p/api", relative: "y.go", roots: r) == nil)
        #expect(editorTreeStatus(root: "/p/web", relative: "x.go", roots: r) == nil)
    }

    @Test func aFileOnlyStagedShowsItsStagedLetter() {
        let r = [root("/p/api", [("x.go", .staged, "D")])]
        #expect(editorTreeStatus(root: "/p/api", relative: "x.go", roots: r) == "D")
    }
}
