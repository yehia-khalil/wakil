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
    /// The broker the window drains; a test given its own parks the registry's requests there.
    let conversations: ConversationBroker
}

/// A window with the standard actions registered, driving `sessions`' harnesses and sockets.
@MainActor
private func wiredWindow(
    _ sessions: Sessions, confirmations: ConfirmationBroker = ConfirmationBroker(),
    socketFactory: AgentSocketFactory? = nil, parkedConversations: ConversationBroker? = nil
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
        conversationRequests: parkedConversations ?? conversations)
    await registerLayoutActions(into: registry, layout: layout, panes: panes)
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, persistence: nil, context: nil,
        harnessFactory: { place, _, socketPath in sessions.harness(place, socketPath) },
        resumes: resumes, rootPath: "/tmp", providerId: "test-provider",
        lookupFactory: { _ in AlwaysSucceedsCredentialsLookupForTesting() },
        confirmations: confirmations,
        conversationRequests: conversations,
        agentSocketFactory: socketFactory ?? sessions.socketFactory, environment: "staging")
    model.setOrganizationForTesting(org)
    return Wired(model: model, registry: registry, layout: layout, conversations: conversations)
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

/// Puts one editor tab on `a.go` into `scope`'s canvas — unsaved when `dirty` — as the removal
/// tests do (`WindowModelProjectLifecycleTests.dirtyTab`).
@MainActor
private func setTab(_ window: WindowModel, in scope: LayoutScope, dirty: Bool) async {
    let panes = window.panesForTesting
    let shown = await panes.screenScope
    if scope != shown { await panes.switchScope(to: scope) }
    await panes.updateEditor(paneId: "editor-9", create: true) { s in
        var t = EditorTab.file(path: "/p/a.go", root: "/p", text: "x", mtime: 1, language: "go")
        if dirty { t.text = "y" }
        s.tabs = [t]; s.active = 0
    }
    if scope != shown { await panes.switchScope(to: shown) }
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

        #expect(await waitUntil { model.chipCandidates.first?.state == .failed }, "\(model.chipCandidates)")
        #expect(model.chipCandidates.first?.conversation == dead.id)
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

    // MARK: Controller addition: an unsaved tab refuses the close

    @Test func anUnsavedTabInItsCanvasRefusesTheCloseUntilItIsSavedOrClosed() async throws {
        let sessions = Sessions()
        let model = try await wiredWindow(sessions).model
        show(placeA, in: model)
        #expect(await model.send("long job"))
        let agent = try #require(model.currentAgent)
        let scope = try #require(agent.layoutScope)
        await setTab(model, in: scope, dirty: true)

        await model.closeConversation()

        #expect(model.status == "long job has unsaved changes in a.go — save or close them first.")
        #expect(model.closeQuestion == nil, "refused, not asked, though its turn runs")
        #expect(model.conversation(id: agent.id) === agent && !sessions.harnesses.in(placeA)[0].stopped)

        await setTab(model, in: scope, dirty: false)
        await model.closeConversation()
        #expect(model.closeQuestion?.conversation == agent.id, "with the tab saved, the turn running asks")
        await model.answerCloseQuestion(close: true)
        #expect(model.conversation(id: agent.id) == nil && sessions.harnesses.in(placeA)[0].stopped)
        await model.shutdown()
    }

    // MARK: Fix round 1

    /// Invariant 4: a late call on a closed conversation's still-open connection names a
    /// conversation no longer live. It is refused whole (Rule 8) and writes into no canvas — not
    /// the place's next conversation's, not the Landing's — nor brings the closed one's back.
    @Test func aLateCallFromAClosedConversationIsRefusedAndTouchesNoCanvas() async throws {
        let sessions = Sessions()
        let w = try await wiredWindow(sessions)
        let model = w.model
        show(placeA, in: model)
        let first = try await idleConversation(model, sessions, "first job")
        await model.newConversation()
        let second = try await idleConversation(model, sessions, "second job")
        let oldCaller = second.caller
        let closedScope = try #require(second.layoutScope)
        let nextScope = try #require(first.layoutScope)
        await model.closeConversation()
        #expect(model.currentAgent === first)
        let before = await w.layout.scopes

        await #expect(throws: ActionError.callerGone(
            "pane_open",
            reason: "pane_open: the conversation this call came from was closed — nothing was done")) {
            _ = try await w.registry.dispatch(
                name: "pane_open", params: .object(["kind": .string("db")]),
                origin: .agent, caller: oldCaller, confirmation: nil)
        }

        let next = await ScopeRouting.$home.withValue(nextScope) { await w.layout.snapshot() }
        #expect(next.panes.isEmpty, "the next conversation's canvas is untouched")
        #expect(model.layoutSnapshot.panes.isEmpty)
        #expect(await w.layout.scopes == before && !before.contains(closedScope), "nothing re-created")
        await model.shutdown()
    }

    @Test func twoClosesAcrossTheUnsavedTabCheckAskOnceAndSayNothingElse() async throws {
        let sessions = Sessions()
        let model = try await wiredWindow(sessions).model
        show(placeA, in: model)
        #expect(await model.send("long job"))
        let id = try #require(model.currentAgent).id

        let one = Task { await model.closeConversation() }
        let two = Task { await model.closeConversation() }
        await one.value
        await two.value

        #expect(model.closeQuestion?.conversation == id)
        #expect(!model.status.contains("another conversation"), "the second is ignored (Rule 5): \(model.status)")
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
        let secondSession = try #require(second.sessionId)
        #expect(model.shownSocketSessionIdForTesting(placeA) == nil,
                "the conversation shown has its session, so no shown socket — \(secondSession)'s least of all")
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

    // MARK: Task 2: ⌘⇧W and ⌘K, quit

    /// Review of Task 1: File ▸ Close Conversation goes through the window's real dispatch — the
    /// registry, origin `ui` — pinned to the conversation on screen at the press, so a screen that
    /// moves before the request drains leaves the conversation switched to alone.
    @Test func fileCloseConversationDispatchesSessionClosePinnedAtThePress() async throws {
        let sessions = Sessions()
        let parked = ConversationBroker()
        let w = try await wiredWindow(sessions, parkedConversations: parked)
        let model = w.model
        show(placeA, in: model)
        let first = try await idleConversation(model, sessions, "first job")
        await model.newConversation()
        let second = try await idleConversation(model, sessions, "second job")
        await model.switchToConversation(first.id)

        await model.dispatchSessionClose()
        var requests = await parked.requests().makeAsyncIterator()
        let request = try #require(await requests.next())
        #expect(request == .close(conversation: first.id), "pinned to the screen's conversation when pressed")
        let journal = try await w.registry.journalEntries()
        #expect(journal.contains { $0.action == "session_close" && $0.origin == .ui })

        await model.switchToConversation(second.id)
        await w.conversations.request(request)

        #expect(await waitUntil { model.conversation(id: first.id) == nil })
        #expect(model.currentAgent === second, "the conversation switched to is untouched")
        #expect(sessions.harnesses.in(placeA)[0].stopped && !sessions.harnesses.in(placeA)[1].stopped)
        await model.shutdown()
    }

    /// ⌘K's row runs the same dispatch, pinned the same way.
    @Test func thePaletteRowClosesTheConversationOnScreenAtThePress() async throws {
        let sessions = Sessions()
        let parked = ConversationBroker()
        let w = try await wiredWindow(sessions, parkedConversations: parked)
        let model = w.model
        show(placeA, in: model)
        let first = try await idleConversation(model, sessions, "first job")
        await model.newConversation()
        let second = try await idleConversation(model, sessions, "second job")
        let context = await model.paletteContext()
        #expect(context.conversationOnScreen)

        let refusal = await model.performPalette(.runCommand(commandId: "global.closeConversation", value: ""))
        try #require(refusal == nil)
        var requests = await parked.requests().makeAsyncIterator()
        let request = try #require(await requests.next())
        #expect(request == .close(conversation: second.id))

        await model.switchToConversation(first.id)
        await w.conversations.request(request)

        #expect(await waitUntil { model.conversation(id: second.id) == nil })
        #expect(model.currentAgent === first)
        await model.shutdown()
    }

    @Test func quitStopsEveryConversationAndCancelsTheirWrites() async throws {
        let sessions = Sessions()
        let broker = ConfirmationBroker(timeout: .seconds(60))
        let model = try await wiredWindow(sessions, confirmations: broker).model
        show(placeA, in: model)
        let first = try await idleConversation(model, sessions, "first job")
        await model.newConversation()
        #expect(await model.send("second job"))
        let proposal = PendingMutation(
            action: "db_run_mutation", params: .object([:]), database: nil, statement: "DELETE FROM t",
            affectsEveryRow: true, origin: .agent, place: placeA, conversation: first.id)
        let parked = Task { await broker.request(proposal) }
        #expect(await waitUntil { model.parkedSlots[ProposalSlot(place: placeA, conversation: first.id)] != nil })

        await model.shutdown()

        #expect(sessions.harnesses.issued.count == 2)
        let outcome = await parked.value
        #expect(sessions.harnesses.issued.allSatisfy { $0.stopped } && outcome == .cancelled)
        #expect(sessions.issuedSockets.allSatisfy { $0.stopped })
    }

    // MARK: Carried from plan 1

    /// A session start in flight is a running agent for Invariant 5: a rename or removal landing
    /// while `makeSession` holds the place's shown socket, before `install`, is refused rather
    /// than leaving the session on a socket that answers for the old place.
    @Test func aSessionStartInFlightCountsAsRunningForRenameAndRemoval() async throws {
        let sessions = Sessions()
        let gate = HoldGate()
        let reached = Flag()
        let base = sessions.socketFactory
        let model = try await wiredWindow(sessions, socketFactory: { path, caller in
            if gate.isArmed {
                reached.set()
                await gate.wait()
            }
            return try await base(path, caller)
        }).model
        show(placeA, in: model)
        gate.arm()
        await model.activateLayoutForTesting()
        #expect(await waitUntil { reached.value }, "the shown socket's start is held")
        #expect(model.runningAgent(in: "api", environment: "staging") == nil, "nothing starts yet")

        let sending = Task { await model.send("first job") }
        // `makeSession` took the shown socket and waits on its start.
        #expect(await waitUntil { model.shownSocketSessionIdForTesting(placeA) == nil })

        #expect(model.runningAgent(in: "api", environment: "staging") == "agent (test-provider)")
        #expect(model.runningAgent(in: "api", environment: nil) == "agent (test-provider)")

        gate.release()
        #expect(await sending.value)
        #expect(model.runningAgent(in: "api", environment: "staging") == "agent (test-provider)")
        await model.shutdown()
    }

    // MARK: Final review

    /// A window whose first session start holds where `makeSession` waits on the shown socket's
    /// start, after it took that socket and before `install` — once: every later socket opens
    /// at once. Returns the gate that lets it go on.
    private func windowHoldingTheFirstStart(
        _ sessions: Sessions, confirmations: ConfirmationBroker = ConfirmationBroker()
    ) async throws -> (WindowModel, HoldGate) {
        let gate = HoldGate()
        let reached = Flag()
        let base = sessions.socketFactory
        let model = try await wiredWindow(sessions, confirmations: confirmations, socketFactory: { path, caller in
            if gate.isArmed, !reached.value {
                reached.set()
                await gate.wait()
            }
            return try await base(path, caller)
        }).model
        show(placeA, in: model)
        gate.arm()
        await model.activateLayoutForTesting()
        #expect(await waitUntil { reached.value }, "the shown socket's start is held")
        return (model, gate)
    }

    /// I1: a session still starting is work in flight — the operator's message on its way — so a
    /// close asks, and Keep it leaves the start to finish and the turn to go out.
    @Test func closingWhileTheSessionStartsAsksAndKeepItLetsTheTurnGoOut() async throws {
        let sessions = Sessions()
        let (model, gate) = try await windowHoldingTheFirstStart(sessions)
        let composer = ComposerModel(window: model, speech: SpeechRegistry(engines: []))
        let sending = Task { await model.send("first job") }
        #expect(await waitUntil { model.shownSocketSessionIdForTesting(placeA) == nil }, "makeSession took it")
        let agent = try #require(model.currentAgent)
        #expect(agent.harness == nil && !agent.turnInFlight, "nothing is installed yet")

        await model.closeConversation()

        #expect(model.closeQuestion == CloseConversationQuestion(conversation: agent.id))
        let focus = composer.focusToken
        await model.answerCloseQuestion(close: false)
        #expect(composer.focusToken == focus + 1, "Keep it gives the composer the keyboard back")
        gate.release()
        #expect(await sending.value)
        #expect(model.conversation(id: agent.id) === agent && agent.turnInFlight)
        #expect(!sessions.harnesses.in(placeA)[0].stopped)
        await model.shutdown()
    }

    /// I1: Close it during the start ends the conversation, and the session that finishes
    /// starting afterwards is stopped rather than installed on the closed one, where nothing — not
    /// a close, not quit — would reach it again.
    @Test func aStartThatFinishesAfterCloseItLeavesNoRunningHarness() async throws {
        let sessions = Sessions()
        let (model, gate) = try await windowHoldingTheFirstStart(sessions)
        let sending = Task { await model.send("first job") }
        #expect(await waitUntil { model.shownSocketSessionIdForTesting(placeA) == nil })
        let agent = try #require(model.currentAgent)
        await model.closeConversation()
        await model.answerCloseQuestion(close: true)
        #expect(model.conversation(id: agent.id) == nil)

        gate.release()

        #expect(await sending.value == false, "the turn goes nowhere")
        #expect(agent.harness == nil && agent.socket == nil && !agent.turnInFlight)
        let started = sessions.harnesses.in(placeA)
        #expect(!started.isEmpty && started.allSatisfy { $0.stopped }, "no claude is left running")
        let own = await sockets(of: agent.id, sessions)
        #expect(!own.isEmpty && own.allSatisfy { $0.stopped }, "nor its socket")
        await model.shutdown()
    }

    /// Re-review N1: the start finishes while Close it is itself suspended — in `stopSession`,
    /// on the broker, after it found no harness to stop and before the conversation leaves
    /// `conversations`. It is closed to installs from the moment the close began, so the session
    /// is stopped unstarted rather than installed where the close has already looked.
    @Test func aStartThatFinishesWhileCloseItIsUnderWayIsNeverInstalled() async throws {
        let sessions = Sessions()
        let broker = ConfirmationBroker()
        let (model, gate) = try await windowHoldingTheFirstStart(sessions, confirmations: broker)
        let sending = Task { await model.send("first job") }
        #expect(await waitUntil { model.shownSocketSessionIdForTesting(placeA) == nil })
        let agent = try #require(model.currentAgent)
        await model.closeConversation()
        #expect(model.closeQuestion?.conversation == agent.id)

        await broker.holdNextCancelForTesting()
        let closing = Task { await model.answerCloseQuestion(close: true) }
        #expect(await waitUntil { await broker.holdingCancelForTesting }, "the close waits in stopSession")
        #expect(model.conversation(id: agent.id) === agent, "still in the live map")
        gate.release()
        #expect(await waitUntil { !sessions.harnesses.in(placeA).isEmpty }, "the start finished")
        #expect(await sending.value == false, "the turn goes nowhere")
        await broker.releaseHeldCancelForTesting()
        await closing.value

        #expect(model.conversation(id: agent.id) == nil)
        #expect(agent.harness == nil && agent.socket == nil && !agent.turnInFlight)
        let harness = try #require(sessions.harnesses.in(placeA).first)
        #expect(!harness.log.contains { $0.hasPrefix("start:") }, "no claude was started")
        #expect(harness.stopped)
        let own = await sockets(of: agent.id, sessions)
        #expect(!own.isEmpty && own.allSatisfy { $0.stopped })
        await model.shutdown()
    }
}

/// A flag a test double raises from any executor.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    var value: Bool { lock.withLock { raised } }
    func set() { lock.withLock { raised = true } }
}
