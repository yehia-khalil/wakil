import Testing
import Foundation
#if canImport(Darwin)
import Darwin
#endif
@testable import WakilKit

// MARK: - The rule

private func call(allowed: Bool, readOnly: Bool, locked: Bool = false) -> ConnectionCallRequest {
    ConnectionCallRequest(
        connection: "tracker", tool: "create_issue", arguments: .object(["title": .string("Fix it")]),
        allowed: allowed, readOnly: readOnly, locked: locked)
}

@Test func allowedReadOnlyIsAllowed() {
    #expect(connectionCallDecision(call(allowed: true, readOnly: true), spoken: false) == .allow)
    #expect(connectionCallDecision(call(allowed: true, readOnly: true), spoken: true) == .allow)
}

@Test func allowedWriteTypedIsAllowed() {
    #expect(connectionCallDecision(call(allowed: true, readOnly: false), spoken: false) == .allow)
}

@Test func allowedWriteSpokenAsks() {
    #expect(connectionCallDecision(call(allowed: true, readOnly: false), spoken: true) == nil)
}

@Test func unallowedAsks() {
    for readOnly in [false, true] {
        for spoken in [false, true] {
            #expect(connectionCallDecision(call(allowed: false, readOnly: readOnly), spoken: spoken) == nil)
        }
    }
}

@Test func lockedAlwaysAsks() {
    for readOnly in [false, true] {
        for spoken in [false, true] {
            #expect(connectionCallDecision(call(allowed: true, readOnly: readOnly, locked: true), spoken: spoken) == nil)
        }
    }
}

@Test func theApprovalSocketSitsBesideTheAgentSocketAndFitsSunPath() {
    // The per-user temporary directory measured on this machine, 48 characters.
    let directory = URL(fileURLWithPath: "/var/folders/0h/97h9cspn7vv3l2pl6g5r07h80000gn/T")
    let session = UUID().uuidString
    let agent = agentSocketPath(agentSessionId: session, directory: directory)
    let approval = approvalSocketPath(forAgentSocket: agent)
    #expect(approval == directory.appendingPathComponent("\(session)-approval.sock").path)
    #expect(approval != agent)
    #expect(approval.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path))
}

// MARK: - The server

private let place = Place(organization: "initech", project: "billing", environment: "staging")
private let slot = ProposalSlot(place: place, conversation: "conv-1")

private final class Journal: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [(ConnectionCallRequest, String)] = []
    func record(_ request: ConnectionCallRequest, _ outcome: String) {
        lock.lock(); lines.append((request, outcome)); lock.unlock()
    }
    var outcomes: [String] { lock.lock(); defer { lock.unlock() }; return lines.map(\.1) }
}

private func shortSocketPath() -> String {
    // /tmp, not the per-user temporary directory: the test path must fit `sun_path`.
    "/tmp/wakil-approval-\(UUID().uuidString.prefix(8)).sock"
}

private func makeServer(
    path: String = shortSocketPath(), broker: ConfirmationBroker = ConfirmationBroker(),
    spoken: @escaping @Sendable () async -> Bool = { false },
    journal: @escaping @Sendable (ConnectionCallRequest, String) async -> Void = { _, _ in }
) async throws -> (ConnectionApprovalServer, String) {
    let server = ConnectionApprovalServer(
        socketPath: path, place: place, conversation: "conv-1", broker: broker,
        spoken: spoken, journal: journal)
    try await server.start()
    return (server, path)
}

/// Runs `body` against a started server and stops it afterwards, awaited, whether `body` threw.
private func serving(
    path: String = shortSocketPath(), broker: ConfirmationBroker = ConfirmationBroker(),
    spoken: @escaping @Sendable () async -> Bool = { false },
    journal: @escaping @Sendable (ConnectionCallRequest, String) async -> Void = { _, _ in },
    _ body: (ConnectionApprovalServer, String) async throws -> Void
) async throws {
    let (server, path) = try await makeServer(path: path, broker: broker, spoken: spoken, journal: journal)
    do {
        try await body(server, path)
    } catch {
        await server.stop()
        throw error
    }
    await server.stop()
}

private func connect(_ path: String) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var (addr, len) = try makeUnixSocketAddress(path: path)
    let rc = withUnsafePointer(to: &addr) { pointer -> Int32 in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, len) }
    }
    guard rc == 0 else {
        let failed = errno
        close(fd)
        throw MCPTransportError.posixFailure(call: "connect", path: path, errnoValue: failed)
    }
    return fd
}

/// Everything the server writes on `fd` until it closes, read on a thread of its own so a wait
/// on the operator holds no cooperative thread.
private func readToEnd(_ fd: Int32) async -> Data {
    await withCheckedContinuation { continuation in
        Thread {
            continuation.resume(returning: FileHandle(fileDescriptor: fd, closeOnDealloc: false).readDataToEndOfFile())
        }.start()
    }
}

/// Sends `line` on a fresh connection and reads the one line back.
private func exchange(_ path: String, _ line: Data) async throws -> [String: String] {
    let fd = try connect(path)
    defer { close(fd) }
    try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: line + Data("\n".utf8))
    return try JSONDecoder().decode([String: String].self, from: await readToEnd(fd))
}

private func exchange(_ path: String, _ request: ConnectionCallRequest) async throws -> [String: String] {
    try await exchange(path, try JSONEncoder().encode(request))
}

/// Waits until something is parked in the conversation's slot.
private func parked(in broker: ConfirmationBroker) async throws -> PendingMutation {
    for _ in 0..<500 {
        if let pending = await broker.current(in: slot) { return pending }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw CancellationError()
}

@Test func approvedOnThePlaneAllows() async throws {
    let broker = ConfirmationBroker()
    try await serving(broker: broker) { _, path in
        let request = call(allowed: false, readOnly: false)
        async let answer = exchange(path, request)
        let pending = try await parked(in: broker)
        #expect(pending.action == "connection_call")
        #expect(pending.params == request.params)
        #expect(pending.statement == #"tracker · create_issue({"title":"Fix it"})"#)
        #expect(pending.origin == .agent)
        #expect(pending.database == nil)
        await broker.approve(id: pending.id)
        #expect(try await answer == ["decision": "allow"])
    }
}

@Test func cancelledOnThePlaneDeniesWithMessage() async throws {
    let broker = ConfirmationBroker()
    try await serving(broker: broker) { _, path in
        async let answer = exchange(path, call(allowed: true, readOnly: false, locked: true))
        await broker.cancel(id: try await parked(in: broker).id)
        let reply = try await answer
        #expect(reply["decision"] == "deny")
        let message = try #require(reply["message"])
        #expect(message.contains("create_issue"))
        #expect(message.contains("tracker"))
        #expect(message.contains("operator declined"))
    }
}

@Test func aSpokenTurnAsksBeforeAnAllowedWrite() async throws {
    let broker = ConfirmationBroker()
    try await serving(broker: broker, spoken: { true }) { _, path in
        async let answer = exchange(path, call(allowed: true, readOnly: false))
        await broker.approve(id: try await parked(in: broker).id)
        #expect(try await answer == ["decision": "allow"])
    }
}

@Test func everyDecisionIsJournalled() async throws {
    let directory = testScratchRoot.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let registry = ActionRegistry(journalDirectory: directory, sessionId: "approval")
    let caller = DispatchCaller(place: place, session: "sess-1", conversation: "conv-1")
    let broker = ConfirmationBroker()
    let allowed = call(allowed: true, readOnly: true)
    try await serving(broker: broker, journal: { request, outcome in
        try? await registry.journalConnectionCall(request, outcome: outcome, caller: caller)
    }) { _, path in
        #expect(try await exchange(path, allowed) == ["decision": "allow"])
        async let approvedAnswer = exchange(path, call(allowed: false, readOnly: false))
        await broker.approve(id: try await parked(in: broker).id)
        _ = try await approvedAnswer
        async let declinedAnswer = exchange(path, call(allowed: false, readOnly: true))
        await broker.cancel(id: try await parked(in: broker).id)
        _ = try await declinedAnswer
    }
    let entries = try await registry.journalEntries()
    #expect(entries.map(\.action) == ["connection_call", "connection_call", "connection_call"])
    // The first ran on the peer's own flags, so it says so: nothing the peer sent approved it.
    #expect(entries.map(\.outcome) == ["peer-allowed", "asked-approved", "asked-declined"])
    #expect(entries[0].params == allowed.params)
    #expect(entries[0].origin == .agent)
    #expect(entries[0].conversation == "conv-1")
    #expect(entries[0].session == "sess-1")
}

@Test func aRequestOnAStoppedServerIsDenied() async throws {
    let journal = Journal()
    let (server, _) = try await makeServer(journal: { journal.record($0, $1) })
    await server.stop()
    let decision = await server.answer(call(allowed: true, readOnly: true))
    guard case .deny(let message) = decision else {
        Issue.record("a stopped conversation's server allowed a call")
        return
    }
    #expect(message.contains("ended"))
    #expect(journal.outcomes == ["conversation-ended"])
}

/// Stopping the server ends its own wait: no proposal is left parked for a conversation that is
/// gone, and the request is answered "ended", journalled so.
@Test func aStopWhileWaitingCancelsWhatItParked() async throws {
    let broker = ConfirmationBroker()
    let journal = Journal()
    let (server, path) = try await makeServer(broker: broker, journal: { journal.record($0, $1) })
    async let answer = exchange(path, call(allowed: false, readOnly: false))
    _ = try await parked(in: broker)
    await server.stop()
    let reply = try await answer
    #expect(reply["decision"] == "deny")
    #expect(reply["message"]?.contains("ended") == true)
    #expect(await broker.current(in: slot) == nil)
    #expect(journal.outcomes == ["conversation-ended"])
}

/// One gate a test opens by hand.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiter: CheckedContinuation<Void, Never>?
    private var entered = false
    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock(); waiter = continuation; entered = true; lock.unlock()
        }
    }
    var isEntered: Bool { lock.lock(); defer { lock.unlock() }; return entered }
    func open() { lock.lock(); let w = waiter; waiter = nil; lock.unlock(); w?.resume() }
}

/// A stop that lands while the request reads `spoken` decides it: nothing is parked afterwards.
@Test func aStopWhileReadingSpokenParksNothing() async throws {
    let broker = ConfirmationBroker()
    let journal = Journal()
    let gate = Gate()
    let (server, _) = try await makeServer(broker: broker, spoken: { await gate.wait(); return false },
                                           journal: { journal.record($0, $1) })
    let answer = Task { await server.answer(call(allowed: false, readOnly: false)) }
    while !gate.isEntered { try await Task.sleep(for: .milliseconds(5)) }
    await server.stop()
    gate.open()
    guard case .deny(let message) = await answer.value else {
        Issue.record("a call raced by a stop was allowed")
        return
    }
    #expect(message.contains("ended"))
    #expect(await broker.current(in: slot) == nil)
    #expect(journal.outcomes == ["conversation-ended"])
}

@Test func theSocketIsOwnerOnlyAndAStaleFileIsReplaced() async throws {
    let path = shortSocketPath()
    FileManager.default.createFile(atPath: path, contents: Data("stale".utf8))
    try await serving(path: path) { _, _ in
        var info = stat()
        #expect(lstat(path, &info) == 0)
        #expect(info.st_mode & S_IFMT == S_IFSOCK)
        #expect(info.st_mode & 0o777 == 0o600)
    }
}

@Test func aLineOverOneMebibyteIsDenied() async throws {
    try await serving { _, path in
        let big = try JSONEncoder().encode(ConnectionCallRequest(
            connection: "tracker", tool: "create_issue",
            arguments: .object(["body": .string(String(repeating: "x", count: 1 << 20))]),
            allowed: true, readOnly: true, locked: false))
        #expect(big.count > 1 << 20)
        let reply = try await exchange(path, big)
        #expect(reply["decision"] == "deny")
    }
}

@Test func aLineThatIsNotARequestIsDenied() async throws {
    try await serving { _, path in
        // A request that names no flags approves nothing: it does not decode.
        let reply = try await exchange(path, Data(#"{"connection":"tracker","tool":"create_issue","arguments":{}}"#.utf8))
        #expect(reply["decision"] == "deny")
    }
}

@Test func aConnectionThatSendsNothingIsDeniedAfterTheReadTimeout() async throws {
    try await serving { server, path in
        server.setReadTimeoutForTesting(0.2)
        let fd = try connect(path)
        defer { close(fd) }
        let reply = try JSONDecoder().decode([String: String].self, from: await readToEnd(fd))
        #expect(reply["decision"] == "deny")
        #expect(reply["message"]?.contains("did not arrive") == true)
    }
}

@Test func connectionsPastTheCapAreClosedUnread() async throws {
    try await serving { server, path in
        server.setReadTimeoutForTesting(30)
        // The cap's worth, each holding its slot by sending nothing.
        var held: [Int32] = []
        defer { held.forEach { close($0) } }
        for _ in 0..<ConnectionApprovalServer.maxConnections { held.append(try connect(path)) }
        try await Task.sleep(for: .milliseconds(100))
        let extra = try connect(path)
        defer { close(extra) }
        #expect(await readToEnd(extra).isEmpty)
    }
}

@Test func aStopAnswersAConnectionStillSending() async throws {
    let (server, path) = try await makeServer()
    server.setReadTimeoutForTesting(30)
    let fd = try connect(path)
    defer { close(fd) }
    try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: Data(#"{"connection":"#.utf8))
    try await Task.sleep(for: .milliseconds(100))
    await server.stop()
    let reply = try JSONDecoder().decode([String: String].self, from: await readToEnd(fd))
    #expect(reply["decision"] == "deny")
}

@Test func concurrentConnectionsAreEachAnswered() async throws {
    let broker = ConfirmationBroker()
    try await serving(broker: broker) { _, path in
        // One waits on the operator while others are answered beside it.
        async let waiting = exchange(path, call(allowed: false, readOnly: false))
        let pending = try await parked(in: broker)
        try await withThrowingTaskGroup(of: [String: String].self) { group in
            for _ in 0..<8 { group.addTask { try await exchange(path, call(allowed: true, readOnly: true)) } }
            for try await reply in group { #expect(reply == ["decision": "allow"]) }
        }
        await broker.approve(id: pending.id)
        #expect(try await waiting == ["decision": "allow"])
    }
}

@Test func theStatementCutsLongArgumentsForDisplayOnly() {
    let request = ConnectionCallRequest(
        connection: "tracker", tool: "create_issue",
        arguments: .object(["body": .string(String(repeating: "y", count: 2000) + "\nend")]),
        allowed: false, readOnly: false, locked: false)
    let statement = ConnectionApprovalServer.statement(request)
    #expect(statement.hasPrefix("tracker · create_issue({\"body\":\"yyy"))
    #expect(statement.hasSuffix("…)"))
    #expect(!statement.contains("\n"))
    #expect(statement.count < 400)
}

/// The statement shows the arguments as `wakil-connect` sent them: an integer past 2^53 is not
/// rounded the way `JSONValue`'s `Double` would round it, a string reads as itself (Go's `\u003c`
/// shown as `<`), and what would not show as itself is still spelled out.
@Test func theStatementShowsNumbersExactlyAsSent() throws {
    let line = Data(#"{"connection":"tracker","tool":"set_id","arguments":{"id":12345678901234567890,"note":"a\u003cb \u202e!","n":[1.50,-2e3]},"allowed":false,"readOnly":false,"locked":false}"#.utf8)
    let request = try #require(ConnectionApprovalServer.request(fromLine: line))
    #expect(request.tool == "set_id")
    let statement = ConnectionApprovalServer.statement(request)
    #expect(statement.contains(#""id":12345678901234567890"#), "\(statement)")
    #expect(statement.contains(#""n":[1.50,-2e3]"#), "\(statement)")
    #expect(statement.contains(#""note":"a<b \u{202E}!""#), "\(statement)")
    #expect(!statement.unicodeScalars.contains { $0.properties.generalCategory == .format })
    // Re-encoding the decoded value is what would have rounded it.
    let encoded = String(decoding: try JSONEncoder().encode(request.arguments), as: UTF8.self)
    #expect(!encoded.contains("12345678901234567890"))
}

@Test func theStatementSpellsOutWhatWouldNotShowAsItself() {
    // A right-to-left override, a zero-width space, a line separator and a bell.
    let request = ConnectionCallRequest(
        connection: "track\u{202E}er", tool: "create\u{200B}issue",
        arguments: .object(["title": .string("a\u{2028}b\u{2029}c\u{07}d")]),
        allowed: false, readOnly: false, locked: false)
    let statement = ConnectionApprovalServer.statement(request)
    #expect(statement.contains(#"track\u{202E}er"#))
    #expect(statement.contains(#"create\u{200B}issue"#))
    #expect(statement.contains(#"\u{2028}"#))
    #expect(statement.contains(#"\u{2029}"#))
    #expect(!statement.unicodeScalars.contains { s in
        [.control, .format, .lineSeparator, .paragraphSeparator].contains(s.properties.generalCategory)
    })
}

// MARK: - Spoken, per conversation

private final class TurnHarness: AgentHarness, @unchecked Sendable {
    private let stream: AsyncStream<HarnessEvent>
    let continuation: AsyncStream<HarnessEvent>.Continuation
    init() { (stream, continuation) = AsyncStream<HarnessEvent>.makeStream() }
    func start(sessionId: String, resumingFrom parentSessionId: String?, workingDirectory: String) async throws {}
    func send(_ text: String) async throws {}
    func events() -> AsyncStream<HarnessEvent> { stream }
    func interrupt() async {}
    func stop() async { continuation.finish() }
}

/// Lands one `.result` and waits for the pump to take it.
@MainActor
private func answerOne(_ harness: TurnHarness, on agent: PlaceAgent) async throws {
    let before = agent.unansweredSends
    harness.continuation.yield(.result(isError: false, text: "done"))
    for _ in 0..<200 where agent.unansweredSends == before {
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
@Test func aVoiceTurnIsSpokenUntilItEnds() async throws {
    let harness = TurnHarness()
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot, harnessFactory: { _, _ in harness })
    await model.send("create the issue", via: .voice)
    let agent = try #require(model.currentAgent)
    #expect(model.turnIsSpoken(conversation: agent.id))
    try await answerOne(harness, on: agent)
    #expect(!model.turnIsSpoken(conversation: agent.id))
}

/// A typed follow-up sent during a spoken turn does not lower it (Invariant 7): until every
/// message sent is answered, the conversation is spoken.
@MainActor
@Test func aTypedFollowUpKeepsTheTurnSpokenUntilItEnds() async throws {
    let harness = TurnHarness()
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot, harnessFactory: { _, _ in harness })
    await model.send("create the issue", via: .voice)
    let agent = try #require(model.currentAgent)
    await model.send("and label it")
    #expect(model.turnIsSpoken(conversation: agent.id))
    try await answerOne(harness, on: agent)
    #expect(model.turnIsSpoken(conversation: agent.id))
    try await answerOne(harness, on: agent)
    #expect(!model.turnIsSpoken(conversation: agent.id))
}

/// A spoken message queued behind a typed turn is not cleared by the typed turn's `.result`.
@MainActor
@Test func aSpokenMessageQueuedBehindATypedTurnStaysSpoken() async throws {
    let harness = TurnHarness()
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot, harnessFactory: { _, _ in harness })
    await model.send("list the issues")
    let agent = try #require(model.currentAgent)
    #expect(!model.turnIsSpoken(conversation: agent.id))
    await model.send("now close the first one", via: .voice)
    try await answerOne(harness, on: agent)
    #expect(model.turnIsSpoken(conversation: agent.id))
    try await answerOne(harness, on: agent)
    #expect(!model.turnIsSpoken(conversation: agent.id))
}

@MainActor
@Test func aTypedTurnAloneIsNotSpoken() async throws {
    let harness = TurnHarness()
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot, harnessFactory: { _, _ in harness })
    await model.send("list the issues")
    let agent = try #require(model.currentAgent)
    #expect(!model.turnIsSpoken(conversation: agent.id))
}

@MainActor
@Test func anUnknownConversationCountsAsSpoken() {
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot)
    #expect(model.turnIsSpoken(conversation: "no-such-conversation"))
}

// MARK: - A socket that would not start is said

private struct HalfStartedSocket: AgentSocket {
    let startFailure: String?
    func stop() async {}
}

@MainActor
@Test func anApprovalSocketThatWouldNotStartIsInTheStatus() async throws {
    let harness = TurnHarness()
    let failure = approvalSocketFailure(
        path: "/tmp/x-approval.sock", error: MCPTransportError.pathTooLong("/tmp/x-approval.sock"))
    let model = WindowModel.forTesting(
        scratchRoot: testScratchRoot, harnessFactory: { _, _ in harness },
        agentSocketFactory: { _, _ in HalfStartedSocket(startFailure: failure) })
    await model.send("list the issues")
    #expect(model.status == failure)
    #expect(failure.contains("approval socket /tmp/x-approval.sock"))
}
