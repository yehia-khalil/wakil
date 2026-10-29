import Foundation
import Testing
@testable import WakilKit

/// Spec amendment 2026-10-26 (plan Task 9): a connection added, removed or changed reaches every
/// open conversation in its organisation at that conversation's next message — the agent is
/// fork-resumed between turns with the organisation's current connections — never mid-turn, and an
/// Allow agent tick restarts nothing.

/// One launch's harness: what it was started from and what it was sent.
private final class LaunchHarness: AgentHarness, @unchecked Sendable {
    private let lock = NSLock()
    private var _resumedFrom: String??
    private var _sent: [String] = []
    private let stream: AsyncStream<HarnessEvent>
    let continuation: AsyncStream<HarnessEvent>.Continuation

    init() { (stream, continuation) = AsyncStream<HarnessEvent>.makeStream() }

    var resumedFrom: String?? { lock.withLock { _resumedFrom } }
    var sent: [String] { lock.withLock { _sent } }

    func start(sessionId: String, resumingFrom parentSessionId: String?, workingDirectory: String) async throws {
        lock.withLock { _resumedFrom = .some(parentSessionId) }
    }
    func send(_ text: String) async throws { lock.withLock { _sent.append(text) } }
    func events() -> AsyncStream<HarnessEvent> { stream }
    func interrupt() async {}
    func stop() async { continuation.finish() }
}

/// Every launch the window made: its MCP config, built from the box at launch exactly as
/// `WindowSession`'s `harnessFactory` builds it, and its harness.
private final class Launches: @unchecked Sendable {
    private let lock = NSLock()
    private var _configs: [String] = []
    private var _harnesses: [LaunchHarness] = []
    var configs: [String] { lock.withLock { _configs } }
    var harnesses: [LaunchHarness] { lock.withLock { _harnesses } }
    var count: Int { lock.withLock { _harnesses.count } }

    func launch(_ place: Place, _ box: AgentConnectionsBox) -> AgentHarness {
        let config = agentMCPConfigJSON(
            shimExecutable: URL(fileURLWithPath: "/Apps/Wakil.app/Contents/MacOS/Wakil"),
            socketPath: "/tmp/wakil-1.sock",
            binaries: [wakilConnectBinaryName: URL(fileURLWithPath: "/Apps/Wakil.app/Contents/Resources/wakil-connect")],
            place: place, provider: "test-provider",
            connections: box.connections(org: place.organization), approvalSocket: "/tmp/1-approval.sock")
        let harness = LaunchHarness()
        lock.withLock {
            _configs.append(config)
            _harnesses.append(harness)
        }
        return harness
    }
}

@Suite @MainActor struct ConnectionRestartTests {
    private func window(
        reads: TranscriptReads = TranscriptReads(), confirmations: ConfirmationBroker = ConfirmationBroker()
    ) async -> (WindowModel, AgentConnectionsBox, Launches) {
        let box = AgentConnectionsBox()
        let launches = Launches()
        let model = WindowModel.forTesting(
            scratchRoot: testScratchRoot, harnessFactory: { place, _ in launches.launch(place, box) },
            confirmations: confirmations)
        model.agentConnectionsBox = box
        box.set(org: model.place.organization, connections: [])
        // The fork-resume reads the conversation's transcript, as every resume does.
        await model.registryForTesting.register(Action(
            name: "session_read", description: "test double", kind: .read,
            schema: .object(["type": .string("object")]),
            handler: { _ in
                try await reads.read()
                return .object(["structuredContent": .object([
                    "cwd": .string("/tmp"), "provider": .string("test-provider"), "parent": .string(""),
                    "truncated": .bool(false),
                    "entries": .array([
                        .object(["kind": .string("user"), "text": .string("one")]),
                        .object(["kind": .string("assistant"), "text": .string("answer to one")]),
                    ]),
                ])])
            }))
        return (model, box, launches)
    }

    /// Waits until `condition` holds, or records that it never did.
    private func until(_ what: String, _ condition: () async -> Bool) async throws {
        for _ in 0..<300 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("never: \(what)")
    }

    /// Lands one `.result` on `harness` and waits for the pump to take it.
    private func answerOne(_ harness: LaunchHarness, on agent: PlaceAgent) async throws {
        let before = agent.unansweredSends
        harness.continuation.yield(.result(isError: false, text: "done"))
        for _ in 0..<300 where agent.unansweredSends == before {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(agent.unansweredSends < before, "the turn did not end")
    }

    private func names(_ config: String, _ server: String) -> Bool {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(config.utf8)),
              case .object(let root) = value, case .object(let servers)? = root["mcpServers"]
        else { return false }
        return servers[server] != nil
    }

    @Test func addingAConnectionRestartsAnIdleConversationAtItsNextMessage() async throws {
        let (model, box, launches) = await window()
        let org = model.place.organization
        await model.send("one")
        let agent = try #require(model.currentAgent)
        let first = try #require(agent.sessionId)
        try await answerOne(launches.harnesses[0], on: agent)
        #expect(!names(launches.configs[0], "tracker"))

        box.set(org: org, connections: [AgentConnection(name: "tracker", kind: "github", transport: "http",
                                                        url: "https://example.com/mcp")])
        // Nothing restarts until the conversation's next message.
        #expect(launches.count == 1)

        await model.send("two")
        try #require(launches.count == 2)
        let relaunch = launches.harnesses[1]
        // The relaunch's MCP config names the new connection, and it is the fork-resume every
        // resume is: the same conversation, a new session id.
        #expect(names(launches.configs[1], "tracker"))
        #expect(relaunch.resumedFrom == .some(first))
        #expect(model.currentAgent === agent)
        #expect(agent.sessionId != first)
        // The message went to the relaunched agent, not the one it replaced.
        #expect(relaunch.sent.last?.hasSuffix("two") == true)
        #expect(launches.harnesses[0].sent == ["one"])
        // The transcript is kept.
        #expect(agent.thoughts.contains { $0.label == "assistant" && $0.detail == "answer to one" })
        #expect(agent.thoughts.contains { $0.label == "you" && $0.detail == "two" })

        // Once restarted, the next message restarts nothing.
        try await answerOne(relaunch, on: agent)
        await model.send("three")
        #expect(launches.count == 2)
    }

    @Test func aConversationMidTurnRestartsOnlyAfterTheTurn() async throws {
        let (model, box, launches) = await window()
        let org = model.place.organization
        await model.send("one")
        let agent = try #require(model.currentAgent)
        box.set(org: org, connections: [AgentConnection(name: "tracker")])

        // The agent is working: a message sent now goes to it, and nothing restarts.
        #expect(agent.turnInFlight)
        await model.send("two")
        #expect(launches.count == 1)
        #expect(launches.harnesses[0].sent == ["one", "two"])

        try await answerOne(launches.harnesses[0], on: agent)
        try await answerOne(launches.harnesses[0], on: agent)
        #expect(!agent.turnInFlight)

        await model.send("three")
        try #require(launches.count == 2)
        #expect(names(launches.configs[1], "tracker"))
        #expect(launches.harnesses[1].sent.last?.hasSuffix("three") == true)
    }

    @Test func anAllowTickRestartsNothing() async throws {
        let (model, box, launches) = await window()
        let org = model.place.organization
        let tracker = AgentConnection(name: "tracker", kind: "github", hints: ["create_issue": "writes"])
        box.set(org: org, connections: [tracker])
        await model.send("one")
        let agent = try #require(model.currentAgent)
        try await answerOne(launches.harnesses[0], on: agent)

        var ticked = tracker
        ticked.allow = ["create_issue": true]
        // A check recording the server's hints is not a server change either.
        ticked.hints = ["create_issue": "writes", "read_doc": "readOnly"]
        box.set(org: org, connections: [ticked])
        await model.send("two")
        #expect(launches.count == 1)
        #expect(launches.harnesses[0].sent == ["one", "two"])
    }

    @Test func anotherOrganisationsChangeRestartsNothing() async throws {
        let (model, box, launches) = await window()
        await model.send("one")
        let agent = try #require(model.currentAgent)
        try await answerOne(launches.harnesses[0], on: agent)

        #expect(model.place.organization != "umbrella")
        box.set(org: "umbrella", connections: [AgentConnection(name: "wiki")])
        await model.send("two")
        #expect(launches.count == 1)
    }

    /// A token replaced shows nowhere in the tree, but `wakil-connect` reads it only at start.
    @Test func aReplacedTokenRestartsAtTheNextMessage() async throws {
        let (model, box, launches) = await window()
        let org = model.place.organization
        box.set(org: org, connections: [AgentConnection(name: "tracker", kind: "github", signedIn: true)])
        await model.registryForTesting.register(Action(
            name: "ctx_connection_secrets_set", description: "stub", kind: .control, audience: .operatorOnly,
            schema: .object([:]), handler: { _ in .object([:]) }))
        await model.send("one")
        let agent = try #require(model.currentAgent)
        try await answerOne(launches.harnesses[0], on: agent)

        #expect(await model.setConnectionSecrets(org: org, name: "tracker", values: ["token": "example-token"]) == nil)
        await model.send("two")
        #expect(launches.count == 2)
    }

    @Test func noChangeNoRestart() async throws {
        let (model, box, launches) = await window()
        let org = model.place.organization
        let tracker = AgentConnection(name: "tracker", kind: "github", url: "https://example.com/mcp")
        box.set(org: org, connections: [tracker])
        await model.send("one")
        let agent = try #require(model.currentAgent)
        try await answerOne(launches.harnesses[0], on: agent)

        // Settings read again, the same connections.
        box.set(org: org, connections: [tracker])
        await model.send("two")
        #expect(launches.count == 1)
        #expect(launches.harnesses[0].sent == ["one", "two"])
    }

    // MARK: Review fixes

    /// The restart is not an instructions change: the first message after it carries no update.
    @Test func aRestartDoesNotSayTheInstructionsChanged() async throws {
        let (model, box, launches) = await window()
        let instructions = AgentInstructionsBox()
        model.agentInstructionsBox = instructions
        instructions.set(org: model.place.organization, project: model.place.project, text: "## Organisation o — general\nA")
        await model.send("one")
        let agent = try #require(model.currentAgent)
        try await answerOne(launches.harnesses[0], on: agent)

        box.set(org: model.place.organization, connections: [AgentConnection(name: "tracker")])
        await model.send("two")
        try #require(launches.count == 2)
        #expect(launches.harnesses[1].sent == ["two"])
        #expect(!agent.thoughts.contains { $0.label == "instructions" })
        #expect(agent.thoughts.contains {
            $0.label == "resumed" && $0.detail.hasPrefix("restarted with the organisation's current connections")
        })
    }

    /// Closed while it restarts: the message goes nowhere, and Rule 8's sentence says so.
    @Test(.timeLimit(.minutes(1))) func aConversationClosedDuringTheRestartSendsNothing() async throws {
        let reads = TranscriptReads()
        let (model, box, launches) = await window(reads: reads)
        await model.send("one")
        let agent = try #require(model.currentAgent)
        try await answerOne(launches.harnesses[0], on: agent)
        box.set(org: model.place.organization, connections: [AgentConnection(name: "tracker")])

        await reads.hold()
        let sending = Task { await model.send("two") }
        try await until("the restart reads the transcript") { await reads.waiting }
        await model.closeConversation(agent.id)
        await model.answerCloseQuestion(close: true)
        await reads.release()
        #expect(await sending.value == false)
        #expect(model.status.contains("no longer live"), "\(model.status)")
        #expect(launches.harnesses[0].sent == ["one"])
        #expect(launches.harnesses.dropFirst().allSatisfy { $0.sent.isEmpty })
        #expect(!agent.thoughts.contains { $0.label == "you" && $0.detail == "two" })
    }

    /// A restart that fails keeps the agent as it was: the message goes to it, the conversation
    /// says why once, and every next message tries again until one succeeds.
    @Test func aFailedRestartSaysSoOnceAndTriesAgainAtTheNextMessage() async throws {
        let reads = TranscriptReads()
        let (model, box, launches) = await window(reads: reads)
        await model.send("one")
        let agent = try #require(model.currentAgent)
        try await answerOne(launches.harnesses[0], on: agent)
        box.set(org: model.place.organization, connections: [AgentConnection(name: "tracker")])
        let old = model.status

        await reads.fail("the transcript is unreadable")
        #expect(await model.send("two"))
        #expect(launches.count == 1)
        #expect(launches.harnesses[0].sent == ["one", "two"])
        #expect(model.status.contains("the transcript is unreadable"), "\(model.status)")
        #expect(model.status != old)
        let said = { agent.thoughts.filter { $0.isError && $0.detail.contains("current connections") }.count }
        #expect(said() == 1)
        try await answerOne(launches.harnesses[0], on: agent)

        #expect(await model.send("three"))
        #expect(await reads.count == 2)
        #expect(launches.harnesses[0].sent == ["one", "two", "three"])
        #expect(said() == 1)
        try await answerOne(launches.harnesses[0], on: agent)

        await reads.fail(nil)
        #expect(await model.send("four"))
        try #require(launches.count == 2)
        #expect(launches.harnesses[1].sent == ["four"])
    }

    /// No restart while the agent's own call waits on the plane.
    @Test(.timeLimit(.minutes(1))) func aCallOnThePlaneHoldsTheRestart() async throws {
        let broker = ConfirmationBroker()
        let (model, box, launches) = await window(confirmations: broker)
        await model.send("one")
        let agent = try #require(model.currentAgent)
        try await answerOne(launches.harnesses[0], on: agent)
        box.set(org: model.place.organization, connections: [AgentConnection(name: "tracker")])

        let proposal = PendingMutation(
            action: "connection_call", params: .object([:]), database: nil, statement: "tracker · create_issue({})",
            affectsEveryRow: false, origin: .agent, place: agent.place, conversation: agent.id)
        let asking = Task { await broker.request(proposal) }
        try await until("the call is on the plane") { model.parkedSlots.values.contains { $0.id == proposal.id } }
        #expect(!model.connectionsRestartDue(agent))
        await model.send("two")
        #expect(launches.count == 1)

        await broker.cancel(id: proposal.id)
        _ = await asking.value
        try await until("the plane is clear") { model.parkedSlots.isEmpty }
        try await answerOne(launches.harnesses[0], on: agent)
        await model.send("three")
        #expect(launches.count == 2)
    }

    /// A message sent while the restart runs waits for it and goes to the new agent; one restart.
    @Test(.timeLimit(.minutes(1))) func aSendDuringTheRestartGoesToTheNewAgent() async throws {
        let reads = TranscriptReads()
        let (model, box, launches) = await window(reads: reads)
        await model.send("one")
        let agent = try #require(model.currentAgent)
        try await answerOne(launches.harnesses[0], on: agent)
        box.set(org: model.place.organization, connections: [AgentConnection(name: "tracker")])

        await reads.hold()
        let first = Task { await model.send("two") }
        try await until("the restart reads the transcript") { await reads.waiting }
        let second = Task { await model.send("three") }
        try await Task.sleep(for: .milliseconds(50))
        await reads.release()
        #expect(await first.value)
        #expect(await second.value)
        #expect(launches.count == 2)
        #expect(launches.harnesses[0].sent == ["one"])
        #expect(launches.harnesses[1].sent == ["two", "three"])
        #expect(await reads.count == 1)
    }
}

/// The transcript read a restart makes: held, failed, counted.
actor TranscriptReads {
    private(set) var count = 0
    private var failure: String?
    private var held = false
    private(set) var waiting = false
    private var gate: CheckedContinuation<Void, Never>?

    func hold() { held = true }
    func fail(_ message: String?) { failure = message }
    func release() {
        held = false
        gate?.resume()
        gate = nil
    }

    func read() async throws {
        count += 1
        if held {
            waiting = true
            await withCheckedContinuation { gate = $0 }
            waiting = false
        }
        if let failure { throw StandardActionError.missingParam(action: "session_read", param: failure) }
    }

}

// MARK: - A removed connection refuses at once

private actor Outcomes {
    var all: [String] = []
    func add(_ outcome: String) { all.append(outcome) }
}

/// Before the conversation's next message, a call on a connection the organisation no longer has
/// is refused by the approval socket and journalled `connection-removed` — whether the app's own
/// list says so (removed in Settings) or `wakil-connect`, reading `org.json` at the call, does
/// (removed from a terminal) — and never parked on the plane.
@Test func removingAConnectionRefusesItsCallsAtOnce() async throws {
    let place = Place(organization: "initech", project: "billing", environment: "staging")
    let box = AgentConnectionsBox()
    box.set(org: "initech", connections: [AgentConnection(name: "tracker"), AgentConnection(name: "wiki")])
    let broker = ConfirmationBroker()
    let outcomes = Outcomes()
    let server = ConnectionApprovalServer(
        socketPath: "/tmp/unused-approval.sock", place: place, conversation: "conv-1", broker: broker,
        spoken: { false }, journal: { _, outcome in await outcomes.add(outcome) },
        connectionExists: { box.stillHas(org: "initech", name: $0) })
    let write = ConnectionCallRequest(
        connection: "tracker", tool: "create_issue", arguments: .object(["title": .string("Fix it")]),
        allowed: true, readOnly: false, locked: false)

    // Removed in Settings: the box no longer has it. A ticked write from a typed turn — one the
    // rule would let through unasked — is refused all the same.
    box.set(org: "initech", connections: [AgentConnection(name: "wiki")])
    guard case .deny(let message) = await server.answer(write) else {
        Issue.record("a call on a removed connection was not refused")
        return
    }
    #expect(message.contains("tracker") && message.contains("no longer"))
    #expect(await broker.all().isEmpty)

    // Removed from a terminal: the app's list still has it, wakil-connect says it is gone.
    var gone = ConnectionCallRequest(
        connection: "wiki", tool: "read_doc", arguments: .object([:]), allowed: true, readOnly: true, locked: false)
    gone.removed = true
    #expect(await server.answer(gone) != .allow)
    #expect(await outcomes.all == ["connection-removed", "connection-removed"])

    // A connection still there is decided as before.
    let kept = ConnectionCallRequest(
        connection: "wiki", tool: "read_doc", arguments: .object([:]), allowed: true, readOnly: true, locked: false)
    #expect(await server.answer(kept) == .allow)
    // An organisation the app has never read decides nothing by the list.
    #expect(AgentConnectionsBox().stillHas(org: "initech", name: "tracker"))
}

/// `"removed":true` on the wire, as `wakil-connect` sends it, decodes; a line without it is not
/// removed.
@Test func aRemovedLineFromTheSocketDecodes() throws {
    let line = #"{"connection":"tracker","tool":"read_doc","arguments":{"id":"d-1"},"allowed":true,"readOnly":true,"locked":false,"removed":true}"#
    let request = try #require(ConnectionApprovalServer.request(fromLine: Data(line.utf8)))
    #expect(request.removed)
    #expect(request.connection == "tracker" && request.tool == "read_doc")
    #expect(request.params == .object([
        "connection": .string("tracker"), "tool": .string("read_doc"), "arguments": .object(["id": .string("d-1")]),
        "allowed": .bool(true), "readOnly": .bool(true), "locked": .bool(false), "removed": .bool(true),
    ]))
    let plain = #"{"connection":"tracker","tool":"read_doc","arguments":{},"allowed":true,"readOnly":true,"locked":false}"#
    let kept = try #require(ConnectionApprovalServer.request(fromLine: Data(plain.utf8)))
    #expect(!kept.removed)
    if case .object(let o) = kept.params { #expect(o["removed"] == nil) }
}
