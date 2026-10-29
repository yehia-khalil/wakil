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
        let roots = agent.place == place ? mainGitRootPaths : await mainRootPaths(forCaller: agent.caller)
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

    /// Where a conversation's view goes when it moves (decision 22). From Main (step 0), the canvas
    /// it was in becomes the new workspace's view — on screen, both stores move it, as a new
    /// conversation adopts the seed — and its editor tabs on files in Main's folders reopen in
    /// the copy. From a workspace (a branch-off, a Move), it goes to the other workspace's view.
    func workspaceViewFollows(_ conversation: String, from: Workspace?, to: Workspace) async {
        guard let agent = conversations[conversation] else { return }
        let before = agent.layoutScope
        agent.workspace = to
        guard let after = agent.layoutScope, after != before else { return }
        guard currentAgent === agent else { return }
        await activateLayout(adoptingFrom: from == nil ? before : nil)
        if from == nil { await repointEditorTabs(in: after, into: to) }
    }

    /// Every file tab of an editor pane in `scope` on a path in Main's folder of a repo `w` has a
    /// copy of, re-pointed to the copy (its buffer kept), and the pane's saved tabs written.
    func repointEditorTabs(in scope: LayoutScope, into w: Workspace) async {
        for target in await panes.editorPanesInEveryScope() where target.scope == scope {
            let snapshot = await panes.updateEditor(in: scope, paneId: target.paneId) { s -> EditorSnapshot in
                for i in s.tabs.indices {
                    guard case .file(let path, let root) = s.tabs[i].subject,
                          let moved = workspacePath(path, in: w) else { continue }
                    s.tabs[i].subject = .file(path: moved, root: workspacePath(root, in: w) ?? root)
                }
                return s
            }
            await ScopeRouting.$home.withValue(scope) {
                await layout.setEditorTabs(id: target.paneId, to: editorSavedTabs(snapshot))
            }
        }
    }

    /// The workspace on screen: the shown conversation's (nil: Main). The context line names it.
    public var workspaceOnScreen: Workspace? { currentAgent?.workspace }

    /// The tag a folder carries in the editor's and a terminal's header (spec, piece 1).
    public func folderTag(for path: String) -> String {
        checkoutTag(for: path, in: currentAgent?.workspace.map { [$0] } ?? [])
    }
}
