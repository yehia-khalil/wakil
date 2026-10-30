import Foundation
import Testing
@testable import WakilKit

// Workspaces, piece 1 (decision 22): a workspace's view is shared by its conversations; the write
// rule's step 0 carries the canvas the conversation was in into the new workspace's view, its editor
// tabs reopened in the copy; the thread says what the rule did.

private let org = "initech"
private let placeA = Place(organization: org, project: "api", environment: "staging")
private let placeB = Place(organization: org, project: "web", environment: "staging")

@MainActor
private func waitUntil(_ condition: @MainActor () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(2 * testWaitLoadMultiplier)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    return await condition()
}

/// Puts `place` on screen as `PlaceAgentTests` does: the context fields, no `wakil-ctx` behind them.
@MainActor
private func show(_ place: Place, in model: WindowModel) {
    model.seedForTesting(
        providerId: "test-provider", rootPath: "/tmp/wakil-window-model-for-testing", thoughts: 0,
        project: place.project, environment: place.environment)
}

private struct Wired {
    let model: WindowModel
    let registry: ActionRegistry
    let panes: PaneStore
    let layout: LayoutStore
    let conversations: ConversationBroker
    let resumes: ResumeBroker
}

/// A window with the standard and layout actions registered, driving `sessions`' harnesses and
/// sockets, with `persistence` when a test needs the project seed on disk.
@MainActor
private func wiredWindow(
    _ sessions: Sessions, persistence: LayoutPersistence? = nil, confirmations: ConfirmationBroker = ConfirmationBroker(),
    context: (any ToolCaller)? = nil, parkedConversations: ConversationBroker? = nil,
    parkedResumes: ResumeBroker? = nil
) async throws -> Wired {
    let dir = testScratchRoot.appendingPathComponent("conversation-switch-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let registry = ActionRegistry(journalDirectory: dir, sessionId: "conversation-switch")
    let panes = PaneStore()
    let layout = LayoutStore()
    let resumes = ResumeBroker()
    let conversations = ConversationBroker()
    // Pointed at the window below, as `WakilWiring.useActiveContext(of:)` points it.
    let live = LiveConversationLookup()
    await registerStandardActions(
        into: registry, context: context, panes: panes, db: nil, resumes: parkedResumes ?? resumes, layout: layout,
        conversationRequests: parkedConversations ?? conversations, liveConversations: { await live.live(in: $0) },
        liveOrganization: { await live.organization() })
    await registerLayoutActions(into: registry, layout: layout, panes: panes)
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, persistence: persistence, context: nil,
        harnessFactory: { place, _, socketPath in sessions.harness(place, socketPath) },
        resumes: resumes, rootPath: "/tmp", providerId: "test-provider",
        lookupFactory: { _ in AlwaysSucceedsCredentialsLookupForTesting() },
        confirmations: confirmations,
        conversationRequests: conversations,
        agentSocketFactory: sessions.socketFactory, environment: "staging")
    model.setOrganizationForTesting(org)
    live.use({ [weak model] place in await model?.liveConversationRows(in: place) ?? [] },
             organization: { [weak model] in await model?.organization })
    return Wired(
        model: model, registry: registry, panes: panes, layout: layout, conversations: conversations, resumes: resumes)
}

/// `scope`'s arrangement, read as a caller homed there reads it.
private func snapshot(_ layout: LayoutStore, in scope: LayoutScope) async -> LayoutSnapshot {
    await ScopeRouting.$home.withValue(scope) { await layout.snapshot() }
}

/// The caller of the live socket that answers for `conversation`, the newest first.
private func caller(of conversation: String, _ sessions: Sessions) async -> DispatchCaller? {
    for socket in sessions.issuedSockets.reversed() where !socket.stopped {
        let c = await socket.caller()
        if c.conversation == conversation { return c }
    }
    return nil
}


private let ws = Workspace(
    id: "w1", name: "Fix OTP guard order", slug: "fix-otp", project: "api", environment: "staging",
    checkouts: [WorkspaceCheckout(repo: "/p/core", path: "/h/ws/api/fix-otp/core", branch: "fix-otp")])

@MainActor
struct WindowModelWorkspacesTests {
    @Test func step0CarriesTheCanvasIntoTheWorkspacesViewAndItsEditorTabsIntoTheCopy() async throws {
        let sessions = Sessions()
        let w = try await wiredWindow(sessions)
        let model = w.model
        show(placeA, in: model)
        #expect(await model.send("fix the guard"))
        let agent = try #require(model.currentAgent)
        let before = try #require(agent.layoutScope)
        _ = try await w.registry.dispatch(
            name: "pane_open", params: .object(["kind": .string("db")]), origin: .ui,
            caller: DispatchCaller(place: model.place, session: nil), confirmation: nil)
        #expect(await w.panes.activeScope == before)
        await w.panes.updateEditor(paneId: "editor-x", create: true) { s in
            s.tabs = [EditorTab(subject: .file(path: "/p/core/a.go", root: "/p/core"), text: "x", savedText: "x", language: "go",
                                diskState: .inSync, mtime: 1, cursor: EditorPosition(line: 1, column: 1), selection: nil,
                                visibleRange: nil, scrollTop: 0, notice: nil, readOnly: false, saving: false, edits: 0,
                                lastAgentEdit: nil)]
            s.active = 0
        }

        await model.workspaceViewFollows(agent.id, from: nil, to: ws)

        let after = try #require(agent.layoutScope)
        #expect(after.lineageRoot == "workspace-w1")
        #expect(model.layoutSnapshot.panes.contains { $0.kind == "db" }, "the data pane came along")
        let tabs = await w.panes.editorSnapshot(in: after, paneId: "editor-x").tabs
        #expect(tabs.first?.path == "/h/ws/api/fix-otp/core/a.go")
        #expect(model.workspaceOnScreen?.id == "w1")
        #expect(model.folderTag(for: "/h/ws/api/fix-otp/core/a.go") == "workspace copy")
        #expect(model.folderTag(for: "/p/web/b.go") == "Main · your folder")
        await model.shutdown()
    }

    /// The write rule applies to a conversation whose agent runs. A place's conversation minted by a
    /// pane, with no agent ever started (the seeded e2e checks' dispatches name it), is not one; a sent
    /// message starts it (amendment 2026-10-30).
    @Test func aConversationWithNoAgentStartedIsNotAWriterForTheRule() async throws {
        let sessions = Sessions()
        let w = try await wiredWindow(sessions)
        let model = w.model
        show(placeA, in: model)
        model.markSessionStarted()
        let idle = try #require(model.currentAgent)
        #expect(await model.workspaceFacts(idle.id)?.agentRuns == false)
        #expect(await model.send("fix the guard"))
        let agent = try #require(model.currentAgent)
        #expect(await model.workspaceFacts(agent.id)?.agentRuns == true)
        await model.shutdown()
    }

    @Test func twoConversationsInOneWorkspaceShareItsView() async throws {
        let sessions = Sessions()
        let w = try await wiredWindow(sessions)
        let model = w.model
        show(placeA, in: model)
        #expect(await model.send("first job"))
        let first = try #require(model.currentAgent)
        await model.newConversation()
        #expect(await model.send("second job"))
        let second = try #require(model.currentAgent)
        await model.workspaceViewFollows(second.id, from: nil, to: ws)
        await model.workspaceViewFollows(first.id, from: ws, to: ws)
        first.workspace = ws
        #expect(first.layoutScope == second.layoutScope)
        await model.shutdown()
    }

    @Test func theRulesSentenceLandsInTheConversationsThread() async throws {
        let sessions = Sessions()
        let w = try await wiredWindow(sessions)
        let model = w.model
        show(placeA, in: model)
        #expect(await model.send("first job"))
        let agent = try #require(model.currentAgent)
        model.sayWorkspace(agent.id, .tookOver(repo: "api", from: "backend"))
        model.sayWorkspace(agent.id, .addFailed(repo: "core", message: "fatal: no"))
        let rows = agent.thoughts.suffix(2)
        #expect(rows.first?.detail == "Took over api from ‘backend’ (idle).")
        #expect(rows.last?.isError == true)
        #expect(rows.last?.detail == "Could not make a copy of core, so the change was not made:\nfatal: no")
        await model.shutdown()
    }
}

@MainActor
struct WindowModelWorkspaceRootsTests {
    @Test func theViewsFoldersAreTheWorkspacesCopiesAndMainsForTheRest() async throws {
        let sessions = Sessions()
        let w = try await wiredWindow(sessions)
        let model = w.model
        show(placeA, in: model)
        model.setRootPathsForTesting(["/p/core", "/p/web"])
        #expect(await model.send("first job"))
        let agent = try #require(model.currentAgent)
        #expect(model.gitRootPaths == ["/p/core", "/p/web"])
        agent.workspace = ws
        #expect(model.gitRootPaths == ["/h/ws/api/fix-otp/core", "/p/web"])
        #expect(model.mainGitRootPaths == ["/p/core", "/p/web"])
        #expect(model.activeShellContext.rootPath == "/h/ws/api/fix-otp/core")
        await model.shutdown()
    }
}
