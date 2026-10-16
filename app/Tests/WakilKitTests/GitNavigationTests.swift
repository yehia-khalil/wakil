import Testing
@testable import WakilKit

private func root(_ name: String, _ files: [(String, GitGroup)]) -> GitRootState {
    GitRootState(root: "/p/\(name)", name: name, branch: "main", detached: "", ahead: 0, behind: 0,
                 files: files.map { GitFileRow(path: $0.0, origPath: nil, group: $0.1, status: "M") },
                 error: nil, loading: false)
}
private func sel(_ r: String, _ p: String, _ g: GitGroup) -> GitSelection { GitSelection(root: "/p/\(r)", path: p, group: g) }

@Test func stepOrderCrossesGroupsThenRootsAndVisitsAPartlyStagedFileTwice() {
    let roots = [root("api", [("b.php", .changed), ("a.php", .staged), ("a.php", .changed), ("z", .untracked)]),
                 root("portal", [("v.vue", .changed)])]
    #expect(gitRows(roots) == [sel("api", "a.php", .staged), sel("api", "a.php", .changed),
                               sel("api", "b.php", .changed), sel("api", "z", .untracked),
                               sel("portal", "v.vue", .changed)])
}

@Test func stepClampsAtBothEnds() {
    let roots = [root("api", [("a", .changed), ("b", .changed)])]
    #expect(gitStep(roots, from: sel("api", "b", .changed), by: 1) == sel("api", "b", .changed))
    #expect(gitStep(roots, from: sel("api", "a", .changed), by: -1) == sel("api", "a", .changed))
    #expect(gitStep(roots, from: nil, by: 1) == sel("api", "a", .changed))
    #expect(gitStep([], from: nil, by: 1) == nil)
}

@Test func aSelectedFileThatStillExistsIsKept() {
    let before = [root("api", [("a", .changed), ("b", .changed)])]
    #expect(gitReselect(sel("api", "a", .changed), before: before, after: before) == .keep(sel("api", "a", .changed)))
}

@Test func aSelectedFileThatVanishedMovesToTheRowNowInItsPlace() {
    let before = [root("api", [("a", .changed), ("b", .changed), ("c", .changed)])]
    let after = [root("api", [("a", .changed), ("c", .changed)])]
    #expect(gitReselect(sel("api", "b", .changed), before: before, after: after) == .moved(sel("api", "c", .changed)))
}

@Test func theLastRowVanishingMovesToTheNewLastRowInTheSameRoot() {
    let before = [root("api", [("a", .changed), ("b", .changed)]), root("portal", [("v", .changed)])]
    let after = [root("api", [("a", .changed)]), root("portal", [("v", .changed)])]
    #expect(gitReselect(sel("api", "b", .changed), before: before, after: after) == .moved(sel("api", "a", .changed)))
}

@Test func aRootWithNothingLeftUnfoldsAtThatRoot() {
    let before = [root("api", [("a", .changed)])]
    let after = [root("api", [])]
    #expect(gitReselect(sel("api", "a", .changed), before: before, after: after) == .unfold(root: "/p/api"))
}

@Test func changedToStagedFollowsTheFile() {
    let before = [root("api", [("a", .changed), ("b", .changed)])]
    let after = [root("api", [("a", .staged), ("b", .changed)])]
    #expect(gitReselect(sel("api", "a", .changed), before: before, after: after) == .moved(sel("api", "a", .staged)))
}

@Test func stagedToChangedFollowsTheFile() {
    let before = [root("api", [("a", .staged), ("b", .changed)])]
    let after = [root("api", [("a", .changed), ("b", .changed)])]
    #expect(gitReselect(sel("api", "a", .staged), before: before, after: after) == .moved(sel("api", "a", .changed)))
}

@Test func followsFileWhenIndexShiftsAndGroupChanges() {
    let before = [root("api", [("z", .changed), ("a", .changed), ("b", .changed)])]
    let after = [root("api", [("a", .staged), ("b", .changed)])]
    #expect(gitReselect(sel("api", "a", .changed), before: before, after: after) == .moved(sel("api", "a", .staged)))
}

@Test func partlyStagedFilePrefersOriginalGroup() {
    let before = [root("api", [("a", .changed)])]
    let after = [root("api", [("a", .staged), ("a", .changed)])]
    #expect(gitReselect(sel("api", "a", .changed), before: before, after: after) == .moved(sel("api", "a", .changed)))
}

@Test func partlyStagedFilePrefersOriginalGroupFromStaged() {
    let before = [root("api", [("a", .staged)])]
    let after = [root("api", [("a", .staged), ("a", .changed)])]
    #expect(gitReselect(sel("api", "a", .staged), before: before, after: after) == .moved(sel("api", "a", .staged)))
}
