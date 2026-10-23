import Foundation
import Testing
@testable import WakilKit

// Conversations 3 of 3, Task 1: `session_close` ends the conversation on screen — its agent
// stops, its panes close as on quit, it moves to Continue — asking first only when its turn is
// running or it has a write waiting; the place then shows its next live conversation or its
// Landing. And a conversation whose process died is shown failed, and its next turn resumes it.

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

@MainActor
private func show(_ place: Place, in model: WindowModel) {
    model.seedForTesting(
        providerId: "test-provider", rootPath: "/tmp/wakil-window-model-for-testing", thoughts: 0,
        project: place.project, environment: place.environment)
}

private struct Wired {
    let model: WindowModel
    let registry: ActionRegistry
    let layout: LayoutStore
}

/// A window with the standard actions registered, driving `sessions`' harnesses and sockets.
@MainActor
private func wiredWindow(
    _ sessions: Sessions, confirmations: ConfirmationBroker = ConfirmationBroker()
) async throws -> Wired {
    let dir = testScratchRoot.appendingPathComponent("conversation-close-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let registry = ActionRegistry(journalDirectory: dir, sessionId: "conversation-close")
    let panes = PaneStore()
    let layout = LayoutStore()
    let resumes = ResumeBroker()
    let conversations = ConversationBroker()
    await registerStandardActions(
        into: registry, context: nil, panes: panes, db: nil, resumes: resumes, layout: layout,
        conversationRequests: conversations)
    await registerLayoutActions(into: registry, layout: layout, panes: panes)
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, persistence: nil, context: nil,
        harnessFactory: { place, _, socketPath in sessions.harness(place, socketPath) },
        resumes: resumes, rootPath: "/tmp", providerId: "test-provider",
        lookupFactory: { _ in AlwaysSucceedsCredentialsLookupForTesting() },
        confirmations: confirmations,
        conversationRequests: conversations,
        agentSocketFactory: sessions.socketFactory, environment: "staging")
    model.setOrganizationForTesting(org)
    return Wired(model: model, registry: registry, layout: layout)
}

/// A `session_list` listing `ids`, newest first, and a `session_read` answering an empty
/// transcript, so a session can be listed in Continue and resumed.
private func registerPastSessions(_ ids: [String], into registry: ActionRegistry) async {
    await registry.register(Action(
        name: "session_list", description: "test double", kind: .read,
        schema: .object(["type": .string("object")]),
        handler: { _ in
            .object(["structuredContent": .object(["sessions": .array(ids.map {
                .object(["id": .string($0), "title": .string("past \($0)"), "provider": .string("test-provider")])
            })])])
        }))
    await registry.register(Action(
        name: "session_read", description: "test double", kind: .read,
        schema: .object(["type": .string("object")]),
        handler: { _ in
            .object(["structuredContent": .object([
                "cwd": .string("/tmp"), "provider": .string("test-provider"), "parent": .string(""),
                "truncated": .bool(false), "entries": .array([]),
            ])])
        }))
}

/// Every socket the window started that answers for `conversation`, oldest first.
private func sockets(of conversation: String, _ sessions: Sessions) async -> [RecordedSocket] {
    var out: [RecordedSocket] = []
    for socket in sessions.issuedSockets where await socket.caller().conversation == conversation {
        out.append(socket)
    }
    return out
}

/// Sends one turn on screen and lets it finish: the conversation is idle.
@MainActor
private func idleConversation(_ model: WindowModel, _ sessions: Sessions, _ text: String = "first job") async throws -> PlaceAgent {
    #expect(await model.send(text))
    let agent = try #require(model.currentAgent)
    try #require(sessions.harnesses.in(placeA).last).emit(.result(isError: false, text: "done"))
    #expect(await waitUntil { !agent.turnInFlight })
    return agent
}

@MainActor
struct ConversationCloseTests {
    @Test func closingAnIdleConversationAsksNothingAndShowsTheLanding() async throws {
        let sessions = Sessions()
        let w = try await wiredWindow(sessions)
        let model = w.model
        show(placeA, in: model)
        let agent = try await idleConversation(model, sessions)
        let scope = try #require(agent.layoutScope)
        #expect(await w.layout.scopes.contains(scope))

        await model.closeConversation()

        #expect(!(await w.layout.scopes.contains(scope)), "its canvas is let go of in memory")
        #expect(model.closeQuestion == nil && model.currentAgent == nil && !model.sessionStarted)
        #expect(model.conversation(id: agent.id) == nil && model.liveConversations().isEmpty)
        #expect(sessions.harnesses.in(placeA)[0].stopped)
        let own = await sockets(of: agent.id, sessions)
        #expect(!own.isEmpty && own.allSatisfy { $0.stopped }, "no socket of it is left open")
        await model.shutdown()
    }

    @Test func closingWithATurnRunningAsksOnceAndIgnoresASecondClose() async throws {
        let sessions = Sessions()
        let model = try await wiredWindow(sessions).model
        show(placeA, in: model)
        #expect(await model.send("long job"))
        let id = try #require(model.currentAgent).id

        await model.closeConversation()
        await model.closeConversation()

        #expect(model.closeQuestion == CloseConversationQuestion(conversation: id))
        #expect(CloseConversationQuestion.text
            == "Close this conversation? The agent is still working; what it is doing now stops.")
        #expect(CloseConversationQuestion.closeLabel == "Close it" && CloseConversationQuestion.keepLabel == "Keep it")
        #expect(!sessions.harnesses.in(placeA)[0].stopped, "nothing stops while it asks")

        await model.answerCloseQuestion(close: false)

        #expect(model.closeQuestion == nil)
        #expect(model.currentAgent?.id == id && !sessions.harnesses.in(placeA)[0].stopped)
        #expect(model.currentAgent?.turnInFlight == true, "its turn carries on")
        await model.shutdown()
    }

    @Test func aTurnThatEndsWhileAskedStillClosesWithoutASecondQuestion() async throws {
        let sessions = Sessions()
        let model = try await wiredWindow(sessions).model
        show(placeA, in: model)
        #expect(await model.send("long job"))
        let agent = try #require(model.currentAgent)
        await model.closeConversation()
        #expect(model.closeQuestion?.conversation == agent.id)

        try #require(sessions.harnesses.in(placeA).first).emit(.result(isError: false, text: "done"))
        #expect(await waitUntil { !agent.turnInFlight })
        await model.answerCloseQuestion(close: true)

        #expect(model.conversation(id: agent.id) == nil && model.closeQuestion == nil)
        #expect(model.currentAgent == nil && sessions.harnesses.in(placeA)[0].stopped)
        await model.shutdown()
    }

    @Test func aWaitingWriteAsksAndCloseItCancelsIt() async throws {
        let sessions = Sessions()
        let broker = ConfirmationBroker(timeout: .seconds(60))
        let model = try await wiredWindow(sessions, confirmations: broker).model
        show(placeA, in: model)
        let agent = try await idleConversation(model, sessions)
        let proposal = PendingMutation(
            action: "db_run_mutation", params: .object([:]), database: nil, statement: "DELETE FROM t",
            affectsEveryRow: true, origin: .agent, place: placeA, conversation: agent.id)
        let parked = Task { await broker.request(proposal) }
        #expect(await waitUntil { model.parkedSlots[ProposalSlot(place: placeA, conversation: agent.id)] != nil })

        await model.closeConversation()
        #expect(model.closeQuestion?.conversation == agent.id, "a write waiting is work in flight")
        await model.answerCloseQuestion(close: true)

        #expect(await parked.value == .cancelled)
        #expect(model.conversation(id: agent.id) == nil)
        await model.shutdown()
    }

    @Test func closingShowsThePlacesNextLiveConversation() async throws {
        let sessions = Sessions()
        let model = try await wiredWindow(sessions).model
        show(placeA, in: model)
        let first = try await idleConversation(model, sessions, "first job")
        await model.newConversation()
        let second = try await idleConversation(model, sessions, "second job")
        #expect(model.currentAgent === second)

        await model.closeConversation()

        #expect(model.currentAgent?.id == first.id && sessions.harnesses.in(placeA).count == 2, "no fork")
        #expect(model.sessionStarted && model.liveConversations(in: placeA).map(\.id) == [first.id])
        #expect(!sessions.harnesses.in(placeA)[0].stopped && sessions.harnesses.in(placeA)[1].stopped)
        #expect(model.landingBaselineForTesting(placeA) == nil, "no Landing is left over for it")
        await model.shutdown()
    }

    @Test func aClosedConversationIsInContinueAndNotInRunning() async throws {
        let sessions = Sessions()
        let w = try await wiredWindow(sessions)
        let model = w.model
        show(placeA, in: model)
        let agent = try await idleConversation(model, sessions)
        let sessionId = try #require(agent.sessionId)
        await registerPastSessions([sessionId, "other-1"], into: w.registry)
        #expect(await model.landingSessions().map(\.payload) == ["other-1"], "live: in Running only")

        await model.closeConversation()

        #expect(model.liveConversationRows(in: placeA).isEmpty)
        #expect(await model.landingSessions().map(\.payload).contains(sessionId))
        await model.shutdown()
    }

    @Test func aConversationWhoseProcessDiedOffScreenShowsItAndItsNextTurnResumesIt() async throws {
        let sessions = Sessions()
        let w = try await wiredWindow(sessions)
        let model = w.model
        await registerPastSessions([], into: w.registry)
        show(placeA, in: model)
        #expect(await model.send("first job"))
        let dead = try #require(model.currentAgent)
        let deadSession = try #require(dead.sessionId)
        await model.newConversation()
        #expect(await model.send("second job"))

        try #require(sessions.harnesses.in(placeA).first).finish()

        #expect(await waitUntil { model.chips.first?.state == .failed }, "\(model.chips)")
        #expect(model.chips.first?.conversation == dead.id)
        await model.switchToConversation(dead.id)
        #expect(model.currentAgent === dead)
        #expect(model.thoughts.last?.isError == true, "the failure is shown whole (Rule 8)")
        await model.settleShownSocketsForTesting()
        #expect(model.shownSocketSessionIdForTesting(placeA) == nil, "no stale socket opened for the dead session")

        #expect(await model.send("carry on"))

        let resumed = try #require(sessions.harnesses.in(placeA).last)
        #expect(sessions.harnesses.in(placeA).count == 3)
        #expect(resumed.log.first == "start:\(model.sessionId!):\(deadSession)", "a resume of it, forked")
        #expect(resumed.log.contains { $0.hasPrefix("send:") && $0.contains("carry on") }, "\(resumed.log)")
        #expect(model.currentAgent === dead && model.sessionId != deadSession)
        let live = await sockets(of: dead.id, sessions).filter { !$0.stopped }
        #expect(live.count == 1, "one socket answers for it: the fork's")
        await model.shutdown()
    }

    // MARK: The pump and the gesture

    @Test func sessionCloseParksOnTheBrokerAndClosesTheScreensConversation() async throws {
        let sessions = Sessions()
        let w = try await wiredWindow(sessions)
        let model = w.model
        show(placeA, in: model)
        let agent = try await idleConversation(model, sessions)

        let out = try await w.registry.dispatch(
            name: "session_close", params: .object([:]), origin: .ui,
            caller: DispatchCaller(place: model.place, session: nil), confirmation: nil)

        #expect(out == .object(["closing": .null]))
        #expect(await waitUntil { model.conversation(id: agent.id) == nil })
        #expect(model.currentAgent == nil)
        await model.shutdown()
    }

    @Test func anOperatorCloseActsOnTheConversationOnScreenAtThePress() async throws {
        #expect(WindowModel.screenPinnedActions.contains("session_close"))
        let sessions = Sessions()
        let w = try await wiredWindow(sessions)
        let model = w.model
        show(placeA, in: model)
        let first = try await idleConversation(model, sessions, "first job")
        await model.newConversation()
        let second = try await idleConversation(model, sessions, "second job")

        // Pinned to `first` when pressed; `second` is on screen by the time it drains.
        let out = try await w.registry.dispatch(
            name: "session_close", params: .object([:]), origin: .ui,
            caller: DispatchCaller(place: placeA, session: nil, conversation: first.id), confirmation: nil)

        #expect(out == .object(["closing": .string(first.id)]))
        #expect(await waitUntil { model.conversation(id: first.id) == nil })
        #expect(model.currentAgent === second, "the screen's conversation is untouched")
        #expect(!sessions.harnesses.in(placeA)[1].stopped)
        await model.shutdown()
    }

    @Test func aCloseOnALandingDoesNothing() async throws {
        let sessions = Sessions()
        let model = try await wiredWindow(sessions).model
        show(placeA, in: model)
        let first = try await idleConversation(model, sessions)
        await model.newConversation()
        let reserved = try #require(model.screenConversation)

        await model.closeConversation()
        await model.closeConversation(reserved)

        #expect(model.conversation(id: first.id) === first && !sessions.harnesses.in(placeA)[0].stopped)
        #expect(model.closeQuestion == nil && model.currentAgent == nil)
        await model.shutdown()
    }

    // MARK: Carried from plan 2

    @Test func closingDropsItsDraftAndLeavesNoSocketOrBaselineOfIt() async throws {
        let sessions = Sessions()
        let model = try await wiredWindow(sessions).model
        let composer = ComposerModel(window: model, speech: SpeechRegistry(engines: []))
        show(placeA, in: model)
        await model.activateLayoutForTesting()
        let first = try await idleConversation(model, sessions, "first job")
        await model.newConversation()
        let second = try await idleConversation(model, sessions, "second job")
        composer.edited(draft: "half a thought", caret: 14)
        await model.switchToConversation(first.id)
        #expect(composer.draftKeysForTesting.contains(second.id), "kept for its return")

        await model.switchToConversation(second.id)
        #expect(composer.draft == "half a thought")
        await model.closeConversation()

        #expect(model.currentAgent === first)
        #expect(!composer.draftKeysForTesting.contains(second.id), "its draft goes with it")
        #expect(composer.draft.isEmpty)
        #expect(model.landingBaselineForTesting(placeA) == nil)
        let own = await sockets(of: second.id, sessions)
        #expect(own.allSatisfy { $0.stopped }, "no orphan socket")
        await model.settleShownSocketsForTesting()
        #expect(model.shownSocketSessionIdForTesting(placeA) != second.id)
        await model.shutdown()
    }

    @Test func theLandingAfterAClosePlacesItsShownSocketUnderItsNewIdNotTheClosedOnes() async throws {
        let sessions = Sessions()
        let model = try await wiredWindow(sessions).model
        show(placeA, in: model)
        await model.activateLayoutForTesting()
        let closed = try await idleConversation(model, sessions)

        await model.closeConversation()
        await model.settleShownSocketsForTesting()

        let reserved = try #require(model.screenConversation)
        #expect(reserved != closed.id)
        #expect(model.shownSocketSessionIdForTesting(placeA) == reserved)
        let shown = try #require(await sockets(of: reserved, sessions).last)
        #expect(!shown.stopped)

        #expect(await model.send("next job"))

        #expect(model.currentAgent?.id == reserved)
        #expect(sessions.log.last == "harness:api:\(shown.path)", "the next session takes the Landing's socket")
        #expect(await sockets(of: closed.id, sessions).allSatisfy { $0.stopped })
        await model.shutdown()
    }
}
