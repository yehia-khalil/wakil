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

    /// Decision 22: terminals stay in Main's view — the canvas the place's Landing draws over, shell
    /// and frame as they were — and the new view opens its own in the copy, where each one stood.
    @Test func step0LeavesTerminalsInMainsViewAndOpensTheViewsOwnInTheCopy() async throws {
        let sessions = Sessions()
        let w = try await wiredWindow(sessions)
        let model = w.model
        show(placeA, in: model)
        #expect(await model.send("fix the guard"))
        let agent = try #require(model.currentAgent)
        let before = try #require(agent.layoutScope)
        let shell = await ScopeRouting.$home.withValue(before) {
            await w.layout.open(kind: "terminal", title: "core", terminalPath: "/p/core/sub")
        }
        _ = try await w.registry.dispatch(
            name: "pane_open", params: .object(["kind": .string("db")]), origin: .ui,
            caller: DispatchCaller(place: model.place, session: nil), confirmation: nil)
        await model.refreshLayout()

        await model.workspaceViewFollows(agent.id, from: nil, to: ws)

        let after = try #require(agent.layoutScope)
        let view = await snapshot(w.layout, in: after)
        #expect(!view.panes.contains { $0.id == shell.id }, "the shell stayed in Main")
        let own = try #require(view.panes.first { $0.kind == "terminal" })
        #expect(own.terminalPath == "/h/ws/api/fix-otp/core/sub")
        #expect(own.frame == shell.frame)
        #expect(view.panes.contains { $0.kind == "db" }, "data panes still come along")

        await model.newConversation()
        let main = model.layoutSnapshot
        let kept = try #require(main.panes.first { $0.id == shell.id }, "Main's view holds it")
        #expect(kept.terminalPath == "/p/core/sub")
        #expect(kept.frame == shell.frame)
        await model.shutdown()
    }

    /// Decision 28: a workspace's environment changed, so its view's data panes go to the view in the
    /// new environment, where their subjects re-run; the running conversation keeps its own view in
    /// the old one, its other panes with it.
    @Test func aWorkspacesDataPanesFollowItsEnvironment() async throws {
        let sessions = Sessions()
        let w = try await wiredWindow(sessions)
        let model = w.model
        show(placeA, in: model)
        #expect(await model.send("fix the guard"))
        let agent = try #require(model.currentAgent)
        await model.workspaceViewFollows(agent.id, from: nil, to: ws)
        let staging = try #require(agent.layoutScope)
        for kind in ["db", "api"] {
            _ = try await w.registry.dispatch(
                name: "pane_open", params: .object(["kind": .string(kind)]), origin: .ui,
                caller: DispatchCaller(place: model.place, session: nil), confirmation: nil)
        }
        _ = await w.layout.open(kind: "editor", title: "a.go")
        await model.refreshLayout()
        let data = model.layoutSnapshot.panes.filter { $0.kind == "db" || $0.kind == "api" }.map(\.id)
        #expect(data.count == 2)

        var moved = ws
        moved.environment = "qa"
        await model.workspaceDataPanesFollow(moved, from: "staging")

        #expect(!model.layoutSnapshot.panes.contains { data.contains($0.id) }, "they left the view on screen")
        #expect(model.layoutSnapshot.panes.contains { $0.kind == "editor" }, "the other panes stay")
        let qa = LayoutScope(organization: staging.organization, project: staging.project, environment: "qa",
                             lineageRoot: staging.lineageRoot)
        #expect(await snapshot(w.layout, in: qa).panes.map(\.id).sorted() == data.sorted())
        await model.shutdown()
    }

    /// The first write moves the view mid-dispatch: the rest of that dispatch was homed on the
    /// canvas it left (`ScopeRouting.home`), so `editor_create`'s tab opened on a canvas no screen
    /// shows any more (e2e workspaces-first-change, 2026-10-30). The carried canvas takes them.
    @Test func aDispatchHomedOnTheCanvasStep0CarriedWritesIntoTheWorkspacesView() async throws {
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
        let editor = "editor-x"

        await model.workspaceViewFollows(agent.id, from: nil, to: ws)
        let after = try #require(agent.layoutScope)
        #expect(after != before)

        await ScopeRouting.$home.withValue(before) {
            await w.panes.updateEditor(paneId: editor, create: true) { s in
                s.tabs = [EditorTab(subject: .file(path: "/h/ws/api/fix-otp/core/new.txt", root: "/h/ws/api/fix-otp/core"),
                                    text: "", savedText: "", language: "text", diskState: .inSync, mtime: 1,
                                    cursor: EditorPosition(line: 1, column: 1), selection: nil, visibleRange: nil,
                                    scrollTop: 0, notice: nil, readOnly: false, saving: false, edits: 0, lastAgentEdit: nil)]
                s.active = 0
            }
        }
        #expect(await w.panes.editorSnapshot(in: after, paneId: editor).tabs.first?.path == "/h/ws/api/fix-otp/core/new.txt")
        let homedLayout = await ScopeRouting.$home.withValue(before) { await w.layout.snapshot() }
        #expect(homedLayout.panes.contains { $0.kind == "db" }, "the layout reads the carried canvas too")
        // The canvas left behind is the carried one's from now on.
        #expect(await w.panes.editorSnapshot(in: before, paneId: editor).tabs.isEmpty)
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

    /// A new terminal in a workspace's view opens in its copy (decision 22), even when the copy is
    /// not of the project's first root: the first root here is a plain folder with no copy, and the
    /// terminal opened in Main's folder of it (e2e workspaces-first-change, 2026-10-30).
    @Test func aNewTerminalInAWorkspacesViewOpensInItsCopyWhateverRootComesFirst() async throws {
        let sessions = Sessions()
        let w = try await wiredWindow(sessions)
        let model = w.model
        show(placeA, in: model)
        model.setRootPathsForTesting(["/p/plain", "/p/core", "/p/web"])
        #expect(await model.send("first job"))
        let agent = try #require(model.currentAgent)
        #expect(model.activeShellContext.rootPath == "/p/plain", "Main's view: the first root")
        agent.workspace = ws
        #expect(model.activeShellContext.rootPath == "/h/ws/api/fix-otp/core")
        await model.shutdown()
    }
}

// Workspaces, piece 3: the views' doors (decision 22) — Main's view with panes and no agent, a
// workspace's view with no conversation, New conversation here.
@MainActor
struct WindowModelWorkspaceViewsTests {
    private func router(with workspaces: [Workspace]) async -> WorkspaceRouter {
        let store = WorkspaceStore()
        await store.use(load: { WorkspacesFile(workspaces: workspaces) }, save: { _ in })
        let router = WorkspaceRouter(store: store)
        _ = await router.load(org: org)
        return router
    }

    @Test func mainsViewOpensWithNoAgentAndOpeningItAgainGoesBackToIt() async throws {
        let sessions = Sessions()
        let w = try await wiredWindow(sessions)
        let model = w.model
        show(placeA, in: model)
        model.useWorkspaces(await router(with: []))
        #expect(!model.sessionStarted, "the home first")

        await model.openWorkspaceView(nil)

        let view = try #require(model.currentAgent)
        #expect(model.sessionStarted, "the canvas is drawn, not the home")
        #expect(view.isViewSlot && view.workspace == nil, "Main's view, and no agent behind it")
        #expect(sessions.issuedSockets.allSatisfy(\.stopped) || view.harness == nil)
        await model.newConversation()
        #expect(!model.sessionStarted)
        await model.openWorkspaceView(nil)
        #expect(model.currentAgent?.id == view.id, "Main keeps one view per place")
        await model.shutdown()
    }

    /// Piece 1's step 0 leaves the terminals in Main's view (decision 22): with Main's view open as a
    /// slot, that is the slot's canvas — what the project's **Open** goes back to — not the canvas the
    /// home reserves for its next conversation.
    @Test func step0LeavesTheTerminalsInMainsOpenView() async throws {
        let sessions = Sessions()
        let w = try await wiredWindow(sessions)
        let model = w.model
        show(placeA, in: model)
        model.useWorkspaces(await router(with: [ws]))
        await model.openWorkspaceView(nil)
        let main = try #require(model.currentAgent)
        await model.newConversation()
        #expect(await model.send("fix the guard"))
        let agent = try #require(model.currentAgent)
        #expect(agent.id != main.id)
        let before = try #require(agent.layoutScope)
        let shell = await ScopeRouting.$home.withValue(before) {
            await w.layout.open(kind: "terminal", title: "core", terminalPath: "/p/core/sub")
        }
        await model.refreshLayout()

        await model.workspaceViewFollows(agent.id, from: nil, to: ws)

        #expect(!(await snapshot(w.layout, in: try #require(agent.layoutScope))).panes.contains { $0.id == shell.id })
        await model.openWorkspaceView(nil)
        #expect(model.currentAgent?.id == main.id, "Open goes back to Main's view")
        let kept = try #require(model.layoutSnapshot.panes.first { $0.id == shell.id }, "Main's view holds the shell")
        #expect(kept.terminalPath == "/p/core/sub")
        await model.shutdown()
    }

    /// Piece 2's run on the home (piece 3): the card carries what the runner last said runs there,
    /// and nothing once it stopped.
    @Test func theHomesCardCarriesWhatTheRunnerSaysRuns() async throws {
        let sessions = Sessions()
        let w = try await wiredWindow(sessions)
        let model = w.model
        show(placeA, in: model)
        model.useWorkspaces(await router(with: [ws]))

        model.runLineChanged("w1", "core running on :41200")
        var screen = await model.readHomeScreen(projects: ["api"], past: [], filter: nil)
        #expect(screen.sections.first?.cards.first?.running == "core running on :41200")

        model.runLineChanged("w1", "")
        #expect(model.homeRunLines["w1"] == nil)
        screen = await model.readHomeScreen(projects: ["api"], past: [], filter: nil)
        #expect(screen.sections.first?.cards.first?.running == nil)
        await model.shutdown()
    }

    @Test func aWorkspaceWithNoLiveConversationOpensOnItsOwnView() async throws {
        let sessions = Sessions()
        let w = try await wiredWindow(sessions)
        let model = w.model
        show(placeA, in: model)
        model.useWorkspaces(await router(with: [ws]))

        await model.openWorkspaceView("w1")

        let view = try #require(model.currentAgent)
        #expect(view.isViewSlot)
        #expect(view.workspace?.id == "w1")
        #expect(view.layoutScope?.lineageRoot == "workspace-w1", "the workspace's view, filed under the workspace")
        #expect(model.liveConversationRows().first { $0.id == view.id }?.workspace?.id == "w1")
        await model.shutdown()
    }

    @Test func aWorkspaceOpensOnItsMostRecentConversationAndNewHereStartsAnother() async throws {
        let sessions = Sessions()
        let w = try await wiredWindow(sessions)
        let model = w.model
        show(placeA, in: model)
        model.useWorkspaces(await router(with: [ws]))
        #expect(await model.send("first job"))
        let first = try #require(model.currentAgent)
        first.workspace = ws
        await model.newConversation()

        await model.openWorkspaceView("w1")
        #expect(model.currentAgent?.id == first.id)

        await model.newConversationHere("w1")
        let fresh = try #require(model.currentAgent)
        #expect(fresh.id != first.id && fresh.isViewSlot && fresh.workspace?.id == "w1")
        #expect(fresh.layoutScope == first.layoutScope, "its conversations share the workspace's view")
        #expect(first.harness != nil, "the one left keeps running in the background")
        await model.shutdown()
    }

    @Test func anUnknownWorkspaceIsSaidWhole() async throws {
        let sessions = Sessions()
        let w = try await wiredWindow(sessions)
        let model = w.model
        show(placeA, in: model)
        model.useWorkspaces(await router(with: []))
        await model.openWorkspaceView("gone")
        #expect(model.status == "workspace_open: there is no workspace gone")
        #expect(!model.sessionStarted, "the screen stays where it was (Rule 6)")
        await model.shutdown()
    }
}
