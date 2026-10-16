import Foundation
import WakilKit

/// Returns the `--socket <path>` value when `--mcp-shim` is present in
/// `arguments`; `nil` when `--mcp-shim` is absent (the normal app launch
/// path). Exits the process directly, with a message on stderr, when
/// `--mcp-shim` is present but `--socket` is missing or has no value —
/// there is no reasonable path to hand `runShim` in that case, and this
/// runs before any of this file's other code, so nothing else has started
/// yet for a partial-exit to leave dangling.
private func shimSocketPath(in arguments: [String]) -> String? {
    guard arguments.contains("--mcp-shim") else { return nil }
    guard let flagIndex = arguments.firstIndex(of: "--socket"),
          arguments.indices.contains(flagIndex + 1) else {
        FileHandle.standardError.write(Data("wakil --mcp-shim: missing required \"--socket <path>\" argument\n".utf8))
        exit(1)
    }
    return arguments[flagIndex + 1]
}

/// Parsed `--dispatch <file> [--environment <name>]` arguments.
/// `environment` defaults to `"development"` rather than `"production"`:
/// per `writeGate` in `WriteGate.swift`, an environment name that
/// lowercases to `"production"` — so `"production"`, `"Production"` and
/// `"PRODUCTION"` alike — blocks a `.mutate` action outright, while every
/// other name (recognised or not) merely gates it. An operator must
/// therefore opt into that stricter behaviour explicitly
/// (`--environment production`) rather than trip it by omission on every
/// debug script. In 2a this flag decided nothing, there being no `.mutate`
/// action for it to decide about; since Phase 2b-iii registered
/// `db_run_mutation` on 2026-09-09 it is load-bearing, and it is what
/// `phase-2a-acceptance.md`'s checks 5 and 6 differ by.
///
/// **It does not re-point the active context, and that trips people.** It is
/// the environment string `writeGate` reads and the one the journal records,
/// and nothing more: `wakil-db` resolves *which* database to open from
/// `active.json`. So `--environment staging` against an account sitting on
/// `production` — which probe §7 found `personal` doing — gates the call as
/// staging while opening the production database. Named in
/// `phase-2a-acceptance.md` check 5's preconditions for the same reason.
private struct DispatchArguments {
    var scriptPath: String
    var environment: String
}

/// Returns the parsed `--dispatch` arguments when `--dispatch` is present in
/// `arguments`; `nil` when absent (the normal app launch path, or
/// `--mcp-shim`, handled separately above). Exits the process directly,
/// with a message on stderr, when a flag is present but its value is
/// missing — mirroring `shimSocketPath`'s handling of a missing `--socket`
/// value just above, for the same reason: there is no reasonable value to
/// invent, and this runs before anything else in this file has started.
///
/// A value beginning with `--` is rejected rather than accepted, because
/// the failure it otherwise produces is silent. `--environment --dispatch
/// f.jsonl` would run `f.jsonl` in an environment literally named
/// `"--dispatch"`, which `writeGate` treats as an unrecognised environment
/// — gated, not blocked — so an operator checking that production is
/// refused would watch the check pass for the wrong reason. No legitimate
/// environment or path argument starts with `--`.
private func dispatchArguments(in arguments: [String]) -> DispatchArguments? {
    guard let flagIndex = arguments.firstIndex(of: "--dispatch") else { return nil }
    guard let scriptPath = value(after: flagIndex, in: arguments, flag: "--dispatch", named: "<file>") else {
        exit(1)
    }
    var environment = "development"
    if let envFlagIndex = arguments.firstIndex(of: "--environment") {
        guard let name = value(after: envFlagIndex, in: arguments, flag: "--environment", named: "<name>") else {
            exit(1)
        }
        environment = name
    }
    return DispatchArguments(scriptPath: scriptPath, environment: environment)
}

/// Returns the `--capture <directory>` value, or `nil` when the flag is
/// absent. Same shape and same reasoning as `shimSocketPath` above: exits
/// with a message when the flag is present and its value is missing.
private func capturePath(in arguments: [String]) -> String? {
    guard let flagIndex = arguments.firstIndex(of: "--capture") else { return nil }
    guard let path = value(after: flagIndex, in: arguments, flag: "--capture", named: "<directory>") else {
        exit(1)
    }
    return path
}

/// Returns the `--capture-motion <directory>` value, or `nil` when absent.
/// Same shape and reasoning as `capturePath` above.
private func captureMotionPath(in arguments: [String]) -> String? {
    guard let flagIndex = arguments.firstIndex(of: "--capture-motion") else { return nil }
    guard let path = value(after: flagIndex, in: arguments, flag: "--capture-motion", named: "<directory>") else {
        exit(1)
    }
    return path
}

/// Returns the row count `--bench-surface` should run with, when the flag is
/// present in `arguments`; `nil` when absent. Unlike `capturePath` and
/// `captureMotionPath`, a present-but-valueless flag is not an error here —
/// `--bench-surface` alone defaults to 50,000 rows — so a following argument
/// is consumed only when it parses as a non-negative integer; anything else
/// (another flag, or nothing) leaves the default in place rather than
/// exiting.
private func benchSurfaceRowCount(in arguments: [String]) -> Int? {
    guard let flagIndex = arguments.firstIndex(of: "--bench-surface") else { return nil }
    let nextIndex = flagIndex + 1
    if arguments.indices.contains(nextIndex), let rows = Int(arguments[nextIndex]), rows >= 0 {
        return rows
    }
    return 50000
}

/// The argument following `flagIndex`, or `nil` (having written why to
/// stderr) when there is none or it looks like another flag.
private func value(after flagIndex: Int, in arguments: [String], flag: String, named: String) -> String? {
    guard arguments.indices.contains(flagIndex + 1) else {
        FileHandle.standardError.write(Data("wakil: \(flag) requires a \(named) argument\n".utf8))
        return nil
    }
    let value = arguments[flagIndex + 1]
    guard !value.hasPrefix("--") else {
        FileHandle.standardError.write(
            Data("wakil: \(flag) requires a \(named) argument, but got the flag \"\(value)\"\n".utf8))
        return nil
    }
    return value
}

/// Runs `--dispatch <file>` to completion: reads `args.scriptPath` as
/// newline-delimited JSON, runs it through `runDebugScript` against the
/// registry `WakilWiring.build` assembles — the same assembly the window
/// uses (`WindowSession.start` in WakilWindow.swift), so a name that
/// dispatches here dispatches there — journalling to `~/.wakil/journal` (the real journal location, per
/// docs/superpowers/specs/2026-09-07-phase-2a-spine-design.md §4 — this
/// hook is a real consumer of the registry, not test scaffolding, so it
/// writes to the same place the agent bridge does).
///
/// Prints one output line to stdout per **non-empty** line of the script,
/// in order: a blank or whitespace-only line is skipped and produces no
/// output at all, so output line N corresponds to the Nth non-empty line
/// of the file. Lines are split on any Unicode newline rather than on
/// `"\n"` alone, because `"\r\n"` is a single Swift `Character` and a
/// CRLF-saved script would otherwise arrive as one enormous line and
/// produce one parse error for the whole file.
///
/// **Exit codes**, which are the point of running this headlessly:
///
/// - `0` — every line dispatched successfully.
/// - `1` — the run never happened. Two ways to get it, both writing a
///   reason to stderr: the script file could not be read (here), or the
///   arguments never parsed — a `--dispatch` or `--environment` whose
///   value is missing or flag-shaped exits 1 from `dispatchArguments`
///   above, before this function is called at all. `wakil --dispatch
///   f.jsonl --environment` is the second case; verified, it exits 1
///   without reading `f.jsonl`.
/// - `2` — the run happened and at least one line produced an error line
///   (malformed JSON, an unknown action, a gate refusal, a handler that
///   threw). Every other line still ran; `runDebugScript` does not abort.
///
/// Note the inversion this implies for a check whose *expected* result is
/// a refusal — "production blocks a mutation", say. That script exits 2 on
/// success, so its runbook assertion is `[ $? -eq 2 ]`, not `[ $? -eq 0 ]`.
/// Wakil itself never distinguishes an expected error from an unexpected
/// one; only the operator writing the check knows which they meant.
private func runDispatchFile(_ args: DispatchArguments) async -> Int32 {
    let text: String
    do {
        text = try String(contentsOfFile: args.scriptPath, encoding: .utf8)
    } catch {
        FileHandle.standardError.write(Data("wakil --dispatch: could not read \"\(args.scriptPath)\": \(error)\n".utf8))
        return 1
    }
    let lines = text
        .split(whereSeparator: \.isNewline)
        .map(String.init)
        .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

    // Same `HOME`-resolution convention as `buildLaunch` in
    // ClaudeCodeCLIHarness.swift: read `HOME` from the current process's
    // environment rather than `FileManager.default.homeDirectoryForCurrentUser`,
    // which resolves via the system user directory service and ignores an
    // overridden `HOME` env var. Verified on this machine: with `HOME` overridden
    // to a scratch directory, `homeDirectoryForCurrentUser` still pointed at the
    // real account home and this run wrote a real journal entry there — the exact
    // thing the global "never touch the real ~/.wakil" constraint forbids in a
    // test, and worth avoiding here too so `--dispatch` behaves predictably under
    // an overridden `HOME`.
    let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    let journalDirectory = URL(fileURLWithPath: home)
        .appendingPathComponent(".wakil", isDirectory: true)
        .appendingPathComponent("journal", isDirectory: true)

    let wiring = await WakilWiring.build(journalDirectory: journalDirectory, sessionId: UUID().uuidString)
    for note in wiring.diagnostics {
        // stderr, not stdout: stdout is the one-line-per-script-line
        // channel a caller parses, and a missing binary must not shift it.
        FileHandle.standardError.write(Data("wakil --dispatch: \(note)\n".utf8))
    }

    let result = await runDebugScriptReportingFailures(lines, registry: wiring.registry, environment: args.environment)
    for line in result.lines {
        print(line)
    }

    // Before returning, not in a `defer`: these are child processes, and
    // the `exit()` at this function's call site would otherwise orphan
    // every Wakil-owned Go child for as long as it cared to run.
    // `shutdown()` iterates `wakilOwnedClients` (#185): it named two of
    // them literally until 2c-iv added a third, and `wakil-http` is the
    // one most likely to be mid-call when this runs.
    await wiring.shutdown()

    return result.failureCount == 0 ? 0 : 2
}

// This check, and the `exit` below, must be the first thing this file does.
// `--mcp-shim` runs headlessly with no display session (it is spawned as a
// stdio-to-socket pipe for an MCP client, per
// docs/superpowers/specs/2026-09-07-phase-2a-spine-design.md §2.2): if any
// AppKit-touching code below it ran first, it would fail or hang. Since Task
// 11 that is no longer hypothetical — `WakilWindow.swift` imports AppKit and
// SwiftUI, and the last line of this file starts an `NSApplication` — so
// this check and the `--dispatch` one below it stay first, stay
// self-contained, and stay above the only statement in this file that
// touches the display server. `ShimTests` runs the built binary in shim mode
// with no display session and asserts it exits rather than hangs, which is
// what makes that ordering a tested property rather than a convention.
if let socketPath = shimSocketPath(in: CommandLine.arguments) {
    exit(runShim(socketPath: socketPath))
}

// Same reasoning as `--mcp-shim` above: `--dispatch` (the debug dispatch
// hook, design doc §4) also runs headlessly with no display session, so it
// must also be checked, and exit, before any AppKit-touching code.
if let args = dispatchArguments(in: CommandLine.arguments) {
    exit(await runDispatchFile(args))
}

// Offscreen rendering, so it runs without a window — but it does need a
// Metal device, so it sits *below* the two headless checks above rather
// than beside them. `runCapture` is synchronous: every draw is followed by
// `waitUntilCompleted`, because the GPU timestamps are the point.
if let directory = capturePath(in: CommandLine.arguments) {
    exit(runCapture(into: directory))
}

// The motion sequences (spec §8). Same offscreen path as `--capture`, but
// many frames per state rather than one, so the four states can be watched
// rather than inspected — which is the one judgement this sub-phase cannot
// make headlessly.
if let directory = captureMotionPath(in: CommandLine.arguments) {
    exit(runCaptureMotion(into: directory))
}

// Hosts `DataSurface` offscreen over a synthetic result and prints its
// scroll-step cost against the 8.33ms frame budget (task-13-brief.md). Sits
// beside `--capture` and `--capture-motion` rather than beside the two
// headless checks above them: unlike those two, `runSurfaceBench` creates
// `NSApplication.shared` itself (see that function's doc comment for why a
// SwiftUI-hosted `NSWindow` needs one, where an offscreen Metal render does
// not), so it does not need to run before AppKit exists — only before the
// ordinary window launch below claims the application object for itself.
if let rowCount = benchSurfaceRowCount(in: CommandLine.arguments) {
    exit(runSurfaceBench(rows: rowCount))
}

// Neither headless mode applied, so this is an ordinary launch: open the
// window. `WakilApplication.main()` (see WakilWindow.swift) is called rather
// than marked `@main` because a module with a `main.swift` may not also
// declare a `@main` type — and `main.swift` is required here, since the two
// argument checks above have to run before `NSApplication` exists. It never
// returns; the process ends through AppKit's own termination path, which
// `WakilAppDelegate.applicationShouldTerminate` hooks to shut the wiring
// down before it does.
WakilApplication.main()
