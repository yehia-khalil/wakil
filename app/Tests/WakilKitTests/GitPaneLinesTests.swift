import Testing
@testable import WakilKit

/// The text the Changes view draws for the window's git status (3a-i's Git pane's, kept in 3b-iii),
/// pure, because `WakilApp` has no test target: what a root header reads, and the list's groups,
/// order, labels and tones.

private func r(_ files: [GitFileRow] = [], branch: String = "main", detached: String = "",
               ahead: Int = 0, behind: Int = 0, error: String? = nil) -> GitRootState {
    GitRootState(root: "/p/api", name: "api", branch: branch, detached: detached, ahead: ahead,
                 behind: behind, files: files, error: error, loading: false)
}

private func row(_ path: String, _ group: GitGroup = .changed, _ status: String = "M",
                 orig: String? = nil) -> GitFileRow {
    GitFileRow(path: path, origPath: orig, group: group, status: status)
}

// MARK: - The root header

@Test func rootLines() {
    #expect(gitRootLine(r()) == "api · main · clean")
    #expect(gitRootLine(r([GitFileRow(path: "a", origPath: nil, group: .changed, status: "M")], ahead: 2, behind: 1)) == "api · main ↑2 ↓1")
    #expect(gitRootLine(r([GitFileRow(path: "a", origPath: nil, group: .changed, status: "M")], branch: "", detached: "a1b2c3d")) == "api · a1b2c3d")
    #expect(gitRootLine(r(error: "not a git repository")) == "api · not a git repository")
}

@Test func aCleanRootAheadSaysBoth() {
    #expect(gitRootLine(r(ahead: 2)) == "api · main ↑2 · clean")
    #expect(gitRootLine(r(behind: 3)) == "api · main ↓3 · clean")
}

/// The view draws the name and the rest apart, the rest dimmed; a non-repository is not drawn.
@Test func aRootsDetailIsItsLineAfterTheName() {
    #expect(gitRootDetail(r()) == "main · clean")
    #expect(gitRootDetail(r([row("a")], ahead: 1)) == "main ↑1")
    #expect(gitRootDetail(r(error: "fatal: bad object HEAD\nhint: x")) == "fatal: bad object HEAD")
    #expect(gitRootDetail(r(branch: "")) == "")
    #expect(gitRootIsRepository(r()))
    #expect(gitRootIsRepository(r(error: "fatal: bad object HEAD")))
    #expect(!gitRootIsRepository(r(error: "not a git repository")))
    #expect(!gitRootIsRepository(r(error: "not a git repository (the repository is above this root)")))
}

/// A root no read has reached yet has no branch and no SHA. It is not "clean" — nobody knows.
@Test func aRootNotYetReadIsOnlyItsName() {
    var pending = r(branch: "")
    pending.loading = true
    #expect(gitRootLine(pending) == "api")
}

/// Rule 8: the header carries an error's first line; the rest is drawn whole beneath it.
@Test func aLongErrorIsSplitBetweenTheHeaderAndTheLinesBeneath() {
    let one = r(error: "not a git repository")
    #expect(gitRootErrorDetail(one) == nil)
    let many = r(error: "fatal: bad object HEAD\nhint: run git fsck\nhint: or re-clone")
    #expect(gitRootLine(many) == "api · fatal: bad object HEAD")
    #expect(gitRootErrorDetail(many) == "hint: run git fsck\nhint: or re-clone")
    #expect(gitRootErrorDetail(r()) == nil)
}

// MARK: - The list

@Test func groupsAreLabelledAndAnEmptyGroupIsNotDrawn() {
    #expect(gitGroupLabel(.staged) == "Staged")
    #expect(gitGroupLabel(.changed) == "Changes")
    #expect(gitGroupLabel(.untracked) == "Untracked")
    let state = r([row("b.txt", .untracked, "?"), row("a.txt", .staged, "A"), row("c.txt", .untracked, "?")])
    let sections = gitListSections(state)
    #expect(sections.map(\.group) == [.staged, .untracked])
    #expect(sections[1].rows.map(\.path) == ["b.txt", "c.txt"])
}

/// The list's rows run in the same order ↑↓ steps through the Changes view.
@Test func theListsOrderIsTheStepOrder() {
    let state = r([row("z.txt"), row("a.txt", .untracked, "?"), row("m.txt", .staged, "A"), row("b.txt")])
    let listed = gitListSections(state).flatMap(\.rows)
        .map { EditorChangesRow(root: state.root, path: $0.path, group: $0.group.rawValue) }
    #expect(listed == editorChangesRows([state], closed: []))
}

/// A row reads its name first and its folder dimmed after it; a rename says where it came from.
@Test func aRowIsItsNameThenItsFolder() {
    #expect(gitRowName(row("src/app.txt")) == "app.txt")
    #expect(gitRowFolder(row("src/app.txt")) == "src")
    #expect(gitRowFolder(row("notes")) == "")
    #expect(gitRowFolder(row("new.swift", .staged, "R", orig: "old.swift")) == "← old.swift")
    #expect(gitRowFolder(row("src/new.swift", .staged, "R", orig: "lib/old.swift")) == "src · ← lib/old.swift")
}

@Test func aRenameReadsOldToNew() {
    #expect(gitRowLabel(row("new.swift", .staged, "R", orig: "old.swift")) == "old.swift → new.swift")
    #expect(gitRowLabel(row("same.swift")) == "same.swift")
}

/// §5: amber for a change, green for an addition, and a deletion muted — red is production's.
@Test func statusTones() {
    #expect(gitStatusTone("M") == .modified)
    #expect(gitStatusTone("R") == .modified)
    #expect(gitStatusTone("T") == .modified)
    #expect(gitStatusTone("A") == .added)
    #expect(gitStatusTone("?") == .added)
    #expect(gitStatusTone("D") == .muted)
    #expect(gitStatusTone("U") == .modified)
}

// MARK: - 3a-v-b: conflicts

private func op(_ kind: String, incoming: String = "", onto: String = "", step: Int = 0, steps: Int = 0,
                head: String = "", subject: String = "") -> GitOpState {
    GitOpState(kind: kind, incoming: incoming, onto: onto, step: step, steps: steps, head: head, subject: subject)
}

private func stated(_ files: [GitFileRow], _ state: GitOpState?) -> GitRootState {
    var root = r(files)
    root.state = state
    return root
}

@Test func theHeaderNamesTheState() {
    let id = "abc1234" + String(repeating: "f", count: 33)
    #expect(gitOpStateLabel(op("merge", incoming: "feature/search")) == "merging feature/search")
    #expect(gitOpStateLabel(op("rebase", onto: "main", step: 2, steps: 5, head: id)) == "rebasing 2/5 onto main")
    #expect(gitOpStateLabel(op("cherry-pick", head: id)) == "cherry-picking abc1234")
    #expect(gitOpStateLabel(op("revert", head: id)) == "reverting abc1234")
}

@Test func theCommitButtonFollowsTheState() {
    #expect(changesCommitTitle(r([row("a.txt", .staged, "A")])) == "Commit")
    #expect(changesCommitTitle(r([row("a.txt")])) == "Commit All")
    for kind in ["merge", "cherry-pick", "revert"] {
        #expect(changesCommitTitle(stated([row("a.txt", .staged, "M")], op(kind))) == "Commit Merge", "\(kind)")
    }
    #expect(changesCommitTitle(stated([], op("rebase"))) == "Continue Rebase")
}

@Test func theReasonCountsConflicts() {
    let c1 = GitFileRow(path: "a.txt", origPath: nil, group: .conflicts, status: "U", kind: "UU")
    let c2 = GitFileRow(path: "b c.txt", origPath: nil, group: .conflicts, status: "U", kind: "AA")
    #expect(changesConflictsReason(stated([c1, row("x.txt", .staged, "M")], op("merge"))) == "Resolve 1 conflict first")
    #expect(changesConflictsReason(stated([c1, c2], op("rebase"))) == "Resolve 2 conflicts first")
    #expect(changesConflictsReason(stated([row("x.txt", .staged, "M")], op("merge"))) == nil)
}

@Test func theMergeChangesGroupAndItsKinds() {
    #expect(gitGroupLabel(.conflicts) == "Merge Changes")
    let labels = ["UU", "AA", "DU", "UD", "AU", "UA", "DD"].map(gitConflictKindLabel)
    #expect(labels == ["both modified", "both added", "deleted by us", "deleted by them", "added by us",
                       "added by them", "both deleted"])
    let flagged = GitFileRow(path: "src/a.txt", origPath: nil, group: .staged, status: "M", markers: true)
    #expect(gitRowMarkersNote(flagged) == "a.txt — staged with conflict markers")
    #expect(gitRowMarkersNote(row("a.txt", .staged, "M")) == nil)
    let c = GitFileRow(path: "a.txt", origPath: nil, group: .conflicts, status: "U", kind: "UU")
    let sections = gitListSections(r([row("b.txt", .staged, "A"), c]))
    #expect(sections.map(\.group) == [.conflicts, .staged])
}

@Test func theConfirmationsReadExactly() {
    #expect(changesAbortConfirmation(op("merge"))
            == "Abort the merge? The tree goes back to before it, and your resolutions are lost.")
    #expect(changesAbortConfirmation(op("rebase"))
            == "Abort the rebase? The tree goes back to before it, and your resolutions are lost.")
    #expect(changesAbortConfirmation(op("cherry-pick"))
            == "Abort the cherry-pick? The tree goes back to before it, and your resolutions are lost.")
    #expect(changesAbortConfirmation(op("revert"))
            == "Abort the revert? The tree goes back to before it, and your resolutions are lost.")
    #expect(changesSkipConfirmation(id7: "abc1234", subject: "Seed search")
            == "Skip abc1234 \"Seed search\"? Its changes are left out of the rebase.")
    #expect(changesTakeConfirmation(path: "a.txt", take: "current", incoming: "feature/search")
            == "Take all of HEAD's a.txt? Any edits you made to it are lost.")
    #expect(changesTakeConfirmation(path: "a.txt", take: "incoming", incoming: "feature/search")
            == "Take all of feature/search's a.txt? Any edits you made to it are lost.")
    // Delete File takes the side that deleted it: ours (HEAD) for DU, theirs for UD.
    #expect(changesTakeConfirmation(path: "a.txt", take: "delete", incoming: "feature/search", kind: "DU")
            == "Take all of HEAD's a.txt? Any edits you made to it are lost, and the file is deleted.")
    #expect(changesTakeConfirmation(path: "a.txt", take: "delete", incoming: "feature/search", kind: "UD")
            == "Take all of feature/search's a.txt? Any edits you made to it are lost, and the file is deleted.")
    #expect(changesUndoApplyConfirmation(message: "On main: wip")
            == "Undo applying \"On main: wip\"? The files it touched go back to HEAD; the stash stays in the list.")
}
