import Foundation
import Testing
@testable import WakilKit

// Background agents, 3 of 4, Task 3: one agent per place, each with its own thread, turn and
// session, alive while the screen shows another place.

private let org = "initech"
private let placeA = Place(organization: org, project: "api", environment: "staging")
private let placeB = Place(organization: org, project: "billing", environment: "staging")

/// A harness the test drives: it records what it was told and emits what the test yields.
final class ScriptedHarness: AgentHarness, @unchecked Sendable {
    let place: Place
    private let lock = NSLock()
    private var entries: [String] = []
    private var directory: String?
    private let stream: AsyncStream<HarnessEvent>
    private let continuation: AsyncStream<HarnessEvent>.Continuation

    /// What `start` throws, if anything.
    private let startError: (any Error)?

    init(place: Place, startError: (any Error)? = nil) {
        self.place = place
        self.startError = startError
        (stream, continuation) = AsyncStream<HarnessEvent>.makeStream()
    }

    var log: [String] { lock.withLock { entries } }
    /// The working directory `start` was given.
    var workingDirectory: String? { lock.withLock { directory } }
    var stopped: Bool { log.contains("stop") }
    private func record(_ entry: String) { lock.withLock { entries.append(entry) } }

    func start(sessionId: String, resumingFrom parentSessionId: String?, workingDirectory: String) async throws {
        record("start:\(sessionId):\(parentSessionId ?? "-")")
        lock.withLock { directory = workingDirectory }
        if let startError { throw startError }
    }
    func send(_ text: String) async throws { record("send:\(text)") }
    func events() -> AsyncStream<HarnessEvent> { stream }
    func interrupt() async {}
    func stop() async {
        record("stop")
        continuation.finish()
    }
    func emit(_ event: HarnessEvent) { continuation.yield(event) }
    /// Ends the event stream unasked, as a `claude` process that went away does: no `stop`.
    func finish() { continuation.finish() }
}

/// Every harness the window asked for, in order, with the place it asked for.
final class Harnesses: @unchecked Sendable {
    private let lock = NSLock()
    private var made: [ScriptedHarness] = []
    var issued: [ScriptedHarness] { lock.withLock { made } }
    /// Set, every harness made from now on throws it from `start`.
    var startError: (any Error)? {
        get { lock.withLock { failure } }
        set { lock.withLock { failure = newValue } }
    }
    private var failure: (any Error)?
    func make(_ place: Place) -> AgentHarness? {
        let harness = ScriptedHarness(place: place, startError: startError)
        lock.withLock { made.append(harness) }
        return harness
    }
    func `in`(_ place: Place) -> [ScriptedHarness] { issued.filter { $0.place == place } }
}

/// One socket the window asked for: where, and whom it answers for.
final class RecordedSocket: AgentSocket, @unchecked Sendable {
    let path: String
    let caller: @Sendable () async -> DispatchCaller
    private let lock = NSLock()
    private var isStopped = false
    init(path: String, caller: @escaping @Sendable () async -> DispatchCaller) {
        self.path = path
        self.caller = caller
    }
    var stopped: Bool { lock.withLock { isStopped } }
    func stop() async { lock.withLock { isStopped = true } }
}

/// The sockets and harnesses a window asked for, in one log, so a test can read which came
/// first and which socket each harness was told to reach.
final class Sessions: @unchecked Sendable {
    let harnesses = Harnesses()
    private let lock = NSLock()
    private var sockets: [RecordedSocket] = []
    private var entries: [String] = []
    /// `socket:<path>` and `harness:<place.project>:<path>`, in order.
    var log: [String] { lock.withLock { entries } }
    var issuedSockets: [RecordedSocket] { lock.withLock { sockets } }

    /// Set, every socket start throws it.
    var socketError: (any Error)? {
        get { lock.withLock { socketFailure } }
        set { lock.withLock { socketFailure = newValue } }
    }
    private var socketFailure: (any Error)?
    /// Set, the harness factory has no harness to give.
    var refusesHarnesses: Bool {
        get { lock.withLock { refusing } }
        set { lock.withLock { refusing = newValue } }
    }
    private var refusing = false

    var socketFactory: AgentSocketFactory {
        { path, caller in
            if let error = self.socketError { throw error }
            let socket = RecordedSocket(path: path, caller: caller)
            self.lock.withLock {
                self.sockets.append(socket)
                self.entries.append("socket:\(path)")
            }
            return socket
        }
    }
    func harness(_ place: Place, _ socketPath: String) -> AgentHarness? {
        lock.withLock { entries.append("harness:\(place.project):\(socketPath)") }
        return refusesHarnesses ? nil : harnesses.make(place)
    }
}

@MainActor
private func waitUntil(_ condition: @MainActor () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(2 * testWaitLoadMultiplier)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    return await condition()
}

/// Puts `place` on screen the way the existing window tests do: the context fields, with no
/// `wakil-ctx` behind them.
@MainActor
private func show(_ place: Place, in model: WindowModel) {
    model.seedForTesting(
        providerId: "test-provider", rootPath: "/tmp/wakil-window-model-for-testing", thoughts: 0,
        project: place.project, environment: place.environment)
}

@MainActor
private func twoPlaceWindow(
    _ harnesses: Harnesses, persistence: LayoutPersistence? = nil,
    confirmations: ConfirmationBroker = ConfirmationBroker()
) -> WindowModel {
    WindowModel.forTesting(
        scratchRoot: testScratchRoot, organization: org,
        harnessFactory: { place, _ in harnesses.make(place) }, confirmations: confirmations,
        persistence: persistence)
}

/// A window whose agents can be resumed: `session_resume` registered, and an empty parent
/// transcript under the window's provider.
@MainActor
private func resumableWindow(
    _ sessions: Sessions, confirmations: ConfirmationBroker = ConfirmationBroker(),
    persistence: LayoutPersistence? = nil
) async throws -> (WindowModel, ActionRegistry) {
    let dir = testScratchRoot.appendingPathComponent("place-agent-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let registry = ActionRegistry(journalDirectory: dir, sessionId: "place-agent")
    let panes = PaneStore()
    let layout = LayoutStore()
    let broker = ResumeBroker()
    await registerStandardActions(
        into: registry, context: nil, panes: panes, db: nil, resumes: broker, layout: layout)
    // `resume` reads the parent's transcript first; an empty one, under the window's provider.
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
        registry: registry, panes: panes, layout: layout, persistence: persistence, context: nil,
        harnessFactory: { place, _, socketPath in sessions.harness(place, socketPath) },
        resumes: broker, rootPath: "/tmp", providerId: "test-provider",
        lookupFactory: { _ in AlwaysSucceedsCredentialsLookupForTesting() },
        confirmations: confirmations,
        agentSocketFactory: sessions.socketFactory, environment: "staging")
    model.setOrganizationForTesting(org)
    return (model, registry)
}

@MainActor
struct PlaceAgentTests {
    @Test func twoPlacesRunTwoAgentsAtOnce() async throws {
        let harnesses = Harnesses()
        let model = twoPlaceWindow(harnesses)

        show(placeA, in: model)
        #expect(await model.send("hello A"))
        show(placeB, in: model)
        #expect(await model.send("hello B"))

        #expect(harnesses.issued.map(\.place) == [placeA, placeB])
        #expect(harnesses.issued.allSatisfy { !$0.stopped }, "switching place stops no agent")
        #expect(model.agents.count == 2)
        #expect(model.agentPlaces == [placeA, placeB])
        #expect(model.agents[placeA]?.sessionId != model.agents[placeB]?.sessionId)
    }

    @Test func aBackgroundAgentsEventsLandInItsOwnThread() async throws {
        let harnesses = Harnesses()
        let model = twoPlaceWindow(harnesses)
        show(placeA, in: model)
        await model.send("hello A")
        show(placeB, in: model)
        await model.send("hello B")
        let agentA = try #require(model.agents[placeA])
        let rowsB = model.thoughts
        #expect(agentA.turnInFlight)

        let harnessA = try #require(harnesses.in(placeA).first)
        harnessA.emit(.assistantText("working on A"))
        harnessA.emit(.result(isError: false, text: "done A"))

        #expect(await waitUntil { !agentA.turnInFlight }, "A's `.result` ends A's turn")
        #expect(agentA.thoughts.map(\.detail).contains("working on A"))
        #expect(model.place == placeB)
        #expect(model.thoughts == rowsB, "the screen's thread is B's, and A's events never reach it")
        #expect(model.turnInFlight, "B's turn is still B's")
    }

    @Test func returningToAPlaceShowsItsThreadAndAgent() async throws {
        let harnesses = Harnesses()
        let model = twoPlaceWindow(harnesses)
        show(placeA, in: model)
        await model.send("hello A")
        let sessionA = model.sessionId
        show(placeB, in: model)
        await model.send("hello B")
        #expect(model.sessionId != sessionA)

        show(placeA, in: model)

        #expect(model.sessionId == sessionA)
        #expect(model.thoughts.map(\.detail) == ["hello A"])
        #expect(model.currentAgent === model.agents[placeA])
    }

    @Test func sendingInAPlaceWithAnAgentTalksToIt() async throws {
        let harnesses = Harnesses()
        let model = twoPlaceWindow(harnesses)
        show(placeA, in: model)
        await model.send("first")
        show(placeB, in: model)
        show(placeA, in: model)

        #expect(await model.send("second"))

        #expect(harnesses.issued.count == 1, "no second harness for a place that has one")
        let harnessA = try #require(harnesses.issued.first)
        #expect(harnessA.log.filter { $0.hasPrefix("send:") }.count == 2)
        #expect(harnessA.log.filter { $0.hasPrefix("start:") }.count == 1)
    }

    @Test func anAgentsResumeActsOnItsOwnPlace() async throws {
        let sessions = Sessions()
        let harnesses = sessions.harnesses
        let (model, registry) = try await resumableWindow(sessions)
        show(placeA, in: model)
        await model.send("hello A")
        show(placeB, in: model)
        await model.send("hello B")
        let agentA = try #require(model.agents[placeA])
        let agentB = try #require(model.agents[placeB])
        let (oldA, sessionB, rowsB) = (agentA.sessionId, agentB.sessionId, model.thoughts)

        // A's own agent asks to resume, through its own socket caller, while B is on screen.
        _ = try await registry.dispatch(
            name: "session_resume", params: .object(["id": .string("parent-1")]),
            origin: .agent, caller: agentA.caller, confirmation: nil)

        #expect(await waitUntil { agentA.sessionId != oldA }, "A's session is replaced")
        let forkA = try #require(harnesses.in(placeA).last)
        #expect(harnesses.in(placeA).count == 2)
        #expect(forkA.log.contains { $0.hasSuffix(":parent-1") }, "\(forkA.log)")
        #expect(harnesses.in(placeA).first?.stopped == true, "A's old harness is stopped")
        #expect(harnesses.in(placeB).count == 1)
        #expect(harnesses.in(placeB).first?.stopped == false, "B's agent is untouched")
        #expect(agentB.sessionId == sessionB)
        #expect(model.place == placeB)
        #expect(model.thoughts == rowsB)
    }

    /// Ruling 2: an agent's pane in a place the operator has left reaches that place's file,
    /// not only memory.
    @Test func aBackgroundAgentsPaneReachesItsPlacesFileOnDisk() async throws {
        let directory = testScratchRoot.appendingPathComponent("place-agent-layouts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let persistence = LayoutPersistence(directory: directory)
        let harnesses = Harnesses()
        let model = twoPlaceWindow(harnesses, persistence: persistence)
        show(placeA, in: model)
        await model.send("hello A")
        show(placeB, in: model)
        await model.send("hello B")
        let agentA = try #require(model.agents[placeA])
        let scopeA = try #require(agentA.layoutScope)

        let opened = try await model.registryForTesting.dispatch(
            name: "pane_open", params: .object(["kind": .string("db"), "title": .string("A's pane")]),
            origin: .agent, caller: agentA.caller, confirmation: nil)
        guard case .object(let fields) = opened, case .string(let id)? = fields["id"] else {
            Issue.record("pane_open answered \(opened)")
            return
        }

        #expect(await waitUntil {
            persistence.load(for: scopeA).snapshot?.panes.contains { $0.id == id } == true
        }, "A's file holds the pane its agent opened while B was on screen")
        #expect(!model.layoutSnapshot.panes.contains { $0.id == id }, "the screen's canvas is B's")
    }

    /// Shells are keyed by the scope they were opened in (ruling 3), so a first turn that files
    /// the Landing's canvas under a conversation takes its shells along: the operator's keys
    /// still reach a shell opened before the turn.
    @Test func aShellOpenedOnTheLandingStillAnswersAfterTheFirstTurn() async throws {
        let harnesses = Harnesses()
        let model = twoPlaceWindow(harnesses)
        show(placeA, in: model)
        await model.activateLayoutForTesting()
        let pane = await model.openTerminalForTesting(path: NSTemporaryDirectory())
        #expect(!pane.isEmpty)

        await model.send("hello A")
        #expect(model.lineageRoot != nil, "the turn filed the canvas under a conversation")
        await model.sendToTerminalForTesting(pane: pane, text: "printf landed\n")

        #expect(await waitUntil { await model.screenContainsForTesting(pane: pane, "landed") })
        await model.shutdown()
    }

    // MARK: Task 4: each agent has its own socket

    @Test func twoAgentsGetTwoSocketsEachAnsweringForItsOwnPlace() async throws {
        let sessions = Sessions()
        let (model, _) = try await resumableWindow(sessions)
        show(placeA, in: model)
        await model.send("hello A")
        show(placeB, in: model)
        await model.send("hello B")

        let sockets = sessions.issuedSockets
        #expect(sockets.count == 2)
        #expect(Set(sockets.map(\.path)).count == 2, "two agents, two paths")
        let sessionA = try #require(model.agents[placeA]?.sessionId)
        let sessionB = try #require(model.agents[placeB]?.sessionId)
        // Each socket is started before its harness, and that harness is told to reach it.
        #expect(sessions.log == [
            "socket:\(sockets[0].path)", "harness:api:\(sockets[0].path)",
            "socket:\(sockets[1].path)", "harness:billing:\(sockets[1].path)",
        ])
        let callerA = await sockets[0].caller()
        let callerB = await sockets[1].caller()
        #expect(callerA.place == placeA)
        #expect(callerA.session == sessionA)
        #expect(callerB.place == placeB)
        #expect(callerB.session == sessionB)
        #expect(sockets[0].path.hasSuffix("wakil-\(sessionA).sock"))
        #expect(sockets.allSatisfy { !$0.stopped })
    }

    @Test func droppingAnAgentStopsItsSocket() async throws {
        let sessions = Sessions()
        let (model, _) = try await resumableWindow(sessions)
        show(placeA, in: model)
        await model.send("hello A")
        show(placeB, in: model)
        await model.send("hello B")
        show(placeA, in: model)
        let (oldA, socketB) = (sessions.issuedSockets[0], sessions.issuedSockets[1])

        await model.resume(sessionId: "parent-1")

        let forkA = try #require(model.agents[placeA]?.sessionId)
        let sockets = sessions.issuedSockets
        #expect(sockets.count == 3, "the fork answers on a new socket")
        #expect(oldA.stopped, "A's old session's socket is stopped with its harness")
        let newA = try #require(sockets.last)
        #expect(!newA.stopped)
        #expect(newA.path != oldA.path)
        #expect(await newA.caller().session == forkA)
        #expect(await newA.caller().place == placeA)
        #expect(sessions.log.suffix(2) == ["socket:\(newA.path)", "harness:api:\(newA.path)"])
        #expect(!socketB.stopped, "B's socket is untouched")

        await model.shutdown()
        #expect(newA.stopped && socketB.stopped, "no socket outlives the window")
    }

    @Test func theSocketPathFitsTheUnixLimit() throws {
        let agent = UUID().uuidString
        let path = agentSocketPath(agentSessionId: agent)
        // `sun_path` is 104 bytes, its terminator among them.
        #expect(path.utf8.count < 104, "\(path) is \(path.utf8.count) bytes")
        #expect(path.hasPrefix(FileManager.default.temporaryDirectory.path))
        #expect(path.hasSuffix("/wakil-\(agent).sock"), "the whole session id: no two sessions share a path")
        _ = try makeUnixSocketAddress(path: path)

        // The longest directory that still fits: 55 characters, 7 more than this machine's
        // per-user temporary directory.
        let longest = URL(fileURLWithPath: "/" + String(repeating: "d", count: 54), isDirectory: true)
        #expect(longest.path.utf8.count == 55)
        let worst = agentSocketPath(agentSessionId: agent, directory: longest)
        #expect(worst.utf8.count == 103)
        _ = try makeUnixSocketAddress(path: worst)
    }

    /// The first turn's harness starts in the root and on the provider of the place it was typed
    /// in, even when the operator moves to another project before it starts. Held at the
    /// credential lookup, the last suspension before the start; the canvas's activation before
    /// it is the same case.
    @Test func aFirstTurnStartsInItsOwnPlacesRootWhenTheScreenMovesBeforeItStarts() async throws {
        let harnesses = Harnesses()
        let providers = ProviderLog()
        let lookup = HeldLookup()
        let model = WindowModel.forTesting(
            scratchRoot: testScratchRoot, organization: org,
            harnessFactory: { place, selection in
                providers.append(selection.id)
                return harnesses.make(place)
            }, lookup: lookup)
        model.seedForTesting(
            providerId: "test-provider", rootPath: "/src/api", thoughts: 0,
            project: placeA.project, environment: placeA.environment)

        let sending = Task { await model.send("hello A") }
        #expect(await waitUntil { lookup.calls == 1 }, "the send is starting the session")
        model.seedForTesting(
            providerId: "other-provider", rootPath: "/src/billing", thoughts: 0,
            project: placeB.project, environment: placeB.environment)
        lookup.release()
        #expect(await sending.value)

        let harnessA = try #require(harnesses.in(placeA).first)
        #expect(harnessA.workingDirectory == "/src/api")
        #expect(providers.ids == ["test-provider"])
        #expect(model.agents[placeA]?.providerId == "test-provider")
    }

    // MARK: Fix round 1

    /// Rule 7: a socket that will not start does not refuse the session. The agent runs without
    /// Wakil's own tools, and the status says so.
    @Test func aSocketThatWillNotStartLeavesTheAgentRunningWithoutWakilsTools() async throws {
        let sessions = Sessions()
        sessions.socketError = MCPTransportError.pathTooLong("/too/long")
        let (model, _) = try await resumableWindow(sessions)
        show(placeA, in: model)

        #expect(await model.send("hello A"))

        let harnessA = try #require(sessions.harnesses.in(placeA).first)
        #expect(harnessA.log.contains { $0.hasPrefix("start:") })
        #expect(harnessA.log.contains("send:hello A"))
        #expect(model.agents[placeA].map { $0.socket == nil } == true)
        #expect(model.status.contains("cannot reach Wakil's own tools"), "\(model.status)")
        #expect(model.status.contains("too/long"), "the reason is shown whole: \(model.status)")
    }

    /// The socket the place opened when it was shown is the place's, not the refused session's:
    /// it stays listening for the next start, which takes it.
    @Test func aHarnessTheFactoryRefusesLeavesThePlaceItsShownSocket() async throws {
        let sessions = Sessions()
        sessions.refusesHarnesses = true
        let (model, _) = try await resumableWindow(sessions)
        show(placeA, in: model)

        #expect(await model.send("hello A") == false)

        let socket = try #require(sessions.issuedSockets.first)
        #expect(!socket.stopped, "the place on screen keeps its channel")
        #expect(model.agents[placeA].map { $0.socket == nil } == true)

        sessions.refusesHarnesses = false
        #expect(await model.send("hello again"))
        #expect(sessions.issuedSockets.count == 1, "the next start takes the same socket")
        #expect(model.agents[placeA]?.socket as? RecordedSocket === socket)
        await model.shutdown()
        #expect(socket.stopped)
    }

    @Test func aResumeWhoseForkFailsToStartStopsItsSocket() async throws {
        let sessions = Sessions()
        let (model, _) = try await resumableWindow(sessions)
        show(placeA, in: model)
        await model.send("hello A")
        let running = try #require(sessions.issuedSockets.first)
        sessions.harnesses.startError = HarnessTestError.refused

        await model.resume(sessionId: "parent-1")

        let fork = try #require(sessions.issuedSockets.last)
        #expect(fork !== running)
        #expect(fork.stopped, "the fork's socket goes with the fork")
        #expect(!running.stopped, "the running session keeps its socket")
        #expect(model.agents[placeA]?.socket as? RecordedSocket === running)
    }

    @Test func aProviderSwitchWhoseSessionFailsToStartStopsItsSocket() async throws {
        let sessions = Sessions()
        let (model, _) = try await resumableWindow(sessions)
        show(placeA, in: model)
        await model.send("hello A")
        let agentA = try #require(model.agents[placeA])
        try #require(sessions.harnesses.in(placeA).first).emit(.result(isError: false, text: "done"))
        #expect(await waitUntil { !agentA.turnInFlight })
        let running = try #require(sessions.issuedSockets.first)
        sessions.harnesses.startError = HarnessTestError.refused

        await model.setProvider("other-provider")

        let fresh = try #require(sessions.issuedSockets.last)
        #expect(fresh !== running)
        #expect(fresh.stopped, "the new session's socket goes with it")
        #expect(!running.stopped)
        #expect(agentA.socket as? RecordedSocket === running)
    }

    /// The ruling `send` follows, for a provider switch: the session replaced, its root and the
    /// provider it is switched from are the ones on screen when the switch was asked for.
    @Test func aProviderSwitchStartsInItsOwnPlacesRootWhenTheScreenMovesDuringTheLookup() async throws {
        let harnesses = Harnesses()
        let lookup = HeldLookup()
        let model = WindowModel.forTesting(
            scratchRoot: testScratchRoot, organization: org,
            harnessFactory: { place, _ in harnesses.make(place) }, lookup: lookup)
        model.seedForTesting(
            providerId: "test-provider", rootPath: "/src/api", thoughts: 0,
            project: placeA.project, environment: placeA.environment)

        let switching = Task { await model.setProvider("other-provider") }
        #expect(await waitUntil { lookup.calls == 1 })
        model.seedForTesting(
            providerId: "test-provider", rootPath: "/src/billing", thoughts: 0,
            project: placeB.project, environment: placeB.environment)
        lookup.release()
        await switching.value

        let harnessA = try #require(harnesses.in(placeA).first)
        #expect(harnessA.workingDirectory == "/src/api")
        #expect(harnesses.in(placeB).isEmpty)
        #expect(model.agents[placeB] == nil)
        #expect(model.agents[placeA]?.providerId == "other-provider")
    }

    /// Rule 5: a second turn typed while the place's session is still starting rides on that
    /// session, as a turn typed while one is in flight goes to the running harness. One harness,
    /// one socket, both turns sent.
    @Test func twoFirstTurnsInOnePlaceStartOneSession() async throws {
        let harnesses = Harnesses()
        let sessions = Sessions()
        let lookup = HeldLookup()
        let model = WindowModel.forTesting(
            scratchRoot: testScratchRoot, organization: org,
            harnessFactory: { place, _ in harnesses.make(place) }, lookup: lookup,
            agentSocketFactory: sessions.socketFactory)
        show(placeA, in: model)

        let first = Task { await model.send("one") }
        #expect(await waitUntil { lookup.calls == 1 }, "the first send is starting the session")
        let second = Task { await model.send("two") }
        // Room for the second send to reach the start, where it used to begin its own.
        for _ in 0..<200 { await Task.yield() }
        lookup.release()

        #expect(await first.value)
        #expect(await second.value)
        #expect(harnesses.issued.count == 1, "one harness for one place")
        #expect(sessions.issuedSockets.count == 1, "one socket for one session")
        #expect(lookup.calls == 1)
        let harness = try #require(harnesses.issued.first)
        #expect(harness.log.filter { $0.hasPrefix("start:") }.count == 1)
        #expect(harness.log.filter { $0.hasPrefix("send:") } == ["send:one", "send:two"])
    }
}

private enum HarnessTestError: Error { case refused }

/// A credentials lookup whose first call is held until `release()`; later calls answer at once.
private final class HeldLookup: ProviderCredentialsLookup, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var released = false
    private var held: CheckedContinuation<Void, Never>?
    var calls: Int { lock.withLock { count } }

    func credentials(forProvider id: String) async throws -> ProviderCredentials {
        let first: Bool = lock.withLock {
            count += 1
            return count == 1
        }
        if first {
            await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
                let resumeNow: Bool = lock.withLock {
                    if released { return true }
                    held = k
                    return false
                }
                if resumeNow { k.resume() }
            }
        }
        return ProviderCredentials(claudePath: "/usr/bin/true", configDir: "/dev/null", oauthToken: "test-only")
    }

    func release() {
        let parked: CheckedContinuation<Void, Never>? = lock.withLock {
            released = true
            defer { held = nil }
            return held
        }
        parked?.resume()
    }
}

private final class ProviderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var made: [String] = []
    var ids: [String] { lock.withLock { made } }
    func append(_ id: String) { lock.withLock { made.append(id) } }
}

/// An agent's proposal parked in `place`, as `MCPServer.parkForConfirmation` parks one.
/// `conversation`: the one that parks it, as a socket caller names its own.
private func agentProposal(in place: Place, conversation: String) -> PendingMutation {
    PendingMutation(
        action: "db_run_mutation", params: .object([:]), database: nil, statement: "DELETE FROM t",
        affectsEveryRow: true, origin: .agent, place: place, conversation: conversation)
}

/// Waits for `request` to answer, cancelling `proposal` first when it is still parked after
/// `waitUntil`'s bound, so a broken build fails the test rather than hanging it.
@MainActor
private func decision(
    of request: Task<ConfirmationDecision, Never>, _ proposal: PendingMutation, in broker: ConfirmationBroker
) async -> ConfirmationDecision? {
    if await waitUntil({ await broker.current(for: proposal.place)?.id != proposal.id }) {
        return await request.value
    }
    await broker.cancel(id: proposal.id)
    _ = await request.value
    return nil
}

/// Final review I2: an agent's proposal never expires (R1), so one left by a session that is
/// gone would hold its place's slot for ever. Stopping or replacing the session ends it.
@MainActor
struct PlaceApprovalTests {
    @Test func replacingAPlacesSessionCancelsItsAgentsWaitingApproval() async throws {
        let sessions = Sessions()
        let broker = ConfirmationBroker()
        let (model, _) = try await resumableWindow(sessions, confirmations: broker)
        show(placeA, in: model)
        #expect(await model.send("hello A"))
        let conversationA = try #require(model.agents[placeA]?.id)
        let old = agentProposal(in: placeA, conversation: conversationA)
        let parked = Task { await broker.request(old) }
        #expect(await waitUntil { await broker.current(for: placeA)?.id == old.id })

        await model.resume(sessionId: "parent-1")

        #expect(sessions.harnesses.in(placeA).count == 2, "the session was replaced: \(model.status)")
        #expect(await decision(of: parked, old, in: broker) == .cancelled, "the old request returns")
        let next = agentProposal(in: placeA, conversation: conversationA)
        let nextParked = Task { await broker.request(next) }
        #expect(await waitUntil { await broker.current(for: placeA)?.id == next.id },
                "the new session's gated call parks, not .busy")
        await broker.cancel(id: next.id)
        #expect(await nextParked.value == .cancelled)
    }

    @Test func anotherPlacesWaitingApprovalOutlivesThisPlacesResume() async throws {
        let sessions = Sessions()
        let broker = ConfirmationBroker()
        let (model, _) = try await resumableWindow(sessions, confirmations: broker)
        show(placeB, in: model)
        #expect(await model.send("hello B"))
        show(placeA, in: model)
        #expect(await model.send("hello A"))
        let other = agentProposal(in: placeB, conversation: try #require(model.agents[placeB]?.id))
        let parked = Task { await broker.request(other) }
        #expect(await waitUntil { await broker.current(for: placeB)?.id == other.id })

        await model.resume(sessionId: "parent-1")

        #expect(sessions.harnesses.in(placeA).count == 2, "\(model.status)")
        #expect(await broker.current(for: placeB)?.id == other.id, "B's agent still waits")
        await broker.cancel(id: other.id)
        _ = await parked.value
    }

    @Test func shutdownCancelsEveryWaitingApproval() async throws {
        let harnesses = Harnesses()
        let broker = ConfirmationBroker()
        let model = twoPlaceWindow(harnesses, confirmations: broker)
        show(placeA, in: model)
        #expect(await model.send("hello A"))
        let proposal = agentProposal(in: placeA, conversation: try #require(model.agents[placeA]?.id))
        let parked = Task { await broker.request(proposal) }
        #expect(await waitUntil { await broker.current(for: placeA)?.id == proposal.id })

        await model.shutdown()

        #expect(await decision(of: parked, proposal, in: broker) == .cancelled, "the parked request returns")
        #expect(await broker.all().isEmpty)
    }

    /// Final review minor 6: an agent's own resume, off screen, reads its arrangement once. A
    /// file it cannot read is not marked read — so its next pane does not overwrite that file —
    /// and the note is said when the operator comes back to it, as an on-screen read says it.
    @Test func anOffScreenReadOfAnUnreadableLayoutKeepsTheFileAndItsNote() async throws {
        let directory = testScratchRoot.appendingPathComponent("place-agent-unreadable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let persistence = LayoutPersistence(directory: directory)
        // The project seed a resume with no lineage files under, made unreadable.
        let seed = LayoutScope(organization: org, project: placeA.project, environment: placeA.environment)
        try persistence.save(LayoutSnapshot(panes: []), for: seed)
        let files = try #require(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "json" }
        let file = try #require(files.first, "\(files)")
        let garbage = Data("not a layout".utf8)
        try garbage.write(to: file)

        let model = twoPlaceWindow(Harnesses(), persistence: persistence)
        // `resume` reads the parent's transcript first; an empty one, under the window's provider.
        await model.registryForTesting.register(Action(
            name: "session_read", description: "test double", kind: .read,
            schema: .object(["type": .string("object")]),
            handler: { _ in
                .object(["structuredContent": .object([
                    "cwd": .string("/tmp"), "provider": .string("test-provider"), "parent": .string(""),
                    "truncated": .bool(false), "entries": .array([]),
                ])])
            }))
        show(placeA, in: model)
        #expect(await model.send("hello A"))
        show(placeB, in: model)
        await model.activateLayoutForTesting()
        let agentA = try #require(model.agents[placeA])

        await model.resume(sessionId: "parent-1", in: placeA)
        #expect(agentA.layoutScope == seed, "\(String(describing: agentA.layoutScope)) \(model.status)")
        _ = try await model.registryForTesting.dispatch(
            name: "pane_open", params: .object(["kind": .string("db"), "title": .string("A's pane")]),
            origin: .agent, caller: agentA.caller, confirmation: nil)

        // Long enough for the observation pump to have persisted the agent's change: before
        // this fix the file was overwritten within milliseconds.
        try await Task.sleep(for: .milliseconds(500))
        #expect(try Data(contentsOf: file) == garbage, "the unreadable file is kept")
        show(placeA, in: model)
        await model.activateLayoutForTesting()
        #expect(model.status.contains("could not be read"), "\(model.status)")
    }

    /// Minor 6's other half: a file read off screen with a note — a pane of a kind this build
    /// does not draw, dropped — says that note when the operator comes back to it.
    @Test func anOffScreenReadsNoteIsSaidOnTheReturn() async throws {
        let directory = testScratchRoot.appendingPathComponent("place-agent-stale-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let persistence = LayoutPersistence(directory: directory)
        let seed = LayoutScope(organization: org, project: placeA.project, environment: placeA.environment)
        try persistence.save(LayoutSnapshot(panes: [Pane(
            id: "gone-1", kind: "retired-kind", title: "gone",
            frame: PaneFrame(x: 0, y: 0, width: 200, height: 200))]), for: seed)

        let model = twoPlaceWindow(Harnesses(), persistence: persistence)
        await model.registryForTesting.register(Action(
            name: "session_read", description: "test double", kind: .read,
            schema: .object(["type": .string("object")]),
            handler: { _ in
                .object(["structuredContent": .object([
                    "cwd": .string("/tmp"), "provider": .string("test-provider"), "parent": .string(""),
                    "truncated": .bool(false), "entries": .array([]),
                ])])
            }))
        show(placeA, in: model)
        #expect(await model.send("hello A"))
        show(placeB, in: model)
        await model.activateLayoutForTesting()

        await model.resume(sessionId: "parent-1", in: placeA)
        #expect(model.agents[placeA]?.layoutScope == seed, "\(model.status)")
        #expect(!model.status.contains("retired-kind"), "not said while elsewhere: \(model.status)")

        show(placeA, in: model)
        await model.activateLayoutForTesting()
        #expect(model.status.contains("retired-kind"), "\(model.status)")
    }
}
