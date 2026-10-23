import Foundation
import Testing
@testable import WakilKit

/// A wakil-git answering the remote tools; `pull` can report conflicts, `commit` can be held.
private actor RemoteGit: ToolCaller {
    var calls: [String] = []
    var conflicts: [String] = []
    var holdCommit = false
    private var parked: CheckedContinuation<Void, Never>?
    func failPullWithConflicts(_ paths: [String]) { conflicts = paths }
    func hold() { holdCommit = true }
    func release() { holdCommit = false; parked?.resume(); parked = nil }
    private func park(_ c: CheckedContinuation<Void, Never>) { if holdCommit { parked = c } else { c.resume() } }
    func count(_ name: String) -> Int { calls.filter { $0 == name }.count }

    func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        func ok(_ o: [String: JSONValue]) -> JSONValue { .object(["structuredContent": .object(o)]) }
        if name != "git_status" { calls.append(name) }
        switch name {
        case "git_status":
            return ok(["root": .string(optionalString(arguments, "root") ?? ""), "branch": .string("main"), "detached": .string(""),
                       "upstream": .string("origin/main"), "ahead": .integer(1), "behind": .integer(0), "files": .array([])])
        case "git_commit":
            await withCheckedContinuation { c in Task { await self.park(c) } }
            return ok(["commit": .string("abc"), "summary": .string("x")])
        case "git_pull" where !conflicts.isEmpty:
            return .object(["isError": .bool(true),
                            "content": .array([.object(["type": .string("text"), "text": .string("Pull stopped on conflicts in a.txt")])]),
                            "structuredContent": .object(["conflicts": .array(conflicts.map { .string($0) })])])
        default:
            return ok(["summary": .string(""), "ahead": .integer(0), "behind": .integer(0)])
        }
    }
}

private func remoteFixture() async throws -> (ActionRegistry, RemoteGit) {
    let dir = testScratchRoot.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let registry = ActionRegistry(journalDirectory: dir, sessionId: "t")
    let git = RemoteGit()
    let status = GitStatus(git: git, roots: { ["/p"] })
    await status.refresh()
    await registerEditorChangesWrites(into: registry, gitStatus: status, panes: PaneStore(kinds: PaneKinds.standard),
                                      layout: LayoutStore(), writes: GitWriteFlights())
    return (registry, git)
}

@Suite struct EditorChangesRemoteTests {
    @Test func eachRemoteActionCallsItsToolAndIsAllowedForTheAgentInProduction() async throws {
        let (registry, git) = try await remoteFixture()
        for (action, tool) in [("editor_changes_fetch", "git_fetch"), ("editor_changes_pull", "git_pull"),
                               ("editor_changes_push", "git_push"), ("editor_changes_sync", "git_sync"),
                               ("editor_changes_publish", "git_publish")] {
            _ = try await registry.dispatch(name: action, params: .object(["root": .string("/p")]), origin: .agent,
                                            caller: .test("production"), confirmation: nil)
            #expect(await git.count(tool) == 1, "\(action)")
            let d = try #require(await registry.descriptor(named: action))
            #expect(d.kind == .mutate)
            #expect(d.audience == .agentReachable)
        }
    }

    @Test func aRemoteWriteTakesTheRootsWriteLock() async throws {
        let (registry, git) = try await remoteFixture()
        await git.hold()
        let commit = Task {
            try await registry.dispatch(name: "editor_changes_commit", params: .object(["root": .string("/p"), "message": .string("m")]),
                                        origin: .ui, caller: .test("staging"), confirmation: nil)
        }
        try await Task.sleep(for: .milliseconds(100))
        await #expect(throws: (any Error).self) {
            _ = try await registry.dispatch(name: "editor_changes_push", params: .object(["root": .string("/p")]), origin: .ui,
                                            caller: .test("staging"), confirmation: nil)
        }
        await git.release()
        _ = try await commit.value
        #expect(await git.count("git_push") == 0)
    }

    @Test func theButtonFollowsAheadBehindAndUpstream() {
        func root(_ upstream: String, _ ahead: Int, _ behind: Int) -> GitRootState {
            GitRootState(root: "/p", name: "p", branch: "main", detached: "", ahead: ahead, behind: behind, files: [],
                         error: nil, loading: false, upstream: upstream)
        }
        #expect(changesRemoteButton(root("", 0, 0)) == .publish)
        #expect(changesRemoteButton(root("", 3, 0)) == .publish)
        #expect(changesRemoteButton(root("origin/main", 2, 1)) == .sync)
        #expect(changesRemoteButton(root("origin/main", 2, 0)) == .push)
        #expect(changesRemoteButton(root("origin/main", 0, 1)) == .pull)
        #expect(changesRemoteButton(root("origin/main", 0, 0)) == .none)
        var detached = root("", 0, 0)
        detached.branch = ""
        detached.detached = "abc1234"
        #expect(changesRemoteButton(detached) == .none)
    }

    @Test func conflictsComeBackWhole() async throws {
        let (registry, git) = try await remoteFixture()
        await git.failPullWithConflicts(["a.txt"])
        do {
            _ = try await registry.dispatch(name: "editor_changes_pull", params: .object(["root": .string("/p")]), origin: .ui,
                                            caller: .test("staging"), confirmation: nil)
            Issue.record("a conflicting pull succeeded")
        } catch {
            #expect("\(error)".contains("Pull stopped on conflicts in a.txt"))
        }
    }
}
