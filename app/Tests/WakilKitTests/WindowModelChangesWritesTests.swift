import Foundation
import Testing
@testable import WakilKit

/// A wakil-git that answers the writes the window dispatches, records them, and can fail or park a commit.
private actor ChangesGit: ToolCaller {
    struct Call: Sendable { let name: String; let args: JSONValue }
    var calls: [Call] = []
    var lastCall: Call? { calls.last }
    var failCommit: String?
    var undoMessage = "m"
    var identity: (name: String, email: String, from: String) = ("O", "o@x", "organisation")
    var gated = false
    private var parked: CheckedContinuation<Void, Never>?
    private var released = false

    func configure(failCommit: String?, undoMessage: String?) {
        self.failCommit = failCommit
        if let undoMessage { self.undoMessage = undoMessage }
    }
    func set(identity: (name: String, email: String, from: String)) { self.identity = identity }
    func gateCommits() { gated = true; released = false }
    func release() { released = true; parked?.resume(); parked = nil }
    private func park(_ c: CheckedContinuation<Void, Never>) { if released { c.resume() } else { parked = c } }
    func parkedNow() -> Bool { parked != nil }
    func count(_ name: String) -> Int { calls.filter { $0.name == name }.count }

    func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        if name != "git_status" { calls.append(Call(name: name, args: arguments)) }
        func ok(_ o: [String: JSONValue]) -> JSONValue { .object(["structuredContent": .object(o)]) }
        switch name {
        case "git_status":
            return ok(["root": .string(optionalString(arguments, "root") ?? ""), "branch": .string("main"),
                       "detached": .string(""), "upstream": .string(""), "ahead": .integer(0),
                       "behind": .integer(0), "files": .array([])])
        case "git_commit":
            if gated { await withCheckedContinuation { c in Task { await self.park(c) } } }
            if let failCommit {
                return .object(["isError": .bool(true), "content": .array([.object(["type": .string("text"), "text": .string(failCommit)])])])
            }
            return ok(["commit": .string("abc1234"), "summary": .string("fix")])
        case "git_amend": return ok(["commit": .string("def"), "summary": .string("amended")])
        case "git_undo_commit": return ok(["message": .string(undoMessage)])
        case "git_identity":
            return ok(["name": .string(identity.name), "email": .string(identity.email), "from": .string(identity.from)])
        default: return ok([:])
        }
    }
}

@MainActor
private func changesWindow(failCommit: String? = nil, undoMessage: String? = nil)
    async -> (WindowModel, ChangesGit)
{
    let git = ChangesGit()
    await git.configure(failCommit: failCommit, undoMessage: undoMessage)
    let status = GitStatus(git: git, roots: { ["/p"] })
    let window = WindowModel.forTesting(scratchRoot: testScratchRoot, gitStatus: status)
    await registerEditorChangesWrites(
        into: window.registryForTesting, gitStatus: status, panes: PaneStore(kinds: PaneKinds.standard), layout: LayoutStore(),
        writes: GitWriteFlights())
    return (window, git)
}

@Suite @MainActor struct WindowModelChangesWritesTests {
    @Test func aCommitClearsTheDraftAndRemembersTheMessage() async {
        let (window, git) = await changesWindow()
        window.changesMessageEdited(root: "/p", text: "fix")
        await window.changesCommit(root: "/p")
        #expect(window.changesMessages["/p", default: ""] == "")
        #expect(window.changesHistory["/p"] == ["fix"])
        #expect(await git.lastCall?.name == "git_commit")
        #expect(!window.changesInFlight.contains("/p"))
    }

    @Test func aWhitespaceMessageCommitsNothing() async {
        let (window, git) = await changesWindow()
        window.changesMessageEdited(root: "/p", text: "  \n")
        await window.changesCommit(root: "/p")
        #expect(await git.lastCall == nil)
    }

    @Test func aFailedCommitKeepsTheDraftAndShowsTheErrorWhole() async {
        let (window, _) = await changesWindow(failCommit: "git commit failed (exit 1):\nlint: 3 problems")
        window.changesMessageEdited(root: "/p", text: "fix")
        await window.changesCommit(root: "/p")
        #expect(window.changesMessages["/p"] == "fix")
        #expect(window.changesErrors["/p"]?.contains("lint: 3 problems") == true)
        #expect(window.changesErrors["/p"]?.hasPrefix("editor_changes_commit:") == true)
        #expect(window.changesHistory["/p"] == nil)
        #expect(!window.changesInFlight.contains("/p"))
    }

    @Test func undoPutsTheMessageBackInTheBox() async {
        let (window, _) = await changesWindow(undoMessage: "undo me")
        await window.changesUndoCommit(root: "/p")
        #expect(window.changesMessages["/p"] == "undo me")
    }

    @Test func upAndDownStepThroughHistoryAndTypingLeavesIt() async {
        let (window, _) = await changesWindow()
        for m in ["one", "two"] { window.changesMessageEdited(root: "/p", text: m); await window.changesCommit(root: "/p") }
        window.changesHistoryStep(root: "/p", by: -1)
        #expect(window.changesMessages["/p"] == "two")
        window.changesHistoryStep(root: "/p", by: -1)
        #expect(window.changesMessages["/p"] == "one")
        window.changesHistoryStep(root: "/p", by: 1)
        #expect(window.changesMessages["/p"] == "two")
        window.changesMessageEdited(root: "/p", text: "two!")
        window.changesHistoryStep(root: "/p", by: -1)      // a typed box is not history: ↑ does nothing
        #expect(window.changesMessages["/p"] == "two!")
    }

    @Test func historyKeepsTheLastTwenty() async {
        let (window, _) = await changesWindow()
        for i in 0..<25 {
            window.changesMessageEdited(root: "/p", text: "m\(i)")
            await window.changesCommit(root: "/p")
        }
        let h = window.changesHistory["/p"] ?? []
        #expect(h.count == 20)
        #expect(h.first == "m24")
        #expect(h.last == "m5")
    }

    @Test func theHintNamesWhoWillCommit() async {
        let (window, git) = await changesWindow()
        #expect(window.changesHint(root: "/p") == nil)
        await window.refreshChangesIdentity(root: "/p")
        #expect(window.changesHint(root: "/p") == "committing as o@x")
        await git.set(identity: ("", "me@y", "git config"))
        await window.refreshChangesIdentity(root: "/p")
        #expect(window.changesHint(root: "/p") == "committing as me@y (from git config)")
    }

    @Test func savingTheGitIdentityReadsTheHintAgain() async {
        let (window, git) = await changesWindow()
        await window.refreshChangesIdentity(root: "/p")
        await window.registryForTesting.register(Action(
            name: "ctx_update_org", description: "stub", kind: .control, audience: .agentReachable,
            schema: .object(["type": .string("object")]), handler: { _ in .object([:]) }))
        await git.set(identity: ("N", "n@z", "organisation"))
        _ = await window.saveOrganisationField(.gitEmail, to: "n@z", organisation: "test-org")
        #expect(window.changesHint(root: "/p") == "committing as n@z")
    }

    @Test func aCommitThatLandsAfterAnOrgSwitchIsNotShown() async throws {
        let (window, git) = await changesWindow(failCommit: "boom")
        await git.gateCommits()
        window.changesMessageEdited(root: "/p", text: "fix")
        let commit = Task { await window.changesCommit(root: "/p") }
        while await !git.parkedNow() { try await Task.sleep(for: .milliseconds(1)) }
        #expect(window.changesInFlight.contains("/p"))
        await window.invalidateForOrgChange()
        #expect(window.changesInFlight.isEmpty)
        await git.release()
        await commit.value
        #expect(window.changesErrors["/p"] == nil)
        #expect(window.changesHistory["/p"] == nil)
        #expect(window.changesMessages["/p"] == nil)
    }

    @Test func aSuccessfulCommitThatLandsAfterAnOrgSwitchLeavesTheNewOrgsHistoryEmpty() async throws {
        let (window, git) = await changesWindow()
        await git.gateCommits()
        window.changesMessageEdited(root: "/p", text: "fix")
        let commit = Task { await window.changesCommit(root: "/p") }
        while await !git.parkedNow() { try await Task.sleep(for: .milliseconds(1)) }
        await window.invalidateForOrgChange()
        await git.release()
        await commit.value
        #expect(window.changesHistory["/p"] == nil)
    }
}
