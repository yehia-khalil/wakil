import Testing
@testable import WakilKit

private func object(_ v: JSONValue?) -> [String: JSONValue] {
    guard case .object(let o)? = v else { return [:] }
    return o
}

private func array(_ v: JSONValue?) -> [JSONValue] {
    guard case .array(let a)? = v else { return [] }
    return a
}

@Test func gitIsARegisteredAndClassifiedKind() {
    #expect(Pane.kinds.contains("git"))
    #expect(PaneKinds.is("git", GitPaneKind.self))
    #expect(GitPaneKind.rerunsSubjectOnRestore == true)
}

@Test func anUnwrittenGitPaneAnswersEmptyNotAsAGrid() async {
    let store = PaneStore(kinds: PaneKinds.standard)
    let snap = await store.snapshot(paneId: "g1", kind: "git")
    #expect(snap.git == .empty)
}

@Test func oneBrokenRootDoesNotHideTheOther() async {
    let store = PaneStore()
    var s = GitSnapshot.empty
    s.roots = [
        GitRootState(root: "/tmp/a", name: "a", branch: "main", detached: "", ahead: 0, behind: 0,
                     files: [GitFileRow(path: "x.php", origPath: nil, group: .changed, status: "M")],
                     error: nil, loading: false),
        GitRootState(root: "/tmp/b", name: "b", branch: "", detached: "", ahead: 0, behind: 0,
                     files: [], error: "git status: fatal: index file corrupt", loading: false),
    ]
    await store.setGit(paneId: "g1", s)
    let json = object(await store.readPane(paneId: "g1", kind: "git"))
    let roots = array(json["roots"])
    #expect(roots.count == 2)
    #expect(array(object(roots[0])["files"]).count == 1)
    #expect(object(roots[1])["error"] == .string("git status: fatal: index file corrupt"))
    #expect(object(roots[0])["error"] == .null)
    #expect(json["selection"] == .null)
    #expect(json["diff"] == .null)
    #expect(json["folded"] == .bool(false))
}

@Test func aGitPaneIgnoresWritesOfOtherKindsAndTheReverse() async {
    let store = PaneStore()
    var s = GitSnapshot.empty
    s.folded = true
    await store.setGit(paneId: "g1", s)
    #expect(await store.gitSnapshot(paneId: "g1").folded == true)
    #expect(await store.gitSnapshot(paneId: "nope") == .empty)
}
