import Foundation

// Workspaces, piece 1: the window's side of the write rule — what it knows of a conversation, its
// state, its thread, and where its view goes when the rule moves it.
extension WindowModel {
    /// Points the write rule at this window (`WakilWiring.useActiveContext(of:)`).
    public func useWorkspaces(_ router: WorkspaceRouter) {
        workspaceRouter = router
        let hooks = WorkspaceRouterHooks(
            conversation: { [weak self] id in await self?.workspaceFacts(id) },
            states: { [weak self] in await self?.conversationStates() ?? [:] },
            say: { [weak self] conversation, line in await self?.sayWorkspace(conversation, line) },
            moved: { [weak self] conversation, from, to in await self?.workspaceMoved(conversation, from: from, to: to) },
            branchName: { [weak self] request in await self?.draftBranchName(request) })
        Task { await router.install(hooks) }
    }

    /// What the write rule needs of conversation `id`; nil when it is not live.
    func workspaceFacts(_ id: String) async -> WorkspaceConversationFacts? {
        guard let agent = conversations[id] else { return nil }
        let roots = agent.place == place ? gitRootPaths : await mainRootPaths(forCaller: agent.caller)
        return WorkspaceConversationFacts(
            id: agent.id, lineageRoot: agent.lineageRoot, title: agent.title, ticket: agent.handoff?.key,
            organization: agent.place.organization, project: agent.place.project,
            environment: agent.place.environment, mainRoots: roots, firstMessage: agent.firstMessage)
    }

    /// Every live conversation's state, for the rule's idle/working test.
    func conversationStates() -> [String: ConversationState] {
        Dictionary(liveConversationRows().map { ($0.id, $0.state) }, uniquingKeysWith: { a, _ in a })
    }

    /// The rule's sentence in the conversation's thread; a failure as an error row, whole (Rule 8).
    func sayWorkspace(_ conversation: String, _ line: WorkspaceLine) {
        guard let agent = conversations[conversation] else { return }
        var failed = false
        if case .addFailed = line { failed = true }
        agent.appendRow(label: "workspace", detail: line.text, isError: failed)
    }

    /// A conversation the rule moved into a workspace. Its view follows (decision 22) once views
    /// are filed by workspace; until then the canvas it is on stays (Rule 6).
    func workspaceMoved(_ conversation: String, from: Workspace?, to: Workspace) async {
        await workspaceViewFollows(conversation, from: from, to: to)
    }

    /// The branch name the ✨ quick task drafts from the Branches instructions (decision 10); nil
    /// falls back to `fallbackBranchName`.
    func draftBranchName(_ request: BranchNameRequest) async -> String? { nil }

    /// Where a conversation's view goes when it moves: filled by the views phase.
    func workspaceViewFollows(_ conversation: String, from: Workspace?, to: Workspace) async {}
}
