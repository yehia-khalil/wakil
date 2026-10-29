import Foundation

// The write rule (spec, "How a write finds its checkout"), as a pure function: given where a
// conversation is and who holds what, which step applies. `WorkspaceWriter` carries it out.

/// One checkout's hold: the workspace and the repo (Main's folder) it is a checkout of.
public struct WorkspaceHold: Hashable, Sendable {
    public let workspace: String
    public let repo: String
    public init(workspace: String, repo: String) {
        self.workspace = workspace
        self.repo = repo
    }
}

/// A branch a switch asks for that another folder has checked out: a checkout of `workspace`
/// (held by `holder`, nil when free), or Main's folder (`workspace` nil).
public struct HeldBranch: Equatable, Sendable {
    public let workspace: String?
    public let repo: String
    public let path: String
    public let holder: String?
    public init(workspace: String?, repo: String, path: String, holder: String?) {
        self.workspace = workspace
        self.repo = repo
        self.path = path
        self.holder = holder
    }
}

/// What the write needs before it runs.
public struct WriteRuleInput: Sendable {
    /// The writing conversation's id.
    public let conversation: String
    /// Its workspace; nil for Main.
    public let workspace: Workspace?
    /// The repo written in: the project root (Main's folder) the path or root belongs to.
    public let repo: String
    /// Who holds each checkout (conversation ids).
    public let holders: [WorkspaceHold: String]
    /// Each live conversation's state; one not listed is not live, so idle.
    public let states: [String: ConversationState]
    /// The branch Main's folder of `repo` is on (nil when detached or unread).
    public let mainBranch: String?
    /// A branch switch's target, and where else it is checked out (nil when nowhere).
    public let switchTo: String?
    public let switchHeld: HeldBranch?

    public init(conversation: String, workspace: Workspace?, repo: String, holders: [WorkspaceHold: String],
                states: [String: ConversationState], mainBranch: String? = nil, switchTo: String? = nil,
                switchHeld: HeldBranch? = nil) {
        self.conversation = conversation
        self.workspace = workspace
        self.repo = repo
        self.holders = holders
        self.states = states
        self.mainBranch = mainBranch
        self.switchTo = switchTo
        self.switchHeld = switchHeld
    }
}

/// Where a new checkout starts (step 2).
public enum CheckoutStart: Equatable, Sendable {
    /// From the repo's base (a new branch), or the workspace's branch when it exists.
    case base
    /// Its recorded branch, which exists (a checkout re-made after Restore, its snapshot re-applied).
    case existingBranch
    /// The workspace's branch is checked out in Main's folder: taken from Main (decision 8).
    case takeFromMain
}

public enum WriteDecision: Equatable, Sendable {
    /// Step 0: the conversation is in Main; a workspace is made for it (from Main's commit).
    case startWorkspace
    /// Step 1: the checkout is free or the conversation's own.
    case use(checkoutOf: String)
    /// Step 1: its holder is idle; the conversation takes it.
    case takeOver(checkoutOf: String, from: String)
    /// Step 1: its holder is working; a child workspace on a new branch off `tip`.
    case branchOff(from: String, tip: String)
    /// Step 2: the workspace has no checkout of the repo.
    case make(CheckoutStart)
    /// A switch to a branch held by an idle conversation, by none, or by Main's folder: the other
    /// folder lets go of it and the conversation's checkout switches.
    case switchTakesOver(HeldBranch)
    /// A switch to a branch a working conversation holds: a new branch off its tip instead.
    case switchBranchesOff(HeldBranch)
}

/// Idle is idle, done and failed; working and waiting are working (spec). A conversation that is
/// not live holds nothing that can stop a take-over.
public func holderIsWorking(_ state: ConversationState?) -> Bool {
    state == .working || state == .waiting
}

/// The write rule's step for one write.
public func decideWrite(_ input: WriteRuleInput) -> WriteDecision {
    guard let w = input.workspace else { return .startWorkspace }
    if let co = w.checkout(of: input.repo), co.path != nil, !co.inMain {
        let hold = WorkspaceHold(workspace: w.id, repo: input.repo)
        if let target = input.switchTo, target != co.branch, let held = input.switchHeld {
            if let holder = held.holder, holder != input.conversation, holderIsWorking(input.states[holder]) {
                return .switchBranchesOff(held)
            }
            return .switchTakesOver(held)
        }
        guard let holder = input.holders[hold], holder != input.conversation else {
            return .use(checkoutOf: input.repo)
        }
        if holderIsWorking(input.states[holder]) { return .branchOff(from: holder, tip: co.branch) }
        return .takeOver(checkoutOf: input.repo, from: holder)
    }
    if let co = w.checkout(of: input.repo) {
        if co.inMain || (input.mainBranch != nil && input.mainBranch == co.branch) { return .make(.takeFromMain) }
        return .make(.existingBranch)
    }
    if let branch = w.branch, let main = input.mainBranch, main == branch { return .make(.takeFromMain) }
    return .make(.base)
}
