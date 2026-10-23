import Foundation
import Testing
@testable import WakilKit

// Conversations 2 of 3, Task 2: `session_new` puts the conversation on screen into the
// background, untouched, and shows the place's Landing; `session_switch` brings one back — same
// session, thread and canvas, no fork.

private let org = "initech"
private let placeA = Place(organization: org, project: "api", environment: "staging")

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
}

/// A window with the standard and layout actions registered, driving `sessions`' harnesses and
/// sockets, with `persistence` when a test needs the project seed on disk.
@MainActor
private func wiredWindow(_ sessions: Sessions, persistence: LayoutPersistence? = nil) async throws -> Wired {
    let dir = testScratchRoot.appendingPathComponent("conversation-switch-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let registry = ActionRegistry(journalDirectory: dir, sessionId: "conversation-switch")
    let panes = PaneStore()
    let layout = LayoutStore()
    let resumes = ResumeBroker()
    let conversations = ConversationBroker()
    await registerStandardActions(
        into: registry, context: nil, panes: panes, db: nil, resumes: resumes, layout: layout,
        conversationRequests: conversations)
    await registerLayoutActions(into: registry, layout: layout, panes: panes)
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, persistence: persistence, context: nil,
        harnessFactory: { place, _, socketPath in sessions.harness(place, socketPath) },
        resumes: resumes, rootPath: "/tmp", providerId: "test-provider",
        lookupFactory: { _ in AlwaysSucceedsCredentialsLookupForTesting() },
        conversationRequests: conversations,
        agentSocketFactory: sessions.socketFactory, environment: "staging")
    model.setOrganizationForTesting(org)
    return Wired(model: model, registry: registry, panes: panes, layout: layout, conversations: conversations)
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

@MainActor
struct ConversationSwitchTests {
    @Test func newConversationBackgroundsABusyOneAndItsTurnFinishesThere() async throws {
        let sessions = Sessions()
        let model = try await wiredWindow(sessions).model
        show(placeA, in: model)
        #expect(await model.send("first job"))
        let first = try #require(model.currentAgent)
        #expect(model.conversationOnScreen)

        await model.newConversation()

        #expect(!model.sessionStarted && model.currentAgent == nil && model.thoughts.isEmpty)
        #expect(!model.conversationOnScreen)
        #expect(model.conversation(id: first.id) === first, "still live")
        #expect(first.harness != nil && sessions.harnesses.in(placeA).first?.stopped == false)
        #expect(first.turnInFlight, "its turn carries on")
        try #require(sessions.harnesses.in(placeA).first).emit(.result(isError: false, text: "done"))
        #expect(await waitUntil { model.chips.first?.state == .done }, "\(model.chips)")
        #expect(model.chips.first?.conversation == first.id)

        await model.switchToConversation(first.id)

        #expect(model.currentAgent === first && model.sessionId == first.sessionId)
        #expect(model.chips.isEmpty, "seen on its return")
        #expect(sessions.harnesses.in(placeA).count == 1, "no fork, no fresh process")
        await model.shutdown()
    }

    @Test func theNextTurnOnTheLandingMintsANewSessionAndRoot() async throws {
        let sessions = Sessions()
        let model = try await wiredWindow(sessions).model
        show(placeA, in: model)
        #expect(await model.send("first job"))
        let first = try #require(model.currentAgent)
        await model.newConversation()

        #expect(await model.send("second job"))

        let second = try #require(model.currentAgent)
        #expect(second.id != first.id && model.lineageRoot == second.id)
        #expect(second.sessionId != first.sessionId)
        #expect(model.liveConversations(in: placeA).map(\.id) == [first.id, second.id])
        #expect(sessions.harnesses.in(placeA).count == 2)
        #expect(first.layoutScope != second.layoutScope, "each its own canvas")
        await model.shutdown()
    }

    @Test func theLandingAfterNewConversationSurvivesTheSeedsPanes() async throws {
        let sessions = Sessions()
        let directory = testScratchRoot.appendingPathComponent("conversation-switch-seed-\(UUID().uuidString)")
        let persistence = LayoutPersistence(directory: directory)
        let seed = LayoutSnapshot(panes: [
            Pane(id: "db-1", kind: "db", title: "the seed's pane", frame: PaneFrame(x: 0, y: 0, width: 4, height: 4))
        ])
        try persistence.save(seed, for: LayoutScope(
            organization: org, project: placeA.project, environment: placeA.environment))
        let w = try await wiredWindow(sessions, persistence: persistence)
        let model = w.model
        show(placeA, in: model)
        #expect(await model.send("first job"))
        #expect(model.layoutSnapshot.panes.count == 1)

        await model.newConversation()
        _ = try await w.registry.dispatch(
            name: "pane_focus", params: .object(["id": .string("db-1")]), origin: .ui,
            caller: DispatchCaller(place: model.place, session: nil), confirmation: nil)
        // The hook runs on the observation pump, after the dispatch returns.
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(!model.sessionStarted, "the #264 hook ignores the seed's own panes")
        #expect(model.layoutSnapshot.panes.count == 1, "the new conversation starts from the seed")
        await model.shutdown()
    }

    // Fix round 1, item 1: the baseline is the seed as loaded for the Landing, not the canvas
    // left — a seed pane closed in the conversation comes back with the seed and is not work.
    @Test func theLandingSurvivesASeedPaneTheLeftConversationHadClosed() async throws {
        let sessions = Sessions()
        let directory = testScratchRoot.appendingPathComponent("conversation-switch-seed-\(UUID().uuidString)")
        let persistence = LayoutPersistence(directory: directory)
        let seed = LayoutSnapshot(panes: [
            Pane(id: "db-1", kind: "db", title: "the seed's pane", frame: PaneFrame(x: 0, y: 0, width: 4, height: 4))
        ])
        try persistence.save(seed, for: LayoutScope(
            organization: org, project: placeA.project, environment: placeA.environment))
        let w = try await wiredWindow(sessions, persistence: persistence)
        let model = w.model
        show(placeA, in: model)
        #expect(await model.send("first job"))
        let operatorCaller = DispatchCaller(place: model.place, session: nil)
        _ = try await w.registry.dispatch(
            name: "pane_close", params: .object(["id": .string("db-1")]), origin: .ui,
            caller: operatorCaller, confirmation: nil)
        #expect(await waitUntil { model.layoutSnapshot.panes.isEmpty })

        await model.newConversation()
        #expect(model.layoutSnapshot.panes.map(\.id) == ["db-1"], "the Landing draws over the seed")
        _ = try await w.registry.dispatch(
            name: "pane_focus", params: .object(["id": .string("db-1")]), origin: .ui,
            caller: operatorCaller, confirmation: nil)
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(!model.sessionStarted, "the seed's pane is not work begun, nothing was asked")
        #expect(model.currentAgent == nil)
        await model.shutdown()
    }

    // Fix round 1, item 2: a conversation put on screen ends the place's Landing, and its
    // baseline with it, so no later Landing inherits it.
    @Test func switchingBackClearsThePlacesLandingBaseline() async throws {
        let sessions = Sessions()
        let model = try await wiredWindow(sessions).model
        show(placeA, in: model)
        #expect(await model.send("first job"))
        let first = try #require(model.currentAgent)
        await model.newConversation()
        #expect(model.landingBaselineForTesting(placeA) != nil)

        await model.switchToConversation(first.id)

        #expect(model.currentAgent === first)
        #expect(model.landingBaselineForTesting(placeA) == nil)
        await model.shutdown()
    }

    @Test func aNewPaneOnTheLandingAfterNewConversationIsWorkBegunThere() async throws {
        let sessions = Sessions()
        let w = try await wiredWindow(sessions)
        let model = w.model
        show(placeA, in: model)
        #expect(await model.send("first job"))
        let first = try #require(model.currentAgent)
        await model.newConversation()
        await model.settleShownSocketsForTesting()
        let landingScope = await w.panes.activeScope

        _ = try await w.registry.dispatch(
            name: "pane_open", params: .object(["kind": .string("db")]), origin: .ui,
            caller: DispatchCaller(place: model.place, session: nil), confirmation: nil)

        #expect(await waitUntil { model.sessionStarted }, "a pane not on the seed is work begun")
        let second = try #require(model.currentAgent)
        #expect(second.id != first.id)
        #expect(second.layoutScope == landingScope, "the canvas the Landing drew over is the conversation's")
        #expect(model.layoutSnapshot.panes.count == 1)
        await model.shutdown()
    }

    @Test func newConversationOnALandingDoesNothing() async throws {
        let sessions = Sessions()
        let model = try await wiredWindow(sessions).model
        show(placeA, in: model)
        await model.activateLayoutForTesting()
        await model.settleShownSocketsForTesting()
        let reserved = try #require(model.shownSocketSessionIdForTesting(placeA))
        let sockets = sessions.issuedSockets.count

        await model.newConversation()
        await model.settleShownSocketsForTesting()

        #expect(model.currentAgent == nil && model.conversations.isEmpty)
        #expect(model.shownSocketSessionIdForTesting(placeA) == reserved)
        #expect(sessions.issuedSockets.count == sockets)
        model.markSessionStarted()
        #expect(model.currentAgent?.id == reserved, "the place's next conversation still takes it")
        await model.shutdown()
    }

    @Test func aTitleMatchingTwoConversationsIsRefusedNamingBoth() async throws {
        let sessions = Sessions()
        let model = try await wiredWindow(sessions).model
        show(placeA, in: model)
        #expect(await model.send("job"))
        let a = try #require(model.currentAgent?.id)
        await model.newConversation()
        #expect(await model.send("job"))
        let b = try #require(model.currentAgent?.id)

        await model.switchToConversation("job")

        #expect(model.status == "switch to job: two conversations here are called that — \(a), \(b)")
        #expect(model.currentAgent?.id == b, "nothing moved")
        await model.shutdown()
    }

    @Test func aTitleNamingOneConversationSwitchesToIt() async throws {
        let sessions = Sessions()
        let model = try await wiredWindow(sessions).model
        show(placeA, in: model)
        #expect(await model.send("the first job"))
        let first = try #require(model.currentAgent)
        await model.newConversation()
        #expect(await model.send("the second job"))

        await model.switchToConversation("the first job")
        #expect(model.currentAgent === first)

        await model.switchToConversation("nothing like it")
        #expect(model.status == "switch to nothing like it: no live conversation is called that")
        #expect(model.currentAgent === first)
        await model.shutdown()
    }

    @Test func theBrokerDrivesNewAndSwitch() async throws {
        let sessions = Sessions()
        let w = try await wiredWindow(sessions)
        let model = w.model
        show(placeA, in: model)
        #expect(await model.send("first job"))
        let first = try #require(model.currentAgent)

        let backgrounded = try await w.registry.dispatch(
            name: "session_new", params: .object([:]), origin: .ui,
            caller: DispatchCaller(place: model.place, session: nil), confirmation: nil)
        #expect(backgrounded == .object(["backgrounded": .null]))
        #expect(await waitUntil { model.currentAgent == nil })

        let switching = try await w.registry.dispatch(
            name: "session_switch", params: .object(["conversation": .string(first.id)]), origin: .ui,
            caller: DispatchCaller(place: model.place, session: nil), confirmation: nil)
        #expect(switching == .object(["switching": .string(first.id)]))
        #expect(await waitUntil { model.currentAgent === first })
        await model.shutdown()
    }

    @Test func aSessionNewOnAConversationsOwnSocketNamesThatConversation() async throws {
        let sessions = Sessions()
        let w = try await wiredWindow(sessions)
        let model = w.model
        show(placeA, in: model)
        #expect(await model.send("first job"))
        let first = try #require(model.currentAgent)
        let socketCaller = try #require(await caller(of: first.id, sessions))

        let backgrounded = try await w.registry.dispatch(
            name: "session_new", params: .object([:]), origin: .ui, caller: socketCaller, confirmation: nil)

        #expect(backgrounded == .object(["backgrounded": .string(first.id)]))
        #expect(await waitUntil { model.currentAgent == nil })
        await model.shutdown()
    }

    // Plan 1's final review, carried (a): two conversations in ONE place, so place routing and
    // conversation routing answer differently.
    @Test func aCallOnTheBackgroundConversationsSocketWritesItsCanvasNotTheScreens() async throws {
        let sessions = Sessions()
        let w = try await wiredWindow(sessions)
        let model = w.model
        show(placeA, in: model)
        #expect(await model.send("first job"))
        let first = try #require(model.currentAgent)
        await model.newConversation()
        #expect(await model.send("second job"))
        let second = try #require(model.currentAgent)
        #expect(first.place == second.place)
        let backgroundCaller = try #require(await caller(of: first.id, sessions))

        _ = try await w.registry.dispatch(
            name: "pane_open", params: .object(["kind": .string("db")]),
            origin: .agent, caller: backgroundCaller, confirmation: nil)

        #expect(model.layoutSnapshot.panes.isEmpty, "the screen's conversation's canvas is untouched")
        let firstScope = try #require(first.layoutScope)
        #expect(await snapshot(w.layout, in: firstScope).panes.count == 1)
        await model.shutdown()
    }

    @Test func switchingToAnotherOrgsConversationGoesThere() async throws {
        let ctx = TwoOrgContext()
        let harnesses = Harnesses()
        let model = await twoOrgWindow(ctx, harnesses)
        await model.refreshContext()
        let home = model.place
        #expect(await model.send("first in initech"))
        let first = try #require(model.currentAgent)
        await model.newConversation()
        #expect(await model.send("second in initech"))
        let second = try #require(model.currentAgent)
        let away = Place(organization: "globex", project: "web", environment: "dev")
        await model.goTo(away)
        try #require(model.place == away, "\(model.status)")
        try #require(harnesses.in(home).last).emit(.result(isError: false, text: "done"))
        #expect(await waitUntil { model.chips.contains { $0.conversation == second.id && $0.state == .done } })

        await model.switchToConversation(first.id)

        #expect(model.place == home, "\(model.status)")
        #expect(model.currentAgent === first, "that conversation, not the place's other one")
        #expect(model.chips.contains { $0.conversation == second.id && $0.state == .done },
                "the place's other conversation was not seen by the switch")
        await model.shutdown()
    }

    // Plan 1's final review, carried (b): a rename carries every idle conversation of the place,
    // the background ones too.
    @Test func aRenameCarriesTheBackgroundConversationsOfThePlaceToo() async throws {
        let sessions = Sessions()
        let ctx = RenameContext()
        let model = WindowModel.forTesting(
            scratchRoot: testScratchRoot, context: ContextStore(client: ctx),
            agentSocketFactory: sessions.socketFactory)
        await registerStandardActions(
            into: model.registryForTesting, context: ctx, panes: model.panesForTesting,
            db: nil, resumes: ResumeBroker())
        await model.refreshContext()
        let oldPlace = model.place
        model.markSessionStarted()
        let background = try #require(model.currentAgent)
        await model.newConversation()
        model.markSessionStarted()
        let onScreen = try #require(model.currentAgent)
        #expect(background.id != onScreen.id)

        #expect(await model.renameEnvironment(project: "p", projectPath: "/p", "dev", to: "local") == nil)

        let renamed = Place(organization: oldPlace.organization, project: "p", environment: "local")
        #expect(model.place == renamed)
        #expect(background.place == renamed && onScreen.place == renamed)
        #expect(model.currentAgent === onScreen)
        #expect(Set(model.liveConversations(in: renamed).map(\.id)) == [background.id, onScreen.id])
        #expect(model.liveConversations(in: oldPlace).isEmpty)
        await model.switchToConversation(background.id)
        #expect(model.currentAgent === background)
        await model.shutdown()
    }

    @Test func aRenameOnTheLandingAfterNewConversationCarriesTheReservedIdAndTheBackgroundOne() async throws {
        let sessions = Sessions()
        let ctx = RenameContext()
        let model = WindowModel.forTesting(
            scratchRoot: testScratchRoot, context: ContextStore(client: ctx),
            agentSocketFactory: sessions.socketFactory)
        await registerStandardActions(
            into: model.registryForTesting, context: ctx, panes: model.panesForTesting,
            db: nil, resumes: ResumeBroker())
        await model.refreshContext()
        let oldPlace = model.place
        model.markSessionStarted()
        let background = try #require(model.currentAgent)
        await model.newConversation()
        await model.settleShownSocketsForTesting()

        #expect(await model.renameEnvironment(project: "p", projectPath: "/p", "dev", to: "local") == nil)
        await model.settleShownSocketsForTesting()

        let renamed = Place(organization: oldPlace.organization, project: "p", environment: "local")
        #expect(background.place == renamed)
        #expect(model.currentAgent == nil && !model.sessionStarted, "still the Landing")
        model.markSessionStarted()
        let next = try #require(model.currentAgent)
        #expect(next.id != background.id && next.place == renamed)
        let caller = try #require(await caller(of: next.id, sessions))
        #expect(caller.place == renamed, "the reserved id's socket answers for the renamed place")
        await model.shutdown()
    }
}

/// A wakil-ctx that renames one environment of `p` and answers as the Go tools do: the active
/// place keeps its place.
private actor RenameContext: ToolCaller {
    var environment = "dev"

    private func ok(_ o: [String: JSONValue]) -> JSONValue { .object(["structuredContent": .object(o)]) }

    func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        func arg(_ key: String) -> String {
            guard case .object(let o) = arguments, case .string(let s)? = o[key] else { return "" }
            return s
        }
        switch name {
        case "get_context":
            return ok([
                "Org": .string("test-org"), "Environment": .string(environment),
                "ProjectKey": .string("p"), "Project": .object(["name": .string("p")]),
                "RootPaths": .array([]), "ActiveProvider": .string("test-provider"),
            ])
        case "config_tree": return ok(["projects": .array([])])
        case "rename_environment":
            if environment == arg("name") { environment = arg("newName") }
            return ok([:])
        default: return ok([:])
        }
    }
}

/// A window whose context reads and switches go to `ctx`, and whose org switch moves `ctx`.
@MainActor
private func twoOrgWindow(_ ctx: TwoOrgContext, _ harnesses: Harnesses) async -> WindowModel {
    let registry = ActionRegistry(
        journalDirectory: testScratchRoot.appendingPathComponent("conversation-switch-\(UUID().uuidString)"),
        sessionId: "conversation-switch")
    let panes = PaneStore()
    let resumes = ResumeBroker()
    await registerStandardActions(into: registry, context: ctx, panes: panes, db: nil, resumes: resumes)
    let model = WindowModel(
        registry: registry, panes: panes, layout: LayoutStore(), context: ContextStore(client: ctx),
        harnessFactory: { place, _, _ in harnesses.make(place) }, resumes: resumes, rootPath: "/tmp",
        providerId: "test-provider",
        lookupFactory: { _ in AlwaysSucceedsCredentialsLookupForTesting() },
        orgSwitcher: { org in await ctx.switchOrg(org) },
        environment: "")
    model.setOrganizationForTesting("initech")
    return model
}

/// `wakil-ctx` for two organisations, each with one project and environment active.
private actor TwoOrgContext: ToolCaller {
    private let projects: [String: [String: [String]]] = [
        "initech": ["api": ["staging"]],
        "globex": ["web": ["dev"]],
    ]
    private var active: [String: (project: String, environment: String)] = [
        "initech": ("api", "staging"),
        "globex": ("web", "dev"),
    ]
    private var org = "initech"

    func switchOrg(_ next: String) -> [String] {
        guard projects[next] != nil else { return ["\(next): no such organisation"] }
        org = next
        return []
    }

    func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        var argument = ""
        if case .object(let fields) = arguments, case .string(let value)? = fields["name"] { argument = value }
        let current = active[org]!
        switch name {
        case "get_context":
            return .object(["structuredContent": .object([
                "Org": .string(org), "Environment": .string(current.environment),
                "Project": .object(["name": .string(current.project)]), "ProjectKey": .string(current.project),
                "RootPaths": .array([]), "ActiveProvider": .string("test-provider"),
            ])])
        case "set_project":
            guard let environments = projects[org]?[argument] else { return refusal("no project \(argument)") }
            active[org] = (argument, environments[0])
            return .object([:])
        case "set_environment":
            active[org] = (current.project, argument)
            return .object([:])
        default:
            return refusal("\(name): not faked")
        }
    }

    private func refusal(_ text: String) -> JSONValue {
        .object(["isError": .bool(true), "content": .array([.object(["type": .string("text"), "text": .string(text)])])])
    }
}
