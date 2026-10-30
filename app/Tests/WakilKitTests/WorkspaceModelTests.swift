import Foundation
import Testing
@testable import WakilKit

// Workspaces, piece 1: the record as Go writes it, the write rule, path translation and names.

private func checkout(_ repo: String, _ path: String? = nil, branch: String = "fix-otp") -> WorkspaceCheckout {
    WorkspaceCheckout(repo: repo, path: path, branch: branch)
}

private func workspace(
    _ id: String, checkouts: [WorkspaceCheckout] = [], branch: String = "fix-otp", parent: String? = nil,
    tickets: [String] = []
) -> Workspace {
    Workspace(id: id, name: "Fix OTP guard order", slug: id, project: "estate", environment: "staging",
              tickets: tickets, parent: parent, branch: branch, checkouts: checkouts)
}

// MARK: the record

@Test func theRecordReadsGosJSON() throws {
    let json = """
    {"workspaces":[{"id":"w1","name":"Fix OTP","slug":"fix-otp","project":"estate","environment":"staging",
    "tickets":["INI-142"],"branch":"fix-otp","checkouts":[{"repo":"/p/core","path":"/h/core","branch":"fix-otp",
    "base":"main","ports":{"first":41200,"count":10},"lastHolder":"r1"}],"conversations":["r1"],"view":"w1"}]}
    """
    let file = try JSONDecoder().decode(WorkspacesFile.self, from: Data(json.utf8))
    let w = try #require(file.workspaces.first)
    #expect(w.tickets == ["INI-142"])
    #expect(w.checkouts.first?.ports == PortBlock(first: 41200, count: 10))
    #expect(w.checkouts.first?.lastHolder == "r1")
    #expect(!w.archived)
    let again = try JSONDecoder().decode(WorkspacesFile.self, from: try JSONEncoder().encode(file))
    #expect(again == file)
}

@Test func aSparseRecordStillReads() throws {
    let file = try JSONDecoder().decode(WorkspacesFile.self, from: Data(#"{"workspaces":[{"id":"w","slug":"w","project":"p"}]}"#.utf8))
    #expect(file.workspaces.first?.checkouts == [])
    #expect(file.workspaces.first?.environment == "")
}

// MARK: the write rule

@Test func step0AConversationInMainStartsAWorkspaceFromMainsCommit() {
    let d = decideWrite(WriteRuleInput(conversation: "c", workspace: nil, repo: "/p/core", holders: [:], states: [:]))
    #expect(d == .startWorkspace)
}

@Test func step1AFreeCheckoutIsTaken() {
    let w = workspace("w", checkouts: [checkout("/p/core", "/h/core")])
    let d = decideWrite(WriteRuleInput(conversation: "c", workspace: w, repo: "/p/core", holders: [:], states: [:]))
    #expect(d == .use(checkoutOf: "/p/core"))
}

@Test func step1ACheckoutItHoldsIsItsOwn() {
    let w = workspace("w", checkouts: [checkout("/p/core", "/h/core")])
    let d = decideWrite(WriteRuleInput(conversation: "c", workspace: w, repo: "/p/core",
                                       holders: [WorkspaceHold(workspace: "w", repo: "/p/core"): "c"], states: ["c": .working]))
    #expect(d == .use(checkoutOf: "/p/core"))
}

@Test func step1AnIdleHoldersCheckoutIsTakenOver() {
    let w = workspace("w", checkouts: [checkout("/p/core", "/h/core")])
    for state in [ConversationState.idle, .done, .failed] {
        let d = decideWrite(WriteRuleInput(conversation: "c", workspace: w, repo: "/p/core",
                                           holders: [WorkspaceHold(workspace: "w", repo: "/p/core"): "b"], states: ["b": state]))
        #expect(d == .takeOver(checkoutOf: "/p/core", from: "b"))
    }
}

@Test func step1AWorkingHolderMakesItBranchOff() {
    let w = workspace("w", checkouts: [checkout("/p/core", "/h/core", branch: "fix-otp")])
    for state in [ConversationState.working, .waiting] {
        let d = decideWrite(WriteRuleInput(conversation: "c", workspace: w, repo: "/p/core",
                                           holders: [WorkspaceHold(workspace: "w", repo: "/p/core"): "b"], states: ["b": state]))
        #expect(d == .branchOff(from: "b", tip: "fix-otp"))
    }
}

@Test func aHolderThatIsNoLongerLiveCountsAsIdle() {
    let w = workspace("w", checkouts: [checkout("/p/core", "/h/core")])
    let d = decideWrite(WriteRuleInput(conversation: "c", workspace: w, repo: "/p/core",
                                       holders: [WorkspaceHold(workspace: "w", repo: "/p/core"): "gone"], states: [:]))
    #expect(d == .takeOver(checkoutOf: "/p/core", from: "gone"))
}

@Test func step2NoCheckoutMakesOneFromTheBase() {
    let w = workspace("w", checkouts: [checkout("/p/web", "/h/web")])
    let d = decideWrite(WriteRuleInput(conversation: "c", workspace: w, repo: "/p/core", holders: [:], states: [:],
                                       mainBranch: "main"))
    #expect(d == .make(.base))
}

@Test func step2ARecordedCheckoutWithNoFolderIsRemadeOnItsBranch() {
    var co = checkout("/p/core", nil)
    co.snapshot = "refs/wakil/snapshots/w/core"
    let d = decideWrite(WriteRuleInput(conversation: "c", workspace: workspace("w", checkouts: [co]), repo: "/p/core",
                                       holders: [:], states: [:]))
    #expect(d == .make(.existingBranch))
}

@Test func step2TheWorkspacesBranchCheckedOutInMainIsTakenFromMain() {
    let w = workspace("w", branch: "INI-142-login", tickets: ["INI-142"])
    let d = decideWrite(WriteRuleInput(conversation: "c", workspace: w, repo: "/p/core", holders: [:], states: [:],
                                       mainBranch: "INI-142-login"))
    #expect(d == .make(.takeFromMain))
}

@Test func aRepoBroughtToMainIsTakenBackAtTheNextChange() {
    var co = checkout("/p/core", nil, branch: "fix-otp")
    co.inMain = true
    let d = decideWrite(WriteRuleInput(conversation: "c", workspace: workspace("w", checkouts: [co]), repo: "/p/core",
                                       holders: [:], states: [:], mainBranch: "fix-otp"))
    #expect(d == .make(.takeFromMain))
}

@Test func aBranchSwitchToABranchHeldByAnIdleCheckoutTakesItOver() {
    let w = workspace("w", checkouts: [checkout("/p/core", "/h/core")])
    let held = HeldBranch(workspace: "w2", repo: "/p/core", path: "/h2/core", holder: "b")
    let d = decideWrite(WriteRuleInput(conversation: "c", workspace: w, repo: "/p/core", holders: [:], states: ["b": .idle],
                                       switchTo: "feature", switchHeld: held))
    #expect(d == .switchTakesOver(held))
}

@Test func aBranchSwitchToABranchAWorkingConversationHoldsBranchesOff() {
    let w = workspace("w", checkouts: [checkout("/p/core", "/h/core")])
    let held = HeldBranch(workspace: "w2", repo: "/p/core", path: "/h2/core", holder: "b")
    let d = decideWrite(WriteRuleInput(conversation: "c", workspace: w, repo: "/p/core", holders: [:], states: ["b": .working],
                                       switchTo: "feature", switchHeld: held))
    #expect(d == .switchBranchesOff(held))
}

@Test func aBranchSwitchToABranchMainHoldsTakesItFromMain() {
    let w = workspace("w", checkouts: [checkout("/p/core", "/h/core")])
    let held = HeldBranch(workspace: nil, repo: "/p/core", path: "/p/core", holder: nil)
    let d = decideWrite(WriteRuleInput(conversation: "c", workspace: w, repo: "/p/core", holders: [:], states: [:],
                                       switchTo: "feature", switchHeld: held))
    #expect(d == .switchTakesOver(held))
}

// MARK: paths

@Test func aPathInMainsFolderTranslatesToTheCheckoutAndBack() {
    let w = workspace("w", checkouts: [checkout("/p/core", "/h/ws/fix/core")])
    #expect(workspacePath("/p/core/src/a.go", in: w) == "/h/ws/fix/core/src/a.go")
    #expect(workspacePath("/p/core", in: w) == "/h/ws/fix/core")
    #expect(workspacePath("/p/core-extra/a", in: w) == nil)
    #expect(workspacePath("/p/web/a", in: w) == nil)
    #expect(mainPath("/h/ws/fix/core/src/a.go", in: w) == "/p/core/src/a.go")
    #expect(mainPath("/p/core/src/a.go", in: w) == nil)
}

@Test func aPathInAnotherWorkspacesCheckoutIsRefusedNamingIt() {
    let mine = workspace("w", checkouts: [checkout("/p/core", "/h/ws/mine/core")])
    var theirs = workspace("t", checkouts: [checkout("/p/core", "/h/ws/theirs/core")])
    theirs.name = "Try a token bucket"
    let all = [mine, theirs]
    #expect(confinementRefusal("/h/ws/theirs/core/a.go", workspace: mine, all: all, action: "editor_save")
        == "editor_save: /h/ws/theirs/core/a.go is in workspace ‘Try a token bucket’; this conversation writes only in its own workspace")
    #expect(confinementRefusal("/h/ws/mine/core/a.go", workspace: mine, all: all, action: "editor_save") == nil)
    #expect(confinementRefusal("/p/core/a.go", workspace: mine, all: all, action: "editor_save") == nil)
    // From Main every checkout is another workspace's.
    #expect(confinementRefusal("/h/ws/mine/core/a.go", workspace: nil, all: all, action: "editor_save") != nil)
}

// MARK: names

@Test func branchNamesFallBackToTheKeyAndASlugOfTheTitle() {
    #expect(branchSlug("Fix OTP guard order!") == "fix-otp-guard-order")
    #expect(branchSlug("  Ünïcode — and/slashes  ") == "unicode-and-slashes")
    #expect(fallbackBranchName(key: "INI-142", title: "Login rate limit") == "INI-142-login-rate-limit")
    #expect(fallbackBranchName(key: nil, title: "Login rate limit") == "login-rate-limit")
    #expect(fallbackBranchName(key: nil, title: "") == "work")
    #expect(branchSlug(String(repeating: "word ", count: 40)).count <= 50)
}

/// A title that already starts with the ticket's key gets the key once (the walk's
/// `AQ247-141-aq247-141-work-toward-next`), in the key's own case, whatever the title's.
@Test func aTitleStartingWithTheTicketsKeyIsNotPrefixedTwice() {
    #expect(fallbackBranchName(key: "AQ247-141", title: "AQ247-141 · Work toward Next.") == "AQ247-141-work-toward-next")
    #expect(fallbackBranchName(key: "INI-142", title: "ini-142: Login rate limit") == "INI-142-login-rate-limit")
    #expect(fallbackBranchName(key: "INI-142", title: "INI-142") == "INI-142")
    #expect(fallbackBranchName(key: "INI-14", title: "INI-142 Login") == "INI-14-ini-142-login")
}

@Test func aChildBranchAddsTwoCharactersOfItsConversationLengthenedUntilUnused() {
    #expect(childBranchName("fix-otp", conversation: "ab12cd", taken: []) == "fix-otp--ab")
    #expect(childBranchName("fix-otp", conversation: "ab12cd", taken: ["fix-otp--ab"]) == "fix-otp--ab1")
    #expect(childBranchName("fix-otp", conversation: "ab12cd", taken: ["fix-otp--ab", "fix-otp--ab1"]) == "fix-otp--ab12")
}

@Test func aWorkspaceSlugIsUniqueInItsProject() {
    #expect(uniqueSlug("fix-otp", taken: []) == "fix-otp")
    #expect(uniqueSlug("fix-otp", taken: ["fix-otp"]) == "fix-otp-2")
    #expect(uniqueSlug("fix-otp", taken: ["fix-otp", "fix-otp-2"]) == "fix-otp-3")
}

// MARK: thread lines

@Test func theThreadSaysWhatTheWriteRuleDid() {
    #expect(WorkspaceLine.started(name: "Fix OTP guard order", repo: "core", branch: "fix-otp-guard-order", uncommitted: 2).text
        == "Started workspace ‘Fix OTP guard order’ — a copy of core on `fix-otp-guard-order`, from the commit your folder is on. Your folder is untouched; your 2 uncommitted changes there are not in the copy.")
    #expect(WorkspaceLine.started(name: "W", repo: "core", branch: "b", uncommitted: 1).text.hasSuffix("your 1 uncommitted change there is not in the copy."))
    #expect(WorkspaceLine.started(name: "W", repo: "core", branch: "b", uncommitted: 0).text.hasSuffix("Your folder is untouched."))
    #expect(WorkspaceLine.tookOver(repo: "api", from: "backend").text == "Took over api from ‘backend’ (idle).")
    #expect(WorkspaceLine.branchedOff(name: "Try a token bucket", repo: "api", branch: "fix--ab", holder: "backend").text
        == "‘backend’ is working in api, so this conversation branched off into workspace ‘Try a token bucket’ on `fix--ab`.")
    #expect(WorkspaceLine.tookFromMain(repo: "core", branch: "INI-142-login", base: "main", carried: true).text
        == "Took `INI-142-login` from your folder of core: your folder is back on `main`, and its uncommitted changes came along into the copy.")
    #expect(WorkspaceLine.addFailed(repo: "core", message: "fatal: a\nline two").text
        == "Could not make a copy of core, so the change was not made:\nfatal: a\nline two")
}

// MARK: the branch draft (decision 10)

@Test func theBranchDraftCarriesTheRulesTheTicketAndTheFirstMessage() {
    let r = BranchNameRequest(key: "INI-142", title: "Login rate limit", firstMessage: "Add a rate limit to login",
                              repo: "/p/core", organization: "initech", project: "estate")
    let req = BranchDraft.request(r, instructions: "<KEY>-<slug>", recent: ["INI-100-old"])
    #expect(req.instructions.contains("Follow these branch naming rules:\n<KEY>-<slug>"))
    #expect(req.instructions.contains("INI-100-old"))
    #expect(req.input.contains("Ticket: INI-142"))
    #expect(req.input.contains("Add a rate limit to login"))
}

@Test func aDraftedBranchIsMadeSafeOrRefused() throws {
    #expect(try BranchDraft.parse(#"{"branch": "INI-142 login rate limit"}"#) == "INI-142-login-rate-limit")
    #expect(try BranchDraft.parse("```json\n{\"branch\": \"fix-otp\"}\n```") == "fix-otp")
    #expect(try BranchDraft.parse(#"{"branch": "--force"}"#) == "force", "never handed to git as a flag")
    #expect(throws: WorkspaceWriteError.self) { try BranchDraft.parse(#"{"branch": "a..b"}"#) }
    #expect(throws: WorkspaceWriteError.self) { try BranchDraft.parse("not json") }
}
