import Foundation
import Testing
@testable import WakilKit

/// 3a-iv: the branch picker's rows, the Branch segment's text, the active root, and the exact copy of
/// the delete and drop confirmations.
@Suite struct BranchPickerTests {
    private let branches = GitBranchesInfo(
        local: [
            GitBranchInfo(name: "feature/search", upstream: "origin/feature/search", ahead: 1, behind: 0, unmerged: 3, current: false),
            GitBranchInfo(name: "main", upstream: "origin/main", ahead: 0, behind: 0, unmerged: 0, current: true),
            GitBranchInfo(name: "Fix-Login", upstream: "", ahead: 0, behind: 0, unmerged: 1, current: false),
        ],
        remote: ["origin/theirs"], current: "main", detached: "")

    @Test func withNoFilterEveryRowInOrder() {
        #expect(branchPickerRows(branches, filter: "") == [
            .createFrom, .local(branches.local[0]), .local(branches.local[1]), .local(branches.local[2]),
            .remote("origin/theirs"), .fetch,
        ])
    }

    @Test func aFilterNamingNoBranchOffersToCreateIt() {
        #expect(branchPickerRows(branches, filter: "new idea") == [.create("new-idea"), .createFrom, .fetch])
    }

    @Test func aFilterMatchesCaseInsensitivelyAndAnExactNameOffersNoCreate() {
        #expect(branchPickerRows(branches, filter: "fix") == [.create("fix"), .createFrom, .local(branches.local[2]), .fetch])
        #expect(branchPickerRows(branches, filter: "Fix-Login") == [.createFrom, .local(branches.local[2]), .fetch])
        #expect(branchPickerRows(branches, filter: "theirs") == [.create("theirs"), .createFrom, .remote("origin/theirs"), .fetch])
    }

    @Test func theSegmentReadsTheActiveRootsBranch() {
        let api = GitRootState(root: "/p/api", name: "api", branch: "main", detached: "", ahead: 0, behind: 0, files: [], error: nil, loading: false)
        let detached = GitRootState(root: "/p/api", name: "api", branch: "", detached: "3f2a1c9", ahead: 0, behind: 0, files: [], error: nil, loading: false)
        #expect(branchSegmentText(api, rootCount: 1) == "main")
        #expect(branchSegmentText(api, rootCount: 2) == "api: main")
        #expect(branchSegmentText(detached, rootCount: 1) == "detached at 3f2a1c9")
        #expect(branchSegmentText(nil, rootCount: 0) == nil)
    }

    @Test func theActiveRootIsTheFocusedTabsElseTheFirst() {
        let roots = [GitRootState(root: "/p/api", name: "api", branch: "main", detached: "", ahead: 0, behind: 0, files: [], error: nil, loading: false),
                     GitRootState(root: "/p/portal", name: "portal", branch: "dev", detached: "", ahead: 0, behind: 0, files: [], error: nil, loading: false)]
        #expect(activeGitRoot(focusedPath: "/p/portal/src/a.ts", roots: roots)?.name == "portal")
        #expect(activeGitRoot(focusedPath: "/elsewhere/x", roots: roots)?.name == "api")
        #expect(activeGitRoot(focusedPath: nil, roots: roots)?.name == "api")
        #expect(activeGitRoot(focusedPath: nil, roots: []) == nil)
    }

    @Test func theConfirmationsSayWhatIsLost() {
        #expect(deleteBranchConfirmation(branches.local[0], current: "main")
                == "Delete feature/search? Its 3 commits not on main are kept only in git's reflog.")
        #expect(deleteBranchConfirmation(branches.local[2], current: "main")
                == "Delete Fix-Login? Its 1 commit not on main is kept only in git's reflog.")
        let merged = GitBranchInfo(name: "done", upstream: "", ahead: 0, behind: 0, unmerged: 0, current: false)
        #expect(deleteBranchConfirmation(merged, current: "main") == "Delete done? It is merged into main.")
        let stash = GitStashInfo(index: 0, id: String(repeating: "a", count: 40), message: "wip search", branch: "main", date: "", files: ["a.txt"])
        #expect(dropStashConfirmation(stash) == "Drop \"wip search\"? It cannot be applied again.")
        #expect(dropAllStashesConfirmation(3) == "Drop all 3 stashes? They cannot be applied again.")
    }

    @Test func aStashFilesDiffSides() {
        let id = String(repeating: "b", count: 40)
        #expect(editorStashDiffRevs(stash: id, untracked: false) == ("stash-base:\(id)", "stash:\(id)"))
        #expect(editorStashDiffRevs(stash: id, untracked: true) == (nil, "stash-untracked:\(id)"))
    }

    // 3a-iv e2e audit, defect 2: a project whose first root is a plain folder still has a branch.
    @Test func theFallbackIsTheFirstGitRoot() {
        let plain = GitRootState(root: "/p/docs", name: "docs", branch: "", detached: "", ahead: 0, behind: 0,
                                 files: [], error: "not a git repository", loading: false)
        let api = GitRootState(root: "/p/api", name: "api", branch: "main", detached: "", ahead: 0, behind: 0,
                               files: [], error: nil, loading: false)
        #expect(activeGitRoot(focusedPath: nil, roots: [plain, api])?.name == "api")
        #expect(activeGitRoot(focusedPath: "/p/docs/readme.md", roots: [plain, api])?.name == "api")
        #expect(activeGitRoot(focusedPath: nil, roots: [plain]) == nil)
    }

    // 3a-iv walk: with nothing typed the highlight is the current branch, so Return on opening does
    // not start Create branch from…; typed, it is the first row (Create, or the first match).
    @Test func theHighlightStartsOnTheCurrentBranch() {
        #expect(branchPickerDefaultSelection(branchPickerRows(branches, filter: ""), filter: "") == 2)   // main ✓
        let none = GitBranchesInfo(local: [GitBranchInfo(name: "a", upstream: "", ahead: 0, behind: 0, unmerged: 0, current: false)],
                                   remote: [], current: "", detached: "3f2a1c9")
        #expect(branchPickerDefaultSelection(branchPickerRows(none, filter: ""), filter: "") == 1)      // the first branch
        #expect(branchPickerDefaultSelection(branchPickerRows(branches, filter: "fix"), filter: "fix") == 0)
    }
}

