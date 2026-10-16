import Foundation

/// One tool a server advertised via `tools/list`: its name, human-readable
/// description, and the JSON Schema for the arguments `callTool` expects.
public struct MCPToolDescriptor: Sendable, Equatable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue
}

/// Errors `MCPClient` throws itself, as opposed to errors relayed from the
/// server as a JSON-RPC error object.
public enum MCPClientError: Error, Sendable {
    /// `start()` was never called, or the child process is not running.
    case notRunning
    /// A request got no reply within the budget its caller set (see
    /// `MCPClient.readReplyTimeout` and `MCPClient.mutationReplyTimeout`).
    /// The continuation for it has already been removed from the pending
    /// map, so a late reply (if one ever arrives) is silently dropped
    /// rather than resuming anything.
    ///
    /// **This says nothing about what the server did.** Wakil stopped
    /// waiting; it did not stop the server. For a read that is harmless —
    /// a read changes nothing and can simply be retried — and this case is
    /// left to speak for itself there. For anything that writes it is not,
    /// and the caller is responsible for saying so: see
    /// `StandardActionError.mutationFateUnknown`, which is what
    /// `db_run_mutation` turns this into.
    case timeout(method: String)
    /// The server replied with a JSON-RPC error object rather than a
    /// result.
    case rpcError(code: Int, message: String)
    /// The transport (the child's stdout pipe) closed, or `FrameReader`
    /// latched a decode error, while a request was outstanding or being
    /// made. Per `FrameReader`'s contract this connection is permanently
    /// unusable; a fresh `MCPClient` is required.
    case transportClosed(underlying: Error?)
    /// A JSON-RPC result did not have the shape a specific call expects
    /// (e.g. `tools/list` without a `tools` array).
    case malformedResult(String)
}

/// Reaches the operator wherever `WindowModel` renders a caught error into
/// `status` — `"agent: \(error)"`, `"resume <id>: \(error)"`, and
/// `ContextStore`'s own path, since `MCPClient`'s errors propagate through
/// that store unchanged rather than being translated.
///
/// **`timeout` keeps saying nothing about what the server did**, because
/// that is this case's whole contract: Wakil stopped waiting; it did not
/// stop the server. Wording it as "gave up waiting" rather than "failed"
/// is the difference between an operator who retries a read and one who
/// assumes a write did not happen. Anything that writes turns this into
/// `StandardActionError.mutationFateUnknown` long before it reaches here.
extension MCPClientError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .notRunning:
            return "the server is not running"
        case .timeout(let method):
            return "gave up waiting for \(method) \u{2014} the server may still be working on it"
        case .rpcError(let code, let message):
            return "\(message) (code \(code))"
        case .transportClosed(let underlying):
            let detail = underlying.map { ": \($0)" } ?? ""
            return "the connection to the server closed\(detail) \u{2014} it cannot be reused"
        case .malformedResult(let message):
            return message
        }
    }
}

/// A stdio JSON-RPC client for one child MCP server process, speaking the
/// newline-framed protocol `JSONRPC.swift` defines. Spawns the executable
/// given to `init`, performs the `initialize`/`notifications/initialized`
/// handshake in `start()`, and exposes `tools/list` and `tools/call` as
/// `listTools()`/`callTool(name:arguments:timeout:)`.
///
/// All mutable state (the process handle, the pending-request map, the
/// frame reader) lives on the actor, so concurrent callers can issue
/// requests from multiple tasks without racing each other; responses are
/// matched back to callers by JSON-RPC id and may arrive out of order.
public actor MCPClient {
    private let executable: URL
    private let arguments: [String]
    /// Mutable since 2b-viii: an org switch restarts this client under a
    /// new WAKIL_ORG rather than building a new instance, because the
    /// action handlers registered in WakilWiring.build closed over THIS
    /// instance and a replacement would strand every one of them.
    private var environment: [String: String]

    private var process: Process?

    /// The pid of the child this client is currently driving, or `nil`
    /// when it is not running.
    ///
    /// **Published so an org switch can be proven rather than described**
    /// (#185). "Restarted in place" is a claim about the PROCESS behind an
    /// actor whose identity deliberately does not change, so no other
    /// observable distinguishes a client that came back from one that was
    /// never stopped — and the failure that matters, a client left running
    /// under the outgoing org, looks exactly like success from the
    /// outside. The pid is the one thing that differs.
    ///
    /// `internal`, not `public`: the tests reach it through `@testable`,
    /// and this is the actor's only state accessor — the rest of its
    /// surface is behaviour. Widening `WakilKit`'s API for a test-only
    /// affordance would be the wrong trade.
    var processIdentifier: Int32? {
        guard let process, process.isRunning else { return nil }
        return process.processIdentifier
    }

    private var stdinHandle: FileHandle?
    /// The in-flight (or, once teardown finishes, about-to-be-cleared)
    /// single-flight teardown `Task` `stop()` uses. See `stop()`'s doc
    /// comment for why this exists.
    private var teardownTask: Task<Void, Never>?

    private var frameReader = FrameReader()
    private var nextRequestID = 1

    /// One outstanding request: the method name (kept only so a timeout
    /// error can say what timed out) and the continuation blocking the
    /// caller.
    private struct PendingRequest {
        let method: String
        let continuation: CheckedContinuation<JSONRPCMessage, Error>
    }
    private var pending: [Int: PendingRequest] = [:]
    private var pendingTimeouts: [Int: Task<Void, Never>] = [:]

    /// Set once the transport becomes unusable — either `FrameReader`
    /// latched an error, or the child's stdout closed. Once set, every new
    /// request fails fast instead of hanging on a pipe that will never
    /// produce another reply.
    private var transportError: Error?

    /// Whether the stdout- and stderr-draining background threads have
    /// each observed end-of-file, so `stop()` can wait for both before
    /// returning.
    private var stdoutFinished = false
    private var stderrFinished = false
    private var drainWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var nextDrainWaiterID = 0

    /// How long `performTeardown` waits for BOTH drain threads to observe
    /// end-of-file before giving up on them.
    ///
    /// **Two seconds, which is this repo's standing budget for a child to
    /// finish exiting** — the same constant, for the same reason, as
    /// `ClaudeCodeCLIHarness.stdoutDrainDeadlineNanoseconds` and
    /// `TerminalSession.teardownDeadlineSeconds`. The three teardown paths
    /// in this package now share one policy rather than each inventing its
    /// own.
    ///
    /// **Why this wait had to become bounded at all.** A pipe reaches EOF
    /// only when the LAST write end closes — not when the child this actor
    /// spawned exits. Anything that inherited stdout or stderr from this
    /// process keeps it open, and this wait then never returns: `stop()`
    /// never returns, and every caller awaiting it is parked for the life
    /// of the process. That is not hypothetical. It is exactly what wedged
    /// `make app-test` for 45 minutes, four times, when a terminal pane's
    /// `forkpty`'d shell inherited these very pipes — see
    /// `TerminalSession.spawn`, which no longer lets a shell inherit them,
    /// and `.superpowers/sdd/2026-09-17-phase-2c-iii-terminal-pane/gate-wedge-report.md`.
    ///
    /// The fd fix removes today's cause. **The deadline is what makes the
    /// next one a named failure instead of 45 minutes of silence**, which
    /// is the more durable half: any future holder of these descriptors —
    /// a grandchild, a dependency's `popen`, a raw `fork` — now costs one
    /// recorded abandonment rather than a hang with no thread of ours in a
    /// deadlock anywhere.
    ///
    /// Generous in the safe direction, as the harness's equivalent comment
    /// argues: expiring early loses the tail of a dead child's output,
    /// expiring late merely delays a teardown nobody is watching.
    static let drainDeadlineNanoseconds: UInt64 = 2_000_000_000

    /// Each drain wait that hit `drainDeadlineNanoseconds` instead of EOF,
    /// and which of the two pipes was still open when it did.
    ///
    /// **Recorded rather than merely survived**, the way
    /// `TerminalStore.abandonedResources` records an abandoned pty: a
    /// give-up that leaves no trace is indistinguishable from a clean
    /// teardown, and this one means a descriptor of ours is held by a
    /// process we did not account for. Nothing is closed on expiry —
    /// `close(2)` on an fd a thread is parked reading is the forever-block
    /// this package avoids everywhere else — so the drain thread is left
    /// running and this says so.
    public struct AbandonedDrain: Sendable, Equatable {
        public let stdoutReachedEOF: Bool
        public let stderrReachedEOF: Bool
    }

    private(set) var abandonedDrains: [AbandonedDrain] = []

    public init(executable: URL, arguments: [String], environment: [String: String]) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }

    // MARK: - Reply budgets

    /// The reply budget for a request that only READS: the handshake,
    /// `tools/list`, and every `.read`/`.control` action's tool call.
    ///
    /// Ten seconds was sized for exactly this traffic and is generous for
    /// it. `wakilcore.clampReadLimit` caps a `query` at 1000 rows and
    /// defaults it to 500, `list_databases` reads a config file, and the
    /// `ctx_` tools read and write small JSON under `~/.wakil` — none of
    /// which takes a healthy engine more than a fraction of a second.
    ///
    /// **What makes ten seconds SAFE here is not the margin, it is that
    /// abandoning a read costs nothing.** A read changes no state, so a
    /// caller that gives up too early has lost only an answer it can ask
    /// for again. That property is what stops this constant from also
    /// being the right one for a write — see `mutationReplyTimeout`.
    public static let readReplyTimeout: TimeInterval = 10

    /// The reply budget for a request that WRITES — today, exactly
    /// `db_run_mutation`'s `mutate` call.
    ///
    /// **Deliberately a different number from `readReplyTimeout`, and the
    /// difference is the point.** The two are not "the same timeout, one
    /// tuned looser". They are bounds on two different things:
    ///
    ///   - A read's budget bounds a wait whose abandonment is free.
    ///   - A mutation's budget bounds a wait whose abandonment is NOT
    ///     free, because giving up does not roll anything back. The
    ///     statement keeps running inside the engine, holding its locks,
    ///     and commits or fails on its own schedule with nobody listening.
    ///     Whatever Wakil reports at that moment is a report about Wakil's
    ///     patience, not about the database.
    ///
    /// So this number has to be long enough that a legitimate write is
    /// almost never abandoned. A single `DELETE`/`UPDATE` across a large
    /// table, or one waiting behind another transaction's row locks, can
    /// honestly take minutes; ten seconds would turn an ordinary
    /// housekeeping delete into a call Wakil reports as failed while it
    /// commits. Five minutes is chosen as the point past which a *single*
    /// INSERT/UPDATE/DELETE (the only three statements
    /// `wakilcore.AssertSQLMutation` allows through — no DDL, no
    /// multi-statement scripts) has almost certainly hit something no
    /// amount of further waiting fixes.
    ///
    /// **It is not removed altogether, and must not be.** `MCPClient`'s
    /// callers run on the main actor by way of `WindowModel`, and the
    /// socket server's `Connection` serves one request at a time, so an
    /// unbounded wait is a hung window and a dead connection rather than
    /// patience.
    ///
    /// **A timeout here therefore remains possible, and is handled rather
    /// than hoped away.** See `StandardActionError.mutationFateUnknown`
    /// and `recordUncertainMutation` for what a caller must say and record
    /// when this budget runs out.
    public static let mutationReplyTimeout: TimeInterval = 300

    /// Spawns the child process, then performs the MCP handshake: sends
    /// `initialize` and awaits its reply, then sends the
    /// `notifications/initialized` notification. The notification has no
    /// `id` and expects no reply, so it is fire-and-forget — unlike every
    /// other outgoing message here, it does not go through `sendRequest`.
    ///
    /// **`environment` re-points the client, and is how an org switch
    /// works** (spec §3). Passing `nil` keeps whatever this client was
    /// last started with, so the ordinary first start is unchanged. It is
    /// a parameter here rather than a `restart` method of its own because
    /// the reset below and the re-point are one statement about what
    /// starting means, and because the stop-then-start ordering belongs
    /// at the call site, where the invalidation is ordered against it.
    ///
    /// **The four resets are required and are safe for a structural
    /// reason.** `stop()` lets the stdout drain thread reach EOF, which
    /// sets `transportError = .transportClosed`; `sendRequest` throws any
    /// latched `transportError` (`:359`), so the `initialize` at the end
    /// of this very method would be rejected by the PREVIOUS child's
    /// death. They are safe to clear because `stop()` awaits
    /// `waitForDrainToFinish()`, which does not return until both drain
    /// threads have run their actor-isolated callbacks — so no old thread
    /// survives to re-set the error after this point. A restart that did
    /// not await drain would have exactly that race; this one cannot.
    ///
    /// On a never-started instance all four already hold these values, so
    /// the started-once path is unchanged in behaviour.
    public func start(environment: [String: String]? = nil) async throws {
        if let environment { self.environment = environment }
        transportError = nil
        stdoutFinished = false
        stderrFinished = false
        frameReader = FrameReader()

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = self.environment

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        self.process = process
        self.stdinHandle = stdinPipe.fileHandleForWriting

        startStdoutDrainThread(stdoutPipe.fileHandleForReading)
        startStderrDrainThread(stderrPipe.fileHandleForReading)

        let initParams = JSONValue.object([
            "protocolVersion": .string("2024-11-05"),
            "capabilities": .object([:]),
            "clientInfo": .object([
                "name": .string("wakil"),
                "version": .string("2a"),
            ]),
        ])
        _ = try await sendRequest(
            method: "initialize", params: initParams, timeout: Self.readReplyTimeout)
        try sendNotification(method: "notifications/initialized", params: .object([:]))
    }

    /// Lists the tools the server advertises via `tools/list`.
    public func listTools() async throws -> [MCPToolDescriptor] {
        let result = try await sendRequest(
            method: "tools/list", params: .object([:]), timeout: Self.readReplyTimeout)
        guard case .object(let obj) = result, case .array(let toolsValue)? = obj["tools"] else {
            throw MCPClientError.malformedResult("tools/list result has no \"tools\" array")
        }
        return try toolsValue.map(Self.parseToolDescriptor)
    }

    private static func parseToolDescriptor(_ value: JSONValue) throws -> MCPToolDescriptor {
        guard case .object(let obj) = value, case .string(let name)? = obj["name"] else {
            throw MCPClientError.malformedResult("tool descriptor has no string \"name\"")
        }
        // Every tool this client has been run against (wakil-ctx's seven)
        // sets a description, but the MCP spec does not require one, so a
        // missing or non-string value degrades to "" rather than throwing.
        let description: String
        if case .string(let d)? = obj["description"] {
            description = d
        } else {
            description = ""
        }
        let inputSchema = obj["inputSchema"] ?? .object([:])
        return MCPToolDescriptor(name: name, description: description, inputSchema: inputSchema)
    }

    /// Calls `name` with `arguments` via `tools/call` and returns the raw
    /// `result` value.
    ///
    /// A server-side tool failure (the wakil-ctx pattern of returning a
    /// `CallToolResult` with `isError: true`) is still a successful
    /// JSON-RPC response — it comes back as a normal result object, not a
    /// thrown error, and it is the caller's job to check the tool-specific
    /// `isError` field inside it. Only a JSON-RPC-level error object
    /// (malformed request, unknown method, transport failure) throws
    /// `MCPClientError.rpcError` here.
    public func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        let params = JSONValue.object(["name": .string(name), "arguments": arguments])
        return try await sendRequest(method: "tools/call", params: params, timeout: timeout)
    }

    /// Terminates the child process and waits for both pipe-draining
    /// threads to observe end-of-file before returning, so no buffered
    /// output from a just-killed process is left unread — **or for
    /// `drainDeadlineNanoseconds`, whichever comes first.** That bound is
    /// not a nicety: EOF requires every holder of these pipes' write ends
    /// to have closed, which is not something this actor can guarantee
    /// about a process it does not own. See `drainDeadlineNanoseconds` and
    /// `abandonedDrains` for what expiry costs and where it is recorded.
    ///
    /// Safe to call concurrently, more than once, or on a client that
    /// never started. Teardown is single-flight: the first caller to
    /// arrive runs `performTeardown` and every other caller — whether it
    /// arrived while teardown was already in progress, or calls `stop()`
    /// again afterwards — just awaits that same `Task`'s result instead of
    /// starting a second teardown of its own. This is load-bearing, not
    /// cosmetic: an earlier version of this method re-checked `process !=
    /// nil` on every call with no such guard, so two concurrent callers
    /// both passed that check before either had torn down anything, and
    /// the second call's `waitForProcessExit` then overwrote the first
    /// call's `process.terminationHandler`. Measured directly on a bare
    /// `Process` on this machine (assigning two different
    /// `terminationHandler` closures before the child exited, then letting
    /// it exit): only the second-assigned handler ever fired: no crash, no
    /// warning, no queuing or chaining of the first — it is simply
    /// dropped. Under the old code that meant the first caller's
    /// continuation was never resumed, hanging that caller permanently.
    /// See `MCPClientTests.concurrentStopCallsOnTheSameClientAllReturn` for
    /// the regression test and its measured before/after numbers.
    ///
    /// The `if let teardownTask` check and the `Task { ... }`/assignment
    /// that follows it when there is none yet are both synchronous actor-
    /// isolated code with no `await` in between, so they run atomically
    /// with respect to any other call to `stop()`: there is no window in
    /// which two concurrent callers could each decide to start their own
    /// teardown.
    public func stop() async {
        if let teardownTask {
            await teardownTask.value
            return
        }
        guard let process else { return }
        let task = Task {
            await self.performTeardown(process)
        }
        teardownTask = task
        await task.value
    }

    /// The actual teardown work, run at most once per `stop()`
    /// single-flight cycle (see `stop()`'s doc comment). Clears
    /// `teardownTask` as its last step so a `stop()` call made after a
    /// *subsequent* `start()` starts a fresh teardown of its own rather
    /// than replaying this one's already-`nil` `process`.
    private func performTeardown(_ process: Process) async {
        if process.isRunning {
            process.terminate()
        }
        await waitForProcessExit(process)
        await waitForDrainToFinish()
        try? stdinHandle?.close()
        failAllPending(with: MCPClientError.transportClosed(underlying: nil))
        self.process = nil
        self.stdinHandle = nil
        teardownTask = nil
    }

    /// Awaits process exit without blocking the calling thread.
    ///
    /// `Process.waitUntilExit()` blocks synchronously until the child dies.
    /// Calling it from this actor-isolated `async` method ties up whichever
    /// thread Swift's cooperative executor pool handed this task for as
    /// long as the child takes to exit. That pool is small and shared by
    /// every actor-isolated and unstructured `Task` in the process
    /// (including the chunk-consuming `Task` `startStdoutDrainThread`
    /// spawns and the timeout `Task`s `sendRequest` spawns on this same
    /// actor), so enough of these blocking calls in flight at
    /// once starve it, and every actor-isolated call in the process —
    /// including a later `stop()` itself — stops making progress.
    ///
    /// This was not hypothetical: reverting this method to
    /// `process.waitUntilExit()` and driving `MCPClient` through the
    /// concurrent start/stop stress in
    /// `MCPClientTests.concurrentStartStopCyclesCompleteWithoutDeadlocking`
    /// (16 lanes each doing 4 cycles against the real `bin/wakil-ctx`, all
    /// running at once) produced, across 6 back-to-back runs on this
    /// machine: 1 permanent hang inside `stop()` (killed after 75s
    /// wall-clock, with the child already exited) and 1 more failure via
    /// the 10-second per-request timeout inside `start()`, against only 4
    /// of 6 that completed. With the fix below in place, the identical
    /// test body completed in well under a second on all of 8 back-to-back
    /// runs. See that test's comment for the full numbers.
    ///
    /// `terminationHandler` is Foundation's non-blocking equivalent, and it
    /// is race-safe to install after the child has already exited: measured
    /// directly on this machine (spawning `/bin/echo`, waiting for it to
    /// exit via `waitUntilExit()`, then assigning `terminationHandler`
    /// afterwards), the handler still fired. So there is no window in which
    /// installing the handler after `terminate()` — which may itself win
    /// the race against the child dying — leaves this continuation
    /// unresumed.
    private func waitForProcessExit(_ process: Process) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in
                continuation.resume()
            }
        }
    }

    // MARK: - Request/response plumbing

    /// Sends `method`/`params` as a JSON-RPC request with a fresh
    /// monotonically increasing id, and awaits the matching reply, subject
    /// to `timeout` seconds.
    ///
    /// `timeout` is per request rather than one constant for the whole
    /// client because the right bound depends on what the request does:
    /// see `readReplyTimeout` and `mutationReplyTimeout`, which are the
    /// only two values passed here today and whose doc comments carry the
    /// reason they differ.
    ///
    /// The write to stdin and the registration of the pending continuation
    /// happen inside the `withCheckedThrowingContinuation` operation
    /// closure, before that closure returns and the calling task suspends.
    /// Nothing else can run on this actor in between (an actor only yields
    /// at an `await`), so a reply for this id cannot arrive and find no
    /// entry in `pending` to match against.
    private func sendRequest(
        method: String, params: JSONValue?, timeout: TimeInterval
    ) async throws -> JSONValue {
        guard let process, process.isRunning else { throw MCPClientError.notRunning }
        if let transportError { throw transportError }
        guard let stdinHandle else { throw MCPClientError.notRunning }

        try Task.checkCancellation()
        let id = nextRequestID
        nextRequestID += 1
        let frame = try encodeFrame(JSONRPCMessage(id: .number(id), method: method, params: params))

        // W14: a caller that stops waiting cancels the call, not just its own wait. The server
        // is told with `notifications/cancelled`, and `wakil-http` aborts the request through
        // the call's context (proved in `cmd/wakil-http/cancel_test.go`).
        let response = try await withTaskCancellationHandler {
            try await awaitReply(
                id: id, method: method, frame: frame, stdinHandle: stdinHandle, timeout: timeout)
        } onCancel: {
            Task { await self.cancelPending(id: id) }
        }

        if let rpcError = response.error {
            throw MCPClientError.rpcError(code: rpcError.code, message: rpcError.message)
        }
        return response.result ?? .null
    }

    /// The waiting half of `sendRequest`: writes the frame, registers the continuation, and
    /// arms the timeout, all before the calling task suspends (see `sendRequest`).
    private func awaitReply(
        id: Int, method: String, frame: Data, stdinHandle: FileHandle, timeout: TimeInterval
    ) async throws -> JSONRPCMessage {
        try await withCheckedThrowingContinuation { continuation in
            pending[id] = PendingRequest(method: method, continuation: continuation)
            do {
                try stdinHandle.write(contentsOf: frame)
            } catch {
                pending.removeValue(forKey: id)
                continuation.resume(throwing: error)
                return
            }
            pendingTimeouts[id] = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                // No `await` on this call: a `Task` created from code already
                // isolated to this actor inherits that isolation, so this is
                // already running on the actor by the time `Task.sleep`
                // returns.
                self.failIfStillPending(id: id, method: method)
            }
            // A cancel that arrived before the continuation was registered: the handler's
            // `cancelPending` found nothing to resume, so this one does.
            if Task.isCancelled { cancelPending(id: id) }
        }
    }

    /// A caller cancelled call `id` (W14). It is resumed with `CancellationError`, and the server
    /// is told. A reply that already arrived has removed the entry, so this does nothing then.
    private func cancelPending(id: Int) {
        pendingTimeouts.removeValue(forKey: id)?.cancel()
        guard let request = pending.removeValue(forKey: id) else { return }
        request.continuation.resume(throwing: CancellationError())
        // `sendRequest`'s own guard: a server that has exited has nothing to tell.
        guard let process, process.isRunning else { return }
        // Neutral: every cancelled MCP call says this, not only the operator's Cancel.
        try? sendNotification(method: "notifications/cancelled", params: .object([
            "requestId": .integer(Int64(id)), "reason": .string("cancelled by the client"),
        ]))
    }

    /// Sends a notification: a message with no `id`, which the protocol
    /// says expects no reply. Never registers a pending continuation.
    private func sendNotification(method: String, params: JSONValue?) throws {
        guard let stdinHandle else { throw MCPClientError.notRunning }
        let frame = try encodeFrame(JSONRPCMessage(id: nil, method: method, params: params))
        try stdinHandle.write(contentsOf: frame)
    }

    /// Fires once that request's own budget has elapsed. If its continuation is
    /// still in `pending`, the reply never arrived in time: remove the
    /// entry and resume with a timeout error. If it is already gone —
    /// because the reply arrived and `route` already resumed it — this is
    /// a no-op, which is what keeps a late-arriving reply from ever trying
    /// to resume a continuation a second time.
    private func failIfStillPending(id: Int, method: String) {
        pendingTimeouts.removeValue(forKey: id)
        guard let request = pending.removeValue(forKey: id) else { return }
        request.continuation.resume(throwing: MCPClientError.timeout(method: method))
    }

    /// Matches an incoming message to its waiting caller by id and resumes
    /// it. Also cancels that id's timeout `Task`, purely so it wakes up
    /// promptly instead of idling out the rest of its sleep:
    /// `cancel()` does not stop the task's body from running (`try?`
    /// swallows the `CancellationError` `Task.sleep` throws, so
    /// `failIfStillPending` still executes afterwards either way) — it is
    /// `failIfStillPending`'s own guard, not the cancellation, that makes
    /// the entry already being removed here a safe no-op there. Messages
    /// with no id, or with an id this client never issued, are dropped:
    /// this client only ever calls a server, so it never expects an
    /// unsolicited request or notification back.
    private func route(_ message: JSONRPCMessage) {
        guard case .number(let id)? = message.id, let request = pending.removeValue(forKey: id) else { return }
        pendingTimeouts.removeValue(forKey: id)?.cancel()
        request.continuation.resume(returning: message)
    }

    /// Fails every outstanding request with `error`. Called once the
    /// transport is known dead, so no reply for any of them will ever
    /// arrive.
    private func failAllPending(with error: Error) {
        let all = pending
        pending.removeAll()
        for (id, request) in all {
            pendingTimeouts.removeValue(forKey: id)?.cancel()
            request.continuation.resume(throwing: error)
        }
    }

    // MARK: - Reading the child's pipes

    /// Feeds one chunk of stdout bytes through `frameReader` and routes
    /// each decoded message. `FrameReader` is latching (see its doc
    /// comment): a decode error or oversized buffer is unrecoverable for
    /// that reader, so on the first such error this method records it in
    /// `transportError`, fails every outstanding request with it, and
    /// stops calling `push` again — a poisoned `FrameReader` would just
    /// rethrow the same latched error on every subsequent call anyway.
    private func handleStdoutData(_ data: Data) {
        guard transportError == nil else { return }
        do {
            let messages = try frameReader.push(data)
            for message in messages {
                route(message)
            }
        } catch {
            transportError = MCPClientError.transportClosed(underlying: error)
            failAllPending(with: transportError!)
        }
    }

    /// Records that the stdout-reading thread reached end-of-file (the
    /// child closed or exited). If the transport had not already been
    /// marked broken by a `FrameReader` error, mark it now — no further
    /// reply will ever arrive on a closed pipe — and fail anything still
    /// waiting.
    private func stdoutReachedEOF() {
        if transportError == nil {
            transportError = MCPClientError.transportClosed(underlying: nil)
            failAllPending(with: transportError!)
        }
        stdoutFinished = true
        resumeDrainWaitersIfBothFinished()
    }

    private func stderrReachedEOF() {
        stderrFinished = true
        resumeDrainWaitersIfBothFinished()
    }

    private func resumeDrainWaitersIfBothFinished() {
        guard stdoutFinished, stderrFinished else { return }
        let waiters = drainWaiters
        drainWaiters.removeAll()
        for waiter in waiters.values {
            waiter.resume()
        }
    }

    /// Waits for both drain threads to reach end-of-file, or for
    /// `drainDeadlineNanoseconds`, whichever comes first.
    ///
    /// Same shape as `ClaudeCodeCLIHarness.waitForStdoutDrain`, deliberately:
    /// the deadline `Task` is formed in actor-isolated code, so it inherits
    /// this actor's isolation and cannot run before this method suspends —
    /// which happens only after the closure below has registered the waiter.
    /// There is therefore no window in which the deadline fires against a
    /// waiter that does not exist yet.
    private func waitForDrainToFinish() async {
        if stdoutFinished, stderrFinished { return }
        let id = nextDrainWaiterID
        nextDrainWaiterID += 1
        let deadline = Task {
            try? await Task.sleep(nanoseconds: Self.drainDeadlineNanoseconds)
            self.abandonDrainWaiter(id)
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            drainWaiters[id] = continuation
        }
        // Purely so the deadline task stops idling out the rest of its sleep
        // once EOF has already released this waiter. Removal-before-resume
        // in both paths is what makes a late firing a no-op, not this.
        deadline.cancel()
    }

    /// Gives up on one parked drain wait, recording what was still open.
    /// A no-op if `resumeDrainWaitersIfBothFinished` already released it,
    /// which is what keeps a deadline firing just after EOF from resuming
    /// a continuation twice.
    private func abandonDrainWaiter(_ id: Int) {
        guard let waiter = drainWaiters.removeValue(forKey: id) else { return }
        abandonedDrains.append(
            AbandonedDrain(stdoutReachedEOF: stdoutFinished, stderrReachedEOF: stderrFinished))
        waiter.resume()
    }

    /// Spawns a plain background `Thread` that blocks on `FileHandle.availableData`
    /// in a loop, handing each chunk to the actor through the serial
    /// `AsyncStream` `consumeStdout` drains. A dedicated thread (rather than
    /// `Task.detached`) is used specifically because the read blocks: parking a
    /// blocking call on a Swift concurrency cooperative-pool thread would risk
    /// starving that pool, whereas a plain `Thread` only ties up itself.
    ///
    /// The chunks travel over an `AsyncStream` rather than one unstructured
    /// `Task { await self.handleStdoutData(data) }` each, because unstructured
    /// `Task`s have no ordering relative to one another: two chunks read
    /// microseconds apart could reach `frameReader` in either order, and
    /// `FrameReader` is reassembling a *byte* stream, so an inversion does not
    /// merely reorder frames — it splices the bytes of one frame into the
    /// middle of another. `FrameReader` then latches the resulting decode
    /// error and, per its contract, this whole connection is dead. Measured
    /// directly on this machine before this fix, against a fake server
    /// replying with 60 KB frames (large enough that one frame always spans
    /// several reads), over four runs of ten clients each: 1, 3, 4 and 10 of
    /// every 10 clients lost their transport, most of them with
    /// `transportClosed(DecodingError … Unexpected character 'x' around line
    /// 1, column 1)` — the padding bytes of one reply arriving ahead of that
    /// reply's own opening brace. `yield` is synchronous and non-blocking, so
    /// the blocking read stays on this plain `Thread`, and an `AsyncStream`
    /// delivers to its single consumer in exactly yield order. `.unbounded`
    /// buffering because every bounded policy drops elements when full, and a
    /// dropped chunk here is a hole punched in the middle of the byte stream.
    ///
    /// EOF is likewise not a separate `Task`: the thread finishes the chunk
    /// stream, and `consumeStdout` calls `stdoutReachedEOF` only after the
    /// loop has drained everything already yielded. That matters because
    /// `stdoutReachedEOF` fails every outstanding request with
    /// `transportClosed` — an EOF that overtook the chunk carrying the last
    /// reply would report a dead transport to a caller whose answer had, in
    /// fact, already arrived.
    private func startStdoutDrainThread(_ handle: FileHandle) {
        let (chunks, chunkSink) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .unbounded)
        // Strong `self`, unlike the `[weak self]` the per-chunk-`Task`
        // version used: this task is the chunk stream's only consumer and
        // ends of its own accord when the drain thread finishes that stream
        // at EOF, so it keeps this actor alive for exactly as long as chunks
        // remain to be delivered.
        Task { await self.consumeStdout(chunks) }
        let thread = Thread {
            while true {
                let data = handle.availableData
                if data.isEmpty {
                    chunkSink.finish()
                    return
                }
                chunkSink.yield(data)
            }
        }
        thread.name = "MCPClient.stdout"
        thread.start()
    }

    /// Drains the stdout chunk stream one chunk at a time, in yield order,
    /// then reports EOF. Being its single consumer is what makes this
    /// ordered: each chunk is pushed through `frameReader` to completion
    /// before the next is taken, and the line after the loop is reached only
    /// once the stream has been finished *and* emptied.
    private func consumeStdout(_ chunks: AsyncStream<Data>) async {
        for await chunk in chunks {
            handleStdoutData(chunk)
        }
        stdoutReachedEOF()
    }

    /// Drains stderr on its own plain `Thread`, for the same blocking-read
    /// reason as stdout, purely so the child can never block on a full stderr
    /// pipe; its bytes are discarded rather than parsed, since nothing in the
    /// MCP protocol is carried on stderr.
    ///
    /// This one keeps the single unstructured `Task`, because it dispatches
    /// exactly one thing ever — the EOF — and one `Task` cannot be out of
    /// order with respect to itself. There is no chunk stream to order it
    /// against, since the chunks are dropped on this thread and never reach
    /// the actor at all.
    private func startStderrDrainThread(_ handle: FileHandle) {
        let thread = Thread { [weak self] in
            while true {
                let data = handle.availableData
                guard let self else { return }
                if data.isEmpty {
                    Task { await self.stderrReachedEOF() }
                    return
                }
            }
        }
        thread.name = "MCPClient.stderr"
        thread.start()
    }
}
