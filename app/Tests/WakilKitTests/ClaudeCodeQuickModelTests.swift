import Testing
import Foundation
@testable import WakilKit

@Suite struct ClaudeCodeQuickModelTests {
    @Test func quickLaunchArgumentsAreTheGlobalConstraint() {
        let a = quickLaunchArguments()
        #expect(a.starts(with: ["--model", "haiku", "--tools", "", "--no-session-persistence", "--system-prompt"]))
        #expect(a.last == QuickPrompts.system)
        // buildLaunch already emits the MCP pair from its own argument.
        #expect(!a.contains("--mcp-config") && !a.contains("--strict-mcp-config"))
    }

    @Test func infillTurnCarriesExtrasAndCursor() async throws {
        let h = FakeHarness(replies: ["ConfirmedAt = time.Now()"])
        let m = ClaudeCodeQuickModel { h }
        let out = try await m.infill(InfillRequest(prefix: "b.", suffix: "\n}", path: "a.go", language: "go",
                                                  extras: [QuickExtra(name: "schema.sql", text: "CREATE TABLE bookings (id);")], multiline: false))
        #expect(out == "ConfirmedAt = time.Now()")
        let turn = try #require(await h.sent.first)
        #expect(turn.contains("schema.sql") && turn.contains("CREATE TABLE bookings"))
        #expect(turn.contains("b.<CURSOR>\n}"))
        #expect(await h.starts == 1)
    }

    @Test func respondWithSchemaReasksOnceThenThrows() async throws {
        let ok = FakeHarness(replies: ["not json", #"{"action":"open"}"#])
        #expect(try await ClaudeCodeQuickModel { ok }.respond(RespondRequest(instructions: "i", input: "x", jsonSchema: #"{"type":"object"}"#, maxTokens: 32)) == #"{"action":"open"}"#)
        #expect(await ok.sent.count == 2)
        #expect(await ok.sent.last?.hasPrefix("That reply was not valid: ") == true)
        let bad = FakeHarness(replies: ["no", "still no"])
        await #expect(throws: QuickModelError.self) {
            try await ClaudeCodeQuickModel { bad }.respond(RespondRequest(instructions: "i", input: "x", jsonSchema: #"{"type":"object"}"#, maxTokens: 32))
        }
        #expect(await bad.sent.count == 2)
    }

    @Test func respondWithoutSchemaIsOneTurn() async throws {
        let h = FakeHarness(replies: ["plain answer"])
        #expect(try await ClaudeCodeQuickModel { h }.respond(RespondRequest(instructions: "Summarise.", input: "x", jsonSchema: nil, maxTokens: 32)) == "plain answer")
        #expect(await h.sent == ["Summarise.\n\nInput:\nx"])
    }

    @Test func recyclesAfterTwentyTurnsWithAWarmSpare() async throws {
        let made = HarnessLog()
        let m = ClaudeCodeQuickModel(recycleAfter: 2) { made.next(replies: Array(repeating: "x", count: 10)) }
        for _ in 0..<5 { _ = try await m.infill(InfillRequest(prefix: "", suffix: "", path: "", language: "", extras: [], multiline: false)) }
        // turns 1-2 on #0, 3-4 on #1 (the spare started at turn 2), 5 on #2; #0 and #1 stopped.
        #expect(made.count >= 3)
        #expect(await made.harness(0).stops == 1)
        #expect(await made.harness(1).stops == 1)
        #expect(await made.harness(0).sent.count == 2)
        #expect(await made.harness(1).sent.count == 2)
        #expect(await made.harness(2).sent.count == 1)
    }

    @Test func cancellingInterruptsTheTurnAndTheNextRequestIsNotStale() async throws {
        let h = FakeHarness(replies: ["late", "fresh"], holdFirst: true)
        let m = ClaudeCodeQuickModel { h }
        let first = Task { try await m.infill(InfillRequest(prefix: "a", suffix: "", path: "", language: "", extras: [], multiline: false)) }
        await h.waitUntilSent(1)
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(await h.interrupts == 1)
        #expect(await h.sigints == 0)
        await h.release()
        #expect(try await m.infill(InfillRequest(prefix: "b", suffix: "", path: "", language: "", extras: [], multiline: false)) == "fresh")
    }

    @Test func anErrorResultIsFailedWhole() async {
        let h = FakeHarness(replies: [], errorText: "rate limited")
        await #expect(throws: QuickModelError.failed("rate limited")) {
            try await ClaudeCodeQuickModel { h }.infill(InfillRequest(prefix: "", suffix: "", path: "", language: "", extras: [], multiline: false))
        }
    }

    @Test func idleTimeoutStopsTheSessionAndTheNextTurnStartsAnother() async throws {
        let made = HarnessLog()
        let m = ClaudeCodeQuickModel(idleTimeout: .milliseconds(20)) { made.next(replies: ["x"]) }
        _ = try await m.infill(InfillRequest(prefix: "", suffix: "", path: "", language: "", extras: [], multiline: false))
        var waited = 0
        while await made.harness(0).stops == 0, waited < 200 {
            try await Task.sleep(for: .milliseconds(10))
            waited += 1
        }
        #expect(await made.harness(0).stops == 1)
        _ = try await m.infill(InfillRequest(prefix: "", suffix: "", path: "", language: "", extras: [], multiline: false))
        #expect(made.count == 2)
    }

    @Test func shutdownStopsCurrentAndSpare() async throws {
        let made = HarnessLog()
        let m = ClaudeCodeQuickModel(recycleAfter: 2) { made.next(replies: ["x"]) }
        _ = try await m.infill(InfillRequest(prefix: "", suffix: "", path: "", language: "", extras: [], multiline: false))
        await m.shutdown()
        #expect(made.count == 2)
        #expect(await made.harness(0).stops == 1)
        #expect(await made.harness(1).stops == 1)
    }
}

// MARK: - Doubles

/// Answers each `send` with an `.assistantText` then a `.result` carrying the next scripted reply.
/// `holdFirst`: the first reply waits for `release()`, and is yielded even after `interruptTurn()` —
/// a real session's interrupted turn still ends in a `result`, which the model must drop.
private actor FakeHarness: QuickHarness {
    nonisolated let stream: AsyncStream<HarnessEvent>
    private nonisolated let continuation: AsyncStream<HarnessEvent>.Continuation
    private var replies: [String]
    private let holdFirst: Bool
    private let errorText: String?
    private var held: String?
    private var sentWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    private(set) var sent: [String] = []
    private(set) var starts = 0
    private(set) var stops = 0
    /// `interruptTurn()` calls — the control request.
    private(set) var interrupts = 0
    /// `interrupt()` calls — `SIGINT`, which ends a real session; the model must not use it.
    private(set) var sigints = 0

    init(replies: [String], holdFirst: Bool = false, errorText: String? = nil) {
        (stream, continuation) = AsyncStream.makeStream(of: HarnessEvent.self)
        self.replies = replies
        self.holdFirst = holdFirst
        self.errorText = errorText
    }

    func start(sessionId: String, resumingFrom parentSessionId: String?, workingDirectory: String) async throws {
        starts += 1
    }

    func send(_ text: String) async throws {
        sent.append(text)
        let ready = sentWaiters.filter { $0.count <= sent.count }
        sentWaiters.removeAll { $0.count <= sent.count }
        ready.forEach { $0.continuation.resume() }
        if let errorText {
            continuation.yield(.result(isError: true, text: errorText))
            return
        }
        let reply = replies.isEmpty ? "" : replies.removeFirst()
        if holdFirst, sent.count == 1 { held = reply; return }
        answer(reply)
    }

    nonisolated func events() -> AsyncStream<HarnessEvent> { stream }

    func interruptTurn() async throws { interrupts += 1 }

    func interrupt() async { sigints += 1 }

    func stop() async {
        stops += 1
        continuation.finish()
    }

    func release() {
        if let held { answer(held) }
        held = nil
    }

    func waitUntilSent(_ count: Int) async {
        if sent.count >= count { return }
        await withCheckedContinuation { sentWaiters.append((count, $0)) }
    }

    private func answer(_ reply: String) {
        continuation.yield(.assistantText(reply))
        continuation.yield(.result(isError: false, text: reply))
    }
}

/// Every `FakeHarness` a model's factory has made, in order.
private final class HarnessLog: @unchecked Sendable {
    private let lock = NSLock()
    private var made: [FakeHarness] = []

    func next(replies: [String]) -> FakeHarness {
        let h = FakeHarness(replies: replies)
        lock.withLock { made.append(h) }
        return h
    }

    var count: Int { lock.withLock { made.count } }
    func harness(_ i: Int) -> FakeHarness { lock.withLock { made[i] } }
}
