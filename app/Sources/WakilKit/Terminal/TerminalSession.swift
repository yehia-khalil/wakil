import Foundation
import SwiftTerm
#if canImport(Darwin)
import Darwin
#endif

/// A pty master and a child pid that teardown had to give up on, kept so
/// the store can say exactly what it leaked. See
/// `TerminalStore.abandonedResources` for why abandoning beats blocking.
/// Bytes a write to a pane's pty could not deliver before its deadline —
/// the write side's equivalent of `AbandonedPty`.
///
/// **Recorded rather than merely dropped**, for the reason
/// `TerminalStore.abandonedResources` states for the read side: what was
/// given up on is a fact about the pane, and a silently truncated write
/// into a shell that stopped reading is exactly the kind of thing that is
/// impossible to diagnose after the fact if nothing kept it.
struct AbandonedWrite: Sendable, Equatable {
    let paneId: String
    /// How many bytes of the requested write never reached the pty.
    let unwritten: Int
}

struct AbandonedPty: Sendable, Equatable {
    /// The master descriptor, deliberately left OPEN — closing it while a
    /// read is parked is the forever-block the teardown ordering exists to
    /// avoid. `-1` when the descriptor was closed normally and only the
    /// reap was abandoned.
    let master: Int32
    /// The child, deliberately left UNREAPED. `-1` when the child was
    /// reaped and only the descriptor was abandoned.
    let pid: pid_t
}

/// The engine's own output, parked until the engine lock is free, plus the
/// two out-of-band states SwiftTerm reports only by callback.
///
/// **Why the delegate must not write to the pty where it is called.**
/// SwiftTerm invokes `send` from inside the parse path — the DA and DSR
/// replies at `Terminal.swift` 670, 1938 and 2388 — and the parse runs
/// under `TerminalSession.lock`. Writing there means blocking in
/// `write(2)` while holding the lock, and everything else that wants the
/// lock — `TerminalStore.write` and `resize`, on the actor's executor
/// thread — is then stuck behind a drain thread that has stopped
/// draining. So the bytes are parked here and flushed once the lock is
/// released.
///
/// **This narrows the stall; it does not abolish it.** A child that has
/// stopped reading its slave can still park the drain thread in `write(2)`
/// inside `flushEngineResponses`, which stops it reading, which fills the
/// child's output buffer — the same flow-control stall, now without the
/// lock held and without anything else queued behind it. What makes that
/// survivable is not this class: it is that teardown's drain wait is
/// bounded at `TerminalSession.teardownDeadlineSeconds` and abandons, so
/// a stalled drain thread costs one abandoned descriptor rather than a
/// teardown chain that never completes.
final class TerminalSessionSignals: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingResponses: [UInt8] = []
    /// Whether the alternate screen is active RIGHT NOW — the level
    /// `isAlternateScreenActive` answers with, and nothing this session
    /// uses to decide `heldTheGrid`. **A block's own `heldTheGrid` is
    /// decided by scanning that block's own captured bytes for the
    /// switch-in sequence** (see `TerminalSession.alternateScreenSwitchStartIndex`,
    /// used from `consume`'s `.output` case), not by this level or any
    /// chunk-wide latch derived from it — a chunk-wide latch cannot tell
    /// WHICH of several blocks assembled from one chunk the switch belongs
    /// to, and a review of this file found exactly that: two commands
    /// pasted together, landing in one `read(2)`, credited the first with
    /// a switch that happened during the second.
    private var alternateScreen = false
    private var hostDirectory: String?

    func parkResponse(_ bytes: ArraySlice<UInt8>) {
        lock.lock()
        pendingResponses.append(contentsOf: bytes)
        lock.unlock()
    }

    /// The parked bytes, handed over and cleared. Called only after the
    /// engine lock has been released.
    func takeResponses() -> [UInt8] {
        lock.lock()
        let taken = pendingResponses
        pendingResponses.removeAll(keepingCapacity: false)
        lock.unlock()
        return taken
    }

    func setAlternateScreen(_ value: Bool) {
        lock.lock()
        alternateScreen = value
        lock.unlock()
    }

    func setHostDirectory(_ value: String) {
        lock.lock()
        hostDirectory = value
        lock.unlock()
    }

    var isAlternateScreen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return alternateScreen
    }

    var currentHostDirectory: String? {
        lock.lock()
        defer { lock.unlock() }
        return hostDirectory
    }
}

/// One shell: the pty master, the child, the drain thread, and the
/// SwiftTerm engine those bytes are fed into.
///
/// **A lock-guarded class, not an actor.** SwiftTerm's `Terminal` is not
/// thread-safe and the drain thread must feed it synchronously — an actor
/// would mean hopping the executor once per `read(2)`, which the pty caps
/// at 1,024 bytes regardless of the buffer offered (probe §6.3). One
/// `NSLock` around the engine, taken by the drain thread on `feed` and by
/// the poller on `getUpdateRange`, is the shape that keeps 78 MB/s.
///
/// **The drain thread parses inline and lets the pty block**, which is the
/// probe's correction to this spec's word "unbounded": the enqueue-and-
/// consume shape is 15% faster precisely *because* it cannot push back,
/// and it queued 18.33 MB during a 28 MB `cat` — a `cat` the operator does
/// by accident, scaling linearly with the file. Inline parsing cannot
/// exhaust memory at any size.
///
/// **A plain `Thread`, not a `readabilityHandler`** — measured at 1 useful
/// callback against 224,207 empty ones in the 300ms after EOF (#38). Same
/// shape as `ClaudeCodeCLIHarness.startStdoutDrainThread` and
/// `MCPClient`'s equivalent.
final class TerminalSession: @unchecked Sendable {
    /// How long teardown waits for the drain thread to see EOF, and then
    /// for the child to be reapable, before abandoning both.
    ///
    /// Two seconds is the budget this repo already gives a child to finish
    /// exiting — `ClaudeCodeCLIHarness`'s stdout drain deadline. The kill
    /// → EOF path was independently measured at 1–2 ms, so the deadline is
    /// three orders of magnitude of headroom, not a guess at a typical
    /// case.
    static let teardownDeadlineSeconds: Double = 2

    let paneId: String
    let shellName: String
    private(set) var master: Int32 = -1
    private(set) var pid: pid_t = -1
    /// The pty SLAVE's device number, captured at spawn. It is how
    /// teardown enumerates the pane's session — see `teardown()`.
    private(set) var slaveDevice: UInt32 = 0

    /// Guards `terminal`, `cols`, `rows`, `cwd`, `marks`, the open block
    /// and the sealed ones.
    let lock = NSLock()
    private let terminal: Terminal
    private let delegate: SessionDelegate
    private let signals = TerminalSessionSignals()
    private var drainThread: Thread?
    /// How long `startDraining`'s `poll(2)` waits before checking
    /// `stopRequested` again — the "one tick" the teardown doc comment
    /// promises the drain thread exits within once `requestStop()` is
    /// called, even with no EOF in sight.
    private static let drainPollTimeoutMilliseconds: Int32 = 50
    /// Set by `teardown()`, before it sends a single signal, read by the
    /// drain thread on every `poll(2)` timeout. A dedicated lock rather
    /// than `lock` above: this is checked on a timer from a thread that
    /// has nothing else to do with the terminal/marks state `lock` guards,
    /// and giving it its own lock keeps that check from ever contending
    /// with `consume`'s hot path.
    private let stopLock = NSLock()
    private var stopRequested = false

    private func requestStop() {
        stopLock.lock()
        stopRequested = true
        stopLock.unlock()
    }

    private func isStopRequested() -> Bool {
        stopLock.lock()
        defer { stopLock.unlock() }
        return stopRequested
    }
    private(set) var cols: Int
    private(set) var rows: Int

    /// Wakil's own scanner over the raw pty bytes — see
    /// `TerminalMarkScanner` for why this exists alongside SwiftTerm
    /// rather than asking it.
    private let scanner = TerminalMarkScanner()
    /// The shell's live working directory, from Wakil's own OSC 7 scan —
    /// empty until the first prompt. Written under `lock` on the drain
    /// thread, read without it elsewhere: the same tolerance this file
    /// already gives `cols` and `rows`.
    private(set) var cwd: String = ""
    /// The absolute grid row (same coordinate space as `screenLines()` —
    /// viewport-relative, never scrollback) the operator's CURRENT prompt
    /// began on: the row `terminal.buffer.y` was at when the last
    /// `.promptStart` (OSC 133;A) fired. `nil` before the first prompt.
    ///
    /// Published so `terminalLiveRegion` (`TerminalPaneSupport.swift`,
    /// walk-fix seam left by the walk-defects C2/D-seam list) can draw
    /// only the current prompt onward instead of redrawing the whole
    /// visible screen. Written under `lock` on the drain thread
    /// (`consume`'s `.promptStart` case), read without it elsewhere — the
    /// same tolerance this file already gives `cwd`, `cols` and `rows`.
    private(set) var promptRow: Int?
    /// Between a `133;B` and the next `A` or `C`: the operator is typing at
    /// a prompt (#365). Read and written under `lock`.
    private var atPrompt = false
    /// `.editSupported` arrived after the latest `A` — so this prompt is
    /// one Wakil's rc drew, not an ssh host's or a nested shell's.
    private var lineEditSupported = false
    /// Whether a command is running **right now**: this session has seen
    /// a `commandStart` (OSC 133;C) with no `commandEnd` (OSC 133;D)
    /// closing it since. `openBlock` below (`consume`'s `.commandStart`/
    /// `.commandEnd` cases) already tracks exactly this fact for the
    /// block itself — this is a read of that same state, not a second one
    /// kept in step by hand.
    ///
    /// **Not `signals.isAlternateScreen` or a block's own `heldTheGrid`.**
    /// Those answer "is a full-screen program on the alternate screen
    /// right now", a different question that `TerminalSnapshot.screen`
    /// already names — the live region this field feeds is drawn only
    /// when `screen != .grid`, i.e. never while that is true. This
    /// answers "is *any* command running", full-screen or not, which
    /// stays true for the whole life of a `claude` or `top` session on
    /// the ordinary screen — programs that render a full interface
    /// without ever switching to the alternate screen, so the grid-vs-
    /// blocks split alone never catches them.
    ///
    /// Published so the live region (`terminalLiveRegionSlice`,
    /// `TerminalPaneSupport.swift`) can stop treating "a command is
    /// running" and "the operator is at an idle prompt" as the same
    /// state: while idle, `promptRow` narrows the region to the current
    /// prompt and what has been typed at it (unchanged); while a command
    /// is running, this says so and the region draws the whole visible
    /// screen instead of an 8-row tail of it. Written under `lock` on the
    /// drain thread, alongside `openBlock` itself; read without it
    /// elsewhere — the same tolerance this file already gives `cwd`,
    /// `promptRow`, `cols` and `rows`.
    var commandRunning: Bool { openBlock != nil }
    /// TEST-ONLY accumulator: every non-`.output` event this session's
    /// shell has emitted, in order.
    ///
    /// **Bounded, the same shape as `TerminalBlock.openBufferByteCap`,
    /// even though a shipped build never reads it.** Flagged rather than
    /// fixed by the agent that added that cap: this array was still
    /// appended to UNCONDITIONALLY in production, on the drain thread,
    /// for the life of the session, with no bound at all — not
    /// byte-rate-driven the way the open buffer was (a TUI redrawing at
    /// frame rate emits none of these events after its own
    /// `commandStart`), but still a session that never stops growing,
    /// and this pane now hosts programs left open for hours. A pane that
    /// sees many hundreds of commands, or one that receives many
    /// prompt/OSC-7 events (`ssh` shell integration, heavy directory
    /// churn), grew this indefinitely.
    ///
    /// **Bounded rather than made genuinely test-only**, because the
    /// second option would trade a leak for a lie: every test in
    /// `marksForTesting`'s callers (`TerminalStoreTests`) asserts on a
    /// handful of marks from a session that just ran a handful of
    /// commands, never on the FULL history of a long-lived one — gating
    /// population behind a test-only flag would need that flag threaded
    /// through every production call site for a field production never
    /// reads anyway, for no test that actually needs the unbounded tail.
    /// A cap keeps every existing test's assertions true while giving
    /// production the same bound the open buffer got.
    ///
    /// Trimmed from the FRONT, keeping the tail — `appendMark`, right
    /// below.
    private var marks: [TerminalStreamEvent] = []
    /// **4,000 events.** Each command emits on the order of four
    /// (`promptStart`, `commandStart`, `commandEnd`, and usually one
    /// `hostDirectory`), so this is generous for a thousand commands in
    /// one session — far more than the "many hundreds" the leak this
    /// closes was measured against — while still bounding memory for a
    /// session left open indefinitely. Not tied to `TerminalBlock
    /// .historyCap` (200): that bounds SEALED BLOCKS, a different unit
    /// this array does not share, kept here as its own named constant so
    /// the two can move independently.
    private static let marksCap = 4_000
    /// Appends `event` to `marks` and trims it back to `marksCap` from
    /// the front — the one call site every `marks.append` in `consume`
    /// goes through, so the bound cannot be forgotten at a future call
    /// site the way the open buffer's own trim already is not (see
    /// `trimmedOpenBuffer`, applied at its own single call site the same
    /// way).
    private func appendMark(_ event: TerminalStreamEvent) {
        marks.append(event)
        if marks.count > Self.marksCap {
            marks.removeFirst(marks.count - Self.marksCap)
        }
    }

    /// The block `C` opened and `D` has not yet closed, accumulating on
    /// the drain thread under `lock`.
    ///
    /// **This is the whole reason the history is not read back out of the
    /// emulator.** A mark dies with the row the scrollback cap evicts — 6
    /// of 200 marked commands were already unrecoverable in measurement,
    /// 207 of 400 (probe §4.1) — so a block has to be captured while it
    /// happens or not at all.
    private struct OpenBlock {
        let id: String
        let command: String
        let startedAt: Date
        /// Raw bytes, split into lines only at the seal: a line can
        /// straddle any number of `read(2)`s.
        ///
        /// **Bounded to `TerminalBlock.openBufferByteCap`, trimmed to the
        /// tail on every `.output` event** (`consume`'s `.output` case,
        /// via `trimmedOpenBuffer`) — not just once at the seal the way
        /// `TerminalBlock.capped`'s line cap is. Without this, a command
        /// that never closes — a TUI redrawing its own interface at frame
        /// rate, left running for an hour — grew this array for as long
        /// as it ran, with nothing bounding it at all.
        ///
        /// **Stops accumulating the moment this block REPAINTS rather than
        /// PRINTS** (walk-defects D4, widened) — see `heldTheGrid` below
        /// and `consume`'s `.output` case. Before the original fix, this
        /// held the alternate screen's own mangled rows: `vim`'s takeover
        /// was captured into the block the same as any ordinary command's
        /// stdout, because nothing distinguished the two at the point of
        /// capture. The screen was never the command's stdout — Wakil's
        /// own generated rc gates OSC 133 behind `!isCurrentBufferAlternate`
        /// for the identical reason — and half-scraped screen rows are
        /// worse than an empty body.
        var output: [UInt8] = []
        /// **This block's own idea of which row of ITS OWN OUTPUT the
        /// cursor is on right now** — 0-indexed from this block's first
        /// byte, advanced only by `upwardCursorMoveScan`, on this block's
        /// own bytes, in wire order. Not `terminal.buffer.y`: that is the
        /// engine's ABSOLUTE row, and by the time this block's own bytes
        /// are scanned `terminal.feed` has already consumed the WHOLE
        /// chunk and moved past them — the identical "chunk-final state
        /// answers the wrong question" trap `screenClearScan`'s own doc
        /// comment names for the alternate screen, here for `CSI
        /// row;colH`/`f`, which need "was the cursor already past the
        /// target row BEFORE this sequence ran", not "where is it now".
        var cursorRow = 0
        /// An escape sequence `upwardCursorMoveScan` saw start but could
        /// not finish before this `.output` event's bytes ran out —
        /// carried into the next event's window rather than re-scanned,
        /// because unlike the alternate-screen needle below (a fixed
        /// short byte pattern, safe to look for again in a look-back
        /// window built from what is already in `output`) this scan
        /// ACCUMULATES `cursorRow`, and re-scanning bytes already counted
        /// would double-count them.
        ///
        /// **A bookkeeping aid for the scan alone — NOT a gate on what
        /// reaches `output`.** The bytes it holds are appended to
        /// `output` regardless, by whichever round first saw them
        /// (`consume`'s `.output` case, the `else` branch), the same
        /// unconditional append the alternate-screen mechanism has
        /// always made. An earlier version of this field withheld them
        /// instead — cleaner in isolation, and wrong: the alternate-
        /// screen scan's own look-back window is built from what is
        /// already committed to `output`, and withholding these bytes
        /// made that scan blind to a switch sequence split across the
        /// same boundary this field exists to survive, silently un-doing
        /// walk-defects D4's own split-read coverage.
        ///
        /// Bounded the same way `TerminalMarkScanner.pending` is, for
        /// the same reason (`upwardCursorMoveScanCap`) — past the bound,
        /// `cursorRow` simply stops accounting for whatever this turned
        /// out to be; the bytes themselves are unaffected, already in
        /// `output` either way.
        var pendingCursorScan: [UInt8] = []
        /// Set, and latched, the first time this block's own output is
        /// seen to REPAINT rather than PRINT — either of two ways in, as
        /// of this widening:
        ///
        /// 1. **The alternate screen** (the original, walk-defects D4):
        ///    an `.output` event arrives after this block's own bytes
        ///    switched into it (`alternateScreenSwitchStartIndex`).
        /// 2. **The cursor moves up** (this widening): this block's own
        ///    bytes contain `CSI A`, `CSI n F`, `ESC M`, or a `CSI
        ///    row;colH`/`f` addressing a row this scan had already
        ///    passed (`upwardCursorMoveScan`).
        ///
        /// **Widened from "switched to the alternate screen" to "moved
        /// the cursor up" because the first was a MECHANISM, not the
        /// BEHAVIOUR that actually matters.** `vim` happens to do both —
        /// take the alternate screen AND repaint in place — which is why
        /// keying on the mechanism looked sufficient. Claude Code (and
        /// any TUI that renders a full interface on the ordinary screen)
        /// does the second without the first: it never switches screens,
        /// so the original rule missed it entirely, and its block
        /// recorded the raw, unemulated redraw byte-stream — noise, not
        /// output, handed to an operator's block history and to an
        /// agent's `read_pane` alike.
        ///
        /// **`\r` alone is deliberately NOT one of the triggers.** A bare
        /// carriage return rewrites the CURRENT line — exactly what
        /// `npm install`, `curl` and every progress bar do — and that
        /// real output is exactly what an operator wants kept. Only
        /// upward movement, which repaints a row already left behind,
        /// counts.
        ///
        /// **Latched rather than tracking a live level**, for the same
        /// reason the original alternate-screen version was: a full-
        /// screen program can drop back to printing normally (a status
        /// line, a final redraw) before its `D` mark arrives, and any of
        /// that trailing noise is exactly as untrustworthy as the
        /// repaint itself — the decision is "a block that repainted
        /// records no output", not "no output while it happens to be
        /// repainting at this exact instant".
        var heldTheGrid = false
    }
    private var openBlock: OpenBlock?
    /// Blocks sealed at their `D` and not yet collected by the publisher.
    private var completedBlocks: [TerminalBlock] = []
    /// Distinguishes this session's blocks from the next shell's on the
    /// same pane. `TerminalBlock.id` is what `PaneStore.recordTerminal`
    /// de-duplicates on, so it must not repeat across a reopen.
    private let blockRunId = UUID().uuidString
    private var blockCounter = 0

    /// Set when the raw stream has shown the CSI "erase entire screen"
    /// sequence (walk-defects D1) outside the alternate screen since the
    /// last `takeScreenCleared()`. Latched, like `completedBlocks`, rather
    /// than tracking anything live: `TerminalStore`'s poll only needs to
    /// know that it happened at some point since the last pass, not
    /// exactly when.
    private var screenCleared = false
    /// Bytes held back because they might be the first few bytes of
    /// `screenClearSequence` OR of an alternate-screen switch split across
    /// a `read(2)` boundary — the same possibility `TerminalMarkScanner
    /// .pending` exists for OSC marks, kept here because neither of these
    /// two CSI sequences is one of that scanner's own OSC opens and
    /// neither ever becomes one of its events. Sized to the longer of the
    /// two needles `screenClearScan` looks for.
    private var pendingScreenClearScan: [UInt8] = []
    /// The alternate-screen state `screenClearScan` had tracked itself to
    /// as of the end of `pendingScreenClearScan`'s own window — **this
    /// session's own mirror of `signals.isAlternateScreen`, not that
    /// field itself.** See `screenClearScan`'s own doc comment for why a
    /// second, independently-tracked copy of "is the alternate screen
    /// active" is necessary here rather than reading the one `TerminalSession`
    /// already has.
    private var pendingScreenClearAlternate = false

    /// SwiftTerm's out-of-band events. It has **no content-change member
    /// at all** — the dirty range is polled, not pushed (probe §4.2) — so
    /// this carries only the alternate-screen switch, the OSC 7 cwd, the
    /// title, and bytes the engine wants written back to the pty.
    ///
    /// **All three are `let`s, handed to `init`.** As `var`s they were an
    /// unsynchronised ARC write racing the drain thread inside `feed`:
    /// `write` happened to be sound only because `spawn` assigned it
    /// before `startDraining()`, an invariant that was written down
    /// nowhere, and the other two had no safe writer at any point.
    final class SessionDelegate: TerminalDelegate, @unchecked Sendable {
        let onWrite: @Sendable (ArraySlice<UInt8>) -> Void
        let onAlternateScreenChanged: @Sendable (Bool) -> Void
        let onHostDirectory: @Sendable (String) -> Void

        init(
            onWrite: @escaping @Sendable (ArraySlice<UInt8>) -> Void,
            onAlternateScreenChanged: @escaping @Sendable (Bool) -> Void,
            onHostDirectory: @escaping @Sendable (String) -> Void
        ) {
            self.onWrite = onWrite
            self.onAlternateScreenChanged = onAlternateScreenChanged
            self.onHostDirectory = onHostDirectory
        }

        func send(source: Terminal, data: ArraySlice<UInt8>) { onWrite(data) }
        func bufferActivated(source: Terminal) {
            onAlternateScreenChanged(source.isCurrentBufferAlternate)
        }
        func hostCurrentDirectoryUpdated(source: Terminal) {
            // `hostCurrentDirectory` hands back a raw URL —
            // `file://localhost/Users/…` — not a path (probe §4.4).
            guard let raw = source.hostCurrentDirectory,
                  let url = URL(string: raw) else { return }
            onHostDirectory(url.path)
        }
    }

    init(paneId: String, shellName: String, cols: Int, rows: Int) {
        self.paneId = paneId
        self.shellName = shellName
        self.cols = cols
        self.rows = rows
        var options = TerminalOptions.default
        options.cols = cols
        options.rows = rows
        // Wakil's own block cap is what bounds the history; this bounds
        // only what a full-screen program can scroll back through.
        options.scrollback = 2_000
        // The closures capture the signals box rather than `self`, which
        // is what lets them be `let`s built before the engine exists.
        let signals = self.signals
        let delegate = SessionDelegate(
            onWrite: { signals.parkResponse($0) },
            onAlternateScreenChanged: { signals.setAlternateScreen($0) },
            onHostDirectory: { signals.setHostDirectory($0) })
        self.delegate = delegate
        self.terminal = Terminal(delegate: delegate, options: options)
    }

    // MARK: - Spawning

    /// `forkpty` + `execve`, never `posix_spawn`.
    ///
    /// **Ctrl-C working for arbitrary programs depends on this choice.**
    /// `posix_spawn` with a new session leaves the tty's foreground process
    /// group at 0 and the parent cannot set it; `^C` to a `posix_spawn`'d
    /// `cat` did nothing in measurement, while `forkpty` sets the group for
    /// any child and the signal lands (#38).
    ///
    /// **Everything the child touches is built in the PARENT.** Between
    /// `fork` and `exec` in a multithreaded process — and this one has
    /// libdispatch's workers and the Swift runtime — only async-signal-safe
    /// calls are legal. `setenv` and `strdup` allocate: if any other thread
    /// held the malloc lock at fork time it is held forever in the child,
    /// which then never reaches `exec` while the parent sees a live pid
    /// that never becomes a shell. So argv, envp and the cwd are C strings
    /// before the fork, the signal resets are written out rather than
    /// looped over an array literal, and the child calls nothing but
    /// `sigemptyset`, `sigprocmask`, `signal`, `chdir`, `execve` and
    /// `_exit`.
    func spawn(
        argv: [String], environment: [String: String], cwd: String
    ) -> Bool {
        guard let executable = argv.first else { return false }
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)

        let pathC = strdup(executable)
        let cwdC = strdup(cwd)
        let argvC = Self.makeCArray(argv)
        // **The whole environment, as given.** `execve` REPLACES the
        // environment rather than overlaying it, so `environment` must
        // already be complete — `TerminalStore.childEnvironment` seeds it
        // from this process's own. Passing a partial one hands the shell
        // nothing: `TERM=dumb`, `HOME`, `USER` and `LANG` empty, bash's
        // built-in `PATH`, and no rc file read. Not re-merged here, so a
        // key the store removed (an inherited `WAKIL_PROJECT`) stays removed.
        let merged = environment
        let envC = Self.makeCArray(merged.map { "\($0.key)=\($0.value)" })
        defer {
            free(pathC)
            free(cwdC)
            Self.freeCArray(argvC, count: argv.count)
            Self.freeCArray(envC, count: merged.count)
        }

        // Where the child's close loop stops. Computed in the PARENT,
        // because neither call below is on the async-signal-safe list and
        // the child must call nothing that is not.
        let descriptorCeiling = Self.descriptorCloseCeiling()

        var fd: Int32 = -1
        let child = forkpty(&fd, nil, nil, &size)
        if child < 0 { return false }
        if child == 0 {
            // **The mask, not only the dispositions.** libdispatch worker
            // threads block SIGINT, SIGWINCH, SIGTERM, SIGHUP and SIGCHLD;
            // the mask is inherited across exec, and this runs from an
            // actor method, so the app inherits exactly the mask a test
            // does. Resetting dispositions alone leaves ^C dead.
            var empty = sigset_t()
            sigemptyset(&empty)
            sigprocmask(SIG_SETMASK, &empty, nil)
            signal(SIGINT, SIG_DFL)
            signal(SIGWINCH, SIG_DFL)
            signal(SIGTERM, SIG_DFL)
            signal(SIGHUP, SIG_DFL)
            signal(SIGCHLD, SIG_DFL)
            signal(SIGPIPE, SIG_DFL)
            // **Every descriptor this process had open above the tty,
            // closed.** `forkpty` has already put the pty slave on 0, 1
            // and 2; everything else this child can see is the PARENT's —
            // and the parent here is Wakil, which holds MCP stdio pipes,
            // the MCP server's unix sockets, subprocess pipes, and every
            // OTHER pane's pty master. `fork` copies all of them and
            // nothing in this repo's `Pipe`/`Process` usage sets
            // `FD_CLOEXEC`, so without this loop an interactive shell
            // sits on a duplicate of each one for as long as the pane
            // lives.
            //
            // The bound is `descriptorCloseCeiling()`, which is one past
            // the highest descriptor actually open plus a margin — NOT
            // "all descriptors". See that function for the one race it
            // does not close.
            //
            // **That is what wedged the test suite, and it is a shipped
            // bug, not a test artefact.** A pipe reaches EOF only when
            // the LAST write end closes, and `MCPClient.performTeardown`
            // waits for its stdout and stderr drain threads to see that
            // EOF. Measured on this tree: a wedged run had three threads
            // parked in `read(2)` — `MCPClient.stdout`,
            // `MCPClient.stderr` and `MCPSocketServer.connection` — while
            // `lsof` showed the pipes and unix sockets under them held
            // open by live `wakil-terminal-*` shells still childed to the
            // test process. Three pipe write-ends the process was reading
            // matched leaked shells fd-for-fd. So `stop()` never
            // returned, the task awaiting it never resumed, and the whole
            // run sat at 0.02s of CPU per 10s — the leaked drain threads'
            // `poll` ticks and nothing else.
            //
            // **`MCPServer` is the milder case and is described correctly
            // here on purpose:** `MCPServer.stop()` closes the listening
            // socket and returns; it never joins a connection. A leaked
            // holder of a connection's socket therefore leaks that
            // thread, it does not hang `stop()`. Only `MCPClient`'s join
            // — and `ClaudeCodeCLIHarness`'s — turn an inherited
            // descriptor into a hang, which is why those two are the ones
            // with deadlines on them.
            //
            // `close` is async-signal-safe; the loop calls nothing else,
            // and errors are ignored because a descriptor that was never
            // open is exactly the case being covered.
            var descriptor: Int32 = 3
            while descriptor < descriptorCeiling {
                _ = close(descriptor)
                descriptor += 1
            }
            _ = chdir(cwdC)
            _ = execve(pathC, argvC, envC)
            _exit(127)
        }
        // **Not because `Foundation.Process` would otherwise inherit it.**
        // An earlier version of this comment said so and was wrong:
        // Darwin's `Process` spawns with `POSIX_SPAWN_CLOEXEC_DEFAULT`,
        // and a parent descriptor with `FD_CLOEXEC` unset was measured
        // NOT reaching a `Process` child. No Wakil subprocess was ever
        // carrying a pane's master.
        //
        // What this does defend is everything that is NOT `Process`: the
        // `fork`+`exec` two lines above (one pane's master must not reach
        // another pane's shell if the close loop's bound ever misses it —
        // see `descriptorCloseCeiling()`'s race), any future raw
        // `fork`/`exec` or `posix_spawn` without that flag, and a
        // dependency's `system`/`popen`. It costs one syscall per pane, so
        // it is kept rather than argued about.
        //
        // Checked, not discarded: a failure here leaves the master
        // silently inheritable, which is exactly the class of bug this
        // whole change is about, so it is worth a line in the log rather
        // than a shrug. It is not fatal to the spawn — the close loop is
        // the primary defence — so the shell still starts.
        if fcntl(fd, F_SETFD, FD_CLOEXEC) == -1 {
            // Captured BEFORE anything else runs: `errno` is thread-local
            // but not call-local, and interpolating it after
            // `FileHandle.standardError` has been evaluated reads whatever
            // that evaluation last set.
            let failure = errno
            FileHandle.standardError.write(
                Data("wakil: pane \(paneId): could not set FD_CLOEXEC on the pty master "
                    .appending("(errno \(failure)); the master may be inherited by a subprocess\n")
                    .utf8))
        }
        // **Non-blocking, and that is the write side's whole fix** (final
        // review, Important 1). A blocking master parks in `write(2)`
        // whenever the slave's line discipline buffer is full and nothing
        // is draining it, which for `TerminalStore.write` means parking
        // the actor and everything queued behind it. Non-blocking turns
        // that into `EAGAIN`, which `writeToPty` waits out under a
        // deadline instead.
        //
        // The read side is unaffected in the ordinary case — it already
        // `poll(2)`s before every `read(2)`, so it only ever reads when
        // there is something to read — and `startDraining` treats the
        // `EAGAIN` that a lost race can still produce as "nothing yet",
        // not as EOF. A failure here leaves the descriptor blocking:
        // survivable (it is the behaviour that shipped), so the shell
        // still starts, but worth the same line on stderr the CLOEXEC
        // failure gets.
        let flags = fcntl(fd, F_GETFL, 0)
        if flags == -1 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) == -1 {
            let failure = errno
            FileHandle.standardError.write(
                Data("wakil: pane \(paneId): could not set O_NONBLOCK on the pty master "
                    .appending("(errno \(failure)); a write to a stalled shell may block\n")
                    .utf8))
        }
        master = fd
        pid = child
        // The slave's device number, taken while the pty still exists.
        // `teardown` needs it to find the pane's other processes, and by
        // then the kernel has revoked the terminal.
        //
        // **`ptsname_r`, never `ptsname`.** `ptsname` returns a pointer
        // into a single static buffer, and `spawn` is reachable
        // concurrently from two stores — which the parallel suite does
        // routinely. A lost race hands this pane another *live* pane's
        // rdev, and `paneProcesses` then returns that pane's whole
        // session, which teardown would SIGKILL. The blast radius is
        // bounded to ptys this process opened, which is no comfort at all.
        var slaveName = [CChar](repeating: 0, count: 1_024)
        if ptsname_r(fd, &slaveName, slaveName.count) == 0 {
            var info = stat()
            if stat(slaveName, &info) == 0 { slaveDevice = UInt32(bitPattern: info.st_rdev) }
        }
        startDraining()
        return true
    }

    /// Where `spawn`'s child-side close loop stops: one past the highest
    /// descriptor this process actually has open, plus a margin.
    ///
    /// **Asking the kernel rather than closing to `RLIMIT_NOFILE`.** The
    /// first version of this looped to the soft `RLIMIT_NOFILE`, clamped
    /// at 65,536 so an enormous limit could not turn the loop into a
    /// million syscalls between `fork` and `exec`. Both halves of that
    /// were wrong on this machine. Measured here, in C, in a process with
    /// three descriptors open:
    ///
    ///     RLIMIT_NOFILE soft            1,048,576
    ///     close loop to 65,536             16.90 ms
    ///     close loop to 1,048,576         111.83 ms
    ///     close loop to highest + 1,025     0.091 ms
    ///
    /// So the clamp was load-bearing rather than theoretical — every
    /// descriptor at or above 65,536 survived into the child, which is
    /// precisely the leak the loop exists to close — and it still cost
    /// ~17 ms of `close(2)` on every pane spawn to miss them. Asking the
    /// kernel costs 0.09 ms and misses nothing below the margin: **185×
    /// cheaper and strictly more correct.**
    ///
    /// `proc_pidinfo(PROC_PIDLISTFDS)` answers the question the loop is
    /// actually asking. It is not a new dependency class here: this file
    /// already calls `proc_listpids` for `paneProcesses()`.
    ///
    /// **`descriptorCloseMargin`, and the race it does not fully close.**
    /// The snapshot is taken before `fork`, and another thread in this
    /// process may open a descriptor in between. Darwin allocates the
    /// lowest free descriptor, so such a latecomer lands just above the
    /// highest one seen — the margin covers that at a cost of a few
    /// microseconds. It is a margin, not a proof: a thread that opened
    /// thousands of descriptors inside that one `fork`-wide window could
    /// still place one past it. Nothing safe can be done about that from
    /// the child, which may call only async-signal-safe functions, and no
    /// unsafe thing is worth doing for it.
    ///
    /// Falls back to the clamped `RLIMIT_NOFILE` if the call fails, so the
    /// loop is never skipped outright.
    private static let descriptorCloseMargin: Int32 = 1_024

    private static func descriptorCloseCeiling() -> Int32 {
        if let highest = highestOpenDescriptor() {
            return highest + 1 + descriptorCloseMargin
        }
        var limits = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limits) == 0 else { return 4_096 }
        // `RLIM_INFINITY` is a C macro Swift does not import, so the clamp
        // is written as the one comparison it needs: anything above
        // 65,536 — infinity included — becomes 65,536.
        return limits.rlim_cur > 1 << 16 ? 1 << 16 : Int32(limits.rlim_cur)
    }

    /// The highest descriptor open in this process, or nil if the kernel
    /// would not say. Grown-and-retried the same way `paneProcesses()`
    /// handles a possibly-truncated `proc_listpids` buffer.
    private static func highestOpenDescriptor() -> Int32? {
        let stride = MemoryLayout<proc_fdinfo>.stride
        var slots = max(Int(proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)) / stride, 64)
        for _ in 0..<4 {
            var entries = [proc_fdinfo](repeating: proc_fdinfo(), count: slots)
            let bytes = entries.withUnsafeMutableBytes {
                proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
            }
            if bytes <= 0 { return nil }
            let count = Int(bytes) / stride
            // A full buffer may have been truncated; ask again with room.
            if count >= slots { slots *= 2; continue }
            var highest: Int32 = 2
            for index in 0..<count { highest = max(highest, entries[index].proc_fd) }
            return highest
        }
        return nil
    }

    /// A NULL-terminated C array of copies, built in the parent. The child
    /// inherits the pages and never allocates; the parent frees its own.
    private static func makeCArray(
        _ strings: [String]
    ) -> UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> {
        let array = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
            .allocate(capacity: strings.count + 1)
        for (index, string) in strings.enumerated() { array[index] = strdup(string) }
        array[strings.count] = nil
        return array
    }

    private static func freeCArray(
        _ array: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>, count: Int
    ) {
        for index in 0..<count { free(array[index]) }
        array.deallocate()
    }

    /// **`poll(2)` with a bounded timeout, not a bare blocking `read(2)`.**
    /// See `teardown()`'s doc comment for the failure this closes: a
    /// blocking read only ends at EOF, and EOF requires every process
    /// holding this pty as its controlling terminal to already be dead —
    /// which `paneProcesses()` cannot always confirm for a child forked in
    /// the instant before teardown runs. Polling instead of blocking means
    /// this loop checks `stopRequested` every `drainPollTimeoutMilliseconds`
    /// regardless of whether the far end has actually closed, so it exits
    /// on `teardown`'s signal even in the run where EOF would have arrived
    /// late or not at all.
    private func startDraining() {
        let thread = Thread { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 65_536)
            drainLoop: while true {
                var pfd = pollfd(fd: self.master, events: Int16(POLLIN), revents: 0)
                let ready = poll(&pfd, 1, Self.drainPollTimeoutMilliseconds)
                if ready < 0 {
                    // EINTR is retried; any other error means the fd itself
                    // is no longer pollable (e.g. already closed) and the
                    // thread has nothing left to do.
                    if errno == EINTR { continue drainLoop }
                    break drainLoop
                }
                if ready == 0 {
                    // Timed out with nothing to read: the one moment this
                    // loop checks whether teardown asked it to stop.
                    if self.isStopRequested() { break drainLoop }
                    continue drainLoop
                }
                if Int32(pfd.revents) & POLLIN != 0 {
                    let count = buffer.withUnsafeMutableBytes {
                        read(self.master, $0.baseAddress, 65_536)
                    }
                    // The master is non-blocking (see `spawn`), so a
                    // `poll` that said readable can still be raced to the
                    // bytes — by nothing today, but `EAGAIN` is "nothing
                    // yet", never EOF, and reading it as EOF would end the
                    // drain on a live shell. `0` still means EOF.
                    if count < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                        continue drainLoop
                    }
                    if count <= 0 { break drainLoop }
                    self.consume(buffer[0..<count])
                    continue drainLoop
                }
                // POLLHUP / POLLERR / POLLNVAL with no POLLIN alongside it:
                // the other end is gone and nothing more will ever arrive.
                break drainLoop
            }
        }
        thread.stackSize = 1 << 20
        thread.start()
        drainThread = thread
    }

    /// Everything the pty produced, fed to the engine under the lock — and
    /// the engine's replies written back **after** it is released.
    ///
    /// **Bytes are not coalesced before the parser.** Chunk size does not
    /// move the parse rate (73–77 MB/s plain, 55–60 SGR, flat from 1 KB to
    /// 1 MB) and the pty caps reads at 1,024 bytes regardless (probe §6.3).
    /// Coalescing before *drawing* is what the frame-rate poll does.
    ///
    /// **The scan happens alongside the feed, over the SAME bytes, not
    /// instead of it.** The engine gets the whole raw chunk — marks
    /// included — because it parses and discards them, and stripping them
    /// first would be a second, divergent view of the same stream. See
    /// `TerminalMarkScanner` for why Wakil scans at all rather than
    /// asking SwiftTerm.
    private func consume(_ bytes: ArraySlice<UInt8>) {
        lock.lock()
        terminal.feed(buffer: bytes)
        lock.unlock()
        flushEngineResponses()

        // Walk-defects D1: scanned on the SAME raw bytes just fed to the
        // engine, not on `events` below — a CSI "erase entire screen" is
        // not one of `TerminalMarkScanner`'s own OSC marks and never
        // becomes one of its events, the identical reason
        // `alternateScreenSwitchStartIndex` reads `bytes` rather than
        // `events` for the alternate-screen switch.
        //
        // **NOT gated on `signals.isAlternateScreen` read after
        // `terminal.feed` returns — that reads the state as of the END of
        // this whole chunk, and a quick full-screen program's entire
        // visit can land inside ONE chunk.** `vim -c q` switches in,
        // clears, and switches back out again in well under 1,024 bytes,
        // so by the time `terminal.feed` returns, `signals
        // .isAlternateScreen` has already gone back to `false` — a check
        // against it here would see "not alternate" for a chunk whose
        // clear happened entirely INSIDE the alternate screen and wipe the
        // history over it. `screenClearScan` tracks the switch
        // POSITIONALLY instead, in the same wire order the bytes arrived
        // in, which is the only way to ask "was the alternate screen
        // active at the MOMENT this particular clear happened" rather
        // than "is it active now".
        let window = pendingScreenClearScan + Array(bytes)
        let scan = Self.screenClearScan(window, alternateAtStart: pendingScreenClearAlternate)
        if scan.cleared {
            lock.lock()
            screenCleared = true
            lock.unlock()
        }
        pendingScreenClearAlternate = scan.alternateAtEnd
        pendingScreenClearScan = Array(window.suffix(Self.screenClearScanCarryover))

        let events = scanner.consume(bytes)
        guard !events.isEmpty else { return }
        lock.lock()
        for event in events {
            switch event {
            case .output(let bytes):
                // Only while a block is open: the prompt, and anything
                // else between one `D` and the next `C`, belongs to no
                // command and is drawn by the grid rather than stored.
                //
                // **And only up to the moment this block's OWN bytes
                // REPAINT rather than PRINT** (walk-defects D4, widened
                // to "the cursor moved up" — see `OpenBlock.heldTheGrid`'s
                // own doc comment for the two ways in and why the rule
                // was widened). `signals.isAlternateScreen` — the
                // chunk-wide level SwiftTerm sets — is deliberately NOT
                // what gates this (see `alternateScreenSwitchStartIndex`'s
                // doc comment): a chunk-wide flag credits the wrong block
                // when two commands' bytes land in one `read(2)` (`ls;
                // vim -c q` pasted together). Scanning THIS event's own
                // `bytes` — already scoped to whichever block is open
                // right now, because `commandStart`/`commandEnd` reset
                // `openBlock` in wire order in this same loop — keeps
                // that scoping.
                if openBlock != nil, !openBlock!.heldTheGrid {
                    // Way in #1 — the alternate screen. A small carry-
                    // over of the tail already APPENDED covers a switch
                    // split across two `read(2)`s; safe to re-derive from
                    // committed output every time because this is a
                    // presence check, not a running count.
                    let altScreenCarryover = openBlock!.output.suffix(Self.alternateScreenSwitchMaxLength - 1)
                    let altScreenWindow = Array(altScreenCarryover) + bytes
                    let altScreenCut = Self.alternateScreenSwitchStartIndex(in: altScreenWindow)
                        .map { max(0, $0 - altScreenCarryover.count) }

                    // Way in #2 — the cursor moved up. `upwardCursorMoveScan`
                    // accumulates `cursorRow` as it walks, so an escape
                    // sequence still open when THIS event's bytes run out
                    // is carried forward in `pendingCursorScan` purely so
                    // the NEXT event can pick the row count back up where
                    // this one left it — it is a bookkeeping aid for the
                    // scan alone, never a gate on what reaches `output`
                    // below, which appends every byte exactly once
                    // regardless of whether this scan could make sense of
                    // it yet (matching way in #1, and the reason: way in
                    // #1's own look-back trick depends on unresolved bytes
                    // already sitting in `output` from an earlier round,
                    // and withholding them here would blind it).
                    let pendingCursorScan = openBlock!.pendingCursorScan
                    let cursorWindow = pendingCursorScan + Array(bytes)
                    let cursorScan = Self.upwardCursorMoveScan(
                        cursorWindow, cursorRow: &openBlock!.cursorRow)
                    let upwardCut = cursorScan.trigger.map { max(0, $0 - pendingCursorScan.count) }

                    if let cut = [altScreenCut, upwardCut].compactMap({ $0 }).min() {
                        // Whichever fired first wins; the loser's own
                        // pending state stops mattering because nothing
                        // is ever captured for this block again. Only
                        // THIS event's own bytes are appended — anything
                        // in `pendingCursorScan` was already appended, in
                        // full, by whichever earlier round first saw it
                        // (see the `else` branch below).
                        openBlock!.output.append(contentsOf: bytes.prefix(cut))
                        openBlock!.heldTheGrid = true
                        openBlock!.pendingCursorScan = []
                    } else {
                        // Neither fired: this event's bytes are real
                        // output and belong in the block, in full — the
                        // same unconditional append way in #1 already
                        // made before this widening. Whatever
                        // `upwardCursorMoveScan` could not yet resolve is
                        // remembered so the NEXT event's own scan starts
                        // from the right `cursorRow`, not re-counted from
                        // scratch — it is not re-appended here because it
                        // is either already in `output` (unresolved from
                        // a PRIOR round) or about to be (unresolved from
                        // THIS round's `bytes`, appended on the line
                        // above either way).
                        openBlock!.output.append(contentsOf: bytes)
                        let unresolved = cursorWindow.suffix(from: cursorScan.unresolvedFrom)
                        // Bounded the same way `TerminalMarkScanner.pending`
                        // is: past this, give up trying to make sense of
                        // it as an escape sequence rather than hold it
                        // forever — the bytes themselves are already in
                        // `output` either way, so this only stops
                        // `cursorRow` from ever advancing again on
                        // whatever it turns out to be.
                        openBlock!.pendingCursorScan =
                            unresolved.count > Self.upwardCursorMoveScanCap ? [] : Array(unresolved)
                    }
                    // Bounds the buffer a still-running command accumulates
                    // into — see `TerminalBlock.openBufferByteCap` and
                    // `trimmedOpenBuffer` for the bound and why it is sized
                    // the way it is.
                    openBlock!.output = Self.trimmedOpenBuffer(openBlock!.output)
                }
            case .promptStart:
                appendMark(event)
                // The engine's own cursor row at the moment the mark
                // fired — under the same `lock` `terminal.feed` above
                // already took, so this read is safe. Latched until the
                // NEXT prompt, not cleared at `commandStart`/`commandEnd`:
                // a running command's own output keeps drawing below this
                // row, which is exactly what "current prompt onward"
                // needs while the command is still running.
                promptRow = terminal.buffer.y
                atPrompt = false
                lineEditSupported = false
            case .hostDirectory(let path):
                cwd = path
                appendMark(event)
            case .commandStart(let command):
                appendMark(event)
                atPrompt = false
                blockCounter += 1
                openBlock = OpenBlock(
                    id: "\(blockRunId)-\(blockCounter)", command: command, startedAt: Date())
            case .commandEnd(let exitCode):
                appendMark(event)
                // **A `D` with no open block is dropped.** The generated
                // rc gates its own first-`precmd` `D` behind
                // `__wakil_in_block`, but that guarantee cannot live only
                // in a shell script Wakil wrote: a pane that `ssh`es to a
                // host running its own shell integration, one running
                // `tmux`, or simply a program that echoes `ESC]133;D`
                // produces orphan `D`s, and the scanner forwards every one
                // of them unconditionally. A block invented here would
                // carry someone else's exit code under no command at all.
                guard let open = openBlock else { continue }
                openBlock = nil
                let outputLines = Self.outputLines(open.output)
                completedBlocks.append(TerminalBlock.capped(
                    id: open.id, command: open.command, origin: .operatorTyped,
                    exitCode: exitCode,
                    durationMs: Int(Date().timeIntervalSince(open.startedAt) * 1_000),
                    output: outputLines,
                    heldTheGrid: open.heldTheGrid,
                    startedAt: open.startedAt,
                    outputRuns: Self.styledOutputRuns(rawOutput: open.output, plainLines: outputLines)))
            case .promptEnd:
                appendMark(event)
                atPrompt = true
            case .editSupported:
                // Not a mark: `marks` records the shell's structure, and
                // this says only which rc drew the prompt.
                lineEditSupported = true
            default:
                appendMark(event)
            }
        }
        lock.unlock()
    }

    /// The byte offset of the CSI sequence that switches into the
    /// alternate screen, if `bytes` contains one — mode 47, 1047 or 1049,
    /// the three DEC private modes a full-screen takeover uses (`vim`,
    /// `less` and `tmux` all use 1049). `nil` if none is present.
    ///
    /// **Called from `consume`'s `.output` case with a small live window,
    /// not once at the seal over a whole block's accumulated output**
    /// (walk-defects D4). It used to be the latter, answering only a
    /// `Bool`, back when a block's `output` was captured in full — mangled
    /// alternate-screen rows included — and `heldTheGrid` was decided
    /// retroactively by scanning what had already been kept. Now that
    /// `.output` events stop appending the moment the switch is seen, that
    /// retroactive scan would find nothing: the bytes it looked for are
    /// exactly what is no longer stored. The offset this now returns is
    /// what lets the caller keep the legitimate bytes before the switch
    /// and drop the switch onward, in the same event.
    private static func alternateScreenSwitchStartIndex(in bytes: [UInt8]) -> Int? {
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 0x1B, index + 1 < bytes.count, bytes[index + 1] == 0x5B else {
                index += 1
                continue
            }
            var cursor = index + 2
            guard cursor < bytes.count, bytes[cursor] == 0x3F else {
                // Not a DEC private-mode CSI ("ESC [ ?…"); not ours.
                index += 1
                continue
            }
            cursor += 1
            var params: [Int] = []
            var current = 0
            var sawDigit = false
            while cursor < bytes.count {
                let byte = bytes[cursor]
                if byte >= 0x30, byte <= 0x39 {  // '0'...'9'
                    current = current * 10 + Int(byte - 0x30)
                    sawDigit = true
                    cursor += 1
                } else if byte == 0x3B {  // ';' — another param follows
                    if sawDigit { params.append(current) }
                    current = 0
                    sawDigit = false
                    cursor += 1
                } else {
                    break
                }
            }
            if sawDigit { params.append(current) }
            if cursor < bytes.count, bytes[cursor] == 0x68,  // 'h' — DECSET (turn ON)
               params.contains(where: { [47, 1047, 1049].contains($0) }) {
                return index
            }
            index += 1
        }
        return nil
    }

    /// The longest byte length `alternateScreenSwitchStartIndex` needs to
    /// see whole in order to recognise a switch — `"\u{1B}[?1049h"`, 8
    /// bytes, the longest of the three DEC private modes it looks for.
    /// Used only to size the carry-over window below.
    private static let alternateScreenSwitchMaxLength = 8

    /// The second way in to `OpenBlock.heldTheGrid` (walk-defects D4,
    /// widened) — see that field's own doc comment for what this rule
    /// is and why the alternate screen alone was too narrow a key for
    /// it. This is the discriminator: a program that moves the cursor
    /// UP is repainting a row it already left behind, by definition; a
    /// program that only rewrites its CURRENT line — `\r`, what
    /// `npm install`, `curl` and every progress bar do — is not, and
    /// must not trigger this.
    ///
    /// **Recognised as upward movement:**
    /// - `CSI A` (CUU, cursor up) and `CSI n F` (CPL, cursor to previous
    ///   line) — unconditionally: both move up by definition, no matter
    ///   where the cursor already was.
    /// - `ESC M` (RI, reverse index) — unconditionally, the same as
    ///   `CSI A`: it is "move up one line, scrolling if already at the
    ///   top margin", never anything else.
    /// - `CSI row;colH` (CUP) and `CSI row;colf` (HVP) — only when the
    ///   TARGET row is one this scan has already passed (`cursorRow`,
    ///   tracked by this same function from LF, `CSI n B`/`CSI n E` and
    ///   earlier `H`/`f` moves). Addressing the row the cursor is
    ///   ALREADY on is deliberately not a trigger — that is `\r`'s own
    ///   case in absolute-position form, the exact thing that must
    ///   survive.
    ///
    /// **Deliberately left out:**
    /// - `CSI n S` / `CSI n T` (SU/SD, scroll the page up/down). Both
    ///   move the PAGE's content, not the cursor's row, and a program
    ///   using a scroll region to bring in a genuinely new line reads
    ///   closer to `\r`-driven progress than to a repaint — modelling
    ///   their effect on this scan's own `cursorRow` correctly would mean
    ///   tracking scroll-region margins too, which starts to duplicate
    ///   the terminal engine this scan deliberately does not consult
    ///   (see `OpenBlock.cursorRow`'s own doc comment). No walk defect
    ///   or test in hand needs them; left for a future widening if one
    ///   ever does.
    /// - `CSI n G` / backspace / plain column motion. Same row, no
    ///   vertical component — the same reason `\r` itself is excluded.
    /// - `ESC 7` / `ESC 8` (DECSC/DECRC, save/restore cursor). A restore
    ///   can move the cursor anywhere, including up, but this scan does
    ///   not track a saved position to compare against — a program that
    ///   saves, prints elsewhere, then restores and OVERWRITES is only
    ///   caught here if the restore is followed by (or itself is) one of
    ///   the sequences above addressing an already-passed row. Not
    ///   known to be exercised by anything in the walk; left out rather
    ///   than modelled speculatively.
    ///
    /// **Returns** the byte offset of the first upward move found, if
    /// any — everything in `bytes` before it has already updated
    /// `cursorRow` — and `unresolvedFrom`, the offset where an escape
    /// sequence was still open when `bytes` ran out (equal to
    /// `bytes.count` when nothing was left hanging). The caller carries
    /// `bytes[unresolvedFrom...]` into the next call's OWN window so
    /// `cursorRow` picks the count back up correctly — a bookkeeping
    /// carry, not a claim that those bytes are unresolved for `output`
    /// too; see `OpenBlock.pendingCursorScan`'s own doc comment for why
    /// this scan cannot use the alternate-screen switch's look-back-
    /// window trick instead.
    private static func upwardCursorMoveScan(
        _ bytes: [UInt8], cursorRow: inout Int
    ) -> (trigger: Int?, unresolvedFrom: Int) {
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x0A {  // LF: the one plain byte that advances a row.
                cursorRow += 1
                index += 1
                continue
            }
            guard byte == 0x1B else {
                index += 1  // Not an escape — including `\r` — no row effect.
                continue
            }
            guard index + 1 < bytes.count else {
                return (nil, index)  // A lone trailing ESC: could be anything.
            }
            if bytes[index + 1] == 0x4D {  // ESC M — reverse index: always up.
                return (index, index)
            }
            guard bytes[index + 1] == 0x5B else {
                // Some other two-byte escape (`ESC c`, `ESC =`, …, none of
                // them cursor movement): skip just the ESC, the same
                // tolerance `stripEscapeSequences` gives these.
                index += 1
                continue
            }
            // CSI: "ESC [", an optional "?" (DEC private mode — never one
            // of the sequences this scan recognises; skipped, not tracked,
            // the identical scope `alternateScreenSwitchStartIndex` claims
            // for those modes), then `;`-separated digits, then a final
            // byte in 0x40...0x7E.
            var cursor = index + 2
            var isPrivate = false
            if cursor < bytes.count, bytes[cursor] == 0x3F {
                isPrivate = true
                cursor += 1
            }
            var params: [Int] = []
            var current = 0
            while cursor < bytes.count {
                let b = bytes[cursor]
                if b >= 0x30, b <= 0x39 {  // '0'...'9'
                    current = current * 10 + Int(b - 0x30)
                    cursor += 1
                } else if b == 0x3B {  // ';' — another param follows
                    params.append(current)
                    current = 0
                    cursor += 1
                } else {
                    break
                }
            }
            guard cursor < bytes.count else {
                return (nil, index)  // Split across this event and the next.
            }
            guard (0x40...0x7E).contains(bytes[cursor]) else {
                // Not a legal CSI final byte where one was expected — not
                // one of ours; resume right after "ESC [" rather than
                // trying to guess where a malformed sequence ends.
                index += 2
                continue
            }
            params.append(current)
            let final = bytes[cursor]
            if !isPrivate {
                switch final {
                case 0x41, 0x46:  // 'A' CUU, 'F' CPL — always up.
                    return (index, index)
                case 0x42, 0x45:  // 'B' CUD, 'E' CNL — down; default n = 1.
                    cursorRow += params.first.map { $0 == 0 ? 1 : $0 } ?? 1
                case 0x48, 0x66:  // 'H' CUP, 'f' HVP — absolute; default row = 1.
                    let target = (params.first.map { $0 == 0 ? 1 : $0 } ?? 1) - 1
                    if target < cursorRow {
                        return (index, index)
                    }
                    cursorRow = target
                default:
                    break
                }
            }
            index = cursor + 1
        }
        return (nil, bytes.count)
    }

    /// How long `upwardCursorMoveScan` holds an unresolved escape sequence
    /// in `OpenBlock.pendingCursorScan` before giving up and preserving it
    /// as literal bytes instead. 64 is generous for any realistic
    /// `row;col` pair (`"\u{1B}[9999;9999H"` is 13 bytes) — this is a
    /// backstop against a pathological stream, not a bound anything
    /// legitimate is expected to brush against, the same role
    /// `TerminalMarkScanner.pendingCap` plays for a mark split across
    /// reads.
    private static let upwardCursorMoveScanCap = 64

    /// The literal CSI ED (Erase in Display) sequence for "entire
    /// screen", `ESC [ 2 J` — walk-defects D1's own trigger for wiping the
    /// block history.
    ///
    /// **Confirmed on this machine, not assumed.** `clear | cat -v` prints
    /// `\e[3J\e[H\e[2J`; a bare `tput clear` (the terminfo `clear`
    /// capability alone, with none of the `clear` COMMAND's own additions)
    /// prints only `\e[H\e[2J`. `2J` is the part both share. zsh's `^L`
    /// — the `clear-screen` ZLE widget — calls that same terminfo
    /// capability directly rather than shelling out to `clear`, so it
    /// emits the `tput` form too: `\e[H\e[2J`, no `\e[3J`.
    ///
    /// **Keyed on `2J`, not `3J`, because of that last fact.** `3J` is
    /// ncurses' own extra "erase scrollback" (the xterm/E3 extension) that
    /// the `clear` COMMAND prepends and the ZLE widget does not — keying
    /// on it would silently stop catching `^L`, exactly the gap
    /// walk-defects D1 itself names ("the command name misses `^L`").
    /// `2J` is common to both, which is the whole reason this scan exists
    /// rather than matching on the completed command's own name.
    private static let screenClearSequence: [UInt8] = [0x1B, 0x5B, 0x32, 0x4A]  // ESC [ 2 J

    /// How much of a window `screenClearScan` carries forward as the next
    /// chunk's own leading bytes — long enough to hold either needle it
    /// looks for split across a `read(2)` boundary: `screenClearSequence`
    /// itself (4 bytes) or an alternate-screen switch (`alternateScreenSwitchMaxLength`,
    /// 8 bytes, the longer of the two).
    private static let screenClearScanCarryover = max(
        screenClearSequence.count, alternateScreenSwitchMaxLength) - 1

    /// Walks `window` left to right tracking the alternate-screen switch
    /// in BOTH directions — `h` (DECSET, entering) and `l` (DECRST,
    /// leaving) for modes 47/1047/1049, the same three
    /// `alternateScreenSwitchStartIndex` recognises for the switch-IN
    /// alone — starting from `alternateAtStart`, and reports whether
    /// `screenClearSequence` occurred anywhere in `window` while that
    /// TRACKED state said "not alternate" at the exact point it occurred,
    /// plus the tracked state as of the end of `window` for the next call
    /// to start from.
    ///
    /// **Positional, not `signals.isAlternateScreen` read after the whole
    /// chunk is fed — that is the one bug this shape exists to avoid.** A
    /// quick full-screen program's entire visit to the alternate screen —
    /// switch in, clear, switch out — routinely lands in ONE `read(2)`:
    /// `vim -c q` does exactly this in well under 1,024 bytes. Checking
    /// `signals.isAlternateScreen` only after `terminal.feed` returns
    /// answers "is it alternate NOW", which for that whole chunk is
    /// `false` — the switch-out already happened — and wiping the block
    /// history on that answer would take the history down over a clear
    /// that happened entirely INSIDE a full-screen program's own startup.
    /// This is walk-defects D4's own trap, applied to D1, and the fix is
    /// the same shape D4's `heldTheGrid` already uses for the switch-IN
    /// alone (`alternateScreenSwitchStartIndex`): track the transition
    /// IN WIRE ORDER instead of asking for a single chunk-wide answer.
    /// This is why `TerminalSession` keeps its own `pendingScreenClearAlternate`
    /// rather than reading `signals.isAlternateScreen` here at all — that
    /// field is deliberately the chunk-FINAL level (`isAlternateScreenActive`'s
    /// own contract, read by `TerminalStore` between chunks), while this
    /// needs the state at every point WITHIN one.
    private static func screenClearScan(
        _ window: [UInt8], alternateAtStart: Bool
    ) -> (cleared: Bool, alternateAtEnd: Bool) {
        var alternate = alternateAtStart
        var cleared = false
        var index = 0
        while index < window.count {
            if index + screenClearSequence.count <= window.count,
                Array(window[index..<(index + screenClearSequence.count)]) == screenClearSequence
            {
                if !alternate { cleared = true }
                index += screenClearSequence.count
                continue
            }
            guard window[index] == 0x1B, index + 2 < window.count, window[index + 1] == 0x5B,
                window[index + 2] == 0x3F
            else {
                index += 1
                continue
            }
            var cursor = index + 3
            var params: [Int] = []
            var current = 0
            var sawDigit = false
            while cursor < window.count {
                let byte = window[cursor]
                if byte >= 0x30, byte <= 0x39 {  // '0'...'9'
                    current = current * 10 + Int(byte - 0x30)
                    sawDigit = true
                    cursor += 1
                } else if byte == 0x3B {  // ';' — another param follows
                    if sawDigit { params.append(current) }
                    current = 0
                    sawDigit = false
                    cursor += 1
                } else {
                    break
                }
            }
            if sawDigit { params.append(current) }
            let isAlternateScreenMode = params.contains { [47, 1047, 1049].contains($0) }
            if isAlternateScreenMode, cursor < window.count, window[cursor] == 0x68 {  // 'h'
                alternate = true
                index = cursor + 1
            } else if isAlternateScreenMode, cursor < window.count, window[cursor] == 0x6C {  // 'l'
                alternate = false
                index = cursor + 1
            } else {
                index += 1
            }
        }
        return (cleared, alternate)
    }

    /// `buffer`, trimmed from the FRONT to at most
    /// `TerminalBlock.openBufferByteCap` bytes — the running counterpart
    /// to `TerminalBlock.capped`'s own line trim, applied on every
    /// `.output` event rather than once at the `D` mark, which is the
    /// whole fix for the open block's unbounded growth (see
    /// `OpenBlock.output`'s own doc comment).
    ///
    /// **The tail is kept, not the head** — `TerminalBlock.capped`'s own
    /// rule, for the same reason: whatever an operator, or an agent
    /// reading `read_pane`, is asking about is the most RECENT output,
    /// not the oldest.
    ///
    /// **Cuts only right after a line terminator (`\n` or `\r`) — never
    /// mid-line, and never mid-UTF-8-sequence.** Neither byte is ever a
    /// UTF-8 continuation byte (those are always `0x80`–`0xBF`), so a cut
    /// placed immediately after one cannot land inside a multi-byte
    /// character — the safety here comes from WHERE the cut falls, not
    /// from decoding anything. `outputLines` below treats both bytes as
    /// line terminators the same way, so a cut on either is a cut this
    /// buffer was always going to make at the seal too.
    ///
    /// **May leave `buffer` over the cap** in the one case where no such
    /// terminator exists anywhere at or after the point that would bring
    /// it under: an unbroken run of bytes with no line break in it at
    /// all. That is the same trade `stripEscapeSequences` makes for an
    /// escape sequence that never terminates — preserving a boundary
    /// correctly is worth more than the bound in a case this
    /// pathological, and no realistic program's output is shaped that way
    /// for anywhere near a megabyte.
    private static func trimmedOpenBuffer(_ buffer: [UInt8]) -> [UInt8] {
        let cap = TerminalBlock.openBufferByteCap
        guard buffer.count > cap else { return buffer }
        var cut = buffer.count - cap
        while cut < buffer.count, buffer[cut] != 0x0A, buffer[cut] != 0x0D {
            cut += 1
        }
        guard cut < buffer.count else { return buffer }
        return Array(buffer[(cut + 1)...])
    }

    /// A block's raw output bytes as lines.
    ///
    /// `\r\n` and a bare `\r` both end a line on a pty, and a trailing
    /// newline is a terminator rather than an empty last line — so it is
    /// dropped, while a blank line the command actually printed in the
    /// middle of its output is kept.
    private static func outputLines(_ bytes: [UInt8]) -> [String] {
        var lines = String(decoding: stripEscapeSequences(bytes), as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        if lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    /// A sealed block's colour, or `nil` — the one call site that decides
    /// whether `TerminalBlock.outputRuns` is worth keeping at all.
    ///
    /// **Two independent safety nets, both cheap, neither trusted to the
    /// other.** `terminalStyledOutputLines` is documented to produce the
    /// same line count as `outputLines` for the same bytes, but this
    /// checks it rather than assuming it — a mismatch (a future bug in
    /// either parser, or an input neither anticipated) falls back to
    /// `nil` rather than to a runs array a caller could zip against the
    /// wrong line. And a block that used no colour at all — checked here,
    /// once, rather than left to every future reader — stores `nil`
    /// instead of an array of single plain runs that would just be
    /// `output` again in a heavier shape; see `TerminalBlock.outputRuns`'s
    /// own doc comment for why that matters at this cap.
    private static func styledOutputRuns(
        rawOutput: [UInt8], plainLines: [String]
    ) -> [[TerminalStyleRun]]? {
        let runs = terminalStyledOutputLines(rawOutput)
        guard runs.count == plainLines.count else { return nil }
        guard runs.contains(where: { line in line.contains { $0.style != .plain } }) else {
            return nil
        }
        return runs
    }

    /// `bytes` with every CSI sequence (cursor movement, SGR colour, the
    /// alternate-screen switch itself) and every OSC that is not one of
    /// Wakil's own marks — those are already gone by the time `output`
    /// events reach here, removed by `TerminalMarkScanner` — stripped out.
    ///
    /// **At the capture layer, not the view.** `TerminalBlock.output` is
    /// declared `[String]`: plain text, not attributed text carrying
    /// colour. Stripping here is what makes a block's stored value match
    /// its own declared type, and it runs only on `open.output` — the copy
    /// captured for the block — never on what `terminal.feed` receives, so
    /// the live grid the engine draws is built from the untouched bytes.
    ///
    /// **A sequence that never terminates before the buffer ends is
    /// PRESERVED AS TEXT, not consumed** (final review; the ledger's own
    /// T9-a, ruled fix-before-merge). Both branches below used to run
    /// their cursor to `bytes.count` and set `index` past it, so a
    /// malformed or truncated sequence anywhere near the end ate every
    /// real byte after it into nothing — silently, out of the text an LLM
    /// then reads as the command's output. Preserving is the rule
    /// `TerminalMarkScanner` already follows when its own pending buffer
    /// overflows the cap: bytes that turned out not to be a sequence go
    /// back to being what they always were. Over-recognition eating real
    /// text is the worse of this stripper's two failure directions,
    /// because nothing downstream can tell that it happened.
    ///
    /// Unlike the scanner there is nothing to hold them FOR: this runs
    /// once, over one sealed block's whole captured output, so there is no
    /// next chunk in which the terminator might arrive.
    private static func stripEscapeSequences(_ bytes: [UInt8]) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 0x1B else {
                result.append(bytes[index])
                index += 1
                continue
            }
            guard index + 1 < bytes.count else {
                index += 1  // A lone trailing ESC; nothing legitimate follows it.
                continue
            }
            switch bytes[index + 1] {
            case 0x5B:  // CSI: "ESC [" … up to a final byte in 0x40...0x7E.
                var cursor = index + 2
                while cursor < bytes.count, !(0x40...0x7E).contains(bytes[cursor]) {
                    cursor += 1
                }
                guard cursor < bytes.count else {
                    // No final byte before the buffer ends. **Preserved as
                    // text, not eaten** — see this method's doc comment.
                    result.append(contentsOf: bytes[index...])
                    return result
                }
                index = cursor + 1
            case 0x5D:  // OSC: "ESC ]" … up to BEL or "ESC \".
                var cursor = index + 2
                var terminated = false
                while cursor < bytes.count {
                    if bytes[cursor] == 0x07 { cursor += 1; terminated = true; break }
                    if bytes[cursor] == 0x1B, cursor + 1 < bytes.count, bytes[cursor + 1] == 0x5C {
                        cursor += 2
                        terminated = true
                        break
                    }
                    cursor += 1
                }
                guard terminated else {
                    result.append(contentsOf: bytes[index...])
                    return result
                }
                index = cursor
            default:
                // A two-byte escape (`ESC c`, `ESC =`, `ESC >`, …): drop
                // only the ESC and let its argument byte read as itself,
                // rather than guessing at every terminal's private
                // repertoire of one-off escapes.
                index += 1
            }
        }
        return result
    }

    /// Every block sealed since the last call, handed over and cleared.
    /// Called from `TerminalStore`'s frame-rate poll.
    func takeCompletedBlocks() -> [TerminalBlock] {
        lock.lock()
        defer { lock.unlock() }
        let taken = completedBlocks
        completedBlocks.removeAll(keepingCapacity: false)
        return taken
    }

    /// Whether the raw stream has shown the screen-clear sequence
    /// (walk-defects D1) since the last call, handed over and cleared —
    /// the same take-and-clear shape as `takeCompletedBlocks`. Called from
    /// `TerminalStore`'s frame-rate poll, ORDERED AFTER that call drains
    /// `takeCompletedBlocks` into `PaneStore`: a `clear` earns a completed
    /// block like any other command (its `C`/`D` marks are ordinary shell
    /// integration), and the operator's own decision (walk-defects.md) is
    /// that block disappears too, along with everything above it — which
    /// only happens if it is recorded first and then wiped, not the other
    /// way round.
    func takeScreenCleared() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let taken = screenCleared
        screenCleared = false
        return taken
    }

    /// Seals whatever block is still open, with a **null exit code**, and
    /// returns it — or `nil` when nothing was running.
    ///
    /// **Called by teardown, so a `tail -f` killed by `pane_close` still
    /// leaves a block and a journal line.** The shell is SIGKILLed, so its
    /// `EXIT` trap never runs and no `D` is ever emitted for this command;
    /// `nil` here means *the shell was killed before it reported*, which
    /// is exactly what `TerminalBlock.exitCode`'s own doc comment says a
    /// `nil` means, and never *it succeeded*.
    func sealOpenBlockAtTeardown() -> TerminalBlock? {
        lock.lock()
        defer { lock.unlock() }
        guard let open = openBlock else { return nil }
        openBlock = nil
        let outputLines = Self.outputLines(open.output)
        return TerminalBlock.capped(
            id: open.id, command: open.command, origin: .operatorTyped, exitCode: nil,
            durationMs: Int(Date().timeIntervalSince(open.startedAt) * 1_000),
            output: outputLines,
            heldTheGrid: open.heldTheGrid, startedAt: open.startedAt,
            outputRuns: Self.styledOutputRuns(rawOutput: open.output, plainLines: outputLines))
    }

    /// Whether a full-screen program currently owns the screen — what
    /// decides which surface `TerminalSnapshot.screen` names.
    var isAlternateScreenActive: Bool { signals.isAlternateScreen }

    /// TEST-ONLY: every non-`.output` event this pane's shell has emitted.
    func marksForTesting() -> [TerminalStreamEvent] {
        lock.lock()
        defer { lock.unlock() }
        return marks
    }

    /// TEST-ONLY: the raw bytes of the block currently open, or `nil` if
    /// none is. What `trimmedOpenBuffer` bounds — read directly, so a
    /// test can check the OPEN buffer's own bound without waiting for a
    /// `D` mark to seal it and apply `TerminalBlock.outputLineCap` on top.
    func openBlockOutputForTesting() -> [UInt8]? {
        lock.lock()
        defer { lock.unlock() }
        return openBlock?.output
    }

    /// TEST-ONLY: drives `consume` directly with a synthetic chunk, on a
    /// session that need not even be spawned — `consume` touches only the
    /// engine, the scanner, and this session's own locked state, none of
    /// which need a real pty.
    ///
    /// **What this proves that a real shell cannot.** A live shell's own
    /// `read(2)` calls happen to split however the kernel and its
    /// scheduling landed on that run; a test built on them can only show
    /// that a particular split was survived, never that TWO commands'
    /// marks and a screen switch landing in the SAME chunk are attributed
    /// correctly, because there is no way to force that split from the
    /// outside. Calling `consume` once, with a chunk built by hand to
    /// contain exactly that, tests the attribution itself.
    func feedForTesting(_ bytes: [UInt8]) {
        consume(bytes[...])
    }

    /// The DA/DSR replies the parse produced, written once nothing holds
    /// the engine lock. See `TerminalSessionSignals` for what writing them
    /// in place would deadlock.
    private func flushEngineResponses() {
        let responses = signals.takeResponses()
        if !responses.isEmpty { writeToPty(responses) }
    }

    /// Writes `bytes` to the pty master, **bounded**, and records what it
    /// could not deliver.
    ///
    /// **The failure this closes** (final review, Important 1). This used
    /// to be a bare `write(2)` loop, and `TerminalStore.write` calls it on
    /// the actor's own executor. A pty master blocks in `write(2)` once
    /// the slave's line discipline buffer is full and nothing is reading
    /// it — `sleep 100` in the pane, then a proposal longer than ~1 KB
    /// accepted in one call (`WindowModel.acceptProposal` writes the whole
    /// command at once, and nothing caps a proposal's length). The actor
    /// then wedged, taking the 60 Hz publisher, every other pane's
    /// `close`, the org switch and app quit with it.
    ///
    /// Task 7 fixed exactly this shape on the READ side — `poll(2)` with a
    /// short timeout plus a `stopRequested` check, instead of a blocking
    /// `read(2)`. This is the symmetric fix, deferred by the ledger to a
    /// task that did not exist: the master is non-blocking (see `spawn`),
    /// so a full buffer answers `EAGAIN` instead of parking, and this
    /// `poll(2)`s for `POLLOUT` between attempts, gives up at
    /// `writeDeadlineSeconds`, and gives up at once when teardown has
    /// asked it to stop.
    ///
    /// **The give-up is recorded, not swallowed** — the same trade
    /// `TerminalStore.abandonedResources` makes for teardown. What is lost
    /// is the tail of one write into a pane whose shell has stopped
    /// reading; what is bought is that nothing else in the process stops.
    /// Returns the number of bytes it could not write, `0` on success.
    @discardableResult
    func writeToPty(_ bytes: [UInt8]) -> Int {
        guard master >= 0, !bytes.isEmpty else { return 0 }
        var offset = 0
        let deadline = Date().addingTimeInterval(Self.writeDeadlineSeconds)
        bytes.withUnsafeBytes { raw in
            writeLoop: while offset < raw.count {
                let written = write(master, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written > 0 {
                    offset += written
                    continue writeLoop
                }
                let failure = errno
                if written < 0, failure == EINTR { continue writeLoop }
                guard written < 0, failure == EAGAIN || failure == EWOULDBLOCK else {
                    // A real error (EIO on a shell that has already died,
                    // EBADF on a descriptor teardown closed): there is
                    // nothing to wait for.
                    break writeLoop
                }
                // The buffer is full. Wait for room, but never past the
                // deadline and never through a teardown.
                if isStopRequested() || Date() >= deadline { break writeLoop }
                var pfd = pollfd(fd: master, events: Int16(POLLOUT), revents: 0)
                let ready = poll(&pfd, 1, Self.writePollTimeoutMilliseconds)
                if ready < 0, errno != EINTR { break writeLoop }
            }
        }
        let unwritten = bytes.count - offset
        if unwritten > 0 {
            writeLock.lock()
            abandonedWrites.append(AbandonedWrite(paneId: paneId, unwritten: unwritten))
            writeLock.unlock()
        }
        return unwritten
    }

    /// How long `writeToPty` waits for a pty whose reader has stopped
    /// reading before abandoning the rest of the write.
    ///
    /// The same two seconds teardown gives a child to exit, and for the
    /// same reason: it is long enough that no healthy shell ever reaches
    /// it, and short enough that a wedged one cannot hold the actor.
    static let writeDeadlineSeconds: Double = 2
    /// One `poll(2)` tick while waiting for room — short enough that a
    /// teardown arriving mid-write is noticed promptly, the mirror of
    /// `drainPollTimeoutMilliseconds` on the read side.
    private static let writePollTimeoutMilliseconds: Int32 = 50

    /// Guards `abandonedWrites` alone. Not `lock`: this is appended to
    /// from the drain thread (`flushEngineResponses`) as well as from the
    /// actor, and it has nothing to do with the terminal state `lock`
    /// guards.
    private let writeLock = NSLock()
    private var abandonedWrites: [AbandonedWrite] = []

    /// Every abandoned write since the last call, handed over and cleared
    /// — drained by `TerminalStore` into its own record, beside the ptys
    /// teardown had to give up on.
    func takeAbandonedWrites() -> [AbandonedWrite] {
        writeLock.lock()
        defer { writeLock.unlock() }
        let taken = abandonedWrites
        abandonedWrites.removeAll(keepingCapacity: false)
        return taken
    }

    func resize(cols newCols: Int, rows newRows: Int) {
        guard master >= 0, newCols > 0, newRows > 0 else { return }
        var size = winsize(
            ws_row: UInt16(newRows), ws_col: UInt16(newCols), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &size)
        lock.lock()
        cols = newCols
        rows = newRows
        terminal.resize(cols: newCols, rows: newRows)
        lock.unlock()
        flushEngineResponses()
        // The shell redraws its prompt for the new width when it is told.
        if pid > 0 { kill(pid, SIGWINCH) }
    }

    /// **kill → EOF → close, and never close while the drain is parked.**
    /// That ordering is a rule, not a detail: `close(2)` on a pty master
    /// blocks forever while a thread sits in a blocking `read(2)` —
    /// reproduced twice, process in state `U` (#38). Killing first is what
    /// produces the EOF that ends the drain in the fast, common case: EOF
    /// was independently reproduced arriving 1–2 ms after the SIGKILL, for
    /// foreground, background and fully redirected jobs alike, because
    /// macOS revokes the tty when the session leader dies.
    ///
    /// **EOF is not the only way the drain thread can end, which is what
    /// makes the deadline below actually bounded rather than probabilistic.**
    /// `startDraining` no longer sits in a bare blocking `read(2)`; it
    /// `poll(2)`s the master with a short timeout and checks an atomic-ish
    /// (lock-guarded) `stopRequested` flag on every tick, which `teardown`
    /// sets **before** it sends a single signal. Measured without this: a
    /// child forked microseconds before teardown runs has not yet attached
    /// to this pty as its controlling terminal, so `paneProcesses()` — and
    /// therefore the EOF that depends on every holder actually being
    /// killed — can miss it, and the drain read stays parked past the
    /// deadline. That surfaced as `AbandonedPty` at 2.0–2.1s in roughly
    /// 30% of runs once the live-shell test count went up. The poll tick
    /// means the drain thread exits within one tick of `requestStop()`
    /// regardless of whether EOF ever arrives, so a parked read is no
    /// longer possible and `close(master)` below is never reached while
    /// anything is still using the descriptor.
    ///
    /// **The whole pane dies, not just the shell.** `kill(pid, …)` reaches
    /// only the shell, and a job the operator backgrounded outlives the
    /// pane: measured, `sleep 45 </dev/null >/dev/null 2>&1 &` survived
    /// teardown, reparented to `ppid` 1, still alive 8 seconds later. A job
    /// that still writes to the tty dies anyway via the revoke, which is
    /// exactly why a check for the *shell* could not see this.
    ///
    /// `kill(-pid, …)` is necessary and **not sufficient**: `forkpty` makes
    /// the shell a session leader so its pgid is its pid, but an
    /// interactive bash has job control on and puts each job in a group of
    /// its own, so the group kill misses exactly the jobs this is about.
    /// The order below is what works, and each step was measured — stop
    /// the shell so it cannot start anything else, snapshot every process
    /// still holding this pty as its controlling terminal (see
    /// `paneProcesses`), kill them, then kill the shell's group and the
    /// shell.
    ///
    /// **Both waits are bounded**, and on expiry this abandons rather than
    /// blocks — see `TerminalStore.abandonedResources` for the trade.
    ///
    /// Synchronous by design: it is called from one place, inside
    /// `TerminalStore`'s single-flight teardown task, which is what keeps
    /// it off the cooperative pool.
    func teardown() -> AbandonedPty? {
        // Set BEFORE a single signal is sent: the drain thread's next
        // `poll(2)` timeout — at most `drainPollTimeoutMilliseconds` away,
        // never more than one tick behind this call — is what now bounds
        // the wait below, not whichever of EOF or the deadline happens
        // to land first.
        requestStop()
        if pid > 0 {
            // Stopped first, so the shell cannot start another job between
            // the snapshot and the kill.
            kill(-pid, SIGSTOP)
            kill(pid, SIGSTOP)
            let inSession = paneProcesses()
            for other in inSession where other != pid && other != getpid() {
                kill(other, SIGKILL)
            }
            kill(-pid, SIGKILL)
            // Belt and braces: if the child ever left its own group, the
            // group kill misses it and this does not.
            kill(pid, SIGKILL)
        }

        let drainDeadline = Date().addingTimeInterval(Self.teardownDeadlineSeconds)
        while let thread = drainThread, !thread.isFinished, Date() < drainDeadline { usleep(200) }
        if let thread = drainThread, !thread.isFinished {
            // The read never ended. Closing now is the documented
            // forever-block, so the descriptor is abandoned open.
            let abandoned = AbandonedPty(master: master, pid: pid)
            drainThread = nil
            master = -1
            pid = -1
            return abandoned
        }
        drainThread = nil

        if master >= 0 { close(master); master = -1 }

        guard pid > 0 else { return nil }
        // `WNOHANG` in a bounded loop rather than a blocking `waitpid`:
        // a child stuck exiting must not be able to park this thread for
        // the rest of the process's life.
        var status: Int32 = 0
        let reapDeadline = Date().addingTimeInterval(Self.teardownDeadlineSeconds)
        var reaped = false
        while Date() < reapDeadline {
            let result = waitpid(pid, &status, WNOHANG)
            // `result < 0` is ECHILD — already reaped, which counts.
            if result != 0 { reaped = true; break }
            usleep(200)
        }
        let unreaped = pid
        pid = -1
        return reaped ? nil : AbandonedPty(master: -1, pid: unreaped)
    }

    /// Every process whose controlling terminal is this pane's pty.
    ///
    /// **Measured, because two simpler answers do not work.**
    /// `kill(-pid, …)` alone does not reach a backgrounded job: an
    /// interactive bash has job control on, and job control puts each job
    /// in its OWN process group — reproduced, shell pgid 79154 against job
    /// pgid 79175 — so the pane's group kill misses it entirely.
    /// `sysctl(KERN_PROC_SESSION)` is declared in the SDK but returns
    /// ENOENT on this OS. `proc_listpids(PROC_TTY_ONLY, …)` does work, and
    /// returned exactly the shell plus its fully redirected `sleep`.
    ///
    /// **It has to be called before the shell dies.** Repeated after the
    /// kill it returns nothing at all, because macOS revokes the terminal
    /// when the session leader dies, and the survivors then have no
    /// controlling tty to be found by. That is the whole reason teardown
    /// stops the shell, snapshots, and only then kills.
    private func paneProcesses() -> [pid_t] {
        guard slaveDevice != 0 else { return [] }
        var capacity = 64
        while capacity <= 8_192 {
            var pids = [pid_t](repeating: 0, count: capacity)
            let bytes = pids.withUnsafeMutableBytes {
                proc_listpids(
                    UInt32(PROC_TTY_ONLY), slaveDevice, $0.baseAddress, Int32($0.count))
            }
            if bytes <= 0 { return [] }
            let count = Int(bytes) / MemoryLayout<pid_t>.size
            // A full buffer may have been truncated; ask again with room.
            if count >= capacity { capacity *= 2; continue }
            return pids.prefix(count).filter { $0 > 1 }
        }
        return []
    }

    // MARK: - Reading, for the poller and for tests

    func screenLines() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return (0..<rows).map { row in
            guard let line = terminal.getLine(row: row) else { return "" }
            return String(Self.rowCells(line).map(\.character))
        }
    }

    /// `screenLines()`'s own rows, as coalesced style runs — the grid's
    /// half of colour, the other being `stylesForBlockOutput` below.
    ///
    /// **Read from SwiftTerm's own per-cell `Attribute`, never re-parsed.**
    /// The engine has already parsed every SGR sequence the live screen
    /// received into `CharData.attribute` by the time anything asks for a
    /// row; re-parsing the same bytes a second time here would be a
    /// second, divergent view of the same stream — the identical reason
    /// `consume` feeds the engine the whole raw chunk rather than a
    /// stripped copy. `Self.rowCells` is the one adapter from SwiftTerm's
    /// `Attribute.Color` to this file's `TerminalAnsiColorSource`, and
    /// `terminalCoalesceStyleRuns` (pure, `TerminalAnsiColorTests.swift`)
    /// does the actual merging.
    func styledScreenLines() -> [[TerminalStyleRun]] {
        lock.lock()
        defer { lock.unlock() }
        return (0..<rows).map { row in
            guard let line = terminal.getLine(row: row) else { return [] }
            return terminalCoalesceStyleRuns(Self.rowCells(line))
        }
    }

    /// One row's cells as `(character, style)`, trimmed the same way
    /// `translateToString(trimRight: true)` used to be — everything after
    /// the last non-empty cell is dropped, never drawn as trailing blank
    /// space.
    ///
    /// **A cell SwiftTerm never wrote draws as a literal space, not as
    /// whatever `getCharacter()` decodes its empty code to.** An
    /// unwritten cell's underlying `code` is `0`, and `CharData
    /// .getCharacter()` treats that as the NUL scalar and returns it — a
    /// real character, U+0000, which most renderers draw as nothing at
    /// all. (`code` itself is not a public property of `CharData` —
    /// checked here the only way this module can, by asking whether the
    /// CHARACTER it decodes to is NUL, which is exactly the case
    /// `getCharacter()`'s own fallback documents: "if let c =
    /// Unicode.Scalar(UInt32(code))" succeeds for `0` too, since NUL is a
    /// valid scalar.) A program that positions its cursor forward (`CSI n
    /// C`, or an absolute column move) rather than writing literal spaces
    /// leaves exactly these cells behind — real terminal emulators do not
    /// special-case this because a NUL glyph reads as a space to begin
    /// with; SwiftUI's `Text` does not extend it the same courtesy, and
    /// the result was interior gaps vanishing ("Transcriptsavingisoff"
    /// for "Transcript saving is off"), never leading or trailing ones —
    /// trailing blanks were already gone via `getTrimmedLength()`, and a
    /// leading run of unwritten cells before any real content on the row
    /// is indistinguishable from indentation typed as spaces, so it
    /// renders the same way indentation would.
    private static func rowCells(_ line: BufferLine) -> [(character: Character, style: TerminalCellStyle)] {
        let trimmed = min(line.getTrimmedLength(), line.count)
        guard trimmed > 0 else { return [] }
        var cells: [(character: Character, style: TerminalCellStyle)] = []
        cells.reserveCapacity(trimmed)
        for index in 0..<trimmed {
            let cell = line[index]
            let decoded = cell.getCharacter()
            let character: Character = decoded == "\0" ? " " : decoded
            cells.append((character, cellStyle(for: cell.attribute)))
        }
        return cells
    }

    /// The adapter from SwiftTerm's own `Attribute` to this file's
    /// `TerminalCellStyle` — the one place `Attribute.Color` is read for
    /// the live grid.
    private static func cellStyle(for attribute: Attribute) -> TerminalCellStyle {
        let fgSource = colorSource(attribute.fg)
        return TerminalCellStyle(
            foreground: terminalPaletteColor(for: fgSource),
            background: terminalPaletteColor(for: colorSource(attribute.bg)),
            bold: attribute.style.contains(.bold),
            dim: attribute.style.contains(.dim) || terminalIsAnsiBlack(fgSource),
            underline: attribute.style.contains(.underline) || attribute.underlineStyle != .none,
            reverse: attribute.style.contains(.inverse))
    }

    /// `Attribute.Color` names four cases; only two of them are colours
    /// this file has a value for. `ansi256` already covers 0–15 (the
    /// standard 16) as well as the extended 256, which is exactly
    /// `TerminalAnsiColorSource`'s own split — see that enum's doc
    /// comment. `defaultInvertedColor` is SwiftTerm's own "default
    /// background, or the inverse fill" — treated identically to
    /// `defaultColor` here because neither names one of this file's
    /// anchors; `CharacterStyle.inverse`, read separately in `cellStyle`,
    /// is what actually decides whether a cell is shown reversed.
    private static func colorSource(_ color: Attribute.Color) -> TerminalAnsiColorSource {
        switch color {
        case .ansi256(let code): return code < 16 ? .standard(code) : .extended(code)
        case .trueColor(let r, let g, let b): return .trueColor(r, g, b)
        case .defaultColor, .defaultInvertedColor: return .defaultColor
        }
    }

    /// The pty's cursor, in the SAME absolute grid coordinates
    /// `screenLines()` and `promptRow` use — row 0 is the top of the
    /// currently visible screen, never scrollback. Feeds
    /// `terminalCursorLocation` (`TerminalPaneSupport.swift`, walk-defects
    /// D3): nothing drew a cursor at all because nothing published where
    /// one was.
    ///
    /// **`buffer.y` is already viewport-relative here, not absolute
    /// scroll-buffer-relative**, because this headless engine is never
    /// told to scroll its own display independently of content growth —
    /// nothing in this file ever calls the API that would move `yDisp`
    /// away from `yBase` — so the two stay equal and `buffer.y` (relative
    /// to `yBase`) lands in the same space `getLine(row:)` (relative to
    /// `yDisp`) already does.
    func cursorPosition() -> (row: Int, col: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (terminal.buffer.y, terminal.buffer.x)
    }

    /// The cursor's run of rows as cells, or `nil` when the line is not
    /// editable: not at a prompt, a prompt Wakil's rc did not draw, or the
    /// alternate screen. See `TerminalInputLine`.
    func inputLine() -> TerminalInputLine? {
        if isAlternateScreenActive { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard atPrompt, lineEditSupported else { return nil }
        let cursor = TerminalGridPoint(row: terminal.buffer.y, col: terminal.buffer.x)
        var first = cursor.row
        var last = cursor.row
        // `isWrapped` marks a row that CONTINUES the one above it.
        while first > 0, terminal.getLine(row: first)?.isWrapped == true { first -= 1 }
        while last + 1 < rows, terminal.getLine(row: last + 1)?.isWrapped == true { last += 1 }
        var cells: [TerminalInputCell] = []
        for row in first...last {
            guard let line = terminal.getLine(row: row) else { continue }
            for col in 0..<min(line.count, cols) {
                let cell = line[col]
                guard cell.width > 0 else { continue }  // a wide character's trailing half
                let decoded = cell.getCharacter()
                cells.append(TerminalInputCell(
                    point: TerminalGridPoint(row: row, col: col),
                    character: decoded == "\0" ? " " : decoded, width: Int(cell.width)))
            }
        }
        return TerminalInputLine(cells: cells, cursor: cursor)
    }

    /// Whether the shell asked for bracketed paste (DECSET 2004), as
    /// SwiftTerm tracks it.
    var bracketedPasteMode: Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminal.bracketedPasteMode
    }

    /// TEST-ONLY.
    func lineEditSupportedForTesting() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return lineEditSupported
    }

    /// Whether anything has been written since the last call, and the rows
    /// it touched — SwiftTerm's dirty range, which is the ONLY way it
    /// reports a content change.
    func takeUpdateRange() -> (startY: Int, endY: Int)? {
        lock.lock()
        defer { lock.unlock() }
        guard let range = terminal.getUpdateRange() else { return nil }
        terminal.clearUpdateRange()
        return (range.startY, range.endY)
    }
}
