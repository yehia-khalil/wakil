import Foundation
import Testing
@testable import WakilKit

// Conversations 1 of 3, Task 2: a place's agent is a conversation stored by its own id — the id
// Wakil mints before the first session, which a resume or a provider switch never moves — and the
// socket a place opens when shown is keyed by the conversation it reserves.

private let org = "initech"
private let placeA = Place(organization: org, project: "api", environment: "staging")
private let placeB = Place(organization: org, project: "billing", environment: "staging")

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

/// `PlaceAgentTests`' resumable window: `session_resume` registered, and an empty parent
/// transcript under the window's provider.
@MainActor
private func resumableWindow(_ sessions: Sessions) async throws -> WindowModel {
    try await wiredWindow(sessions).model
}

/// What a test drives a resumable window through: its registry (with the layout actions), its
/// layout store, and its resume and confirmation brokers.
private struct Wired {
    let model: WindowModel
    let registry: ActionRegistry
    let layout: LayoutStore
    let resumes: ResumeBroker
    let confirmations: ConfirmationBroker
}

@MainActor
private func wiredWindow(_ sessions: Sessions) async throws -> Wired {
    let dir = testScratchRoot.appendingPathComponent("conversation-key-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let registry = ActionRegistry(journalDirectory: dir, sessionId: "conversation-key")
    let panes = PaneStore()
    let layout = LayoutStore()
    let broker = ResumeBroker()
    await registerStandardActions(
        into: registry, context: nil, panes: panes, db: nil, resumes: broker, layout: layout)
    await registerLayoutActions(into: registry, layout: layout, panes: panes)
    let confirmations = ConfirmationBroker()
    await registry.register(Action(
        name: "session_read", description: "test double", kind: .read,
        schema: .object(["type": .string("object")]),
        handler: { _ in
            .object(["structuredContent": .object([
                "cwd": .string("/tmp"), "provider": .string("test-provider"), "parent": .string(""),
                "truncated": .bool(false), "entries": .array([]),
            ])])
        }))
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, persistence: nil, context: nil,
        harnessFactory: { place, _, socketPath in sessions.harness(place, socketPath) },
        resumes: broker, rootPath: "/tmp", providerId: "test-provider",
        lookupFactory: { _ in AlwaysSucceedsCredentialsLookupForTesting() },
        confirmations: confirmations,
        agentSocketFactory: sessions.socketFactory, environment: "staging")
    model.setOrganizationForTesting(org)
    return Wired(model: model, registry: registry, layout: layout, resumes: broker, confirmations: confirmations)
}

/// `scope`'s arrangement, read as a caller homed there reads it.
private func snapshot(_ layout: LayoutStore, in scope: LayoutScope) async -> LayoutSnapshot {
    await ScopeRouting.$home.withValue(scope) { await layout.snapshot() }
}

private func agentProposal(in place: Place, conversation: String?) -> PendingMutation {
    PendingMutation(
        action: "db_run_mutation", params: .object([:]), database: nil, statement: "DELETE FROM t",
        affectsEveryRow: true, origin: .agent, place: place, conversation: conversation)
}

@MainActor
struct ConversationKeyTests {
    @Test func aConversationsIdIsTheIdItsFirstSessionAndSocketCarry() async throws {
        let sessions = Sessions()
        let model = try await resumableWindow(sessions)
        show(placeA, in: model)
        #expect(await model.send("hello"))
        let agent = try #require(model.currentAgent)
        #expect(agent.sessionId == agent.id)
        #expect(sessions.issuedSockets.first?.path == agentSocketPath(agentSessionId: agent.id))
        #expect(await sessions.issuedSockets.first?.caller().conversation == agent.id)
        #expect(model.conversations[agent.id] === agent && model.agents[placeA] === agent)
        #expect(model.conversation(id: agent.id) === agent)
        #expect(model.liveConversations(in: placeA).map(\.id) == [agent.id])
        await model.shutdown()
    }

    @Test func aResumeKeepsTheConversationIdAndMovesTheSession() async throws {
        let sessions = Sessions()
        let model = try await resumableWindow(sessions)
        show(placeA, in: model)
        #expect(await model.send("hello"))
        let agent = try #require(model.currentAgent)
        let idBefore = agent.id

        await model.resume(sessionId: "parent-1")

        #expect(agent.id == idBefore)
        #expect(agent.sessionId != idBefore && agent.assignedSessionId == agent.sessionId)
        #expect(model.conversations[idBefore] === agent && model.conversations.count == 1)
        #expect(await sessions.issuedSockets.last?.caller().conversation == idBefore,
                "the fork's own socket still answers for its conversation")
        await model.shutdown()
    }

    @Test func aProviderSwitchKeepsTheConversationId() async throws {
        let sessions = Sessions()
        let model = try await resumableWindow(sessions)
        show(placeA, in: model)
        #expect(await model.send("hello"))
        let agent = try #require(model.currentAgent)
        let idBefore = agent.id
        try #require(sessions.harnesses.in(placeA).first).emit(.result(isError: false, text: "done"))
        #expect(await waitUntil { !agent.turnInFlight })

        await model.setProvider("other-provider")

        #expect(agent.id == idBefore)
        #expect(agent.sessionId != idBefore && agent.assignedSessionId == agent.sessionId)
        #expect(model.conversations[idBefore] === agent && model.conversations.count == 1)
        #expect(await sessions.issuedSockets.last?.caller().conversation == idBefore,
                "the new session's socket still answers for its conversation")
        await model.shutdown()
    }

    @Test func theShownSocketReservesTheIdThePlacesFirstConversationTakes() async throws {
        let sessions = Sessions()
        let model = try await resumableWindow(sessions)
        show(placeA, in: model)
        await model.activateLayoutForTesting()
        await model.settleShownSocketsForTesting()
        let reserved = try #require(model.shownSocketSessionIdForTesting(placeA))
        #expect(await sessions.issuedSockets.first?.caller().conversation == reserved)

        model.markSessionStarted()

        #expect(model.currentAgent?.id == reserved)
        #expect(model.currentAgent?.assignedSessionId == reserved)
        await model.shutdown()
    }

    // MARK: Task 3: calls, proposals, chips and turns resolve to their conversation

    @Test func aCallOnABackgroundConversationsSocketWritesItsOwnCanvas() async throws {
        let sessions = Sessions()
        let w = try await wiredWindow(sessions)
        let model = w.model
        show(placeA, in: model)
        #expect(await model.send("hello A"))
        show(placeB, in: model)
        #expect(await model.send("hello B"))
        let caller = try #require(await sessions.issuedSockets.first?.caller())
        #expect(caller.conversation == model.agents[placeA]?.id)

        _ = try await w.registry.dispatch(
            name: "pane_open", params: .object(["kind": .string("db")]),
            origin: .agent, caller: caller, confirmation: nil)

        #expect(model.layoutSnapshot.panes.isEmpty, "B's canvas is untouched")
        let scopeA = try #require(model.agents[placeA]?.layoutScope)
        #expect(await snapshot(w.layout, in: scopeA).panes.count == 1)
        await model.shutdown()
    }

    @Test func aResumeRequestNamingAConversationForksThatOne() async throws {
        let sessions = Sessions()
        let w = try await wiredWindow(sessions)
        let model = w.model
        show(placeA, in: model)
        #expect(await model.send("hello A"))
        let idA = try #require(model.currentAgent?.id)
        show(placeB, in: model)
        #expect(await model.send("hello B"))

        await w.resumes.request(ResumeRequest(sessionId: "parent-1", place: placeA, conversation: idA))

        #expect(await waitUntil { sessions.harnesses.in(placeA).count == 2 }, "\(model.status)")
        #expect(model.agents[placeA]?.id == idA)
        #expect(sessions.harnesses.in(placeB).count == 1)
        #expect(model.place == placeB)
        await model.shutdown()
    }

    @Test func aLateCallFromAReplacedSessionStillResolvesItsConversation() async throws {
        let sessions = Sessions()
        let w = try await wiredWindow(sessions)
        let model = w.model
        show(placeA, in: model)
        #expect(await model.send("hello A"))
        let idA = try #require(model.currentAgent?.id)
        let oldCaller = try #require(await sessions.issuedSockets.first?.caller())
        await model.resume(sessionId: "parent-1")
        #expect(model.currentAgent?.sessionId != oldCaller.session, "the session was replaced")
        show(placeB, in: model)
        #expect(await model.send("hello B"))

        #expect(oldCaller.conversation == idA)
        _ = try await w.registry.dispatch(
            name: "pane_open", params: .object(["kind": .string("db")]),
            origin: .agent, caller: oldCaller, confirmation: nil)

        #expect(model.layoutSnapshot.panes.isEmpty, "the screen's canvas is B's")
        let scopeA = try #require(model.conversation(id: idA)?.layoutScope)
        #expect(await snapshot(w.layout, in: scopeA).panes.count == 1, "A's conversation took it")
        await model.shutdown()
    }

    @Test func aChipWaitsOnItsOwnConversationsProposalOnly() async throws {
        let sessions = Sessions()
        let w = try await wiredWindow(sessions)
        let model = w.model
        show(placeA, in: model)
        #expect(await model.send("hello A"))
        let idA = try #require(model.currentAgent?.id)
        show(placeB, in: model)
        #expect(await model.send("hello B"))

        let proposal = agentProposal(in: placeA, conversation: idA)
        let parked = Task { await w.confirmations.request(proposal) }

        #expect(await waitUntil { model.chips.first?.state == .waiting })
        #expect(model.chips.first?.conversation == idA)
        #expect(model.parkedSlots[ProposalSlot(place: placeA, conversation: idA)]?.id == proposal.id)
        #expect(model.pending == nil, "B's plane shows nothing of A's")
        await w.confirmations.cancel(id: proposal.id)
        #expect(await parked.value == .cancelled)
        await model.shutdown()
    }

    @Test func theOnScreenConversationsProposalIsTheOnePending() async throws {
        let sessions = Sessions()
        let w = try await wiredWindow(sessions)
        let model = w.model
        show(placeA, in: model)
        #expect(await model.send("hello A"))
        let idA = try #require(model.currentAgent?.id)
        #expect(model.turnScope.conversation == idA, "a turn typed here goes to this conversation")

        let proposal = agentProposal(in: placeA, conversation: idA)
        let parked = Task { await w.confirmations.request(proposal) }

        #expect(await waitUntil { model.pending?.id == proposal.id })
        await model.cancelPending()
        #expect(await parked.value == .cancelled)
        await model.shutdown()
    }

    // MARK: Task 4: place-level paths walk conversations

    @Test func aRenamedPlacesIdleConversationKeepsItsIdUnderTheNewPlace() async throws {
        let sessions = Sessions()
        let window = try await renameWindow(sessions)
        let model = window.model
        let oldPlace = model.place
        model.markSessionStarted()
        let id = try #require(model.currentAgent?.id)

        #expect(await model.renameEnvironment(project: "p", projectPath: "/p", "dev", to: "local") == nil)

        let renamed = Place(organization: oldPlace.organization, project: "p", environment: "local")
        #expect(model.place == renamed)
        #expect(model.agents[renamed]?.id == id)
        #expect(model.conversation(id: id)?.place == renamed)
        #expect(model.agents[oldPlace] == nil)
        #expect(model.liveConversations(in: renamed).map(\.id) == [id])
    }

    @Test func aRenamedPlacesReservedIdAndShownSocketFollowItAndNoSecondSocketOpens() async throws {
        let sessions = Sessions()
        let window = try await renameWindow(sessions)
        let model = window.model
        let oldPlace = model.place
        await model.activateLayoutForTesting()
        await model.settleShownSocketsForTesting()
        let reserved = try #require(model.shownSocketSessionIdForTesting(oldPlace))
        #expect(sessions.issuedSockets.count == 1)

        #expect(await model.renameEnvironment(project: "p", projectPath: "/p", "dev", to: "local") == nil)
        await model.activateLayoutForTesting()
        await model.settleShownSocketsForTesting()

        let renamed = Place(organization: oldPlace.organization, project: "p", environment: "local")
        #expect(model.shownSocketSessionIdForTesting(renamed) == reserved, "found under the new place")
        #expect(model.shownSocketSessionIdForTesting(oldPlace) == nil)
        #expect(sessions.issuedSockets.count == 1, "no second socket opened")
        model.markSessionStarted()
        #expect(model.agents[renamed]?.id == reserved, "the new place's first conversation takes the reserved id")
        await model.shutdown()
    }

    @Test func shutdownStopsEveryConversationAndEveryReservedSocketOnce() async throws {
        let sessions = Sessions()
        let model = try await resumableWindow(sessions)
        show(placeA, in: model)
        #expect(await model.send("hello A"))
        show(placeB, in: model)
        await model.activateLayoutForTesting()
        await model.settleShownSocketsForTesting()
        #expect(sessions.issuedSockets.count == 2, "A's socket, and B's reserved and not taken")

        await model.shutdown()

        #expect(sessions.issuedSockets.allSatisfy { $0.stopped })
        #expect(sessions.harnesses.issued.allSatisfy { $0.stopped })
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

@MainActor
private func renameWindow(_ sessions: Sessions) async throws -> Wired {
    let ctx = RenameContext()
    let model = WindowModel.forTesting(
        scratchRoot: testScratchRoot, context: ContextStore(client: ctx),
        agentSocketFactory: sessions.socketFactory)
    await registerStandardActions(
        into: model.registryForTesting, context: ctx, panes: model.panesForTesting,
        db: nil, resumes: ResumeBroker())
    await model.refreshContext()
    return Wired(
        model: model, registry: model.registryForTesting, layout: LayoutStore(), resumes: ResumeBroker(),
        confirmations: ConfirmationBroker())
}
