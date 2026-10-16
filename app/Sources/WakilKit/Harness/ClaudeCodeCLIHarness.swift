import Foundation

// MARK: - HarnessLaunch / buildLaunch

/// The fully-resolved argv/environment for one `claude` CLI invocation:
/// exactly what `Process` needs (`executableURL`, `arguments`, `environment`)
/// to spawn it. Kept as a plain value type, separate from `Process` itself,
/// so `buildLaunch` can be tested without spawning anything.
public struct HarnessLaunch: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]
    /// The directory the child runs in.
    ///
    /// Not optional and not defaulted. Until 2b-v nothing set it, so
    /// `claude` inherited Wakil.app's own directory, recorded it in the
    /// transcript, and was filed under its encoded form — while
    /// `ListSessions` filters by the active project's roots, so **no
    /// session Wakil created could appear in ⌘P at all**
    /// (`session-resume-probe.md` §8, measured on three real transcripts).
    /// A default here would let that reappear silently.
    public let workingDirectory: String
}

/// Builds the argv/environment for one `claude` CLI invocation, per the flags
/// spec §3.2 lists. Pure — no I/O, no process spawn — so every flag and
/// environment key here is exercised directly by `ClaudeCodeCLIHarnessTests`
/// without ever running the real binary.
///
/// The environment dictionary is built from nothing rather than derived from
/// `ProcessInfo.processInfo.environment` by filtering or copying: `HOME` and
/// `PATH` are the only two values read from the current process, one key at
/// a time, and `CLAUDE_CONFIG_DIR`/`CLAUDE_CODE_OAUTH_TOKEN` come from this
/// function's own parameters. That construction is what makes it structural
/// that the result can only ever contain these four keys — there is no
/// dictionary-merge step where a fifth key (in particular `ANTHROPIC_API_KEY`,
/// were it set in whatever process launches Wakil) could slip in.
///
/// The executable is passed through as `claudePath` verbatim — never
/// resolved by searching `PATH` — so `Process.executableURL` always points
/// at one pinned binary.
///
/// This function builds exactly two argv shapes, and never a third. A fresh
/// launch (`resumingFrom: nil`) carries only `--session-id <fresh>`. A
/// resume carries `--resume <parent> --fork-session --session-id <fresh>` —
/// all three together, never `--resume` alone. That is not a style choice:
/// probe §2 measured the CLI refusing `--session-id` alongside `--resume` at
/// startup, before any turn, unless `--fork-session` is also present —
/// `Error: --session-id can only be used with --continue or --resume if
/// --fork-session is also specified.` — so any argv with `--resume` but
/// missing one of the other two is a session that never starts.
///
/// Every resume is a fork, never a continue-in-place, even though the CLI
/// supports the latter (`--resume <old>` alone, per probe §2's table).
/// Continuing in place is only safe under an exclusivity guarantee no layer
/// of this system can make: the CLI enforces none, and a session an
/// operator has open in a terminal is invisible to Wakil. Probe §9 measured
/// what that costs — two processes resuming the same session id at once,
/// neither refused, produced one transcript that stays valid JSON and stops
/// describing a real conversation, an assistant reply landing after a later
/// question that was never asked when it was answered. Forking is safe by
/// construction — a new transcript per fork, never a shared writer — and it
/// keeps Wakil minting every session id it runs, which is what makes the
/// resume list authoritative (charter open question 5).
///
/// `--append-system-prompt agentSystemPrompt` is always passed, unconditionally
/// and with no parameter to disable it: until it existed, `claude` was never
/// told a canvas existed at all, and reasoned about the only surface it had
/// been told about — the conversation — which is what let it decline to
/// redraw a pane the operator had already asked for once. `--append-system-prompt`
/// rather than `--system-prompt`: the latter replaces Claude Code's own
/// prompt outright, discarding its tool-use discipline and refusal behaviour,
/// neither of which `agentSystemPrompt` restates. See that constant's own
/// doc comment for why it is a `let` in `WakilKit` rather than a file read
/// at runtime.
///
/// `allowedTools` is passed as `--allowedTools`, and is not optional in
/// practice: probe §6 measured the CLI's permission layer covering MCP tool
/// calls and denying them outright in a session with no approval surface,
/// which `-p` is, so a launch carrying no allow list is a session in which
/// the agent is refused every Wakil tool. The list is built by
/// `agentAllowedTools` (`App/AgentMCPConfig.swift`), which derives it from the
/// registry and carries the reasoning for what is on it — including why every
/// entry on it is a `.read` or `.control` action and never a `.mutate` one.
///
/// **`--permission-prompt-tool` is built here, and is the other half of that
/// list.** The allow list says what runs without being asked about;
/// the prompt tool is who gets asked about everything else the CLI's own
/// policy does not already settle — probe §7 measured `Read`, `Glob` and a
/// read-only `Bash` being auto-allowed without reaching it at all, so
/// "everything else" is not everything not on the allow list. See
/// `agentAllowedTools`'s doc comment for the three populations this
/// distinguishes. Until 2026-09-10
/// only the first half existed, so "everything else" — every `.mutate`
/// action, `db_run_mutation` included — was denied by the CLI before the
/// request reached Wakil's socket. `--permission-mode` is still not passed;
/// the reasoning for that is unchanged and lives with `agentAllowedTools`.
/// This function neither invents nor filters the list; it only spells it
/// onto the command line, and it is that spelling — not the CLI's treatment
/// of it — that `ClaudeCodeCLIHarnessTests` asserts. Nothing in this repo's
/// tests runs `claude`, so the live behaviour is confirmed by standing check
/// 2 of `docs/wakil/phase-2a-acceptance.md` and nowhere else.
public func buildLaunch(
    claudePath: String,
    sessionId: String,
    configDir: String,
    oauthToken: String,
    mcpConfigJSON: String,
    allowedTools: [String],
    workingDirectory: String,
    resumingFrom parentSessionId: String? = nil
) -> HarnessLaunch {
    let currentEnvironment = ProcessInfo.processInfo.environment
    let environment: [String: String] = [
        "CLAUDE_CONFIG_DIR": configDir,
        "CLAUDE_CODE_OAUTH_TOKEN": oauthToken,
        "HOME": currentEnvironment["HOME"] ?? NSHomeDirectory(),
        "PATH": currentEnvironment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin",
    ]

    var arguments: [String] = [
        "-p",
        "--input-format", "stream-json",
        "--output-format", "stream-json",
        // Not optional, and not verbosity for its own sake: Task 1's live
        // probe found `claude` 2.1.263 refusing the invocation outright
        // without it — `Error: When using --print, --output-format=stream-json
        // requires --verbose` (docs/wakil/phase-2a-probe.md §1).
        "--verbose",
        "--include-partial-messages",
    ]

    // Exactly two shapes, and never a third: the CLI refuses `--session-id`
    // alongside `--resume` unless `--fork-session` is also passed, at
    // startup, before any turn (`session-resume-probe.md` §2).
    //
    // Every resume is a fork. Continuing a session in place would need an
    // exclusivity guarantee no layer of this system can make — the CLI
    // enforces none, and a session the operator has open in a terminal is
    // invisible to Wakil — and probe §9 measured what its absence costs: two
    // concurrent resumes interleave into one transcript that stays valid
    // JSON and stops describing a real conversation. Forking is safe by
    // construction, and it keeps Wakil minting every session id it runs,
    // which is what makes the resume list authoritative (charter open
    // question 5).
    if let parentSessionId {
        arguments += ["--resume", parentSessionId, "--fork-session"]
    }
    arguments += ["--session-id", sessionId]

    arguments += [
        "--mcp-config", mcpConfigJSON,
        "--strict-mcp-config",
        // D3. Before this, Wakil passed no system prompt at all, and the
        // agent's entire knowledge of the app was the tool descriptions.
        // Asked a fourth time for a pane it had already described in chat,
        // it declined to draw one — reasoning about the conversation,
        // because that was the only surface it had been told about.
        "--append-system-prompt", agentSystemPrompt,
        // The approval surface. Probe §6 of `phase-2a-probe.md` measured the
        // CLI denying an unlisted MCP tool outright in a `-p` session — "it
        // requires approval, and this session has no approval surface" — which
        // is why `db_run_mutation`, correctly kept off `--allowedTools` by
        // `agentAllowedTools`, could never reach Wakil at all. Naming a prompt
        // tool is what turns that automatic denial into a question Wakil
        // answers. See `permissionDecision` for what it answers and why every
        // kind is allowed there.
        //
        // Built from the two constants rather than written as a literal:
        // `permission-prompt-probe.md` §8 measured the CLI refusing at its
        // first permission check when this name is not in the server's
        // `tools/list`, and putting that error in front of the agent.
        //
        // Placed here rather than appended, so `--allowedTools` stays the last
        // flag built — it is variadic, and its value should not depend on
        // being last, but nothing is gained by testing that.
        "--permission-prompt-tool", "mcp__\(wakilShimServerName)__\(permissionPromptToolName)",
    ]

    // Comma-separated in a single argument rather than the space-separated
    // form `--help` also accepts: `--allowedTools` is variadic, so a
    // space-separated list would run on into whatever argument came next.
    // Nothing here is passed after it today, but the flag's value should not
    // depend on being last. An empty list passes no flag at all — an empty
    // `--allowedTools ""` would be a rule the CLI has to interpret, and this
    // function should not invent one.
    if !allowedTools.isEmpty {
        arguments.append(contentsOf: ["--allowedTools", allowedTools.joined(separator: ",")])
    }

    return HarnessLaunch(
        executable: claudePath,
        arguments: arguments,
        environment: environment,
        workingDirectory: workingDirectory
    )
}

// MARK: - ClaudeCodeCLIHarness

/// Errors `ClaudeCodeCLIHarness` throws itself, as opposed to whatever the
/// child process does on its own.
public enum ClaudeCodeCLIHarnessError: Error, Sendable, Equatable {
    /// `send` or `interrupt` was called before `start`, or after `stop`.
    case notRunning
    /// `start` was called on a harness that already has a running child.
    case alreadyStarted
    /// `start` was called on a harness `stop()` has already run on. A
    /// stopped harness is spent — see `Engine.everStopped`'s doc comment —
    /// so this is distinct from `alreadyStarted`: it tells the caller their
    /// `start()` call did nothing, rather than returning as if it worked.
    case alreadyStopped
}

/// Reaches the operator through `WindowModel`'s `status = "agent: \(error)"`
/// and `"resume <id>: \(error)"`. All three are states of this window's own
/// agent rather than anything the child process said, so each names what
/// the window did instead of what failed inside `claude`.
extension ClaudeCodeCLIHarnessError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .notRunning: return "no agent is running in this window"
        case .alreadyStarted: return "an agent is already running in this window"
        case .alreadyStopped:
            return "this agent was stopped and cannot be restarted \u{2014} start a new session"
        }
    }
}

/// Drives one `claude` CLI subprocess per session over the bidirectional
/// `--input-format stream-json --output-format stream-json` protocol spec
/// §3.2 describes — the only `AgentHarness` implementation this phase has.
///
/// All of the mutable process/pipe state lives on a private actor
/// (`Engine`), following the division `MCPClient` (Task 5) establishes for
/// the same reason: every method that touches `Process`, its pipes, or the
/// line buffer runs with exclusive access, one at a time, with no locks.
/// `events()` itself needs no actor hop — the `AsyncStream` and its
/// continuation are created once in `init`, before any child exists, as
/// plain `Sendable` values the outer class holds directly, so a caller may
/// call `events()` at any time, including before `start()`.
///
/// The event stream's buffering policy is deliberately the default
/// `.unbounded`, not a bounded one: this stream feeds the thought thread,
/// whose entire purpose is showing every step the agent took, and every
/// bounded `AsyncStream` buffering policy drops elements once the buffer is
/// full. A dropped `HarnessEvent` would be silent, undetectable data loss in
/// the one feature this buffer exists to serve, so the trade this makes
/// instead is an unbounded buffer whose true bound is one session's worth of
/// events, on the expectation (not enforced by this type) that whatever
/// consumes `events()` drains it continuously rather than batching.
public final class ClaudeCodeCLIHarness: AgentHarness, Sendable {
    private let claudePath: String
    private let configDir: String
    private let oauthToken: String
    private let mcpConfigJSON: String
    private let allowedTools: [String]
    private let stream: AsyncStream<HarnessEvent>
    private let engine: Engine
    /// Guards `events()` against being called more than once — see that
    /// method's doc comment for why a second call must be refused rather
    /// than served.
    private let eventsGate = SingleConsumerGate()

    public init(
        claudePath: String,
        configDir: String,
        oauthToken: String,
        mcpConfigJSON: String,
        allowedTools: [String]
    ) {
        self.claudePath = claudePath
        self.configDir = configDir
        self.oauthToken = oauthToken
        self.mcpConfigJSON = mcpConfigJSON
        self.allowedTools = allowedTools

        var capturedContinuation: AsyncStream<HarnessEvent>.Continuation!
        self.stream = AsyncStream { continuation in
            capturedContinuation = continuation
        }
        self.engine = Engine(continuation: capturedContinuation)
    }

    /// Spawns the child under `sessionId`, which the caller generated, as
    /// either a fresh launch (`resumingFrom: nil`) or a fork of
    /// `resumingFrom`'s conversation — see `buildLaunch`'s doc comment for
    /// the two argv shapes this produces. `workingDirectory` is passed
    /// straight through to `buildLaunch` and, via `Engine.start`, to the
    /// child's `currentDirectoryURL`.
    ///
    /// A resumed session is always started on a **new instance** of this
    /// class, never this one after some in-place state change: `stop()`
    /// makes an instance spent (see `everStopped` below), so the only way
    /// to continue a conversation is a fresh `ClaudeCodeCLIHarness` whose
    /// `start` is called with `resumingFrom` set.
    ///
    /// Racing this against a concurrent `stop()` on the same instance can
    /// never leave an unsupervised child running, regardless of which of
    /// the two the actor happens to run first: see `Engine.everStopped`'s
    /// doc comment for the mechanism, and
    /// `ClaudeCodeCLIHarnessTests.racingStartAndStopNeverLeavesAnOrphan`
    /// for the test that exercises both orderings and checks actual OS
    /// process state, not just that the calls returned.
    ///
    /// Throws `ClaudeCodeCLIHarnessError.alreadyStopped` — never a silent
    /// no-op — if `stop()` has already run on this instance, whether that
    /// was a normal end-of-session teardown or the losing side of the race
    /// above: a stopped harness is spent, and the caller must be able to
    /// tell that this call spawned nothing rather than believe it started a
    /// session that does not exist. See
    /// `ClaudeCodeCLIHarnessTests.startAfterStopThrowsAlreadyStopped`.
    public func start(sessionId: String, resumingFrom parentSessionId: String?, workingDirectory: String) async throws {
        let launch = buildLaunch(
            claudePath: claudePath,
            sessionId: sessionId,
            configDir: configDir,
            oauthToken: oauthToken,
            mcpConfigJSON: mcpConfigJSON,
            allowedTools: allowedTools,
            workingDirectory: workingDirectory,
            resumingFrom: parentSessionId
        )
        try await engine.start(launch: launch)
    }

    public func send(_ text: String) async throws {
        try await engine.send(text)
    }

    /// Returns the stream of `HarnessEvent`s this session produces.
    ///
    /// **Exactly one caller may ever receive it.** Measured directly on this
    /// machine: handing the same `AsyncStream` to two concurrent `for await`
    /// consumers does not duplicate events between them, it *splits* them —
    /// of 6 values yielded into one stream, one consumer received 3 and the
    /// other received the other 3, each permanently missing what the other
    /// got. For a stream whose sole intended consumer is the thought thread,
    /// a second, accidental consumer would silently steal events the first
    /// will never see — worse than merely "unsupported", since nothing about
    /// it looks like a failure at the call site. So this is enforced, not
    /// left as a caller responsibility: `eventsGate` allows exactly one
    /// `tryConsume()` to succeed, and a second call to this method is a
    /// programmer error that crashes immediately via `preconditionFailure`
    /// rather than silently handing back a stream that would cannibalise the
    /// first consumer.
    public func events() -> AsyncStream<HarnessEvent> {
        guard eventsGate.tryConsume() else {
            preconditionFailure(
                "ClaudeCodeCLIHarness.events() was already called once on this instance; "
                    + "only a single consumer of the event stream is supported, because a second "
                    + "concurrent consumer would split events with the first rather than both seeing them."
            )
        }
        return stream
    }

    public func interrupt() async {
        await engine.interrupt()
    }

    public func stop() async {
        await engine.stop()
    }
}

/// Enforces "at most one caller ever gets past this point" for
/// `ClaudeCodeCLIHarness.events()`. Backed by `NSLock` rather than the
/// `Engine` actor because `events()` is a synchronous, non-`async` protocol
/// method with no actor to hop to.
private final class SingleConsumerGate: @unchecked Sendable {
    private let lock = NSLock()
    private var consumed = false

    /// Returns `true` the first time this is called on a given instance, and
    /// `false` — without mutating anything further — on every call after
    /// that. Two callers racing this concurrently cannot both see `true`:
    /// `consumed` is only ever read and written while `lock` is held, so one
    /// of them observes the other's write.
    func tryConsume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !consumed else { return false }
        consumed = true
        return true
    }
}

/// The mutable half of `ClaudeCodeCLIHarness`: the child process, its pipes,
/// and the raw-line buffering that feeds `events()`. Kept on an actor,
/// rather than the outer class, purely so every method below has exclusive
/// access to `process`/`stdinHandle`/`lineBuffer` — the same reason
/// `MCPClient` (Task 5) is an actor.
private actor Engine {
    private let continuation: AsyncStream<HarnessEvent>.Continuation

    private var process: Process?
    private var stdinHandle: FileHandle?
    /// Single-flight teardown task; see `MCPClient.stop()`'s doc comment for
    /// why concurrent `stop()` calls must all await one shared teardown
    /// rather than each racing to tear down the same `Process`.
    private var teardownTask: Task<Void, Never>?
    private var lineBuffer = Data()
    /// Set by `consumeStdout` once its `for await` loop has ended — that is,
    /// once the drain thread has finished the chunk stream at EOF *and* every
    /// chunk it ever yielded has been through `handleStdoutData`. `stop()`
    /// waits on this before finishing the event stream; see
    /// `waitForStdoutDrain` for why, and for the deadline that bounds it.
    private var stdoutFinished = false
    /// Continuations parked in `waitForStdoutDrain`, keyed by a per-waiter id
    /// so that waiter's own deadline can resume exactly that one. Every entry
    /// is removed from this dictionary in the same synchronous, actor-isolated
    /// step that resumes it — by `handleStdoutEOF` for all of them at once, or
    /// by `resumeDrainWaiter` for one — so no continuation here can ever be
    /// resumed twice.
    private var drainWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var nextDrainWaiterID = 0
    /// Set by `stop()` before it does anything else, and never cleared:
    /// once a `stop()` call has run on this actor, no future `start()` call
    /// may ever spawn a process.
    ///
    /// This closes a race a concurrent `start()`/`stop()` pair otherwise has.
    /// `start()`'s body below has no `await` in it — `Process.run()` is a
    /// plain synchronous, non-suspending call — so once its actor job begins
    /// running it runs to completion with no possibility of a `stop()` job
    /// interleaving partway through. The same is true of `stop()`'s
    /// "nothing running yet" path (the `guard let process else` branch
    /// below): it also has no `await` before it returns. That means the
    /// actor has only two possible total orderings for a concurrent
    /// `start()`/`stop()` pair that both find no process yet — `start`'s job
    /// runs first, or `stop`'s job runs first — never a partial interleaving
    /// of one inside the other. `everStopped` makes both orderings safe:
    /// if `stop`'s job runs first, it sets this flag (there being no process
    /// yet to tear down) and returns; when `start`'s job then runs, it sees
    /// the flag and throws `.alreadyStopped` instead of spawning anything.
    /// If `start`'s job runs first, it spawns normally and `stop`'s job —
    /// running after, since actor jobs never interleave here — sees a real
    /// `process` and tears it down through the usual path below. Either
    /// ordering ends with no process left running unsupervised. See
    /// `ClaudeCodeCLIHarnessTests.racingStartAndStopNeverLeavesAnOrphan` for
    /// the regression test, which races both calls against a real child (a
    /// long-running shell script under `/tmp`) many times and checks actual
    /// OS process state rather than trusting that the calls returned.
    ///
    /// The trade this makes: a `start()` call on an instance that has ever
    /// had `stop()` called on it — even if nothing was running at the time —
    /// can never spawn again, and reports that with `.alreadyStopped` rather
    /// than returning as if it had worked (an earlier version returned
    /// silently here; see `ClaudeCodeCLIHarnessTests.startAfterStopThrowsAlreadyStopped`
    /// for the regression test). `ClaudeCodeCLIHarness` is built one per
    /// session (see its own doc comment), so this instance is not expected
    /// to be reused for a second session after `stop()`; a new session gets
    /// a new harness.
    private var everStopped = false

    init(continuation: AsyncStream<HarnessEvent>.Continuation) {
        self.continuation = continuation
    }

    func start(launch: HarnessLaunch) throws {
        guard process == nil else { throw ClaudeCodeCLIHarnessError.alreadyStarted }
        guard !everStopped else {
            // A `stop()` call already ran on this actor — see `everStopped`'s
            // doc comment for why that permanently forecloses spawning.
            // Throwing here (rather than a silent no-op) is load-bearing:
            // an earlier version just returned, so a caller's `start()`
            // returned success with no child ever having been spawned and
            // nothing to tell it apart from a real start. `.alreadyStopped`
            // gives the caller a distinct, checkable signal that this call
            // did nothing, instead of a mental model that has silently
            // diverged from reality.
            throw ClaudeCodeCLIHarnessError.alreadyStopped
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch.executable)
        // Where the transcript gets filed, and therefore whether ⌘P can
        // ever see this session: `claude` records its cwd in the
        // transcript and files it under that path's encoded form, while
        // `ListSessions` filters by the active project's roots. Inheriting
        // Wakil.app's directory — which is what happened until 2b-v —
        // hides every session Wakil creates from its own resume list.
        process.currentDirectoryURL = URL(fileURLWithPath: launch.workingDirectory)
        process.arguments = launch.arguments
        process.environment = launch.environment

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // No `terminationHandler` is assigned here. It is assigned exactly
        // once, later, inside `waitForProcessExit` — which only runs from
        // `stop()`. `MCPClient.waitForProcessExit`'s doc comment records why:
        // a second assignment silently replaces the first with no error, so
        // this process must have at most one call site that ever sets it.
        try process.run()

        self.process = process
        self.stdinHandle = stdinPipe.fileHandleForWriting

        startStdoutDrainThread(stdoutPipe.fileHandleForReading)
        startStderrDiscardThread(stderrPipe.fileHandleForReading)
    }

    /// Encodes `text` as one stream-json user-turn frame and writes it,
    /// newline-terminated, to the child's stdin. The frame this builds is
    /// `{"type":"user","message":{"role":"user","content":[{"type":"text","text":...}]}}` —
    /// this is what this method writes, not a claim about what the running
    /// `claude` process does with it, which this task does not run and so
    /// cannot observe.
    func send(_ text: String) throws {
        guard let stdinHandle, let process, process.isRunning else {
            throw ClaudeCodeCLIHarnessError.notRunning
        }
        let frame = JSONValue.object([
            "type": .string("user"),
            "message": .object([
                "role": .string("user"),
                "content": .array([
                    .object(["type": .string("text"), "text": .string(text)])
                ]),
            ]),
        ])
        var data = try JSONEncoder().encode(frame)
        data.append(UInt8(ascii: "\n"))
        try stdinHandle.write(contentsOf: data)
    }

    /// Calls `Process.interrupt()`. Verified directly on this machine (a
    /// `/bin/sh` child trapping `SIGINT`) that this delivers `SIGINT` to the
    /// child without blocking the caller. What the running `claude` process
    /// itself does on receiving it is not something this task runs or
    /// observes. A no-op if there is no running child.
    func interrupt() {
        process?.interrupt()
    }

    /// Terminates the child and waits for its exit without blocking the
    /// calling thread, then finishes the event stream. Safe to call
    /// concurrently, more than once, or before `start()`. See
    /// `MCPClient.stop()`'s doc comment for why teardown must be
    /// single-flight rather than letting each caller race its own, and
    /// `everStopped`'s doc comment for why this sets that flag as its very
    /// first, synchronous action — before either branch below, so a
    /// concurrent `start()` racing this call can never observe a window in
    /// which this `stop()` has run but the flag is not yet set.
    func stop() async {
        everStopped = true
        if let teardownTask {
            await teardownTask.value
            return
        }
        guard let process else {
            // Nothing to tear down — either `start()` was never called, or
            // it will run later and see `everStopped` (see that flag's doc
            // comment). Finish the stream now regardless, so a consumer
            // sees the session end rather than waiting on a stream that
            // will never produce anything.
            continuation.finish()
            return
        }
        let task = Task {
            await self.performTeardown(process)
        }
        teardownTask = task
        await task.value
    }

    private func performTeardown(_ process: Process) async {
        if process.isRunning {
            process.terminate()
        }
        await waitForProcessExit(process)
        await waitForStdoutDrain()
        try? stdinHandle?.close()
        self.process = nil
        self.stdinHandle = nil
        teardownTask = nil
        // Usually redundant by this point: `waitForStdoutDrain` above returns
        // either because `handleStdoutEOF` ran — and that already finished the
        // continuation — or because the deadline expired. Measured directly on
        // this machine, a second `AsyncStream.Continuation.finish()` call is a
        // silent no-op (no crash, no warning), so calling it unconditionally
        // here is harmless in the first case and is what ends the stream in
        // the second, where EOF may never come at all.
        continuation.finish()
    }

    /// How long `performTeardown` will wait for `consumeStdout` to work
    /// through its backlog before finishing the event stream anyway.
    ///
    /// The wait itself is not optional — see `waitForStdoutDrain` — but an
    /// unbounded one would be a `stop()` that can hang forever, so this number
    /// is what decides between losing the tail of a session and hanging the
    /// caller. It is chosen from the measured drain rate rather than picked
    /// as a round number.
    ///
    /// By the time this deadline starts running the child is already dead, so
    /// the work left is finite: whatever the drain thread has read into the
    /// chunk stream but the actor has not yet parsed, plus whatever is still
    /// in the pipe (bounded by its 64 KiB capacity). Measured directly on this
    /// machine, over five sessions each: the 3000-frame child of
    /// `stopDeliversTheTailOfTheStreamRatherThanDiscardingIt` — around 2500
    /// events still undelivered when `stop()` is called — took 90 to 115 ms to
    /// terminate, drain and finish; the same shape with a single frame and so
    /// no backlog at all took under 3 ms. The backlog, in other words, drains
    /// at upwards of 20,000 events per second, JSON decoding dominating. The
    /// ranges are given loosely on purpose: two machines measured the same
    /// shape about 5% apart, so a tighter figure here would only invite a
    /// later re-measurement to contradict a comment that is still correct.
    ///
    /// 2 seconds therefore covers a backlog north of 40,000 queued events,
    /// some sixteen times the largest this suite can construct and far past
    /// any plausible single session's tail — while still bounding the case
    /// this deadline exists for, a stdout write end held open by a grandchild
    /// the harness cannot terminate, at 2 seconds of `stop()`
    /// (see `stopReturnsPromptlyWhenAGrandchildHoldsStdoutOpen`). Note that
    /// only `stop()` is bounded, not the leak: nothing closes the stdout and
    /// stderr read handles, so on that path the two drain threads stay parked
    /// in `availableData` and `consumeStdout`'s strong `self` keeps this
    /// `Engine` and its pipes alive until the grandchild exits. That is
    /// pre-existing and not fixed here — closing an fd another thread is
    /// blocked reading is not a safe remedy — but it is why this bounds the
    /// call rather than the resources. The margin
    /// is deliberately generous in that direction: expiring early is silent
    /// data loss, which is the bug this whole mechanism exists to fix, whereas
    /// expiring late merely delays a teardown in a rare case.
    private static let stdoutDrainDeadlineNanoseconds: UInt64 = 2_000_000_000

    /// Waits, up to `stdoutDrainDeadlineNanoseconds`, for `consumeStdout` to
    /// finish draining the stdout chunk stream.
    ///
    /// This is what keeps `stop()` from destroying the tail of a session.
    /// `continuation.finish()` is irreversible and a finished `AsyncStream`
    /// continuation silently discards every later `yield` (the same property
    /// `handleStdoutEOF`'s doc comment turns on), so finishing the stream the
    /// moment the child exits throws away every chunk `consumeStdout` had not
    /// yet reached. Measured on this machine before this method existed, with
    /// a child that wrote 3000 frames and then parked: 469, 1123, 550, 631 and
    /// 817 of the 3000 events delivered across five sessions, and 0 in all
    /// five when `stop()` came a fixed 150 ms in — the rest destroyed silently.
    /// `MCPClient.performTeardown` has had the same guard from the start
    /// (`waitForDrainToFinish`); this is the harness's equivalent, plus a
    /// deadline that one does not need.
    ///
    /// The deadline is why this cannot simply mirror `MCPClient`. The drain
    /// thread finishes its chunk stream only when `read(2)` returns 0, which
    /// requires *every* holder of the stdout pipe's write end to have closed
    /// it — not merely the child this actor spawned and just terminated. A
    /// grandchild that inherited stdout keeps it open indefinitely, and
    /// waiting unconditionally on that would be exactly the hanging `stop()`
    /// this file has taken pains to avoid elsewhere.
    private func waitForStdoutDrain() async {
        if stdoutFinished { return }
        let id = nextDrainWaiterID
        nextDrainWaiterID += 1
        // Created before the continuation is registered but unable to run
        // before it: a `Task` formed in actor-isolated code inherits that
        // isolation, so its body cannot execute until this method suspends,
        // which happens only after the closure below has stored the waiter.
        let deadline = Task {
            try? await Task.sleep(nanoseconds: Self.stdoutDrainDeadlineNanoseconds)
            self.resumeDrainWaiter(id)
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            drainWaiters[id] = continuation
        }
        // Purely so the deadline task stops idling out the rest of its sleep
        // once EOF has already released this waiter; `resumeDrainWaiter`'s own
        // removal-before-resume is what makes a late firing a no-op.
        deadline.cancel()
    }

    /// Resumes one parked drain waiter if it is still parked. A no-op if
    /// `handleStdoutEOF` already resumed it, which is what keeps a deadline
    /// that fires just after EOF from resuming a continuation twice.
    private func resumeDrainWaiter(_ id: Int) {
        drainWaiters.removeValue(forKey: id)?.resume()
    }

    /// Awaits process exit without blocking the calling thread, using
    /// `Process.terminationHandler` rather than the blocking
    /// `waitUntilExit()`. This is the exact pattern `MCPClient.waitForProcessExit`
    /// uses and its doc comment explains and measures: a blocking wait here
    /// would tie up a thread from Swift's cooperative executor pool for as
    /// long as the child takes to exit, and installing `terminationHandler`
    /// after the child has already exited still fires it (no lost wakeup).
    /// This method is only ever called from `performTeardown`, itself only
    /// reachable through `stop()`'s single-flight `teardownTask`, so this is
    /// the one and only place this actor ever assigns `terminationHandler`.
    private func waitForProcessExit(_ process: Process) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in
                continuation.resume()
            }
        }
    }

    // MARK: - Reading the child's stdout

    /// Feeds one chunk of stdout bytes into `lineBuffer`, splits out every
    /// complete newline-terminated line, and yields every `HarnessEvent`
    /// that line decodes to, in order. One line is not one event: a single
    /// `assistant` frame carrying text and two tool calls is three events,
    /// so this yields each rather than at most one per line.
    ///
    /// Unlike `FrameReader` (Task 3), a decode failure here is never latched
    /// and never thrown: a line `decodeHarnessEvents` rejects as malformed
    /// is dropped silently and reading continues, since `AgentHarness` has
    /// no way to surface a per-line decode error to its caller and stream-json
    /// is, per spec §3.4, an unverified and weaker contract than `FrameReader`'s
    /// JSON-RPC frames. Only a structurally broken line is dropped that way;
    /// a frame whose `"type"` the decoder does not map still arrives, as
    /// `.unknown(type:)`.
    private func handleStdoutData(_ data: Data) {
        lineBuffer.append(data)
        while let newlineIndex = lineBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = lineBuffer[lineBuffer.startIndex..<newlineIndex]
            lineBuffer.removeSubrange(lineBuffer.startIndex...newlineIndex)
            guard !line.isEmpty else { continue }
            for event in Self.decode(Data(line)) {
                continuation.yield(event)
            }
        }
    }

    /// The stdout-draining thread reached end-of-file: the child closed or
    /// exited. Finishes the event stream so a `for await` consumer of
    /// `events()` ends its loop instead of waiting forever.
    ///
    /// Called only from `consumeStdout` below, after its `for await` loop has
    /// run to completion — which, because the drain thread finishes the chunk
    /// stream only after its last `yield`, means after every chunk read before
    /// the EOF has already been through `handleStdoutData`. That ordering is
    /// load-bearing: `finish()` is irreversible, and an `AsyncStream`
    /// continuation that has finished silently discards every subsequent
    /// `yield`, so an EOF that overtook a still-unprocessed chunk would drop
    /// the last events of a session — the `result` frame most of all — with
    /// no error anywhere. See
    /// `ClaudeCodeCLIHarnessTests.theLastEventBeforeEOFIsNeverDroppedByTheStreamFinishing`.
    ///
    /// Reaching this point is also the signal a concurrent `stop()` is waiting
    /// on: everything the child ever wrote has now been yielded, so a teardown
    /// parked in `waitForStdoutDrain` may stop waiting and finish up.
    private func handleStdoutEOF() {
        continuation.finish()
        stdoutFinished = true
        let waiters = drainWaiters
        drainWaiters.removeAll()
        for waiter in waiters.values {
            waiter.resume()
        }
    }

    /// Decodes one stream-json line into the events it carries, via
    /// `decodeHarnessEvents` — the decoder built against the fixtures the
    /// live probe recorded (`docs/wakil/phase-2a-probe.md`).
    ///
    /// It is handed exactly one line at a time, never a whole buffer,
    /// because that is what makes its `throws` survivable here: a malformed
    /// line throws away only itself, and this returns an empty array,
    /// dropping the line while every other line in the same read chunk still
    /// reaches `events()`. Passing several lines at once would let one bad
    /// line discard the good ones decoded before it.
    private static func decode(_ line: Data) -> [HarnessEvent] {
        (try? decodeHarnessEvents(line)) ?? []
    }

    /// Spawns a plain background `Thread` that blocks on
    /// `FileHandle.availableData` in a loop, handing each chunk to this actor
    /// through the serial `AsyncStream` `consumeStdout` drains. As in
    /// `MCPClient.startStdoutDrainThread`, a dedicated `Thread` (not
    /// `Task.detached`) is used specifically because the read blocks: parking
    /// that on a cooperative-pool thread would risk starving it, whereas a
    /// plain `Thread` only ever ties up itself.
    ///
    /// The chunks travel over an `AsyncStream` rather than one unstructured
    /// `Task { await self.handleStdoutData(data) }` per chunk, and that is
    /// the whole point of this shape: unstructured `Task`s carry no ordering
    /// guarantee relative to one another, so two chunks read microseconds
    /// apart could reach the actor in either order. Measured directly on this
    /// machine with the per-chunk-`Task` version and a child printing 400
    /// numbered frames with no sleeps, across eight runs of ten sessions: 4,
    /// 5, 6, 6, 6, 7, 8 and 10 of every 10 sessions delivered at least one
    /// adjacent pair of events inverted (`48` before `47`, and so on).
    ///
    /// `yield` here is synchronous, non-blocking and safe off the cooperative
    /// pool — so the blocking read stays on this plain `Thread` — and an
    /// `AsyncStream` hands its single consumer the elements in exactly the
    /// order they were yielded, so read order *is* delivery order by
    /// construction rather than by luck.
    ///
    /// Buffering is `.unbounded` deliberately, matching `events()`'s own
    /// stream: every bounded policy drops elements when full, and a dropped
    /// chunk here is not a lost event but a *hole in the byte stream*, which
    /// would silently corrupt whatever line `handleStdoutData` was
    /// reassembling around it.
    ///
    /// EOF is not dispatched separately either — the thread finishes the
    /// chunk stream, which `consumeStdout` observes only after draining
    /// everything already yielded. See `handleStdoutEOF` for why that has to
    /// be strictly last.
    private func startStdoutDrainThread(_ handle: FileHandle) {
        let (chunks, chunkSink) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .unbounded)
        // Strong `self`, unlike the `[weak self]` the per-chunk-`Task`
        // version used: this task is the only consumer of the chunk stream,
        // and it ends on its own the moment the drain thread finishes that
        // stream at EOF, so it keeps this actor alive for exactly as long as
        // there are chunks left to deliver and no longer.
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
        thread.name = "ClaudeCodeCLIHarness.stdout"
        thread.start()
    }

    /// Drains the stdout chunk stream one chunk at a time, in yield order,
    /// then reports EOF. Being the stream's single consumer is what makes
    /// this ordered: it processes each chunk to completion before taking the
    /// next, and reaches the line after the loop only once the stream has
    /// been finished *and* emptied.
    private func consumeStdout(_ chunks: AsyncStream<Data>) async {
        for await chunk in chunks {
            handleStdoutData(chunk)
        }
        handleStdoutEOF()
    }

    /// Drains stderr on its own thread purely so the child can never block on
    /// a full stderr pipe; bytes are discarded rather than parsed, since
    /// `stream-json` events only ever arrive on stdout.
    private func startStderrDiscardThread(_ handle: FileHandle) {
        let thread = Thread {
            while true {
                let data = handle.availableData
                if data.isEmpty { return }
            }
        }
        thread.name = "ClaudeCodeCLIHarness.stderr"
        thread.start()
    }
}
