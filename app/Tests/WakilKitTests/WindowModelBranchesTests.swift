import Foundation
import Testing
@testable import WakilKit

/// A wakil-git that answers the branch and stash tools, recording what it was asked.
private actor BranchGit: ToolCaller {
    var calls: [(String, JSONValue)] = []
    var blocked: [String] = []
    func block(_ paths: [String]) { blocked = paths }
    /// 3a-v-b: the status's conflicted paths and operation, and whether a stash apply or a switch clashes.
    var conflicts: [String] = []
    var state: JSONValue?
    var clashing = false
    func set(conflicts paths: [String], state: JSONValue? = nil) { conflicts = paths; self.state = state }
    func clash(_ on: Bool) { clashing = on }
    /// git_continue's reply when set; else it stops as git_merge does.
    var continueReply: [String: JSONValue]?
    func set(continueReply r: [String: JSONValue]?) { continueReply = r }
    func args(_ tool: String) -> JSONValue? { calls.last { $0.0 == tool }?.1 }
    func names() -> [String] { calls.map(\.0) }

    func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        func ok(_ o: [String: JSONValue]) -> JSONValue { .object(["structuredContent": .object(o)]) }
        if name != "git_status" { calls.append((name, arguments)) }
        switch name {
        case "git_status":
            var o: [String: JSONValue] = [
                "root": .string("/p"), "branch": .string("main"), "detached": .string(""), "upstream": .string(""),
                "ahead": .integer(0), "behind": .integer(0),
                "files": .array(conflicts.map { .object(["path": .string($0), "group": .string("conflicts"),
                                                         "status": .string("U"), "kind": .string("UU")]) })]
            if let state { o["state"] = state }
            return ok(o)
        case "git_stash_apply", "git_stash_pop":
            guard clashing else { return ok(["note": .string("")]) }
            return ok(["note": .string("Your stash clashes with main in a.txt; resolve it below, or Undo Apply"),
                       "clash": clashJSON])
        case "git_continue" where continueReply != nil:
            return ok(continueReply!)
        case "git_merge", "git_continue":
            return ok(["done": .bool(false), "conflicts": .array([.string("a.txt")]),
                       "summary": .string("Merge stopped on conflicts in a.txt; resolve them below")])
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
            guard clashing else { return ok(["switched": .bool(true), "note": .string("")]) }
            return ok(["switched": .bool(true), "clash": clashJSON,
                       "note": .string("Switched to other; your changes clash with it in a.txt — resolve them below, or Undo Apply")])
        default:
            return ok([:])
        }
    }
}

/// A clash as wakil-git returns it, and decoded.
private let clashJSON: JSONValue = .object([
    "id": .string(String(repeating: "c", count: 40)),
    "files": .array([.object(["path": .string("a.txt"), "hash": .string("h1")]),
                     .object(["path": .string("new file.txt"), "hash": .string("h2")])]),
    "created": .array([.string("new file.txt")]), "conflicts": .array([.string("a.txt")]),
    "staged": .array([.object(["path": .string("a.txt"), "mode": .string("100644"), "hash": .string("h0")])]),
])
private let clash = GitStashClash(id: String(repeating: "c", count: 40),
                                  files: [GitClashFile(path: "a.txt", hash: "h1"), GitClashFile(path: "new file.txt", hash: "h2")],
                                  created: ["new file.txt"], conflicts: ["a.txt"],
                                  staged: [GitClashIndex(path: "a.txt", mode: "100644", hash: "h0")])
private let stash = GitStashInfo(index: 0, id: String(repeating: "c", count: 40), message: "wip", branch: "main", date: "", files: ["a.txt"])

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
                                                caller: DispatchCaller(place: window.place, session: nil, conversation: "c1"), confirmation: nil)
            }
            _ = try await registry.dispatch(name: name, params: .object(params), origin: .ui,
                                            caller: DispatchCaller(place: window.place, session: nil), confirmation: nil)
        }
        #expect(await git.names().filter { $0.hasPrefix("git_branch_delete") || $0.hasPrefix("git_stash_drop") }
                == ["git_branch_delete", "git_stash_drop", "git_stash_drop_all"])
        // Everything else runs for the agent too.
        _ = try await registry.dispatch(name: "editor_changes_stash", params: .object(["root": .string("/p")]), origin: .agent,
                                        caller: DispatchCaller(place: window.place, session: nil, conversation: "c1"), confirmation: nil)
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

    // 3a-v-b: what throws work away asks only when the agent asks (Decision 46's option A, kept).
    @Test func theAbortSkipTakeAndUndoGateOnlyTheAgent() async throws {
        let (window, git) = await branchWindow()
        await git.clash(true)
        await git.set(conflicts: ["a.txt"])
        #expect(await window.changesStashApply(root: "/p", stash: stash, pop: false) == nil)
        let registry = window.registryForTesting
        for (name, params) in [
            ("editor_changes_abort", ["root": JSONValue.string("/p")]),
            ("editor_changes_skip", ["root": .string("/p")]),
            ("editor_changes_take", ["root": .string("/p"), "path": .string("a.txt"), "take": .string("incoming")]),
            ("editor_changes_stash_undo_apply", ["root": .string("/p")]),
        ] {
            await #expect(throws: ActionError.needsConfirmation(name)) {
                _ = try await registry.dispatch(name: name, params: .object(params), origin: .agent,
                                                caller: DispatchCaller(place: window.place, session: nil, conversation: "c1"), confirmation: nil)
            }
            _ = try await registry.dispatch(name: name, params: .object(params), origin: .ui,
                                            caller: DispatchCaller(place: window.place, session: nil), confirmation: nil)
        }
        #expect(await git.names().filter { ["git_abort", "git_skip", "git_resolve", "git_stash_undo_apply"].contains($0) }
                == ["git_abort", "git_skip", "git_resolve", "git_stash_undo_apply"])
        // Merge, rebase, continue and Keep File run for the agent too.
        for (name, params) in [
            ("editor_changes_merge", ["root": JSONValue.string("/p"), "branch": .string("side")]),
            ("editor_changes_rebase", ["root": .string("/p"), "onto": .string("main")]),
            ("editor_changes_continue", ["root": .string("/p")]),
            ("editor_changes_keep_file", ["root": .string("/p"), "path": .string("a.txt")]),
        ] {
            _ = try await registry.dispatch(name: name, params: .object(params), origin: .agent,
                                            caller: DispatchCaller(place: window.place, session: nil, conversation: "c1"), confirmation: nil)
        }
        #expect(await git.names().suffix(4) == ["git_merge", "git_rebase", "git_continue", "git_resolve"])
    }

    // R4: a Wakil stash clash is remembered per root until Undo Apply, or until the conflicts group empties.
    @Test func aStashClashIsRememberedThenForgotten() async throws {
        let (window, git) = await branchWindow()
        await git.set(conflicts: ["a.txt"])
        await window.refreshPanes()
        #expect(window.changesClashes.isEmpty)
        await git.clash(true)
        #expect(await window.changesStashApply(root: "/p", stash: stash, pop: true) == nil)
        #expect(window.changesClashes == ["/p": clash])
        #expect(window.changesErrors["/p"] == "Your stash clashes with main in a.txt; resolve it below, or Undo Apply")
        #expect(await window.changesStashUndoApply(root: "/p") == nil)
        #expect(await git.args("git_stash_undo_apply") == .object(["root": .string("/p"), "clash": clashJSON]))
        #expect(window.changesClashes.isEmpty)
        #expect(await window.changesStashUndoApply(root: "/p")?.contains("No stash clash to undo") == true)

        // Bring Them Along's clash is remembered the same way; resolving the last conflict forgets it.
        #expect(await window.changesSwitch(root: "/p", branch: "other", carry: "bring")
                == .switched(note: "Switched to other; your changes clash with it in a.txt — resolve them below, or Undo Apply"))
        #expect(window.changesClashes == ["/p": clash])
        await git.set(conflicts: [])
        _ = try await window.registryForTesting.dispatch(
            name: "editor_changes_keep_file", params: .object(["root": .string("/p"), "path": .string("a.txt")]), origin: .ui,
            caller: DispatchCaller(place: window.place, session: nil), confirmation: nil)
        await window.refreshPanes()
        #expect(window.changesClashes.isEmpty)
    }

    // Rule 2: git's prepared message fills an empty box once; the operator's edits, emptying included, are kept.
    @Test func theBoxFillsOnceWithGitsMessage() async {
        let (window, git) = await branchWindow()
        func state(_ kind: String, _ message: String) -> JSONValue {
            .object(["kind": .string(kind), "incoming": .string("side"), "onto": .string(""), "step": .integer(0),
                     "steps": .integer(0), "head": .string(""), "subject": .string(""), "message": .string(message)])
        }
        await git.set(conflicts: ["a.txt"], state: state("merge", "Merge branch 'side'"))
        await window.gitStatus?.refresh()
        await window.refreshPanes()
        #expect(window.changesMessages["/p"] == "Merge branch 'side'")
        window.changesMessageEdited(root: "/p", text: "")
        await window.refreshPanes()
        #expect(window.changesMessages["/p"] == nil, "emptied by the operator, not filled again")

        // The next operation fills again; a draft already in the box is kept; a rebase brings none.
        await git.set(conflicts: [])
        await window.gitStatus?.refresh()
        await window.refreshPanes()
        window.changesMessageEdited(root: "/p", text: "mine")
        await git.set(conflicts: ["a.txt"], state: state("cherry-pick", "Seed search"))
        await window.gitStatus?.refresh()
        await window.refreshPanes()
        #expect(window.changesMessages["/p"] == "mine")
        window.changesMessageEdited(root: "/p", text: "")
        await git.set(conflicts: [], state: nil)
        await window.gitStatus?.refresh()
        await window.refreshPanes()
        await git.set(conflicts: ["a.txt"], state: state("rebase", "Seed search"))
        await window.gitStatus?.refresh()
        await window.refreshPanes()
        #expect(window.changesMessages["/p"] == nil)
        await git.set(conflicts: [], state: state("revert", "Revert \"Seed search\""))
        await window.gitStatus?.refresh()
        await window.refreshPanes()
        #expect(window.changesMessages["/p"] == "Revert \"Seed search\"")
    }

    // A stop's note is left under the box, as a stash clash's is; Continue sends what the box holds.
    @Test func aStopsNoteIsShownAndContinueSendsTheBox() async {
        let (window, git) = await branchWindow()
        #expect(await window.changesMerge(root: "/p", branch: "side") == nil)
        #expect(window.changesErrors["/p"] == "Merge stopped on conflicts in a.txt; resolve them below")
        window.changesMessageEdited(root: "/p", text: "Merge side into main")
        #expect(await window.changesContinue(root: "/p") == nil)
        #expect(await git.args("git_continue") == .object(["root": .string("/p"), "message": .string("Merge side into main")]))
        window.changesMessageEdited(root: "/p", text: "  ")
        _ = await window.changesContinue(root: "/p")
        #expect(await git.args("git_continue") == .object(["root": .string("/p")]))
    }

    // Fix round 1: a finish that kept the autostash, or rewrote pushed commits, says so; a clean one says nothing.
    @Test func aFinishThatKeptTheStashSaysSo() async {
        let (window, git) = await branchWindow()
        let kept = "abc1234 Merge side; your uncommitted changes are in git stash"
        await git.set(continueReply: ["done": .bool(true), "conflicts": .array([]), "summary": .string(kept)])
        #expect(await window.changesContinue(root: "/p") == nil)
        #expect(window.changesErrors["/p"] == kept)
        let rewritten = "Successfully rebased; commits already pushed were rewritten, so Push is refused as behind"
        await git.set(continueReply: ["done": .bool(true), "conflicts": .array([]), "summary": .string(rewritten)])
        _ = await window.changesContinue(root: "/p")
        #expect(window.changesErrors["/p"] == rewritten)
        await git.set(continueReply: ["done": .bool(true), "conflicts": .array([]), "summary": .string("abc1234 Merge side")])
        _ = await window.changesContinue(root: "/p")
        #expect(window.changesErrors["/p"] == nil)
    }
}

