import Testing
import Foundation
@testable import WakilKit

private func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)          // app/Tests/WakilKitTests/MCPClientTests.swift
        .deletingLastPathComponent()          // WakilKitTests
        .deletingLastPathComponent()          // Tests
        .deletingLastPathComponent()          // app
        .deletingLastPathComponent()          // repo root
}

@Test func listToolsReturnsWakilCtxToolSet() async throws {
    let bin = repoRoot().appendingPathComponent("bin/wakil-ctx")
    try #require(FileManager.default.isExecutableFile(atPath: bin.path),
                 "run `make build` first")

    let home = testScratchRoot.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

    let c = MCPClient(executable: bin, arguments: [],
                      environment: ["HOME": home.path, "WAKIL_ORG": "probe", "PATH": "/usr/bin:/bin"])
    try await c.start()
    let tools = try await c.listTools().map(\.name).sorted()
    await c.stop()

    // set_provider added by Phase 2b-vi Task 9 — the write half of
    // active.json's fourth axis (Task 7); see cmd/wakil-ctx/main.go.
    // list_providers added by Phase 2b-vi Task 12 — the picker's own
    // source of what an org has registered to switch to.
    // list_orgs and create_org added by Phase 2b-viii for the org plane's
    // Choosing and Creating states.
    // list_machine_providers and adopt_provider added by Phase 2b-viii for
    // the org plane's Adopting state, which binds an account that already
    // exists on the machine into another organisation via shared registration.
    // set_local_provider added by 3b-viii for a local model endpoint (Decision 42).
    // connection_* and jira_token_set added by Connections Task 2: the Settings pane's
    // connections and their browser sign-in.
    // The pin grows with the server, layer by layer. It is here because
    // the Swift side speaks to whatever binary `bin/` holds, and
    // `make app-test` does not depend on `make build` — so a tool added
    // in Go without landing here is a suite that keeps passing against
    // yesterday's server and says nothing.
    #expect(tools == ["add_provider", "adopt_provider", "capacity", "config_tree",
                      "connection_add", "connection_allow_set", "connection_catalog", "connection_remove",
                      "connection_secrets_set", "connection_signin_start", "connection_signin_wait",
                      "connection_signout", "connection_update", "create_environment",
                      "create_org", "create_project", "derive_config_dir", "editor_settings", "get_context", "get_session",
                      "git_account_add", "git_account_remove", "git_account_test", "git_device_poll",
                      "git_device_start", "git_gh_import", "git_gh_logins", "git_host_suggestions",
                      "git_key_generate", "git_key_passphrase_set", "git_ssh_keys", "git_token_set", "jira_token_set",
                      "list_accounts", "list_environments", "list_machine_providers",
                      "list_orgs", "list_projects", "list_providers", "list_sessions",
                      "read_session", "record_capacity", "record_session_parent", "remove_api_entry", "remove_database",
                      "remove_environment", "remove_project", "rename_environment", "rename_project",
                      "set_api_entry", "set_database_connection", "set_database_dsn", "set_editor_settings", "set_environment", "set_local_provider",
                      "set_project", "set_project_agent_instructions",
                      "set_project_editor_settings", "set_provider", "unlink_provider", "update_api_entry",
                      "update_database", "update_org"])
}

@Test func callToolSurfacesAServerSideErrorRatherThanHanging() async throws {
    let bin = repoRoot().appendingPathComponent("bin/wakil-ctx")
    try #require(FileManager.default.isExecutableFile(atPath: bin.path))
    let home = testScratchRoot.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

    let c = MCPClient(executable: bin, arguments: [],
                      environment: ["HOME": home.path, "WAKIL_ORG": "probe", "PATH": "/usr/bin:/bin"])
    try await c.start()
    // No project is registered under org "probe", so this must report an error, not hang.
    let out = try await c.callTool(
        name: "get_context", arguments: .object([:]), timeout: MCPClient.readReplyTimeout)
    await c.stop()
    #expect(out != .null)
}

@Test func clientSurvivesStopThenStartAndAnswersForTheNewOrg() async throws {
    let bin = repoRoot().appendingPathComponent("bin/wakil-ctx")
    try #require(FileManager.default.isExecutableFile(atPath: bin.path),
                 "run `make build` first")

    let home = testScratchRoot.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

    let client = MCPClient(
        executable: bin, arguments: [],
        environment: ["HOME": home.path, "WAKIL_ORG": "alpha", "PATH": "/usr/bin:/bin"])

    try await client.start()
    _ = try await client.listTools()
    await client.stop()

    // The whole point: a second start on the SAME instance. Before the
    // reset in start(), this threw .transportClosed — the client
    // rejecting its own handshake against an error latched by the
    // PREVIOUS child's EOF.
    try await client.start(environment: ["HOME": home.path, "WAKIL_ORG": "beta", "PATH": "/usr/bin:/bin"])
    let tools = try await client.listTools()
    #expect(!tools.isEmpty)
    await client.stop()
}

// Regression test for a fix-round-1 finding: `start(environment:)`'s
// parameter shadows the actor's `environment` property inside the
// function body, so `process.environment = environment` on the line that
// actually spawns the child read the PARAMETER rather than the property.
// On a plain `start()` (no argument) that parameter is `nil`, so
// `process.environment` was set to `nil` and Foundation made the child
// inherit the TEST PROCESS's own environment — which has no `WAKIL_ORG` —
// instead of the environment passed to `init`. The line was fixed to read
// `self.environment` explicitly. `clientSurvivesStopThenStartAndAnswersForTheNewOrg`
// above cannot catch this because it passes an explicit `environment` on
// both `start()` calls; this test exercises the plain, argument-less
// `start()` that every pre-existing call site uses.
@Test func plainStartUsesTheStoredEnvironmentNotAShadowingParameter() async throws {
    let bin = repoRoot().appendingPathComponent("bin/wakil-ctx")
    try #require(FileManager.default.isExecutableFile(atPath: bin.path),
                 "run `make build` first")

    let home = testScratchRoot.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

    let c = MCPClient(executable: bin, arguments: [],
                      environment: ["HOME": home.path, "WAKIL_ORG": "probe", "PATH": "/usr/bin:/bin"])
    try await c.start()
    let out = try await c.callTool(
        name: "get_context", arguments: .object([:]), timeout: MCPClient.readReplyTimeout)
    await c.stop()

    guard case .object(let result) = out, case .array(let content)? = result["content"],
        case .object(let block)? = content.first, case .string(let text)? = block["text"]
    else {
        Issue.record("get_context result has no text content block: \(out)")
        return
    }
    // If the child inherited the test process's environment instead of
    // the one given to `init`, WAKIL_ORG would be unset and this exact
    // sentence (internal/wakilcore/paths.go) would come back instead of
    // an org-scoped "no project registered" error.
    #expect(!text.contains("WAKIL_ORG is not set"))
}

// Regression test for a deadlock found in review: `stop()` used to call
// `Process.waitUntilExit()`, which blocks the calling thread, from this
// actor's async context. A single blocked thread does not reliably exhaust
// Swift's cooperative executor pool (this machine has 8 cores), so a
// serial loop of `start()`/`stop()` cycles did not reproduce the hang
// consistently. Running cycles concurrently, so multiple `stop()` calls
// can be blocked in `waitUntilExit()` on the pool at the same time, is a
// much stronger reproducer: measured on this machine across 6 back-to-back
// runs of exactly this test body with `stop()` temporarily reverted to
// `process.waitUntilExit()`, 1 run hung permanently (killed after 75s
// wall-clock) and 1 more failed via a 10-second per-request timeout inside
// `start()` (the same pool starvation, just severe enough to stall a
// request rather than deadlock `stop()` outright), against 4 of 6 that
// happened to complete anyway -- this is a starvation race, not a
// certainty, so no fixed cycle/lane count can promise 100% reproduction.
// With the fix below (this file's current, non-reverted `stop()`), the
// same test body completed in well under a second on all of 8 back-to-back
// runs.
//
// `.timeLimit(.minutes(1))` is Swift Testing's coarsest granularity
// (`.seconds`/`.milliseconds`/etc are marked unavailable on
// `TimeLimitTrait.Duration`), but it is enough to turn a regression of
// this bug back into a failing test instead of a suite that hangs forever.
@Test(.timeLimit(.minutes(1)))
func concurrentStartStopCyclesCompleteWithoutDeadlocking() async throws {
    let bin = repoRoot().appendingPathComponent("bin/wakil-ctx")
    try #require(FileManager.default.isExecutableFile(atPath: bin.path),
                 "run `make build` first")

    try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<16 {
            group.addTask {
                for _ in 0..<4 {
                    let home = testScratchRoot.appendingPathComponent(UUID().uuidString)
                    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

                    let c = MCPClient(executable: bin, arguments: [],
                                      environment: ["HOME": home.path, "WAKIL_ORG": "probe", "PATH": "/usr/bin:/bin"])
                    try await c.start()
                    await c.stop()
                }
            }
        }
        try await group.waitForAll()
    }
}


// Regression test for a deadlock found in review, introduced by the fix
// for the *previous* deadlock: two tasks calling `stop()` on the SAME
// client instance both used to pass the "already torn down?" check before
// either had finished tearing down, so the second call's
// `waitForProcessExit` overwrote the first call's
// `Process.terminationHandler` -- Foundation silently drops the
// overwritten handler -- leaking the first caller's continuation forever.
//
// `concurrentStartStopCyclesCompleteWithoutDeadlocking` above cannot catch
// this: it creates a fresh `MCPClient` per cycle, so no two `stop()` calls
// there ever race on the same instance. This test exists specifically to
// cover the case that one doesn't.
@Test(.timeLimit(.minutes(1)))
func concurrentStopCallsOnTheSameClientAllReturn() async throws {
    let bin = repoRoot().appendingPathComponent("bin/wakil-ctx")
    try #require(FileManager.default.isExecutableFile(atPath: bin.path),
                 "run `make build` first")
    let home = testScratchRoot.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

    let c = MCPClient(executable: bin, arguments: [],
                      environment: ["HOME": home.path, "WAKIL_ORG": "probe", "PATH": "/usr/bin:/bin"])
    try await c.start()

    // Several tasks race to tear down the same client at once. If any of
    // them leaks a continuation, that task's `await c.stop()` never
    // returns and `waitForAll()` hangs until the time limit above kills
    // the test.
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<8 {
            group.addTask { await c.stop() }
        }
        await group.waitForAll()
    }
}

// MARK: - replies split across read chunks

/// A fake MCP server, in `/bin/sh`, that answers every framed request
/// carrying an `"id"` with a result padded to 60 KB — large enough that one
/// reply always spans several of the client's `availableData` reads, which is
/// the condition `reads split mid-frame` the test below needs and no other
/// test in this file creates. Never the real `claude` CLI, and never
/// `bin/wakil-ctx` either: this needs a peer whose reply size it controls.
///
/// The id is extracted with shell parameter expansion rather than `sed` (no
/// process per line). Both the trailing `,` and the trailing `}` are stripped
/// because `JSONEncoder` emits a dictionary's keys in an order that is
/// randomised per process, so `"id"` is sometimes the last key in the frame
/// and sometimes not — an earlier version of this helper stripped only the
/// comma and so replied `"id":1}` on runs where the seed put `id` last,
/// producing a corrupt frame of its own making.
private func makeEchoServer(_ dir: URL) throws -> URL {
    let pad = String(repeating: "x", count: 60_000)
    let script = dir.appendingPathComponent("echo-server.sh")
    let body = """
    #!/bin/sh
    PAD='\(pad)'
    while IFS= read -r line; do
      case "$line" in *'"id":'*) ;; *) continue;; esac
      rest=${line#*\\"id\\":}
      id=${rest%%,*}
      id=${id%%\\}*}
      printf '{"jsonrpc":"2.0","id":%s,"result":{"pad":"%s"}}\\n' "$id" "$PAD"
    done
    """
    try body.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return script
}

/// A fake MCP server that answers `initialize` and nothing else, and writes every frame it reads
/// to the log named in its first argument. A `tools/call` to it waits forever, unless it is
/// cancelled.
private func makeSilentServer(_ dir: URL) throws -> URL {
    let script = dir.appendingPathComponent("silent-server.sh")
    let body = """
    #!/bin/sh
    LOG="$1"
    while IFS= read -r line; do
      printf '%s\\n' "$line" >> "$LOG"
      case "$line" in *'"initialize"'*)
        rest=${line#*\\"id\\":}
        id=${rest%%,*}
        id=${id%%\\}*}
        printf '{"jsonrpc":"2.0","id":%s,"result":{}}\\n' "$id" ;;
      esac
    done
    """
    try body.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return script
}

/// W14: cancelling the task that awaits a call stops the wait at once, and tells the server with
/// `notifications/cancelled` for that request's id. Until this, the client could only stop
/// waiting, and the HTTP request ran on to its timeout.
@Test(.timeLimit(.minutes(1)))
func cancellingACallStopsWaitingAndTellsTheServer() async throws {
    let dir = testScratchRoot.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let log = dir.appendingPathComponent("frames.log")
    let c = MCPClient(
        executable: try makeSilentServer(dir), arguments: [log.path],
        environment: ["PATH": "/usr/bin:/bin"])
    try await c.start()
    let call = Task {
        try await c.callTool(name: "request", arguments: .object([:]), timeout: 30)
    }
    try await Task.sleep(nanoseconds: 200_000_000)
    let cancelled = Date()
    call.cancel()
    await #expect(throws: CancellationError.self) { _ = try await call.value }
    #expect(Date().timeIntervalSince(cancelled) < 2)

    var line: Substring?
    for _ in 0..<50 where line == nil {
        let frames = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        // JSONEncoder escapes "/", so the method arrives as notifications\/cancelled.
        line = frames.split(separator: "\n").first { $0.contains("cancelled") && $0.contains("requestId") }
        if line == nil { try await Task.sleep(nanoseconds: 50_000_000) }
    }
    await c.stop()
    // initialize is id 1, so the call is id 2.
    #expect(try #require(line).contains("\"requestId\":2"))
    // Neutral: every cancelled call says this, whoever cancelled it (fix round 1).
    #expect(try #require(line).contains("cancelled by the client"))
}

/// Regression test for the same cross-cutting bug at `MCPClient`: the stdout
/// drain thread used to hand each chunk to the actor as its own unstructured
/// `Task { await self.handleStdoutData(data) }`, with no ordering between
/// them. `FrameReader` is reassembling a *byte* stream, so an inversion there
/// is not a reordering of replies — it splices the middle of one reply into
/// the front of another, `FrameReader` latches the decode error, and per its
/// contract the whole connection is finished.
///
/// The two tests above that talk to the real `bin/wakil-ctx` cannot reach
/// this: their replies are small enough to arrive in one chunk each, so the
/// reader never has two chunks of one frame to invert. Hence the 60 KB
/// padding here, and 40 calls in flight at once to keep the pipe busy.
///
/// Measured on this machine before the fix, over four runs: 1, 3, 4 and 10 of
/// every 10 clients lost their transport, most with
/// `transportClosed(DecodingError … Unexpected character 'x' around line 1,
/// column 1)` — the padding bytes of a reply arriving ahead of that reply's
/// own opening brace — and the rest with `timeout(method:)` on a reply whose
/// frame never completed. After the fix, 0 of 10 on every run. Ten iterations
/// rather than five because this race is the least frequent of the four this
/// change covers: at five, one negative-control run in three came out clean.
@Test(.timeLimit(.minutes(2)))
func repliesSplitAcrossReadChunksNeverCorruptTheFrameStream() async throws {
    let dir = testScratchRoot.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let script = try makeEchoServer(dir)

    var failures = 0
    let iterations = 10
    let calls = 40
    for _ in 0..<iterations {
        let c = MCPClient(executable: script, arguments: [], environment: ["PATH": "/usr/bin:/bin"])
        do {
            try await c.start()
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<calls {
                    group.addTask {
                        _ = try await c.callTool(
                            name: "x", arguments: .object([:]), timeout: MCPClient.readReplyTimeout)
                    }
                }
                try await group.waitForAll()
            }
        } catch {
            failures += 1
        }
        await c.stop()
    }
    #expect(failures == 0, "\(failures) of \(iterations) clients lost their transport to a corrupted frame stream")
}

// MARK: - the drain deadline

/// The other side of `MCPClient.drainDeadlineNanoseconds`, and the test
/// this bound was missing when it was first added.
///
/// `performTeardown` waits for BOTH drain threads to see end-of-file. A
/// pipe reaches EOF only when the LAST write end closes, which is not
/// something this actor can guarantee about a process it does not own: a
/// grandchild that inherited stdout and outlives `terminate()` keeps it
/// open, and no amount of waiting changes that. Unbounded, that wait is a
/// `stop()` that never returns — measured, four times, as a `make
/// app-test` that hung for 45 minutes when a terminal pane's `forkpty`'d
/// shell inherited these very pipes (see
/// `.superpowers/sdd/2026-09-17-phase-2c-iii-terminal-pane/gate-wedge-report.md`).
///
/// **Mirrors `ClaudeCodeCLIHarnessTests.stopReturnsPromptlyWhenAGrandchildHoldsStdoutOpen`
/// deliberately**, including its one hard-won correction:
/// `Process.terminate()` signals the child's whole process GROUP, not just
/// its pid, so a plain backgrounded `sleep &` dies with the child, closes
/// the pipe, and turns this into an ordinary-EOF test that proves nothing.
/// The grandchild therefore sets `trap "" TERM` before `exec`ing — SIG_IGN
/// survives `exec`, so one pid both declines SIGTERM and holds the
/// inherited stdout for the full 20 seconds.
///
/// **It asserts the RECORD, not just the prompt return.** A test that
/// checked only the elapsed time would still pass if the give-up stopped
/// being recorded, and a give-up nobody can observe is how a bound rots
/// back into a hang without anyone noticing. `abandonedDrains` is internal
/// and reached here through `@testable`, the same way
/// `TerminalStore.pidForTesting` exists so a test can assert a reap rather
/// than infer one.
@Test(.timeLimit(.minutes(1)))
func stopReturnsPromptlyAndRecordsTheGiveUpWhenAGrandchildHoldsStdoutOpen() async throws {
    let dir = testScratchRoot
        .appendingPathComponent("wakil-mcpclient-heldopen-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let grandchildPIDFile = dir.appendingPathComponent("grandchild.pid")
    let script = dir.appendingPathComponent("held-open-server.sh")
    // The reply loop is `makeEchoServer`'s, minus the 60 KB padding this
    // test has no use for: it only has to answer `start()`'s `initialize`.
    try """
    #!/bin/sh
    sh -c 'trap "" TERM; echo $$ > "\(grandchildPIDFile.path)"; exec sleep 20' &
    while IFS= read -r line; do
      case "$line" in *'"id":'*) ;; *) continue;; esac
      rest=${line#*\\"id\\":}
      id=${rest%%,*}
      id=${id%%\\}*}
      printf '{"jsonrpc":"2.0","id":%s,"result":{}}\\n' "$id"
    done
    """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

    let client = MCPClient(
        executable: script, arguments: [], environment: ["PATH": "/usr/bin:/bin"])
    try await client.start()

    var grandchild: Int32?
    for _ in 0..<300 where grandchild == nil {
        if let text = try? String(contentsOf: grandchildPIDFile, encoding: .utf8),
           let value = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            grandchild = value
        } else {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
    defer { if let grandchild { kill(grandchild, SIGKILL) } }
    try #require(grandchild != nil, "the server never recorded its backgrounded grandchild's pid")

    let started = ContinuousClock.now
    await client.stop()
    let elapsed = ContinuousClock.now - started
    // Checked rather than assumed: without it, a change that let
    // `terminate()` reach the grandchild after all would leave this passing
    // vacuously, having measured an ordinary EOF instead of the deadline.
    let heldOpenThroughout = grandchild.map { kill($0, 0) == 0 } ?? false

    #expect(heldOpenThroughout,
            "the grandchild died during stop(), so this ran the ordinary EOF path, not the deadline")
    // Loose against the 2s deadline for the same reason the harness's
    // equivalent is, and far below the 20s the grandchild would otherwise
    // hold the pipe for.
    #expect(elapsed < .seconds(8),
            "stop() took \(elapsed) with the stdout write end held open by a grandchild")

    let abandoned = await client.abandonedDrains
    #expect(abandoned.count == 1, "expected exactly one recorded give-up, got \(abandoned)")
    #expect(abandoned.first?.stdoutReachedEOF == false)
    #expect(abandoned.first?.stderrReachedEOF == false)
}
