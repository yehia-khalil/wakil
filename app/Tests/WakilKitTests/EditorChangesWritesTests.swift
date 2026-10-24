import Foundation
import Testing
@testable import WakilKit

/// A recording wakil-git: answers each write's shape, parks `git_commit` on a root until released.
private actor WriteGit: ToolCaller {
    struct Call: Sendable { let name: String; let args: JSONValue; let timeout: TimeInterval }
    var calls: [Call] = []
    var lastCall: Call? { calls.last }
    var holdCommit: String?
    private var parked: CheckedContinuation<Void, Never>?
    private var released = false
    var statusRows: [String: [(String, String, String)]] = [:]
    var origPaths: [String: String] = [:]
    /// `git_show`'s text by rev (3a-ii-b); a rev missing here answers absent.
    var shows: [String: String] = [:]
    var stageHunkError: String?

    func set(show text: String, rev: String) { shows[rev] = text }
    func failStageHunk(_ why: String) { stageHunkError = why }

    func set(rows: [(String, String, String)], root: String) { statusRows[root] = rows }
    func set(origPath: String, for path: String) { origPaths[path] = origPath }
    func hold(root: String) { holdCommit = root; released = false }
    func release() { released = true; parked?.resume(); parked = nil }
    private func park(_ c: CheckedContinuation<Void, Never>) { if released { c.resume() } else { parked = c } }
    func count(_ name: String) -> Int { calls.filter { $0.name == name }.count }

    func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        calls.append(Call(name: name, args: arguments, timeout: timeout))
        let root = optionalString(arguments, "root") ?? ""
        func ok(_ o: [String: JSONValue]) -> JSONValue { .object(["structuredContent": .object(o)]) }
        switch name {
        case "git_status":
            let rows = statusRows[root] ?? []
            return ok(["root": .string(root), "branch": .string("main"), "detached": .string(""),
                       "upstream": .string(""), "ahead": .integer(0), "behind": .integer(0),
                       "files": .array(rows.map { row in
                           var o: [String: JSONValue] = ["path": .string(row.0), "group": .string(row.1), "status": .string(row.2)]
                           if let orig = origPaths[row.0] { o["origPath"] = .string(orig) }
                           return .object(o)
                       })])
        case "git_commit":
            if holdCommit == root { await withCheckedContinuation { c in Task { await self.park(c) } } }
            return ok(["commit": .string("abc"), "summary": .string("1 file changed")])
        case "git_amend": return ok(["commit": .string("def"), "summary": .string("amended")])
        case "git_undo_commit": return ok(["message": .string("m")])
        case "git_discard": return ok(["trashed": .array([.string("a.go")])])
        case "git_blob": return ok(["blob": .string("abc123")])
        case "git_show":
            let rev = optionalString(arguments, "rev") ?? ""
            guard let text = shows[rev] else { return ok(["text": .string(""), "absent": .bool(true)]) }
            return ok(["text": .string(text), "binary": .bool(false), "truncated": .bool(false),
                       "bytes": .integer(Int64(text.utf8.count))])
        case "git_stage_hunk" where stageHunkError != nil:
            return .object(["isError": .bool(true), "content": .array([.object(["type": .string("text"), "text": .string(stageHunkError!)])])])
        case "git_merge", "git_rebase", "git_continue", "git_skip", "git_abort":
            return ok(["done": .bool(false), "conflicts": .array([.string("a.txt")]),
                       "summary": .string("Merge stopped on conflicts in a.txt; resolve them below")])
        case "git_stash_apply", "git_stash_pop":
            return ok(["note": .string("Your stash clashes with main in a.txt; resolve it below, or Undo Apply"),
                       "clash": testClash])
        case "git_fail": return .object(["isError": .bool(true), "content": .array([.object(["type": .string("text"), "text": .string("nope")])])])
        default: return ok([:])
        }
    }
}

/// A clash as git_stash_apply returns it (3a-v-b).
private let testClash: JSONValue = .object([
    "id": .string(String(repeating: "c", count: 40)),
    "files": .array([.object(["path": .string("a.txt"), "hash": .string("h1")])]),
    "created": .array([]), "conflicts": .array([.string("a.txt")]),
])

private struct Fixture {
    let registry: ActionRegistry
    let git: WriteGit
    let status: GitStatus
    let panes: PaneStore
    let layout: LayoutStore
    let pane: String

    /// In production, from the agent, with no confirmation: a write priced anything but allow fails here.
    func dispatch(_ name: String, _ params: [String: JSONValue]) async throws -> JSONValue {
        try await registry.dispatch(name: name, params: .object(params), origin: .agent,
                                    caller: .test("production"), confirmation: nil)
    }
}

private func fixture(rows: [String: [(String, String, String)]] = ["/p": [], "/q": []]) async throws -> Fixture {
    let dir = testScratchRoot.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let registry = ActionRegistry(journalDirectory: dir, sessionId: "t")
    let git = WriteGit()
    for (r, f) in rows { await git.set(rows: f, root: r) }
    let status = GitStatus(git: git, roots: { ["/p", "/q"] })
    await status.refresh()
    let panes = PaneStore(kinds: PaneKinds.standard)
    let layout = LayoutStore()
    let pane = await layout.open(kind: "editor", title: "Editor").id
    await registerEditorChangesWrites(into: registry, gitStatus: status, panes: panes, layout: layout, writes: GitWriteFlights())
    return Fixture(registry: registry, git: git, status: status, panes: panes, layout: layout, pane: pane)
}

private func args(_ call: WriteGit.Call?, _ key: String) -> JSONValue? {
    guard case .object(let o)? = call?.args else { return nil }
    return o[key]
}

@Suite struct EditorChangesWritesTests {
    @Test func eachWriteCallsItsToolWithTheRootAndIsAllowedEverywhere() async throws {
        let f = try await fixture()
        let rows: [(String, String, [String: JSONValue])] = [
            ("editor_changes_stage", "git_stage", ["root": .string("/p"), "paths": .array([.string("a.go")])]),
            ("editor_changes_unstage", "git_unstage", ["root": .string("/p"), "paths": .array([.string("a.go")])]),
            ("editor_changes_discard", "git_discard", ["root": .string("/p"), "paths": .array([.string("a.go")])]),
            ("editor_changes_commit", "git_commit", ["root": .string("/p"), "message": .string("m")]),
            ("editor_changes_amend", "git_amend", ["root": .string("/p")]),
            ("editor_changes_undo_commit", "git_undo_commit", ["root": .string("/p")]),
        ]
        for (action, tool, params) in rows {
            _ = try await f.dispatch(action, params)
            let calls = await f.git.calls.map(\.name).filter { $0 != "git_status" }
            #expect(calls.last == tool, "\(action)")
            let d = try #require(await f.registry.descriptor(named: action))
            #expect(d.kind == .mutate)
            #expect(d.audience == .agentReachable)
        }
    }

    @Test func resultsCarryTheToolsFields() async throws {
        let f = try await fixture()
        let c = try await f.dispatch("editor_changes_commit", ["root": .string("/p"), "message": .string("m")])
        #expect(c == .object(["commit": .string("abc"), "summary": .string("1 file changed")]))
        let u = try await f.dispatch("editor_changes_undo_commit", ["root": .string("/p")])
        #expect(u == .object(["message": .string("m")]))
        let d = try await f.dispatch("editor_changes_discard", ["root": .string("/p"), "paths": .array([.string("a.go")])])
        #expect(d == .object(["trashed": .array([.string("a.go")])]))
    }

    @Test func aGroupStagesEveryPathInIt() async throws {
        let f = try await fixture(rows: ["/p": [("a.go", "changed", "M"), ("b.go", "changed", "M"), ("c.go", "untracked", "?")], "/q": []])
        _ = try await f.dispatch("editor_changes_stage", ["root": .string("/p"), "group": .string("changed")])
        let call = await f.git.calls.last { $0.name == "git_stage" }
        #expect(args(call, "paths") == .array([.string("a.go"), .string("b.go")]))
    }

    @Test func absolutePathsAreSentRelativeToTheRoot() async throws {
        let f = try await fixture()
        _ = try await f.dispatch("editor_changes_stage", ["root": .string("/p"), "paths": .array([.string("/p/sub/a.go")])])
        #expect(args(await f.git.calls.last { $0.name == "git_stage" }, "paths") == .array([.string("sub/a.go")]))
    }

    @Test func commitWithNothingStagedDefaultsToAll() async throws {
        let f = try await fixture(rows: ["/p": [("a.go", "changed", "M")], "/q": [("b.go", "staged", "M")]])
        _ = try await f.dispatch("editor_changes_commit", ["root": .string("/p"), "message": .string("m")])
        #expect(args(await f.git.calls.last { $0.name == "git_commit" }, "all") == .bool(true))
        _ = try await f.dispatch("editor_changes_commit", ["root": .string("/q"), "message": .string("m")])
        let call = await f.git.calls.last { $0.name == "git_commit" }
        #expect(args(call, "all") == .bool(false))
        #expect(call?.timeout == MCPClient.gitWriteReplyTimeout)
        _ = try await f.dispatch("editor_changes_commit", ["root": .string("/q"), "message": .string("m"), "all": .bool(true)])
        #expect(args(await f.git.calls.last { $0.name == "git_commit" }, "all") == .bool(true))
    }

    @Test(.timeLimit(.minutes(1))) func aSecondWriteOnTheSameRootIsRefusedAndAnotherRootIsNot() async throws {
        let f = try await fixture()
        await f.git.hold(root: "/p")
        let first = Task { try await f.dispatch("editor_changes_commit", ["root": .string("/p"), "message": .string("m")]) }
        while await f.git.count("git_commit") == 0 { try await Task.sleep(for: .milliseconds(1)) }
        do {
            _ = try await f.dispatch("editor_changes_stage", ["root": .string("/p"), "paths": .array([.string("a.go")])])
            Issue.record("a second write on /p ran")
        } catch {
            #expect("\(error)".contains("a git write is already running in p"), "\(error)")
        }
        _ = try await f.dispatch("editor_changes_stage", ["root": .string("/q"), "paths": .array([.string("a.go")])])
        await f.git.release()
        _ = try await first.value
        // The root is free again.
        _ = try await f.dispatch("editor_changes_stage", ["root": .string("/p"), "paths": .array([.string("a.go")])])
    }

    @Test func afterAWriteTheRootsStatusIsReadAgain() async throws {
        let f = try await fixture()
        let before = await f.git.count("git_status")
        _ = try await f.dispatch("editor_changes_stage", ["root": .string("/p"), "paths": .array([.string("a.go")])])
        #expect(await f.git.count("git_status") == before + 1)
    }

    @Test func flightsAreOnePerRoot() async {
        let flights = GitWriteFlights()
        #expect(await flights.begin("/p"))
        #expect(await flights.begin("/p") == false)
        #expect(await flights.begin("/q"))
        #expect(await flights.running("/p"))
        await flights.end("/p")
        #expect(await flights.running("/p") == false)
    }

    @Test func stageHunkSendsTheIndexTextAndTheBlobItWasComputedFrom() async throws {
        let f = try await fixture()
        let base = "a\nb\n", text = "a\nB\nc\n"
        await f.panes.updateEditor(paneId: f.pane, create: true) { s in
            s.tabs = [EditorTab(subject: .file(path: "/p/a.go", root: "/p"), text: text, savedText: base, language: "go",
                                diskState: .inSync, mtime: 1, cursor: EditorPosition(line: 1, column: 1), selection: nil,
                                visibleRange: nil, scrollTop: 0, notice: nil, readOnly: false, saving: false, edits: 0,
                                lastAgentEdit: nil, baseline: base, peek: 0)]
            s.active = 0
        }
        _ = try await f.dispatch("editor_changes_stage_hunk", ["path": .string("/p/a.go"), "hunk": .integer(0)])
        let call = await f.git.calls.last { $0.name == "git_stage_hunk" }
        #expect(args(call, "root") == .string("/p"))
        #expect(args(call, "path") == .string("a.go"))
        #expect(args(call, "content") == .string(try #require(editorStagedText(base: base, text: text, hunk: 0))))
        #expect(args(call, "expect") == .string(gitBlobId(base)), "the id of the baseline, not of the index now")
        #expect(await f.git.count("git_blob") == 0)
        // hunk omitted: the tab's peek.
        _ = try await f.dispatch("editor_changes_stage_hunk", ["path": .string("/p/a.go")])
        #expect(await f.git.count("git_stage_hunk") == 2)
    }

    private func openTab(_ f: Fixture, baseline: String?) async {
        await f.panes.updateEditor(paneId: f.pane, create: true) { s in
            s.tabs = [EditorTab(subject: .file(path: "/p/a.go", root: "/p"), text: "a\nB\n", savedText: "a\nb\n", language: "go",
                                diskState: .inSync, mtime: 1, cursor: EditorPosition(line: 1, column: 1), selection: nil,
                                visibleRange: nil, scrollTop: 0, notice: nil, readOnly: false, saving: false, edits: 0,
                                lastAgentEdit: nil, baseline: baseline, peek: 0)]
            s.active = 0
        }
    }

    @Test func stageHunkRefusesATabWithNoBaseline() async throws {
        let f = try await fixture()
        await openTab(f, baseline: nil)
        await #expect(throws: (any Error).self) {
            _ = try await f.dispatch("editor_changes_stage_hunk", ["path": .string("/p/a.go"), "hunk": .integer(0)])
        }
        #expect(await f.git.count("git_stage_hunk") == 0)
    }

    @Test func stageHunkRefusesAHunkOutOfRange() async throws {
        let f = try await fixture()
        await openTab(f, baseline: "a\nb\n")
        await #expect(throws: (any Error).self) {
            _ = try await f.dispatch("editor_changes_stage_hunk", ["path": .string("/p/a.go"), "hunk": .integer(5)])
        }
        #expect(await f.git.count("git_stage_hunk") == 0)
    }

    @Test func stageHunkRefusesAFileThatIsNotOpenOrHasNoBaseline() async throws {
        let f = try await fixture()
        await #expect(throws: (any Error).self) {
            _ = try await f.dispatch("editor_changes_stage_hunk", ["path": .string("/p/none.go"), "hunk": .integer(0)])
        }
        #expect(await f.git.count("git_stage_hunk") == 0)
    }

    @Test func eachPathWriteTakesOnlyItsOwnGroups() async throws {
        let f = try await fixture(rows: ["/p": [("a.go", "changed", "M"), ("s.go", "staged", "M"), ("n.go", "untracked", "?")], "/q": []])
        for (action, group) in [("editor_changes_stage", "staged"), ("editor_changes_unstage", "changed"),
                                ("editor_changes_unstage", "untracked"), ("editor_changes_discard", "staged")] {
            await #expect(throws: (any Error).self, "\(action) with group \(group)") {
                _ = try await f.dispatch(action, ["root": .string("/p"), "group": .string(group)])
            }
        }
        #expect(await f.git.count("git_stage") + f.git.count("git_unstage") + f.git.count("git_discard") == 0)
        do {
            _ = try await f.dispatch("editor_changes_unstage", ["root": .string("/p"), "group": .string("changed")])
        } catch {
            #expect("\(error)".contains("editor_changes_unstage takes group staged, not changed"), "\(error)")
        }
        _ = try await f.dispatch("editor_changes_unstage", ["root": .string("/p"), "group": .string("staged")])
        _ = try await f.dispatch("editor_changes_discard", ["root": .string("/p"), "group": .string("untracked")])
        _ = try await f.dispatch("editor_changes_stage", ["root": .string("/p"), "group": .string("untracked")])
    }

    @Test func unstagingARenameUnstagesItsOldPathToo() async throws {
        let f = try await fixture(rows: ["/p": [("b.go", "staged", "R"), ("c.go", "staged", "M")], "/q": []])
        await f.git.set(origPath: "a.go", for: "b.go")
        await f.status.refresh()
        _ = try await f.dispatch("editor_changes_unstage", ["root": .string("/p"), "paths": .array([.string("/p/b.go")])])
        #expect(args(await f.git.calls.last { $0.name == "git_unstage" }, "paths") == .array([.string("b.go"), .string("a.go")]))
        _ = try await f.dispatch("editor_changes_unstage", ["root": .string("/p"), "group": .string("staged")])
        #expect(args(await f.git.calls.last { $0.name == "git_unstage" }, "paths")
                == .array([.string("b.go"), .string("a.go"), .string("c.go")]))
    }

    @Test func stageHunkTakesTheTabOfTheGivenPane() async throws {
        let f = try await fixture()
        let second = await f.layout.open(kind: "editor", title: "Editor 2").id
        let base = "a\nb\n"
        for (pane, text) in [(f.pane, "a\nFIRST\n"), (second, "a\nSECOND\n")] {
            await f.panes.updateEditor(paneId: pane, create: true) { s in
                s.tabs = [EditorTab(subject: .file(path: "/p/a.go", root: "/p"), text: text, savedText: base, language: "go",
                                    diskState: .inSync, mtime: 1, cursor: EditorPosition(line: 1, column: 1), selection: nil,
                                    visibleRange: nil, scrollTop: 0, notice: nil, readOnly: false, saving: false, edits: 0,
                                    lastAgentEdit: nil, baseline: base, peek: 0)]
                s.active = 0
            }
        }
        _ = try await f.dispatch("editor_changes_stage_hunk", ["path": .string("/p/a.go"), "hunk": .integer(0), "pane": .string(second)])
        let call = await f.git.calls.last { $0.name == "git_stage_hunk" }
        #expect(args(call, "content") == .string(try #require(editorStagedText(base: base, text: "a\nSECOND\n", hunk: 0))))
    }

    // MARK: 3a-ii-b — Stage and Unstage Selected Ranges

    private func openDiff(_ f: Fixture, group: GitGroup, original: String, modified: String,
                          selection: EditorRange? = nil, binary: Bool = false, truncated: Bool = false,
                          loading: Bool = false) async {
        await f.panes.updateEditor(paneId: f.pane, create: true) { s in
            s.tabs = [EditorTab(subject: .diff(root: "/p", path: "a.go", group: group), text: "", savedText: "", language: "go",
                                diskState: .inSync, mtime: 1, cursor: EditorPosition(line: 1, column: 1), selection: selection,
                                visibleRange: nil, scrollTop: 0, notice: nil, readOnly: true, saving: false, edits: 0,
                                lastAgentEdit: nil,
                                diffState: GitDiffState(original: original, modified: modified, language: "go", binary: binary,
                                                        bytes: modified.utf8.count, lines: 0, truncated: truncated, error: nil,
                                                        loading: loading))]
            s.active = 0
        }
    }

    private func spans(_ pairs: [(Int, Int)]) -> JSONValue {
        .array(pairs.map { .object(["start": .integer(Int64($0.0)), "end": .integer(Int64($0.1))]) })
    }

    @Test func stageRangesSendsTheIndexTextWithOnlyTheSelectedLinesAndTheIndexBlob() async throws {
        let f = try await fixture(rows: ["/p": [("a.go", "changed", "M")], "/q": []])
        await openDiff(f, group: .changed, original: "a\n", modified: "a\nb\nc\n")
        _ = try await f.dispatch("editor_changes_stage_ranges", ["path": .string("/p/a.go"), "ranges": spans([(2, 2)])])
        let call = await f.git.calls.last { $0.name == "git_stage_hunk" }
        #expect(args(call, "root") == .string("/p"))
        #expect(args(call, "path") == .string("a.go"))
        #expect(args(call, "content") == .string("a\nb\n"))
        #expect(args(call, "expect") == .string(gitBlobId("a\n")))
        #expect(await f.git.count("git_show") == 0, "the tab's texts, not a fresh read")
    }

    @Test func unstageRangesExpectsTheIndexBlob() async throws {
        let f = try await fixture(rows: ["/p": [("a.go", "staged", "M")], "/q": []])
        await openDiff(f, group: .staged, original: "a\n", modified: "a\nb\n")
        _ = try await f.dispatch("editor_changes_unstage_ranges", ["path": .string("/p/a.go"), "ranges": spans([(2, 2)])])
        let call = await f.git.calls.last { $0.name == "git_stage_hunk" }
        #expect(args(call, "content") == .string("a\n"))
        #expect(args(call, "expect") == .string(gitBlobId("a\nb\n")))
    }

    @Test func stageRangesWithNoTabReadsBothSidesFromGit() async throws {
        let f = try await fixture(rows: ["/p": [("a.go", "changed", "M")], "/q": []])
        await f.git.set(show: "a\n", rev: "index")
        await f.git.set(show: "a\nb\n", rev: "worktree")
        _ = try await f.dispatch("editor_changes_stage_ranges", ["path": .string("/p/a.go"), "ranges": spans([(2, 2)])])
        let names = await f.git.calls.map(\.name).filter { $0 != "git_status" }
        #expect(names == ["git_show", "git_show", "git_stage_hunk"])
        #expect(args(await f.git.calls.last { $0.name == "git_stage_hunk" }, "content") == .string("a\nb\n"))
    }

    @Test func stageRangesDefaultsToTheTabsSelection() async throws {
        let f = try await fixture(rows: ["/p": [("a.go", "changed", "M")], "/q": []])
        let caret = EditorRange(start: EditorPosition(line: 3, column: 1), end: EditorPosition(line: 3, column: 1))
        await openDiff(f, group: .changed, original: "a\n", modified: "a\nb\nc\n", selection: caret)
        _ = try await f.dispatch("editor_changes_stage_ranges", ["path": .string("/p/a.go")])
        #expect(args(await f.git.calls.last { $0.name == "git_stage_hunk" }, "content") == .string("a\nc\n"))
    }

    @Test func stageRangesWithOnlyACaretTakesTheCaretsLine() async throws {
        let f = try await fixture(rows: ["/p": [("a.go", "changed", "M")], "/q": []])
        await openDiff(f, group: .changed, original: "a\n", modified: "a\nb\nc\n")
        await f.panes.updateEditor(paneId: f.pane, create: false) { s in s.tabs[0].cursor = EditorPosition(line: 2, column: 1) }
        _ = try await f.dispatch("editor_changes_stage_ranges", ["path": .string("/p/a.go")])
        #expect(args(await f.git.calls.last { $0.name == "git_stage_hunk" }, "content") == .string("a\nb\n"))
    }

    // Final review I2: a refresh marks the tab loading but keeps the texts the operator is looking at;
    // the lines they selected are of those texts, never of a fresh read.
    @Test func aRefreshingTabStillStagesTheTextsOnScreen() async throws {
        let f = try await fixture(rows: ["/p": [("a.go", "changed", "M")], "/q": []])
        await openDiff(f, group: .changed, original: "a\n", modified: "a\nb\nc\n", loading: true)
        await f.git.set(show: "a\n", rev: "index")
        await f.git.set(show: "a\nNEW\nb\nc\n", rev: "worktree")
        _ = try await f.dispatch("editor_changes_stage_ranges", ["path": .string("/p/a.go"), "ranges": spans([(2, 2)])])
        #expect(await f.git.count("git_show") == 0)
        #expect(args(await f.git.calls.last { $0.name == "git_stage_hunk" }, "content") == .string("a\nb\n"))
    }

    // Final review M2: a file deleted in the work tree has no lines to select; staging "ranges" of it
    // would write an empty file into the index instead of the deletion.
    @Test func refusesAWorkTreeDeletionForStage() async throws {
        let f = try await fixture(rows: ["/p": [("a.go", "changed", "D")], "/q": []])
        await openDiff(f, group: .changed, original: "a\nb\n", modified: "")
        let e = await refusal(f, "editor_changes_stage_ranges", ["path": .string("/p/a.go"), "ranges": spans([(1, 1)])])
        #expect(e.contains("deleted"), "\(e)")
        #expect(await f.git.count("git_stage_hunk") == 0)
    }

    private func refusal(_ f: Fixture, _ action: String, _ params: [String: JSONValue]) async -> String {
        do {
            _ = try await f.dispatch(action, params)
            return ""
        } catch {
            return "\(error)"
        }
    }

    @Test func refusesASelectionWithNoChange() async throws {
        let f = try await fixture(rows: ["/p": [("a.go", "changed", "M")], "/q": []])
        await openDiff(f, group: .changed, original: "a\n", modified: "a\nb\n")
        let e = await refusal(f, "editor_changes_stage_ranges", ["path": .string("/p/a.go"), "ranges": spans([(1, 1)])])
        #expect(e.contains("the selection holds no change"), "\(e)")
        #expect(await f.git.count("git_stage_hunk") == 0)
    }

    @Test func refusesABinaryOrTruncatedDiff() async throws {
        for (binary, truncated, words) in [(true, false, "binary"), (false, true, "first 2 MB shown")] {
            let f = try await fixture(rows: ["/p": [("a.go", "changed", "M")], "/q": []])
            await openDiff(f, group: .changed, original: "a\n", modified: "a\nb\n", binary: binary, truncated: truncated)
            let e = await refusal(f, "editor_changes_stage_ranges", ["path": .string("/p/a.go"), "ranges": spans([(2, 2)])])
            #expect(e.contains(words), "\(e)")
            #expect(await f.git.count("git_stage_hunk") == 0)
        }
    }

    @Test func refusesAConflictedFile() async throws {
        let f = try await fixture(rows: ["/p": [("a.go", "conflicts", "U")], "/q": []])
        await openDiff(f, group: .changed, original: "a\n", modified: "a\nb\n")
        let e = await refusal(f, "editor_changes_stage_ranges", ["path": .string("/p/a.go"), "ranges": spans([(2, 2)])])
        #expect(e.contains("conflict"), "\(e)")
        #expect(await f.git.count("git_stage_hunk") == 0)
    }

    @Test func refusesAStagedDeletionForUnstage() async throws {
        let f = try await fixture(rows: ["/p": [("a.go", "staged", "D")], "/q": []])
        let e = await refusal(f, "editor_changes_unstage_ranges", ["path": .string("/p/a.go"), "ranges": spans([(1, 1)])])
        #expect(e.contains("deleted"), "\(e)")
        #expect(await f.git.count("git_stage_hunk") == 0)
    }

    @Test func aMovedIndexIsReportedAsReopenTheDiff() async throws {
        let f = try await fixture(rows: ["/p": [("a.go", "changed", "M")], "/q": []])
        await openDiff(f, group: .changed, original: "a\n", modified: "a\nb\n")
        await f.git.failStageHunk("the change moved — open the peek again")
        let e = await refusal(f, "editor_changes_stage_ranges", ["path": .string("/p/a.go"), "ranges": spans([(2, 2)])])
        #expect(e.contains("the change moved — reopen the diff"), "\(e)")
    }

    @Test func rangeActionsAreAllowedMutationsForTheAgentInProduction() async throws {
        let f = try await fixture(rows: ["/p": [("a.go", "changed", "M")], "/q": []])
        for action in ["editor_changes_stage_ranges", "editor_changes_unstage_ranges"] {
            let d = try #require(await f.registry.descriptor(named: action))
            #expect(d.kind == .mutate)
            #expect(d.audience == .agentReachable)
        }
        await openDiff(f, group: .changed, original: "a\n", modified: "a\nb\n")
        _ = try await f.dispatch("editor_changes_stage_ranges", ["path": .string("/p/a.go"), "ranges": spans([(2, 2)])])
        #expect(await f.git.count("git_stage_hunk") == 1)
    }

    // 3a-v-b: merge, rebase, continue and Keep File run for anyone; each sends its tool what it was given.
    @Test func theConflictWritesCallTheirTools() async throws {
        let f = try await fixture()
        let rows: [(String, [String: JSONValue], String, JSONValue)] = [
            ("editor_changes_merge", ["root": .string("/p"), "branch": .string("feature")],
             "git_merge", .object(["root": .string("/p"), "branch": .string("feature")])),
            ("editor_changes_rebase", ["root": .string("/p"), "onto": .string("main")],
             "git_rebase", .object(["root": .string("/p"), "onto": .string("main")])),
            ("editor_changes_continue", ["root": .string("/p"), "message": .string("Merge feature")],
             "git_continue", .object(["root": .string("/p"), "message": .string("Merge feature")])),
            ("editor_changes_continue", ["root": .string("/p")], "git_continue", .object(["root": .string("/p")])),
            ("editor_changes_keep_file", ["root": .string("/p"), "path": .string("/p/a.txt")],
             "git_resolve", .object(["root": .string("/p"), "path": .string("a.txt"), "take": .string("keep")])),
        ]
        for (action, params, tool, sent) in rows {
            let reply = try await f.dispatch(action, params)
            let last = await f.git.calls.last { $0.name != "git_status" }
            #expect(last?.name == tool && last?.args == sent, "\(action)")
            if tool != "git_resolve" { #expect(optionalString(reply, "summary")?.contains("stopped on conflicts") == true) }
            let d = try #require(await f.registry.descriptor(named: action))
            #expect(d.kind == .mutate && d.audience == .agentReachable, "\(action)")
        }
    }

    // Abort, Skip, a whole-file take and Undo Apply throw work away: the agent's ask is gated.
    @Test func theThrowingAwayWritesAreGatedForTheAgent() async throws {
        let f = try await fixture()
        for (action, params) in [
            ("editor_changes_abort", ["root": JSONValue.string("/p")]),
            ("editor_changes_skip", ["root": .string("/p")]),
            ("editor_changes_take", ["root": .string("/p"), "path": .string("a.txt"), "take": .string("current")]),
            ("editor_changes_stash_undo_apply", ["root": .string("/p")]),
        ] {
            await #expect(throws: ActionError.needsConfirmation(action)) { _ = try await f.dispatch(action, params) }
            let d = try #require(await f.registry.descriptor(named: action))
            #expect(d.kind == .mutate && d.audience == .agentReachable, "\(action)")
        }
        #expect(await f.git.calls.allSatisfy { $0.name == "git_status" })
    }

    private func ui(_ f: Fixture, _ action: String, _ params: [String: JSONValue]) async throws -> JSONValue {
        try await f.registry.dispatch(name: action, params: .object(params), origin: .ui, caller: .test("staging"), confirmation: nil)
    }

    @Test func aTakeSendsItsSideAndRefusesAnyOther() async throws {
        let f = try await fixture()
        for take in ["current", "incoming", "delete"] {
            _ = try await ui(f, "editor_changes_take", ["root": .string("/p"), "path": .string("/p/b c.txt"), "take": .string(take)])
            let last = await f.git.calls.last { $0.name != "git_status" }
            #expect(last?.name == "git_resolve"
                    && last?.args == .object(["root": .string("/p"), "path": .string("b c.txt"), "take": .string(take)]))
        }
        await #expect(throws: (any Error).self) {
            _ = try await ui(f, "editor_changes_take", ["root": .string("/p"), "path": .string("a.txt"), "take": .string("keep")])
        }
        #expect(await f.git.count("git_resolve") == 3)
    }

    // R4: Undo Apply sends the clash the root's last stash apply returned, once; with none it is refused.
    @Test func undoApplySendsTheRememberedClashOnce() async throws {
        let f = try await fixture()
        do {
            _ = try await ui(f, "editor_changes_stash_undo_apply", ["root": .string("/p")])
            Issue.record("no clash, yet Undo Apply ran")
        } catch {
            #expect("\(error)".contains("No stash clash to undo"), "\(error)")
        }
        let id: JSONValue = .string(String(repeating: "c", count: 40))
        _ = try await ui(f, "editor_changes_stash_apply", ["root": .string("/p"), "index": .integer(0), "id": id])
        let kept = await f.status.clashes
        #expect(kept["/p"] != nil && kept["/q"] == nil)
        _ = try await ui(f, "editor_changes_stash_undo_apply", ["root": .string("/p")])
        let last = await f.git.calls.last { $0.name != "git_status" }
        #expect(last?.name == "git_stash_undo_apply" && last?.args == .object(["root": .string("/p"), "clash": testClash]))
        #expect(await f.status.clashes["/p"] == nil)
    }
}
