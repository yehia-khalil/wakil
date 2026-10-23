import Foundation
import Testing
@testable import WakilKit

/// A wakil-git with one root's status rows and a diff per side; records what was asked.
private actor DraftGit: ToolCaller {
    var rows: [(String, String, String)]
    var asked: [JSONValue] = []
    init(rows: [(String, String, String)]) { self.rows = rows }

    func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        func ok(_ o: [String: JSONValue]) -> JSONValue { .object(["structuredContent": .object(o)]) }
        switch name {
        case "git_status":
            return ok(["root": .string("/p"), "branch": .string("main"), "detached": .string(""), "upstream": .string(""),
                       "ahead": .integer(0), "behind": .integer(0),
                       "files": .array(rows.map { .object(["path": .string($0.0), "group": .string($0.1), "status": .string($0.2)]) })])
        case "git_diff":
            asked.append(arguments)
            let side = optionalString(arguments, "side") ?? ""
            return ok(["text": .string("diff --git a/a.go b/a.go\n@@ -1 +1 @@\n-old \(side)\n+new \(side)\n"),
                       "lines": .integer(4), "truncated": .bool(false), "binary": .bool(false)])
        default: return ok([:])
        }
    }
}

/// `config_tree` with one local quick provider and the org's commit-drafts switch.
private actor DraftContext: ToolCaller {
    let drafts: Bool
    init(drafts: Bool) { self.drafts = drafts }
    func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        switch name {
        case "config_tree":
            return .object(["structuredContent": .object([
                "org": .object(["id": .string("initech"), "quickProvider": .string("qwen"), "commitDrafts": .bool(drafts)]),
                "providers": .array([.object(["id": .string("qwen"), "kind": .string("local"),
                                              "baseURL": .string("http://127.0.0.1:8012"),
                                              "serves": .array([.string("infill"), .string("respond")])])]),
                "projects": .array([]),
            ])])
        default:
            return .object(["structuredContent": .object([:])])
        }
    }
}

/// Answers `respond` with `reply` after `delay`, or fails with `error`; remembers the last input.
private actor DraftModel: QuickModel {
    nonisolated let serves: Set<QuickOperation> = [.respond, .infill]
    let reply: String
    let delay: Duration
    let error: String?
    private(set) var lastInput = ""
    init(reply: String, delay: Duration = .zero, error: String? = nil) {
        self.reply = reply
        self.delay = delay
        self.error = error
    }
    func infill(_ r: InfillRequest) async throws -> String { "" }
    func respond(_ r: RespondRequest) async throws -> String {
        lastInput = r.input
        if delay > .zero { try await Task.sleep(for: delay) }
        if let error { throw QuickModelError.failed(error) }
        return reply
    }
    func shutdown() async {}
}

@MainActor
private func draftWindow(rows: [(String, String, String)] = [("a.go", "staged", "M")], drafts: Bool = true,
                         model: DraftModel = DraftModel(reply: #"{"message":"Fix login"}"#))
    async -> (WindowModel, DraftGit, DraftModel)
{
    let git = DraftGit(rows: rows)
    let status = GitStatus(git: git, roots: { ["/p"] })
    await status.refresh()
    let window = WindowModel.forTesting(
        scratchRoot: testScratchRoot, organization: "initech", context: ContextStore(client: DraftContext(drafts: drafts)),
        providerId: "qwen", quickModelFactory: { _, _ in model }, gitStatus: status)
    await window.rebuildQuickTasks()
    let sink = CommitDraftSink()
    await sink.bind { [weak window] root in
        guard let window else { throw CancellationError() }
        return try await window.changesDraftMessage(root: root)
    }
    await registerCommitDraftAction(into: window.registryForTesting, drafts: sink)
    return (window, git, model)
}

/// Waits (up to 5 s) until the window's draft is in flight: a fixed sleep raced it under load.
@MainActor
private func waitUntilDrafting(_ window: WindowModel) async {
    for _ in 0..<500 where !window.changesDrafting.contains("/p") {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

@Suite @MainActor struct WindowModelCommitDraftTests {
    @Test func aDraftFillsAnEmptyBox() async {
        let (window, git, model) = await draftWindow()
        let replaced = await window.changesDraft(root: "/p")
        #expect(replaced == "")
        #expect(window.changesMessages["/p"] == "Fix login")
        #expect(optionalString(await git.asked.last ?? .null, "side") == "staged")
        #expect(await model.lastInput.contains("+new staged"))
        #expect(window.changesDrafting.isEmpty)
    }

    @Test func aDraftReplacesTextAndReturnsWhatItReplaced() async {
        let (window, _, _) = await draftWindow()
        window.changesMessageEdited(root: "/p", text: "wip")
        #expect(await window.changesDraft(root: "/p") == "wip")
        #expect(window.changesMessages["/p"] == "Fix login")
    }

    @Test func typingWhileDraftingKeepsTheTypedText() async {
        let (window, _, _) = await draftWindow(model: DraftModel(reply: #"{"message":"Fix login"}"#, delay: .seconds(3)))
        let draft = Task { await window.changesDraft(root: "/p") }
        await waitUntilDrafting(window)
        #expect(window.changesDrafting.contains("/p"))
        window.changesMessageEdited(root: "/p", text: "mine")
        #expect(await draft.value == nil)
        #expect(window.changesMessages["/p"] == "mine")
        #expect(window.changesDrafting.isEmpty)
    }

    @Test func aCancelledDraftLeavesTheBox() async {
        let (window, _, _) = await draftWindow(model: DraftModel(reply: #"{"message":"Fix login"}"#, delay: .seconds(3)))
        let draft = Task { await window.changesDraft(root: "/p") }
        await waitUntilDrafting(window)
        window.changesCancelDraft(root: "/p")
        #expect(await draft.value == nil)
        #expect(window.changesMessages["/p"] == nil)
        #expect(window.changesErrors["/p"] == nil, "a cancel is not an error")
    }

    @Test func aDraftAfterAnOrgSwitchIsDropped() async {
        let (window, _, _) = await draftWindow(model: DraftModel(reply: #"{"message":"Fix login"}"#, delay: .seconds(3)))
        let draft = Task { await window.changesDraft(root: "/p") }
        await waitUntilDrafting(window)
        await window.rebuildQuickTasks()          // a new generation, as an org switch makes
        #expect(await draft.value == nil)
        #expect(window.changesMessages["/p"] == nil)
    }

    @Test func theSwitchOffRefusesWithItsWords() async {
        let (window, _, _) = await draftWindow(drafts: false)
        #expect(await window.changesDraft(root: "/p") == nil)
        #expect(window.changesErrors["/p"] == "commit drafts are off for initech — Settings → Providers → Quick tasks")
    }

    @Test func aCleanRootHasNothingToDraftFrom() async {
        let (window, _, _) = await draftWindow(rows: [])
        #expect(await window.changesDraft(root: "/p") == nil)
        #expect(window.changesErrors["/p"] == "nothing to draft from: p has no changes")
    }

    @Test func commitAllDraftsFromChangesAndUntracked() async {
        let (window, git, model) = await draftWindow(rows: [("a.go", "changed", "M"), ("new.go", "untracked", "?")])
        _ = await window.changesDraft(root: "/p")
        #expect(optionalString(await git.asked.last ?? .null, "side") == "changed")
        #expect(await model.lastInput.contains("new.go"))
    }

    @Test func aModelErrorIsShownWholeAndTheBoxKept() async {
        let (window, _, _) = await draftWindow(model: DraftModel(reply: "", error: "the local server said no, at length"))
        window.changesMessageEdited(root: "/p", text: "keep")
        #expect(await window.changesDraft(root: "/p") == nil)
        #expect(window.changesMessages["/p"] == "keep")
        #expect(window.changesErrors["/p"]?.contains("the local server said no, at length") == true)
    }

    @Test func theActionReturnsTheMessageAndIsControlAndAgentReachable() async throws {
        let (window, _, _) = await draftWindow()
        let d = try #require(await window.registryForTesting.descriptor(named: "editor_changes_draft_message"))
        #expect(d.kind == .control)
        #expect(d.audience == .agentReachable)
        let reply = try await window.registryForTesting.dispatch(
            name: "editor_changes_draft_message", params: .object(["root": .string("/p")]), origin: .agent,
            caller: .test("production"), confirmation: nil)
        #expect(reply == .object(["message": .string("Fix login")]))
        #expect(window.changesMessages["/p"] == "Fix login")
    }

    @Test func theActionWithNothingBoundSaysNoProvider() async throws {
        let registry = ActionRegistry(journalDirectory: testScratchRoot.appendingPathComponent(UUID().uuidString), sessionId: "t")
        await registerCommitDraftAction(into: registry, drafts: CommitDraftSink())
        await #expect(throws: (any Error).self) {
            _ = try await registry.dispatch(name: "editor_changes_draft_message", params: .object(["root": .string("/p")]),
                                            origin: .agent, caller: .test("production"), confirmation: nil)
        }
    }

    // Final review I4: a draft from the agent or voice replaces the box too, so the window publishes
    // every replacement — the one place the view registers ⌘Z from — not just the button's.
    @Test func everyDraftThatLandsIsPublishedForUndo() async throws {
        let (window, _, _) = await draftWindow()
        window.changesMessageEdited(root: "/p", text: "wip")
        _ = try await window.registryForTesting.dispatch(
            name: "editor_changes_draft_message", params: .object(["root": .string("/p")]), origin: .agent,
            caller: .test("production"), confirmation: nil)
        let first = try #require(window.changesLastDraft)
        #expect(first.root == "/p")
        #expect(first.replaced == "wip")
        _ = await window.changesDraft(root: "/p")
        let second = try #require(window.changesLastDraft)
        #expect(second.replaced == "Fix login")
        #expect(second.serial != first.serial)
    }
}
