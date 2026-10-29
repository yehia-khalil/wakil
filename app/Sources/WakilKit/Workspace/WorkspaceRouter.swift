import Foundation

/// What the router needs to know of a conversation: the window answers it (`WorkspaceRouterHooks`).
public struct WorkspaceConversationFacts: Sendable, Equatable {
    public let id: String
    public let lineageRoot: String?
    public let title: String
    /// The ticket it works on (a hand-off's key), if any.
    public let ticket: String?
    public let organization: String
    /// The project's registry key.
    public let project: String
    public let environment: String
    /// Main's folders of its project: the roots it reads and the repos a write can be in.
    public let mainRoots: [String]
    /// Its first message, for the branch name's draft.
    public let firstMessage: String?

    public init(id: String, lineageRoot: String?, title: String, ticket: String? = nil, organization: String,
                project: String, environment: String, mainRoots: [String], firstMessage: String? = nil) {
        self.id = id
        self.lineageRoot = lineageRoot
        self.title = title
        self.ticket = ticket
        self.organization = organization
        self.project = project
        self.environment = environment
        self.mainRoots = mainRoots
        self.firstMessage = firstMessage
    }
}

/// What a branch name is drafted from (decision 10): the ticket's key and title or the
/// conversation's first message, and the repo it is first made in.
public struct BranchNameRequest: Sendable, Equatable {
    public let key: String?
    public let title: String
    public let firstMessage: String?
    public let repo: String
    public let organization: String
    public let project: String
}

/// The window's side of the write rule, installed once there is a window.
public struct WorkspaceRouterHooks: Sendable {
    public var conversation: @Sendable (String) async -> WorkspaceConversationFacts?
    public var states: @Sendable () async -> [String: ConversationState]
    public var say: @Sendable (_ conversation: String, _ line: WorkspaceLine) async -> Void
    /// A conversation moved into a workspace: from Main (`from` nil, step 0) or a branch-off.
    public var moved: @Sendable (_ conversation: String, _ from: Workspace?, _ to: Workspace) async -> Void
    /// A drafted branch name (the ✨ quick task); nil falls back to `fallbackBranchName`.
    public var branchName: @Sendable (BranchNameRequest) async -> String?

    public init(
        conversation: @escaping @Sendable (String) async -> WorkspaceConversationFacts?,
        states: @escaping @Sendable () async -> [String: ConversationState],
        say: @escaping @Sendable (String, WorkspaceLine) async -> Void = { _, _ in },
        moved: @escaping @Sendable (String, Workspace?, Workspace) async -> Void = { _, _, _ in },
        branchName: @escaping @Sendable (BranchNameRequest) async -> String? = { _ in nil }
    ) {
        self.conversation = conversation
        self.states = states
        self.say = say
        self.moved = moved
        self.branchName = branchName
    }
}

/// Carries out the write rule (`decideWrite`) for an agent's writes: makes, takes over and branches
/// off checkouts through wakil-git, moves the conversation into a workspace, and tells its thread.
/// One write at a time, so a check and its take are one step (spec, Errors and edges).
public actor WorkspaceRouter: WorkspaceWriteRouting {
    public let store: WorkspaceStore
    private var git: (any ToolCaller)?
    var hooks: WorkspaceRouterHooks?
    private var running = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    /// Whether a checkout's folder is on disk; overridable for tests.
    var folderExists: @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    func setFolderExists(_ f: @escaping @Sendable (String) -> Bool) { folderExists = f }
    /// Overridable clock and ids, for tests.
    var newId: @Sendable () -> String = { UUID().uuidString.lowercased() }

    public init(store: WorkspaceStore, git: (any ToolCaller)? = nil) {
        self.store = store
        self.git = git
    }

    public func use(git: (any ToolCaller)?) { self.git = git }
    func setIds(_ f: @escaping @Sendable () -> String) { newId = f }
    public func install(_ hooks: WorkspaceRouterHooks) { self.hooks = hooks }

    // MARK: the seam

    /// The conversation an agent's dispatch is from; nil for the operator's (call 12).
    private func agentConversation() -> String? {
        guard ActionRegistry.dispatchOrigin == .agent,
              let c = ActionRegistry.dispatchCaller?.conversation, !c.isEmpty
        else { return nil }
        return c
    }

    public func routeRoot(_ root: String, action: String) async throws -> String {
        guard let c = agentConversation(), let facts = await hooks?.conversation(c) else { return root }
        await store.ensure(org: facts.organization)
        return try await serially {
            guard let repo = try await self.repo(of: root, conversation: c, facts: facts, action: action) else { return root }
            return try await self.checkout(repo.repo, conversation: c, facts: facts, action: action)
        }
    }

    public func routePath(_ path: String, action: String) async throws -> String {
        guard let c = agentConversation(), let facts = await hooks?.conversation(c) else { return path }
        await store.ensure(org: facts.organization)
        return try await serially {
            guard let repo = try await self.repo(of: path, conversation: c, facts: facts, action: action) else { return path }
            let dest = try await self.checkout(repo.repo, conversation: c, facts: facts, action: action)
            return repo.rel.isEmpty ? dest : dest + "/" + repo.rel
        }
    }

    public func routeSwitch(root: String, branch: String, action: String) async throws -> RoutedSwitch {
        guard let c = agentConversation(), let facts = await hooks?.conversation(c) else {
            return RoutedSwitch(root: root, branch: branch)
        }
        await store.ensure(org: facts.organization)
        return try await serially {
            guard let repo = try await self.repo(of: root, conversation: c, facts: facts, action: action) else {
                return RoutedSwitch(root: root, branch: branch)
            }
            let path = try await self.checkout(repo.repo, conversation: c, facts: facts, action: action)
            return try await self.switchIn(path, repo: repo.repo, to: branch, conversation: c, facts: facts, action: action)
        }
    }

    /// Every made checkout of the caller's own workspace (an agent's), else nothing: the roots
    /// beside Main's that its file and git actions may reach (call 13).
    public func callerCheckoutRoots() async -> [String] { await callerCheckouts() ?? [] }

    public func callerCheckouts() async -> [String]? {
        guard let c = agentConversation(), let facts = await hooks?.conversation(c) else { return nil }
        return await store.workspace(ofConversation: c, root: facts.lineageRoot)?.checkouts.compactMap(\.path) ?? []
    }

    // MARK: one write at a time

    func serially<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        while running {
            await withCheckedContinuation { waiting.append($0) }
        }
        running = true
        defer {
            running = false
            if !waiting.isEmpty { waiting.removeFirst().resume() }
        }
        return try await body()
    }

    // MARK: where a write is

    /// The repo (Main's folder) `path` is in and the path below it; nil for a path outside every
    /// root, which the action's own confinement refuses. A path in another workspace's checkout is
    /// refused here, naming it.
    private func repo(of path: String, conversation c: String, facts: WorkspaceConversationFacts,
                      action: String) async throws -> (repo: String, rel: String)? {
        let all = await store.all()
        let mine = await store.workspace(ofConversation: c, root: facts.lineageRoot)
        if let refusal = confinementRefusal(path, workspace: mine, all: all.filter { !$0.archived }, action: action) {
            throw WorkspaceWriteError(description: refusal)
        }
        let clean = (path as NSString).standardizingPath
        if let mine {
            for co in mine.checkouts {
                guard let p = co.path else { continue }
                let root = (p as NSString).standardizingPath
                if clean == root { return (co.repo, "") }
                if clean.hasPrefix(root + "/") { return (co.repo, String(clean.dropFirst(root.count + 1))) }
            }
        }
        let holding = facts.mainRoots.filter {
            let r = ($0 as NSString).standardizingPath
            return clean == r || clean.hasPrefix(r + "/")
        }
        guard let root = holding.max(by: { $0.count < $1.count }) else { return nil }
        let r = (root as NSString).standardizingPath
        return (root, clean == r ? "" : String(clean.dropFirst(r.count + 1)))
    }

    // MARK: the rule, carried out

    /// The path of `c`'s checkout of `repo`, after the write rule ran.
    private func checkout(_ repo: String, conversation c: String, facts: WorkspaceConversationFacts,
                          action: String) async throws -> String {
        let mine = await store.workspace(ofConversation: c, root: facts.lineageRoot)
        // A resumed conversation found by its lineage root goes back into its workspace, and its
        // view follows (no canvas carried: the workspace's own is read).
        let member = await store.isMember(c)
        if let mine, !member {
            await store.move(c, root: facts.lineageRoot, to: mine.id)
            await hooks?.moved(c, mine, mine)
        }
        // A checkout deleted outside Wakil: git forgets it, and it is re-made below on its branch.
        if let mine, let gone = mine.checkout(of: repo)?.path, !folderExists(gone) {
            _ = try? await call("git_worktree_prune", ["root": .string(repo)])
            await store.update(mine.id) { w in
                if let i = w.checkouts.firstIndex(where: { $0.repo == repo }) { w.checkouts[i].path = nil }
            }
            try? await store.save()
            return try await checkout(repo, conversation: c, facts: facts, action: action)
        }
        var mainBranch: String?
        if mine != nil, mine?.checkout(of: repo)?.path == nil {
            mainBranch = await mainState(repo)?.branch
        }
        let input = WriteRuleInput(
            conversation: c, workspace: mine, repo: repo, holders: await store.holders(),
            states: await hooks?.states() ?? [:], mainBranch: mainBranch)
        switch decideWrite(input) {
        case .startWorkspace:
            return try await startWorkspace(repo, conversation: c, facts: facts)
        case .use(let r):
            let w = mine!
            await store.hold(WorkspaceHold(workspace: w.id, repo: r), by: c, root: facts.lineageRoot)
            try? await store.save()
            return w.checkout(of: r)!.path!
        case .takeOver(let r, let from):
            let w = mine!
            await store.hold(WorkspaceHold(workspace: w.id, repo: r), by: c, root: facts.lineageRoot)
            try? await store.save()
            let name = await hooks?.conversation(from)?.title ?? "an earlier conversation"
            await hooks?.say(c, .tookOver(repo: repoName(r), from: name))
            return w.checkout(of: r)!.path!
        case .branchOff(let from, let tip):
            return try await branchOff(mine!, repo: repo, tip: tip, holder: from, conversation: c, facts: facts)
        case .make(let start):
            return try await make(mine!, repo: repo, start: start, conversation: c, facts: facts)
        case .switchTakesOver, .switchBranchesOff:
            // Only a switch asks the rule with a target; `switchIn` handles it.
            return mine!.checkout(of: repo)!.path!
        }
    }

    /// Step 0: a workspace for a conversation in Main, its first checkout from the commit Main's
    /// folder is on (call 4; a detached HEAD is that commit). Main's uncommitted changes are not
    /// carried, and the thread says how many there were.
    private func startWorkspace(_ repo: String, conversation c: String, facts: WorkspaceConversationFacts) async throws -> String {
        let all = await store.all()
        let name = facts.title.isEmpty || facts.title == newConversationTitle
            ? (facts.firstMessage.map(conversationTitle) ?? "Work") : facts.title
        let drafted = await hooks?.branchName(BranchNameRequest(
            key: facts.ticket, title: name, firstMessage: facts.firstMessage, repo: repo,
            organization: facts.organization, project: facts.project))
        let branch = drafted.flatMap { NormalisedBranch($0) } ?? fallbackBranchName(key: facts.ticket, title: name)
        let slug = uniqueSlug(branchSlug(branch), taken: Set(all.filter { $0.project == facts.project }.map(\.slug)))
        var w = Workspace(
            id: newId(), name: name, slug: slug, project: facts.project, environment: facts.environment,
            tickets: facts.ticket.map { [$0] } ?? [], branch: branch,
            created: ISO8601DateFormatter().string(from: Date()))
        let main = await mainState(repo)
        let made: JSONValue
        do {
            made = try await call("git_worktree_add", [
                "root": .string(repo), "project": .string(facts.project), "slug": .string(slug),
                "branch": .string(branch), "create": .bool(true), "from": .string("HEAD"),
            ])
        } catch {
            await hooks?.say(c, .addFailed(repo: repoName(repo), message: "\(error)"))
            throw WorkspaceWriteError(description: WorkspaceLine.addFailed(repo: repoName(repo), message: "\(error)").text)
        }
        let path = string(made, "path") ?? ""
        w.checkouts = [WorkspaceCheckout(repo: repo, path: path, branch: branch, base: main?.branch)]
        await store.add(w)
        await store.move(c, root: facts.lineageRoot, to: w.id)
        await store.hold(WorkspaceHold(workspace: w.id, repo: repo), by: c, root: facts.lineageRoot)
        w = await store.workspace(w.id) ?? w
        try? await store.save()
        await hooks?.say(c, .started(name: name, repo: repoName(repo), branch: branch, uncommitted: main?.uncommitted ?? 0))
        await hooks?.moved(c, nil, w)
        return path
    }

    /// Step 1, a working holder: a child workspace (decision 9) on a new branch off the tip.
    private func branchOff(_ parent: Workspace, repo: String, tip: String, holder: String, conversation c: String,
                           facts: WorkspaceConversationFacts) async throws -> String {
        let all = await store.all()
        let taken = Set(all.flatMap { $0.checkouts.map(\.branch) } + all.compactMap(\.branch))
        let branch = childBranchName(tip, conversation: c, taken: taken)
        let slug = uniqueSlug(branchSlug(branch), taken: Set(all.filter { $0.project == parent.project }.map(\.slug)))
        let name = facts.title.isEmpty || facts.title == newConversationTitle ? "\(parent.name) (branch)" : facts.title
        var child = Workspace(
            id: newId(), name: name, slug: slug, project: parent.project, environment: parent.environment,
            tickets: parent.tickets, parent: parent.id, branch: branch,
            created: ISO8601DateFormatter().string(from: Date()))
        let made: JSONValue
        do {
            made = try await call("git_worktree_add", [
                "root": .string(repo), "project": .string(parent.project), "slug": .string(slug),
                "branch": .string(branch), "create": .bool(true), "from": .string(tip),
            ])
        } catch {
            await hooks?.say(c, .addFailed(repo: repoName(repo), message: "\(error)"))
            throw WorkspaceWriteError(description: WorkspaceLine.addFailed(repo: repoName(repo), message: "\(error)").text)
        }
        child.checkouts = [WorkspaceCheckout(repo: repo, path: string(made, "path"), branch: branch, base: tip)]
        await store.add(child)
        await store.move(c, root: facts.lineageRoot, to: child.id)
        await store.hold(WorkspaceHold(workspace: child.id, repo: repo), by: c, root: facts.lineageRoot)
        child = await store.workspace(child.id) ?? child
        try? await store.save()
        let holderName = await hooks?.conversation(holder)?.title ?? "another conversation"
        await hooks?.say(c, .branchedOff(name: name, repo: repoName(repo), branch: branch, holder: holderName))
        await hooks?.moved(c, parent, child)
        return child.checkout(of: repo)?.path ?? ""
    }

    /// Step 2: a checkout of `repo` made in `w`.
    private func make(_ w: Workspace, repo: String, start: CheckoutStart, conversation c: String,
                      facts: WorkspaceConversationFacts) async throws -> String {
        let recorded = w.checkout(of: repo)
        let branch = recorded?.branch ?? w.branch ?? fallbackBranchName(key: w.tickets.first, title: w.name)
        var path: String?
        var base = recorded?.base
        var line: WorkspaceLine?
        do {
            switch start {
            case .takeFromMain:
                var args: [String: JSONValue] = [
                    "root": .string(repo), "project": .string(w.project), "slug": .string(w.slug), "branch": .string(branch),
                ]
                if let base { args["base"] = .string(base) }
                let r = try await call("git_take_from_main", args)
                path = string(r, "path")
                let now = await mainState(repo)?.branch ?? base ?? "its base"
                base = base ?? now
                line = .tookFromMain(repo: repoName(repo), branch: branch, base: now, carried: flag(r, "carried"))
            case .existingBranch:
                let r = try await call("git_worktree_add", [
                    "root": .string(repo), "project": .string(w.project), "slug": .string(w.slug), "branch": .string(branch),
                    "create": .bool(true), "fromIsBase": .bool(true),
                ])
                path = string(r, "path")
                if let snap = recorded?.snapshot, let path {
                    _ = try await call("git_snapshot_apply", ["root": .string(path), "ref": .string(snap)])
                }
            case .base:
                let r = try await call("git_worktree_add", [
                    "root": .string(repo), "project": .string(w.project), "slug": .string(w.slug), "branch": .string(branch),
                    "create": .bool(true), "fromIsBase": .bool(true),
                ])
                path = string(r, "path")
                if let note = string(r, "note"), !note.isEmpty { line = .madeCheckout(repo: repoName(repo), branch: branch, note: note) }
            }
        } catch {
            await hooks?.say(c, .addFailed(repo: repoName(repo), message: "\(error)"))
            throw WorkspaceWriteError(description: WorkspaceLine.addFailed(repo: repoName(repo), message: "\(error)").text)
        }
        let made = WorkspaceCheckout(repo: repo, path: path, branch: branch, base: base, ports: recorded?.ports,
                                     lastHolder: recorded?.lastHolder)
        await store.update(w.id) { ws in
            if ws.branch == nil { ws.branch = branch }
            if let i = ws.checkouts.firstIndex(where: { $0.repo == repo }) { ws.checkouts[i] = made } else { ws.checkouts.append(made) }
        }
        await store.hold(WorkspaceHold(workspace: w.id, repo: repo), by: c, root: facts.lineageRoot)
        try? await store.save()
        if let line { await hooks?.say(c, line) }
        return path ?? ""
    }

    /// A switch in `c`'s checkout at `path` to `branch`, which another folder may hold.
    private func switchIn(_ path: String, repo: String, to branch: String, conversation c: String,
                          facts: WorkspaceConversationFacts, action: String) async throws -> RoutedSwitch {
        let all = await store.all()
        let holds = await store.holders()
        var held: HeldBranch?
        for w in all where !w.archived {
            for co in w.checkouts where co.repo == repo && co.branch == branch {
                guard let p = co.path, p != path else { continue }
                held = HeldBranch(workspace: w.id, repo: repo, path: p, holder: holds[WorkspaceHold(workspace: w.id, repo: repo)])
            }
        }
        if held == nil, await mainState(repo)?.branch == branch {
            held = HeldBranch(workspace: nil, repo: repo, path: repo, holder: nil)
        }
        let mine = await store.workspace(ofConversation: c, root: facts.lineageRoot)
        let input = WriteRuleInput(conversation: c, workspace: mine, repo: repo, holders: holds,
                                   states: await hooks?.states() ?? [:], switchTo: branch, switchHeld: held)
        switch decideWrite(input) {
        case .switchTakesOver(let h):
            _ = try await call("git_release_branch", ["root": .string(h.path)])
            if let other = h.workspace {
                await store.update(other) { w in
                    if let i = w.checkouts.firstIndex(where: { $0.repo == repo }) { w.checkouts[i].branch = "" }
                }
            }
            await recordBranch(of: mine, repo: repo, branch)
            return RoutedSwitch(root: path, branch: branch)
        case .switchBranchesOff(let h):
            let taken = Set(all.flatMap { $0.checkouts.map(\.branch) })
            let fresh = childBranchName(branch, conversation: c, taken: taken)
            var holder = "another conversation"
            if let id = h.holder, let title = await hooks?.conversation(id)?.title { holder = title }
            await hooks?.say(c, .switchBranchedOff(branch: branch, holder: holder, fresh: fresh))
            await recordBranch(of: mine, repo: repo, fresh)
            return RoutedSwitch(root: path, branch: fresh, create: true, from: branch)
        default:
            await recordBranch(of: mine, repo: repo, branch)
            return RoutedSwitch(root: path, branch: branch)
        }
    }

    private func recordBranch(of w: Workspace?, repo: String, _ branch: String) async {
        guard let w else { return }
        await store.update(w.id) { ws in
            if let i = ws.checkouts.firstIndex(where: { $0.repo == repo }) { ws.checkouts[i].branch = branch }
        }
        try? await store.save()
    }

    // MARK: git

    func call(_ tool: String, _ args: [String: JSONValue]) async throws -> JSONValue {
        guard let git else { throw WorkspaceWriteError(description: "\(tool): wakil-git is not running") }
        let r = try await callCheckedTool(git, tool: tool, arguments: .object(args), action: tool,
                                          timeout: MCPClient.mutationReplyTimeout)
        if case .object(let o) = r, let s = o["structuredContent"] { return s }
        return r
    }

    /// Main's folder of `repo`: its branch (nil when detached) and how many files it has changes in.
    func mainState(_ repo: String) async -> (branch: String?, uncommitted: Int)? {
        guard let git,
              let r = try? await callCheckedTool(git, tool: "git_status", arguments: .object(["root": .string(repo)]),
                                                 action: "git_status", timeout: MCPClient.readReplyTimeout)
        else { return nil }
        var value = r
        if case .object(let o) = r, let s = o["structuredContent"] { value = s }
        guard case .object(let o) = value else { return nil }
        let branch = o["branch"].flatMap { if case .string(let s) = $0, !s.isEmpty { s } else { nil } }
        var paths = Set<String>()
        if case .array(let files)? = o["files"] {
            for f in files { if case .object(let fo) = f, case .string(let p)? = fo["path"] { paths.insert(p) } }
        }
        return (branch, paths.count)
    }

    nonisolated func string(_ v: JSONValue, _ key: String) -> String? {
        if case .object(let o) = v, case .string(let s)? = o[key] { return s }
        return nil
    }

    nonisolated private func flag(_ v: JSONValue, _ key: String) -> Bool {
        if case .object(let o) = v, case .bool(let b)? = o[key] { return b }
        return false
    }

    nonisolated func repoName(_ repo: String) -> String { (repo as NSString).lastPathComponent }
}

/// A drafted branch name made safe to hand git: spaces to "-", nothing that starts a flag; nil
/// when nothing is left.
func NormalisedBranch(_ raw: String) -> String? {
    let name = raw.split(whereSeparator: \.isWhitespace).joined(separator: "-")
        .trimmingCharacters(in: CharacterSet(charactersIn: "-/."))
    guard !name.isEmpty, !name.hasPrefix("-"), !name.contains(".."), !name.contains("~"), !name.contains("^"),
          !name.contains(":"), !name.contains("\\"), !name.contains("?"), !name.contains("*"), !name.contains("[")
    else { return nil }
    return name
}
