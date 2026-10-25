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
    spoken: Bool = false, journal: @escaping @Sendable (ConnectionCallRequest, String) async -> Void = { _, _ in }
) async throws -> (ConnectionApprovalServer, String) {
    let server = ConnectionApprovalServer(
        socketPath: path, place: place, conversation: "conv-1", broker: broker,
        spoken: { spoken }, journal: journal)
    try await server.start()
    return (server, path)
}

/// Sends `line` on a fresh connection and reads the one line back, on a thread of its own so a
/// wait on the operator holds no cooperative thread.
private func exchange(_ path: String, _ line: Data) async throws -> [String: String] {
    try await withCheckedThrowingContinuation { continuation in
        Thread {
            do {
                let fd = socket(AF_UNIX, SOCK_STREAM, 0)
                var (addr, len) = try makeUnixSocketAddress(path: path)
                let rc = withUnsafePointer(to: &addr) { pointer -> Int32 in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
                }
                guard rc == 0 else {
                    close(fd)
                    throw MCPTransportError.posixFailure(call: "connect", path: path, errnoValue: errno)
                }
                defer { close(fd) }
                let out = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
                try out.write(contentsOf: line + Data("\n".utf8))
                let reply = out.readDataToEndOfFile()
                let answer = try JSONDecoder().decode([String: String].self, from: reply)
                continuation.resume(returning: answer)
            } catch {
                continuation.resume(throwing: error)
            }
        }.start()
    }
}

private func exchange(_ path: String, _ request: ConnectionCallRequest) async throws -> [String: String] {
    try await exchange(path, try JSONEncoder().encode(request))
}

/// Waits until something is parked in the conversation's slot.
private func parked(in broker: ConfirmationBroker) async throws -> PendingMutation {
    let slot = ProposalSlot(place: place, conversation: "conv-1")
    for _ in 0..<500 {
        if let pending = await broker.current(in: slot) { return pending }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw CancellationError()
}

@Test func approvedOnThePlaneAllows() async throws {
    let broker = ConfirmationBroker()
    let (server, path) = try await makeServer(broker: broker)
    defer { Task { await server.stop() } }
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

@Test func cancelledOnThePlaneDeniesWithMessage() async throws {
    let broker = ConfirmationBroker()
    let (server, path) = try await makeServer(broker: broker)
    defer { Task { await server.stop() } }
    async let answer = exchange(path, call(allowed: true, readOnly: false, locked: true))
    await broker.cancel(id: try await parked(in: broker).id)
    let reply = try await answer
    #expect(reply["decision"] == "deny")
    let message = try #require(reply["message"])
    #expect(message.contains("create_issue"))
    #expect(message.contains("tracker"))
    #expect(message.contains("operator declined"))
}

@Test func aSpokenTurnAsksBeforeAnAllowedWrite() async throws {
    let broker = ConfirmationBroker()
    let (server, path) = try await makeServer(broker: broker, spoken: true)
    defer { Task { await server.stop() } }
    async let answer = exchange(path, call(allowed: true, readOnly: false))
    await broker.approve(id: try await parked(in: broker).id)
    #expect(try await answer == ["decision": "allow"])
}

@Test func everyDecisionIsJournalled() async throws {
    let directory = testScratchRoot.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let registry = ActionRegistry(journalDirectory: directory, sessionId: "approval")
    let caller = DispatchCaller(place: place, session: "sess-1", conversation: "conv-1")
    let broker = ConfirmationBroker()
    let (server, path) = try await makeServer(broker: broker) { request, outcome in
        try? await registry.journalConnectionCall(request, outcome: outcome, caller: caller)
    }
    defer { Task { await server.stop() } }

    let allowed = call(allowed: true, readOnly: true)
    #expect(try await exchange(path, allowed) == ["decision": "allow"])
    async let approvedAnswer = exchange(path, call(allowed: false, readOnly: false))
    await broker.approve(id: try await parked(in: broker).id)
    _ = try await approvedAnswer
    async let declinedAnswer = exchange(path, call(allowed: false, readOnly: true))
    await broker.cancel(id: try await parked(in: broker).id)
    _ = try await declinedAnswer

    let entries = try await registry.journalEntries()
    #expect(entries.map(\.action) == ["connection_call", "connection_call", "connection_call"])
    #expect(entries.map(\.outcome) == ["allowed", "asked-approved", "asked-declined"])
    #expect(entries[0].params == allowed.params)
    #expect(entries[0].origin == .agent)
    #expect(entries[0].conversation == "conv-1")
    #expect(entries[0].session == "sess-1")
}

@Test func requestOnUnknownConversationIsDenied() async throws {
    let journal = Journal()
    let (server, _) = try await makeServer { journal.record($0, $1) }
    await server.stop()
    let decision = await server.answer(call(allowed: true, readOnly: true))
    guard case .deny(let message) = decision else {
        Issue.record("a stopped conversation's server allowed a call")
        return
    }
    #expect(message.contains("ended"))
    #expect(journal.outcomes == ["conversation-ended"])
}

@Test func aStopWhileWaitingDenies() async throws {
    let broker = ConfirmationBroker()
    let (server, path) = try await makeServer(broker: broker)
    async let answer = exchange(path, call(allowed: false, readOnly: false))
    _ = try await parked(in: broker)
    await server.stop()
    await broker.cancelAgentProposal(inConversation: "conv-1")
    let reply = try await answer
    #expect(reply["decision"] == "deny")
    #expect(reply["message"]?.contains("ended") == true)
}

@Test func theSocketIsOwnerOnlyAndAStaleFileIsReplaced() async throws {
    let path = shortSocketPath()
    FileManager.default.createFile(atPath: path, contents: Data("stale".utf8))
    let (server, _) = try await makeServer(path: path)
    defer { Task { await server.stop() } }
    var info = stat()
    #expect(lstat(path, &info) == 0)
    #expect(info.st_mode & S_IFMT == S_IFSOCK)
    #expect(info.st_mode & 0o777 == 0o600)
}

@Test func aLineOverOneMebibyteIsDenied() async throws {
    let (server, path) = try await makeServer()
    defer { Task { await server.stop() } }
    let big = try JSONEncoder().encode(ConnectionCallRequest(
        connection: "tracker", tool: "create_issue",
        arguments: .object(["body": .string(String(repeating: "x", count: 1 << 20))]),
        allowed: true, readOnly: true, locked: false))
    #expect(big.count > 1 << 20)
    let reply = try await exchange(path, big)
    #expect(reply["decision"] == "deny")
}

@Test func aLineThatIsNotARequestIsDenied() async throws {
    let (server, path) = try await makeServer()
    defer { Task { await server.stop() } }
    // A request that names no flags approves nothing: it does not decode.
    let reply = try await exchange(path, Data(#"{"connection":"tracker","tool":"create_issue","arguments":{}}"#.utf8))
    #expect(reply["decision"] == "deny")
}

@Test func concurrentConnectionsAreEachAnswered() async throws {
    let broker = ConfirmationBroker()
    let (server, path) = try await makeServer(broker: broker)
    defer { Task { await server.stop() } }
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

@MainActor
@Test func aVoiceTurnIsSpokenUntilItEnds() async throws {
    let harness = TurnHarness()
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot, harnessFactory: { _, _ in harness })
    await model.send("create the issue", via: .voice)
    let conversation = try #require(model.currentAgent?.id)
    #expect(model.turnIsSpoken(conversation: conversation))
    harness.continuation.yield(.result(isError: false, text: "done"))
    for _ in 0..<200 where model.turnIsSpoken(conversation: conversation) {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!model.turnIsSpoken(conversation: conversation))
}

@MainActor
@Test func aTypedTurnIsNotSpoken() async throws {
    let harness = TurnHarness()
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot, harnessFactory: { _, _ in harness })
    await model.send("create the issue", via: .voice)
    let conversation = try #require(model.currentAgent?.id)
    // A typed turn while the spoken one runs (Rule 5) is the operator's own words.
    await model.send("and label it")
    #expect(!model.turnIsSpoken(conversation: conversation))
}

@MainActor
@Test func anUnknownConversationCountsAsSpoken() {
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot)
    #expect(model.turnIsSpoken(conversation: "no-such-conversation"))
}
