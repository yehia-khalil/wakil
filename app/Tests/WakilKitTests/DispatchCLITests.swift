import Testing
import Foundation
@testable import WakilKit

/// The `--dispatch` CLI path, exercised the same way `ShimTests` exercises
/// `--mcp-shim`: by running the built `WakilApp` binary as a subprocess.
/// Nothing here can be reached from inside the test process — `--dispatch`
/// is argument parsing plus `exit()` in `main.swift`, in the `WakilApp`
/// executable target, which a test target cannot import — so the
/// subprocess is the only way to cover it at all.
///
/// Every run below gets a scratch `HOME` and an explicit `WAKIL_BIN_DIR`,
/// so no run can read or write the real `~/.wakil` (the journal
/// `--dispatch` writes lands under the scratch `HOME`) or spawn a Go
/// binary the test did not choose.

private func repoRootFromTestFile() -> URL {
    URL(fileURLWithPath: #filePath)          // app/Tests/WakilKitTests/DispatchCLITests.swift
        .deletingLastPathComponent()          // WakilKitTests
        .deletingLastPathComponent()          // Tests
        .deletingLastPathComponent()          // app
        .deletingLastPathComponent()          // repo root
}

private func wakilAppBinary() -> URL {
    repoRootFromTestFile().appendingPathComponent("app/.build/debug/WakilApp")
}

private func scratchDirectory() throws -> URL {
    let dir = testScratchRoot.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// The same minimal `~/.wakil` fixture `ContextStoreTests` writes: one org
/// directory and one project registered under it, written directly rather
/// than through the `wakil` CLI, into a fresh scratch `HOME`.
private func makeContextFixture(org: String) throws -> URL {
    let home = try scratchDirectory()
    let orgDir = home.appendingPathComponent(".wakil/orgs/\(org)")
    try FileManager.default.createDirectory(at: orgDir, withIntermediateDirectories: true)

    let projectDir = home.appendingPathComponent("proj")
    try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
    let projectPath = projectDir.appendingPathComponent("project.json")
    let projectJSON = """
    {"name":"widgets","org":"\(org)","roots":[{"path":"/tmp/widgets"}],"scopes":{},\
    "environments":{"dev":{"databases":[]}}}
    """
    try projectJSON.write(to: projectPath, atomically: true, encoding: .utf8)
    let registryJSON = "{\"widgets\":{\"path\":\"\(projectPath.path)\"}}"
    try registryJSON.write(to: orgDir.appendingPathComponent("projects.json"), atomically: true, encoding: .utf8)
    return home
}

private struct DispatchRun {
    var exitCode: Int32
    var stdoutLines: [String]
    var stderr: String
}

/// Runs the built binary with `arguments`, under `home` as `HOME` and
/// `binDir` as `WAKIL_BIN_DIR`, and returns what came back. The
/// environment is built from nothing rather than inherited, so a stray
/// `WAKIL_ORG` (or a real `HOME`) in whatever shell ran the suite cannot
/// change the result.
private func runDispatchBinary(
    arguments: [String], home: URL, binDir: URL, org: String = "acme"
) throws -> DispatchRun {
    let exe = wakilAppBinary()
    try #require(FileManager.default.isExecutableFile(atPath: exe.path), "run `swift build --package-path app` first")

    let p = Process()
    p.executableURL = exe
    p.arguments = arguments
    p.environment = [
        "HOME": home.path,
        "PATH": "/usr/bin:/bin",
        "WAKIL_BIN_DIR": binDir.path,
        "WAKIL_ORG": org,
    ]
    let out = Pipe()
    let err = Pipe()
    p.standardOutput = out
    p.standardError = err
    try p.run()
    // Read before waiting: a pipe buffer that fills while nothing drains it
    // would deadlock the child.
    let outData = out.fileHandleForReading.readDataToEndOfFile()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()

    let text = String(decoding: outData, as: UTF8.self)
    return DispatchRun(
        exitCode: p.terminationStatus,
        stdoutLines: text.split(whereSeparator: \.isNewline).map(String.init),
        stderr: String(decoding: errData, as: UTF8.self)
    )
}

/// The regression this whole file exists for: as first delivered,
/// `--dispatch` built a bare `ActionRegistry` and registered nothing into
/// it, so *every* real action name came back `unknown(...)`. A registry
/// reached through the shared wiring knows the standard action set even
/// when the Go binary behind an action is absent — the handler then
/// reports which client is missing, which is a different and far more
/// useful failure than "no such action".
@Test func dispatchResolvesRealActionNamesThroughTheSharedWiring() throws {
    let home = try scratchDirectory()
    let emptyBin = try scratchDirectory()     // deliberately contains no binaries
    let script = home.appendingPathComponent("script.jsonl")
    try #"{"action":"db_run_query","params":{"query":"select 1"}}"#
        .write(to: script, atomically: true, encoding: .utf8)

    let run = try runDispatchBinary(arguments: ["--dispatch", script.path], home: home, binDir: emptyBin)

    #expect(run.stdoutLines.count == 1)
    let line = try #require(run.stdoutLines.first)
    #expect(line.contains("unknown") == false, "the action was not registered at all: \(line)")
    #expect(line.contains("no database MCP client was provided"), "unexpected output: \(line)")
}

/// A CRLF-saved script must still be one dispatch per line. `split(separator:
/// "\n")` does not split `"\r\n"` — it is a single Swift grapheme cluster —
/// so the whole file used to arrive as one line and produce a single
/// baffling parse error.
@Test func dispatchSplitsCRLFScriptsIntoOneDispatchPerLine() throws {
    let home = try scratchDirectory()
    let emptyBin = try scratchDirectory()
    let script = home.appendingPathComponent("crlf.jsonl")
    let body = [
        #"{"action":"db_list_databases","params":{}}"#,
        #"{"action":"ctx_list_projects","params":{}}"#,
    ].joined(separator: "\r\n") + "\r\n"
    try body.write(to: script, atomically: true, encoding: .utf8)

    let run = try runDispatchBinary(arguments: ["--dispatch", script.path], home: home, binDir: emptyBin)

    #expect(run.stdoutLines.count == 2)
    #expect(run.stdoutLines.allSatisfy { $0.contains("invalid JSON") == false }, "\(run.stdoutLines)")
}

/// Blank lines (and a trailing newline) must not produce output lines of
/// their own, or the "one output line per non-empty input line"
/// correspondence an operator reads the output against would shift.
@Test func dispatchSkipsBlankLinesRatherThanErroringOnThem() throws {
    let home = try scratchDirectory()
    let emptyBin = try scratchDirectory()
    let script = home.appendingPathComponent("blanks.jsonl")
    let body = "\n\n" + #"{"action":"db_list_databases","params":{}}"# + "\n   \n\n"
    try body.write(to: script, atomically: true, encoding: .utf8)

    let run = try runDispatchBinary(arguments: ["--dispatch", script.path], home: home, binDir: emptyBin)

    #expect(run.stdoutLines.count == 1, "\(run.stdoutLines)")
}

/// The exit code is what lets Task 11's runbook assert headlessly instead
/// of reading output by eye: non-zero when any line produced an error.
@Test func dispatchExitsNonZeroWhenAnyLineErrored() throws {
    let home = try scratchDirectory()
    let emptyBin = try scratchDirectory()
    let script = home.appendingPathComponent("bad.jsonl")
    try #"{"action":"no.such.action","params":{}}"#
        .write(to: script, atomically: true, encoding: .utf8)

    let run = try runDispatchBinary(arguments: ["--dispatch", script.path], home: home, binDir: emptyBin)

    #expect(run.exitCode != 0)
}

/// ...and zero when every line succeeded, which needs a real action
/// running against a real Go binary — the end-to-end proof that the shared
/// wiring actually spawns and talks to `wakil-ctx`, not just that it
/// registers names.
@Test func dispatchExitsZeroAndReturnsRealResultsWhenTheBinariesArePresent() throws {
    let home = try makeContextFixture(org: "acme")
    let binDir = repoRootFromTestFile().appendingPathComponent("bin")
    try #require(FileManager.default.isExecutableFile(atPath: binDir.appendingPathComponent("wakil-ctx").path),
                 "run `make build` first")
    let script = home.appendingPathComponent("ok.jsonl")
    try #"{"action":"ctx_list_projects","params":{}}"#
        .write(to: script, atomically: true, encoding: .utf8)

    let run = try runDispatchBinary(arguments: ["--dispatch", script.path], home: home, binDir: binDir)

    #expect(run.exitCode == 0, "stderr: \(run.stderr)")
    let line = try #require(run.stdoutLines.first)
    #expect(line.contains("widgets"), "unexpected output: \(line)")
}

/// A `--dispatch` run journals under the `HOME` it was given, not the
/// account's real home directory — the property that makes every test in
/// this file safe to run.
@Test func dispatchJournalsUnderTheGivenHome() throws {
    let home = try scratchDirectory()
    let emptyBin = try scratchDirectory()
    let script = home.appendingPathComponent("j.jsonl")
    try #"{"action":"db_list_databases","params":{}}"#
        .write(to: script, atomically: true, encoding: .utf8)

    _ = try runDispatchBinary(arguments: ["--dispatch", script.path], home: home, binDir: emptyBin)

    let journalDir = home.appendingPathComponent(".wakil/journal")
    let entries = try FileManager.default.contentsOfDirectory(atPath: journalDir.path)
    #expect(entries.count == 1)
    let text = try String(contentsOf: journalDir.appendingPathComponent(try #require(entries.first)), encoding: .utf8)
    #expect(text.contains("\"origin\":\"debug\""))
}

/// `--environment` with no value used to be silently ignored, leaving the
/// run on `development` while the operator believed they had selected
/// something else — the one flag whose whole purpose is to decide whether
/// the write gate blocks.
@Test func dispatchRejectsAnEnvironmentFlagWithNoValue() throws {
    let home = try scratchDirectory()
    let emptyBin = try scratchDirectory()
    let script = home.appendingPathComponent("e.jsonl")
    try #"{"action":"db_list_databases","params":{}}"#
        .write(to: script, atomically: true, encoding: .utf8)

    let run = try runDispatchBinary(
        arguments: ["--dispatch", script.path, "--environment"], home: home, binDir: emptyBin)

    #expect(run.exitCode != 0)
    #expect(run.stderr.contains("--environment"))
    #expect(run.stdoutLines.isEmpty, "nothing should have been dispatched: \(run.stdoutLines)")
}

/// `--environment --dispatch f` used to run the script with the
/// environment string `"--dispatch"`, which the write gate treats as an
/// unrecognised (therefore gated, not blocked) environment — a silently
/// wrong answer rather than an error.
@Test func dispatchRejectsAnEnvironmentValueThatIsAnotherFlag() throws {
    let home = try scratchDirectory()
    let emptyBin = try scratchDirectory()
    let script = home.appendingPathComponent("e2.jsonl")
    try #"{"action":"db_list_databases","params":{}}"#
        .write(to: script, atomically: true, encoding: .utf8)

    let run = try runDispatchBinary(
        arguments: ["--environment", "--dispatch", script.path], home: home, binDir: emptyBin)

    #expect(run.exitCode != 0)
    #expect(run.stderr.contains("--environment"))
    #expect(run.stdoutLines.isEmpty, "nothing should have been dispatched: \(run.stdoutLines)")
}
