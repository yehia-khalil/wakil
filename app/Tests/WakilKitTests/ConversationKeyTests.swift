import Foundation
import Testing
@testable import WakilKit

// Conversations 1 of 3, Task 2: a place's agent is a conversation stored by its own id — the id
// Wakil mints before the first session, which a resume or a provider switch never moves — and the
// socket a place opens when shown is keyed by the conversation it reserves.

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

/// `PlaceAgentTests`' resumable window: `session_resume` registered, and an empty parent
/// transcript under the window's provider.
@MainActor
private func resumableWindow(_ sessions: Sessions) async throws -> WindowModel {
    let dir = testScratchRoot.appendingPathComponent("conversation-key-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let registry = ActionRegistry(journalDirectory: dir, sessionId: "conversation-key")
    let panes = PaneStore()
    let layout = LayoutStore()
    let broker = ResumeBroker()
    await registerStandardActions(
        into: registry, context: nil, panes: panes, db: nil, resumes: broker, layout: layout)
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
        confirmations: ConfirmationBroker(),
        agentSocketFactory: sessions.socketFactory, environment: "staging")
    model.setOrganizationForTesting(org)
    return model
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
}
