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
            branchName: { [weak self] request in await self?.draftBranchName(request) },
            environmentChanged: { [weak self] w, from in await self?.workspaceDataPanesFollow(w, from: from) })
        Task { await router.install(hooks) }
    }

    /// What the write rule needs of conversation `id`; nil when it is not live. `agentRuns` is false
    /// for one no agent was started in (a place's reserved conversation the e2e harness dispatches as).
    func workspaceFacts(_ id: String) async -> WorkspaceConversationFacts? {
        guard let agent = conversations[id] else { return nil }
        let roots = agent.place == place ? mainGitRootPaths : await mainRootPaths(forCaller: agent.caller)
        return WorkspaceConversationFacts(
            id: agent.id, lineageRoot: agent.lineageRoot, title: agent.title, ticket: agent.handoff?.key,
            organization: agent.place.organization, project: agent.place.project,
            environment: agent.place.environment, mainRoots: roots, firstMessage: agent.firstMessage,
            agentRuns: agent.runsOrStarts)
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
    func draftBranchName(_ request: BranchNameRequest) async -> String? {
        let rules = branchInstructions(project: request.project)
        guard !rules.isEmpty, commitDraftsEnabled, let tasks = quickTasks else { return nil }
        let draft = Task { try BranchDraft.parse(try await tasks.respond(BranchDraft.request(request, instructions: rules))) }
        let timer = Task {
            try? await Task.sleep(for: BranchDraft.patience)
            draft.cancel()
        }
        defer { timer.cancel() }
        return try? await draft.value
    }

    /// Where a conversation's view goes when it moves (decision 22). From Main (step 0), the canvas
    /// it was in becomes the new workspace's view — on screen, both stores move it, as a new
    /// conversation adopts the seed — its editor tabs on files in Main's folders reopen in the
    /// copy, and its terminals stay in Main's view, a new one in the copy in each one's place.
    /// From a workspace (a branch-off, a Move), it goes to the other workspace's view.
    func workspaceViewFollows(_ conversation: String, from: Workspace?, to: Workspace) async {
        guard let agent = conversations[conversation] else { return }
        let before = agent.layoutScope
        agent.workspace = to
        guard let after = agent.layoutScope, after != before else { return }
        guard currentAgent === agent else { return }
        let terminals = layoutSnapshot.panes.filter { PaneKinds.is($0.kind, TerminalPaneKind.self) }.map(\.id)
        await activateLayout(adoptingFrom: from == nil ? before : nil)
        if from == nil, let before {
            await repointEditorTabs(in: after, into: to)
            // The write that moved it is still homed on the canvas it left: it lands in this one.
            await panes.scopeCarried(from: before, to: after)
            await layout.scopeCarried(from: before, to: after)
            // Terminals stay in Main's view; the new view opens its own in the copy (decision 22).
            await leaveTerminalsInMain(terminals, of: agent.place, view: after, into: to)
        }
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

    /// What `agent`'s map reads (spec, "The agent sees real paths"): its workspace from the record,
    /// with holders and states; for one in Main, Main's folders, the conversations there and the
    /// project's workspaces.
    func workspaceMapInput(for agent: PlaceAgent) async -> WorkspaceMapInput {
        let place = agent.place
        let listings = await workspaceRouter?.listing(project: place.project) ?? []
        let own = agent.workspace.map { w in
            listings.first { $0.workspace.id == w.id } ?? WorkspaceListing(workspace: w, holders: [:], live: [:])
        }
        let roots = place == self.place ? mainGitRootPaths : await mainRootPaths(forCaller: agent.caller)
        var branches: [String: String] = [:]
        if place == self.place {
            for r in gitRoots where roots.contains(r.root) { branches[r.root] = r.branch }
        }
        let rows = liveConversationRows(in: place)
        var mainLive: [String: ConversationState] = [:]
        for row in rows where conversations[row.id]?.workspace == nil { mainLive[row.id] = row.state }
        return WorkspaceMapInput(
            conversation: agent.id, project: place.project, environment: place.environment, own: own,
            mainRoots: roots, mainBranches: branches, workspaces: listings, mainLive: mainLive,
            titles: Dictionary(rows.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a }))
    }

    /// The map block `agent`'s next turn carries after its words: on its session's first turn, and
    /// whenever the map changed since it was last sent; nil otherwise, with no project (no folders
    /// to map), and in a window the write rule is not wired into (no record: `useWorkspaces`).
    func workspaceMapUpdate(for agent: PlaceAgent) async -> String? {
        guard workspaceRouter != nil, !agent.place.project.isEmpty else { return nil }
        let map = workspaceMapText(await workspaceMapInput(for: agent))
        guard map != agent.sentWorkspaceMap else { return nil }
        agent.sentWorkspaceMap = map
        return workspaceMapHeader + "\n" + map
    }

    /// The workspace on screen: the shown conversation's (nil: Main). The context line names it.
    public var workspaceOnScreen: Workspace? { currentAgent?.workspace }

    /// The tag a folder carries in the editor's and a terminal's header (spec, piece 1).
    public func folderTag(for path: String) -> String {
        checkoutTag(for: path, in: currentAgent?.workspace.map { [$0] } ?? [])
    }
}

// Workspaces, piece 2: a run's failure in the thread of the conversation that asked, and the
// project.json the runner reads a workspace's recipes from.
extension WindowModel {
    /// Points the runner at this window (`WakilWiring.useActiveContext(of:)`).
    public func useRunner(_ runner: WorkspaceRunner) {
        Task {
            await runner.use(say: { [weak self] conversation, text, isError in
                await self?.sayRun(conversation, text, isError: isError)
            })
            await runner.use(projectPath: { [weak self] project in await self?.projectFilePath(project) })
        }
    }

    func sayRun(_ conversation: String, _ text: String, isError: Bool) {
        conversations[conversation]?.appendRow(label: "run", detail: text, isError: isError)
    }

    /// A project registry key's project.json, from the settings tree; nil when it is not read yet.
    func projectFilePath(_ project: String) -> String? {
        settings?.projects.first { $0.name == project }?.path
    }
}

// Workspaces, piece 2: the Running settings dispatch their actions as the operator.
extension WindowModel {
    /// Dispatches one `running_*` (or `workspace_run`…) action from Settings; answers its result,
    /// or the refusal's text whole (Rule 8).
    public func runningDispatch(_ action: String, _ params: JSONValue) async -> (result: JSONValue?, error: String?) {
        do {
            let r = try await registry.dispatch(
                name: action, params: params, origin: .ui, caller: DispatchCaller(place: place, session: nil), confirmation: nil)
            var value = r
            if case .object(let o) = r, let s = o["structuredContent"] { value = s }
            return (value, nil)
        } catch {
            return (nil, "\(error)")
        }
    }
}
