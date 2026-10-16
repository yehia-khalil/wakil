# ToolCaller Seam Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Put a one-method protocol between the action layer's handlers and `MCPClient`, so an action can be tested against an in-memory adapter instead of a spawned shell script.

**Architecture:** `ToolCaller` declares the single operation the handlers use — call a tool by name, with arguments and a timeout. `MCPClient` conforms unchanged; a recording actor in the test target is the second adapter. Nothing about lifecycle (`start`, `stop`, the restart-in-place an org switch performs) joins the protocol, so `AppWiring` keeps holding concrete `MCPClient`s and its wiring constraint is untouched. The change is type-widening at three declaration sites, then the test work the widening makes possible.

**Tech Stack:** Swift 6 (`swift-tools-version: 6.0`, macOS 14.4), Swift Testing (`@Test`/`@Suite`), SwiftPM. Go 1.27 side untouched.

**Spec:** https://github.com/yehia-khalil/rafiq/issues/103

**Measured by:** — no probe. Skipping that rung is a decision with a name: this sub-phase has no unknown a spike would measure. Every fact the plan rests on was read off the shipped code during the 2026-09-18 architecture review — the subprocess harness, the `.serialized` suite, the three helpers' own doc comments, and the 8-of-26 coverage map. There is nothing here to pre-register.

## Global Constraints

- **The protocol carries exactly one method.** `start`, `stop`, `listTools`, reply budgets, drain abandonment and `AbandonedDrain` stay off it. A second method is a signal the seam moved, and must be raised before it is added.
- **`MCPClient.readReplyTimeout` and `MCPClient.mutationReplyTimeout` stay on `MCPClient`.** They describe the real transport's reply budget, not the call; tests do not need them; and moving them would churn eight doc-comment citations for no testability gain. Handlers keep writing `MCPClient.readReplyTimeout`.
- **`AppWiring.contextClient` and `AppWiring.databaseClient` stay typed `MCPClient?`.** That module owns lifecycle, which is exactly what is not on the protocol.
- **Invariant 10 is unweakened, and Decision 3 is untouched.** The protocol sits on the action side as a caller's view of a capability process. No capability moves in-app.
- **Invariant 1 is untouched.** The protocol names a tool call. It does not know a harness or a model exists.
- **No behaviour change in production.** Every step is type-widening or test work. A production semantic that changes is a defect in this plan.
- **Existing tests that assert projections must pass unchanged.** If one needs editing, stop: the seam is in the wrong place.
- **Gates, run from the repo root:** `make test` (Go, must stay green and untouched) and `make app-test` (Swift). Scoped runs during a task: `cd app && ../scripts/swift-test.sh --filter <TestName>`.
- **Do not run the full suite from a subagent.** Scoped `--filter` runs only; the controller runs `make app-test`.

---

### Task 1: The port, its conformance, and the recording adapter

**Files:**
- Create: `app/Sources/WakilKit/MCP/ToolCaller.swift`
- Create: `app/Tests/WakilKitTests/ToolCallerTests.swift`

**Interfaces:**
- Consumes: `JSONValue` (`app/Sources/WakilKit/MCP/JSONRPC.swift:132`, already `Codable, Sendable, Equatable`); `MCPClient.callTool(name:arguments:timeout:)` (`app/Sources/WakilKit/MCP/MCPClient.swift:342`).
- Produces: `public protocol ToolCaller: Sendable` with `func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue`; `extension MCPClient: ToolCaller {}`; and in the test target `actor RecordingToolCaller: ToolCaller` with `init(reply:)`, `init(always:)`, `var calls: [RecordingToolCaller.Call]`, and `struct Call { let name: String; let arguments: JSONValue; let timeout: TimeInterval }`. Tasks 2–8 all use `RecordingToolCaller`.

- [ ] **Step 1: Write the failing test**

Create `app/Tests/WakilKitTests/ToolCallerTests.swift`:

```swift
import Foundation
import Testing
@testable import WakilKit

/// The second adapter at the `ToolCaller` seam, and the one that makes the
/// seam real rather than hypothetical: the first is `MCPClient` over a
/// subprocess, this one answers from memory. It records every call so a
/// test can assert what reached the wire, which is what the stub server's
/// request log used to be for.
actor RecordingToolCaller: ToolCaller {
    struct Call: Equatable, Sendable {
        let name: String
        let arguments: JSONValue
        let timeout: TimeInterval
    }

    private(set) var calls: [Call] = []
    private let reply: @Sendable (String, JSONValue) throws -> JSONValue

    /// `reply` receives the tool name and arguments, so a test can vary the
    /// result per tool — which the stub script could not do at all.
    init(reply: @escaping @Sendable (String, JSONValue) throws -> JSONValue) {
        self.reply = reply
    }

    /// Answers every tool with the same result.
    init(always result: JSONValue) {
        self.reply = { _, _ in result }
    }

    func callTool(
        name: String, arguments: JSONValue, timeout: TimeInterval
    ) async throws -> JSONValue {
        calls.append(Call(name: name, arguments: arguments, timeout: timeout))
        return try reply(name, arguments)
    }
}

@Suite struct ToolCallerTests {
    @Test func theRecordingAdapterReturnsItsCannedResultAndRecordsTheCall() async throws {
        let caller = RecordingToolCaller(always: .object(["ok": .bool(true)]))

        let result = try await caller.callTool(
            name: "query", arguments: .object(["sql": .string("select 1")]), timeout: 10)

        #expect(result == .object(["ok": .bool(true)]))
        let calls = await caller.calls
        #expect(calls == [RecordingToolCaller.Call(
            name: "query", arguments: .object(["sql": .string("select 1")]), timeout: 10)])
    }

    @Test func theReplyClosureCanVaryTheResultPerToolName() async throws {
        let caller = RecordingToolCaller(reply: { name, _ in
            name == "list_tables" ? .array([.string("users")]) : .object([:])
        })

        #expect(try await caller.callTool(
            name: "list_tables", arguments: .object([:]), timeout: 10) == .array([.string("users")]))
        #expect(try await caller.callTool(
            name: "query", arguments: .object([:]), timeout: 10) == .object([:]))
    }

    /// The conformance that makes the seam load-bearing: production's
    /// adapter satisfies the port without a line of adaptation.
    @Test func theLiveClientIsAToolCaller() async throws {
        let client = MCPClient(
            executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], environment: [:])
        let asPort: any ToolCaller = client
        #expect(asPort is MCPClient)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && ../scripts/swift-test.sh --filter ToolCallerTests`
Expected: FAIL to compile — `cannot find type 'ToolCaller' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `app/Sources/WakilKit/MCP/ToolCaller.swift`:

```swift
import Foundation

/// The one operation the action layer performs against a capability
/// process: call a tool by name and read its raw `result`.
///
/// **Why this exists as a protocol and `MCPClient` alone did not suffice.**
/// The handlers `registerStandardActions` builds were registered against
/// the concrete actor, which owns a subprocess. That left a test exactly
/// one seam — spawn a fake MCP server in `/bin/sh`, handshake with it, and
/// grep a request log — and the cost is recorded in the code it produced:
/// fifty serialized tests, three functions extracted only so something
/// could be tested without a client, and 18 of 26 registered actions with
/// no reachable missing-client path.
///
/// **What is deliberately NOT here.** Lifecycle — `start`, `stop`, the
/// restart-in-place `AppWiring` performs on an org switch — and the reply
/// budgets (`MCPClient.readReplyTimeout`, `MCPClient.mutationReplyTimeout`)
/// stay on the concrete type. A caller that needs those needs the client,
/// not the port, and `AppWiring` is that caller. Adding a second
/// requirement here is a design change, not a convenience.
///
/// **Two adapters, so the seam is real rather than hypothetical:**
/// `MCPClient` over a subprocess in production, and `RecordingToolCaller`
/// in the test target.
///
/// Invariant 10 is unweakened by this: the port is a caller's view of a
/// capability process from the action side, and the capability layer stays
/// a separate headless process (Decision 3).
public protocol ToolCaller: Sendable {
    /// Calls `name` with `arguments` and returns the raw `result` value.
    ///
    /// A server-side tool failure — the `wakil-ctx` pattern of returning a
    /// `CallToolResult` carrying `isError: true` — is a *successful* call
    /// and comes back as a normal result object. Only a transport- or
    /// protocol-level failure throws. `callChecked` in `StandardActions`
    /// is what reads the tool-specific `isError` out of the result, and
    /// every handler goes through it.
    func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue
}

/// `callTool` already has this exact signature, so the conformance is
/// empty: the port was extracted from the client, not imposed on it.
extension MCPClient: ToolCaller {}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd app && ../scripts/swift-test.sh --filter ToolCallerTests`
Expected: PASS, 3 tests.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/MCP/ToolCaller.swift app/Tests/WakilKitTests/ToolCallerTests.swift
git commit -m "Add the ToolCaller port and its two adapters (#103)"
```

---

### Task 2: The action layer takes the port

**Files:**
- Modify: `app/Sources/WakilKit/Registry/StandardActions.swift` — `registerStandardActions` signature (~line 236), its doc comment (~line 228), `callChecked` (line 1998)
- Modify: `app/Sources/WakilKit/App/AppWiring.swift` — doc comment at line 433 only
- Test: `app/Tests/WakilKitTests/StandardActionsTests.swift` (add one test)

**Interfaces:**
- Consumes: `ToolCaller`, `RecordingToolCaller` from Task 1.
- Produces: `registerStandardActions(into:context:panes:db:resumes:providerSwitches:layout:)` with `context: (any ToolCaller)?` and `db: (any ToolCaller)?`; `callChecked(_ client: any ToolCaller, tool:arguments:action:timeout:)`. Tasks 4–8 register against fakes through this signature.

- [ ] **Step 1: Write the failing test**

Append to `app/Tests/WakilKitTests/StandardActionsTests.swift`, inside the existing top-level `@Suite` that holds the routing tests (the one beginning at line 585):

```swift
/// The test the seam exists for: a DB read, dispatched end to end, with no
/// subprocess, no handshake and no shell script. Before `ToolCaller` this
/// could only be written by spawning a stub server.
@Test func aDatabaseReadRunsAgainstAnInMemoryAdapter() async throws {
    let db = RecordingToolCaller(always: .object([
        "content": .array([.object(["type": .string("text"), "text": .string("stub")])]),
        "structuredContent": .object([
            "columns": .array([.string("id")]),
            "rows": .array([.array([.integer(1)])]),
        ]),
    ]))
    let panes = PaneStore()
    let registry = ActionRegistry(
        journalDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString),
        sessionId: "s1")
    await registerStandardActions(
        into: registry, context: nil, panes: panes, db: db, resumes: ResumeBroker())

    _ = try await registry.dispatch(
        name: "db_run_query", params: .object(["query": .string("select 1")]),
        origin: .ui, environment: "staging", confirmation: nil)

    let calls = await db.calls
    #expect(calls.count == 1)
    #expect(calls.first?.name == "query")
    #expect(calls.first?.timeout == MCPClient.readReplyTimeout)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && ../scripts/swift-test.sh --filter aDatabaseReadRunsAgainstAnInMemoryAdapter`
Expected: FAIL to compile — `cannot convert value of type 'RecordingToolCaller' to expected argument type 'MCPClient?'`.

- [ ] **Step 3: Write minimal implementation**

In `app/Sources/WakilKit/Registry/StandardActions.swift`, change the two parameters:

```swift
public func registerStandardActions(
    into registry: ActionRegistry,
    context: (any ToolCaller)?,
    panes: PaneStore,
    db: (any ToolCaller)?,
```

and `callChecked` at line 1998:

```swift
private func callChecked(
    _ client: any ToolCaller, tool: String, arguments: JSONValue, action: String, timeout: TimeInterval
) async throws -> JSONValue {
```

Replace the paragraph of the `registerStandardActions` doc comment that currently begins *"`context` and `db` are optional so this function"* with:

```swift
/// `context` and `db` are `ToolCaller`s rather than `MCPClient`s, and
/// optional. The port is what makes an action testable without spawning a
/// Go binary (see `ToolCaller`); the optionality is what makes it testable
/// without any adapter at all — passing `nil` for one still registers
/// every action that needs it, and that action's handler throws
/// `StandardActionError.missingClient` instead of crashing on a forced
/// unwrap or silently returning something that looks like success.
///
/// The reply budgets the handlers pass — `MCPClient.readReplyTimeout` and
/// `MCPClient.mutationReplyTimeout` — stay on the concrete client on
/// purpose: they describe the real transport, not the call, and no test
/// needs to vary them.
```

In `app/Sources/WakilKit/App/AppWiring.swift`, line 433, the doc comment says *"`registerStandardActions`'s captured `Optional<MCPClient>`"*. Change that phrase to:

```swift
    /// `registerStandardActions`'s captured `Optional<any ToolCaller>` and nil
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd app && ../scripts/swift-test.sh --filter aDatabaseReadRunsAgainstAnInMemoryAdapter`
Expected: PASS.

Then confirm the widening broke no caller — 52 existing `registerStandardActions` call sites across seven test files pass `nil` or an `MCPClient`, and both convert implicitly:

Run: `cd app && ../scripts/swift-test.sh --filter StandardActionsTests`
Expected: PASS, no compile errors.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Registry/StandardActions.swift app/Sources/WakilKit/App/AppWiring.swift app/Tests/WakilKitTests/StandardActionsTests.swift
git commit -m "Register standard actions against the port, not the client (#103)"
```

---

### Task 3: ContextStore takes the port

**Files:**
- Modify: `app/Sources/WakilKit/Context/ContextStore.swift:166-168` (stored property and initialiser), and the doc comment at line 99
- Test: `app/Tests/WakilKitTests/ContextStoreTests.swift` (add one test)

**Interfaces:**
- Consumes: `ToolCaller`, `RecordingToolCaller`.
- Produces: `ContextStore.init(client: any ToolCaller)`.

- [ ] **Step 1: Write the failing test**

Append to `app/Tests/WakilKitTests/ContextStoreTests.swift`, inside its existing suite:

```swift
/// What `ContextStore` puts on the wire was previously observable only
/// with a live `wakil-ctx` or a stub script. `current()` is the store's
/// one public call, and its private `callChecked` gives every call the
/// read budget — a fact nothing asserted until now.
@Test func theStoreCallsGetContextWithTheReadBudget() async throws {
    let client = RecordingToolCaller(always: .object([
        "content": .array([.object(["type": .string("text"), "text": .string("{}")])]),
        "structuredContent": .object([
            "Org": .string("initech"),
            "Environment": .string("staging"),
        ]),
    ]))
    let store = ContextStore(client: client)

    // Whether that result satisfies `parseActiveContext` is not this
    // test's subject — that mapping already has its own tests against a
    // literal `JSONValue`. What is new, and was untestable before the
    // port, is what reached the wire.
    _ = try? await store.current()

    let calls = await client.calls
    #expect(calls.count == 1)
    #expect(calls.first?.name == "get_context")
    #expect(calls.first?.arguments == .object([:]))
    #expect(calls.first?.timeout == MCPClient.readReplyTimeout)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && ../scripts/swift-test.sh --filter theStoreCallsGetContextWithTheReadBudget`
Expected: FAIL to compile — `cannot convert value of type 'RecordingToolCaller' to expected argument type 'MCPClient'`.

- [ ] **Step 3: Write minimal implementation**

In `app/Sources/WakilKit/Context/ContextStore.swift`:

```swift
    private let client: any ToolCaller

    public init(client: any ToolCaller) {
```

And at line 99, the type's doc comment currently opens *"Wraps an `MCPClient` already started against `bin/wakil-ctx`"*. Change that clause to:

```swift
/// Wraps a `ToolCaller` — in production an `MCPClient` already started
/// against `bin/wakil-ctx` — mapping one
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd app && ../scripts/swift-test.sh --filter ContextStoreTests`
Expected: PASS, including the existing tests unchanged.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Context/ContextStore.swift app/Tests/WakilKitTests/ContextStoreTests.swift
git commit -m "ContextStore holds the port (#103)"
```

---

### Task 4: Replace the stubbed-database harness

**Files:**
- Modify: `app/Tests/WakilKitTests/StandardActionsTests.swift:236-302` — `standardActionsOverStubbedDatabase` and `withStubClientStoppedAfterwards`

**Interfaces:**
- Consumes: `RecordingToolCaller`, the widened `registerStandardActions`.
- Produces: `standardActionsOverStubbedDatabase(queryResult:layout:) async throws -> (registry: ActionRegistry, panes: PaneStore, client: RecordingToolCaller)` — note the third element's type changes, and it no longer needs stopping.

- [ ] **Step 1: Replace the harness**

Delete `withStubClientStoppedAfterwards` entirely — there is no process to stop. Replace `standardActionsOverStubbedDatabase` and the comment block above it with:

```swift
// Before `ToolCaller` existed, controlling a DB action's replies meant a
// fake MCP server in `/bin/sh`, a real handshake and a spawned process,
// because `MCPClient` was a concrete actor over a subprocess and
// `wakil-db`'s `query` tool needs Keychain-backed credentials no test here
// may touch. The port removed the subprocess; the harness kept its shape
// and its name so the tests below read unchanged.
private func standardActionsOverStubbedDatabase(
    queryResult: JSONValue, layout: LayoutStore? = nil
) async throws -> (registry: ActionRegistry, panes: PaneStore, client: RecordingToolCaller) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let client = RecordingToolCaller(always: queryResult)
    let panes = PaneStore()
    let registry = ActionRegistry(
        journalDirectory: dir.appendingPathComponent("journal"), sessionId: "s1")
    await registerStandardActions(
        into: registry, context: nil, panes: panes, db: client, resumes: ResumeBroker(),
        layout: layout)
    return (registry, panes, client)
}
```

- [ ] **Step 2: Remove the teardown wrapper at its call sites**

Run: `cd app && grep -n 'withStubClientStoppedAfterwards' Tests/WakilKitTests/StandardActionsTests.swift`

For each hit, unwrap the closure: the body runs directly, and the trailing `await client.stop()` the wrapper performed is deleted. Nothing else in those tests changes.

- [ ] **Step 3: Run the tests to verify they pass unchanged**

Run: `cd app && ../scripts/swift-test.sh --filter StandardActionsTests`
Expected: PASS. **No assertion in any test may change.** If one does, stop and report — the fake is not answering what the stub server answered.

- [ ] **Step 4: Commit**

```bash
git add app/Tests/WakilKitTests/StandardActionsTests.swift
git commit -m "Drop the stub DB server for the in-memory adapter (#103)"
```

---

### Task 5: Replace DBActionHarness, and drop the serialized suite

**Files:**
- Modify: `app/Tests/WakilKitTests/StandardActionsTests.swift:316-~420` — `DBActionHarness`; and line 585 — `@Suite(.serialized)`

**Interfaces:**
- Consumes: `RecordingToolCaller`.
- Produces: `DBActionHarness` with the same members it has today (`registry`, `layout`, `panes`, `init(rows:)`, and its request-log reader), backed by the fake's `calls` instead of a file.

- [ ] **Step 1: Rewrite the harness onto the fake**

Keep `DBActionHarness`'s public shape — `registry`, `layout`, `panes`, `convenience init(rows:)` and the row-encoding helpers — exactly as they are. Replace only three things:

1. `private let client: MCPClient` becomes `private let client: RecordingToolCaller`.
2. The `requestLog: URL` and everything that writes or reads it are deleted; the log becomes `await client.calls`.
3. The stub script — its creation, its permissions, the `MCPClient(executable:...)` and `try await client.start()` — is deleted, replaced by `RecordingToolCaller(always: resultObject)`.

Two members read that log today, and both keep their names and their return shapes so no test below them changes:

- `resetCallLog()` truncates the log file so a later read reports only the dispatch under test. Its body becomes `await client.reset()`. Add that method to `RecordingToolCaller` in `ToolCallerTests.swift`:

```swift
    /// Drops every recorded call, so a later read reports only what the
    /// dispatch under test sent — not a setup call the test made to get
    /// the harness into position (opening a pane, seeding a fetch).
    func reset() {
        calls.removeAll()
    }
```

- `lastCall() -> (name: String, arguments: [String: JSONValue])?` decodes the last `tools/call` frame out of the file. It becomes a read of the recorded calls, with the JSON-RPC decoding gone because there is no wire:

```swift
    private func lastCall() async -> (name: String, arguments: [String: JSONValue])? {
        guard let call = await client.calls.last else { return nil }
        guard case .object(let args) = call.arguments else { return (call.name, [:]) }
        return (call.name, args)
    }
```

The old body filtered for `message.method == "tools/call"` to skip the initialize handshake. There is no handshake now — every recorded call is a tool call — so the filter goes with it.

- [ ] **Step 2: Run the suite scoped, still serialized**

Run: `cd app && ../scripts/swift-test.sh --filter StandardActionsTests`
Expected: PASS, with every existing assertion unchanged.

- [ ] **Step 3: Drop `@Suite(.serialized)`**

At `app/Tests/WakilKitTests/StandardActionsTests.swift:585`, change:

```swift
@Suite(.serialized)
```

to:

```swift
// Serialization came off with the subprocess. These tests were serialized
// because concurrent shell stubs were missing the initialize timeout —
// contention control standing in for a seam. `RecordingToolCaller` holds
// its state in an actor, one instance per test, so there is nothing left
// to contend over.
@Suite
```

- [ ] **Step 4: Run it three times to verify it is genuinely parallel-safe**

Run: `cd app && for i in 1 2 3; do ../scripts/swift-test.sh --filter StandardActionsTests || break; done`
Expected: PASS all three. A failure here means shared state survived the rewrite — find it rather than restoring `.serialized`.

- [ ] **Step 5: Commit**

```bash
git add app/Tests/WakilKitTests/StandardActionsTests.swift
git commit -m "Rebuild DBActionHarness on the port, and unserialize the suite (#103)"
```

---

### Task 6: The missing-client test earns its name

**Files:**
- Modify: `app/Tests/WakilKitTests/StandardActionsTests.swift:2680-~2720` — `everyActionWithAMissingClientThrowsRatherThanCrashing`

**Interfaces:**
- Consumes: `ActionRegistry.all() -> [ActionDescriptor]` (`app/Sources/WakilKit/Registry/ActionRegistry.swift:116`), whose `ActionDescriptor` carries `name`, `description`, `kind`, `schema` (`app/Sources/WakilKit/Registry/Action.swift:148`).
- Produces: nothing other tasks consume.

The test is named "every" and drives a hand-written map of 8 of 26 registered actions. Rather than synthesising params from each schema — which would test the synthesiser — keep the explicit map and **assert it is complete**, so a new action must either join it or be excused by name.

- [ ] **Step 1: Write the failing completeness assertion**

Extend the existing test. Keep `paramsByAction` exactly as it is, add the remaining entries, and add the guard that keeps it honest:

```swift
    /// Actions that need no client, so dispatching them with both `nil`
    /// would succeed rather than throw and break this test's premise.
    /// Every exclusion is named, and adding one is a deliberate act.
    let needsNoClient: Set<String> = [
        // Parks into `resumes` and returns; needs no client at all.
        "session_resume",
    ]

    let registered = Set(await r.all().map(\.name))
    let covered = Set(paramsByAction.keys).union(needsNoClient)
    #expect(registered.subtracting(covered).isEmpty,
            "every registered action must appear in paramsByAction or be named in needsNoClient")

    for (name, params) in paramsByAction {
        await #expect(throws: StandardActionError.self) {
            _ = try await r.dispatch(
                name: name, params: params, origin: .ui,
                environment: "staging", confirmation: nil)
        }
    }
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd app && ../scripts/swift-test.sh --filter everyActionWithAMissingClientThrowsRatherThanCrashing`
Expected: FAIL — the completeness expectation reports the 18 registered actions absent from both sets.

- [ ] **Step 3: Fill the map from the failure's own list**

Add an entry to `paramsByAction` for each name the failure reports, giving each the minimum params its schema requires. Read each action's schema at its registration in `app/Sources/WakilKit/Registry/StandardActions.swift` — do not guess. The 18 are: `ctx_list_orgs`, `ctx_create_org`, `ctx_adopt_provider`, `ctx_list_machine_providers`, `db_list_tables`, `db_describe_table`, `db_read_table`, `db_refetch`, `db_page`, `db_render_update`, `db_run_mutation`, `session_read`, `session_list`, `session_record_parent`, and the four remaining context and pane actions the failure names.

An action that turns out to need no client goes in `needsNoClient` **with a one-line reason**, never silently.

- [ ] **Step 4: Run it to verify it passes**

Run: `cd app && ../scripts/swift-test.sh --filter everyActionWithAMissingClientThrowsRatherThanCrashing`
Expected: PASS, with all 26 actions accounted for.

- [ ] **Step 5: Commit**

```bash
git add app/Tests/WakilKitTests/StandardActionsTests.swift
git commit -m "Make the missing-client test cover every registered action (#103)"
```

---

### Task 7: The mutation-timeout chain, end to end

**Files:**
- Modify: `app/Tests/WakilKitTests/MutationActionTests.swift` (add one test)

**Interfaces:**
- Consumes: `RecordingToolCaller`; `MCPClientError.timeout(method:)` (`app/Sources/WakilKit/MCP/MCPClient.swift:17`); `runDebugScriptReportingFailures(_:registry:environment:)` (`app/Sources/WakilKit/Registry/DebugDispatch.swift:69`); `ActionRegistry.journalEntries()` (line 285) returning `[JournalEntry]` with an `outcome: String` (`app/Sources/WakilKit/Registry/Journal.swift:31-39`).
- Produces: nothing other tasks consume.

Today only the pure translation of a failed mutation call is tested. The chain it sits in has never been driven, because driving it needs a client that times out.

**Drive it through `runDebugScriptReportingFailures`, not through `dispatch`.** `dispatch` journals `"error"` when a handler throws; the `"uncertain"` line beside it is written by `recordUncertainMutation`, which only the *callers* of dispatch invoke — the window, the MCP server, and the debug runner. The debug runner is the one reachable from `WakilKitTests`, and it is the same path `phase-2b-iii-acceptance.md` check 1 uses.

- [ ] **Step 1: Write the failing test**

```swift
/// A mutation whose reply never arrives is NOT a failed mutation: the
/// statement may well have run. The pair of journal lines that says so —
/// `dispatch`'s own `"error"`, then `"uncertain"` from the caller's catch
/// — could not be driven before `ToolCaller`, because it needs a client
/// that times out on demand.
@Test func aTimedOutMutationIsJournalledUncertainBesideItsError() async throws {
    let db = RecordingToolCaller(reply: { _, _ in
        throw MCPClientError.timeout(method: "tools/call")
    })
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let registry = ActionRegistry(journalDirectory: dir, sessionId: "s1")
    await registerStandardActions(
        into: registry, context: nil, panes: PaneStore(), db: db, resumes: ResumeBroker())

    let line = #"{"action":"db_run_mutation","params":{"statement":"update t set a = 1 where id = 1"},"confirmation":"confirm"}"#
    let result = await runDebugScriptReportingFailures(
        [line], registry: registry, environment: "staging")

    #expect(result.failureCount == 1)

    let outcomes = try await registry.journalEntries()
        .filter { $0.action == "db_run_mutation" }
        .map(\.outcome)
    #expect(outcomes == ["error", "uncertain"])
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd app && ../scripts/swift-test.sh --filter aTimedOutMutationIsJournalledUncertainBesideItsError`
Expected: FAIL — before Tasks 1–2 the fake cannot be passed as `db` at all; after them, this is the first test to reach the chain.

- [ ] **Step 3: Make it pass without touching production code**

No production change belongs in this task. If the chain turns out to be **broken** rather than merely untested — the `"uncertain"` line missing, or the outcomes in the other order — **stop and report it.** That is a defect this plan surfaced, and it belongs on issue #103 as a comment and its own fix, not in a silent repair here.

- [ ] **Step 4: Run it to verify it passes**

Run: `cd app && ../scripts/swift-test.sh --filter MutationActionTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/Tests/WakilKitTests/MutationActionTests.swift
git commit -m "Drive the mutation timeout chain end to end (#103)"
```

---

### Task 8: Re-judge the three helpers extracted only for testability

**Files:**
- Modify: `app/Sources/WakilKit/Registry/StandardActions.swift` — `dbPaneContents` (~line 1828) and `mutationCallFailure` (~line 1683) doc comments
- Modify: `app/Sources/WakilKit/App/WindowModel.swift:3310` — `sessionItems(from:)` doc comment

**Interfaces:**
- Consumes: nothing from earlier tasks beyond the seam existing.
- Produces: nothing.

Each of these three says, in its own words, that it is a free function *because* the caller could not be tested. That sentence is now false, and a false doc comment in this repo is a defect. The functions themselves stay — they are each a real projection worth naming, and Task 6's coverage now tests them through their callers as well as directly.

- [ ] **Step 1: Correct `dbPaneContents`'s reason**

Its comment says it is *"A free function rather than inline in `db_run_query`'s handler so it can be tested without an `MCPClient`."* Replace that sentence with:

```swift
/// A free function rather than inline in `db_run_query`'s handler because
/// three actions project the same shape and one definition is the point.
/// It was originally extracted so it could be tested without an
/// `MCPClient`; since `ToolCaller`, the handler around it is testable too,
/// and both are covered.
```

- [ ] **Step 2: Correct `mutationCallFailure`'s reason**

Its comment says the translation is extracted *"so the translation can be tested without a database"*. Replace with:

```swift
/// Extracted so the translation has one definition, and originally so it
/// could be tested without a database. Since `ToolCaller` the whole chain
/// is driveable — see
/// `aTimedOutMutationIsRecordedAsUncertainRatherThanFailed` — and this
/// stays a named function on its own merit.
```

- [ ] **Step 3: Correct `sessionItems(from:)`'s reason**

Its comment calls it *"the pure half of `sessionPaletteItems`"*, with the split justified by testability. Keep the description of what it does and replace the justification clause with:

```swift
/// The pure half of `sessionPaletteItems`. The split was originally what
/// made any of this testable; it is kept because the partiality note and
/// the item projection are genuinely separate decisions.
```

- [ ] **Step 4: Verify nothing else still claims the seam is absent**

Run: `cd app && grep -rn 'without an \`\?MCPClient\|without a database\|too large a change for a flakiness fix' Sources Tests`
Expected: no hit that still states testability as the reason for a split, and no hit of the declined-fix comment — that comment is in the suite the earlier tasks rewrote, and it must be gone. Correct any that remain.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Registry/StandardActions.swift app/Sources/WakilKit/App/WindowModel.swift
git commit -m "Correct the three doc comments that said the seam was impossible (#103)"
```

---

## Completion gate

Run both suites from the repo root, in full, and paste the output before claiming anything:

```bash
make test
make app-test
```

Expected: both green. `make test` (Go) must be untouched by this work — a change there is a defect in this plan.

Then use `superpowers:verification-before-completion` before any claim of doneness, and report on the issue:

```bash
gh issue comment 103 --body "<what shipped, what it left unestablished>"
```
