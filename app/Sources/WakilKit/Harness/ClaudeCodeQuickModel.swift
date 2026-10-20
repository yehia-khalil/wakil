import Foundation

/// The text a quick-tasks `claude` session is driven with.
public enum QuickPrompts {
    public static let system = "You are a completion engine inside a code editor. Do exactly what each message asks. Reply with the result only — no prose, no code fences, no explanation."

    /// Each extra as a named block, then the file with `<CURSOR>` where the text goes.
    public static func infill(_ r: InfillRequest) -> String {
        var text = ""
        for extra in r.extras { text += "--- \(extra.name)\n\(extra.text)\n" }
        text += "--- \(r.path) (\(r.language))\n\(r.prefix)<CURSOR>\(r.suffix)\n---\n"
        text += "Reply with only the text to insert at <CURSOR>\(r.multiline ? " (up to six lines)" : " (one line)")."
        return text
    }

    public static func respond(_ r: RespondRequest) -> String {
        var text = "\(r.instructions)\n\nInput:\n\(r.input)"
        if let schema = r.jsonSchema { text += "\n\nReply with one JSON value matching this schema:\n\(schema)" }
        return text
    }
}

/// The flags that make a `claude` session a quick-tasks one: the small model, no tools, nothing
/// kept on disk, and `QuickPrompts.system` in place of Claude Code's own prompt. The tail of
/// `buildQuickLaunch`, which emits the empty `--mcp-config`/`--strict-mcp-config` pair itself.
public func quickLaunchArguments() -> [String] {
    ["--model", "haiku", "--tools", "", "--no-session-persistence", "--system-prompt", QuickPrompts.system]
}

/// A session a quick turn can be cut short in without ending it.
public protocol QuickHarness: AgentHarness {
    /// Ends the turn in flight; the session stays up, and that turn still ends in a `result`.
    func interruptTurn() async throws
}

/// A `QuickModel` on one warm `claude` session per provider, driven through `QuickHarness`.
///
/// One turn at a time: turns queue behind each other, since a session answers in order.
/// Once an operation leaves the session at `recycleAfter` turns or more, the session is stopped
/// and a spare — started when it reached `recycleAfter - 1`, so it is already warm — takes over;
/// the context of a long session is cost, not help. Recycling happens between operations, never
/// inside one, so `respond`'s re-ask always reaches the session that saw the question.
/// After `idleTimeout` with no turn, everything is stopped and the next turn starts afresh.
///
/// A cancelled turn interrupts the session, and the `result` that interrupted turn still
/// produces is dropped, so the next turn never reads a stale reply. A turn with no `result`
/// after `turnTimeout` fails, and its session is retired: a wedged session would otherwise
/// hold up every quick task queued behind it. Retired sessions are torn down in the background.
///
/// `RespondRequest.maxTokens` is ignored here: the CLI has no per-turn token limit flag.
public actor ClaudeCodeQuickModel: QuickModel {
    public nonisolated let serves: Set<QuickOperation> = [.infill, .respond]

    private struct Reply {
        var isError: Bool
        var text: String?
    }

    /// One harness, its event pump, and the turn waiting on it.
    private final class Session {
        let id: Int
        let harness: any QuickHarness
        var startup: Task<Void, Error>?
        var pump: Task<Void, Never>?
        var turns = 0
        /// Results that arrived with no turn waiting on them.
        var ready: [Reply] = []
        var waiter: (turn: Int, continuation: CheckedContinuation<Reply, Error>)?
        /// Fails `waiter` after `turnTimeout`; cancelled whenever the waiter is taken.
        var deadline: Task<Void, Never>?
        /// Results still owed by interrupted turns; each is dropped on arrival.
        var stale = 0
        var ended = false

        init(id: Int, harness: any QuickHarness) {
            self.id = id
            self.harness = harness
        }

        /// Clears the waiting turn, if any, and its deadline, and hands back its continuation.
        func takeWaiter(turn turnID: Int? = nil) -> CheckedContinuation<Reply, Error>? {
            guard let waiter, turnID == nil || waiter.turn == turnID else { return nil }
            self.waiter = nil
            deadline?.cancel()
            deadline = nil
            return waiter.continuation
        }
    }

    private let recycleAfter: Int
    private let idleTimeout: Duration
    private let turnTimeout: Duration
    private let makeHarness: @Sendable () -> any QuickHarness

    private var current: Session?
    private var spare: Session?
    private var nextSessionID = 0
    private var nextTurnID = 0
    private var busy = false
    private var queue: [CheckedContinuation<Void, Never>] = []
    private var idleTask: Task<Void, Never>?
    private var idleGeneration = 0
    /// Set by `shutdown()`: every later operation ends at once, and no session is launched again.
    private var closed = false

    public init(recycleAfter: Int = 20, idleTimeout: Duration = .seconds(600), turnTimeout: Duration = .seconds(15),
                makeHarness: @escaping @Sendable () -> any QuickHarness) {
        self.recycleAfter = max(1, recycleAfter)
        self.idleTimeout = idleTimeout
        self.turnTimeout = turnTimeout
        self.makeHarness = makeHarness
    }

    public func infill(_ request: InfillRequest) async throws -> String {
        try await exclusively { try await self.turn(QuickPrompts.infill(request)) }
    }

    public func respond(_ request: RespondRequest) async throws -> String {
        try await exclusively {
            let reply = try await self.turn(QuickPrompts.respond(request))
            guard let schema = request.jsonSchema else { return reply }
            do {
                return try QuickJSON.validate(reply, schema: schema)
            } catch QuickModelError.invalidReply(let reason) {
                let again = try await self.turn("That reply was not valid: \(reason). Reply again with only the JSON value.")
                return try QuickJSON.validate(again, schema: schema)
            }
        }
    }

    public func shutdown() async {
        closed = true
        idleTask?.cancel()
        idleTask = nil
        let sessions = [current, spare].compactMap { $0 }
        current = nil
        spare = nil
        for session in sessions { await end(session).value }
    }

    // MARK: - Turns

    /// Runs `body` with no other operation in flight, then recycles if due and re-arms the idle timer.
    private func exclusively<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        if busy {
            await withCheckedContinuation { queue.append($0) }
        }
        busy = true
        idleTask?.cancel()
        defer {
            recycleIfDue()
            if queue.isEmpty {
                busy = false
                armIdle()
            } else {
                queue.removeFirst().resume()
            }
        }
        try Task.checkCancellation()
        // After the queue, and inside the defer, so a shut-down model still hands the turn on.
        if closed { throw CancellationError() }
        return try await body()
    }

    /// Sends `text` and waits for its `result`.
    private func turn(_ text: String) async throws -> String {
        let session = try await ensureStarted()
        do {
            try await session.harness.send(text)
        } catch {
            retire(session)
            throw QuickModelError.unreachable("claude quick session did not take the turn: \(error)")
        }
        let reply = try await awaitReply(on: session)
        session.turns += 1
        if reply.isError { throw QuickModelError.failed(reply.text ?? "claude quick turn failed") }
        return reply.text ?? ""
    }

    private func awaitReply(on session: Session) async throws -> Reply {
        nextTurnID += 1
        let turnID = nextTurnID
        let sessionID = session.id
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if session.ended {
                    continuation.resume(throwing: QuickModelError.unreachable("claude quick session ended"))
                } else if !session.ready.isEmpty {
                    continuation.resume(returning: session.ready.removeFirst())
                } else {
                    session.waiter = (turnID, continuation)
                    let timeout = turnTimeout
                    session.deadline = Task { [weak self] in
                        try? await Task.sleep(for: timeout)
                        guard !Task.isCancelled else { return }
                        await self?.timeOut(turn: turnID, onSession: sessionID)
                    }
                    if Task.isCancelled { Task { await self.cancel(turn: turnID, onSession: sessionID) } }
                }
            }
        } onCancel: {
            Task { await self.cancel(turn: turnID, onSession: sessionID) }
        }
    }

    /// Interrupts the session and fails `turn`'s waiter, if it is still the one waiting.
    private func cancel(turn turnID: Int, onSession sessionID: Int) async {
        guard let session = live(sessionID), let waiter = session.takeWaiter(turn: turnID) else { return }
        session.stale += 1
        do {
            try await session.harness.interruptTurn()
        } catch {
            // No interrupt reached it, so no stale `result` will either; the session is unusable.
            session.stale -= 1
            retire(session)
        }
        waiter.resume(throwing: CancellationError())
    }

    /// Fails `turn` if it is still waiting after `turnTimeout`, and retires its session.
    private func timeOut(turn turnID: Int, onSession sessionID: Int) {
        guard let session = live(sessionID), let waiter = session.takeWaiter(turn: turnID) else { return }
        retire(session)
        waiter.resume(throwing: QuickModelError.failed("quick turn timed out after \(Self.seconds(turnTimeout)) s"))
    }

    /// `15` for fifteen seconds, `0.05` for fifty milliseconds.
    private static func seconds(_ d: Duration) -> String {
        let value = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        return String(format: "%g", value)
    }

    private func deliver(_ event: HarnessEvent, to sessionID: Int) {
        guard case .result(let isError, let text) = event, let session = live(sessionID) else { return }
        if session.stale > 0 {
            session.stale -= 1
            return
        }
        let reply = Reply(isError: isError, text: text)
        if let waiter = session.takeWaiter() {
            waiter.resume(returning: reply)
        } else {
            session.ready.append(reply)
        }
    }

    private func streamEnded(_ sessionID: Int) {
        guard let session = live(sessionID) else { return }
        session.ended = true
        session.takeWaiter()?.resume(throwing: QuickModelError.unreachable("claude quick session ended"))
        retireNow(session)
    }

    // MARK: - Sessions

    /// The current or spare session with this id; a retired one is gone, and its events with it.
    private func live(_ sessionID: Int) -> Session? {
        [current, spare].lazy.compactMap { $0 }.first { $0.id == sessionID }
    }

    private func ensureStarted() async throws -> Session {
        // Shut down mid-operation (a respond's re-ask): no session is launched again.
        if closed { throw CancellationError() }
        if let current, current.ended { retireNow(current) }
        let session = current ?? launch()
        current = session
        do {
            try await session.startup?.value
        } catch {
            retire(session)
            throw QuickModelError.unreachable("claude quick session did not start: \(error)")
        }
        return session
    }

    /// Makes a harness, starts it in the background, and pumps its events into this actor.
    private func launch() -> Session {
        nextSessionID += 1
        let session = Session(id: nextSessionID, harness: makeHarness())
        let harness = session.harness
        session.startup = Task {
            try await harness.start(sessionId: UUID().uuidString.lowercased(), resumingFrom: nil,
                                    workingDirectory: NSTemporaryDirectory())
        }
        let events = harness.events()
        let id = session.id
        session.pump = Task { [weak self] in
            for await event in events { await self?.deliver(event, to: id) }
            await self?.streamEnded(id)
        }
        return session
    }

    /// Run between operations. One turn before the limit a spare starts warming; at the limit it
    /// takes over, and the old session is torn down in the background.
    private func recycleIfDue() {
        if let session = current, session.turns >= recycleAfter { retire(session) }
        if let session = current, session.turns >= recycleAfter - 1, spare == nil { spare = launch() }
    }

    /// Takes `session` out of service — the spare, if any, steps up — and tears it down in the background.
    private func retire(_ session: Session) {
        retireNow(session)
        end(session)
    }

    private func retireNow(_ session: Session) {
        if current === session {
            current = spare
            spare = nil
        }
        if spare === session { spare = nil }
    }

    /// Fails any turn still waiting on `session`, then stops it; the returned task is the teardown.
    @discardableResult
    private func end(_ session: Session) -> Task<Void, Never> {
        session.ended = true
        session.takeWaiter()?.resume(throwing: QuickModelError.unreachable("claude quick session ended"))
        let startup = session.startup
        let harness = session.harness
        let pump = session.pump
        return Task {
            _ = try? await startup?.value
            await harness.stop()
            pump?.cancel()
        }
    }

    private func armIdle() {
        guard !closed else { return }
        idleGeneration += 1
        let generation = idleGeneration
        let timeout = idleTimeout
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.idleExpired(generation)
        }
    }

    private func idleExpired(_ generation: Int) {
        guard generation == idleGeneration, !busy else { return }
        idleTask = nil
        let sessions = [current, spare].compactMap { $0 }
        current = nil
        spare = nil
        for session in sessions { end(session) }
    }
}
