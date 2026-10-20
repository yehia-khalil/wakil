import Testing
import Foundation
import Darwin
@testable import WakilKit

private func launch(
    allowedTools: [String] = ["mcp__wakil__read_pane", "mcp__wakil-pm"],
    resumingFrom parent: String? = nil,
    workingDirectory: String = "/Users/x/proj"
) -> HarnessLaunch {
    buildLaunch(claudePath: "/opt/homebrew/bin/claude", sessionId: "abc-123",
                configDir: "/Users/x/.claude-personal", oauthToken: "tok",
                mcpConfigJSON: #"{"mcpServers":{}}"#,
                allowedTools: allowedTools,
                workingDirectory: workingDirectory,
                resumingFrom: parent)
}

@Test func environmentNeverCarriesAnAPIKey() {
    #expect(launch().environment["ANTHROPIC_API_KEY"] == nil)
}

@Test func environmentIsBuiltExplicitlyNotInherited() {
    let env = launch().environment
    #expect(env["CLAUDE_CONFIG_DIR"] == "/Users/x/.claude-personal")
    #expect(env["CLAUDE_CODE_OAUTH_TOKEN"] == "tok")
    // Only the keys the harness sets deliberately; nothing inherited from the parent.
    #expect(Set(env.keys) == ["CLAUDE_CONFIG_DIR", "CLAUDE_CODE_OAUTH_TOKEN", "HOME", "PATH"])
}

// MARK: - 3b-viii: the quick-tasks launch

private func quickLaunch() -> HarnessLaunch {
    buildQuickLaunch(claudePath: "/opt/homebrew/bin/claude", configDir: "/Users/x/.claude-personal",
                     oauthToken: "tok", sessionId: "q-1", workingDirectory: "/tmp")
}

@Test func theQuickLaunchIsExactlyTheStreamFlagsNoMCPAndTheQuickConstraint() {
    let l = quickLaunch()
    #expect(l.executable == "/opt/homebrew/bin/claude")
    #expect(l.workingDirectory == "/tmp")
    #expect(l.arguments == [
        "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
        "--include-partial-messages", "--session-id", "q-1",
        "--mcp-config", #"{"mcpServers":{}}"#, "--strict-mcp-config",
    ] + quickLaunchArguments())
}

@Test func theQuickLaunchSharesTheFourKeyEnvironment() {
    let env = quickLaunch().environment
    #expect(Set(env.keys) == ["CLAUDE_CONFIG_DIR", "CLAUDE_CODE_OAUTH_TOKEN", "HOME", "PATH"])
    #expect(env["CLAUDE_CONFIG_DIR"] == "/Users/x/.claude-personal")
    #expect(env["CLAUDE_CODE_OAUTH_TOKEN"] == "tok")
    #expect(env == launch().environment)
}

@Test func theQuickLaunchCarriesNoneOfTheAgentsFlags() {
    let a = quickLaunch().arguments
    for flag in ["--append-system-prompt", "--permission-prompt-tool", "--allowedTools"] {
        #expect(!a.contains(flag), "carries \(flag)")
    }
}

/// The interrupt's acknowledgement is not an event anything acts on, and not a malformed line.
@Test func aControlResponseDecodesToUnknownNotAnError() throws {
    let line = #"{"type":"control_response","response":{"subtype":"success","request_id":"r1"}}"#
    #expect(try decodeHarnessEvents(Data(line.utf8)) == [.unknown(type: "control_response")])
}

/// `interruptTurn` writes the stream-json interrupt control request on stdin — not `SIGINT`,
/// which the real CLI answers by exiting. The fake child copies its first stdin line to a file.
@Test(.timeLimit(.minutes(1)))
func interruptTurnWritesTheControlRequestToStdin() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let out = dir.appendingPathComponent("stdin.txt")
    let script = dir.appendingPathComponent("fake-claude.sh")
    try "#!/bin/sh\nhead -n 1 > \"\(out.path)\"\nexec sleep 30\n".write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

    let harness = ClaudeCodeCLIHarness { sessionId, _, workingDirectory in
        buildQuickLaunch(claudePath: script.path, configDir: dir.path, oauthToken: "t",
                         sessionId: sessionId, workingDirectory: workingDirectory)
    }
    try await harness.start(sessionId: UUID().uuidString, resumingFrom: nil, workingDirectory: dir.path)
    try await harness.interruptTurn()

    var line = ""
    for _ in 0..<200 {
        line = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
        if line.hasSuffix("\n") { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    await harness.stop()
    let frame = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    #expect(frame["type"] as? String == "control_request")
    #expect((frame["request_id"] as? String)?.isEmpty == false)
    #expect((frame["request"] as? [String: Any])?["subtype"] as? String == "interrupt")
}

@Test func executableIsPinnedByAbsolutePath() {
    #expect(launch().executable == "/opt/homebrew/bin/claude")
}

@Test func requiredStreamingFlagsArePresent() {
    let a = launch().arguments
    for flag in ["-p", "--input-format", "stream-json", "--output-format", "--verbose",
                 "--include-partial-messages", "--session-id", "abc-123",
                 "--mcp-config", "--strict-mcp-config"] {
        #expect(a.contains(flag), "missing \(flag)")
    }
}

@Test func sessionIdIsPassedNotGeneratedByTheCLI() {
    let a = launch().arguments
    let i = a.firstIndex(of: "--session-id")!
    #expect(a[a.index(after: i)] == "abc-123")
}

// MARK: - The two resume shapes

@Test func aFreshLaunchNeverMentionsResume() {
    let a = launch().arguments
    #expect(!a.contains("--resume"))
    #expect(!a.contains("--fork-session"))
    #expect(a.contains("--session-id"))
}

@Test func aForkCarriesResumeForkSessionAndAFreshSessionId() {
    let a = launch(resumingFrom: "parent-9").arguments
    let r = a.firstIndex(of: "--resume")!
    #expect(a[a.index(after: r)] == "parent-9")
    #expect(a.contains("--fork-session"))
    let s = a.firstIndex(of: "--session-id")!
    #expect(a[a.index(after: s)] == "abc-123")
}

// Measured: `--session-id can only be used with --continue or --resume if
// --fork-session is also specified.` (session-resume-probe.md §2), at
// startup and before any turn. So an argv carrying one of --resume /
// --fork-session without the other is a session that never begins, and
// this asserts the biconditional itself — across both launch shapes,
// since "never without" is a claim about the relationship between the two
// flags, not about a single launch that happens to carry both.
@Test func resumeNeverAppearsWithoutForkSessionAndASessionId() {
    let fresh = launch().arguments
    #expect(!fresh.contains("--resume"))
    #expect(!fresh.contains("--fork-session"))
    #expect(fresh.contains("--resume") == fresh.contains("--fork-session"))

    let fork = launch(resumingFrom: "parent-9").arguments
    #expect(fork.contains("--resume"))
    #expect(fork.contains("--fork-session"))
    #expect(fork.contains("--session-id"))
    #expect(fork.contains("--resume") == fork.contains("--fork-session"))
}

@Test func theWorkingDirectoryIsCarriedOnTheLaunch() {
    #expect(launch(workingDirectory: "/Users/x/booking").workingDirectory == "/Users/x/booking")
}

// The defect probe §8 measured: `claude` inherited Wakil.app's own directory
// because nothing set this, so its transcript was filed somewhere
// `ListSessions` would never look. A previous ruling on this file held that
// `Engine.start` setting `process.currentDirectoryURL` from
// `launch.workingDirectory` was unreachable from a test because `Engine` and
// its `Process` are private — that was wrong. This file already spawns a
// real fake-`claude` shell script and reads its decoded stdout through the
// public `events()` stream (`stdoutLinesArriveAsDecodedEventsNotJustUnknowns`,
// `aLineSplitAcrossTwoReadChunksIsReassembled`, and two others below); the
// child's own `$PWD` is just as reachable that way as any other line it
// prints. So this spawns a script that reports its own working directory
// back over stdout, in the shape of an `assistant` event, and asserts
// through `start(sessionId:resumingFrom:workingDirectory:)` — the only
// public entry point — that the directory it named is where the child
// actually ran. Without this one line the whole resume sub-phase is
// unreachable in practice: a resumed session's transcript would land
// wherever Wakil.app happens to be running from, not where the operator's
// project lives. Its only other verification today is an unwalked
// acceptance check.
@Test(.timeLimit(.minutes(1)))
func startRunsTheChildInTheGivenWorkingDirectory() async throws {
    let dir = testScratchRoot
        .appendingPathComponent("wakil-harness-cwd-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    // `dir` sits under `/var`, which macOS symlinks to `/private/var`. The
    // harness never passes `PWD` through (see
    // `environmentIsBuiltExplicitlyNotInherited`), so the spawned shell
    // computes its own `$PWD` itself via `getcwd(3)`, which reports the
    // physical, symlink-resolved path. `realpath(3)` mirrors that;
    // `URL.resolvingSymlinksInPath()` does not — Foundation documents it as
    // deliberately leaving `/tmp`, `/var` and `/private` unresolved, which
    // would make this assertion fail for a reason that has nothing to do
    // with the fix under test.
    var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
    try #require(realpath(dir.path, &buffer) != nil)
    let resolvedDir = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }

    let script = dir.appendingPathComponent("fake-claude.sh")
    try """
    #!/bin/sh
    printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"'"$PWD"'"}]}}'
    """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

    let harness = ClaudeCodeCLIHarness(
        claudePath: script.path, configDir: dir.path, oauthToken: "t", mcpConfigJSON: "{}", allowedTools: []
    )
    let stream = harness.events()
    try await harness.start(sessionId: UUID().uuidString, resumingFrom: nil, workingDirectory: dir.path)

    var events: [HarnessEvent] = []
    for await event in stream { events.append(event) }
    await harness.stop()

    #expect(events == [.assistantText(resolvedDir)])
}

// MARK: - The permission allow list

/// The gap this closes. Probe §6 measured the CLI's permission layer
/// covering MCP tool calls and denying them outright in a session with no
/// approval surface — which `-p` is — so a launch carrying no permission
/// flags at all leaves the agent unable to call *any* Wakil tool, `read_pane`
/// included. The allow list is what stops that.
///
/// Asserted here at the argv level only. Nothing in this suite runs `claude`,
/// so that the CLI honours these entries is confirmed by the operator's
/// standing check 2 (`docs/wakil/phase-2a-acceptance.md`) and by nothing here.
@Test func allowedToolsReachTheArgvAsOneCommaSeparatedValue() throws {
    let a = launch(allowedTools: ["mcp__wakil__db_run_query", "mcp__wakil__read_pane"]).arguments
    let i = try #require(a.firstIndex(of: "--allowedTools"))
    #expect(a[a.index(after: i)] == "mcp__wakil__db_run_query,mcp__wakil__read_pane")
}

/// An empty list means "no allow rules", which is a different thing from
/// "allow nothing": `--allowedTools ""` is a rule the CLI would have to
/// interpret, and passing a flag with nothing behind it is not something
/// this function should invent. It omits the flag instead, which is exactly
/// the pre-fix behaviour — so a caller that forgets to build a list gets the
/// old, denied-everything session rather than a silently different one.
@Test func anEmptyAllowListOmitsTheFlagEntirelyRatherThanPassingItEmpty() {
    #expect(!launch(allowedTools: []).arguments.contains("--allowedTools"))
}

/// The flag that makes the write gate reachable at all.
///
/// Before it, an unlisted tool in a `-p` session was denied by the CLI —
/// "it requires approval, and this session has no approval surface"
/// (`docs/wakil/phase-2a-probe.md` §6) — so `db_run_mutation` never reached
/// Wakil's socket, the broker never parked it, and no confirmation plane
/// ever appeared. This names the surface.
///
/// Asserted at the argv level only, as with every flag `buildLaunch`
/// builds. That the CLI honours it was measured in
/// `docs/wakil/permission-prompt-probe.md` and is re-confirmed by the
/// operator's acceptance run; nothing in this suite runs `claude`.
@Test func thePermissionPromptToolIsNamedInTheArgv() throws {
    let a = launch().arguments
    let i = try #require(a.firstIndex(of: "--permission-prompt-tool"))
    #expect(a[a.index(after: i)] == "mcp__wakil__approve_tool_use")
}

/// It is spelled from the same two constants the MCP surface uses, so the
/// flag's value and the advertised tool cannot drift apart. Probe §8 makes
/// that drift a session in which every gated tool fails and nothing in the
/// app looks wrong.
@Test func thePromptToolFlagIsBuiltFromTheSameConstantsTheServerAdvertises() throws {
    let a = launch().arguments
    let i = try #require(a.firstIndex(of: "--permission-prompt-tool"))
    #expect(a[a.index(after: i)] == "mcp__\(wakilShimServerName)__\(permissionPromptToolName)")
}

/// `--permission-mode` is still absent, and so are the other two. See
/// `buildLaunch`'s doc comment: the allow list plus a prompt tool is the
/// pair that makes what is listed run silently and everything else the
/// CLI's own policy does not already settle get asked about — `Read`,
/// `Glob` and a read-only `Bash` are neither (probe §7). `bypassPermissions`
/// would switch off the layer this
/// session has just given something to answer with, and
/// `--permission-prompts` defaults to `host`, which is what makes the
/// prompt tool reachable — passing it would only restate a default.
@Test func noPermissionModeNoPromptsTargetAndNoSkipFlagArePassed() {
    let a = launch().arguments
    #expect(!a.contains("--permission-mode"))
    #expect(!a.contains("--permission-prompts"))
    #expect(!a.contains("--dangerously-skip-permissions"))
}

/// The bridge is deliberately NOT on the allow list. Probe §11 ran Wakil's
/// exact shape — a non-empty allow list excluding the prompt tool — and the
/// CLI reached its designated tool anyway. Listing it would buy nothing and
/// hand the agent a silent route to call it directly.
@Test func theBridgeIsNotOnTheAllowList() throws {
    let a = launch().arguments
    // `#require`, not a `guard … else { return }`: the default `launch()`
    // passes a non-empty allow list, so an absent flag is a regression and
    // must fail here rather than pass green having checked nothing.
    let i = try #require(a.firstIndex(of: "--allowedTools"))
    #expect(!a[a.index(after: i)].contains(permissionPromptToolName))
}

// MARK: - the agent's instructions

/// The walked failure: the operator closed a pane and asked for its
/// contents again, and the agent replied "You've asked this exact same
/// question four times in a row now, and the answer hasn't changed" and
/// drew nothing.
///
/// That is not disobedience. Wakil passed NO system prompt at all —
/// `--append-system-prompt` appeared nowhere in the source tree — so the
/// agent was generic Claude Code holding some MCP tools, reasoning about
/// the only surface it had been told about: the conversation.
@Test func theHarnessPassesTheAgentItsInstructions() throws {
    let a = launch().arguments
    let i = try #require(a.firstIndex(of: "--append-system-prompt"),
                          "the agent is launched with no instructions")
    #expect(a[a.index(after: i)] == agentSystemPrompt)
}

/// `--append-system-prompt`, never `--system-prompt`: replacing Claude
/// Code's own prompt would discard its tool-use discipline and its refusal
/// behaviour, both of which Wakil relies on and neither of which it wants
/// to restate.
@Test func theInstructionsAreAppendedAndDoNotReplace() {
    #expect(!launch().arguments.contains("--system-prompt"))
}

/// Whether the agent obeys `agentSystemPrompt` is not testable and must not
/// be pretended otherwise — that is settled at the acceptance walk, or not
/// at all. All this checks is that there is something there to send.
@Test func theAgentSystemPromptIsNotEmpty() {
    #expect(!agentSystemPrompt.isEmpty)
}

// MARK: - events() single-consumer enforcement

/// Regression test for a finding from review: handing the same
/// `AsyncStream` to two concurrent consumers does not duplicate events, it
/// *splits* them (verified separately, with a standalone scratch program on
/// this machine, before this fix: 6 values yielded into one stream arrived
/// as 3 at one consumer and 3 at the other, each permanently missing what
/// the other received). `events()` now enforces a single consumer instead
/// of leaving that as an unstated caller responsibility; a second call must
/// crash rather than silently hand back a stream that would cannibalise the
/// first. This runs the crash in a subprocess via `#expect(processExitsWith:)`,
/// since `preconditionFailure` terminates whatever process calls it.
@Test func aSecondCallToEventsCrashesRatherThanSplittingTheStream() async throws {
    await #expect(processExitsWith: .failure) {
        let harness = ClaudeCodeCLIHarness(
            claudePath: "/bin/true", configDir: "/tmp", oauthToken: "t", mcpConfigJSON: "{}", allowedTools: []
        )
        _ = harness.events()
        _ = harness.events()
    }
}

// MARK: - start()/stop() race

/// Regression test for a finding from review: a `start()` call racing a
/// concurrent `stop()` call on the same instance could previously leave a
/// spawned child running unsupervised, if `stop()`'s actor job happened to
/// run — and find nothing to tear down — before `start()`'s job registered
/// the process.
///
/// Uses a real, disposable shell script under a fresh temp directory as the
/// "child" (never the real `claude` binary): the script writes its own pid
/// to a file, then `exec`s into `sleep 30` (so the pid file's pid is exactly
/// the long-running process this test must confirm is gone, not the
/// short-lived shell that exec'd into it).
///
/// Which of two concurrently-`addTask`-ed jobs an actor runs first is not
/// something this test can rely on wall-clock jitter to vary reliably:
/// measured directly on this machine with a standalone scratch program
/// reproducing this exact shape (fresh actor per iteration, one task with a
/// little synchronous prep before hopping to the actor, one without,
/// 5000 iterations), the task added to the `TaskGroup` *first* won the race
/// to actually run on the actor essentially every time — 4998/5000 and
/// 4999/5000 in the two directions — regardless of which side carried the
/// extra prep work. So this test does not guess at scheduling: it forces
/// both orderings directly by alternating which call is `addTask`-ed first
/// from one iteration to the next, and — using that same scratch
/// program — confirmed each ordering actually produces an orphan when the
/// `everStopped` guard this test protects is stubbed out (4999/5000 and
/// 4998/5000 orphaned respectively), and zero orphans in either ordering
/// with the guard in place.
@Test(.timeLimit(.minutes(1)))
func racingStartAndStopNeverLeavesAnOrphan() async throws {
    let dir = testScratchRoot
        .appendingPathComponent("wakil-harness-race-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    for i in 0..<20 {
        let pidFile = dir.appendingPathComponent("pid-\(i).txt")
        let scriptFile = dir.appendingPathComponent("sleep-\(i).sh")
        let script = "#!/bin/sh\necho $$ > \"\(pidFile.path)\"\nexec sleep 30\n"
        try script.write(to: scriptFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptFile.path)

        let harness = ClaudeCodeCLIHarness(
            claudePath: scriptFile.path, configDir: dir.path, oauthToken: "t", mcpConfigJSON: "{}", allowedTools: []
        )
        let stopFirst = i.isMultiple(of: 2)

        // Both calls are awaited to completion by `waitForAll()` regardless
        // of which the actor runs first, so by the time this returns, the
        // outcome is already fully resolved either way: either `start()`
        // was refused outright (no pid file ever appears), or it spawned
        // and `stop()` — which must then have run after it, per
        // `Engine.everStopped`'s doc comment — already awaited that child's
        // exit before returning.
        await withTaskGroup(of: Void.self) { group in
            if stopFirst {
                group.addTask { await harness.stop() }
                group.addTask { try? await harness.start(sessionId: UUID().uuidString, resumingFrom: nil, workingDirectory: dir.path) }
            } else {
                group.addTask { try? await harness.start(sessionId: UUID().uuidString, resumingFrom: nil, workingDirectory: dir.path) }
                group.addTask { await harness.stop() }
            }
            await group.waitForAll()
        }

        // `waitForAll()` returning only tells us both calls finished, not
        // that a spawned child has had a scheduling quantum yet to run its
        // first instruction (`echo $$ > pidFile`) — measured directly: with
        // no wait at all here, the pid file had not yet appeared for *any*
        // iteration, spawned or not, giving a false "never spawned" reading
        // even for children that were, in fact, orphaned. So this polls,
        // bounded, for the file to appear before concluding it never will.
        var pid: Int32?
        for _ in 0..<20 {
            if let text = try? String(contentsOf: pidFile, encoding: .utf8),
               let value = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                pid = value
                break
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        guard let pid else {
            // `start()` lost the race entirely (an already-run `stop()`
            // blocked it via `everStopped`) -- nothing was ever spawned,
            // one of the two outcomes this test allows.
            continue
        }

        // Bounded grace window purely against scheduling jitter in
        // observing the exit this test expects to have already happened;
        // not relied on to make a slow teardown look correct.
        var stillAlive = kill(pid, 0) == 0
        for _ in 0..<20 where stillAlive {
            try? await Task.sleep(nanoseconds: 50_000_000)
            stillAlive = kill(pid, 0) == 0
        }
        #expect(!stillAlive, "iteration \(i) (stopFirst=\(stopFirst)): child pid \(pid) is still running after start()/stop() raced")
    }
}

// MARK: - start() after stop() is refused, not silently ignored

/// Regression test for a finding from review: `start()` on a harness that
/// `stop()` had already run on used to return normally with no child ever
/// spawned — the caller had no way to distinguish that from a real,
/// successful start. `start()` now throws `.alreadyStopped` instead.
@Test func startAfterStopThrowsAlreadyStopped() async throws {
    let harness = ClaudeCodeCLIHarness(
        claudePath: "/bin/true", configDir: "/tmp", oauthToken: "t", mcpConfigJSON: "{}", allowedTools: []
    )
    await harness.stop() // nothing running yet; sets Engine.everStopped
    await #expect(throws: ClaudeCodeCLIHarnessError.alreadyStopped) {
        try await harness.start(sessionId: UUID().uuidString, resumingFrom: nil, workingDirectory: "/tmp")
    }
}

// MARK: - stdout lines reach events() as decoded events

/// The harness's stdout reader is wired to `decodeHarnessEvents`, not to a
/// placeholder that reports every line as `.unknown`. Two things this pins
/// that the decoder's own tests cannot:
///
/// 1. one line can now yield *several* events (the `assistant` line here
///    carries a text block and a `tool_use` block), and both must be yielded
///    in order — the reader used to yield at most one event per line;
/// 2. a malformed line is still dropped silently and reading *continues*,
///    rather than the decoder's `throws` becoming a crash or an early end of
///    stream: the `result` after it still arrives.
///
/// It pins nothing about lines split across read chunks: the child emits its
/// whole payload from a single `cat`, so every line here arrives inside one
/// `handleStdoutData` call and the buffer's reassembly path never runs. That
/// is `aLineSplitAcrossTwoReadChunksIsReassembled` below, which exists
/// because this comment once claimed the coverage without having it.
///
/// The child is a shell script standing in for `claude` — it ignores the
/// argv the harness builds and prints recorded-shape lines. Nothing here
/// runs the real CLI or spends the subscription.
@Test(.timeLimit(.minutes(1)))
func stdoutLinesArriveAsDecodedEventsNotJustUnknowns() async throws {
    let dir = testScratchRoot
        .appendingPathComponent("wakil-harness-decode-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let script = dir.appendingPathComponent("fake-claude.sh")
    try """
    #!/bin/sh
    cat <<'STREAM'
    {"type":"system","subtype":"init","session_id":"fake-session"}
    {"type":"rate_limit_event"}
    this line is not JSON
    {"type":"assistant","message":{"content":[{"type":"text","text":"hi"},{"type":"tool_use","id":"t1","name":"mcp__wakil-ctx__get_context","input":{}}]}}
    {"type":"result","subtype":"success","is_error":false,"result":"hi"}
    STREAM
    """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

    let harness = ClaudeCodeCLIHarness(
        claudePath: script.path, configDir: dir.path, oauthToken: "t", mcpConfigJSON: "{}", allowedTools: []
    )
    let stream = harness.events()
    try await harness.start(sessionId: UUID().uuidString, resumingFrom: nil, workingDirectory: dir.path)

    // The child exits after printing, closing stdout, which finishes the
    // stream — so this loop terminates on its own.
    var events: [HarnessEvent] = []
    for await event in stream { events.append(event) }
    await harness.stop()

    #expect(events == [
        .systemInit(sessionId: "fake-session"),
        .unknown(type: "rate_limit_event"),
        .assistantText("hi"),
        .toolUse(id: "t1", name: "mcp__wakil-ctx__get_context", input: .object([:])),
        .result(isError: false, text: "hi"),
    ])
}

// MARK: - a line split across two read chunks is reassembled

/// `Engine.handleStdoutData` accumulates into `lineBuffer` and only cuts at a
/// newline, so a frame the OS happens to deliver in two pieces must still
/// decode as one frame. Nothing else in the suite exercised that: every other
/// fake child prints its whole payload from one `cat`, which arrives in a
/// single read, so the accumulation was untested — mutating the append to a
/// plain assignment (`lineBuffer = data`, destroying cross-chunk buffering
/// outright) left all 89 tests passing.
///
/// This child splits one `assistant` frame mid-word and sleeps between the
/// halves, which forces two separate `availableData` reads. If the buffer
/// stopped accumulating, the first half would be discarded and the second
/// half would be an unparseable fragment the reader drops — the whole
/// assistant turn would vanish silently, with only the trailing `result`
/// surviving. The `sleep` is what makes the split reliable rather than
/// hopeful; it is not a timing assumption about correct behaviour, since
/// reassembly must hold however the bytes are divided.
@Test(.timeLimit(.minutes(1)))
func aLineSplitAcrossTwoReadChunksIsReassembled() async throws {
    let dir = testScratchRoot
        .appendingPathComponent("wakil-harness-split-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let script = dir.appendingPathComponent("fake-claude.sh")
    try """
    #!/bin/sh
    printf '%s' '{"type":"assistant","message":{"content":[{"type":"text","text":"hel'
    sleep 0.4
    printf '%s\\n' 'lo"}]}}'
    printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"done"}'
    """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

    let harness = ClaudeCodeCLIHarness(
        claudePath: script.path, configDir: dir.path, oauthToken: "t", mcpConfigJSON: "{}", allowedTools: []
    )
    let stream = harness.events()
    try await harness.start(sessionId: UUID().uuidString, resumingFrom: nil, workingDirectory: dir.path)

    var events: [HarnessEvent] = []
    for await event in stream { events.append(event) }
    await harness.stop()

    #expect(events == [
        .assistantText("hello"),
        .result(isError: false, text: "done"),
    ])
}

// MARK: - stdout chunks reach events() in read order

/// Regression test for a cross-cutting concurrency bug: the stdout drain
/// thread used to hand each chunk to the actor as its own unstructured
/// `Task { await self.handleStdoutData(data) }`, and unstructured `Task`s
/// carry no ordering guarantee relative to one another. Two chunks read
/// microseconds apart could therefore reach `handleStdoutData` inverted,
/// which reorders whole events when a chunk is a whole line and corrupts the
/// bytes of a line when it is not.
///
/// Nothing in the suite could see that. Every other fake child here prints
/// its payload from a single `cat`, or sleeps between writes — one chunk, or
/// chunks far enough apart that the race has no window. This child instead
/// emits 400 numbered frames from a shell loop with **no sleeps at all**, so
/// each `printf` is its own `write(2)` and the reader wakes up per line, and
/// the assertion is the exact ordered list rather than a set or a count.
///
/// Measured on this machine before the fix, over eight runs of this test
/// body: 4, 5, 6, 6, 6, 7, 8 and 10 of every 10 sessions came out mis-ordered,
/// always as an adjacent swap (`…, 47, 49, 48, 50, …`). All 400 events still
/// arrived —
/// this is not loss, it is the thought thread being told the agent did things
/// in an order it did not do them in. After the fix (one serial `AsyncStream`
/// per drain thread, drained by a single consumer), 0 of 10 across every run.
@Test(.timeLimit(.minutes(2)))
func stdoutChunksReachTheEventStreamInTheOrderTheyWereRead() async throws {
    let dir = testScratchRoot
        .appendingPathComponent("wakil-harness-order-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let lines = 400
    let expected: [HarnessEvent] = (0..<lines).map { .assistantText("\($0)") }

    let script = dir.appendingPathComponent("fake-claude.sh")
    try """
    #!/bin/sh
    i=0
    while [ $i -lt \(lines) ]; do
      printf '{"type":"assistant","message":{"content":[{"type":"text","text":"%s"}]}}\\n' "$i"
      i=$((i + 1))
    done
    """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

    var misordered = 0
    let sessions = 10
    for _ in 0..<sessions {
        let harness = ClaudeCodeCLIHarness(
            claudePath: script.path, configDir: dir.path, oauthToken: "t", mcpConfigJSON: "{}", allowedTools: []
        )
        let stream = harness.events()
        try await harness.start(sessionId: UUID().uuidString, resumingFrom: nil, workingDirectory: dir.path)
        // The child exits after printing, closing stdout, which finishes the
        // stream — so this loop terminates on its own.
        var events: [HarnessEvent] = []
        for await event in stream { events.append(event) }
        await harness.stop()
        if events != expected { misordered += 1 }
    }
    #expect(misordered == 0, "\(misordered) of \(sessions) sessions delivered events out of read order")
}

// MARK: - EOF is dispatched after the chunks that preceded it

/// Regression test for the second half of the same bug: EOF used to be its
/// own `Task { await self.handleStdoutEOF() }`, racing whatever
/// `handleStdoutData` `Task`s were still queued. `handleStdoutEOF` calls
/// `continuation.finish()`, and a finished `AsyncStream` continuation
/// silently discards every later `yield` — so an EOF that won that race threw
/// away the closing events of a session, the `result` frame most of all, with
/// no error and nothing in the stream to suggest anything was missing.
///
/// The child here prints exactly one frame and exits, which is the tightest
/// form of the race: the drain thread creates the chunk's dispatch and the
/// EOF's dispatch back-to-back, separated only by one `read(2)` returning 0.
/// One such race is rare — a first attempt at this test, 60 sessions run one
/// after another, caught none at all before the fix — so this runs 400 of
/// them, 16 lanes at a time: concurrency both multiplies the sample and loads
/// the cooperative pool the two `Task`s were competing for.
///
/// Measured on this machine before the fix, over six runs of the 16-lane
/// shape: 1, 3, 3, 3, 4 and 7 of 400 sessions ended with the stream finished
/// and *zero* events delivered. After it: 0 of 400 on every run, because the
/// drain thread now finishes the chunk stream instead of dispatching EOF
/// separately, and the single consumer reaches EOF only after the backlog is
/// drained.
@Test(.timeLimit(.minutes(2)))
func theLastEventBeforeEOFIsNeverDroppedByTheStreamFinishing() async throws {
    let dir = testScratchRoot
        .appendingPathComponent("wakil-harness-eof-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let script = dir.appendingPathComponent("fake-claude.sh")
    try """
    #!/bin/sh
    printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"done"}'
    """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

    let lanes = 16, sessionsPerLane = 25
    let dropped = await withTaskGroup(of: Int.self) { group in
        for _ in 0..<lanes {
            group.addTask {
                var local = 0
                for _ in 0..<sessionsPerLane {
                    let harness = ClaudeCodeCLIHarness(
                        claudePath: script.path, configDir: dir.path, oauthToken: "t", mcpConfigJSON: "{}", allowedTools: []
                    )
                    let stream = harness.events()
                    try? await harness.start(sessionId: UUID().uuidString, resumingFrom: nil, workingDirectory: dir.path)
                    var events: [HarnessEvent] = []
                    for await event in stream { events.append(event) }
                    await harness.stop()
                    if events != [.result(isError: false, text: "done")] { local += 1 }
                }
                return local
            }
        }
        var total = 0
        for await n in group { total += n }
        return total
    }
    #expect(dropped == 0, "\(dropped) of \(lanes * sessionsPerLane) sessions lost their final event to EOF")
}

// MARK: - stop() does not destroy the tail of the session

/// This suite holds exactly one test, and `.serialized` here is not about
/// ordering within the suite — it is what keeps that test from running
/// concurrently with the other ~377 tests in the target. Swift Testing
/// parallelises across the whole plan by default, and this test's own
/// assertion (3000 of 3000 frames delivered against a 2-second production
/// deadline, `Engine.stdoutDrainDeadlineNanoseconds`) is a real-time budget:
/// under full-suite load it lost that race and failed 3/3 runs, while
/// passing standalone in 4.7s. The fix is to stop competing for the
/// machine, not to weaken what it measures — see the test's own doc comment
/// for why 3000-of-3000 is the number and not a rounder, looser one.
@Suite(.serialized)
struct StopDeliversTheTailOfTheStreamSuite {
    /// Regression test for a finding from review, and the other half of the
    /// ordering bug `theLastEventBeforeEOFIsNeverDroppedByTheStreamFinishing`
    /// covers: `handleStdoutEOF` was made to run strictly after the last chunk,
    /// but `performTeardown` still called `continuation.finish()` the instant the
    /// child exited, with no regard for how much of the chunk backlog
    /// `consumeStdout` had actually got through. `finish()` is irreversible and a
    /// finished continuation silently discards every later `yield`, so `stop()`
    /// threw away whatever was still queued — in production that is the `result`
    /// frame and the trailing tool results of any promptly torn-down session.
    ///
    /// The child here writes 3000 frames, touches a marker file, and only then
    /// `exec`s into a long `sleep`. Two properties make this a clean measurement
    /// rather than a timing guess: the marker means that by the time this test
    /// calls `stop()`, all 3000 frames are *provably* already written into the
    /// pipe, so every one of them is owed to the consumer; and because the
    /// `exec`ed `sleep` keeps the stdout write end open, nothing but `stop()` can
    /// ever end the stream, so the count below is entirely `stop()`'s doing.
    ///
    /// Measured on this machine before the fix, five sessions: 469, 1123, 550,
    /// 631 and 817 events delivered of the 3000 owed — between 60% and 85% of
    /// the session destroyed every time, with no error anywhere. A variant that
    /// dropped the marker and called `stop()` on a 150 ms timer instead was worse
    /// still: 0, 0, 0, 0 and 0 delivered across five sessions, the caller seeing
    /// the session produce *nothing at all*. After the fix (`performTeardown`
    /// awaits `consumeStdout`'s drain, under a bounded deadline), 3000 of 3000 in
    /// every session.
    @Test(.timeLimit(.minutes(2)))
    func stopDeliversTheTailOfTheStreamRatherThanDiscardingIt() async throws {
        let dir = testScratchRoot
            .appendingPathComponent("wakil-harness-tail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let frames = 3000
        let sessions = 5
        var delivered: [Int] = []

        for session in 0..<sessions {
            let marker = dir.appendingPathComponent("written-\(session).marker")
            let script = dir.appendingPathComponent("fake-claude-\(session).sh")
            try """
            #!/bin/sh
            i=0
            while [ $i -lt \(frames) ]; do
              printf '{"type":"assistant","message":{"content":[{"type":"text","text":"%s"}]}}\\n' "$i"
              i=$((i + 1))
            done
            : > "\(marker.path)"
            exec sleep 30
            """.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

            let harness = ClaudeCodeCLIHarness(
                claudePath: script.path, configDir: dir.path, oauthToken: "t", mcpConfigJSON: "{}", allowedTools: []
            )
            let stream = harness.events()
            try await harness.start(sessionId: UUID().uuidString, resumingFrom: nil, workingDirectory: dir.path)
            let collector = Task { () -> Int in
                var count = 0
                for await _ in stream { count += 1 }
                return count
            }

            // Bounded poll for the marker: once it exists, the child has finished
            // all 3000 writes and is parked in `sleep`, so nothing is still being
            // produced and every frame is already in the pipe.
            var written = false
            for _ in 0..<300 where !written {
                written = FileManager.default.fileExists(atPath: marker.path)
                if !written { try? await Task.sleep(nanoseconds: 20_000_000) }
            }
            #expect(written, "session \(session): the child never finished writing its frames")

            await harness.stop()
            delivered.append(await collector.value)
        }

        #expect(delivered == Array(repeating: frames, count: sessions),
                "stop() destroyed the tail of the stream: delivered \(delivered) of \(frames) per session")
    }
}

/// The other side of that fix's bounded deadline. Waiting for the stdout
/// drain *unconditionally* would reintroduce a `stop()` that can hang: the
/// drain thread only finishes its chunk stream when `read(2)` returns 0, and
/// that needs every holder of the pipe's write end to have closed it — not
/// merely the child this harness spawned. A grandchild that inherited stdout
/// and outlives `terminate()` keeps it open, and no amount of waiting will
/// change that.
///
/// Constructing that took one correction. `Process.terminate()` turns out to
/// signal the child's whole *process group*, not just its pid: measured
/// directly on this machine with a standalone program, Foundation spawns the
/// child as its own group leader (pgid == child pid) and a plain backgrounded
/// `sleep &` — which shares that group — dies along with it, closing the pipe
/// and making the wait below finish in under a millisecond. A grandchild only
/// outlives `terminate()` if it declines the signal, so this one sets
/// `trap "" TERM` before `exec`ing into `sleep` (SIG_IGN survives `exec`, so
/// one pid both ignores SIGTERM and holds the inherited stdout for the full
/// 20 seconds).
///
/// The assertion is that `stop()` returns anyway: the bound checked here is 10
/// seconds against `Engine.stdoutDrainDeadlineNanoseconds`' 2, loose enough
/// not to fail on scheduling noise but still half the 20 seconds the
/// grandchild would otherwise hold the pipe for. It was 5, and `stop()`
/// measured 5.5 inside the full suite at a load average of 31 on 8 cores —
/// scheduling noise, not the regression, which costs the full 20. Its pid is recorded so this
/// test kills it rather than leaving it to time out.
@Test(.timeLimit(.minutes(1)))
func stopReturnsPromptlyWhenAGrandchildHoldsStdoutOpen() async throws {
    let dir = testScratchRoot
        .appendingPathComponent("wakil-harness-heldopen-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let grandchildPIDFile = dir.appendingPathComponent("grandchild.pid")
    let script = dir.appendingPathComponent("fake-claude.sh")
    try """
    #!/bin/sh
    sh -c 'trap "" TERM; echo $$ > "\(grandchildPIDFile.path)"; exec sleep 20' &
    printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"done"}'
    exec sleep 20
    """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

    let harness = ClaudeCodeCLIHarness(
        claudePath: script.path, configDir: dir.path, oauthToken: "t", mcpConfigJSON: "{}", allowedTools: []
    )
    let stream = harness.events()
    try await harness.start(sessionId: UUID().uuidString, resumingFrom: nil, workingDirectory: dir.path)
    let collector = Task { () -> Int in
        var count = 0
        for await _ in stream { count += 1 }
        return count
    }

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
    #expect(grandchild != nil, "the child never recorded its backgrounded grandchild's pid")

    let started = ContinuousClock.now
    await harness.stop()
    let elapsed = ContinuousClock.now - started
    // Still holding the write end at the moment `stop()` returned. Checked
    // rather than assumed: without it, a change that let `terminate()` reach
    // this process after all would leave the test passing vacuously, having
    // measured an ordinary EOF instead of the deadline.
    let heldOpenThroughout = grandchild.map { kill($0, 0) == 0 } ?? false
    _ = await collector.value

    #expect(heldOpenThroughout,
            "the grandchild died during stop(), so this ran the ordinary EOF path, not the deadline")
    // **Main's bound, scaled by `testWaitLoadMultiplier`.** Two fixes for
    // one flake met here and both are kept. `main` raised the ceiling to
    // 10 seconds; 2e's #127 made these bounds load-aware, because headroom
    // chosen against an idle machine is not a measurement — this
    // assertion took 5.71 s and failed under a full run while `stop()`
    // was working exactly as designed.
    //
    // What the assertion is for survives either way: it distinguishes a
    // BOUNDED stop from an unbounded one, and an unbounded one never
    // returns at all. The product's own deadline is 2 seconds and is
    // measured; everything above it is headroom.
    let budget = Duration.seconds(10 * testWaitLoadMultiplier)
    #expect(elapsed < budget,
            "stop() took \(elapsed) with the stdout write end held open by a grandchild")
}
