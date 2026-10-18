import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Why a shell could not be opened.
public enum TerminalOpenError: Error, Sendable, Equatable, CustomStringConvertible {
    case unsupportedShell(String)
    case spawnFailed(String)

    public var description: String {
        switch self {
        case .unsupportedShell(let shell):
            return "term_open: \(shell) is not a shell Wakil can run. This pane needs shell "
                + "integration to know where one command ends and the next begins — without "
                + "it the shell owns the input line and nothing journals a run at all — and "
                + "Wakil generates that integration for zsh and bash. Not a degraded mode: a "
                + "degraded mode is one in which commands run outside the action registry."
        case .spawnFailed(let detail):
            return "term_open: could not start a shell (\(detail))"
        }
    }
}

/// What `open` reports back about the shell it started.
public struct TerminalOpened: Sendable, Equatable {
    public let shell: String
    public let cols: Int
    public let rows: Int
    public let cwd: String
}

/// One finished command, as the window needs it to journal `term_run`.
///
/// **A separate type from `TerminalBlock`, carrying the pane and the
/// cwd.** A block is what the pane draws and what `read_pane` answers; a
/// run is what the journal records, and it needs two facts the block does
/// not hold — which pane it happened in, and where — while needing none of
/// its output.
public struct TerminalRun: Sendable, Equatable {
    public let paneId: String
    public let command: String
    public let cwd: String
    public let exitCode: Int?
    public let durationMs: Int?
    /// Whether this command reached the prompt through `term_propose` and
    /// the operator's `⏎`, rather than being typed. Materially different
    /// events, and after the fact the journal is the only place the
    /// difference survives.
    public let wasProposed: Bool
    /// The scope the shell was opened in (its home, background agents 3 of 4): where the run
    /// happened, wherever the screen is by the time it finishes. Nil for a shell opened with no
    /// scope — the window journals that under the place on screen.
    public let scope: LayoutScope?

    public init(
        paneId: String, command: String, cwd: String, exitCode: Int?, durationMs: Int?,
        wasProposed: Bool, scope: LayoutScope? = nil
    ) {
        self.scope = scope
        self.paneId = paneId
        self.command = command
        self.cwd = cwd
        self.exitCode = exitCode
        self.durationMs = durationMs
        self.wasProposed = wasProposed
    }
}

/// Every live PTY, keyed by pane id — and **only** the live resource.
///
/// **Why this is not `PaneStore`.** Their lifetimes are genuinely
/// identical: born at pane open, warm across every switch, dead at
/// `pane_close`. It loses on one fact that is not
/// about terminals at all — **there is no `deinit` in `WakilKit` that
/// releases an OS resource, not one.** Every process and every descriptor
/// in this application is released by an explicit awaited stop. Putting a
/// PTY inside `PaneStore.Contents` would make `byProject = [:]` and
/// `drop(paneId:)` its release path: the first resource here whose release
/// depends on ARC, and the one where that is least survivable, because
/// `close(2)` on a pty master blocks forever while a thread is parked in
/// `read(2)`. **A cleared dictionary does not kill a shell, and here it
/// cannot be made to.**
///
/// **Modelled directly on `MCPClient`.** Teardown is single-flight per
/// pane, guarded by a task, so two concurrent closers cannot both pass a
/// `!= nil` check and have the second overwrite the first's completion —
/// the measured failure `MCPClient.stop()`'s doc comment records, which
/// hung the first caller permanently. `open` is single-flight per pane for
/// the mirror-image reason, spelled out on `open` itself.
/// A shell's identity: the scope it was opened in and its pane id. Pane ids are unique within
/// one scope but not across scopes loaded from disk (`LayoutStore.load` raises its counter only
/// from the snapshot it loads), so two places can each hold `terminal-1` (background agents 3
/// of 4). `scope` is nil for a store with no pane store, which has no scopes.
struct TerminalKey: Hashable, Sendable {
    let scope: LayoutScope?
    let paneId: String
}

public actor TerminalStore {
    /// The shells Wakil generates integration for. Named, the way
    /// Invariant 6 refuses DDL by naming each verb rather than by
    /// omission.
    public static let supportedShells: Set<String> = ["zsh", "bash"]

    /// The shell a `term_open` that names none gets: the operator's own,
    /// falling back to the platform default. `$SHELL` is read from Wakil's
    /// process environment, which is the operator's login environment.
    public static func defaultShell(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        environment["SHELL"] ?? "/bin/zsh"
    }

    /// Keyed by the shell's scope and pane id (`TerminalKey`), never the pane id alone.
    private var sessions: [TerminalKey: TerminalSession] = [:]
    /// One per shell, cleared as teardown's last step so a later `open` on
    /// the same pane starts a fresh cycle rather than replaying this one.
    private var teardownTasks: [TerminalKey: Task<Void, Never>] = [:]
    /// One per shell, for the same reason and with the same shape. See
    /// `open`.
    private var openTasks: [TerminalKey: Task<TerminalOpened, Error>] = [:]
    /// Each open shell's rc directory, named once at open (see `instanceId`).
    private var rcDirectories: [TerminalKey: URL] = [:]
    /// Folded into each rc directory's name, so two scopes' shells under one pane id never
    /// share one.
    private var rcSerial = 0
    private var shutdownTask: Task<Void, Never>?

    /// PTY masters and pids teardown had to give up on — what was leaked,
    /// so it is recorded rather than merely gone.
    ///
    /// **Why leaking one descriptor beats hanging every other pane.**
    /// Teardown's two waits used to be unbounded. If either never returned
    /// — a drain thread parked in a `read(2)` the kill did not end, or a
    /// child stuck mid-exit — `continuation.resume()` never ran, so
    /// `teardownTasks[paneId]` stayed set forever. From then on every
    /// `close` on that pane took the `await existing.value` branch and
    /// hung, every `open` on it hung behind its own `close`, and because
    /// `shutdownAll` walks the panes **serially**, no OTHER pane's shell
    /// was ever reaped either: app quit hangs permanently.
    /// That is the exact `MCPClient` failure class this file is modelled
    /// against, reached from a different direction.
    ///
    /// So both waits are bounded at
    /// `TerminalSession.teardownDeadlineSeconds` and teardown abandons on
    /// expiry. It deliberately does **not** close the master when the
    /// drain thread is still parked: `close(2)` with a read in flight is
    /// the forever-block the whole kill → EOF → close ordering exists to
    /// avoid. What is leaked is one descriptor, one thread, and at most
    /// one unreaped pid, belonging to a pane that is already gone. What is
    /// bought is that every other pane still closes.
    private(set) var abandonedResources: [AbandonedPty] = []

    /// Writes that could not be delivered before their deadline — the
    /// write side's equivalent of `abandonedResources`, and recorded for
    /// the same reason. Drained from each session by `write` and by every
    /// publish, so a give-up on the drain thread's own
    /// `flushEngineResponses` is recorded too.
    private(set) var abandonedWrites: [AbandonedWrite] = []
    /// The cursor each pane last published, so a move that redraws nothing
    /// still publishes (see `publish`).
    private var publishedCursors: [TerminalKey: (row: Int, col: Int)] = [:]
    /// Whether each pane last published a command running, for the same reason: a `C` or `D`
    /// mark is an OSC, which redraws nothing and moves no cursor (see `publish`).
    private var publishedCommandRunning: [TerminalKey: Bool] = [:]

    /// Distinguishes this store's rc directories from every other store's.
    ///
    /// **Not optional in a process that can run more than one store.** The
    /// directory a pane's rc lives in is a path built from nothing but
    /// `paneId`, and `paneId` is caller-chosen text with no uniqueness
    /// guarantee across stores — the test suite reuses `"terminal-1"` in
    /// well over a dozen places, each its OWN `TerminalStore`, and Swift
    /// Testing runs them concurrently. Two stores computing the identical
    /// path raced `mkdir`, the atomic rc write's own `mktemp`, and
    /// teardown's `removeItem` against each other — measured as both a
    /// `mktemp`/errno 22 failure and a "file doesn't exist" one, on
    /// runs of this same suite. This instance id is folded into the path
    /// so the SAME store computes the SAME directory across reopens on one
    /// pane — which `WAKIL_USER_ZDOTDIR` restoration has no need to
    /// depend on, but nothing requires it not to — while two different
    /// stores never collide.
    private let instanceId = UUID().uuidString

    /// Where the blocks and the live screen are published. Optional so a
    /// test that only cares about a shell opening and dying — and there
    /// are a dozen of them — does not have to build a `PaneStore` and does
    /// not pay for a 60 Hz loop it never reads.
    private let panes: PaneStore?
    /// The one publisher, or `nil` while no pane holds a shell. See
    /// `startPublishing()`.
    private var publisher: Task<Void, Never>?
    /// The run stream's continuation, installed by `completedRuns()`.
    /// `nil` until something subscribes, which is the ordinary state in
    /// `--dispatch` runs and in most of the suite.
    private var runContinuation: AsyncStream<TerminalRun>.Continuation?
    /// Per pane, the command a `term_propose` had queued — consumed by the
    /// next run whose command matches. See `markNextRunProposed`.
    private var proposedCommands: [TerminalKey: String] = [:]

    /// Where per-pane rc directories are made. The process temp dir in the
    /// shipped app; the test run's own root under test, so a pane a test
    /// never closes is still removed when the run exits (#279).
    private let scratchRoot: URL

    public init(
        scratchRoot: URL = FileManager.default.temporaryDirectory,
        panes: PaneStore? = nil
    ) {
        self.scratchRoot = scratchRoot
        self.panes = panes
    }

    /// Opens a shell at `path` for `paneId`.
    ///
    /// **An already-open pane is torn down first.** A pane holds exactly
    /// one shell — there are no tabs, and a second shell is a second pane
    /// — so a second `term_open` on the same pane replaces rather than
    /// leaks.
    ///
    /// **Single-flight per pane, and that is load-bearing.** The teardown
    /// this begins with is a suspension point. Without the guard, two
    /// `open`s on one pane both suspended there, both resumed, both
    /// spawned, and the second's `sessions[paneId] = session` overwrote
    /// the first — whose shell, master and drain thread were then
    /// unreachable and could never be reaped. `close`'s guard was already
    /// atomic; this is the same guard on the other side, and the `while`
    /// (not `if`) is what makes it hold when three callers pile up.
    @discardableResult
    public func open(
        paneId: String, path: String, shell: String = TerminalStore.defaultShell(),
        cols: Int = 80, rows: Int = 24,
        environment: [String: String] = [:]
    ) async throws -> TerminalOpened {
        let name = (shell as NSString).lastPathComponent
        guard Self.supportedShells.contains(name) else {
            throw TerminalOpenError.unsupportedShell(shell)
        }
        // Every re-check happens after a resumption, and the install below
        // it runs with no suspension in between, so exactly one open per
        // pane is ever in flight.
        let key = await key(paneId)
        while let inFlight = openTasks[key] { _ = try? await inFlight.value }
        let task = Task<TerminalOpened, Error> {
            try await self.performOpen(
                key: key, path: path, shell: shell, shellName: name,
                cols: cols, rows: rows, environment: environment)
        }
        openTasks[key] = task
        return try await task.value
    }

    private func performOpen(
        key: TerminalKey, path: String, shell: String, shellName: String,
        cols: Int, rows: Int, environment: [String: String]
    ) async throws -> TerminalOpened {
        let paneId = key.paneId
        // Cleared here rather than in `open` so the slot is already empty
        // when the next caller resumes from `await inFlight.value`.
        defer { openTasks[key] = nil }
        await close(key: key)

        rcSerial += 1
        let rcDirectory = rcDirectory(for: paneId, serial: rcSerial)
        // The caller's own `environment:` is layered on top of Wakil's
        // process environment for `shellLaunch`'s `base` too — not just
        // for the final `childEnvironment` below — so a caller CAN
        // redirect where a zsh pane's rc restores `ZDOTDIR`/`HOME` to
        // (`WAKIL_USER_ZDOTDIR` reads `base["ZDOTDIR"] ?? base["HOME"]`).
        // Without this a test could isolate a bash pane's `HOME` but had
        // no way to stop a zsh pane's rc from sourcing the real
        // operator's `~/.zshrc` — the gap task 7's own report flagged.
        // See `launchBase(processEnvironment:callerEnvironment:)` for why
        // a real, un-overridden `ZDOTDIR` also has to be stripped, not
        // merely left un-overridden.
        let launchBase = Self.launchBase(
            processEnvironment: ProcessInfo.processInfo.environment, callerEnvironment: environment)
        let launch: (argv: [String], environment: [String: String])
        do {
            launch = try shellLaunch(shell: shell, rcDirectory: rcDirectory, base: launchBase)
        } catch {
            throw TerminalOpenError.spawnFailed("\(error)")
        }
        let childEnvironment = Self.childEnvironment(
            processEnvironment: ProcessInfo.processInfo.environment,
            callerEnvironment: environment, launchEnvironment: launch.environment)

        let session = TerminalSession(
            paneId: paneId, shellName: shellName, cols: cols, rows: rows)
        guard session.spawn(argv: launch.argv, environment: childEnvironment, cwd: path) else {
            throw TerminalOpenError.spawnFailed(shell)
        }
        sessions[key] = session
        rcDirectories[key] = rcDirectory
        if let panes {
            let home = key.scope
            // A new shell is a new history: the old blocks belonged to a
            // process that no longer exists, and leaving them under a fresh
            // prompt would present another shell's output as this one's.
            await ScopeRouting.$home.withValue(home) {
                await panes.clearTerminal(paneId: paneId)
                await panes.setTerminalLiveState(
                    paneId: paneId, cwd: path, shell: shellName, cols: cols, rows: rows,
                    screen: .blocks, grid: [])
            }
        }
        startPublishing()
        return TerminalOpened(shell: shellName, cols: cols, rows: rows, cwd: path)
    }

    /// The shell's whole environment, handed to `spawn` as is: Wakil's process environment,
    /// the caller's `environment:` over it, `shellLaunch`'s additions over that, then
    /// `terminalChildEnvironment` as the floor (`TERM` seeded, `COLUMNS`/`LINES` stripped).
    ///
    /// **The place comes from the caller alone.** `term_open` folds the window's org, project
    /// and environment into what it hands down; a `WAKIL_*` the caller did not set is removed,
    /// so a pin Wakil.app itself was launched with never shows through as the shell's place.
    /// Pure, like `launchBase`, so a test can fabricate the process environment.
    static func childEnvironment(
        processEnvironment: [String: String], callerEnvironment: [String: String],
        launchEnvironment: [String: String]
    ) -> [String: String] {
        var result = processEnvironment
        for (key, value) in callerEnvironment { result[key] = value }
        for (key, value) in launchEnvironment { result[key] = value }
        return terminalChildEnvironment(
            org: callerEnvironment["WAKIL_ORG"] ?? "",
            project: callerEnvironment["WAKIL_PROJECT"] ?? "",
            environment: callerEnvironment["WAKIL_ENVIRONMENT"] ?? "",
            base: result)
    }

    /// `shellLaunch`'s `base`: `processEnvironment` (Wakil's own process
    /// environment in shipped use, a fabricated dict in a test) with
    /// `callerEnvironment` (`open`'s `environment:`) layered on top —
    /// **and then, when `callerEnvironment` sets `HOME` but not
    /// `ZDOTDIR`, with any `ZDOTDIR` stripped out.**
    ///
    /// That extra strip is the fix, not the merge above it. `shellLaunch`
    /// derives `WAKIL_USER_ZDOTDIR` as `base["ZDOTDIR"] ?? base["HOME"]`,
    /// so a caller overriding only `HOME` — which is all
    /// `environment: ["HOME": scratchHome()]` does, and what the three
    /// live-shell tests use — was previously still out-ranked by a REAL,
    /// un-overridden `ZDOTDIR` sitting in `processEnvironment`: on any
    /// machine that exports one (common with zsh frameworks), the merge
    /// alone left it there, `??` picked it first, and a zsh pane's rc
    /// still sourced the operator's real `~/.zshrc`. It only ever passed
    /// on a machine that happens not to export `ZDOTDIR`. A pure function
    /// of two plain dictionaries rather than reading
    /// `ProcessInfo.processInfo.environment` inline, specifically so a
    /// test can assert this without mutating the real process
    /// environment — see the sibling tests in `TerminalStoreTests.swift`.
    static func launchBase(
        processEnvironment: [String: String], callerEnvironment: [String: String]
    ) -> [String: String] {
        var base = processEnvironment
        for (key, value) in callerEnvironment { base[key] = value }
        if callerEnvironment["HOME"] != nil && callerEnvironment["ZDOTDIR"] == nil {
            base.removeValue(forKey: "ZDOTDIR")
        }
        return base
    }

    /// A per-pane directory under `scratchRoot` — the process's temporary
    /// directory, in the shipped app — removed at teardown. Per pane
    /// rather than per app because zsh takes its rc by `ZDOTDIR`, which is
    /// a directory, and two panes sharing one would make a future per-pane
    /// rc impossible to add. `instanceId` is folded in so two different
    /// `TerminalStore`s never compute the same path for the same `paneId`
    /// — see `instanceId`'s doc comment.
    private func rcDirectory(for paneId: String, serial: Int) -> URL {
        scratchRoot.appendingPathComponent("wakil-terminal-\(instanceId)-\(paneId)-\(serial)")
    }

    /// The shell `paneId` names for the running caller: in its own scope (`ScopeRouting.home`),
    /// else the one on screen. Pane ids repeat across scopes loaded from disk, so a pane id alone
    /// would let one place's `term_open` close another place's shell.
    private func key(_ paneId: String) async -> TerminalKey {
        TerminalKey(scope: await panes?.activeScope, paneId: paneId)
    }

    /// Keystrokes, an accepted proposal, or the engine's own replies,
    /// straight to the pane's pty.
    ///
    /// **Bounded.** `writeToPty` gives up at
    /// `TerminalSession.writeDeadlineSeconds` rather than parking this
    /// actor in `write(2)` against a shell that has stopped reading its
    /// tty — see its own doc comment for the wedge that closed. What it
    /// gave up on is drained into `abandonedWrites` here rather than
    /// vanishing.
    public func write(paneId: String, bytes: [UInt8]) async {
        guard let session = sessions[await key(paneId)] else { return }
        session.writeToPty(bytes)
        abandonedWrites.append(contentsOf: session.takeAbandonedWrites())
    }

    public func resize(paneId: String, cols: Int, rows: Int) async {
        sessions[await key(paneId)]?.resize(cols: cols, rows: rows)
    }

    /// Whether this store still **holds a session** for `paneId` — a
    /// dictionary lookup, not a liveness check on a process.
    ///
    /// **Stated plainly because the name invites the other reading, and
    /// the difference is exactly what "no shell outlives its pane" turns
    /// on.** `true` means `open` installed a session and no teardown has
    /// removed it; it does not mean the child is alive (a shell that
    /// exited on its own is still here until its block seals and something
    /// closes the pane), and `false` does not by itself mean the child is
    /// dead — `performTeardown` clears this entry BEFORE it touches the
    /// descriptor, deliberately, so that a keystroke arriving mid-close
    /// cannot find a session whose fd is about to be recycled. The window
    /// between those two facts is real and is where a teardown that
    /// abandons (`abandonedResources`) lives permanently.
    ///
    /// So a test asserting that a shell was **reaped** must assert on the
    /// pid (`kill(pid, 0) == -1`), never on this; `pidForTesting` exists
    /// for that, and the live-shell tests use it for exactly this reason.
    public func isRunning(paneId: String) async -> Bool { sessions[await key(paneId)] != nil }

    public func dimensions(paneId: String) async -> (cols: Int, rows: Int)? {
        sessions[await key(paneId)].map { ($0.cols, $0.rows) }
    }

    /// TEST-ONLY: the child's pid, so a test can assert it was **reaped**
    /// rather than merely dereferenced. The fourth clause of this
    /// sub-phase's exit criterion is its least-defended claim, and a
    /// classification test cannot prove it.
    func pidForTesting(paneId: String) async -> pid_t? {
        sessions[await key(paneId)].map(\.pid)
    }

    /// TEST-ONLY: how many `open`s are in flight, so a test can sweep at a
    /// moment when there demonstrably is one. A sweep that began before any
    /// `open` had entered the actor would prove nothing: a pane opened
    /// after quit is not a pane quit could have seen.
    func openInFlightCountForTesting() -> Int { openTasks.count }

    /// TEST-ONLY: the panes still holding a shell.
    func runningPaneIdsForTesting() -> [String] { sessions.keys.map(\.paneId).sorted() }

    /// TEST-ONLY: whether this pane's pty master is non-blocking — the
    /// mechanism that makes `TerminalSession.writeToPty`'s bound possible
    /// at all, and therefore worth asserting on its own. A blocking master
    /// cannot be bounded by any amount of care in the loop above it: the
    /// process is already parked inside `write(2)` before anything can
    /// check a deadline.
    func masterIsNonBlockingForTesting(paneId: String) async -> Bool {
        guard let master = sessions[await key(paneId)]?.master, master >= 0 else { return false }
        let flags = fcntl(master, F_GETFL, 0)
        return flags != -1 && (flags & O_NONBLOCK) != 0
    }

    /// TEST-ONLY: every non-`.output` event this pane's shell has emitted,
    /// from Wakil's own scan of the raw pty bytes. For the live-shell
    /// tests that assert a real bash or zsh actually emits Wakil's marks.
    func marksForTesting(_ paneId: String) async -> [TerminalStreamEvent] {
        sessions[await key(paneId)]?.marksForTesting() ?? []
    }

    /// The shell's live working directory, from OSC 7 — empty until the
    /// first prompt.
    public func cwd(paneId: String) async -> String { sessions[await key(paneId)]?.cwd ?? "" }

    /// TEST-ONLY: whether the live screen currently contains `needle`.
    func screenContains(_ paneId: String, _ needle: String) async -> Bool {
        sessions[await key(paneId)]?.screenLines().contains { $0.contains(needle) } ?? false
    }

    /// TEST-ONLY (#365).
    func inputLine(_ paneId: String) async -> TerminalInputLine? { sessions[await key(paneId)]?.inputLine() }
    /// TEST-ONLY (#365).
    func screenLines(_ paneId: String) async -> [String] { sessions[await key(paneId)]?.screenLines() ?? [] }
    /// TEST-ONLY (#365).
    func bracketedPaste(_ paneId: String) async -> Bool { sessions[await key(paneId)]?.bracketedPasteMode ?? false }
    /// TEST-ONLY (#365).
    func marks(_ paneId: String) async -> [TerminalStreamEvent] { sessions[await key(paneId)]?.marksForTesting() ?? [] }
    /// TEST-ONLY: bytes handed to the session's own parse as if the shell had written them, so
    /// a test can land a shell-integration mark that dirties no row and moves no cursor.
    func feedForTesting(_ paneId: String, _ bytes: [UInt8]) async { sessions[await key(paneId)]?.feedForTesting(bytes) }
    /// TEST-ONLY (#365).
    func lineEditSupported(_ paneId: String) async -> Bool { sessions[await key(paneId)]?.lineEditSupportedForTesting() ?? false }

    /// Kills one pane's shell and waits for it. Safe concurrently, twice,
    /// and on a pane that never opened.
    public func close(paneId: String) async {
        await close(key: key(paneId))
    }

    /// Moves every shell opened in `outgoing` to `incoming`, for a scope whose panes moved
    /// wholesale (`PaneStore.switchScope(to:adoptingFrom:)`): a shell opened on the Landing
    /// keeps answering the operator's keys, and publishing into its pane, once the first turn
    /// files that canvas under a conversation.
    public func rehome(from outgoing: LayoutScope, to incoming: LayoutScope) {
        func moved(_ key: TerminalKey) -> TerminalKey? {
            key.scope == outgoing ? TerminalKey(scope: incoming, paneId: key.paneId) : nil
        }
        for key in sessions.keys { if let to = moved(key) { sessions[to] = sessions.removeValue(forKey: key) } }
        for key in rcDirectories.keys {
            if let to = moved(key) { rcDirectories[to] = rcDirectories.removeValue(forKey: key) }
        }
        for key in publishedCursors.keys {
            if let to = moved(key) { publishedCursors[to] = publishedCursors.removeValue(forKey: key) }
        }
        for key in publishedCommandRunning.keys {
            if let to = moved(key) {
                publishedCommandRunning[to] = publishedCommandRunning.removeValue(forKey: key)
            }
        }
        for key in proposedCommands.keys {
            if let to = moved(key) { proposedCommands[to] = proposedCommands.removeValue(forKey: key) }
        }
    }

    private func close(key: TerminalKey) async {
        if let existing = teardownTasks[key] {
            await existing.value
            return
        }
        guard let session = sessions[key] else { return }
        let task = Task { await self.performTeardown(key, session) }
        teardownTasks[key] = task
        await task.value
    }

    private func performTeardown(_ key: TerminalKey, _ session: TerminalSession) async {
        // **Unreachable BEFORE the descriptor is touched.** Clearing this
        // after the await left the session findable for the whole teardown
        // window — the actor is free during that suspension — so a
        // keystroke arriving mid-close reached `write(paneId:)`, passed
        // `guard master >= 0`, and called `write(2)` on the fd the
        // teardown thread had just closed. The failure is not EBADF:
        // descriptor numbers are recycled aggressively, so that writes
        // shell keystrokes into whatever reopened the number.
        sessions[key] = nil
        publishedCursors[key] = nil
        publishedCommandRunning[key] = nil

        // Off the cooperative pool: `teardown()` waits on a thread and on
        // a child, and the pool is small and shared by every
        // actor-isolated task in the process. `MCPClient.waitForProcessExit`'s
        // doc comment records what starving it costs — one permanent hang
        // killed after 75 seconds, with the child already exited.
        let abandoned = await withCheckedContinuation {
            (continuation: CheckedContinuation<AbandonedPty?, Never>) in
            let thread = Thread {
                continuation.resume(returning: session.teardown())
            }
            thread.stackSize = 1 << 20
            thread.start()
        }
        if let abandoned { abandonedResources.append(abandoned) }
        // **After the kill, not before.** The drain thread has finished by
        // now, so every byte the shell managed to emit — including the `D`
        // its `EXIT` trap wrote if it got the chance — is already sealed
        // into a block. Publishing here is what keeps the last command of
        // a pane's life from being lost between the final 60 Hz tick and
        // the teardown that made the session unreachable.
        await publish(key, session: session, sealingOpenBlock: true)
        if let rcDirectory = rcDirectories.removeValue(forKey: key) {
            try? FileManager.default.removeItem(at: rcDirectory)
        }
        teardownTasks[key] = nil
    }

    // MARK: - Publishing

    /// One frame at 60 Hz. See `startPublishing()`.
    private static let publishIntervalNanoseconds: UInt64 = 16_666_666

    /// **Redraw is driven by a polled `getUpdateRange()` at the display's
    /// frame rate, never from the feed.** There is no push to drive it
    /// from — `TerminalDelegate` has no content-change member at all — and
    /// polling *is* the coalescing: it turns 28 MB of `cat` into 21 frames
    /// and 144–792 repainted rows, against 1,179,666 rows if every 1 KB
    /// chunk drew (probe §4.2). The pane's redraw cost is a function of
    /// this interval and nothing else, not of how hard the shell is trying.
    ///
    /// **It neither busy-waits nor misses anything.** It sleeps a frame
    /// between passes rather than spinning, and it stops outright once no
    /// pane holds a shell, so an idle store costs nothing at all; every
    /// `open` starts it again. Nothing is missed because both things it
    /// collects are *take-and-clear* buffers under the session's lock
    /// rather than edges — a block sealed between two passes is still
    /// sitting in `completedBlocks` at the next one, and SwiftTerm's dirty
    /// range accumulates until `takeUpdateRange()` clears it.
    private func startPublishing() {
        guard publisher == nil, panes != nil else { return }
        publisherGeneration += 1
        let generation = publisherGeneration
        publisher = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, await self.publishOnce() else { break }
                try? await Task.sleep(nanoseconds: Self.publishIntervalNanoseconds)
            }
            await self?.publisherFinished(generation: generation)
        }
    }

    /// Which loop is the current one. **A cancelled loop still runs its
    /// last line**, and it does so after the actor has been free — long
    /// enough for an `open` to have started a replacement. Without this
    /// counter that straggler's `publisherFinished()` cleared the slot the
    /// replacement had just filled and started a THIRD loop, leaving two
    /// running against one store. Harmless to correctness (blocks are
    /// taken-and-cleared, so neither loop can publish the same one twice)
    /// and pure waste otherwise. An `open` landing after `shutdownAll()` reaches it.
    private var publisherGeneration = 0

    /// Clears the slot this task occupied, and starts a fresh loop if a
    /// pane opened while it was stopping.
    ///
    /// **The restart is the whole point of this being a method.** The loop
    /// decides to stop while the actor is free, and an `open` that lands
    /// in that window sees a non-`nil` `publisher` and starts nothing —
    /// so without this its pane would never publish a block at all.
    private func publisherFinished(generation: Int) {
        guard generation == publisherGeneration else { return }
        publisher = nil
        if !sessions.isEmpty { startPublishing() }
    }

    /// Returns false when nothing is left to publish, which stops the loop.
    private func publishOnce() async -> Bool {
        guard panes != nil, !sessions.isEmpty else { return false }
        for (key, session) in sessions {
            await publish(key, session: session, sealingOpenBlock: false)
        }
        return true
    }

    /// Drains one session's sealed blocks into the pane store, yields a
    /// run for each, and refreshes the live state when the engine reports
    /// a dirty range.
    private func publish(
        _ key: TerminalKey, session: TerminalSession, sealingOpenBlock: Bool
    ) async {
        guard panes != nil else { return }
        // Home, not the screen: the scope the shell was opened in (`TerminalKey`). The 60 Hz
        // loop belongs to no dispatch, so without this it would write into whichever scope is on
        // screen. Bound for the whole pass, so every write below lands in one scope whatever the
        // window does between them.
        await ScopeRouting.$home.withValue(key.scope) {
            await publishHome(key, session: session, sealingOpenBlock: sealingOpenBlock)
        }
    }

    /// `publish`'s body, run with the session's home bound.
    private func publishHome(
        _ key: TerminalKey, session: TerminalSession, sealingOpenBlock: Bool
    ) async {
        guard let panes else { return }
        let paneId = key.paneId
        // Written from the drain thread by `flushEngineResponses`, so this
        // is the only place a give-up there is ever picked up.
        abandonedWrites.append(contentsOf: session.takeAbandonedWrites())
        var blocks = session.takeCompletedBlocks()
        if sealingOpenBlock, let sealed = session.sealOpenBlockAtTeardown() {
            blocks.append(sealed)
        }
        for block in blocks {
            await panes.recordTerminal(paneId: paneId, block: block)
            yieldRun(key, cwd: session.cwd, block: block)
        }
        // Walk-defects D1. **After** the loop above, not before: a
        // `clear` earns a completed block the same as any other command
        // (its `C`/`D` marks are ordinary shell integration, recorded by
        // `recordTerminal` like `ls`'s would be), and the operator's own
        // decision is that block disappears too, along with every one
        // before it — which only happens if it is recorded first and then
        // wiped here, never the other way round. No marker block is
        // written in its place; see `PaneStore.clearTerminalBlocks`'s own
        // doc comment for why that is deliberate.
        if session.takeScreenCleared() {
            await panes.clearTerminalBlocks(paneId: paneId)
        }
        // The dirty range is the only signal SwiftTerm gives that the
        // screen changed, and it is taken (not merely read) so the next
        // pass sees only what has happened since.
        //
        // **It says nothing about the cursor** (#365 walk): zsh moves right
        // with `ESC[C`, which dirties no row, so a → that moved only the
        // cursor stayed unpublished — the drawn cursor sat still, then
        // jumped on the next ← (a `\b`, which does dirty its row). A moved
        // cursor is a change of its own.
        let dirty = session.takeUpdateRange() != nil
        let cursor = session.cursorPosition()
        let cursorMoved = publishedCursors[key].map { $0 != cursor } ?? true
        // **Nor about a command starting** (e2e bg-org-switch-keeps-the-terminal): zsh's preexec
        // writes the `C` mark after the line's newline, so a pass can publish the newline before
        // the mark is parsed, and the mark itself dirties nothing. A `tail -f` that then prints
        // nothing read as idle for as long as it ran.
        let running = session.commandRunning
        let runningChanged = publishedCommandRunning[key].map { $0 != running } ?? true
        guard dirty || cursorMoved || runningChanged || sealingOpenBlock else { return }
        publishedCursors[key] = cursor
        publishedCommandRunning[key] = running
        let onTheGrid = session.isAlternateScreenActive
        await panes.setTerminalLiveState(
            paneId: paneId, cwd: session.cwd, shell: session.shellName,
            cols: session.cols, rows: session.rows,
            screen: onTheGrid ? .grid : .blocks,
            // **Always, not only under the alternate screen** (final
            // review, Critical 2). This used to publish `[]` on the block
            // surface, on the argument that the rows are already in the
            // blocks — which is true of rows that are already in a block
            // and false of every row that is not yet: the prompt itself,
            // the characters being typed into it, and a command's output
            // while it is still running. With `grid` empty there, the
            // operator typed blind and an `npm install` showed nothing
            // until it finished, and `read_pane` answered `grid: []`
            // while this type's own doc comment promised both surfaces
            // always. `screen` still names the one the operator is
            // looking at; the live region under the block history
            // (`TerminalPane.liveRegion`) draws this.
            //
            // It stays the **visible screen only, never scrollback** —
            // `TerminalSnapshot.grid`'s own rule, and the reason this is
            // affordable at all: the bound is `cols × rows`, per pane,
            // per dirty frame, not the history.
            grid: session.screenLines(),
            // The two walk-fix seams (walk-defects list): the row the
            // current prompt began on, and the pty's own cursor — both
            // tracked by `TerminalSession` already, published here
            // alongside the grid they share a coordinate space with.
            promptRow: session.promptRow, cursorRow: cursor.row, cursorCol: cursor.col,
            // `grid`'s own colour, read from SwiftTerm's per-cell
            // `Attribute` and coalesced into runs — see
            // `TerminalSession.styledScreenLines`'s own doc comment.
            gridStyles: session.styledScreenLines(),
            // The third walk-fix seam, alongside `promptRow` and the
            // cursor: whether a command is running right now, off the
            // same `openBlock` state `TerminalSession.commandRunning`
            // documents. `terminalLiveRegionSlice` reads this to decide
            // whether the live region is "the prompt" or "the screen".
            commandRunning: running,
            inputLine: session.inputLine(),
            bracketedPaste: session.bracketedPasteMode)
    }

    /// Emits a `TerminalRun` for a block that has just sealed, consuming
    /// the pane's pending proposal flag whether or not anything is
    /// listening — a flag left behind would attach itself to some later,
    /// unrelated command.
    private func yieldRun(_ key: TerminalKey, cwd: String, block: TerminalBlock) {
        let wasProposed = takeProposedFlag(for: key, command: block.command)
        runContinuation?.yield(TerminalRun(
            paneId: key.paneId, command: block.command, cwd: cwd, exitCode: block.exitCode,
            durationMs: block.durationMs, wasProposed: wasProposed, scope: key.scope))
    }

    /// Every command that finishes in any pane, in completion order.
    ///
    /// **`bufferingPolicy: .unbounded`, unlike `ActionRegistry.dispatches()`.**
    /// That one's `bufferingNewest(1)` is right for a wake-up, where only
    /// the fact that something changed matters. It is wrong here: a
    /// dropped element is a command that ran and was never journalled,
    /// which is the one thing this stream exists to prevent.
    ///
    /// One subscriber — `WindowModel`'s run pump.
    ///
    /// **A second call finishes the outgoing continuation before
    /// installing its own.** Replacing the stored continuation without
    /// that leaves the FIRST caller's stream open with nothing left to
    /// ever yield or finish it — a `for await` that hangs forever with no
    /// signal, the exact failure class (a silent, undiagnosable stall)
    /// this project has already lost hours to elsewhere today. Finishing
    /// it here means an abandoned first subscriber's loop ends cleanly
    /// instead.
    public func completedRuns() -> AsyncStream<TerminalRun> {
        runContinuation?.finish()
        let (stream, continuation) = AsyncStream<TerminalRun>.makeStream(
            of: TerminalRun.self, bufferingPolicy: .unbounded)
        runContinuation = continuation
        return stream
    }

    /// Records that the next run of `command` in `paneId` reached the
    /// prompt as an accepted proposal rather than as typed text.
    ///
    /// **Recorded here rather than read off the block**, because by the
    /// time the command runs it is indistinguishable from a typed one —
    /// which is the point of `term_propose`: the bytes go into the
    /// operator's own prompt without a newline, and from that instant the
    /// command is theirs in every sense. Only Wakil's own memory of having
    /// put them there survives, and this is it.
    public func markNextRunProposed(paneId: String, command: String) async {
        proposedCommands[await key(paneId)] = command
    }

    /// Consumes the pane's pending proposal flag if `command` is the one
    /// that was proposed. **Cleared either way**: a proposal the operator
    /// edited before pressing Enter is a different command, and leaving
    /// the flag armed would mark whatever they ran next as proposed.
    ///
    /// The plan names this `takeProposedFlag(for:)`; it needs the command
    /// as well as the pane, because matching on the command is what the
    /// plan's own description of the flag requires.
    func takeProposedFlag(for paneId: String, command: String) async -> Bool {
        takeProposedFlag(for: await key(paneId), command: command)
    }

    private func takeProposedFlag(for key: TerminalKey, command: String) -> Bool {
        guard let pending = proposedCommands.removeValue(forKey: key) else { return false }
        return pending == command
    }

    /// Every shell, gone, and the run stream finished: app quit and the window's own shutdown,
    /// the end of every consumer's `for await`. Nothing else stops every shell — an org switch
    /// keeps them all (background agents 3 of 4), so the stream the window subscribes to once,
    /// in `init`, is never finished under a window that carries on.
    public func shutdownAll() async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        let task = Task {
            // **In-flight opens first.** A pane mid-`open` has no
            // `sessions` entry yet, so a sweep that only walked `sessions`
            // went straight past it and the shell it was about to install
            // outlived the app — against this sub-phase's own exit
            // criterion, that no shell outlives the pane that opened it.
            // Draining to empty rather than snapshotting once, so an open
            // that installs its OWN task while this loop is still
            // awaiting an earlier one is still caught. **What this does
            // NOT cover** is a caller still parked in `open`'s `while let
            // inFlight = openTasks[paneId]` loop: it has not created its
            // task yet, so it has no entry here for the drain to see. If
            // that caller only inserts one after this loop has already
            // found `openTasks` empty and returned, the two — the queued
            // open and `shutdownAll` itself — resume in undefined order.
            while !self.openTasks.isEmpty {
                for inFlight in self.openTasks.values { _ = try? await inFlight.value }
            }
            for key in self.sessions.keys.sorted(by: { $0.paneId < $1.paneId }) {
                await self.close(key: key)
            }
            // After the last `close`, so the block a `tail -f` was still
            // in has already been sealed and yielded: nothing sealed is dropped.
            // The publisher has no pane left to publish for.
            self.stopPublisher()
            self.finishRunStream()
        }
        shutdownTask = task
        await task.value
        shutdownTask = nil
    }

    private func stopPublisher() {
        publisher?.cancel()
        publisher = nil
    }

    /// `finish()` is what ends the consumer's `for await`; without it the
    /// run pump would outlive the store it reads. **The window's end only** — see
    /// `shutdownAll()`.
    private func finishRunStream() {
        runContinuation?.finish()
        runContinuation = nil
    }
}
