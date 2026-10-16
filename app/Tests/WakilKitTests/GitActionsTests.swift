import Foundation
import Testing
@testable import WakilKit

/// Task 8: the git pane's actions — one path for the operator and the agent.

private struct GitFixture {
    let registry: ActionRegistry
    let panes: PaneStore
    let pane: String
    let git: FakeGit

    func dispatch(_ name: String, _ params: [String: JSONValue] = [:]) async throws {
        var p = params
        p["pane"] = .string(pane)
        _ = try await registry.dispatch(
            name: name, params: .object(p), origin: .agent, environment: "staging", confirmation: nil)
    }
    func snapshot() async -> GitSnapshot { await panes.gitSnapshot(paneId: pane) }
}

private func gitFixture() async throws -> GitFixture {
    let dir = testScratchRoot.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let registry = ActionRegistry(journalDirectory: dir, sessionId: "t")
    let (layout, panes, pane) = await openGitPane()
    let git = FakeGit()
    await git.set(status: "/p/api", files: [("a.php", "changed", "M"), ("b", "changed", "M"), ("c", "changed", "M")])
    await git.set(status: "/p/portal", files: [("x.vue", "untracked", "?")])
    await registerGitActions(into: registry, panes: panes, layout: layout, git: git,
                             roots: { ["/p/api", "/p/portal"] })
    return GitFixture(registry: registry, panes: panes, pane: pane, git: git)
}

private func select(_ root: String, _ path: String, _ group: String) -> [String: JSONValue] {
    ["root": .string(root), "path": .string(path), "group": .string(group)]
}

@Test func refreshListsEveryRootAndShowsANonRepoAsItsError() async throws {
    let f = try await gitFixture()
    await f.git.set(status: "/p/api", files: [("a.php", "changed", "M")])
    await f.git.clearStatus("/p/portal")
    try await f.dispatch("git_refresh")
    let s = await f.snapshot()
    #expect(s.roots.map(\.root) == ["/p/api", "/p/portal"])
    #expect(s.roots[0].files.map(\.path) == ["a.php"])
    #expect(s.roots[0].error == nil)
    #expect(s.roots[0].name == "api")
    #expect(s.roots[1].error == "not a git repository")
    #expect(s.roots[1].files.isEmpty)
    #expect(s.roots.allSatisfy { !$0.loading })
}

@Test func selectFoldsAndLoadsBothSidesForAChangedFile() async throws {
    let f = try await gitFixture()
    await f.git.set(show: "/p/api|a.php|index", "old")
    await f.git.set(show: "/p/api|a.php|worktree", "new")
    try await f.dispatch("git_refresh")
    try await f.dispatch("git_select", select("/p/api", "a.php", "changed"))
    let s = await f.snapshot()
    #expect(s.folded == true)
    #expect(s.selection == GitSelection(root: "/p/api", path: "a.php", group: .changed))
    #expect(s.diff?.original == "old")
    #expect(s.diff?.modified == "new")
    #expect(s.diff?.language == "php")
    #expect(s.diff?.loading == false)
}

@Test func aStagedFileComparesHeadWithTheIndexAndAnUntrackedOneComparesNothing() async throws {
    let f = try await gitFixture()
    await f.git.set(show: "/p/api|a.php|HEAD", "head")
    await f.git.set(show: "/p/api|a.php|index", "staged")
    await f.git.set(show: "/p/portal|x.vue|worktree", "<template/>")
    try await f.dispatch("git_select", select("/p/api", "a.php", "staged"))
    var s = await f.snapshot()
    #expect(s.diff?.original == "head")
    #expect(s.diff?.modified == "staged")
    try await f.dispatch("git_select", select("/p/portal", "x.vue", "untracked"))
    s = await f.snapshot()
    #expect(s.diff?.original == "")
    #expect(s.diff?.modified == "<template/>")
    #expect(s.diff?.language == "html")
}

@Test(.timeLimit(.minutes(1)))
func selectingAnotherFileCancelsTheDiffInFlight() async throws {
    let f = try await gitFixture()
    await f.git.set(show: "/p/api|a.php|worktree", "a's text")
    await f.git.set(show: "/p/api|b|worktree", "b's text")
    try await f.dispatch("git_refresh")
    await f.git.setSlowShow(true)
    let first = Task { try await f.dispatch("git_select", select("/p/api", "a.php", "changed")) }
    #expect(await apiEventually { await f.git.calls.contains("git_show /p/api a.php") })
    #expect(await f.snapshot().diff?.loading == true)
    let second = Task { try await f.dispatch("git_select", select("/p/api", "b", "changed")) }
    #expect(await apiEventually { await f.git.calls.contains("git_show /p/api b") })
    // b's reply lands first and a's last: the stale reply arriving after the current one is
    // the case a cancel must survive, since "last writer wins" would otherwise show a.
    await f.git.release(path: "b")
    _ = try await second.value
    await f.git.release(path: "a.php")
    _ = try await first.value
    let s = await f.snapshot()
    #expect(s.selection?.path == "b")
    #expect(s.diff?.modified == "b's text")
    #expect(s.diff?.loading == false)
}

@Test func stepMovesAcrossRoots() async throws {
    let f = try await gitFixture()
    try await f.dispatch("git_refresh")
    try await f.dispatch("git_select", select("/p/api", "c", "changed"))
    try await f.dispatch("git_step", ["delta": .integer(1)])
    let s = await f.snapshot()
    #expect(s.selection == GitSelection(root: "/p/portal", path: "x.vue", group: .untracked))
    #expect(s.folded == true)
}

@Test func unfoldKeepsTheSelection() async throws {
    let f = try await gitFixture()
    try await f.dispatch("git_refresh")
    try await f.dispatch("git_select", select("/p/api", "b", "changed"))
    try await f.dispatch("git_unfold")
    var s = await f.snapshot()
    #expect(s.folded == false)
    #expect(s.selection == GitSelection(root: "/p/api", path: "b", group: .changed))
    try await f.dispatch("git_fold")
    s = await f.snapshot()
    #expect(s.folded == true)
}

@Test func refreshAfterACommitMovesTheSelection() async throws {
    let f = try await gitFixture()
    await f.git.set(show: "/p/api|c|worktree", "c's text")
    try await f.dispatch("git_refresh")
    try await f.dispatch("git_select", select("/p/api", "b", "changed"))
    await f.git.set(status: "/p/api", files: [("a.php", "changed", "M"), ("c", "changed", "M")])
    try await f.dispatch("git_refresh", ["root": .string("/p/api")])
    let s = await f.snapshot()
    #expect(s.selection == GitSelection(root: "/p/api", path: "c", group: .changed))
    #expect(s.diff?.modified == "c's text")
}

@Test func aRootThatEmptiesUnfoldsTheList() async throws {
    let f = try await gitFixture()
    try await f.dispatch("git_refresh")
    try await f.dispatch("git_select", select("/p/portal", "x.vue", "untracked"))
    await f.git.set(status: "/p/portal", files: [])
    try await f.dispatch("git_refresh")
    let s = await f.snapshot()
    #expect(s.folded == false)
    #expect(s.selection == nil)
    #expect(s.diff == nil)
    // Rule 6: the list unfolds with that root in view.
    #expect(s.inView == "/p/portal")
    try await f.dispatch("git_select", select("/p/api", "a.php", "changed"))
    #expect(await f.snapshot().inView == nil, "a select puts its file in view instead")
}

@Test func withNoGitClientEveryActionSaysSo() async throws {
    let dir = testScratchRoot.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let registry = ActionRegistry(journalDirectory: dir, sessionId: "t")
    let (layout, panes, pane) = await openGitPane()
    await registerGitActions(into: registry, panes: panes, layout: layout, git: nil, roots: { ["/p/api"] })
    let calls: [(String, [String: JSONValue])] = [
        ("git_refresh", [:]),
        ("git_select", select("/p/api", "a.php", "changed")),
        ("git_step", ["delta": .integer(1)]),
    ]
    for (name, extra) in calls {
        var params = extra
        params["pane"] = .string(pane)
        await #expect(throws: StandardActionError.missingClient(action: name, role: "git")) {
            _ = try await registry.dispatch(name: name, params: .object(params),
                                            origin: .agent, environment: "staging", confirmation: nil)
        }
    }
}

@Test func anUnknownPaneIsRefused() async throws {
    let f = try await gitFixture()
    await #expect(throws: StandardActionError.self) {
        _ = try await f.registry.dispatch(name: "git_refresh", params: .object(["pane": .string("nope")]),
                                          origin: .agent, environment: "staging", confirmation: nil)
    }
}

@Test func everyGitActionIsAgentReachableAndNoneMutates() async throws {
    let f = try await gitFixture()
    let git = await f.registry.all().filter { $0.name.hasPrefix("git_") }
    #expect(Set(git.map(\.name)) == ["git_refresh", "git_select", "git_step", "git_fold", "git_unfold"])
    for action in git {
        #expect(action.audience == .agentReachable)
        #expect(action.kind != .mutate)
    }
}

@Test func languageFollowsTheExtension() {
    #expect(gitLanguage(for: "a/b.tsx") == "typescript")
    #expect(gitLanguage(for: "x.yml") == "yaml")
    #expect(gitLanguage(for: "x.py") == "python")
    #expect(gitLanguage(for: "Makefile") == "plaintext")
}

@Test func aFailedShowLandsWholeAsTheDiffsError() async throws {
    let f = try await gitFixture()
    await f.git.set(showError: "/p/api|a.php|worktree", "git show: fatal: bad object :a.php")
    try await f.dispatch("git_select", select("/p/api", "a.php", "changed"))
    let s = await f.snapshot()
    #expect(s.diff?.error == "git show: fatal: bad object :a.php")
    #expect(s.diff?.loading == false)
}

@Test(.timeLimit(.minutes(1)))
func rootsShowLoadingWhileARefreshIsInFlight() async throws {
    let f = try await gitFixture()
    await f.git.setSlowStatus(true)
    let refresh = Task { try await f.dispatch("git_refresh") }
    #expect(await apiEventually { await f.git.statusCount == 2 })
    let mid = await f.snapshot()
    #expect(mid.roots.map(\.root) == ["/p/api", "/p/portal"])
    #expect(mid.roots.allSatisfy { $0.loading })
    await f.git.releaseStatus(0)
    await f.git.releaseStatus(1)
    _ = try await refresh.value
    #expect(await f.snapshot().roots.allSatisfy { !$0.loading })
}

/// Important 2 (fix round 1): an older read's reply landing after a newer one's must not
/// put back the older list, and an older read landing first must not end the newer one's
/// loading.
@Test(.timeLimit(.minutes(1)))
func anOlderRefreshNeverOverwritesANewerOne() async throws {
    let f = try await gitFixture()
    await f.git.setSlowStatus(true)
    await f.git.set(status: "/p/api", files: [("old", "changed", "M")])
    let older = Task { try await f.dispatch("git_refresh", ["root": .string("/p/api")]) }
    #expect(await apiEventually { await f.git.statusCount == 1 })
    await f.git.set(status: "/p/api", files: [("new", "changed", "M")])
    let newer = Task { try await f.dispatch("git_refresh", ["root": .string("/p/api")]) }
    #expect(await apiEventually { await f.git.statusCount == 2 })

    // The older reply first: dropped, and the root is still loading for the newer read.
    await f.git.releaseStatus(0)
    _ = try await older.value
    var s = await f.snapshot()
    #expect(s.roots[0].files.isEmpty)
    #expect(s.roots[0].loading == true)

    await f.git.releaseStatus(1)
    _ = try await newer.value
    s = await f.snapshot()
    #expect(s.roots[0].files.map(\.path) == ["new"])
    #expect(s.roots[0].loading == false)
}

@Test(.timeLimit(.minutes(1)))
func anOlderRefreshLandingLastIsDropped() async throws {
    let f = try await gitFixture()
    await f.git.setSlowStatus(true)
    await f.git.set(status: "/p/api", files: [("old", "changed", "M")])
    let older = Task { try await f.dispatch("git_refresh", ["root": .string("/p/api")]) }
    #expect(await apiEventually { await f.git.statusCount == 1 })
    await f.git.set(status: "/p/api", files: [("new", "changed", "M")])
    let newer = Task { try await f.dispatch("git_refresh", ["root": .string("/p/api")]) }
    #expect(await apiEventually { await f.git.statusCount == 2 })

    await f.git.releaseStatus(1)
    _ = try await newer.value
    await f.git.releaseStatus(0)
    _ = try await older.value
    let s = await f.snapshot()
    #expect(s.roots[0].files.map(\.path) == ["new"])
    #expect(s.roots[0].loading == false)
}

/// Minor 5 (fix round 1): a refresh cut short writes no "CancellationError()" as a root's
/// error; the root keeps what it showed and stops loading.
@Test(.timeLimit(.minutes(1)))
func aCancelledRefreshWritesNoError() async throws {
    let f = try await gitFixture()
    try await f.dispatch("git_refresh")
    await f.git.setSlowStatus(true)
    let refresh = Task { try await f.dispatch("git_refresh", ["root": .string("/p/api")]) }
    #expect(await apiEventually { await f.git.statusCount == 3 })
    refresh.cancel()
    await f.git.releaseStatus(2)
    _ = try? await refresh.value
    let s = await f.snapshot()
    #expect(s.roots[0].error == nil)
    #expect(s.roots[0].files.map(\.path) == ["a.php", "b", "c"])
    #expect(s.roots[0].loading == false)
}

/// Important 1 (fix round 1): the selection and the flight that loads it are written in
/// one turn, so however selects and a refresh's reselect interleave, the last selection
/// written owns the diff — it lands, and it is never left loading. The gap the finding
/// describes no longer exists to be stepped into, so this drives the race by volume: with
/// the flight started after the write, it fails (see the task-8 report).
@Test(.timeLimit(.minutes(1)))
func theLastSelectionAlwaysOwnsTheDiff() async throws {
    let f = try await gitFixture()
    for p in ["a.php", "b", "c"] {
        await f.git.set(show: "/p/api|\(p)|worktree", "\(p)'s text")
    }
    try await f.dispatch("git_refresh")
    for _ in 0..<300 {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for p in ["a.php", "b", "c", "b", "a.php"] {
                group.addTask { try await f.dispatch("git_select", select("/p/api", p, "changed")) }
            }
            group.addTask { try await f.dispatch("git_refresh") }
            try await group.waitForAll()
        }
        let s = await f.snapshot()
        #expect(s.diff?.loading == false)
        #expect(s.diff?.modified == "\(s.selection?.path ?? "?")'s text")
    }
}

/// R13: a conflicted file is one Changes row, status U, and its diff is HEAD against the
/// working tree — the index holds no single version of it mid-merge.
@Test func aConflictedFileComparesHeadWithTheWorkingTree() async throws {
    let f = try await gitFixture()
    await f.git.set(status: "/p/api", files: [("m.php", "changed", "U")])
    await f.git.set(show: "/p/api|m.php|HEAD", "ours")
    await f.git.set(show: "/p/api|m.php|index", "stage zero")
    await f.git.set(show: "/p/api|m.php|worktree", "<<<<<<< HEAD")
    try await f.dispatch("git_refresh")
    try await f.dispatch("git_select", select("/p/api", "m.php", "changed"))
    let s = await f.snapshot()
    #expect(s.diff?.original == "ours")
    #expect(s.diff?.modified == "<<<<<<< HEAD")
    #expect(await f.git.calls.filter { $0.hasPrefix("git_show") }.count == 2)
}

/// Final review, item 7: a step reads the selection and writes the next one in one turn, so
/// two steps at once move two rows — never both from the same row onto the same next one.
@Test(.timeLimit(.minutes(1)))
func twoConcurrentStepsLandOnDistinctRows() async throws {
    let f = try await gitFixture()
    try await f.dispatch("git_refresh")
    for _ in 0..<200 {
        try await f.dispatch("git_select", select("/p/api", "a.php", "changed"))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<2 { group.addTask { try await f.dispatch("git_step", ["delta": .integer(1)]) } }
            try await group.waitForAll()
        }
        let s = await f.snapshot()
        #expect(s.selection == GitSelection(root: "/p/api", path: "c", group: .changed))
        if s.selection?.path != "c" { break }
    }
}

/// Final review, item 8: a diff that lands after its pane closed writes nothing — the
/// closed pane's entry is not brought back to hold it.
@Test(.timeLimit(.minutes(1)))
func aDiffLandingAfterItsPaneClosedLeavesNoEntry() async throws {
    let dir = testScratchRoot.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let registry = ActionRegistry(journalDirectory: dir, sessionId: "t")
    let (layout, panes, pane) = await openGitPane()
    let git = FakeGit()
    await git.set(status: "/p/api", files: [("a.php", "changed", "M")])
    await registerLayoutActions(into: registry, layout: layout, panes: panes)
    await registerGitActions(into: registry, panes: panes, layout: layout, git: git, roots: { ["/p/api"] })
    func dispatch(_ name: String, _ params: [String: JSONValue]) async throws {
        _ = try await registry.dispatch(
            name: name, params: .object(params), origin: .agent, environment: "staging", confirmation: nil)
    }
    try await dispatch("git_refresh", ["pane": .string(pane)])
    await git.setSlowShow(true)
    let selecting = Task {
        try await dispatch("git_select", ["pane": .string(pane), "root": .string("/p/api"),
                                          "path": .string("a.php"), "group": .string("changed")])
    }
    #expect(await apiEventually { await git.calls.contains("git_show /p/api a.php") })
    try await dispatch("pane_close", ["id": .string(pane)])
    #expect(await panes.holdsContents(paneId: pane) == false)
    await git.release()
    _ = try? await selecting.value
    #expect(await panes.holdsContents(paneId: pane) == false, "the late diff brought the pane back")
}

/// Closing a pane drops its flights: the diff in flight is cancelled and its reads forgotten.
@Test func droppingAPaneCancelsItsFlights() async {
    let flights = GitFlights()
    let task = flights.startDiff("git-1") { try? await Task.sleep(for: .seconds(30)) }
    let generation = flights.beginRead("git-1", roots: ["/p/api"])
    flights.drop("git-1")
    #expect(task.isCancelled)
    #expect(!flights.isLatestRead("git-1", root: "/p/api", generation: generation))
}
