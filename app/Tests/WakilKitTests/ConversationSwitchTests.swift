import Foundation
import Testing
@testable import WakilKit

// Conversations 2 of 3, Task 2: `session_new` puts the conversation on screen into the
// background, untouched, and shows the place's Landing; `session_switch` brings one back — same
// session, thread and canvas, no fork.

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

    // MARK: Task 3: the Landing's Running column and ⌘P's Running group

    @Test func runningListsThePlacesLiveConversationsNewestFirstWithTheirState() async throws {
        let sessions = Sessions()
        let model = try await wiredWindow(sessions).model
        show(placeA, in: model)
        #expect(await model.send("first job"))
        await model.newConversation()
        #expect(await model.send("second job"))
        await model.newConversation()

        #expect(model.liveConversationRows(in: placeA).map(\.title) == ["second job", "first job"])
        #expect(model.liveConversationRows(in: placeA).map(\.state) == [.working, .working])
        #expect(model.liveConversationRows(in: placeA).allSatisfy { !$0.onScreen }, "the Landing is on screen")
        #expect(model.liveConversationRows(in: placeB).isEmpty)
        #expect(model.liveConversationRows().count == 2)

        // A finished turn off screen is done, unseen — and, being the latest activity, first; one
        // seen and finished is idle.
        let first = try #require(model.liveConversations(in: placeA).first)
        try #require(sessions.harnesses.in(placeA).first).emit(.result(isError: false, text: "done"))
        #expect(await waitUntil { model.liveConversationRows(in: placeA).first?.state == .done })
        #expect(model.liveConversationRows(in: placeA).map(\.title) == ["first job", "second job"])
        await model.switchToConversation(first.id)
        let onScreen = try #require(model.liveConversationRows(in: placeA).first { $0.id == first.id })
        #expect(onScreen.state == .idle && onScreen.onScreen)
        await model.shutdown()
    }

    @Test func aResumedPastSessionLeavesContinueAndJoinsRunning() async throws {
        let sessions = Sessions()
        let w = try await wiredWindow(sessions)
        let model = w.model
        await registerPastSessions(["parent-1", "other-1"], into: w.registry)
        show(placeA, in: model)
        #expect(await model.landingSessions().map(\.payload) == ["parent-1", "other-1"])

        await model.continueSession("parent-1")
        #expect(await waitUntil { model.currentAgent?.sessionIds.contains("parent-1") == true })
        await model.newConversation()

        #expect(await model.landingSessions().map(\.payload).contains("parent-1") == false)
        #expect(await model.landingSessions().map(\.payload) == ["other-1"])
        #expect(model.liveConversationRows(in: placeA).count == 1, "it is listed under Running instead")
        let open = await model.paletteRootEntries(mode: .open) { _ in }
        #expect(!open.contains { $0.group == .sessions && $0.payloadSession == "parent-1" },
                "⌘P lists it once too, under Running")
        await model.shutdown()
    }

    @Test func aRunningRowsClickSwitchesThroughTheRegistryAsTheOperator() async throws {
        let sessions = Sessions()
        let w = try await wiredWindow(sessions)
        let model = w.model
        show(placeA, in: model)
        #expect(await model.send("first job"))
        let first = try #require(model.currentAgent)
        await model.newConversation()

        await model.switchToRunning(first.id)

        #expect(await waitUntil { model.currentAgent === first })
        let journal = try await w.registry.journalEntries()
        #expect(journal.contains { $0.action == "session_switch" && $0.origin == .ui })
        #expect(sessions.harnesses.in(placeA).count == 1, "no fork")
        await model.shutdown()
    }

    // MARK: Task 4: chips name their conversation; drafts and focus per conversation

    @Test func aBackgroundConversationInThePlaceOnScreenHasAChipNamingIt() async throws {
        let sessions = Sessions()
        let model = try await wiredWindow(sessions).model
        show(placeA, in: model)
        #expect(await model.send("fix the flaky login test"))
        let first = try #require(model.currentAgent)
        await model.newConversation()

        let chip = try #require(model.chips.first)
        #expect(chip.label == "initech · api · staging — fix the flaky login test")
        #expect(chip.identifier == "window.agentChip.initech/api/staging" && chip.state == .working)
        #expect(chip.id == first.id && chip.ordinal == 1)
        await model.shutdown()
    }

    @Test func aPlacesSecondConversationsChipIsOrdinal() async throws {
        let sessions = Sessions()
        let model = try await wiredWindow(sessions).model
        show(placeA, in: model)
        #expect(await model.send("first job"))
        await model.newConversation()
        #expect(await model.send("second job"))
        await model.newConversation()

        #expect(model.chips.map(\.identifier) == [
            "window.agentChip.initech/api/staging", "window.agentChip.initech/api/staging#2"])
        #expect(model.chips.map(\.title) == ["first job", "second job"])
        #expect(Set(model.chips.map(\.id)).count == 2, "two chips in one place never share an id")
        await model.shutdown()
    }

    @Test func aBackgroundConversationsProposalWaitsOnItsChipAndIsApprovedThere() async throws {
        let sessions = Sessions()
        let broker = ConfirmationBroker(timeout: .seconds(60))
        let model = try await wiredWindow(sessions, confirmations: broker).model
        show(placeA, in: model)
        #expect(await model.send("first job"))
        let a = try #require(model.currentAgent).id
        await model.newConversation()
        let proposal = PendingMutation(
            action: "db_run_mutation", params: .object([:]), database: nil, statement: "DELETE FROM t",
            affectsEveryRow: true, origin: .agent, place: placeA, conversation: a)
        let parked = Task { await broker.request(proposal) }

        #expect(await waitUntil { model.chips.first?.state == .waiting } && model.pending == nil)
        await model.switchToConversation(a)
        #expect(model.pending?.conversation == a)
        await model.confirmPending(typed: "confirm")   // the plane's own typed confirmation (Invariant 7)
        #expect(await parked.value == .approved)
        await model.shutdown()
    }

    @Test func newConversationTellsTheScreenItLeftAndFocusesTheComposer() async throws {
        let sessions = Sessions()
        let model = try await wiredWindow(sessions).model
        show(placeA, in: model)
        #expect(await model.send("first job"))
        let first = try #require(model.currentAgent)
        var changes: [(String, String, Bool)] = []
        model.onScreenChange = { changes.append(($0, $1, $2)) }

        await model.newConversation()

        #expect(model.screenKey.hasPrefix("landing:") && model.screenKey != "landing:")
        #expect(changes.count == 1)
        #expect(changes.first?.0 == first.id && changes.first?.1 == model.screenKey && changes.first?.2 == true)

        await model.switchToConversation(first.id)

        #expect(model.screenKey == first.id)
        #expect(changes.count == 2)
        #expect(changes.last?.1 == first.id && changes.last?.2 == true, "no focused pane: the composer")
        await model.shutdown()
    }

    @Test func aSwitchBackToACanvasWithAFocusedPaneHandsThePaneTheKeyboard() async throws {
        let sessions = Sessions()
        let w = try await wiredWindow(sessions)
        let model = w.model
        show(placeA, in: model)
        #expect(await model.send("first job"))
        let first = try #require(model.currentAgent)
        _ = try await w.registry.dispatch(
            name: "pane_open", params: .object(["kind": .string("db")]), origin: .ui,
            caller: DispatchCaller(place: model.place, session: nil), confirmation: nil)
        #expect(await waitUntil { model.layoutSnapshot.focusedId != nil })
        await model.newConversation()
        var changes: [(String, String, Bool)] = []
        model.onScreenChange = { changes.append(($0, $1, $2)) }
        let returns = model.keyboardReturns

        await model.switchToConversation(first.id)

        #expect(changes.count == 1 && changes.first?.2 == false, "its focused pane, not the composer")
        #expect(model.keyboardReturns == returns + 1)
        await model.shutdown()
    }

    @Test func fileNewConversationDispatchesSessionNewAsTheOperator() async throws {
        let sessions = Sessions()
        let w = try await wiredWindow(sessions)
        let model = w.model
        show(placeA, in: model)
        #expect(await model.send("first job"))

        await model.dispatchSessionNew()

        #expect(await waitUntil { !model.conversationOnScreen })
        let journal = try await w.registry.journalEntries()
        #expect(journal.contains { $0.action == "session_new" && $0.origin == .ui })
        #expect(await model.paletteContext().conversationOnScreen == false)
        await model.shutdown()
    }

    @Test func openModeListsRunningFirstAcrossPlaces() async throws {
        let sessions = Sessions()
        let model = try await wiredWindow(sessions).model
        show(placeB, in: model)
        #expect(await model.send("other place"))
        show(placeA, in: model)
        #expect(await model.send("first job"))
        await model.newConversation()

        let entries = await model.paletteRootEntries(mode: .open) { _ in }

        #expect(entries.first?.group == .running)
        let running = entries.filter { $0.group == .running }
        #expect(running.count == 2)
        let first = try #require(model.liveConversations(in: placeA).first)
        let row = try #require(running.first { $0.title == "first job" })
        #expect(row.subtitle == "initech · api · staging · working")
        #expect(row.verb == "switch to" && row.kindLabel == "conversation" && row.state == .working)
        #expect(row.action == .dispatch(action: "session_switch", params: .object(["conversation": .string(first.id)])))

        #expect(await model.performPalette(.run(row.action)) == nil)
        #expect(await waitUntil { model.currentAgent === first }, "picking it switches there, no fork")
        #expect(sessions.harnesses.in(placeA).count == 1)
        await model.shutdown()
    }

    // MARK: Task 5: `session_list` carries the live conversations

    @Test func sessionListCarriesTheLiveConversationsNarrowedByPlace() async throws {
        let sessions = Sessions()
        let registry = try await wiredWindow(sessions, context: PastSessionsContext())
        let model = registry.model
        show(placeB, in: model)
        #expect(await model.send("other place"))
        show(placeA, in: model)
        #expect(await model.send("first job"))
        try #require(sessions.harnesses.in(placeA).first).emit(.result(isError: false, text: "done"))
        #expect(await waitUntil { model.liveConversationRows(in: placeA).first?.state == .idle })
        await model.newConversation()
        #expect(await model.send("second job"))

        let out = try await registry.registry.dispatch(
            name: "session_list", params: .object(["project": .string("api")]), origin: .ui,
            caller: DispatchCaller(place: model.place, session: nil), confirmation: nil)
        #expect(liveTitles(out) == ["second job", "first job"])
        #expect(liveStates(out) == ["working", "idle"])
        #expect(pastIds(out) == ["s-past"], "Go's answer is kept as it was")

        let everywhere = try await registry.registry.dispatch(
            name: "session_list", params: .object([:]), origin: .ui,
            caller: DispatchCaller(place: model.place, session: nil), confirmation: nil)
        #expect(Set(liveTitles(everywhere)) == ["other place", "second job", "first job"],
                "every place of the organisation")
        let narrowed = try await registry.registry.dispatch(
            name: "session_list", params: .object(["project": .string("api"), "environment": .string("qa")]),
            origin: .ui,
            caller: DispatchCaller(place: model.place, session: nil), confirmation: nil)
        #expect(liveTitles(narrowed).isEmpty)
        let elsewhere = try await registry.registry.dispatch(
            name: "session_list", params: .object(["project": .string("api")]), origin: .ui,
            caller: DispatchCaller(place: Place(organization: "globex", project: "api", environment: "staging"), session: "s-g"),
            confirmation: nil)
        #expect(liveTitles(elsewhere).isEmpty, "the filter is the pinned caller's organisation")
        await model.shutdown()
    }

    // Fix round 1: `live` never spans two organisations (north-star non-goal "No query spans two
    // orgs") — the pinned caller's, else the one on screen, as Go's past half answers.
    @Test func sessionListsLiveConversationsAreOneOrganisationsOnly() async throws {
        let sessions = Sessions()
        let w = try await wiredWindow(sessions, context: PastSessionsContext())
        let model = w.model
        let globex = Place(organization: "globex", project: "web", environment: "staging")
        model.setOrganizationForTesting("globex")
        show(globex, in: model)
        #expect(await model.send("globex job"))
        model.setOrganizationForTesting(org)
        show(placeA, in: model)
        #expect(await model.send("initech job"))
        try #require(model.liveConversationRows().count == 2)

        func live(as caller: DispatchCaller) async throws -> [String] {
            liveTitles(try await w.registry.dispatch(
                name: "session_list", params: .object([:]), origin: .ui, caller: caller, confirmation: nil))
        }
        #expect(try await live(as: DispatchCaller(place: placeA, session: "s-a")) == ["initech job"],
                "a session pinned in initech sees none of globex's")
        #expect(try await live(as: DispatchCaller(place: globex, session: "s-g")) == ["globex job"],
                "a session pinned in globex sees only globex's, whatever the screen shows")
        #expect(try await live(as: DispatchCaller(place: model.place, session: nil)) == ["initech job"],
                "the operator's, unpinned: the organisation on screen")
        #expect(try await live(as: DispatchCaller(
            place: Place(organization: "", project: "", environment: ""), session: nil)) == ["initech job"],
                "no place at all (--dispatch): the organisation on screen, never every one")
        await model.shutdown()
    }

    // Review Focus 5: after ⌘N the screen's conversation is the one the Landing reserved, and its
    // socket is open — so the e2e channel, which picks by it, acts there, not in the backgrounded one.
    @Test func afterNewConversationTheScreensConversationIsTheReservedOnesSocket() async throws {
        let sessions = Sessions()
        let model = try await wiredWindow(sessions).model
        show(placeA, in: model)
        #expect(await model.send("first job"))
        let first = try #require(model.currentAgent)
        #expect(model.screenConversation == first.id)
        await model.newConversation()

        let reserved = try #require(model.screenConversation)
        #expect(reserved != first.id)
        #expect(model.screenKey == "landing:" + reserved)
        #expect(await waitUntil { await caller(of: reserved, sessions) != nil }, "the Landing's own socket")
        #expect(await caller(of: first.id, sessions) != nil, "the backgrounded one keeps its own")
        await model.shutdown()
    }

    // Final review, item 1 (Invariant 4): a gesture acts on the conversation the screen showed
    // when it was made. A switch drained while a Landing's message waits on the fast path does
    // not take the message: it is refused, whole, and given back to the Landing it was typed on.
    @Test func aLandingsMessageIsNotSentIntoAConversationSwitchedToMeanwhile() async throws {
        let sessions = Sessions()
        let model = try await wiredWindow(sessions).model
        show(placeA, in: model)
        #expect(await model.send("first job"))
        let x = try #require(model.currentAgent)
        await model.newConversation()
        let landing = model.screenKey
        let rowsBefore = x.thoughts
        let composer = ComposerModel(
            window: model, speech: SpeechRegistry(engines: []),
            fastPathRunner: { [model] _, _ in
                await model.switchToConversation(x.id)
                return .toAgent
            })
        composer.edited(draft: "landing message", caret: 15)

        await composer.submit()

        #expect(model.currentAgent === x, "the switch happened")
        #expect(x.thoughts == rowsBefore, "X's thread is untouched")
        // X's own harness, by identity, not by the order harnesses were made in; and every
        // harness's log, so a failure says which one heard what.
        let xHarness = try #require(x.harness as? ScriptedHarness)
        #expect(!xHarness.log.contains { $0.contains("landing message") },
                "\(sessions.harnesses.issued.map { ($0 === xHarness ? "X" : "other", $0.log) })")
        #expect(model.liveConversations(in: placeA).map(\.id) == [x.id], "no conversation was made")
        #expect(model.status.contains("not sent"), "\(model.status)")
        #expect(composer.draft.isEmpty, "the Landing's words are not staged on X")

        await model.newConversation()
        #expect(model.screenKey == landing)
        #expect(composer.draft == "landing message", "given back to the Landing it was typed on")
        await model.shutdown()
    }

    @Test func aTurnScopeOnALandingNamesTheIdItReserves() async throws {
        let sessions = Sessions()
        let model = try await wiredWindow(sessions).model
        show(placeA, in: model)
        #expect(model.screenConversation == nil, "unreserved")

        let scope = model.pinTurnScope()

        let reserved = try #require(model.screenConversation)
        #expect(scope.conversation == reserved)
        #expect(await model.send("hello", scope: scope))
        #expect(model.currentAgent?.id == reserved, "the Landing's own conversation, under its id")
        await model.shutdown()
    }

    @Test func anOperatorSessionNewPinnedToAConversationLeavesTheOneSwitchedToAlone() async throws {
        let sessions = Sessions()
        let parked = ConversationBroker()
        let w = try await wiredWindow(sessions, parkedConversations: parked)
        let model = w.model
        show(placeA, in: model)
        #expect(await model.send("first job"))
        let a = try #require(model.currentAgent)
        await model.newConversation(a.id)
        #expect(await model.send("second job"))
        let b = try #require(model.currentAgent)
        await model.switchToConversation(a.id)

        await model.dispatchSessionNew()
        var requests = await parked.requests().makeAsyncIterator()
        let request = try #require(await requests.next())
        #expect(request == .new(conversation: a.id), "pinned to the screen's conversation when made")

        await model.switchToConversation(b.id)
        await w.conversations.request(request)
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(model.currentAgent === b, "B is not backgrounded")
        #expect(model.conversation(id: a.id) === a)
        await model.shutdown()
    }

    @Test func anOperatorResumeIsPinnedAndRefusedWhenItsLandingHasGone() async throws {
        let sessions = Sessions()
        let parked = ResumeBroker()
        let w = try await wiredWindow(sessions, parkedResumes: parked)
        let model = w.model
        show(placeA, in: model)
        #expect(await model.send("first job"))
        let x = try #require(model.currentAgent)
        await model.newConversation()
        let reserved = try #require(model.screenConversation)

        await model.continueSession("past-1")
        var requests = await parked.requests().makeAsyncIterator()
        let request = try #require(await requests.next())
        #expect(request.conversation == reserved, "pinned to the Landing's reserved id")

        await model.switchToConversation(x.id)
        await model.resume(sessionId: request.sessionId, in: request.place, conversation: request.conversation)

        #expect(model.status.hasPrefix("resume past-1:") && model.status.contains("nothing was resumed"),
                "\(model.status)")
        #expect(model.liveConversations(in: placeA).map(\.id) == [x.id])
        #expect(sessions.harnesses.in(placeA).count == 1, "X was not forked")
        await model.shutdown()
    }

    // Item 3: an unreserved Landing renamed is its reserved id, never another conversation.
    @Test func anUnreservedLandingIsNotRenamedIntoAnotherConversation() async throws {
        let sessions = Sessions()
        let model = try await wiredWindow(sessions).model
        show(placeA, in: model)
        #expect(await model.send("first job"))
        let other = try #require(model.currentAgent)
        await model.newConversation()
        let reserved = try #require(model.screenConversation)
        let unreserved = WindowModel.unreservedLandingKey(placeA)

        #expect(model.isSameScreenRenamed(from: unreserved, to: "landing:" + reserved))
        #expect(model.isSameScreenRenamed(from: unreserved, to: reserved))
        #expect(!model.isSameScreenRenamed(from: unreserved, to: other.id))
        #expect(!model.isSameScreenRenamed(from: unreserved, to: "landing:" + other.id))
        await model.shutdown()
    }
}

/// A `session_list` listing `ids`, newest first, and a `session_read` answering an empty
/// transcript, so a Continue row can be resumed.
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

private extension PaletteEntry {
    /// The session a ⌘P Sessions row resumes.
    var payloadSession: String? {
        if case .resumeSession(let id) = action { return id }
        return nil
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

/// A wakil-ctx whose `list_sessions` answers one past session, as Go's shape does.
private struct PastSessionsContext: ToolCaller {
    func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        .object(["structuredContent": .object(["sessions": .array([
            .object(["id": .string("s-past"), "provider": .string("test-provider")]),
        ])])])
    }
}

private func liveRows(_ out: JSONValue) -> [[String: JSONValue]] {
    guard case .object(let o) = out, case .object(let s)? = o["structuredContent"],
          case .array(let rows)? = s["live"] else { return [] }
    return rows.compactMap { if case .object(let r) = $0 { return r }; return nil }
}

private func liveTitles(_ out: JSONValue) -> [String] {
    liveRows(out).compactMap { if case .string(let t)? = $0["title"] { return t }; return nil }
}

private func liveStates(_ out: JSONValue) -> [String] {
    liveRows(out).compactMap { if case .string(let t)? = $0["state"] { return t }; return nil }
}

private func pastIds(_ out: JSONValue) -> [String] {
    guard case .object(let o) = out, case .object(let s)? = o["structuredContent"],
          case .array(let rows)? = s["sessions"] else { return [] }
    return rows.compactMap { row in
        if case .object(let r) = row, case .string(let id)? = r["id"] { return id }
        return nil
    }
}
