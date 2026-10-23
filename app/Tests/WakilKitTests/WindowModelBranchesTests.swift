import Foundation
import Testing
@testable import WakilKit

/// A wakil-git that answers the branch and stash tools, recording what it was asked.
private actor BranchGit: ToolCaller {
    var calls: [(String, JSONValue)] = []
    var blocked: [String] = []
    func block(_ paths: [String]) { blocked = paths }
    func names() -> [String] { calls.map(\.0) }

    func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        func ok(_ o: [String: JSONValue]) -> JSONValue { .object(["structuredContent": .object(o)]) }
        if name != "git_status" { calls.append((name, arguments)) }
        switch name {
        case "git_status":
            return ok(["root": .string("/p"), "branch": .string("main"), "detached": .string(""), "upstream": .string(""),
                       "ahead": .integer(0), "behind": .integer(0), "files": .array([])])
        case "git_branches":
            return ok(["current": .string("main"), "remote": .array([.string("origin/theirs")]),
                       "local": .array([.object(["name": .string("main"), "current": .bool(true)]),
                                        .object(["name": .string("side"), "unmerged": .integer(2)])])])
        case "git_stashes":
            return ok(["stashes": .array([.object(["index": .integer(0), "id": .string(String(repeating: "c", count: 40)),
                                                   "message": .string("wip"), "branch": .string("main"),
                                                   "files": .array([.string("a.txt")])])])])
        case "git_switch":
            if !blocked.isEmpty { return ok(["switched": .bool(false), "blocked": .array(blocked.map { .string($0) })]) }
            return ok(["switched": .bool(true), "note": .string("")])
        default:
            return ok([:])
        }
    }
}

@MainActor
private func branchWindow() async -> (WindowModel, BranchGit) {
    let git = BranchGit()
    let status = GitStatus(git: git, roots: { ["/p"] })
    await status.refresh()
    let window = WindowModel.forTesting(scratchRoot: testScratchRoot, gitStatus: status)
    await registerEditorChangesWrites(into: window.registryForTesting, gitStatus: status, panes: PaneStore(kinds: PaneKinds.standard),
                                      layout: LayoutStore(), writes: GitWriteFlights())
    return (window, git)
}

@Suite @MainActor struct WindowModelBranchesTests {
    @Test func theReadsAnswerTheBranchesAndTheStashes() async {
        let (window, _) = await branchWindow()
        let b = await window.changesBranches(root: "/p")
        #expect(b?.current == "main" && b?.local.map(\.name) == ["main", "side"] && b?.remote == ["origin/theirs"])
        let s = await window.changesStashes(root: "/p")
        #expect(s.map(\.message) == ["wip"] && s.first?.files == ["a.txt"])
    }

    @Test func aBlockedSwitchComesBackWithItsPaths() async {
        let (window, git) = await branchWindow()
        await git.block(["a.txt", "u.txt"])
        #expect(await window.changesSwitch(root: "/p", branch: "other") == .blocked(paths: ["a.txt", "u.txt"]))
        await git.block([])
        #expect(await window.changesSwitch(root: "/p", branch: "other", carry: "bring") == .switched(note: ""))
        let sent = await git.calls.last { $0.0 == "git_switch" }?.1
        #expect(sent == .object(["root": .string("/p"), "branch": .string("other"), "carry": .string("bring")]))
    }

    // Decision 46 (operator, option A): delete and drop ask only when the agent asks.
    @Test func theDeleteAndDropsGateOnlyTheAgent() async throws {
        let (window, git) = await branchWindow()
        let registry = window.registryForTesting
        let id = String(repeating: "c", count: 40)
        for (name, params) in [
            ("editor_changes_branch_delete", ["root": JSONValue.string("/p"), "branch": .string("side")]),
            ("editor_changes_stash_drop", ["root": .string("/p"), "index": .integer(0), "id": .string(id)]),
            ("editor_changes_stash_drop_all", ["root": .string("/p"), "ids": .array([.string(id)])]),
        ] {
            await #expect(throws: ActionError.needsConfirmation(name)) {
                _ = try await registry.dispatch(name: name, params: .object(params), origin: .agent,
                                                caller: DispatchCaller(place: window.place, session: nil), confirmation: nil)
            }
            _ = try await registry.dispatch(name: name, params: .object(params), origin: .ui,
                                            caller: DispatchCaller(place: window.place, session: nil), confirmation: nil)
        }
        #expect(await git.names().filter { $0.hasPrefix("git_branch_delete") || $0.hasPrefix("git_stash_drop") }
                == ["git_branch_delete", "git_stash_drop", "git_stash_drop_all"])
        // Everything else runs for the agent too.
        _ = try await registry.dispatch(name: "editor_changes_stash", params: .object(["root": .string("/p")]), origin: .agent,
                                        caller: DispatchCaller(place: window.place, session: nil), confirmation: nil)
        #expect(await git.names().contains("git_stash"))
    }

    @Test func theSegmentReadsTheActiveRootsBranch() async {
        let (window, _) = await branchWindow()
        await window.refreshPanes()
        var spins = 0
        while window.gitRoots.isEmpty, spins < 200 { await Task.yield(); spins += 1 }
        #expect(window.activeBranchRoot?.root == "/p")
        #expect(window.branchSegment == "main")
    }
}

