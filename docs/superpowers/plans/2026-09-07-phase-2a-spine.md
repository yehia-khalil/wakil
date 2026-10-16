# Wakil Phase 2a — The Spine — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build Wakil.app's load-bearing architecture — an agent harness, an action registry with a single dispatch chokepoint, and an MCP surface Wakil serves itself — proving that a typed command and a mouse click reach pane state by the same path.

**Architecture:** Wakil.app spawns one `claude` process per session over bidirectional stream-json, handing it a `--mcp-config` that names Wakil's own executable running as a `--mcp-shim`. The shim copies JSON-RPC frames between its stdio and a `0700` unix socket back to the app. Inside the app, an `ActionRegistry` projects into that MCP tool list and into SwiftUI controls, and every dispatch — from a control, from the agent, or from a debug hook — enters at one function and appends one journal line. Registry handlers reach the Phase 1 Go binaries as a stdio MCP client; the agent never sees those binaries.

**Tech Stack:** Swift 6.3.2, SwiftPM, `swift-testing`, SwiftUI + AppKit (macOS 26 SDK, Command Line Tools — **no Xcode**). Go 1.27.1 for the existing `wakil-*` binaries, unchanged. No third-party Swift dependencies.

**Spec:** `docs/superpowers/specs/2026-09-07-phase-2a-spine-design.md`

## Global Constraints

- **No Xcode.** Build with `swift build` from Command Line Tools only. `xcrun metal` is absent — no shader compilation, no code signing, no entitlements, no Instruments. Any task needing those belongs to 2b, not here.
- **No third-party Swift packages.** `Package.swift` declares zero external dependencies. JSON-RPC is hand-rolled; the surface is `initialize`, `notifications/initialized`, `tools/list`, `tools/call`.
- **`CGO_ENABLED=0` stays exported in the Makefile** for the Go side. The Swift side must not alter it, and must not add Go code.
- **No test may touch the real `~/.wakil`, `~/.claude*`, or the login Keychain.** Build fixtures in a temp directory. Never set `WAKIL_KEYCHAIN_TEST`.
- **No test may spend the user's Claude subscription.** Only Task 1 runs a live `claude`, and only the operator runs it. Every other test uses recorded fixtures.
- **2a registers zero `.mutate` actions.** The write gate's exhaustive tests use a test-only action declared in the test target.
- **2a ships no styling.** No colours, no motion, no custom fonts, no layout work. `design-language.md` is out of scope until 2b.
- **Comment accuracy is a hard failure.** Every claim written into a comment must have been run.
- **Probe, don't read.** Measure the CLI's and the SDK's behaviour; do not infer it.
- **Never use `git stash`** — the stash stack is shared across worktrees. Use a WIP commit.
- Gate before finishing each task: `swift build`, `swift test`, and for Go-touching tasks `make test`, `make vet`, `make fmt`.

---

## Prerequisite — operator, before Task 1

Task 1 runs a live Claude session. Two things must happen first, both from `docs/wakil/operator-todo.md` §4:

1. **Rotate both `CLAUDE_CODE_OAUTH_TOKEN` values.** They were pasted into an agent transcript on 2026-09-07. `claude setup-token` per config dir, then replace them in `~/.claude-tokens.zsh`.
2. **Develop against `personal` only.** `claude auth status --json` shows `personal` = `max` (unmanaged), `initech` = `team`, `umbrella` = `enterprise`. The latter two may carry managed settings that override the flags this architecture needs.

No other task is blocked on the operator.

---

## File Structure

| Path | Responsibility |
|---|---|
| `app/Package.swift` | SwiftPM manifest: `WakilKit` library, `WakilApp` executable, `WakilKitTests` |
| `app/Sources/WakilKit/MCP/JSONRPC.swift` | `JSONRPCMessage` codable, newline-delimited framing, read/write over any `FileHandle` pair |
| `app/Sources/WakilKit/MCP/MCPClient.swift` | stdio MCP client: spawn a server binary, `initialize`, `listTools`, `callTool` |
| `app/Sources/WakilKit/MCP/MCPServer.swift` | the socket-side server: `tools/list` and `tools/call` backed by the registry |
| `app/Sources/WakilKit/MCP/Shim.swift` | `--mcp-shim` mode: copy frames between stdio and the unix socket |
| `app/Sources/WakilKit/Registry/Action.swift` | `Action`, `ActionKind`, `ActionOrigin`, `ActionError` |
| `app/Sources/WakilKit/Registry/ActionRegistry.swift` | registration, lookup, the single `dispatch` chokepoint |
| `app/Sources/WakilKit/Registry/Journal.swift` | `JournalEntry`, append to `<dir>/<sessionId>.jsonl` |
| `app/Sources/WakilKit/Gate/WriteGate.swift` | the pure `(environment, kind) -> Decision` function |
| `app/Sources/WakilKit/Context/ContextStore.swift` | org/project/environment via the `wakil-ctx` MCP client |
| `app/Sources/WakilKit/Harness/AgentHarness.swift` | the protocol: start, send, events, interrupt, stop |
| `app/Sources/WakilKit/Harness/StreamJSON.swift` | decoding `claude`'s stream-json events |
| `app/Sources/WakilKit/Harness/ClaudeCodeCLIHarness.swift` | process spawn, explicit env, `--mcp-config` generation |
| `app/Sources/WakilKit/Panes/PaneStore.swift` | pane state, owned by the registry; `read_pane` serialisation |
| `app/Sources/WakilApp/main.swift` | argument check for `--mcp-shim` **before** AppKit; otherwise launch the app |
| `app/Sources/WakilApp/WakilWindow.swift` | grey window: text box, table, thought thread, context labels |
| `app/Tests/WakilKitTests/` | one test file per source file above |
| `app/Fixtures/stream-json/` | events recorded by Task 1 |
| `scripts/make-app-bundle.sh` | assemble `Wakil.app` from the SwiftPM product |

---

## Task 1: Record the live probe — fixtures and three unknowns

**This is the only task that runs a live Claude session, and the operator runs it.** Everything downstream is built against what it records, not against assumption.

**Files:**
- Create: `app/Fixtures/stream-json/basic-turn.jsonl`
- Create: `app/Fixtures/stream-json/tool-call.jsonl`
- Create: `docs/wakil/phase-2a-probe.md`

**Interfaces:**
- Consumes: nothing.
- Produces: the fixture files Task 6 decodes, and answers to open questions 1–3 in the spec.

- [ ] **Step 1: Confirm the token rotation happened**

Run: `env CLAUDE_CONFIG_DIR=$HOME/.claude-personal claude auth status --json`
Expected: `"subscriptionType": "max"`, `"apiProvider": "firstParty"`, `"loggedIn": true`.

- [ ] **Step 2: Record a basic turn**

```bash
mkdir -p app/Fixtures/stream-json
cd /Users/operator/conductor/workspaces/wakil/sacramento
echo '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Reply with the single word: ok"}]}}' \
| env -u ANTHROPIC_API_KEY CLAUDE_CONFIG_DIR="$HOME/.claude-personal" \
  claude -p --input-format stream-json --output-format stream-json \
    --include-partial-messages --session-id "$(uuidgen | tr 'A-Z' 'a-z')" \
  > app/Fixtures/stream-json/basic-turn.jsonl
wc -l app/Fixtures/stream-json/basic-turn.jsonl
```

Expected: a non-empty JSONL file. If it is empty or the process hangs, the input framing is wrong — record the actual behaviour in the probe doc rather than working around it.

- [ ] **Step 3: Record a turn that calls an MCP tool**

```bash
make build
cat > /tmp/probe-mcp.json <<'JSON'
{"mcpServers":{"wakil-ctx":{"command":"PWD_PLACEHOLDER/bin/wakil-ctx","env":{"WAKIL_ORG":"personal","WAKIL_PROVIDER":"main"}}}}
JSON
sed -i '' "s|PWD_PLACEHOLDER|$PWD|" /tmp/probe-mcp.json
echo '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Call the get_context tool and show its result."}]}}' \
| env -u ANTHROPIC_API_KEY CLAUDE_CONFIG_DIR="$HOME/.claude-personal" \
  claude -p --input-format stream-json --output-format stream-json \
    --mcp-config /tmp/probe-mcp.json --strict-mcp-config \
    --session-id "$(uuidgen | tr 'A-Z' 'a-z')" \
  > app/Fixtures/stream-json/tool-call.jsonl
```

Expected: the file contains tool-use and tool-result events. **This also answers whether `--strict-mcp-config` survives on the `personal` account.**

- [ ] **Step 4: Answer open question 3 — does `--permission-prompt-tool` see MCP calls?**

```bash
env -u ANTHROPIC_API_KEY CLAUDE_CONFIG_DIR="$HOME/.claude-personal" \
  claude -p --output-format stream-json \
    --mcp-config /tmp/probe-mcp.json --strict-mcp-config \
    --permission-prompts none \
    "Call the get_context tool." 2>&1 | tail -20
```

Expected, and either answer is fine — record which: if the MCP call is **denied**, `--permission-prompts none` covers MCP tools and the gate's second layer works. If it **succeeds**, MCP calls bypass the permission layer and §5's fallback (`--strict-mcp-config` alone, registry as sole chokepoint) is what 2a relies on.

- [ ] **Step 5: Write up the probe**

Create `docs/wakil/phase-2a-probe.md` recording, for each of steps 2–4: the exact command, the observed output, and the conclusion. Include the distinct `"type"` values seen across both fixtures — Task 6 enumerates exactly these and no others.

- [ ] **Step 6: Commit**

```bash
git add app/Fixtures/stream-json docs/wakil/phase-2a-probe.md
git commit -m "probe: record stream-json fixtures and settle the permission-tool question"
```

---

## Task 2: SwiftPM skeleton that builds and tests

**Files:**
- Create: `app/Package.swift`
- Create: `app/Sources/WakilKit/WakilKit.swift`
- Create: `app/Sources/WakilApp/main.swift`
- Create: `app/Tests/WakilKitTests/SmokeTests.swift`
- Modify: `Makefile`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: nothing.
- Produces: targets `WakilKit` (library) and `WakilApp` (executable); `make app-build` and `make app-test`.

- [ ] **Step 1: Write the failing test**

```swift
// app/Tests/WakilKitTests/SmokeTests.swift
import Testing
@testable import WakilKit

@Test func kitVersionIsSet() {
    #expect(WakilKit.version == "2a")
}
```

- [ ] **Step 2: Write the manifest and sources**

```swift
// app/Package.swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Wakil",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "WakilKit"),
        .executableTarget(name: "WakilApp", dependencies: ["WakilKit"]),
        .testTarget(name: "WakilKitTests", dependencies: ["WakilKit"]),
    ]
)
```

```swift
// app/Sources/WakilKit/WakilKit.swift
public enum WakilKit {
    public static let version = "2a"
}
```

```swift
// app/Sources/WakilApp/main.swift
import WakilKit
print("wakil \(WakilKit.version)")
```

- [ ] **Step 3: Run the test**

Run: `cd app && swift test`
Expected: PASS, one test.

- [ ] **Step 4: Wire the Makefile**

Append to `Makefile`, and add `app-build app-test app-bundle` to the `.PHONY` line:

```make
app-build:
	cd app && swift build

app-test:
	cd app && swift test
```

- [ ] **Step 5: Ignore build output**

Append to `.gitignore`:

```
app/.build/
app/Wakil.app/
```

- [ ] **Step 6: Verify and commit**

Run: `make app-build && make app-test && make test && make vet && make fmt`
Expected: all pass — the Go side must be undisturbed.

```bash
git add app Makefile .gitignore
git commit -m "feat: SwiftPM skeleton for Wakil.app"
```

---

## Task 3: JSON-RPC framing

**Files:**
- Create: `app/Sources/WakilKit/MCP/JSONRPC.swift`
- Test: `app/Tests/WakilKitTests/JSONRPCTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `public struct JSONRPCMessage: Codable, Sendable` with `id: JSONRPCID?`, `method: String?`, `params: JSONValue?`, `result: JSONValue?`, `error: JSONRPCError?`
  - `public enum JSONRPCID: Codable, Sendable, Hashable { case number(Int); case string(String) }`
  - `public enum JSONValue: Codable, Sendable, Equatable` — `null`, `bool`, `number(Double)`, `string`, `array([JSONValue])`, `object([String: JSONValue])`
  - `public func encodeFrame(_ m: JSONRPCMessage) throws -> Data` — JSON plus a single `\n`
  - `public struct FrameReader` with `public mutating func push(_ d: Data) -> [JSONRPCMessage]`

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import WakilKit

@Test func encodeFrameEndsWithExactlyOneNewline() throws {
    let m = JSONRPCMessage(id: .number(1), method: "ping", params: nil, result: nil, error: nil)
    let d = try encodeFrame(m)
    #expect(d.last == UInt8(ascii: "\n"))
    #expect(d.dropLast().contains(UInt8(ascii: "\n")) == false)
}

@Test func frameReaderSplitsOnNewlinesAcrossChunks() throws {
    var r = FrameReader()
    let first = r.push(Data(#"{"jsonrpc":"2.0","id":1,"method":"a"}"#.utf8))
    #expect(first.isEmpty)                       // no newline yet: nothing emitted
    let second = r.push(Data("\n".utf8))
    #expect(second.count == 1)
    #expect(second[0].method == "a")
}

@Test func frameReaderEmitsTwoMessagesFromOneChunk() throws {
    var r = FrameReader()
    let out = r.push(Data(#"{"jsonrpc":"2.0","id":1,"method":"a"}\#n{"jsonrpc":"2.0","id":2,"method":"b"}\#n"#.utf8))
    #expect(out.map(\.method) == ["a", "b"])
}

@Test func frameReaderSkipsBlankLinesRatherThanFailing() throws {
    var r = FrameReader()
    let out = r.push(Data(("\n\n" + #"{"jsonrpc":"2.0","id":1,"method":"a"}"# + "\n").utf8))
    #expect(out.count == 1)
}

@Test func jsonValueRoundTripsNestedStructures() throws {
    let v = JSONValue.object(["a": .array([.number(1), .string("x"), .null, .bool(true)])])
    let data = try JSONEncoder().encode(v)
    #expect(try JSONDecoder().decode(JSONValue.self, from: data) == v)
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd app && swift test --filter JSONRPC`
Expected: compile failure — `JSONRPCMessage` is not defined.

- [ ] **Step 3: Implement**

Write `JSONRPC.swift` providing exactly the interfaces listed above. `FrameReader` holds a `Data` buffer, splits on `0x0A`, retains the trailing partial, decodes each complete line, and **skips lines that are empty or whitespace-only**. A line that is non-empty but fails to decode throws — silent loss of a malformed frame would hide protocol drift.

- [ ] **Step 4: Run the tests**

Run: `cd app && swift test --filter JSONRPC`
Expected: PASS, five tests.

- [ ] **Step 5: Mutation-test the framing**

Change `FrameReader.push` to emit the trailing partial line as if complete. Run `swift test --filter JSONRPC -c debug`. Expected: `frameReaderSplitsOnNewlinesAcrossChunks` FAILS on the `first.isEmpty` expectation. Revert, confirm `git diff --exit-code` is clean.

- [ ] **Step 6: Commit**

```bash
git add app/Sources/WakilKit/MCP/JSONRPC.swift app/Tests/WakilKitTests/JSONRPCTests.swift
git commit -m "feat: newline-delimited JSON-RPC framing"
```

---

## Task 4: The action registry, journal, and write gate

These three ship together: the gate is a check inside `dispatch`, and the journal is written by `dispatch`. Splitting them would mean a registry that dispatches without recording, which is never a state worth reviewing.

**Files:**
- Create: `app/Sources/WakilKit/Registry/Action.swift`
- Create: `app/Sources/WakilKit/Registry/ActionRegistry.swift`
- Create: `app/Sources/WakilKit/Registry/Journal.swift`
- Create: `app/Sources/WakilKit/Gate/WriteGate.swift`
- Test: `app/Tests/WakilKitTests/ActionRegistryTests.swift`
- Test: `app/Tests/WakilKitTests/WriteGateTests.swift`

**Interfaces:**
- Consumes: `JSONValue` from Task 3.
- Produces:
  - `public enum ActionKind: String, Sendable { case read, mutate }`
  - `public enum ActionOrigin: String, Codable, Sendable { case ui, agent, debug }`
  - `public struct Action: Sendable` — `name: String`, `description: String`, `kind: ActionKind`, `schema: JSONValue`, `handler: @Sendable (JSONValue) async throws -> JSONValue`
  - `public enum GateDecision: Equatable, Sendable { case allow; case gate; case block }`
  - `public func writeGate(environment: String, kind: ActionKind) -> GateDecision`
  - `public struct JournalEntry: Codable, Sendable` — `id, ts, action, params, origin, paneId, outcome`
  - `public actor ActionRegistry` — `init(journalDirectory: URL, sessionId: String)`, `register(_:)`, `all() -> [Action]`, `dispatch(name:params:origin:environment:confirmation:) async throws -> JSONValue`, `journalEntries() throws -> [JournalEntry]`
  - `public enum ActionError: Error, Equatable { case unknown(String); case needsConfirmation(String); case blockedInProduction(String) }`

- [ ] **Step 1: Write the failing gate tests**

```swift
import Testing
@testable import WakilKit

@Test func readsAreAllowedInEveryEnvironment() {
    for env in ["local", "staging", "production", "anything-else"] {
        #expect(writeGate(environment: env, kind: .read) == .allow)
    }
}

@Test func mutationsAreGatedOutsideProduction() {
    #expect(writeGate(environment: "staging", kind: .mutate) == .gate)
    #expect(writeGate(environment: "local", kind: .mutate) == .gate)
}

@Test func mutationsAreBlockedOutrightInProduction() {
    #expect(writeGate(environment: "production", kind: .mutate) == .block)
}

@Test func productionMatchIsExactAndCaseInsensitive() {
    #expect(writeGate(environment: "PRODUCTION", kind: .mutate) == .block)
    #expect(writeGate(environment: "Production", kind: .mutate) == .block)
    // An unknown environment is gated, not blocked — but never silently allowed.
    #expect(writeGate(environment: "prod", kind: .mutate) == .gate)
}
```

- [ ] **Step 2: Write the failing registry tests**

```swift
import Testing
import Foundation
@testable import WakilKit

private func testAction(_ name: String, _ kind: ActionKind) -> Action {
    Action(name: name, description: "test", kind: kind, schema: .object([:])) { params in
        .object(["echo": params])
    }
}

@Test func dispatchRunsTheHandlerAndReturnsItsValue() async throws {
    let r = ActionRegistry(journalDirectory: FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString), sessionId: "s1")
    await r.register(testAction("db_run_query", .read))
    let out = try await r.dispatch(name: "db_run_query", params: .string("sql"),
                                   origin: .ui, environment: "staging", confirmation: nil)
    #expect(out == .object(["echo": .string("sql")]))
}

@Test func unknownActionThrowsRatherThanSilentlySucceeding() async {
    let r = ActionRegistry(journalDirectory: FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString), sessionId: "s1")
    await #expect(throws: ActionError.unknown("nope")) {
        try await r.dispatch(name: "nope", params: .null, origin: .agent,
                             environment: "staging", confirmation: nil)
    }
}

@Test func journalEntriesAreIdenticalAcrossOriginsExceptForOrigin() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let r = ActionRegistry(journalDirectory: dir, sessionId: "s1")
    await r.register(testAction("db_run_query", .read))
    _ = try await r.dispatch(name: "db_run_query", params: .string("q"),
                             origin: .ui, environment: "staging", confirmation: nil)
    _ = try await r.dispatch(name: "db_run_query", params: .string("q"),
                             origin: .agent, environment: "staging", confirmation: nil)
    let entries = try await r.journalEntries()
    #expect(entries.count == 2)
    #expect(entries[0].origin == .ui)
    #expect(entries[1].origin == .agent)
    #expect(entries[0].action == entries[1].action)
    #expect(entries[0].params == entries[1].params)
    #expect(entries[0].outcome == entries[1].outcome)
}

@Test func mutationWithoutConfirmationIsRefusedAndJournalledAsGated() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let r = ActionRegistry(journalDirectory: dir, sessionId: "s1")
    await r.register(testAction("test.mutate", .mutate))   // test-only: 2a ships no .mutate actions
    await #expect(throws: ActionError.needsConfirmation("test.mutate")) {
        try await r.dispatch(name: "test.mutate", params: .null, origin: .ui,
                             environment: "staging", confirmation: nil)
    }
    let entries = try await r.journalEntries()
    #expect(entries.count == 1)
    #expect(entries[0].outcome == "gated")
}

@Test func mutationInProductionIsBlockedEvenWithCorrectConfirmation() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let r = ActionRegistry(journalDirectory: dir, sessionId: "s1")
    await r.register(testAction("test.mutate", .mutate))
    await #expect(throws: ActionError.blockedInProduction("test.mutate")) {
        try await r.dispatch(name: "test.mutate", params: .null, origin: .ui,
                             environment: "production", confirmation: "confirm")
    }
}

@Test func journalIsAppendedAsOneJSONLineEach() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let r = ActionRegistry(journalDirectory: dir, sessionId: "s1")
    await r.register(testAction("a.b", .read))
    _ = try await r.dispatch(name: "a.b", params: .null, origin: .debug,
                             environment: "staging", confirmation: nil)
    let text = try String(contentsOf: dir.appendingPathComponent("s1.jsonl"), encoding: .utf8)
    #expect(text.hasSuffix("\n"))
    #expect(text.split(separator: "\n").count == 1)
}
```

- [ ] **Step 3: Run to verify they fail**

Run: `cd app && swift test --filter "Registry|Gate"`
Expected: compile failure — none of these types exist.

- [ ] **Step 4: Implement**

Write the four files. `dispatch` does exactly this, in order: look up the action (throw `.unknown`); consult `writeGate(environment:kind:)`; on `.block` journal `"blocked"` and throw `.blockedInProduction`; on `.gate` with `confirmation != "confirm"` journal `"gated"` and throw `.needsConfirmation`; otherwise run the handler, journal `"ok"` or `"error"`, and return. The journal directory is created on demand; each entry is appended as one line plus `\n`.

`writeGate` lowercases the environment and compares to exactly `"production"`.

- [ ] **Step 5: Run the tests**

Run: `cd app && swift test --filter "Registry|Gate"`
Expected: PASS, ten tests.

- [ ] **Step 6: Mutation-test the gate**

Change `writeGate` to return `.allow` for `.mutate` in production. Run `swift test --filter Gate`. Expected: `mutationsAreBlockedOutrightInProduction` FAILS. Revert; confirm `git diff --exit-code`.

Then change `dispatch` to run the handler *before* consulting the gate. Expected: `mutationWithoutConfirmationIsRefusedAndJournalledAsGated` FAILS on the outcome expectation. Revert; confirm clean.

- [ ] **Step 7: Commit**

```bash
git add app/Sources/WakilKit/Registry app/Sources/WakilKit/Gate app/Tests/WakilKitTests
git commit -m "feat: action registry with single dispatch chokepoint, journal, and write gate"
```

---

## Task 5: MCP stdio client, against a real `wakil-ctx`

**Files:**
- Create: `app/Sources/WakilKit/MCP/MCPClient.swift`
- Test: `app/Tests/WakilKitTests/MCPClientTests.swift`

**Interfaces:**
- Consumes: `JSONRPCMessage`, `FrameReader`, `encodeFrame`, `JSONValue` (Task 3).
- Produces:
  - `public actor MCPClient` — `init(executable: URL, arguments: [String], environment: [String: String])`
  - `public func start() async throws` — spawns and completes `initialize` + `notifications/initialized`
  - `public func listTools() async throws -> [MCPToolDescriptor]`
  - `public func callTool(name: String, arguments: JSONValue) async throws -> JSONValue`
  - `public func stop() async`
  - `public struct MCPToolDescriptor: Sendable, Equatable { public let name: String; public let description: String; public let inputSchema: JSONValue }`

- [ ] **Step 1: Write the failing test**

This runs against the **real** `bin/wakil-ctx`, in a temp `WAKIL_HOME`, so no live credentials and no real `~/.wakil` are involved.

```swift
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

    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

    let c = MCPClient(executable: bin, arguments: [],
                      environment: ["HOME": home.path, "WAKIL_ORG": "probe", "PATH": "/usr/bin:/bin"])
    try await c.start()
    let tools = try await c.listTools().map(\.name).sorted()
    await c.stop()

    #expect(tools == ["get_context", "get_session", "list_environments",
                      "list_projects", "list_sessions", "set_environment", "set_project"])
}

@Test func callToolSurfacesAServerSideErrorRatherThanHanging() async throws {
    let bin = repoRoot().appendingPathComponent("bin/wakil-ctx")
    try #require(FileManager.default.isExecutableFile(atPath: bin.path))
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

    let c = MCPClient(executable: bin, arguments: [],
                      environment: ["HOME": home.path, "WAKIL_ORG": "probe", "PATH": "/usr/bin:/bin"])
    try await c.start()
    // No project is registered under org "probe", so this must report an error, not hang.
    let out = try await c.callTool(name: "get_context", arguments: .object([:]))
    await c.stop()
    #expect(out != .null)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `make build && cd app && swift test --filter MCPClient`
Expected: compile failure — `MCPClient` is not defined.

- [ ] **Step 3: Implement**

`MCPClient` wraps a `Process` with `standardInput`/`standardOutput` pipes. `start()` sends `initialize` with `protocolVersion`, `capabilities: {}` and a `clientInfo` of `{"name":"wakil","version":"2a"}`, awaits the response, then sends the `notifications/initialized` notification. Requests carry monotonically increasing integer ids; responses are matched by id through a continuation map. `stop()` terminates the process and drains the pipes.

Every request takes a **10-second timeout** that throws rather than hanging — a hung test is indistinguishable from a slow one, and this client is spawned from a UI.

- [ ] **Step 4: Run the tests**

Run: `cd app && swift test --filter MCPClient`
Expected: PASS, two tests.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/MCP/MCPClient.swift app/Tests/WakilKitTests/MCPClientTests.swift
git commit -m "feat: stdio MCP client, verified against the real wakil-ctx binary"
```

---

## Task 6: stream-json decoding, against Task 1's fixtures

**Files:**
- Create: `app/Sources/WakilKit/Harness/StreamJSON.swift`
- Test: `app/Tests/WakilKitTests/StreamJSONTests.swift`

**Interfaces:**
- Consumes: `FrameReader`, `JSONValue` (Task 3); the fixtures from Task 1.
- Produces:
  - `public enum HarnessEvent: Sendable, Equatable` — `.systemInit(sessionId: String)`, `.assistantText(String)`, `.toolUse(id: String, name: String, input: JSONValue)`, `.toolResult(id: String, content: JSONValue, isError: Bool)`, `.result(isError: Bool, text: String?)`, `.unknown(type: String)`
    - *Amended 2026-09-07: `.toolResult` gained `isError` after review — the probe's §4 `is_error` flag and §6 permission refusal need somewhere to land. See the spec's §3.1 amendment for the reasoning.*
  - `public func decodeHarnessEvents(_ data: Data) throws -> [HarnessEvent]`

- [ ] **Step 1: Write the failing tests**

Read the fixtures rather than inventing events. Replace the `#expect` values below with what `docs/wakil/phase-2a-probe.md` actually recorded — **do not keep an assertion the fixture does not support.**

```swift
import Testing
import Foundation
@testable import WakilKit

private func fixture(_ name: String) throws -> Data {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/stream-json/\(name)")
    return try Data(contentsOf: url)
}

// Neither `.systemInit` nor `.result` sits where this test originally
// assumed. Probe §3: `result|success` is followed by a
// `system|session_state_changed` in both fixtures, so `.result` is not
// last. And the fixtures' *first* line is also a
// `system|session_state_changed` — `system|init` is the *third* line of
// basic-turn and the *second* of tool-call — so `.systemInit` is not first
// either. Both
// must be `contains`, not positional.
@Test func basicTurnYieldsInitAndTextAndResult() throws {
    let events = try decodeHarnessEvents(try fixture("basic-turn.jsonl"))
    #expect(events.isEmpty == false)
    #expect(events.contains { if case .systemInit = $0 { return true }; return false })
    #expect(events.contains { if case .result = $0 { return true }; return false })
    #expect(events.contains { if case .assistantText = $0 { return true }; return false })
}

@Test func toolCallFixtureYieldsAToolUseAndAMatchingResult() throws {
    let events = try decodeHarnessEvents(try fixture("tool-call.jsonl"))
    let uses = events.compactMap { if case .toolUse(let id, _, _) = $0 { return id } else { return nil } }
    let results = events.compactMap { if case .toolResult(let id, _) = $0 { return id } else { return nil } }
    #expect(uses.isEmpty == false)
    #expect(Set(results).isSubset(of: Set(uses)))
}

@Test func anUnrecognisedTypeBecomesUnknownRatherThanThrowing() throws {
    let events = try decodeHarnessEvents(Data((#"{"type":"a_type_that_does_not_exist"}"# + "\n").utf8))
    #expect(events == [.unknown(type: "a_type_that_does_not_exist")])
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd app && swift test --filter StreamJSON`
Expected: compile failure — `decodeHarnessEvents` is not defined.

- [ ] **Step 3: Implement**

Decode each frame's `"type"` and map only the values the probe recorded. Anything else becomes `.unknown(type:)` — never a thrown error. The wire format is a weaker contract than an SDK's types, so an unrecognised event must degrade rather than crash a running session, while still being visible in tests.

- [ ] **Step 4: Run the tests**

Run: `cd app && swift test --filter StreamJSON`
Expected: PASS. Three tests is the floor, not the target — the probe's
specifics (namespaced tool names, a `tool_result` whose content is a JSON
string, a `tool_use` for a tool Wakil never configured, and every fixture
type that has no case arriving as `.unknown`) each need their own.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Harness/StreamJSON.swift app/Tests/WakilKitTests/StreamJSONTests.swift
git commit -m "feat: stream-json event decoding built against recorded fixtures"
```

---

## Task 7: The MCP server and the `--mcp-shim`

**Files:**
- Create: `app/Sources/WakilKit/MCP/MCPServer.swift`
- Create: `app/Sources/WakilKit/MCP/Shim.swift`
- Modify: `app/Sources/WakilApp/main.swift`
- Test: `app/Tests/WakilKitTests/MCPServerTests.swift`
- Test: `app/Tests/WakilKitTests/ShimTests.swift`

**Interfaces:**
- Consumes: `ActionRegistry` (Task 4), `JSONRPCMessage`/`FrameReader` (Task 3).
- Produces:
  - `public actor MCPSocketServer` — `init(registry: ActionRegistry, socketPath: String, environmentProvider: @escaping @Sendable () async -> String)`, `start() async throws`, `stop() async`
  - `public func runShim(socketPath: String) -> Int32` — blocking; returns an exit code
  - `public func handle(_ message: JSONRPCMessage, registry: ActionRegistry, environment: String) async -> JSONRPCMessage?`

- [ ] **Step 1: Write the failing server tests**

`handle` is pure enough to test without a socket, which is where the protocol logic belongs.

```swift
import Testing
import Foundation
@testable import WakilKit

private func reg() async -> ActionRegistry {
    let r = ActionRegistry(journalDirectory: FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString), sessionId: "s1")
    await r.register(Action(name: "db_run_query", description: "run a query",
                            kind: .read, schema: .object(["type": .string("object")])) { p in p })
    return r
}

@Test func initializeIsAnswered() async throws {
    let m = JSONRPCMessage(id: .number(1), method: "initialize", params: .object([:]), result: nil, error: nil)
    let out = await handle(m, registry: await reg(), environment: "staging")
    #expect(out?.id == .number(1))
    #expect(out?.error == nil)
}

@Test func toolsListProjectsTheRegistryPlusReadPane() async throws {
    let m = JSONRPCMessage(id: .number(2), method: "tools/list", params: nil, result: nil, error: nil)
    let out = await handle(m, registry: await reg(), environment: "staging")
    guard case .object(let r)? = out?.result, case .array(let tools)? = r["tools"] else {
        Issue.record("no tools array"); return
    }
    let names = tools.compactMap { t -> String? in
        if case .object(let o) = t, case .string(let n)? = o["name"] { return n }; return nil
    }
    #expect(names.sorted() == ["db_run_query", "read_pane"])
}

@Test func toolsCallDispatchesThroughTheRegistry() async throws {
    let m = JSONRPCMessage(id: .number(3), method: "tools/call",
                           params: .object(["name": .string("db_run_query"),
                                            "arguments": .object(["sql": .string("select 1")])]),
                           result: nil, error: nil)
    let out = await handle(m, registry: await reg(), environment: "staging")
    #expect(out?.error == nil)
}

@Test func anUnknownToolIsAnErrorNotACrash() async throws {
    let m = JSONRPCMessage(id: .number(4), method: "tools/call",
                           params: .object(["name": .string("nope"), "arguments": .object([:])]),
                           result: nil, error: nil)
    let out = await handle(m, registry: await reg(), environment: "staging")
    #expect(out?.error != nil)
}

@Test func aNotificationGetsNoReply() async throws {
    let m = JSONRPCMessage(id: nil, method: "notifications/initialized", params: nil, result: nil, error: nil)
    #expect(await handle(m, registry: await reg(), environment: "staging") == nil)
}
```

- [ ] **Step 2: Write the failing shim test**

```swift
import Testing
import Foundation
@testable import WakilKit

@Test func shimModeIsDetectedBeforeAnyUISetup() throws {
    // The built WakilApp binary must run headlessly in shim mode. If it initialised
    // AppKit it would fail or hang with no display session.
    let exe = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/debug/WakilApp")
    try #require(FileManager.default.isExecutableFile(atPath: exe.path), "run `swift build` first")

    let sock = "/tmp/wakil-test-\(UUID().uuidString).sock"     // deliberately absent
    let p = Process()
    p.executableURL = exe
    p.arguments = ["--mcp-shim", "--socket", sock]
    p.standardError = Pipe()
    p.standardOutput = Pipe()
    try p.run()
    p.waitUntilExit()
    // No socket to connect to, so it must exit non-zero promptly rather than hang or open a window.
    #expect(p.terminationStatus != 0)
}
```

- [ ] **Step 3: Run to verify they fail**

Run: `cd app && swift test --filter "MCPServer|Shim"`
Expected: compile failure.

- [ ] **Step 4: Implement**

`handle` answers `initialize` with `protocolVersion`, `capabilities: {"tools":{}}`, `serverInfo: {"name":"wakil","version":"2a"}`; answers `tools/list` from `registry.all()` plus the one hand-written `read_pane`; answers `tools/call` by dispatching with `origin: .agent`; returns `nil` for any message with no `id`. Registry errors become JSON-RPC errors.

`MCPSocketServer` listens on a unix domain socket created with mode `0700`, unlinking any stale file at that path first.

`runShim` connects to the socket and copies bytes both ways until either side closes. **It parses nothing.** If the connection fails it writes the reason to stderr and returns a non-zero exit code.

`main.swift` checks `CommandLine.arguments` for `--mcp-shim` and calls `exit(runShim(socketPath:))` **before importing or touching AppKit**.

- [ ] **Step 5: Run the tests**

Run: `cd app && swift build && swift test --filter "MCPServer|Shim"`
Expected: PASS, six tests.

- [ ] **Step 6: Mutation-test the notification rule**

Make `handle` return a reply for messages with no `id`. Run `swift test --filter MCPServer`. Expected: `aNotificationGetsNoReply` FAILS. Revert; confirm `git diff --exit-code`.

- [ ] **Step 7: Commit**

```bash
git add app/Sources/WakilKit/MCP app/Sources/WakilApp/main.swift app/Tests/WakilKitTests
git commit -m "feat: registry-backed MCP server and the --mcp-shim transport"
```

---

## Task 8: The harness

**Files:**
- Create: `app/Sources/WakilKit/Harness/AgentHarness.swift`
- Create: `app/Sources/WakilKit/Harness/ClaudeCodeCLIHarness.swift`
- Test: `app/Tests/WakilKitTests/ClaudeCodeCLIHarnessTests.swift`

**Interfaces:**
- Consumes: `HarnessEvent` (Task 6), `FrameReader` (Task 3).
- Produces:
  - `public protocol AgentHarness: Sendable` — `func start(sessionId: String) async throws`, `func send(_ text: String) async throws`, `func events() -> AsyncStream<HarnessEvent>`, `func interrupt() async`, `func stop() async`
  - `public struct HarnessLaunch: Equatable, Sendable { public let executable: String; public let arguments: [String]; public let environment: [String: String] }`
  - `public func buildLaunch(claudePath: String, sessionId: String, configDir: String, oauthToken: String, mcpConfigJSON: String) -> HarnessLaunch`
  - `public final class ClaudeCodeCLIHarness: AgentHarness`

- [ ] **Step 1: Write the failing tests**

`buildLaunch` is pure, so the risky parts — the environment and the flags — are tested without spending a subscription.

```swift
import Testing
@testable import WakilKit

private func launch() -> HarnessLaunch {
    buildLaunch(claudePath: "/opt/homebrew/bin/claude", sessionId: "abc-123",
                configDir: "/Users/x/.claude-personal", oauthToken: "tok",
                mcpConfigJSON: #"{"mcpServers":{}}"#)
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

@Test func executableIsPinnedByAbsolutePath() {
    #expect(launch().executable == "/opt/homebrew/bin/claude")
}

@Test func requiredStreamingFlagsArePresent() {
    let a = launch().arguments
    // `--verbose` per probe §1: without it the real CLI refuses the
    // invocation with `Error: When using --print, --output-format=stream-json
    // requires --verbose`.
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
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd app && swift test --filter Harness`
Expected: compile failure — `buildLaunch` is not defined.

- [ ] **Step 3: Implement**

`buildLaunch` returns exactly the four environment keys asserted above and the flag list from the spec's §3.2. `ClaudeCodeCLIHarness` spawns that launch, feeds `send` as a stream-json user message on stdin, and publishes decoded `HarnessEvent`s through an `AsyncStream`.

**Start fresh:** `start(sessionId:)` always takes a fresh UUID from the caller. `--resume` is not passed here — and is not passed anywhere else in 2a either. Task 9's `session_resume` action *reads* a session's metadata and first prompt in preparation for resuming it; actually resuming a transcript is 2b's.

- [ ] **Step 4: Run the tests**

Run: `cd app && swift test --filter Harness`
Expected: PASS, five tests.

- [ ] **Step 5: Mutation-test the key exclusion**

Add `"ANTHROPIC_API_KEY": "sk-test"` to `buildLaunch`'s environment. Run `swift test --filter Harness`. Expected: both `environmentNeverCarriesAnAPIKey` and `environmentIsBuiltExplicitlyNotInherited` FAIL. Revert; confirm `git diff --exit-code`.

- [ ] **Step 6: Commit**

```bash
git add app/Sources/WakilKit/Harness app/Tests/WakilKitTests/ClaudeCodeCLIHarnessTests.swift
git commit -m "feat: AgentHarness protocol and the Claude Code CLI implementation"
```

---

## Task 9: Context store, pane store, and the real action set

**Files:**
- Create: `app/Sources/WakilKit/Context/ContextStore.swift`
- Create: `app/Sources/WakilKit/Panes/PaneStore.swift`
- Create: `app/Sources/WakilKit/Registry/StandardActions.swift`
- Test: `app/Tests/WakilKitTests/ContextStoreTests.swift`
- Test: `app/Tests/WakilKitTests/StandardActionsTests.swift`

**Interfaces:**
- Consumes: `MCPClient` (Task 5), `ActionRegistry`/`Action` (Task 4).
- Produces:
  - `public actor PaneStore` — `setRows(paneId:columns:rows:)`, `snapshot(paneId:) -> JSONValue`
  - `public actor ContextStore` — `current() async throws -> ActiveContext`, `setProject(_:)`, `setEnvironment(_:)`; `public struct ActiveContext: Equatable, Sendable { public let org, project, environment: String }`
  - `public func registerStandardActions(into:context:panes:db:) async` — registers `ctx_set_project`, `ctx_set_environment`, `ctx_list_projects`, `db_list_databases`, `db_run_query`, `session_resume`, all `.read`

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import WakilKit

@Test func paneSnapshotSerialisesColumnsAndRowsForReadPane() async throws {
    let p = PaneStore()
    await p.setRows(paneId: "db", columns: ["id", "name"],
                    rows: [[.number(1), .string("ada")]])
    let snap = await p.snapshot(paneId: "db")
    guard case .object(let o) = snap else { Issue.record("not an object"); return }
    #expect(o["columns"] == .array([.string("id"), .string("name")]))
    #expect(o["rowCount"] == .number(1))
}

@Test func snapshotOfAnUnknownPaneIsEmptyNotAnError() async {
    let snap = await PaneStore().snapshot(paneId: "nope")
    #expect(snap == .object(["columns": .array([]), "rows": .array([]), "rowCount": .number(0)]))
}

@Test func everyStandardActionIsReadKindIn2a() async throws {
    // 2a ships zero .mutate actions — see the spec's §5 correction.
    let r = ActionRegistry(journalDirectory: FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString), sessionId: "s1")
    await registerStandardActions(into: r, context: nil, panes: PaneStore(), db: nil)
    let kinds = Set(await r.all().map(\.kind))
    #expect(kinds == [.read])
}

@Test func standardActionNamesAreStableAndNamespaced() async throws {
    let r = ActionRegistry(journalDirectory: FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString), sessionId: "s1")
    await registerStandardActions(into: r, context: nil, panes: PaneStore(), db: nil)
    #expect(await r.all().map(\.name).sorted() ==
            ["ctx_list_projects", "ctx_set_environment", "ctx_set_project",
             "db_list_databases", "db_run_query", "session_resume"])
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd app && swift test --filter "Context|StandardActions"`
Expected: compile failure.

- [ ] **Step 3: Implement**

`ContextStore` wraps an `MCPClient` over `bin/wakil-ctx`, mapping `get_context`, `set_project`, `set_environment`. **`setProject` must surface `wakil-ctx`'s refusal of a project filed under another org as a thrown error carrying the server's own message** — never a silent no-op. `PaneStore` holds columns and rows per pane id. `registerStandardActions` takes optional clients so the registry can be tested without spawning binaries; handlers throw a clear error when their client is `nil`.

- [ ] **Step 4: Run the tests**

Run: `cd app && swift test --filter "Context|StandardActions"`
Expected: PASS, four tests.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Context app/Sources/WakilKit/Panes app/Sources/WakilKit/Registry/StandardActions.swift app/Tests/WakilKitTests
git commit -m "feat: context store, pane store, and the 2a action set"
```

---

## Task 10: The debug dispatch hook

Built before the window, because it is what shrinks the operator's manual checklist from eight items to three — and because it is the registry's third real consumer, which is what keeps Invariant 2 honest.

**Files:**
- Create: `app/Sources/WakilKit/Registry/DebugDispatch.swift`
- Modify: `app/Sources/WakilApp/main.swift`
- Test: `app/Tests/WakilKitTests/DebugDispatchTests.swift`

**Interfaces:**
- Consumes: `ActionRegistry` (Task 4).
- Produces: `public func runDebugScript(_ lines: [String], registry: ActionRegistry, environment: String) async -> [String]`, and a `--dispatch <file>` flag on `WakilApp`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import WakilKit

@Test func debugScriptDispatchesAndJournalsWithDebugOrigin() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let r = ActionRegistry(journalDirectory: dir, sessionId: "s1")
    await r.register(Action(name: "a.b", description: "t", kind: .read, schema: .object([:])) { $0 })
    let out = await runDebugScript([#"{"action":"a.b","params":{"x":1}}"#],
                                   registry: r, environment: "staging")
    #expect(out.count == 1)
    let entries = try await r.journalEntries()
    #expect(entries.map(\.origin) == [.debug])
}

@Test func debugScriptReportsAFailureWithoutAbortingLaterLines() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let r = ActionRegistry(journalDirectory: dir, sessionId: "s1")
    await r.register(Action(name: "a.b", description: "t", kind: .read, schema: .object([:])) { $0 })
    let out = await runDebugScript([#"{"action":"missing","params":{}}"#,
                                    #"{"action":"a.b","params":{}}"#],
                                   registry: r, environment: "staging")
    #expect(out.count == 2)
    #expect(out[0].contains("error"))
    #expect(out[1].contains("error") == false)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd app && swift test --filter DebugDispatch`
Expected: compile failure.

- [ ] **Step 3: Implement**

One JSON object per line: `{"action": "...", "params": {...}, "confirmation": "..."}`. Each dispatches with `origin: .debug` and returns a JSON result line. A failing line yields an error line and execution continues. `main.swift` gains `--dispatch <file>`, which runs headlessly and exits — checked alongside `--mcp-shim`, before AppKit.

- [ ] **Step 4: Run the tests**

Run: `cd app && swift test --filter DebugDispatch`
Expected: PASS, two tests.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Registry/DebugDispatch.swift app/Sources/WakilApp/main.swift app/Tests/WakilKitTests/DebugDispatchTests.swift
git commit -m "feat: debug dispatch hook as the registry's third consumer"
```

---

## Task 11: The window, the bundle, and the acceptance runbook

**Files:**
- Create: `app/Sources/WakilApp/WakilWindow.swift`
- Create: `scripts/make-app-bundle.sh`
- Create: `docs/wakil/phase-2a-acceptance.md`
- Modify: `app/Sources/WakilApp/main.swift`
- Modify: `Makefile`

**Interfaces:**
- Consumes: everything above.
- Produces: `Wakil.app`, and `make app-bundle`.

- [ ] **Step 1: Write the window**

A single SwiftUI window, deliberately unstyled: a text field that sends to the harness; a plain `Table` bound to `PaneStore`; a `List` of `HarnessEvent`s as the thought thread; and plain text labels for the active org, project and environment (Invariant 8 — visible, not yet alarming). **No colours, no motion, no custom fonts.** Every control calls `registry.dispatch(..., origin: .ui)`; none mutates pane state directly.

- [ ] **Step 2: Write the bundle script**

```bash
#!/usr/bin/env bash
# Assembles an unsigned Wakil.app from the SwiftPM product. Xcode is not
# required and is not used: 2a needs no shader compilation, signing or
# entitlements. Those arrive with 2b.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-debug}"
APP="app/Wakil.app"
swift build --package-path app -c "$CONFIG"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "app/.build/$CONFIG/WakilApp" "$APP/Contents/MacOS/Wakil"
for b in wakil-ctx wakil-db wakil-http wakil-pm wakil-recall; do
  cp "bin/$b" "$APP/Contents/Resources/$b"
done
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Wakil</string>
  <key>CFBundleIdentifier</key><string>dev.wakil.app</string>
  <key>CFBundleExecutable</key><string>Wakil</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2a</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
echo "built $APP"
```

- [ ] **Step 3: Wire and run it**

Add to `Makefile`:

```make
app-bundle: build
	@bash scripts/make-app-bundle.sh debug
```

Run: `make app-bundle`
Expected: `app/Wakil.app` exists, with the five Go binaries in `Contents/Resources`.

- [ ] **Step 4: Verify the shim still works from inside the bundle**

Run: `app/Wakil.app/Contents/MacOS/Wakil --mcp-shim --socket /tmp/absent.sock; echo "exit=$?"`
Expected: a non-zero exit and an error on stderr — **no window, no hang.**

- [ ] **Step 5: Write the acceptance runbook**

Create `docs/wakil/phase-2a-acceptance.md` with the operator's three standing checks — a window appears and stays; a real turn against `personal` returns an answer; the thought thread renders progressively — each with the exact command, what to look for, and a place to record the result and date. Then the five one-time checks (dual-drive equivalence, the write gate, production blocked, context re-pointing, cross-org isolation) with the `--dispatch` script that replaces each once confirmed.

- [ ] **Step 6: Full gate and commit**

Run: `make app-build && make app-test && make app-bundle && make test && make vet && make fmt`
Expected: all pass.

```bash
git add app scripts/make-app-bundle.sh docs/wakil/phase-2a-acceptance.md Makefile
git commit -m "feat: unstyled window, app bundle, and the 2a acceptance runbook"
```

---

## Self-review notes

**Spec coverage.** §2.1 → Tasks 7, 9. §2.2 → Task 7. §2.3 → Task 7 (`tools/list` projection, `read_pane` the only hand-written tool). §2.4 → Task 8 (`--mcp-config` carries `WAKIL_ORG`/`WAKIL_PROVIDER`). §3.1–3.2 → Task 8. §3.3 → Task 8 step 3 and `session_resume` in Task 9. §3.4 → Task 1. §4 → Tasks 4, 10. §5 → Task 4. §6 → Task 9. §7 → Task 11. §8 → every task's tests plus Task 11 step 5. §9 → Task 2. §10 → Task 1. §11 open questions 1–3 → Task 1 and Task 3 (hand-rolled JSON-RPC confirmed by building it).

**Known gap, deliberate.** The spec's §8 lists JSON-RPC framing tests "both client and shim directions". The shim is a byte copier and is covered only by the headless-exit test in Task 7; a full round-trip through a live socket is exercised by the operator runbook in Task 11, not by a unit test. Closing that properly needs a socket test harness, which is worth adding in 2b when the app is long-running.
