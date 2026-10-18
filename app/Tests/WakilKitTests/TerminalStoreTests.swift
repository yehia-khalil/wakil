import Foundation
import Testing
import SwiftTerm
@testable import WakilKit

/// The dependency is reachable from `WakilKit` and its engine behaves as
/// the probe measured, headlessly, with no view and no display.
///
/// **This asserts the dependency, not our code.** It exists because
/// SwiftTerm is this package's FIRST external dependency: a version bump
/// that changed `getUpdateRange`'s shape or dropped the headless
/// `Terminal` would otherwise surface as a compile error inside a pane
/// three tasks later, with nothing saying the dependency moved.
@Test func swiftTermsHeadlessEngineParsesAndReportsADirtyRange() {
    final class Silent: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }
    var options = TerminalOptions.default
    options.cols = 80
    options.rows = 24
    let terminal = Terminal(delegate: Silent(), options: options)

    terminal.feed(text: "hello\r\n")

    #expect(terminal.getUpdateRange() != nil)
    let line = terminal.getLine(row: 0)
    #expect(line?.translateToString(trimRight: true) == "hello")
}

// MARK: - A real shell on a real pty

/// A real `bash` on a real pty: open, write, read the echo back, resize,
/// close, and assert the child is gone.
///
/// **Driven through the store rather than against a bare `forkpty`.** The
/// standing lesson is 2b-viii's walk: a test that calls a method the
/// shipped path does not call proves nothing about the shipped path.
@Test func aRealShellOpensEchoesResizesAndIsReapedOnClose() async throws {
    try await withTerminalStore { store in
        let opened = try await store.open(
            paneId: "terminal-1", path: NSTemporaryDirectory(), shell: "/bin/bash",
            environment: ["HOME": scratchHome()])

        #expect(opened.shell == "bash")
        #expect(await store.isRunning(paneId: "terminal-1"))
        let pid = await store.pidForTesting(paneId: "terminal-1")
        #expect(pid != nil)

        await store.write(paneId: "terminal-1", bytes: Array("echo wakil-ok\n".utf8))
        try await waitUntil(seconds: 5) { await store.screenContains("terminal-1", "wakil-ok") }

        await store.resize(paneId: "terminal-1", cols: 100, rows: 40)
        #expect(await store.dimensions(paneId: "terminal-1")?.cols == 100)

        await store.close(paneId: "terminal-1")

        #expect(!(await store.isRunning(paneId: "terminal-1")))
        // The claim the sub-phase's fourth exit clause is: the child is
        // REAPED, not merely dereferenced. `kill(pid, 0)` answers ESRCH only
        // once the process is gone and waited for.
        #expect(kill(pid!, 0) == -1)
        #expect(await store.abandonedResources.isEmpty)
    }
}

@Test func closingIsSingleFlightAndSafeToCallTwiceAndOnAPaneThatNeverOpened() async throws {
    try await withTerminalStore { store in
        _ = try await store.open(
            paneId: "terminal-1", path: NSTemporaryDirectory(), shell: "/bin/bash",
            environment: ["HOME": scratchHome()])

        // Concurrently, and again afterwards. The shape MCPClient.stop()'s doc
        // comment records: two callers that both pass a `!= nil` check before
        // either has torn anything down left the first one's continuation
        // unresumed, hanging it permanently.
        async let first: Void = store.close(paneId: "terminal-1")
        async let second: Void = store.close(paneId: "terminal-1")
        _ = await (first, second)
        await store.close(paneId: "terminal-1")
        await store.close(paneId: "never-opened")

        #expect(!(await store.isRunning(paneId: "terminal-1")))
    }
}

@Test func aShellStillProducingOutputIsKilledRatherThanWaitedFor() async throws {
    // The forgotten `tail -f`. Closing must not block on a child that has
    // no intention of stopping, and close(2) on the master must never
    // happen while the drain thread is parked in read(2) — measured
    // blocking forever, twice, process in state U (#38).
    try await withTerminalStore { store in
        _ = try await store.open(
            paneId: "terminal-1", path: NSTemporaryDirectory(), shell: "/bin/bash",
            environment: ["HOME": scratchHome()])
        await store.write(paneId: "terminal-1", bytes: Array("yes wakil\n".utf8))
        try await waitUntil(seconds: 5) { await store.screenContains("terminal-1", "wakil") }

        await store.close(paneId: "terminal-1")

        // **The shape, not the clock** (#307). This used to assert that
        // `close` returned inside `teardownDeadlineSeconds`, which measured
        // how much CPU the rest of the suite was using and went red at 5.6 s
        // under load while passing in 0.018 s alone — sending whoever read
        // the failure to the terminal teardown, which was fine.
        //
        // **The timing added nothing the rest of the test did not already
        // carry.** The shell here runs `yes wakil`, which never exits, so a
        // teardown that WAITED for it would never return and this test would
        // hang rather than fail an assertion. `close` returning at all is the
        // whole claim; `isRunning` false is that it was killed; and
        // `abandonedResources` empty is that it did not reach the give-up
        // branch — which the old comment already named as the stronger
        // assertion of the two.
        #expect(!(await store.isRunning(paneId: "terminal-1")))
        #expect(await store.abandonedResources.isEmpty)
    }
}

@Test func shutdownAllReapsEveryShellAndIsIdempotent() async throws {
    try await withTerminalStore { store in
        var pids: [String: pid_t] = [:]
        for id in ["terminal-1", "terminal-2", "terminal-3"] {
            _ = try await store.open(
                paneId: id, path: NSTemporaryDirectory(), shell: "/bin/bash",
                environment: ["HOME": scratchHome()])
            pids[id] = try #require(await store.pidForTesting(paneId: id))
        }

        await store.shutdownAll()
        await store.shutdownAll()

        for id in ["terminal-1", "terminal-2", "terminal-3"] {
            #expect(!(await store.isRunning(paneId: id)))
            // `isRunning` is a dictionary lookup, not a liveness check, so on
            // its own it says nothing about the three children. This is the
            // clause the sub-phase actually has to defend, and it is the same
            // assertion the single-shell test makes: ESRCH only answers once
            // the process is gone AND waited for.
            #expect(kill(pids[id]!, 0) == -1)
        }
        #expect(await store.abandonedResources.isEmpty)
    }
}

@Test func anUnsupportedShellIsRefusedAtOpenRatherThanDegraded() async {
    // A degraded mode is a mode in which commands run outside the action
    // registry: without OSC 133 the shell owns the input line and nothing
    // journals a run. zsh and bash are named, the way Invariant 6 refuses
    // DDL by naming each verb.
    let store = TerminalStore(scratchRoot: testScratchRoot)

    await #expect(throws: TerminalOpenError.unsupportedShell("/bin/fish")) {
        _ = try await store.open(
            paneId: "terminal-1", path: NSTemporaryDirectory(), shell: "/bin/fish")
    }
}

// MARK: - The shell is not the only thing the pane owns

/// A job the operator backgrounded and fully redirected must die with the
/// pane.
///
/// **This is the case a check for the shell structurally cannot see.**
/// `kill(pid, …)` reaches only the shell itself; a job that still writes to
/// the tty then dies anyway, because macOS revokes the tty when the session
/// leader dies. Only a job with all three descriptors redirected survives
/// — measured, `sleep 45 </dev/null >/dev/null 2>&1 &` outlived teardown,
/// reparented to `ppid` 1, and was still alive eight seconds later. The
/// signal has to go to the process GROUP, which `forkpty` makes equal to
/// the shell's pid by making it a session leader.
///
/// The pid travels through a file rather than the screen: the terminal
/// echoes the command line as well as its output, so a marker scraped off
/// the screen can match the echo of its own request.
@Test func tearingDownAPaneKillsAJobTheShellBackgroundedAndFullyRedirected() async throws {
    try await withTerminalStore { store in
        _ = try await store.open(
            paneId: "terminal-1", path: NSTemporaryDirectory(), shell: "/bin/bash",
            environment: ["HOME": scratchHome()])

        let pidFile = testScratchRoot.appendingPathComponent("wakil-orphan-\(UUID().uuidString).pid").path
        defer { try? FileManager.default.removeItem(atPath: pidFile) }
        await store.write(
            paneId: "terminal-1",
            bytes: Array("sleep 45 </dev/null >/dev/null 2>&1 & echo $! > \(pidFile)\n".utf8))
        try await waitUntil(seconds: 5) { readPid(pidFile) != nil }

        let jobPid = try #require(readPid(pidFile))
        // Without this the test could pass on a job that never started.
        #expect(kill(jobPid, 0) == 0)

        await store.close(paneId: "terminal-1")

        // The job is not our child — it reparents to launchd — so there is no
        // waitpid to synchronise on, only the moment it stops existing.
        try await waitUntil(seconds: 5) { kill(jobPid, 0) == -1 }
        #expect(kill(jobPid, 0) == -1)
        if kill(jobPid, 0) == 0 { kill(jobPid, SIGKILL) }
    }
}

// MARK: - The two windows where a pane could be opened or closed twice

/// A second `term_open` on a live pane replaces its shell **and reaps the
/// one it replaced**. A pane holds exactly one shell; a replacement that
/// only overwrote the dictionary entry would leak a process, an fd and a
/// thread on every reopen.
@Test func reopeningAPaneReplacesItsShellAndReapsTheOneItReplaced() async throws {
    try await withTerminalStore { store in
        _ = try await store.open(
            paneId: "terminal-1", path: NSTemporaryDirectory(), shell: "/bin/bash",
            environment: ["HOME": scratchHome()])
        let firstPid = try #require(await store.pidForTesting(paneId: "terminal-1"))

        _ = try await store.open(
            paneId: "terminal-1", path: NSTemporaryDirectory(), shell: "/bin/bash",
            environment: ["HOME": scratchHome()])
        let secondPid = try #require(await store.pidForTesting(paneId: "terminal-1"))

        #expect(secondPid != firstPid)
        #expect(kill(firstPid, 0) == -1)

        await store.close(paneId: "terminal-1")
        // Reported alongside the reap, not instead of it: this assertion went
        // red once in ~30 runs of the parallel suite at exactly 2.018s — the
        // teardown deadline — and did not recur in 180 instrumented runs
        // afterwards. If it ever does, `abandonedResources` names which of the
        // two bounded waits gave up rather than leaving it to be guessed.
        let abandoned = await store.abandonedResources
        #expect(abandoned.isEmpty, "\(abandoned)")
        #expect(kill(secondPid, 0) == -1, "abandoned: \(abandoned)")
    }
}

/// Two `open`s racing on one pane leave exactly one shell, and no
/// unreachable one behind.
///
/// `open` begins with `await close(paneId:)`, which is a suspension point.
/// Unguarded, both callers suspended there, both resumed, both spawned, and
/// the second's `sessions[paneId] = session` overwrote the first — whose
/// shell, master and drain thread were then unreachable by every method on
/// the store and could never be reaped. `close`'s single-flight guard was
/// already atomic; this is the same guard on the opening side.
@Test func twoOpensRacingOnOnePaneLeaveExactlyOneReachableShell() async throws {
    try await withTerminalStore { store in
        let path = NSTemporaryDirectory()
        async let first = store.open(
            paneId: "terminal-1", path: path, shell: "/bin/bash", environment: ["HOME": scratchHome()])
        async let second = store.open(
            paneId: "terminal-1", path: path, shell: "/bin/bash", environment: ["HOME": scratchHome()])
        _ = try await (first, second)

        let survivor = try #require(await store.pidForTesting(paneId: "terminal-1"))
        await store.close(paneId: "terminal-1")

        #expect(kill(survivor, 0) == -1)
        #expect(!(await store.isRunning(paneId: "terminal-1")))
        #expect(await store.abandonedResources.isEmpty)
    }
}

/// Keystrokes arriving while a pane is closing must not reach the
/// descriptor teardown is closing.
///
/// The actor is free for the whole teardown suspension, so `write` and
/// `resize` interleave with it freely. When the session was cleared
/// *after* that await, both still found it, both passed
/// `guard master >= 0`, and both called into an fd the teardown thread had
/// already closed — and because descriptor numbers are recycled
/// aggressively, that writes shell keystrokes into whatever reopened the
/// number rather than failing with EBADF. Clearing the session as
/// `performTeardown`'s first statement, with no suspension before it,
/// makes the session unreachable before the closing thread is even
/// created.
@Test func writesAndResizesArrivingDuringACloseNeverReachTheClosingDescriptor() async throws {
    for round in 0..<8 {
        try await withTerminalStore { store in
            _ = try await store.open(
                paneId: "terminal-1", path: NSTemporaryDirectory(), shell: "/bin/bash",
                environment: ["HOME": scratchHome()])

            async let closing: Void = store.close(paneId: "terminal-1")
            for _ in 0..<64 {
                await store.write(paneId: "terminal-1", bytes: Array("echo racing\n".utf8))
                await store.resize(paneId: "terminal-1", cols: 90, rows: 30)
            }
            await closing

            #expect(!(await store.isRunning(paneId: "terminal-1")), "round \(round)")
            #expect(await store.dimensions(paneId: "terminal-1") == nil, "round \(round)")
            #expect(await store.abandonedResources.isEmpty, "round \(round)")
        }
    }
}

// MARK: - What the shell is handed, and what quit has to see

/// The shell is started with Wakil's own environment, plus whatever the
/// caller layered on top.
///
/// **This is a regression test for the `execve` switch.** `execv` inherited
/// `environ` and the child's `setenv` calls overlaid it; `execve` REPLACES
/// the environment, and `open`'s `environment:` defaults to empty — so the
/// shell was handed nothing at all: `TERM=dumb`, `HOME`/`USER`/`LANG`
/// empty, and bash falling back to its own built-in PATH. The suite could
/// not see it because bash synthesises a PATH when it has none. **No rc
/// file is read without a `HOME`**, which is precisely what Task 7's
/// shell-integration injection depends on.
///
/// `HOME` is deliberately overridden to a directory with no `.bashrc`,
/// which serves twice: it proves the caller's entry beats the inherited
/// one, and it stops a real rc file from rewriting the PATH this asserts.
///
/// **The comparison is a SET, not an exact string, since Task 7.** The
/// generated rc now always sources `/etc/profile` — that is `path_helper`,
/// which is the whole point of the login-shell requirement — and
/// `path_helper` deduplicates and reorders `PATH`, moving the canonical
/// system directories to the front. What Task 6 needs proven still holds:
/// every entry Wakil's own process carried arrives at the child, none
/// silently dropped, and the built-in fallback never fires. Byte-for-byte
/// order is not part of that claim once a real login shell is in the
/// loop.
@Test func aSpawnedShellInheritsWakilsEnvironmentWithTheCallersEntriesOnTop() async throws {
    try await withTerminalStore { store in
        let probe = "wakil-task6-\(UUID().uuidString)"
        let home = scratchHome()
        let report = testScratchRoot.appendingPathComponent("wakil-env-\(UUID().uuidString).txt").path
        defer { try? FileManager.default.removeItem(atPath: report) }

        _ = try await store.open(
            paneId: "terminal-1", path: NSTemporaryDirectory(), shell: "/bin/bash",
            environment: ["HOME": home, "WAKIL_TASK6_PROBE": probe])
        let command = "printf '%s\\n%s\\n%s\\nEND\\n'"
            + " \"$PATH\" \"$HOME\" \"$WAKIL_TASK6_PROBE\" > \(report)\n"
        await store.write(paneId: "terminal-1", bytes: Array(command.utf8))
        try await waitUntil(seconds: 5) { readLines(report)?.last == "END" }
        await store.close(paneId: "terminal-1")

        let lines = try #require(readLines(report))
        let inheritedPath = try #require(ProcessInfo.processInfo.environment["PATH"])
        #expect(lines.count == 4)
        let inheritedEntries = Set(inheritedPath.split(separator: ":"))
        let reportedEntries = Set(lines[0].split(separator: ":"))
        #expect(
            inheritedEntries.isSubset(of: reportedEntries),
            "missing: \(inheritedEntries.subtracting(reportedEntries))")
        // bash's built-in fallback, the tell that it was handed no PATH at all.
        // Its trailing `.` is its own problem.
        #expect(!lines[0].contains("/usr/gnu/bin"))
        #expect(lines[1] == home)
        #expect(lines[2] == probe)
    }
}

/// The shell must not inherit a descriptor this process holds.
///
/// **The regression test for the wedge**, and it asserts the production
/// consequence rather than a proxy for it. A pipe reaches EOF only when
/// the LAST write end closes. So: open a pipe, spawn a pane, close the
/// parent's write end, and read. If the shell inherited a duplicate, the
/// pipe still has a writer, no EOF ever arrives, and `poll` times out —
/// which is exactly what `MCPClient`'s stdout and stderr drain threads
/// experienced when this was broken, except that they had no deadline and
/// the whole parallel suite hung behind them for 45 minutes.
///
/// Pure POSIX on a descriptor this test owns: no `lsof`, no reading
/// another process's fd table, and no dependence on WHICH descriptors
/// Wakil happens to hold on the day it runs.
///
/// It is a stronger claim than "the pane Wakil just opened did not inherit
/// it", because the suite is parallel: any OTHER test's shell forking
/// during this window would hold the write end too. That is the claim
/// worth making — `TerminalSession.spawn` is the only thing in this
/// process that `fork`s without `POSIX_SPAWN_CLOEXEC_DEFAULT`.
@Test func aSpawnedShellInheritsNoneOfThisProcessesOtherDescriptors() async throws {
    var ends: [Int32] = [-1, -1]
    try #require(pipe(&ends) == 0)
    let readEnd = ends[0]
    let writeEnd = ends[1]
    defer { close(readEnd) }

    try await withTerminalStore { store in
        _ = try await store.open(
            paneId: "terminal-1", path: NSTemporaryDirectory(), shell: "/bin/bash",
            environment: ["HOME": scratchHome()])

        // The only write end this process still holds, gone.
        #expect(close(writeEnd) == 0)

        // Two seconds, the same budget `TerminalSession.teardownDeadlineSeconds`
        // gives a child to finish exiting. An EOF that is coming at all is
        // already here: the last writer closed on the line above.
        var readable = pollfd(fd: readEnd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&readable, 1, 2_000)
        #expect(
            ready == 1,
            "no EOF within 2s — the shell inherited the pipe's write end (poll returned \(ready))")

        // **Guarded on `poll`, and that guard is the difference between a
        // red test and another wedge.** Measured: with the close loop
        // disabled, `poll` times out (the shell holds a write end, so
        // there is nothing to read and never will be) and an unguarded
        // `read` then parks the test task in `read(2)` FOREVER — a
        // cooperative-pool thread gone, the run hung, and the failure
        // silent. That is the very failure mode this whole change exists
        // to end, reproduced inside its own regression test. `poll`
        // carries the deadline; the read only ever runs when it cannot
        // block.
        if ready == 1 {
            var byte: UInt8 = 0
            #expect(read(readEnd, &byte, 1) == 0, "expected EOF, got data or an error")
        }
    }
}

/// Quit must not sweep past a pane whose `open` has not installed its
/// session yet.
///
/// A pane mid-`open` has no `sessions` entry, so a `shutdownAll` that only
/// walked `sessions` returned while the shell was still being spawned, and
/// that shell outlived the app.
///
/// **Reopening is what makes the window wide and reliable.** Every one of
/// these suspends inside `performOpen`'s teardown of the shell it replaces,
/// so all of them are registered as in flight long before any installs a
/// session — which is what lets the sweep happen at a moment when there
/// demonstrably are in-flight opens rather than at a moment that happens to
/// prove nothing.
@Test func shutdownAllAwaitsThePanesWhoseOpenIsStillInFlight() async throws {
    try await withTerminalStore { store in
        let ids = (1...8).map { "terminal-\($0)" }
        for id in ids {
            _ = try await store.open(
                paneId: id, path: NSTemporaryDirectory(), shell: "/bin/bash",
                environment: ["HOME": scratchHome()])
        }

        async let reopens: Void = withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask {
                    _ = try? await store.open(
                        paneId: id, path: NSTemporaryDirectory(), shell: "/bin/bash",
                        environment: ["HOME": scratchHome()])
                }
            }
        }

        // Sweep once opens are demonstrably in flight. The assertion is that
        // there WAS one, not that all eight had registered: requiring the full
        // count made the test itself racy — measured failing once in ~20 under
        // the parallel suite, on its own gate rather than on the store — and
        // the count is not what the fix is about. `shutdownAll` drains
        // `openTasks` to empty rather than snapshotting it once, so a pane that
        // registers while the drain is running is caught too.
        var inFlight = 0
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            inFlight = await store.openInFlightCountForTesting()
            if inFlight > 0 { break }
            await Task.yield()
        }
        #expect(inFlight > 0)

        await store.shutdownAll()
        await reopens

        let survivors = await store.runningPaneIdsForTesting()
        #expect(survivors.isEmpty, "\(survivors)")
        await store.shutdownAll()
    }
}

// MARK: - The generated rc, live

/// A real `bash`, with Wakil's generated rc injected, emits the four OSC
/// 133 marks around one command it actually runs.
///
/// **Asserted through the store against a LIVE shell, not against byte
/// fixtures.** The parser is SwiftTerm's; what is worth asserting is that
/// a real shell plus Wakil's rc produces the marks the pane draws blocks
/// from.
///
/// **`HOME` isolated, unlike round 1 of this test.** This is exactly the
/// live-shell test that would have gone red against a `.bashrc` setting
/// `HISTIGNORE`/`HISTCONTROL=ignorespace` or a `PROMPT_COMMAND` of its
/// own — the two configurations round 1's review measured breaking the
/// unisolated version — so it is isolated the same way the ~12
/// longer-standing tests already are, rather than being the one live
/// mark test still exposed to whichever machine runs the suite.
@Test func aRealBashEmitsWakilsMarksAroundACommandItRuns() async throws {
    try await withTerminalStore { store in
        _ = try await store.open(
            paneId: "t", path: NSTemporaryDirectory(), shell: "/bin/bash",
            environment: ["HOME": scratchHome()])

        await store.write(paneId: "t", bytes: Array("printf hello; exit 7\n".utf8))
        try await waitUntil(seconds: 8) {
            await store.marksForTesting("t").contains {
                if case .commandEnd = $0 { return true } else { return false }
            }
        }

        let marks = await store.marksForTesting("t")
        #expect(marks.contains { if case .promptStart = $0 { return true } else { return false } })
        #expect(marks.contains { if case .promptEnd = $0 { return true } else { return false } })
        #expect(marks.contains {
            if case .commandStart(let c) = $0 { return c == "printf hello; exit 7" } else { return false }
        })
        // The exit code rides D;<code> and SwiftTerm does not retain it, so
        // capturing it is Wakil's — measured by feeding D;42 and finding
        // nothing at any public seam (probe §4.4).
        #expect(marks.contains {
            if case .commandEnd(let code) = $0 { return code == 7 } else { return false }
        })
    }
}

/// The same shape, for `zsh`.
///
/// **`HOME` alone would not isolate a zsh pane** — `WAKIL_USER_ZDOTDIR`
/// (what the generated rc restores `ZDOTDIR` to) is derived in
/// `TerminalStore.performOpen` from `ProcessInfo.processInfo.environment`
/// merged with THIS test's own `environment:` override, so passing `HOME`
/// here is what redirects it away from the operator's real `~/.zshrc`.
@Test func aRealZshEmitsTheSameMarks() async throws {
    try await withTerminalStore { store in
        _ = try await store.open(
            paneId: "t", path: NSTemporaryDirectory(), shell: "/bin/zsh",
            environment: ["HOME": scratchHome()])
        await store.write(paneId: "t", bytes: Array("printf hello; exit 3\n".utf8))
        try await waitUntil(seconds: 8) {
            await store.marksForTesting("t").contains {
                if case .commandEnd(let code) = $0 { return code == 3 } else { return false }
            }
        }
        #expect(await store.marksForTesting("t").contains {
            if case .commandStart(let c) = $0 { return c == "printf hello; exit 3" } else { return false }
        })
    }
}

/// OSC 7. The header carries the LIVE cwd, so a `cd` never leaves it lying
/// about where the shell actually is.
@Test func aCdIsReportedAsTheShellsLiveWorkingDirectory() async throws {
    try await withTerminalStore { store in
        _ = try await store.open(
            paneId: "t", path: NSTemporaryDirectory(), shell: "/bin/bash",
            environment: ["HOME": scratchHome()])

        await store.write(paneId: "t", bytes: Array("cd /usr/lib\n".utf8))

        try await waitUntil(seconds: 8) { await store.cwd(paneId: "t") == "/usr/lib" }
    }
}

// MARK: - Round 1 review fixes

/// Round 1's critical finding: `history 1`'s TEXT alone is a different
/// oracle from "what is about to run" — it reports what bash RECORDED.
/// `HISTIGNORE` and `HISTCONTROL=ignorespace`, both mainstream, leave
/// history unchanged for a command, so `history 1` at that command's
/// `DEBUG` trap still shows the PREVIOUS entry — a plausible-but-false
/// command, worse than `$BASH_COMMAND`'s mere truncation, because it reads
/// as what ran rather than announcing that it does not know.
///
/// The fix verifies `history 1`'s leading NUMBER advanced since the last
/// block before trusting its text; `ls` and the space-led `echo spaced`
/// below never advance it, so both are reported as an honest empty
/// command rather than a repeat of `echo one`.
@Test func aRealBashReportsAnHonestEmptyCommandRatherThanAStaleOneUnderHistignoreAndIgnorespace() async throws {
    let home = scratchHome()
    let rc = "HISTIGNORE='ls:exit'\nHISTCONTROL=ignorespace\n"
    try rc.write(toFile: home + "/.bashrc", atomically: true, encoding: .utf8)

    try await withTerminalStore { store in
        // `home`, not `NSTemporaryDirectory()`: the `ls` below lists its
        // working directory, and the shared temp directory holds every
        // scratch dir this suite has ever leaked — measured at 168,984
        // entries, ~6.9MB of `ls` output that kept the last two commands
        // from starting inside the wait below. `home` holds only a
        // dot-file, so the `ls` prints nothing.
        _ = try await store.open(
            paneId: "t", path: home, shell: "/bin/bash",
            environment: ["HOME": home])

        await store.write(paneId: "t", bytes: Array("echo one\n".utf8))
        await store.write(paneId: "t", bytes: Array("ls\n".utf8))
        await store.write(paneId: "t", bytes: Array(" echo spaced\n".utf8))
        await store.write(paneId: "t", bytes: Array("echo three\n".utf8))

        try await waitUntil(seconds: 8) {
            await store.marksForTesting("t").filter {
                if case .commandStart = $0 { return true } else { return false }
            }.count >= 4
        }

        let commands = await store.marksForTesting("t").compactMap { mark -> String? in
            if case .commandStart(let c) = mark { return c }
            return nil
        }
        // Never a repeat of `echo one` standing in for `ls` or the space-led
        // command — each of those two is the honest empty string instead.
        #expect(commands.suffix(4) == ["echo one", "", "", "echo three"])
    }
}

/// Round 1's Important 2: a naive `PROMPT_COMMAND='__wakil_precmd'` and
/// `trap '__wakil_preexec' DEBUG` silently replaced whatever the operator's
/// OWN `.bashrc` had already installed — measured against a `.bashrc`
/// setting both — contradicting this file's claim that the pane is the
/// operator's shell and not a stripped one. The fix chains rather than
/// assigns, Wakil's own halves bracketing the operator's original text.
@Test func aRealBashPreservesTheOperatorsOwnPromptCommandAndDebugTrap() async throws {
    let home = scratchHome()
    let marker = testScratchRoot.appendingPathComponent("wakil-user-hooks-\(UUID().uuidString).txt").path
    defer { try? FileManager.default.removeItem(atPath: marker) }
    let rc = """
        PROMPT_COMMAND='echo user_pc >> \(marker)'
        trap 'echo user_debug >> \(marker)' DEBUG
        """
    try rc.write(toFile: home + "/.bashrc", atomically: true, encoding: .utf8)

    try await withTerminalStore { store in
        _ = try await store.open(
            paneId: "t", path: NSTemporaryDirectory(), shell: "/bin/bash",
            environment: ["HOME": home])

        // `user_debug` appears almost immediately — the operator's own raw
        // `trap ... DEBUG` is active from the moment their `.bashrc` is
        // sourced, well before Wakil's own rc finishes loading — so the
        // condition waits for `user_pc`, which only appears once a full
        // `PROMPT_COMMAND` cycle (Wakil's halves plus the chained original)
        // has actually run.
        try await waitUntil(seconds: 8) {
            (try? String(contentsOfFile: marker))?.contains("user_pc") == true
        }
        let content = try String(contentsOfFile: marker)
        #expect(content.contains("user_pc"))
        #expect(content.contains("user_debug"))

        // The chaining does not break Wakil's own marks either.
        await store.write(paneId: "t", bytes: Array("echo hi\n".utf8))
        try await waitUntil(seconds: 8) {
            await store.marksForTesting("t").contains {
                if case .commandStart(let c) = $0 { return c == "echo hi" } else { return false }
            }
        }
    }
}

/// Round 2's Minor 1: preserving the prior `DEBUG` trap's COMMAND wasn't
/// enough — `$_` is the one piece of state such a trap can read about
/// the command about to run besides `$BASH_COMMAND` (bash-preexec's own
/// trap is exactly `'__bp_preexec_invoke_exec "$_"'`), and
/// `__wakil_preexec`'s own `[ ... ] && return` guards each overwrite `$_`
/// with the literal `]` as a side effect of running `test`'s bracket
/// form. Measured: the prior trap received `]` instead of the real `$_`
/// before this was fixed. The fix captures `$_` in the merged trap line
/// before `__wakil_preexec` runs and restores it (via `: "$saved"`)
/// before handing control to the prior trap.
@Test func aRealBashPreservesDollarUnderscoreForThePriorDebugTrap() async throws {
    let home = scratchHome()
    let marker = testScratchRoot.appendingPathComponent("wakil-dollar-underscore-\(UUID().uuidString).txt").path
    defer { try? FileManager.default.removeItem(atPath: marker) }
    let rc = "trap 'echo \"SAW:$_\" >> \(marker)' DEBUG\n"
    try rc.write(toFile: home + "/.bashrc", atomically: true, encoding: .utf8)

    try await withTerminalStore { store in
        _ = try await store.open(
            paneId: "t", path: NSTemporaryDirectory(), shell: "/bin/bash",
            environment: ["HOME": home])

        // The DEBUG trap that fires for whatever bash runs immediately after
        // this command completes (Wakil's own `PROMPT_COMMAND` chain) sees
        // `$_` as bash itself left it — the marker's last argument — if and
        // only if Wakil's own hook didn't clobber it in between.
        await store.write(paneId: "t", bytes: Array("echo wakil_marker_value_42\n".utf8))

        try await waitUntil(seconds: 8) {
            (try? String(contentsOfFile: marker))?.contains("SAW:wakil_marker_value_42") == true
        }
        let content = try String(contentsOfFile: marker)
        // Before Wakil's own rc finishes and wraps this trap, the raw trap
        // the operator's `.bashrc` just installed legitimately sees `]` for
        // the rest of Wakil's OWN rc's `[ ... ]` guards — that window is not
        // what this test is about. What matters is that the operator's real
        // submitted command reaches the wrapped trap intact, once it is
        // wrapped.
        #expect(content.contains("SAW:wakil_marker_value_42"))
    }
}

/// Round 1's Important 1: a one-time `PS1=...` append at rc-load time is
/// erased the moment a LATER `precmd` hook recomputes `PS1` wholesale —
/// oh-my-zsh, powerlevel10k and starship all do this. Measured: `A`, `C`
/// and `D` survived, `B` did not, from the second prompt on. The fix
/// re-appends `B` from inside Wakil's own `precmd`, which runs LAST.
@Test func aRealZshsBMarkSurvivesAPrecmdHookThatRecomputesPS1() async throws {
    let home = scratchHome()
    let rc = """
        autoload -Uz add-zsh-hook
        _wakil_test_setps1() { PS1="testprompt$ " }
        add-zsh-hook precmd _wakil_test_setps1
        """
    try rc.write(toFile: home + "/.zshrc", atomically: true, encoding: .utf8)

    try await withTerminalStore { store in
        _ = try await store.open(
            paneId: "t", path: NSTemporaryDirectory(), shell: "/bin/zsh",
            environment: ["HOME": home])

        await store.write(paneId: "t", bytes: Array("echo one\n".utf8))
        try await waitUntil(seconds: 8) {
            await store.marksForTesting("t").contains {
                if case .commandStart(let c) = $0 { return c == "echo one" } else { return false }
            }
        }
        await store.write(paneId: "t", bytes: Array("echo two\n".utf8))
        try await waitUntil(seconds: 8) {
            await store.marksForTesting("t").contains {
                if case .commandStart(let c) = $0 { return c == "echo two" } else { return false }
            }
        }

        let promptEnds = await store.marksForTesting("t").filter {
            if case .promptEnd = $0 { return true } else { return false }
        }
        // At least two `B`s: the cycle before `echo one` and the one before
        // `echo two` — proving `B` is still there on the SECOND cycle, after
        // the user's own hook has already rewritten `PS1` once.
        #expect(promptEnds.count >= 2, "\(promptEnds.count)")
    }
}

/// The minor fix: a literal `%` in a directory name must survive OSC 7,
/// because `URL(string:)` treats an un-escaped `%XX` as ALREADY encoded
/// and silently decodes it — a directory literally named `100%25` would
/// otherwise round-trip as `100%`.
@Test func aDirectoryNamedWithAPercentSignRoundTripsThroughOsc7() async throws {
    let base = testScratchRoot.appendingPathComponent("wakil-pct-\(UUID().uuidString)").path
    let target = base + "/100%dir"
    try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: base) }

    try await withTerminalStore { store in
        _ = try await store.open(
            paneId: "t", path: NSTemporaryDirectory(), shell: "/bin/bash",
            environment: ["HOME": scratchHome()])

        await store.write(paneId: "t", bytes: Array("cd \"\(target)\"\n".utf8))
        try await waitUntil(seconds: 8) { await store.cwd(paneId: "t").hasSuffix("100%dir") }
    }
}

@Test func theShellCarriesTheActiveContextAndNotTheKeychain() {
    let environment = terminalChildEnvironment(
        org: "initech", project: "booking", environment: "staging",
        base: ["HOME": "/Users/x", "PATH": "/usr/bin", "AWS_PROFILE": "work"])

    #expect(environment["WAKIL_ORG"] == "initech")
    #expect(environment["WAKIL_PROJECT"] == "booking")
    #expect(environment["WAKIL_ENVIRONMENT"] == "staging")
    #expect(environment["TERM"] == "xterm-256color")
    // The operator's own login environment comes through — this is what
    // makes `aws`, `kubectl` and `docker` behave here as they do in
    // Terminal.app, and it is the opposite of the harness's four-variable
    // dictionary that the mirror's blocks ran under.
    #expect(environment["AWS_PROFILE"] == "work")
}

/// `TERM` is seeded BENEATH the caller's own value, not over it: a
/// launchd- or Finder-launched `Wakil.app` inherits no `TERM` at all, so
/// without a default the shipped pane's shell falls back to `dumb` even
/// though every test here passes — `swift test` itself runs under a
/// terminal that already has one.
@Test func termIsSeededWhenAbsentFromTheBaseEnvironment() {
    let noTerm = terminalChildEnvironment(
        org: "", project: "", environment: "", base: ["HOME": "/Users/x"])
    #expect(noTerm["TERM"] == "xterm-256color")

    let alreadySet = terminalChildEnvironment(
        org: "", project: "", environment: "", base: ["HOME": "/Users/x", "TERM": "screen"])
    #expect(alreadySet["TERM"] == "screen")
}

// MARK: - Round 2 review fixes

/// Round 2's Minor 2: `WAKIL_USER_ZDOTDIR` (what a zsh pane's rc restores
/// `ZDOTDIR` to) is derived from `base["ZDOTDIR"] ?? base["HOME"]`, so a
/// caller overriding only `HOME` — exactly what
/// `environment: ["HOME": scratchHome()]` does in the live-shell tests
/// above — was previously still out-ranked by a REAL, un-overridden
/// `ZDOTDIR` inherited from the process environment, on any machine that
/// exports one. It only ever passed here because this machine doesn't.
/// `launchBase` is a pure function precisely so this can be pinned
/// without mutating the real process environment: a fabricated
/// "process environment" stands in for a machine that exports `ZDOTDIR`.
@Test func aCallersHomeOverrideBeatsARealExportedZDOTDIR() {
    let launchBase = TerminalStore.launchBase(
        processEnvironment: [
            "ZDOTDIR": "/real/operator/zdotdir", "HOME": "/real/home", "PATH": "/usr/bin",
        ],
        callerEnvironment: ["HOME": "/scratch/home"])

    #expect(launchBase["ZDOTDIR"] == nil)
    #expect(launchBase["HOME"] == "/scratch/home")
    // Untouched keys the caller didn't mention survive the merge.
    #expect(launchBase["PATH"] == "/usr/bin")
}

/// A caller that explicitly asks for a particular `ZDOTDIR` — not just a
/// `HOME` — gets exactly that, rather than having it stripped too.
@Test func aCallersExplicitZDOTDIROverrideIsRespected() {
    let launchBase = TerminalStore.launchBase(
        processEnvironment: ["ZDOTDIR": "/real/operator/zdotdir", "HOME": "/real/home"],
        callerEnvironment: ["HOME": "/scratch/home", "ZDOTDIR": "/scratch/zdotdir"])

    #expect(launchBase["ZDOTDIR"] == "/scratch/zdotdir")
}

/// The shipped path: no caller override at all, so the real environment's
/// `ZDOTDIR` reaches the shell exactly as `ProcessInfo` reports it — the
/// strip is conditioned on the caller overriding `HOME`, not unconditional.
@Test func noCallerOverrideLeavesTheRealZDOTDIRAlone() {
    let launchBase = TerminalStore.launchBase(
        processEnvironment: ["ZDOTDIR": "/real/operator/zdotdir", "HOME": "/real/home"],
        callerEnvironment: [:])

    #expect(launchBase["ZDOTDIR"] == "/real/operator/zdotdir")
}

@Test func theShellIsLaunchedAsAnInteractiveLoginShellAndSourcesTheProfileChain() throws {
    // The one half of the PATH problem a test CAN hold. The symptom —
    // `which kubectl` failing in the bundled app — is invisible here,
    // because `swift test` runs from a terminal whose environment is
    // already correct. So what is pinned is the CAUSE: the login flag, and
    // the rc reaching the profile chain. Runbook check 3a walks the
    // symptom, in the bundle.
    let directory = testScratchRoot
        .appendingPathComponent("wakil-rc-\(UUID().uuidString)")

    let zsh = try shellLaunch(shell: "/bin/zsh", rcDirectory: directory, base: ["HOME": "/Users/x"])
    #expect(zsh.argv == ["/bin/zsh", "-il"])
    let zshRC = try String(contentsOf: directory.appendingPathComponent(".zshrc"), encoding: .utf8)
    #expect(zshRC.contains(".zprofile"))
    #expect(zshRC.contains(".zshrc"))

    let bash = try shellLaunch(shell: "/bin/bash", rcDirectory: directory, base: ["HOME": "/Users/x"])
    // bash ignores --rcfile for a login shell, so it is interactive and
    // sources the profile chain from Wakil's rc instead.
    #expect(bash.argv.contains("--rcfile"))
    #expect(!bash.argv.contains("-l"))
    let bashRC = try String(
        contentsOf: directory.appendingPathComponent("wakil-bashrc"), encoding: .utf8)
    #expect(bashRC.contains("/etc/profile"))
    #expect(bashRC.contains(".bash_profile"))
}

@Test func anEmptyContextMemberIsAbsentRatherThanAnEmptyString() {
    // Same rule `childProcessEnvironment` already holds itself to: absent
    // means unset, never the empty string, so a script testing `-n
    // "$WAKIL_ENVIRONMENT"` is told the truth.
    let environment = terminalChildEnvironment(
        org: "initech", project: "", environment: "", base: ["HOME": "/Users/x"])
    #expect(environment["WAKIL_PROJECT"] == nil)
    #expect(environment["WAKIL_ENVIRONMENT"] == nil)
}

/// Wakil.app may itself have been launched with a pin in its environment. An empty member
/// means "no such place member", so the inherited value must not show through.
@Test func anEmptyContextMemberRemovesAnInheritedPin() {
    let environment = terminalChildEnvironment(
        org: "initech", project: "", environment: "",
        base: ["HOME": "/Users/x", "WAKIL_PROJECT": "inherited", "WAKIL_ENVIRONMENT": "production"])
    #expect(environment["WAKIL_PROJECT"] == nil)
    #expect(environment["WAKIL_ENVIRONMENT"] == nil)
    #expect(environment["WAKIL_ORG"] == "initech")
}

/// The store's own layering: the shell's place is what the caller (`term_open`) handed down,
/// and a pin in Wakil's process environment the caller did not set never reaches the shell.
@Test func theShellsPlaceIsTheCallersNeverTheProcesss() {
    let process = ["PATH": "/usr/bin", "WAKIL_ORG": "other", "WAKIL_PROJECT": "inherited",
                   "WAKIL_ENVIRONMENT": "production"]
    let unpinned = TerminalStore.childEnvironment(
        processEnvironment: process, callerEnvironment: ["HOME": "/scratch"],
        launchEnvironment: ["ZDOTDIR": "/rc"])
    #expect(unpinned["WAKIL_ORG"] == nil)
    #expect(unpinned["WAKIL_PROJECT"] == nil)
    #expect(unpinned["WAKIL_ENVIRONMENT"] == nil)
    #expect(unpinned["PATH"] == "/usr/bin" && unpinned["HOME"] == "/scratch" && unpinned["ZDOTDIR"] == "/rc")

    let placed = TerminalStore.childEnvironment(
        processEnvironment: process,
        callerEnvironment: ["WAKIL_ORG": "initech", "WAKIL_PROJECT": "api", "WAKIL_ENVIRONMENT": "staging"],
        launchEnvironment: [:])
    #expect(placed["WAKIL_ORG"] == "initech")
    #expect(placed["WAKIL_PROJECT"] == "api")
    #expect(placed["WAKIL_ENVIRONMENT"] == "staging")
}

@Test func anUnsupportedShellIsRefusedByShellLaunchToo() throws {
    let directory = testScratchRoot
        .appendingPathComponent("wakil-rc-\(UUID().uuidString)")
    #expect(throws: TerminalOpenError.unsupportedShell("/bin/fish")) {
        _ = try shellLaunch(shell: "/bin/fish", rcDirectory: directory, base: ["HOME": "/Users/x"])
    }
}

// MARK: - Blocks

/// The whole point of the pane, end to end through a real shell: a
/// submitted command becomes one block carrying what it printed, what it
/// returned and how long it took.
@Test func aRealCommandBecomesABlockCarryingItsExitCodeAndDuration() async throws {
    let panes = PaneStore()
    try await withTerminalStore(panes: panes) { store in
        _ = try await store.open(
            paneId: "terminal-1", path: NSTemporaryDirectory(), shell: "/bin/bash",
            environment: ["HOME": scratchHome()])

        await store.write(
            paneId: "terminal-1", bytes: Array("printf 'a\\nb\\n'; exit 5\n".utf8))
        try await waitUntil(seconds: 8) {
            await panes.terminalBlocks(paneId: "terminal-1").count >= 1
        }

        let block = try #require(await panes.terminalBlocks(paneId: "terminal-1").first)
        #expect(block.command == "printf 'a\\nb\\n'; exit 5")
        #expect(block.origin == .operatorTyped)
        #expect(block.exitCode == 5)
        #expect(block.durationMs != nil)
        #expect(block.output.contains("a"))
        #expect(block.output.contains("b"))
        #expect(block.heldTheGrid == false)
    }
}

/// User Story 16: four minutes in `vim` is not silently dropped from the
/// history. This works because Wakil scans the RAW stream — the engine
/// discards OSC 133 entirely under the alternate screen.
///
/// **`output` is empty (walk-defects D4).** Before this wave, the bytes
/// between the switch-in and switch-out — `hello` here, mangled screen
/// rows for a real full-screen program — were captured into the block the
/// same as any ordinary command's stdout. The decision recorded against
/// D4 is that the screen was never the command's stdout, so a block that
/// took the alternate screen records its exit code and duration and NO
/// output at all, not a faithful or partial redraw of what it drew.
@Test func aProgramThatTookTheScreenStillLeavesABlockWithNoOutput() async throws {
    let panes = PaneStore()
    try await withTerminalStore(panes: panes) { store in
        _ = try await store.open(
            paneId: "terminal-1", path: NSTemporaryDirectory(), shell: "/bin/bash",
            environment: ["HOME": scratchHome()])

        // Enter the alternate screen, draw, leave — without needing vim.
        await store.write(
            paneId: "terminal-1",
            bytes: Array("printf '\\033[?1049hhello\\033[?1049l'; exit 0\n".utf8))
        try await waitUntil(seconds: 8) {
            await panes.terminalBlocks(paneId: "terminal-1").count >= 1
        }

        let block = try #require(await panes.terminalBlocks(paneId: "terminal-1").first)
        #expect(block.heldTheGrid == true)
        #expect(block.exitCode == 0)
        #expect(block.output.isEmpty, "expected no output, got \(block.output)")
    }
}

/// Colour reaches the pty raw; it must not reach the block. `output` is
/// declared `[String]` — plain text — and stripping at capture is what
/// makes a stored block match that declared type, so an agent reading it
/// sees the words, not the SGR codes that painted them.
@Test func colourEscapesAreStrippedFromCapturedOutput() async throws {
    let panes = PaneStore()
    try await withTerminalStore(panes: panes) { store in
        _ = try await store.open(
            paneId: "terminal-1", path: NSTemporaryDirectory(), shell: "/bin/bash",
            environment: ["HOME": scratchHome()])

        await store.write(
            paneId: "terminal-1",
            bytes: Array("printf '\\033[31mred\\033[0m plain\\n'\n".utf8))
        try await waitUntil(seconds: 8) {
            await panes.terminalBlocks(paneId: "terminal-1").count >= 1
        }

        let block = try #require(await panes.terminalBlocks(paneId: "terminal-1").first)
        #expect(block.output.contains("red plain"))
        for line in block.output {
            #expect(!line.contains("\u{1B}"), "an escape survived in \(line)")
        }
    }
}

/// The paste case a code review constructed by hand: `ls; vim -c q`
/// landing in ONE `read(2)` must not credit `ls` with a switch that
/// happened entirely inside `vim`. Built through `feedForTesting` rather
/// than a live shell — see that method's own doc comment for why only a
/// hand-built chunk can force this split at all.
@Test func anAlternateScreenSwitchIsCreditedToTheCommandThatMadeIt() throws {
    let session = TerminalSession(paneId: "test-pane", shellName: "test-shell", cols: 80, rows: 24)

    func osc(_ body: String) -> String { "\u{1B}]\(body)\u{07}" }
    func commandStart(_ command: String) -> String {
        osc("133;C;wakil_cmd=\(Data(command.utf8).base64EncodedString())")
    }

    let chunk =
        commandStart("ls") + "file1\nfile2\n" + osc("133;D;0")
        + commandStart("vim -c q") + "\u{1B}[?1049h" + "editing" + "\u{1B}[?1049l"
        + osc("133;D;0")
    session.feedForTesting(Array(chunk.utf8))

    let blocks = session.takeCompletedBlocks()
    #expect(blocks.count == 2)
    let ls = try #require(blocks.first { $0.command == "ls" })
    let vim = try #require(blocks.first { $0.command == "vim -c q" })
    // The one true failure this test exists to catch: crediting the
    // WRONG command with a switch that happened in the other one.
    #expect(ls.heldTheGrid == false)
    #expect(vim.heldTheGrid == true)
    // walk-defects D4: `ls`'s own legitimate output survives untouched —
    // this is the "ordinary block is unaffected" half of D4's own test
    // instruction — and `vim`'s is empty, not `"editing"`, even though
    // both landed in the very same `read(2)`-sized chunk as `ls`'s output.
    #expect(ls.output.contains("file1"))
    #expect(ls.output.contains("file2"))
    #expect(vim.output.isEmpty, "expected no output, got \(vim.output)")
}

/// The switch-in sequence itself split across two `read(2)`s — "\x1B[?104"
/// in one `consume`, "9h" in the next — is still caught (walk-defects D4).
/// `TerminalMarkScanner` only holds a sequence back FOR Wakil's own OSC
/// marks; a plain CSI like this one passes through byte by byte, so a
/// split landing mid-sequence is the ordinary case for a 1,024-byte pty
/// read, not an exotic one. The small carry-over window `consume`'s
/// `.output` case keeps is what this exercises.
@Test func anAlternateScreenSwitchSplitAcrossTwoReadsIsStillCaught() throws {
    let session = TerminalSession(paneId: "test-pane", shellName: "test-shell", cols: 80, rows: 24)

    func osc(_ body: String) -> String { "\u{1B}]\(body)\u{07}" }
    func commandStart(_ command: String) -> String {
        osc("133;C;wakil_cmd=\(Data(command.utf8).base64EncodedString())")
    }

    session.feedForTesting(Array((commandStart("vim") + "before").utf8))
    // The switch-in sequence, split across this chunk and the next.
    session.feedForTesting(Array("\u{1B}[?104".utf8))
    session.feedForTesting(Array(("9h" + "editing" + osc("133;D;0")).utf8))

    let blocks = session.takeCompletedBlocks()
    let vim = try #require(blocks.first { $0.command == "vim" })
    #expect(vim.heldTheGrid == true)
    #expect(!vim.output.joined(separator: "\n").contains("editing"))
}

// MARK: - The screen-clear signal (walk-defects D1)

/// zsh's `^L` (the `clear-screen` ZLE widget): no command runs at all, so
/// there are no `C`/`D` marks — the raw `\e[2J` is everything there is.
/// `TerminalSession` must still notice it, because `TerminalStore.publish`
/// is what turns this into "wipe the block history", and it has nothing
/// else to go on for this case.
@Test func aBareScreenClearWithNoCommandRunningIsStillDetected() throws {
    let session = TerminalSession(paneId: "test-pane", shellName: "test-shell", cols: 80, rows: 24)

    // `tput clear`'s own form, confirmed on the fix machine: `\e[H\e[2J`.
    session.feedForTesting(Array("\u{1B}[H\u{1B}[2J".utf8))

    #expect(session.takeScreenCleared() == true)
    #expect(session.takeCompletedBlocks().isEmpty)
    // Taking it clears it — the same take-and-clear contract
    // `takeCompletedBlocks` already has.
    #expect(session.takeScreenCleared() == false)
}

/// `clear` the COMMAND, wrapped in its own `C`/`D` marks like any other
/// command a real shell runs — this is the ordinary case walk-defects D1
/// describes: the escape sequence rides ALONGSIDE the command's own
/// shell-integration marks, not instead of them.
@Test func theClearCommandsOwnEscapeSequenceIsDetectedAlongsideItsBlock() throws {
    let session = TerminalSession(paneId: "test-pane", shellName: "test-shell", cols: 80, rows: 24)

    func osc(_ body: String) -> String { "\u{1B}]\(body)\u{07}" }
    func commandStart(_ command: String) -> String {
        osc("133;C;wakil_cmd=\(Data(command.utf8).base64EncodedString())")
    }

    // `clear | cat -v` on the fix machine: `\e[3J\e[H\e[2J`. `\e[3J`
    // itself is deliberately NOT what this is keyed on — see
    // `TerminalSession.screenClearSequence`'s own doc comment.
    session.feedForTesting(
        Array((commandStart("clear") + "\u{1B}[3J\u{1B}[H\u{1B}[2J" + osc("133;D;0")).utf8))

    let blocks = session.takeCompletedBlocks()
    #expect(blocks.first?.command == "clear")
    #expect(session.takeScreenCleared() == true)
}

/// Walk-defects D4's own trap, applied to D1: a full-screen program clears
/// the screen on the way IN (`vim`'s `smcup` sequence typically redraws
/// immediately after switching), and that must not wipe the block history
/// — the operator's session, not just one block, would be destroyed by
/// opening an editor. Built so the switch-in and the clear land in the
/// SAME chunk, the case most likely to race a chunk-wide guard.
@Test func enteringTheAlternateScreenAndClearingItDoesNotWipeTheHistory() throws {
    let session = TerminalSession(paneId: "test-pane", shellName: "test-shell", cols: 80, rows: 24)

    func osc(_ body: String) -> String { "\u{1B}]\(body)\u{07}" }
    func commandStart(_ command: String) -> String {
        osc("133;C;wakil_cmd=\(Data(command.utf8).base64EncodedString())")
    }

    session.feedForTesting(
        Array((commandStart("vim") + "\u{1B}[?1049h" + "\u{1B}[H\u{1B}[2J" + "editing").utf8))

    #expect(session.takeScreenCleared() == false)

    // And leaving the alternate screen with a genuine clear right after —
    // the operator's own prompt redrawing — still catches it.
    session.feedForTesting(Array(("\u{1B}[?1049l" + osc("133;D;0")).utf8))
    session.feedForTesting(Array("\u{1B}[H\u{1B}[2J".utf8))
    #expect(session.takeScreenCleared() == true)
}

/// The needle itself split across two `read(2)`s — `"\e[2"` in one
/// `consume`, `"J"` in the next — the same possibility
/// `anAlternateScreenSwitchSplitAcrossTwoReadsIsStillCaught` exercises for
/// the alternate-screen switch, here for `screenClearSequence`.
@Test func aScreenClearSplitAcrossTwoReadsIsStillCaught() throws {
    let session = TerminalSession(paneId: "test-pane", shellName: "test-shell", cols: 80, rows: 24)

    session.feedForTesting(Array("\u{1B}[H\u{1B}[2".utf8))
    session.feedForTesting(Array("J".utf8))

    #expect(session.takeScreenCleared() == true)
}

/// The orphan `D`. The generated rc gates its own — `__wakil_in_block` is
/// 0 at the first `precmd` of every session — but that guarantee cannot
/// live only in a shell script Wakil wrote: an `ssh` to a host with its
/// own shell integration, a `tmux`, or a program that simply echoes the
/// bytes produces one, and the scanner forwards every one unconditionally.
@Test func aCommandEndWithNoOpenBlockInventsNothing() async throws {
    let panes = PaneStore()
    try await withTerminalStore(panes: panes) { store in
        _ = try await store.open(
            paneId: "terminal-1", path: NSTemporaryDirectory(), shell: "/bin/bash",
            environment: ["HOME": scratchHome()])

        // A program echoing `ESC]133;D;9` closes the block its own command
        // opened — early, and with someone else's exit code, which is the
        // shell-integration-inside-shell-integration case exactly. The `D`
        // the rc then emits at the next prompt for that same command has
        // no block left to close, and is the orphan under test: kept, it
        // would leave a SECOND block for one submitted line, carrying no
        // command at all.
        await store.write(
            paneId: "terminal-1", bytes: Array("printf '\\033]133;D;9\\007ok\\n'\n".utf8))
        try await waitUntil(seconds: 8) {
            await panes.terminalBlocks(paneId: "terminal-1").count >= 1
        }
        // The rc's own `D` has landed by now; give any orphan-derived
        // second block the same chance to appear.
        try? await Task.sleep(nanoseconds: 500_000_000)

        let blocks = await panes.terminalBlocks(paneId: "terminal-1")
        #expect(blocks.count == 1, "\(blocks.map(\.command))")
        #expect(blocks[0].exitCode == 9)
        #expect(blocks[0].command.hasPrefix("printf"))
    }
}

@Test func theHistoryIsBoundedInBlocksAndSaysSo() async {
    let panes = PaneStore()
    for index in 0..<(TerminalBlock.historyCap + 5) {
        await panes.recordTerminal(paneId: "terminal-1", block: TerminalBlock(
            id: "b\(index)", command: "echo \(index)", origin: .operatorTyped,
            exitCode: 0, durationMs: 1, output: ["\(index)"], heldTheGrid: false,
            startedAt: Date(timeIntervalSince1970: Double(index))))
    }

    let snapshot = await panes.snapshot(paneId: "terminal-1", kind: "terminal")
    guard let terminal = snapshot.terminal else {
        Issue.record("expected a terminal snapshot"); return
    }
    #expect(terminal.blocks.count == TerminalBlock.historyCap)
    // Partiality, carried beside the data rather than inferred from its
    // length: a short history and a trimmed one must never look alike.
    #expect(terminal.blocksTruncated)
    // The OLDEST go, not the newest.
    #expect(terminal.blocks.first?.command == "echo 5")
}

/// Walk-defects D1, at the `PaneStore` level: `clearTerminalBlocks`
/// empties the block history and its truncated flag, and touches NOTHING
/// else about the pane — `cwd`, `shell`, `cols`/`rows`, `grid` and the
/// pending proposal are all facts about the still-running shell, not
/// about a block.
@Test func clearTerminalBlocksEmptiesTheHistoryAndLeavesTheRestOfThePaneAlone() async {
    let panes = PaneStore()
    await panes.setTerminalLiveState(
        paneId: "terminal-1", cwd: "/usr/lib", shell: "zsh", cols: 132, rows: 36,
        screen: .blocks, grid: ["$ "])
    await panes.recordTerminal(paneId: "terminal-1", block: TerminalBlock(
        id: "b1", command: "ls", origin: .operatorTyped, exitCode: 0, durationMs: 1,
        output: ["a.txt"], heldTheGrid: false, startedAt: Date()))
    await panes.setTerminalProposal(paneId: "terminal-1", TerminalBlock(
        id: "terminal-1-proposal", command: "pwd", origin: .proposed, exitCode: nil,
        durationMs: nil, output: [], heldTheGrid: false, startedAt: Date()))

    await panes.clearTerminalBlocks(paneId: "terminal-1")

    #expect(await panes.terminalBlocks(paneId: "terminal-1").isEmpty)
    let snapshot = await panes.snapshot(paneId: "terminal-1", kind: "terminal")
    guard let terminal = snapshot.terminal else {
        Issue.record("expected a terminal snapshot"); return
    }
    #expect(!terminal.blocksTruncated)
    #expect(terminal.cwd == "/usr/lib")
    #expect(terminal.shell == "zsh")
    #expect(terminal.cols == 132)
    #expect(terminal.rows == 36)
    #expect(terminal.grid == ["$ "])
    // The proposal is not a block — it lives in `TerminalContents.proposal`
    // and is only ever folded into `blocks` at `snapshot()` time — so a
    // clear must not discard a command still waiting on the operator's
    // own `⏎`. It is the last item `blocks` here, since `snapshot()`
    // appends it to the tail.
    #expect(terminal.blocks.last?.command == "pwd")
}

@Test func aBlocksOwnOutputIsCappedInLinesAndTheRestIsDropped() async {
    let long = (0..<(TerminalBlock.outputLineCap + 100)).map { "line \($0)" }
    let block = TerminalBlock.capped(
        id: "b1", command: "seq", origin: .operatorTyped, exitCode: 0, durationMs: 1,
        output: long, heldTheGrid: false, startedAt: Date())

    #expect(block.output.count == TerminalBlock.outputLineCap)
    // The TAIL is what is kept: the end of a build's output is where its
    // error is, and a head-truncated block would keep the part nobody is
    // asking about.
    #expect(block.output.last == "line \(TerminalBlock.outputLineCap + 99)")
}

@Test func theSnapshotReturnsBothSurfacesAndNamesTheOneOnScreen() async {
    let panes = PaneStore()
    await panes.setTerminalLiveState(
        paneId: "terminal-1", cwd: "/usr/lib", shell: "zsh", cols: 132, rows: 36,
        screen: .grid, grid: ["one", "two"])
    await panes.recordTerminal(paneId: "terminal-1", block: TerminalBlock(
        id: "b1", command: "make", origin: .operatorTyped, exitCode: 1, durationMs: 90,
        output: ["boom"], heldTheGrid: false, startedAt: Date()))

    let snapshot = await panes.snapshot(paneId: "terminal-1", kind: "terminal")
    guard let terminal = snapshot.terminal else {
        Issue.record("expected a terminal snapshot"); return
    }
    // Returning only the AUTHORITATIVE surface breaks the rule this
    // defends: an agent that read the blocks a moment ago would find them
    // gone because `vim` opened — exactly when it is most likely to be
    // asked what went wrong in the build behind the pager.
    #expect(terminal.screen == .grid)
    #expect(terminal.grid == ["one", "two"])
    #expect(terminal.blocks.count == 1)
    #expect(terminal.cwd == "/usr/lib")
    #expect(terminal.cols == 132)
}

@Test func theTerminalWireFormCarriesEveryKeyOfItsKind() async {
    let panes = PaneStore()
    await panes.setTerminalLiveState(
        paneId: "terminal-1", cwd: "/tmp", shell: "bash", cols: 80, rows: 24,
        screen: .blocks, grid: [])
    await panes.recordTerminal(paneId: "terminal-1", block: TerminalBlock(
        id: "b1", command: "ls", origin: .proposed, exitCode: nil, durationMs: nil,
        output: [], heldTheGrid: false, startedAt: Date()))

    guard case .object(let wire) = await panes.readPane(paneId: "terminal-1", kind: "terminal"),
          case .array(let blocks)? = wire["blocks"],
          case .object(let first) = blocks[0] else {
        Issue.record("bad wire form"); return
    }
    for key in ["kind", "failure", "screen", "cwd", "shell", "cols", "rows",
                "blocks", "blocksTruncated", "grid", "scrollTarget"] {
        #expect(wire[key] != nil, "missing \(key)")
    }
    for key in ["id", "command", "origin", "exitCode", "durationMs", "output", "heldTheGrid"] {
        #expect(first[key] != nil, "missing block key \(key)")
    }
    // `proposed` is what earns the field: without it the agent cannot tell
    // whether its own proposal was accepted, discarded, or still sitting
    // there — the single thing it most needs to read this pane for.
    #expect(first["origin"] == .string("proposed"))
    #expect(first["exitCode"] == .null)
    // Nothing is emitted yet for `scrollTarget`, and it is emitted anyway.
    #expect(wire["scrollTarget"] == .null)
    // And a terminal pane emits none of the thirteen tabular keys. `rows`
    // is deliberately NOT one of the probes here: a terminal pane has its
    // own `rows` — the pty's height — and asserting its absence would
    // contradict the key list above.
    #expect(wire["rowCount"] == nil)
    #expect(wire["columnTypesInferred"] == nil)
    #expect(wire["pageable"] == nil)
    #expect(wire["listsTables"] == nil)
}

/// A block a `pane_close` interrupts still exists, carrying a null exit
/// code — *the shell was killed before it reported*, never *it succeeded*.
@Test func aBlockStillRunningAtTeardownIsSealedWithNoExitCode() async throws {
    let panes = PaneStore()
    try await withTerminalStore(panes: panes) { store in
        _ = try await store.open(
            paneId: "terminal-1", path: NSTemporaryDirectory(), shell: "/bin/bash",
            environment: ["HOME": scratchHome()])

        await store.write(paneId: "terminal-1", bytes: Array("sleep 45\n".utf8))
        // Wait for the `C` that opens the block, not for output: `sleep`
        // produces none.
        try await waitUntil(seconds: 8) {
            await store.marksForTesting("terminal-1").contains {
                if case .commandStart(let c) = $0 { return c == "sleep 45" } else { return false }
            }
        }

        await store.close(paneId: "terminal-1")

        let blocks = await panes.terminalBlocks(paneId: "terminal-1")
        let sleeping = try #require(blocks.first { $0.command == "sleep 45" })
        #expect(sleeping.exitCode == nil)
        #expect(sleeping.durationMs != nil)
    }
}

/// The publisher stops when no pane holds a shell and starts again when
/// one does — otherwise a store that has been idle publishes nothing for
/// the rest of the process's life.
@Test func thePublisherRestartsForAPaneOpenedAfterTheLastOneClosed() async throws {
    let panes = PaneStore()
    try await withTerminalStore(panes: panes) { store in
        _ = try await store.open(
            paneId: "terminal-1", path: NSTemporaryDirectory(), shell: "/bin/bash",
            environment: ["HOME": scratchHome()])
        await store.close(paneId: "terminal-1")
        // Long enough for the loop to have found `sessions` empty, decided
        // to stop, and cleared its own slot.
        try? await Task.sleep(nanoseconds: 200_000_000)

        _ = try await store.open(
            paneId: "terminal-2", path: NSTemporaryDirectory(), shell: "/bin/bash",
            environment: ["HOME": scratchHome()])
        await store.write(paneId: "terminal-2", bytes: Array("echo restarted\n".utf8))

        try await waitUntil(seconds: 8) {
            await panes.terminalBlocks(paneId: "terminal-2")
                .contains { $0.command == "echo restarted" }
        }
    }
}

/// `markNextRunProposed` is matched on the command, and consumed once.
@Test func aProposedRunIsFlaggedOnceAndOnlyForTheCommandThatWasProposed() async {
    let store = TerminalStore(scratchRoot: testScratchRoot)

    await store.markNextRunProposed(paneId: "terminal-1", command: "make test")
    #expect(await store.takeProposedFlag(for: "terminal-1", command: "make test"))
    // Consumed: the next run is the operator's own.
    #expect(!(await store.takeProposedFlag(for: "terminal-1", command: "make test")))

    // Edited before Enter is a different command, and the flag goes with
    // it rather than attaching itself to whatever runs next.
    await store.markNextRunProposed(paneId: "terminal-1", command: "make test")
    #expect(!(await store.takeProposedFlag(for: "terminal-1", command: "make test -v")))
    #expect(!(await store.takeProposedFlag(for: "terminal-1", command: "make test")))
}

/// Every finished command reaches the run stream, with the pane, the cwd
/// and the exit code the journal needs.
@Test func everyFinishedCommandReachesTheRunStream() async throws {
    let panes = PaneStore()
    try await withTerminalStore(panes: panes) { store in
        let runs = await store.completedRuns()
        let collected = CollectedRuns()
        // Drained into a collector rather than awaited inline: a bare
        // `for await` on a stream that never yields has no deadline, and a
        // test that hangs takes the whole parallel suite with it.
        let pump = Task { for await run in runs { await collected.append(run) } }
        defer { pump.cancel() }

        _ = try await store.open(
            paneId: "terminal-1", path: NSTemporaryDirectory(), shell: "/bin/bash",
            environment: ["HOME": scratchHome()])

        await store.markNextRunProposed(paneId: "terminal-1", command: "echo proposed")
        await store.write(paneId: "terminal-1", bytes: Array("echo proposed\n".utf8))

        try await waitUntil(seconds: 8) { await collected.named("echo proposed") != nil }
        let run = try #require(await collected.named("echo proposed"))
        #expect(run.paneId == "terminal-1")
        #expect(run.command == "echo proposed")
        #expect(run.exitCode == 0)
        #expect(run.wasProposed)
        #expect(!run.cwd.isEmpty)
    }
}

/// A second subscriber must not strand the first. Replacing the stored
/// continuation without finishing the outgoing one first leaves the
/// FIRST caller's `for await` with nothing left to ever yield or finish
/// it — a silent, undiagnosable hang, the exact failure class this
/// session has already lost hours to. `.timeLimit` is what turns a
/// regression of that back into a fast failure instead of a wedged
/// suite: with the fix, the first stream ends as soon as the second is
/// requested; without it, this test would hang for the full minute.
@Test(.timeLimit(.minutes(1)))
func aSecondSubscriberFinishesTheFirstRatherThanStrandingIt() async throws {
    let store = TerminalStore(scratchRoot: testScratchRoot)

    let first = await store.completedRuns()
    _ = await store.completedRuns()  // supersedes `first`'s continuation

    // If the fix regressed, this `for await` never returns and the
    // `.timeLimit` above fails the test rather than the whole suite.
    for await _ in first {
        Issue.record("the superseded stream yielded a run instead of ending")
    }
}

/// A second `term_open` on a pane starts a new history: the old blocks
/// belonged to a process that no longer exists.
@Test func reopeningAPaneStartsANewHistory() async throws {
    let panes = PaneStore()
    try await withTerminalStore(panes: panes) { store in
        _ = try await store.open(
            paneId: "terminal-1", path: NSTemporaryDirectory(), shell: "/bin/bash",
            environment: ["HOME": scratchHome()])
        await store.write(paneId: "terminal-1", bytes: Array("echo first\n".utf8))
        try await waitUntil(seconds: 8) {
            await panes.terminalBlocks(paneId: "terminal-1")
                .contains { $0.command == "echo first" }
        }

        _ = try await store.open(
            paneId: "terminal-1", path: NSTemporaryDirectory(), shell: "/bin/bash",
            environment: ["HOME": scratchHome()])

        #expect(await panes.terminalBlocks(paneId: "terminal-1").isEmpty)
    }
}

// MARK: - `clear` wipes the block history too, end to end (walk-defects D1)

/// The whole point, through a real shell rather than `feedForTesting`: a
/// block that existed before `clear` ran is gone afterwards, and `clear`
/// leaves no block of its own either — no `✓ clear · … ms` line, which is
/// the operator's own complaint this fixes ("clear clears only the
/// bottom half"). `panes.terminalBlocks` is exactly what `read_pane`
/// answers from (`PaneStore.terminal(paneId).blocks`, via
/// `PaneSnapshotJSON`), so this is also the "the operator's screen and
/// the agent's reading of it must not disagree" half of the fix.
@Test func aRealClearEmptiesTheBlockHistoryAndLeavesNoBlockOfItsOwn() async throws {
    let panes = PaneStore()
    try await withTerminalStore(panes: panes) { store in
        _ = try await store.open(
            paneId: "terminal-1", path: NSTemporaryDirectory(), shell: "/bin/bash",
            environment: ["HOME": scratchHome()])

        await store.write(paneId: "terminal-1", bytes: Array("echo first\n".utf8))
        try await waitUntil(seconds: 8) {
            await panes.terminalBlocks(paneId: "terminal-1")
                .contains { $0.command == "echo first" }
        }

        await store.write(paneId: "terminal-1", bytes: Array("clear\n".utf8))
        try await waitUntil(seconds: 8) {
            await panes.terminalBlocks(paneId: "terminal-1").isEmpty
        }

        // Give the publisher a few more poll passes and confirm it STAYS
        // empty — the wipe is not a transient flicker on the way to
        // `clear` earning its own block after all.
        try await Task.sleep(nanoseconds: 200_000_000)
        let blocks = await panes.terminalBlocks(paneId: "terminal-1")
        #expect(blocks.isEmpty, "expected no blocks, got \(blocks.map(\.command))")
    }
}

/// The D4 trap, end to end: a full-screen program's own entry redraw must
/// not take the earlier block history with it. Built with `printf`
/// rather than a real `vim`, exactly like
/// `aProgramThatTookTheScreenStillLeavesABlockWithNoOutput` above, for the
/// same reason — this only needs the two escape sequences, not an editor.
@Test func enteringTheAlternateScreenLeavesEarlierBlocksInPlace() async throws {
    let panes = PaneStore()
    try await withTerminalStore(panes: panes) { store in
        _ = try await store.open(
            paneId: "terminal-1", path: NSTemporaryDirectory(), shell: "/bin/bash",
            environment: ["HOME": scratchHome()])

        await store.write(paneId: "terminal-1", bytes: Array("echo first\n".utf8))
        try await waitUntil(seconds: 8) {
            await panes.terminalBlocks(paneId: "terminal-1")
                .contains { $0.command == "echo first" }
        }

        // Enters the alternate screen and clears it on the way in — the
        // same shape `vim`'s own `smcup` sequence takes.
        await store.write(
            paneId: "terminal-1",
            bytes: Array("printf '\\033[?1049h\\033[H\\033[2Jhello\\033[?1049l'; exit 0\n".utf8))
        try await waitUntil(seconds: 8) {
            await panes.terminalBlocks(paneId: "terminal-1")
                .contains { $0.heldTheGrid == true }
        }

        let blocks = await panes.terminalBlocks(paneId: "terminal-1")
        #expect(blocks.contains { $0.command == "echo first" })
    }
}

// MARK: - Helpers

/// What a test's run-stream pump has seen so far.
private actor CollectedRuns {
    private var runs: [TerminalRun] = []
    func append(_ run: TerminalRun) { runs.append(run) }
    func named(_ command: String) -> TerminalRun? { runs.first { $0.command == command } }
}

/// Runs `body` against a fresh `TerminalStore` and **reaps that store on
/// every path out** — normal return, a `try #require` that threw, a
/// cancelled `Task.sleep` inside `waitUntil`.
///
/// **A fixture rather than a line each test remembers, because eight of
/// them forgot.** Eight live-shell tests opened a pane and never closed
/// it, so eight interactive shells stayed children of the test process for
/// the rest of the run. That was not a cosmetic leak: a shell inherits
/// every descriptor the parent held at `fork` time, so those eight sat on
/// duplicates of `MCPClient`'s stdio pipes and `MCPServer`'s connection
/// sockets, the pipes never reached EOF, the drain threads joined by
/// `stop()` never returned, and the whole parallel suite wedged — measured
/// four times, and reproduced here at 0.02s of CPU per 10s with three
/// threads parked in `read(2)` on pipes whose write ends `lsof` traced to
/// live `wakil-terminal-*` shells. `TerminalSession.spawn` now closes the
/// inherited descriptors, which is what fixes the wedge; this is what
/// stops the leak itself, and with it the orphaned shells an interrupted
/// run used to strand holding their ptys.
///
/// **It does not replace a test's own `close`.** The tests that close a
/// pane explicitly are asserting what `close` does; this only guarantees
/// that whatever they did or failed to do, no shell outlives the test —
/// which is this sub-phase's exit criterion, applied to the suite that
/// defends it.
///
/// **Not `private`.** Task 10's `TerminalActionsTests` opens a store
/// through `term_open` and must reap it exactly the same way — a second,
/// slightly different copy of this fixture is exactly how one test file
/// stops leaking shells while its neighbour keeps doing it.
func withTerminalStore<T>(
    panes: PaneStore? = nil,
    _ body: (TerminalStore) async throws -> T
) async rethrows -> T {
    let store = TerminalStore(scratchRoot: testScratchRoot, panes: panes)
    do {
        let value = try await body(store)
        await store.shutdownAll()
        return value
    } catch {
        await store.shutdownAll()
        throw error
    }
}

/// Polls `condition` until it holds or `seconds` elapse. A shell's echo
/// arrives when it arrives; a fixed sleep either flakes or wastes the
/// 0.073s this whole round trip actually costs.
///
/// `seconds` is the budget for a **healthy, idle** run and is scaled by
/// `testWaitLoadMultiplier` for the contention of the full suite — see
/// that constant for the measurement, and for why 8s here was a false red
/// rather than a broken test (#127).
private func waitUntil(
    seconds: Double, _ condition: @Sendable () async -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(seconds * testWaitLoadMultiplier)
    while Date() < deadline {
        if await condition() { return }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    Issue.record("condition did not hold within \(seconds)s")
}

/// A fresh `HOME` with no dotfiles in it, for the tests that only care
/// about a shell starting, echoing and dying — not about the operator's
/// own configuration.
///
/// **Without this, Task 7's rc made every one of these sensitive to
/// whoever's machine runs the suite.** The generated rc sources
/// `$HOME/.bashrc` (bash) and, via `WAKIL_USER_ZDOTDIR`, the real
/// `~/.zshrc` — so once that rc was wired in, a bare `store.open` here
/// stopped being hermetic: it started running the operator's real shell
/// configuration, which can be slow, can print unexpected output these
/// tests do not look for, and can spawn rc-installed helpers that join
/// the pane's session and give teardown more to clean up against its
/// 2-second deadline. A directory with nothing in it sidesteps all three.
private func scratchHome() -> String {
    let dir = testScratchRoot.appendingPathComponent("wakil-scratch-home-\(UUID().uuidString)").path
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

/// The lines a shell wrote to `path`, or nil while the file is missing or
/// empty. Trailing blank lines are dropped so a final newline does not
/// count as a line.
private func readLines(_ path: String) -> [String]? {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    var lines = text.components(separatedBy: "\n")
    while lines.last?.isEmpty == true { lines.removeLast() }
    return lines.isEmpty ? nil : lines
}

/// The pid a shell wrote to `path`, or nil while the file is missing,
/// empty, or half-written.
private func readPid(_ path: String) -> pid_t? {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let value = pid_t(trimmed), value > 0 else { return nil }
    return value
}

// MARK: - The live screen is published on the blocks surface too (C2)

/// **What the operator is typing, before anything has run.** The pane
/// published `grid: []` whenever a full-screen program was not holding the
/// screen, on the argument that the rows are already in the blocks — true
/// of a row that is already IN a block, and false of the prompt, of the
/// characters being typed into it, and of a running command's output. The
/// operator typed blind and `read_pane` answered `grid: []` while
/// `TerminalSnapshot`'s own doc comment promised both surfaces always.
///
/// Deliberately written with **no newline**: nothing has run, so no block
/// exists and the grid is the only surface these characters can be on. A
/// test that ran the command would pass against the old behaviour too.
@Test func theVisibleScreenIsPublishedWhileTheBlocksSurfaceIsTheOneOnTop() async throws {
    let panes = PaneStore()
    try await withTerminalStore(panes: panes) { store in
        _ = try await store.open(
            paneId: "terminal-1", path: NSTemporaryDirectory(), shell: "/bin/bash",
            environment: ["HOME": scratchHome()])

        await store.write(paneId: "terminal-1", bytes: Array("echo still-typing".utf8))

        try await waitUntil(seconds: 8) {
            guard let snapshot =
                (await panes.snapshot(paneId: "terminal-1", kind: "terminal")).terminal
            else { return false }
            return snapshot.screen == .blocks
                && snapshot.grid.contains { $0.contains("still-typing") }
        }
        // Nothing ran: the ONLY surface those characters can be on is the
        // grid, which is the point.
        #expect(await panes.terminalBlocks(paneId: "terminal-1").isEmpty)
    }
}

// MARK: - The two walk-fix seams: promptRow and the cursor

/// `promptRow` and the cursor are both published on the snapshot, in the
/// same coordinate space as `grid` — the two seams the walk-defects list
/// asked to be picked up: "the screen row where the current prompt
/// began", and "the cursor position", both needed so the pane can narrow
/// its live region and draw a cursor at all (`TerminalPaneSupport.swift`'s
/// `terminalLiveRegion`/`terminalCursorLocation`, which already accept
/// both as parameters and were only ever fed `nil`).
@Test func promptRowAndCursorAreProjectedOntoTheSnapshot() async throws {
    let panes = PaneStore()
    try await withTerminalStore(panes: panes) { store in
        _ = try await store.open(
            paneId: "terminal-1", path: NSTemporaryDirectory(), shell: "/bin/bash",
            environment: ["HOME": scratchHome()])

        // A prompt has to have printed at least once before `promptRow`
        // is anything but `nil`.
        try await waitUntil(seconds: 8) {
            guard let snapshot =
                (await panes.snapshot(paneId: "terminal-1", kind: "terminal")).terminal
            else { return false }
            return snapshot.promptRow != nil
        }

        // Typing (no newline: nothing has run) moves the cursor off column
        // 0 without moving it to a new row — it is still on the prompt
        // `promptRow` names.
        await store.write(paneId: "terminal-1", bytes: Array("echo hi".utf8))
        try await waitUntil(seconds: 8) {
            guard let snapshot =
                (await panes.snapshot(paneId: "terminal-1", kind: "terminal")).terminal
            else { return false }
            return (snapshot.cursorCol ?? 0) > 0
        }

        guard let snapshot =
            (await panes.snapshot(paneId: "terminal-1", kind: "terminal")).terminal
        else { Issue.record("no terminal snapshot"); return }
        #expect(snapshot.promptRow != nil)
        #expect(snapshot.cursorRow == snapshot.promptRow)
    }
}

/// Walk finding (#365 walk, 2026-10-09): → did not move the drawn cursor,
/// and the next ← made it jump. zsh moves right with `ESC[C`, which
/// SwiftTerm does not count as a screen change, and the store published
/// only on a change — so a cursor that moved and nothing else stayed
/// unpublished until the next ← (a `\b`, which does count).
@Test func aCursorThatMovesWithoutRedrawingIsStillPublished() async throws {
    let panes = PaneStore()
    try await withTerminalStore(panes: panes) { store in
        _ = try await store.open(
            paneId: "terminal-1", path: NSTemporaryDirectory(), shell: "/bin/zsh",
            environment: ["HOME": scratchHome()])
        @Sendable func cursorCol() async -> Int? {
            guard let snapshot =
                (await panes.snapshot(paneId: "terminal-1", kind: "terminal")).terminal
            else { return nil }
            return snapshot.cursorCol
        }
        try await waitUntil(seconds: 8) { await store.inputLine("terminal-1") != nil }
        await store.write(paneId: "terminal-1", bytes: Array("echo abc".utf8))
        try await waitUntil(seconds: 8) { await store.screenContains("terminal-1", "echo abc") }
        let end = try #require(await store.inputLine("terminal-1")?.cursor.col)
        try await waitUntil(seconds: 8) { await cursorCol() == end }

        await store.write(paneId: "terminal-1", bytes: Array("\u{1B}[D\u{1B}[D".utf8))
        try await waitUntil(seconds: 8) { await cursorCol() == end - 2 }
        await store.write(paneId: "terminal-1", bytes: Array("\u{1B}[C".utf8))
        try await waitUntil(seconds: 8) { await cursorCol() == end - 1 }
        #expect(await cursorCol() == end - 1)
    }
}

/// e2e `bg-org-switch-keeps-the-terminal` (2026-10-17): a `tail -f` read `commandRunning` false
/// for as long as it ran. zsh's preexec writes the `C` mark after the line's own newline, and an
/// OSC dirties no row and moves no cursor — so a pass that published the newline before the mark
/// was parsed left the pane saying "idle" until the command printed something, which `tail -f`
/// on an empty file never does. A command starting is a change of its own.
@Test func aCommandStartThatRedrawsNothingIsStillPublished() async throws {
    let panes = PaneStore()
    try await withTerminalStore(panes: panes) { store in
        _ = try await store.open(
            paneId: "terminal-1", path: NSTemporaryDirectory(), shell: "/bin/zsh",
            environment: ["HOME": scratchHome()])
        @Sendable func published() async -> TerminalSnapshot? {
            (await panes.snapshot(paneId: "terminal-1", kind: "terminal")).terminal
        }
        try await waitUntil(seconds: 8) { await store.inputLine("terminal-1") != nil }
        try await waitUntil(seconds: 8) { await published()?.promptRow != nil }
        #expect(await published()?.commandRunning == false)

        let mark = "\u{1B}]133;C;wakil_cmd=\(Data("tail -f x".utf8).base64EncodedString())\u{07}"
        await store.feedForTesting("terminal-1", Array(mark.utf8))
        try await waitUntil(seconds: 8) { await published()?.commandRunning == true }
        #expect(await published()?.commandRunning == true)
    }
}

/// Before a shell has ever published a prompt or a cursor — a pane with
/// no live state yet, `PaneStore.empty`'s own shape — all three are
/// `nil`, not a fabricated `0`. A drawn cursor at row/col 0 on a pane that
/// has published nothing would be worse than no cursor at all.
@Test func promptRowAndCursorAreNilBeforeAnyShellHasPublished() async {
    let panes = PaneStore(kinds: PaneKinds.standard)
    let snapshot = await panes.snapshot(paneId: "terminal-1", kind: "terminal")
    guard let terminal = snapshot.terminal else {
        Issue.record("no terminal snapshot"); return
    }
    #expect(terminal.promptRow == nil)
    #expect(terminal.cursorRow == nil)
    #expect(terminal.cursorCol == nil)
}

// MARK: - The write side is bounded (final review, Important 1)

/// **A shell that has stopped reading its tty must not wedge the actor.**
/// The write side used to be a bare blocking `write(2)` called on
/// `TerminalStore`'s own executor, so a write a pty declined to accept —
/// an accepted proposal larger than the line discipline will take, and
/// nothing caps a proposal's length — could park the actor, taking the
/// 60 Hz publisher, every other pane's `close`, the org switch and app
/// quit with it. Task 7 fixed exactly this shape on the READ side; the
/// ledger deferred the write side to a task that never existed.
///
/// **Two claims, because only one of them is reproducible here.** The
/// master being non-blocking is what makes any bound possible at all — a
/// process already parked inside `write(2)` cannot check a deadline — and
/// that is asserted directly. The wedge itself could not be provoked on
/// this platform: 16 MB written into a `sleep 100`, in canonical mode and
/// again in raw mode, was accepted in well under a second, because the pty
/// line discipline discards input it has no room for rather than pushing
/// back on the writer. So the give-up branch is covered by construction
/// (a deadline and a `stopRequested` check between attempts) rather than
/// by a measured stall, and what is measured here is that a very large
/// write into a shell that is not reading returns promptly and leaves the
/// actor answering.
@Test func aWriteToAShellThatIsNotReadingIsBoundedAndLeavesTheActorAnswering() async throws {
    try await withTerminalStore { store in
        _ = try await store.open(
            paneId: "terminal-1", path: NSTemporaryDirectory(), shell: "/bin/bash",
            environment: ["HOME": scratchHome()])
        // Without this the deadline in `writeToPty` is decoration: the
        // thread is inside `write(2)` before it can be consulted.
        #expect(await store.masterIsNonBlockingForTesting(paneId: "terminal-1"))

        await store.write(paneId: "terminal-1", bytes: Array("sleep 100\n".utf8))
        try await waitUntil(seconds: 5) { await store.screenContains("terminal-1", "sleep 100") }

        let start = Date()
        // A megabyte with no newline in it: canonical mode will not hand a
        // partial line to anyone, and nothing is reading anyway.
        await store.write(paneId: "terminal-1", bytes: [UInt8](repeating: 0x61, count: 1 << 20))
        let elapsed = Date().timeIntervalSince(start)

        #expect(
            elapsed < TerminalSession.writeDeadlineSeconds + 3,
            "the write did not give up — this is the wedge, measured")
        // Still answering, which is the whole claim.
        #expect(await store.isRunning(paneId: "terminal-1"))
        // Whatever it could not deliver is recorded rather than lost. On
        // this platform nothing was, which is itself the answer.
        for abandoned in await store.abandonedWrites {
            #expect(abandoned.unwritten > 0)
            #expect(abandoned.paneId == "terminal-1")
        }
        await store.close(paneId: "terminal-1")
    }
}

/// The ordinary write is untouched by the bound: it completes, and nothing
/// is recorded as abandoned.
@Test func anOrdinaryWriteReachesTheShellAndRecordsNoAbandonedBytes() async throws {
    try await withTerminalStore { store in
        _ = try await store.open(
            paneId: "terminal-1", path: NSTemporaryDirectory(), shell: "/bin/bash",
            environment: ["HOME": scratchHome()])

        await store.write(paneId: "terminal-1", bytes: Array("echo wakil-bounded\n".utf8))

        try await waitUntil(seconds: 5) {
            await store.screenContains("terminal-1", "wakil-bounded")
        }
        #expect(await store.abandonedWrites.isEmpty)
    }
}

// MARK: - The escape stripper preserves what it cannot parse (ledger T9-a)

/// **An escape that never terminates before the buffer ends is preserved
/// as text, not consumed to the end of it.** Both branches of the stripper
/// used to run their cursor to the end and set the index past it, so a
/// truncated or malformed sequence near the end of a block's captured
/// output silently ate every real byte after it — out of the text an LLM
/// then reads as that command's output, with nothing downstream able to
/// tell it happened.
///
/// The chunk below is the reachable shape: a CSI whose every following
/// byte is a parameter byte (digits and `:` are all below `0x40`), so the
/// scan never finds a final byte and the timestamp after it is real text
/// with nothing to mark it as anything else. Preserving is the rule
/// `TerminalMarkScanner` already follows when its own pending buffer
/// overflows its cap.
@Test func anUnterminatedEscapePreservesTheTextThatFollowsIt() throws {
    let session = TerminalSession(paneId: "test-pane", shellName: "test-shell", cols: 80, rows: 24)
    func osc(_ body: String) -> String { "\u{1B}]\(body)\u{07}" }
    func commandStart(_ command: String) -> String {
        osc("133;C;wakil_cmd=\(Data(command.utf8).base64EncodedString())")
    }

    let chunk = commandStart("report")
        + "elapsed\n\u{1B}[12:34:56\n"
        + osc("133;D;0")
    session.feedForTesting(Array(chunk.utf8))

    let block = try #require(session.takeCompletedBlocks().first)
    #expect(block.output.contains { $0.contains("12:34:56") },
            "real trailing text was eaten by an unterminated escape: \(block.output)")
    #expect(block.output.contains { $0.contains("elapsed") })
}
