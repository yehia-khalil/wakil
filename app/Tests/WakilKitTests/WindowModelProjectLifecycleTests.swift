import Foundation
import Testing
@testable import WakilKit

/// A wakil-ctx that keeps projects and environments in memory and answers as the Go tools do:
/// a rename keeps the active place, a removal of the active one picks the first remaining.
private actor LifecycleContext: ToolCaller {
    var envs: [String: [String]] = ["p": ["dev", "stage"]]
    var project = "p"
    var environment = "dev"
    var calls: [String] = []
    var failWith: String?

    func fail(with text: String?) { failWith = text }
    func count(_ name: String) -> Int { calls.filter { $0 == name }.count }

    private func ok(_ o: [String: JSONValue]) -> JSONValue { .object(["structuredContent": .object(o)]) }

    func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        calls.append(name)
        func arg(_ key: String) -> String {
            guard case .object(let o) = arguments, case .string(let s)? = o[key] else { return "" }
            return s
        }
        switch name {
        case "get_context":
            return ok([
                "Org": .string("test-org"), "Environment": .string(environment),
                "ProjectKey": .string(project), "Project": .object(["name": .string(project)]),
                "RootPaths": .array([]), "ActiveProvider": .string("p1"),
            ])
        case "config_tree": return ok(["projects": .array([])])
        default: break
        }
        if let failWith {
            return .object(["isError": .bool(true), "content": .array([.object(["type": .string("text"), "text": .string(failWith)])])])
        }
        switch name {
        case "create_project":
            envs[arg("name")] = ["dev"]
            return ok(["name": .string(arg("name")), "path": .string(arg("folder") + "/project.json")])
        case "rename_project":
            envs[arg("newName")] = envs.removeValue(forKey: arg("name"))
            if project == arg("name") { project = arg("newName") }
            return ok([:])
        case "remove_project":
            envs[arg("name")] = nil
            if project == arg("name") { project = envs.keys.sorted().first ?? ""; environment = envs[project]?.first ?? "" }
            return ok([:])
        case "set_environment":
            environment = arg("name")
            return ok([:])
        case "create_environment":
            envs[project, default: []].append("env-2")
            return ok(["name": .string("env-2")])
        case "rename_environment":
            envs[project] = envs[project]?.map { $0 == arg("name") ? arg("newName") : $0 }
            if environment == arg("name") { environment = arg("newName") }
            return ok([:])
        case "remove_environment":
            envs[project]?.removeAll { $0 == arg("name") }
            if environment == arg("name") { environment = envs[project]?.sorted().first ?? "" }
            return ok(["trashed": .string("/Trash/project.json")])
        default: return ok([:])
        }
    }
}

private func snapshot(_ title: String) -> LayoutSnapshot {
    LayoutSnapshot(
        panes: [Pane(id: "db-1", kind: "db", title: title, frame: PaneFrame(x: 1, y: 2, width: 300, height: 200))],
        focusedId: "db-1", maximizedId: nil, graph: SnapGraph())
}

private func scope(_ project: String, _ environment: String) -> LayoutScope {
    LayoutScope(organization: "test-org", project: project, environment: environment)
}

@MainActor
private func lifecycleWindow(saved: [(String, String, String)] = [], harnesses: Harnesses? = nil)
    async throws -> (WindowModel, LifecycleContext, LayoutPersistence)
{
    let ctx = LifecycleContext()
    let directory = testScratchRoot.appendingPathComponent("lifecycle-\(UUID().uuidString)", isDirectory: true)
    let persistence = LayoutPersistence(directory: directory)
    for (project, environment, title) in saved {
        try persistence.save(snapshot(title), for: scope(project, environment))
    }
    let window = WindowModel.forTesting(
        scratchRoot: testScratchRoot,
        harnessFactory: { place, _ in harnesses?.make(place) },
        lookupFactory: { _ in AlwaysSucceedsCredentialsLookupForTesting() },
        context: ContextStore(client: ctx), persistence: persistence)
    // Invariant 5's pin check asks this window's agents, as `WakilWiring.useActiveContext` wires it.
    let agents = ActiveAgentLookup()
    // The window's own pane store: `registerStandardActions` installs the registry's screen scope
    // from the store it is given, and a shell opens under that scope.
    await registerStandardActions(
        into: window.registryForTesting, context: ctx, panes: window.panesForTesting,
        db: nil, resumes: ResumeBroker(),
        agentIn: { project, environment in await agents.agent(in: project, environment: environment) })
    agents.use { [weak window] project, environment in
        await window?.runningAgent(in: project, environment: environment)
    }
    await window.refreshContext()
    return (window, ctx, persistence)
}

@Suite @MainActor struct WindowModelProjectLifecycleTests {
    @Test func renamingTheActiveEnvironmentKeepsThePlaceAndItsPanes() async throws {
        let (window, _, persistence) = try await lifecycleWindow(saved: [("p", "dev", "mine")])
        #expect(window.layoutSnapshot.panes.map(\.title) == ["mine"])

        let error = await window.renameEnvironment(project: "p", projectPath: "/p", "dev", to: "local")

        #expect(error == nil)
        #expect(window.environment == "local")
        #expect(window.layoutSnapshot.panes.map(\.title) == ["mine"])
        #expect(persistence.load(for: scope("p", "dev")).snapshot == nil)
        #expect(persistence.load(for: scope("p", "local")).snapshot != nil)
    }

    @Test func renamingTheActiveProjectKeepsThePlaceAndItsPanes() async throws {
        let (window, _, persistence) = try await lifecycleWindow(saved: [("p", "dev", "mine")])

        let error = await window.renameProject("p", to: "q")

        #expect(error == nil)
        #expect(window.projectKey == "q")
        #expect(window.environment == "dev")
        #expect(window.layoutSnapshot.panes.map(\.title) == ["mine"])
        #expect(persistence.load(for: scope("p", "dev")).snapshot == nil)
    }

    @Test func aRenameOfAnUnrelatedEnvironmentLeavesTheCanvasAlone() async throws {
        let (window, _, persistence) = try await lifecycleWindow(saved: [("p", "dev", "mine"), ("p", "stage", "theirs")])
        _ = await window.renameEnvironment(project: "p", projectPath: "/p", "stage", to: "qa")
        #expect(window.environment == "dev")
        #expect(window.layoutSnapshot.panes.map(\.title) == ["mine"])
        #expect(persistence.load(for: scope("p", "qa")).snapshot?.panes.map(\.title) == ["theirs"])
    }

    @Test func removingTheActiveEnvironmentLandsOnTheFirstRemainingWithItsPanesDropped() async throws {
        let (window, _, persistence) = try await lifecycleWindow(saved: [("p", "dev", "mine")])
        #expect(window.layoutSnapshot.panes.count == 1)

        let result = await window.removeEnvironment(project: "p", projectPath: "/p", "dev")

        #expect(result.error == nil)
        #expect(result.receipt == "Removed dev — a copy of project.json is in the Trash")
        #expect(window.environment == "stage")
        #expect(window.layoutSnapshot.panes.isEmpty)
        // The removed place's canvas is not written back out on the way off it.
        #expect(persistence.load(for: scope("p", "dev")).snapshot?.panes.map(\.title) == ["mine"])
    }

    @Test func removingTheActiveProjectWithPanesOpenDoesNotCrash() async throws {
        let (window, ctx, _) = try await lifecycleWindow(saved: [("p", "dev", "mine")])
        await ctx.fail(with: nil)
        let error = await window.removeProject("p")
        #expect(error == nil)
        #expect(window.projectKey == "")
        #expect(window.layoutSnapshot.panes.isEmpty)
    }

    @Test func creatingAProjectDefaultsTheNameToTheFolder() async throws {
        let (window, ctx, _) = try await lifecycleWindow()
        let result = await window.createProject(folder: "/work/booking")
        #expect(result.error == nil)
        #expect(result.name == "booking")
        #expect(await ctx.envs["booking"] == ["dev"])
    }

    @Test func creatingAnEnvironmentReturnsItsName() async throws {
        let (window, _, _) = try await lifecycleWindow()
        let result = await window.createEnvironment(project: "p", projectPath: "/p")
        #expect(result.error == nil)
        #expect(result.name == "env-2")
    }

    @Test func aFailedActionReturnsTheToolsTextWholeAndStillRefreshesSettings() async throws {
        let (window, ctx, persistence) = try await lifecycleWindow(saved: [("p", "dev", "mine")])
        await ctx.fail(with: "an environment named local already exists")
        let before = await ctx.count("config_tree")

        let error = await window.renameEnvironment(project: "p", projectPath: "/p", "dev", to: "local")

        #expect(error?.contains("an environment named local already exists") == true)
        #expect(await ctx.count("config_tree") > before)
        #expect(window.environment == "dev")
        // Nothing moved: the rename did not happen.
        #expect(persistence.load(for: scope("p", "dev")).snapshot != nil)
    }

    // MARK: Final review Important 1: what is in memory follows a rename, and a removal ends it

    /// A dirty file tab, put straight into `scope`'s editor pane `editor-9`.
    private func dirtyTab(_ window: WindowModel, in scope: LayoutScope, path: String) async {
        let panes = window.panesForTesting
        let shown = await panes.screenScope
        if scope != shown { await panes.switchScope(to: scope) }
        await panes.updateEditor(paneId: "editor-9", create: true) { s in
            var t = EditorTab.file(path: path, root: "/p", text: "x", mtime: 1, language: "go")
            t.text = "y"
            s.tabs = [t]; s.active = 0
        }
        if scope != shown { await panes.switchScope(to: shown) }
    }

    @Test func renamingTheActiveEnvironmentKeepsItsShellRunning() async throws {
        let (window, _, _) = try await lifecycleWindow(saved: [("p", "dev", "mine")])
        let pane = await window.openTerminalForTesting(path: NSTemporaryDirectory())
        let pid = try #require(await window.terminals.pidForTesting(paneId: pane))

        #expect(await window.renameEnvironment(project: "p", projectPath: "/p", "dev", to: "local") == nil)

        // The same shell, reached under the new name: not a fresh one, and not orphaned.
        #expect(await window.terminals.pidForTesting(paneId: pane) == pid)
        #expect(kill(pid, 0) == 0)
        await window.shutdown()
    }

    @Test func renamingTheActiveProjectKeepsADirtyTabReachable() async throws {
        let (window, _, _) = try await lifecycleWindow(saved: [("p", "dev", "mine")])
        await dirtyTab(window, in: scope("p", "dev"), path: "/p/a.go")

        #expect(await window.renameProject("p", to: "q") == nil)

        let panes = window.panesForTesting
        #expect(await panes.screenScope == scope("q", "dev"))
        let tab = await panes.updateEditor(in: scope("q", "dev"), paneId: "editor-9") { s in s.tabs.first }
        #expect(tab?.dirty == true)
        #expect(await panes.editorDirtyTabsInHiddenScopes().isEmpty, "nothing left behind under the old name")
    }

    /// A project rename carries every environment's canvas, not only the one on screen.
    @Test func renamingAProjectCarriesAHiddenEnvironmentsDirtyTab() async throws {
        let (window, _, _) = try await lifecycleWindow(saved: [("p", "dev", "mine")])
        await dirtyTab(window, in: scope("p", "stage"), path: "/p/b.go")

        #expect(await window.renameProject("p", to: "q") == nil)

        let hidden = await window.panesForTesting.editorDirtyTabsInHiddenScopes()
        #expect(hidden.map(\.scope) == [scope("q", "stage")])
        #expect(await window.panesForTesting.screenScope == scope("q", "dev"))
    }

    /// Shown in a conversation (a pane opened mints one): the rename keeps the conversation, its
    /// panes and its saved file, rather than landing on the project's seed.
    @Test func renamingTheActiveProjectKeepsTheConversationOnScreen() async throws {
        let (window, _, persistence) = try await lifecycleWindow(saved: [("p", "dev", "mine")])
        #expect(await window.openPane(kind: "db"))
        let root = try #require(window.lineageRoot)
        #expect(window.layoutSnapshot.panes.count == 2)

        #expect(await window.renameProject("p", to: "q") == nil)

        #expect(window.lineageRoot == root)
        #expect(window.layoutSnapshot.panes.count == 2)
        let moved = LayoutScope(organization: "test-org", project: "q", environment: "dev", lineageRoot: root)
        #expect(persistence.load(for: moved).snapshot?.panes.count == 2)
    }

    @Test func removingTheActiveEnvironmentClosesItsShells() async throws {
        let (window, _, _) = try await lifecycleWindow(saved: [("p", "dev", "mine")])
        let pane = await window.openTerminalForTesting(path: NSTemporaryDirectory())
        let pid = try #require(await window.terminals.pidForTesting(paneId: pane))

        #expect(await window.removeEnvironment(project: "p", projectPath: "/p", "dev").error == nil)

        #expect(kill(pid, 0) == -1, "the removed place's shell was reaped")
        await window.shutdown()
    }

    /// Controller ruling: a removal would strand unsaved work, so it is refused, naming the files.
    @Test func removingAnEnvironmentWithAnUnsavedTabIsRefusedNamingIt() async throws {
        let (window, ctx, _) = try await lifecycleWindow(saved: [("p", "dev", "mine")])
        await dirtyTab(window, in: scope("p", "dev"), path: "/p/a.go")

        let result = await window.removeEnvironment(project: "p", projectPath: "/p", "dev")

        #expect(result.error?.contains("a.go") == true)
        #expect(result.error?.contains("save or close them first") == true)
        #expect(await ctx.count("remove_environment") == 0, "nothing was removed")
        #expect(window.environment == "dev")
    }

    @Test func removingAProjectWithAnUnsavedTabInAHiddenEnvironmentIsRefused() async throws {
        let (window, ctx, _) = try await lifecycleWindow(saved: [("p", "dev", "mine")])
        await dirtyTab(window, in: scope("p", "stage"), path: "/p/b.go")

        let error = await window.removeProject("p")

        #expect(error?.contains("b.go") == true)
        #expect(await ctx.count("remove_project") == 0)
    }

    // MARK: Conversations 3 of 3, Task 2: rename carries every idle conversation, removal closes them

    /// A conversation with no live agent, begun in the place on screen (a pane, or a session that
    /// ended, mints one), then put in the background by New Conversation.
    private func idleConversation(_ window: WindowModel) async throws -> String {
        window.markSessionStarted()
        let id = try #require(window.currentAgent?.id)
        await window.newConversation()
        return id
    }

    @Test func renameCarriesEveryIdleConversationOfThePlace() async throws {
        let (window, _, _) = try await lifecycleWindow(saved: [("p", "dev", "mine")])
        let a = try await idleConversation(window)
        let b = try await idleConversation(window)
        let renamedA = Place(organization: "test-org", project: "p", environment: "local")

        #expect(await window.renameEnvironment(project: "p", projectPath: "/p", "dev", to: "local") == nil)

        #expect(window.liveConversationRows(in: renamedA).map(\.id).sorted() == [a, b].sorted())
        #expect(window.liveConversationRows(in: Place(organization: "test-org", project: "p", environment: "dev")).isEmpty)
        await window.shutdown()
    }

    @Test func removingAnEnvironmentClosesItsIdleConversationsAndTheirShells() async throws {
        let (window, _, _) = try await lifecycleWindow(saved: [("p", "dev", "mine")])
        let dev = Place(organization: "test-org", project: "p", environment: "dev")
        window.markSessionStarted()
        let id = try #require(window.currentAgent?.id)
        let pane = await window.openTerminalForTesting(path: NSTemporaryDirectory())
        let pid = try #require(await window.terminals.pidForTesting(paneId: pane))
        #expect(await window.setEnvironment("stage"))
        #expect(window.liveConversationRows(in: dev).map(\.id) == [id], "idle, in the background")

        #expect(await window.removeEnvironment(project: "p", projectPath: "/p", "dev").error == nil)

        #expect(window.liveConversationRows(in: dev).isEmpty && window.chips.isEmpty)
        #expect(window.conversation(id: id) == nil)
        #expect(kill(pid, 0) == -1, "its shell was reaped")
        #expect(window.environment == "stage")
        await window.shutdown()
    }

    @Test func removingTheEnvironmentOnScreenClosesItsConversation() async throws {
        let (window, _, _) = try await lifecycleWindow(saved: [("p", "dev", "mine")])
        let id = try await idleConversation(window)
        window.markSessionStarted()
        let shown = try #require(window.currentAgent?.id)

        #expect(await window.removeEnvironment(project: "p", projectPath: "/p", "dev").error == nil)

        #expect(window.conversation(id: id) == nil && window.conversation(id: shown) == nil)
        #expect(window.liveConversations().isEmpty)
        #expect(window.environment == "stage")
        await window.shutdown()
    }

    @Test func removingAProjectClosesTheIdleConversationsOfEveryEnvironment() async throws {
        let (window, ctx, _) = try await lifecycleWindow(saved: [("p", "dev", "mine")])
        let dev = try await idleConversation(window)
        #expect(await window.setEnvironment("stage"))
        let stage = try await idleConversation(window)
        await ctx.fail(with: nil)

        #expect(await window.removeProject("p") == nil)

        #expect(window.conversation(id: dev) == nil && window.conversation(id: stage) == nil)
        await window.shutdown()
    }

    @Test func removalIsStillRefusedWhileAnyConversationThereRuns() async throws {
        let harnesses = Harnesses()
        let (window, ctx, _) = try await lifecycleWindow(saved: [("p", "dev", "mine")], harnesses: harnesses)
        let idle = try await idleConversation(window)
        #expect(await window.send("long job"))
        let running = try #require(window.currentAgent?.id)

        let result = await window.removeEnvironment(project: "p", projectPath: "/p", "dev")
        let rename = await window.renameEnvironment(project: "p", projectPath: "/p", "dev", to: "local")

        let expectedTodaysSentence = "ctx_remove_environment: agent (p1) is running in p / dev — an agent keeps its own place; stop it first"
        #expect(result.error == expectedTodaysSentence)
        #expect(rename == "ctx_rename_environment: agent (p1) is running in p / dev — an agent keeps its own place; stop it first")
        #expect(await ctx.count("remove_environment") == 0)
        #expect(await ctx.count("rename_environment") == 0)
        #expect(window.conversation(id: idle) != nil && window.conversation(id: running) != nil, "nothing was closed")
        #expect(harnesses.issued.allSatisfy { !$0.stopped })
        await window.shutdown()
    }

    /// Minor 3: a Name field left by moving to another page is gone when its refusal lands, so
    /// the refusal is said in the window's status instead of under nothing (Rules 2, 8).
    @Test func aRefusalWhoseFieldIsGoneIsSaidInTheStatus() async throws {
        let (window, _, _) = try await lifecycleWindow()
        window.showUnseenRefusal("an environment named local already exists")
        #expect(window.status == "an environment named local already exists")
    }

    @Test func aSuccessfulActionRefreshesSettingsAndContext() async throws {
        let (window, ctx, _) = try await lifecycleWindow()
        let settings = await ctx.count("config_tree")
        let contexts = await ctx.count("get_context")
        _ = await window.removeProject("zzz")
        #expect(await ctx.count("config_tree") > settings)
        #expect(await ctx.count("get_context") > contexts)
    }
}
