# Permission-Prompt Bridge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a live agent's proposed mutation reach Wakil's confirmation plane, by giving the Claude CLI a permission-prompt tool to ask instead of denying the call outright.

**Architecture:** One hand-written MCP tool (`approve_tool_use`) on Wakil's existing shim server, answering one question — *is this a Wakil registry action?* — and one launch flag naming it. The tool decides **reachability, never permission**: every real decision stays in `ActionRegistry.dispatch`, `writeGate`, and the confirmation plane, all unchanged. No new stored state anywhere.

**Tech Stack:** Swift 6.3.3, SwiftPM, swift-testing (`@Test` / `#expect` / `#require`), macOS 26. Package root is `app/`. Tests run via `cd app && ../scripts/swift-test.sh`.

**Spec:** `docs/superpowers/specs/2026-09-10-permission-prompt-bridge-design.md`
**Probe (measured facts the code is written against):** `docs/wakil/permission-prompt-probe.md`

## Global Constraints

- **The bridge decides reachability, never permission.** It must never consult `writeGate`, `ConfirmationBroker`, `PendingMutation`, or the journal. If a task's implementation imports one of those into the new file, the task is wrong.
- **No new stored state.** `permissionDecision` is a pure function. No tokens, no caches, no actors.
- **`agentAllowedTools`'s filter does not change.** It keeps excluding `.mutate`, and `approve_tool_use` is never added to it (probe §11).
- **`updatedInput` echoes `input` verbatim** on allow — never rebuilt, normalised, or added to (probe §5).
- **Every failure direction is deny.** Malformed input, unknown names, unparseable requests → `.deny`, never a JSON-RPC error and never `.allow`.
- Exact tool name: `approve_tool_use`. Exact flag value: `mcp__wakil__approve_tool_use`, built from `wakilShimServerName` + `permissionPromptToolName`, never a literal.
- CLI version this is written against: `claude` 2.1.266. The flag is undocumented in `--help`.
- Existing symbols you will use: `wakilShimServerName` and `agentAllowedTools` in `App/WindowModel.swift`; `readPaneToolName`, `readLayoutToolName`, `handle`, `handleToolsCall`, `MCPSurface` in `MCP/MCPServer.swift`; `JSONValue`, `JSONRPCMessage`, `JSONRPCID` in `MCP/JSONRPC.swift`; `ActionDescriptor` (fields `name`, `description`, `kind`, `schema`) and `ActionKind` (`.read`/`.control`/`.mutate`) in `Registry/Action.swift`.

---

### Task 1: The policy function

The whole decision, as one pure function with no I/O. Nothing in this task touches the MCP server or the harness.

**Files:**
- Create: `app/Sources/WakilKit/MCP/PermissionPrompt.swift`
- Test: `app/Tests/WakilKitTests/PermissionPromptTests.swift` (create)

**Interfaces:**
- Consumes: `wakilShimServerName`, `readPaneToolName`, `readLayoutToolName` (all already public in `WakilKit`).
- Produces: `public enum PermissionDecision: Equatable, Sendable { case allow; case deny(String) }`, `public let permissionPromptToolName = "approve_tool_use"`, and `public func permissionDecision(toolName: String, knownActions: [String]) -> PermissionDecision`. Task 2 calls `permissionDecision` and reads `permissionPromptToolName`; Task 3 reads `permissionPromptToolName`.

- [ ] **Step 1: Write the failing tests**

Create `app/Tests/WakilKitTests/PermissionPromptTests.swift`:

```swift
import Testing
import Foundation
@testable import WakilKit

/// The action names a Wakil session actually registers, in the bare form
/// `permissionDecision` compares against. Deliberately includes a `.mutate`
/// name: `db_run_mutation` is the whole reason this function exists, and a
/// fixture that omitted it would let the one row that matters go untested.
private let known = ["db_run_query", "db_run_mutation", "ctx_set_environment", "pane_set_density"]

@Test func everyRegisteredActionIsReachableIncludingMutations() {
    for name in known {
        #expect(permissionDecision(toolName: "mcp__wakil__\(name)", knownActions: known) == .allow,
                "\(name) should be reachable")
    }
}

@Test func bothHandWrittenReadToolsAreReachable() {
    #expect(permissionDecision(toolName: "mcp__wakil__read_pane", knownActions: known) == .allow)
    #expect(permissionDecision(toolName: "mcp__wakil__read_layout", knownActions: known) == .allow)
}

/// The whole defence against probe §7's widening. Enumerated by name rather
/// than asserted as a fallthrough: a fallthrough test passes for the wrong
/// reason once the matching logic is rewritten, and a named list fails.
///
/// `Read` is here even though probe §7 measured the CLI settling it before
/// asking. This checks what the function answers, not whether the question
/// arrives — the day CLI policy changes is the day the difference matters.
@Test func everyBuiltInToolIsRefused() {
    for name in ["Bash", "Write", "Edit", "Read", "Task", "WebFetch", "WebSearch", "NotebookEdit"] {
        guard case .deny = permissionDecision(toolName: name, knownActions: known) else {
            Issue.record("\(name) should be refused"); continue
        }
    }
}

@Test func anUnregisteredWakilNameIsRefused() {
    guard case .deny = permissionDecision(toolName: "mcp__wakil__db_drop_everything",
                                          knownActions: known) else {
        Issue.record("an unregistered name should be refused"); return
    }
}

/// Unreachable in practice — a designated permission tool is not itself
/// permission-checked — and written anyway, because "unreachable" is a claim
/// about a CLI this repo does not own and the cost of being wrong is a
/// recursion.
@Test func theBridgeRefusesToAnswerAboutItself() {
    guard case .deny = permissionDecision(toolName: "mcp__wakil__approve_tool_use",
                                          knownActions: known) else {
        Issue.record("the bridge should refuse itself"); return
    }
}

/// Equally unreachable — probe §6 says an allow-listed tool never arrives
/// here, and both these servers are allow-listed server-wide. Denying them
/// keeps the fallthrough honest rather than carving out an exception for a
/// case that cannot occur.
@Test func theOtherWakilServersAreRefused() {
    for name in ["mcp__wakil-pm__my_issues", "mcp__wakil-recall__recall"] {
        guard case .deny = permissionDecision(toolName: name, knownActions: known) else {
            Issue.record("\(name) should be refused"); continue
        }
    }
}

/// The prefix is the namespace. A bare action name is not this server's tool,
/// and treating it as one would allow a same-named tool on any other server.
@Test func aBareActionNameWithoutTheServerPrefixIsRefused() {
    guard case .deny = permissionDecision(toolName: "db_run_mutation", knownActions: known) else {
        Issue.record("an unprefixed name should be refused"); return
    }
}

/// `mcp__wakil-pm__…` shares a prefix with `mcp__wakil__…` up to the tenth
/// character. If the prefix test is ever loosened to `contains` or to a
/// shorter literal, this is what fails.
@Test func aServerWhoseNameMerelyStartsWithWakilIsRefused() {
    guard case .deny = permissionDecision(toolName: "mcp__wakil-evil__db_run_mutation",
                                          knownActions: known) else {
        Issue.record("a lookalike server should be refused"); return
    }
}

/// The drift alarm. `knownActions` is derived from the registry rather than
/// listed here, so an action registered tomorrow is reachable tomorrow. The
/// counterpart to `agentAllowedTools`' own drift alarm, for the function
/// that now has the opposite polarity: that one must never name a `.mutate`
/// action, and this one must always allow it.
@Test func everyRegisteredActionIsAllowedWhenDerivedFromALiveRegistry() async {
    let registry = ActionRegistry(
        journalDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString),
        sessionId: "s1")
    await registry.register(Action(name: "db_run_query", description: "read",
                                   kind: .read, schema: .object([:])) { p in p })
    await registry.register(Action(name: "db_run_mutation", description: "write",
                                   kind: .mutate, schema: .object([:])) { p in p })
    let names = await registry.all().map(\.name)
    #expect(!names.isEmpty)
    for name in names {
        #expect(permissionDecision(toolName: "mcp__wakil__\(name)", knownActions: names) == .allow,
                "\(name) should be reachable")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd app && ../scripts/swift-test.sh --filter PermissionPromptTests`
Expected: compile failure — `cannot find 'permissionDecision' in scope`.

- [ ] **Step 3: Write the implementation**

Create `app/Sources/WakilKit/MCP/PermissionPrompt.swift`:

```swift
import Foundation

/// What Wakil tells the Claude CLI when it asks whether a tool may be
/// invoked. `.deny` carries the message the agent will read — probe §4
/// measured it arriving verbatim, as `tool_result` content with
/// `is_error: true`, so the wording here is wording the agent sees.
public enum PermissionDecision: Equatable, Sendable {
    case allow
    case deny(String)
}

/// The name of the third hand-written tool on Wakil's MCP surface, and the
/// value `buildLaunch` spells into `--permission-prompt-tool`.
///
/// A named constant for the reason `readPaneToolName` is one, with a
/// sharper failure mode: probe §8 measured the CLI refusing at the first
/// permission check when the name it was given is not in `tools/list`, and
/// putting that error in front of the agent. A mismatch here is a session
/// in which every gated tool fails and nothing in the app looks wrong.
public let permissionPromptToolName = "approve_tool_use"

/// Whether a tool may be *invoked*. Not whether what it does may happen.
///
/// **This distinction is the whole design.** The CLI asks one question —
/// may this tool be called — and Wakil answers that and only that. Whether
/// the call then executes is decided where it is decided today:
/// `ActionRegistry.dispatch`, then `writeGate`, then a human at the
/// confirmation plane. A bridge that consulted `writeGate` would be a
/// second place where state changes are allowed or refused, which is
/// exactly what Invariant 2 exists to prevent.
///
/// **Every kind is allowed, `.mutate` included, and that is the point.**
/// `agentAllowedTools` filters `.mutate` off the session's allow list and
/// must keep doing so; this function is what the CLI consults *because* of
/// that filter. Before it existed, an unlisted tool in a `-p` session was
/// denied outright by the CLI — the request never reached Wakil's socket,
/// so `ConfirmationBroker` never parked it and no confirmation plane ever
/// appeared (`docs/wakil/phase-2a-probe.md` §6).
///
/// **The default branch is a security boundary, not a fallthrough.** Probe
/// §7 measured `--permission-prompt-tool` routing Claude's own built-in
/// tools here too: `Write` and a non-trivial `Bash` both arrive, with a
/// bare `tool_name`. Today Wakil passes no prompt tool, so those are
/// auto-denied for want of an approval surface; naming one makes Wakil the
/// answerer. Allowing by default would remove that restriction while
/// appearing to add one — the agent would gain `Bash` and `Write` in the
/// same change meant to tighten the gate.
///
/// **What it cannot reach.** Probe §7 and §11 also measured `Read`, `Glob`
/// and read-only `Bash` being auto-allowed by CLI policy without this
/// function being consulted at all. Those cannot be denied here because
/// the question never arrives. That is already true of Wakil today and is
/// not changed either way by this function; the honest summary is that it
/// denies every built-in it is *asked* about.
///
/// `knownActions` is passed in rather than read from a registry so this
/// stays pure and testable, and is derived from `ActionRegistry.all()` at
/// the call site rather than listed anywhere, so it cannot fall behind the
/// action set — the same derivation `agentAllowedTools` uses.
public func permissionDecision(toolName: String, knownActions: [String]) -> PermissionDecision {
    let prefix = "mcp__\(wakilShimServerName)__"
    guard toolName.hasPrefix(prefix) else {
        // Built-ins (bare names), other MCP servers, and lookalikes such as
        // `mcp__wakil-pm__…`, which shares this prefix up to its tenth
        // character and diverges at the separator.
        return .deny(
            "Wakil does not run \(toolName). This session's agent may call Wakil's own "
            + "actions and nothing else — use one of those, or ask the operator to do it "
            + "in the Wakil window.")
    }
    let bare = String(toolName.dropFirst(prefix.count))

    if bare == permissionPromptToolName {
        return .deny("\(toolName) answers permission questions; it does not ask them.")
    }
    if bare == readPaneToolName || bare == readLayoutToolName {
        return .allow
    }
    if knownActions.contains(bare) {
        return .allow
    }
    return .deny(
        "\(toolName) is not a registered Wakil action. Call tools/list to see what is.")
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd app && ../scripts/swift-test.sh --filter PermissionPromptTests`
Expected: PASS, 9 tests. Full suite: 336.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/MCP/PermissionPrompt.swift \
        app/Tests/WakilKitTests/PermissionPromptTests.swift
git commit -m "The permission bridge's policy: reachability, never permission

One pure function answering the one question the CLI asks. Every kind is
allowed, .mutate included — agentAllowedTools keeps filtering it off the
session's allow list, and this is what the CLI consults because of that.

The default branch is the security boundary, not a fallthrough: probe §7
measured the flag routing Write and a non-trivial Bash here too, which
today are auto-denied for want of an approval surface. The test that
covers it enumerates built-ins by name, because a fallthrough assertion
would pass for the wrong reason once the matching logic is rewritten."
```

---

### Task 2: The tool on Wakil's MCP surface

Advertise it in `tools/list` (probe §8: its absence is a hard CLI failure) and answer it in `handleToolsCall`, in the CLI's measured wire shape.

**Files:**
- Modify: `app/Sources/WakilKit/MCP/PermissionPrompt.swift` (append the entry and the handler)
- Modify: `app/Sources/WakilKit/MCP/MCPServer.swift` — `tools/list` case (~line 193) and `handleToolsCall` (~line 331, beside the `read_pane`/`read_layout` interceptions)
- Modify: `app/Tests/WakilKitTests/MCPServerTests.swift:31` — `toolsListProjectsTheRegistryPlusBothReadTools` asserts an exact name set and will now fail
- Test: `app/Tests/WakilKitTests/PermissionPromptTests.swift` (append)

**Interfaces:**
- Consumes: `permissionDecision`, `permissionPromptToolName` from Task 1. `MCPSurface` (field `registry`), `handle(_:surface:environment:)`, `JSONRPCMessage`, `JSONRPCID`, `JSONValue`.
- Produces: `public let permissionPromptToolListEntry: JSONValue` and `func permissionPromptReply(id:arguments:knownActions:) -> JSONRPCMessage` (internal). Nothing after Task 2 calls these.

- [ ] **Step 1: Fix the existing `tools/list` test, which this task breaks**

In `app/Tests/WakilKitTests/MCPServerTests.swift`, replace the whole of `toolsListProjectsTheRegistryPlusBothReadTools` with:

```swift
/// Probe §8: the CLI refuses at its first permission check if the name
/// given to `--permission-prompt-tool` is not in this list, and puts that
/// error in front of the agent. So `approve_tool_use`'s presence here is
/// load-bearing, not cosmetic — hiding it to keep it away from the agent
/// was measured and does not work.
@Test func toolsListProjectsTheRegistryPlusBothReadToolsAndTheBridge() async throws {
    let m = JSONRPCMessage(id: .number(2), method: "tools/list", params: nil, result: nil, error: nil)
    let out = await handle(m, surface: await surface(), environment: { "staging" })
    guard case .object(let r)? = out?.result, case .array(let tools)? = r["tools"] else {
        Issue.record("no tools array"); return
    }
    let names = tools.compactMap { t -> String? in
        if case .object(let o) = t, case .string(let n)? = o["name"] { return n }; return nil
    }
    #expect(names.sorted() == ["approve_tool_use", "db_run_query", "read_layout", "read_pane"])
}
```

- [ ] **Step 2: Write the failing tests**

Append to `app/Tests/WakilKitTests/PermissionPromptTests.swift`:

```swift
// MARK: - The wire shape the CLI measured (probe §2, §3)

private func bridgeReply(toolName: String, input: JSONValue) async throws -> [String: JSONValue] {
    let registry = ActionRegistry(
        journalDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString),
        sessionId: "s1")
    await registry.register(Action(name: "db_run_mutation", description: "write",
                                   kind: .mutate, schema: .object([:])) { p in p })
    let surface = MCPSurface(registry: registry, panes: PaneStore(),
                             layout: LayoutStore(), confirmations: ConfirmationBroker())
    let message = JSONRPCMessage(
        id: .number(9), method: "tools/call",
        params: .object([
            "name": .string("approve_tool_use"),
            "arguments": .object([
                "tool_name": .string(toolName),
                "input": input,
                "tool_use_id": .string("toolu_01probe"),
            ]),
        ]),
        result: nil, error: nil)
    let out = await handle(message, surface: surface, environment: { "staging" })
    // Probe §3: one text content block whose TEXT is the JSON — not a JSON
    // result object. Getting this wrong makes the CLI unable to read the
    // answer at all.
    guard case .object(let result)? = out?.result,
          case .array(let content)? = result["content"],
          case .object(let block)? = content.first,
          case .string(let text)? = block["text"],
          case .object(let body) = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    else {
        Issue.record("reply was not one text block carrying JSON"); return [:]
    }
    #expect(out?.error == nil, "the bridge must answer, never error")
    #expect(block["type"] == .string("text"))
    return body
}

@Test func anAllowedToolAnswersAllow() async throws {
    let body = try await bridgeReply(toolName: "mcp__wakil__db_run_mutation",
                                     input: .object(["statement": .string("DELETE FROM t WHERE id = 1")]))
    #expect(body["behavior"] == .string("allow"))
}

/// Probe §5 measured `updatedInput` REPLACING the tool's arguments
/// wholesale, and the agent is never told. So the echo has to be verbatim:
/// anything rebuilt silently rewrites the call the agent made. The same
/// rule `parkForConfirmation` already follows for its re-dispatch, for the
/// same reason — the call that runs must be the call that was proposed.
///
/// Tested with a nested object and a key no Wakil action declares, since a
/// naive re-encode would be likeliest to drop exactly that.
@Test func updatedInputEchoesTheInputVerbatim() async throws {
    let input = JSONValue.object([
        "statement": .string("UPDATE t SET x = 1 WHERE id = 2"),
        "database": .string("staging"),
        "unknown_to_wakil": .object([
            "nested": .array([.number(1), .string("two"), .bool(true), .null]),
        ]),
    ])
    let body = try await bridgeReply(toolName: "mcp__wakil__db_run_mutation", input: input)
    #expect(body["updatedInput"] == input)
}

@Test func aRefusedToolAnswersDenyWithAMessageTheAgentCanRead() async throws {
    let body = try await bridgeReply(toolName: "Bash",
                                     input: .object(["command": .string("rm -rf /")]))
    #expect(body["behavior"] == .string("deny"))
    guard case .string(let message)? = body["message"] else {
        Issue.record("a denial must carry a message"); return
    }
    #expect(!message.isEmpty)
}

/// An `input` the bridge cannot read is the target tool's business, not the
/// bridge's: refusing here would deny calls Wakil's own dispatch would have
/// handled. It echoes an empty object and still allows.
@Test func anAbsentOrNonObjectInputEchoesEmptyAndStillAllows() async throws {
    for input in [JSONValue.null, .string("not an object"), .array([])] {
        let body = try await bridgeReply(toolName: "mcp__wakil__db_run_mutation", input: input)
        #expect(body["behavior"] == .string("allow"))
        #expect(body["updatedInput"] == .object([:]))
    }
}

/// A JSON-RPC error is not an answer to "may this run", and the CLI's
/// handling of one here is unmeasured. The failure direction that costs
/// nothing is refusal — and the message names the malformation, so an
/// agent that somehow caused it is not told it lacked permission.
@Test func aRequestWithoutAToolNameIsDeniedRatherThanErrored() async throws {
    let registry = ActionRegistry(
        journalDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString),
        sessionId: "s1")
    let surface = MCPSurface(registry: registry, panes: PaneStore(),
                             layout: LayoutStore(), confirmations: ConfirmationBroker())
    let message = JSONRPCMessage(
        id: .number(10), method: "tools/call",
        params: .object([
            "name": .string("approve_tool_use"),
            "arguments": .object(["input": .object([:])]),
        ]),
        result: nil, error: nil)
    let out = await handle(message, surface: surface, environment: { "staging" })
    #expect(out?.error == nil, "a malformed request is denied, not errored")
    guard case .object(let result)? = out?.result,
          case .array(let content)? = result["content"],
          case .object(let block)? = content.first,
          case .string(let text)? = block["text"] else {
        Issue.record("no text block"); return
    }
    #expect(text.contains("\"deny\""))
}

/// The bridge never reaches `ActionRegistry.dispatch`, so it must never
/// journal: an entry per permission question would put a row in the
/// journal every time the agent reached for a tool. The same reason
/// `read_pane` and `read_layout` are hand-written rather than registered.
@Test func answeringAPermissionQuestionWritesNothingToTheJournal() async throws {
    let journal = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let registry = ActionRegistry(journalDirectory: journal, sessionId: "s1")
    await registry.register(Action(name: "db_run_mutation", description: "write",
                                   kind: .mutate, schema: .object([:])) { p in p })
    let surface = MCPSurface(registry: registry, panes: PaneStore(),
                             layout: LayoutStore(), confirmations: ConfirmationBroker())
    let before = (try? FileManager.default.contentsOfDirectory(atPath: journal.path))?.count ?? 0
    let message = JSONRPCMessage(
        id: .number(11), method: "tools/call",
        params: .object([
            "name": .string("approve_tool_use"),
            "arguments": .object([
                "tool_name": .string("mcp__wakil__db_run_mutation"),
                "input": .object([:]),
            ]),
        ]),
        result: nil, error: nil)
    _ = await handle(message, surface: surface, environment: { "staging" })
    let after = (try? FileManager.default.contentsOfDirectory(atPath: journal.path))?.count ?? 0
    #expect(after == before)
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `cd app && ../scripts/swift-test.sh --filter "PermissionPromptTests|toolsListProjects"`
Expected: `toolsListProjectsTheRegistryPlusBothReadToolsAndTheBridge` FAILS (the set is missing `approve_tool_use`), and the wire-shape tests FAIL — the bridge name falls through to `handleToolsCall`'s registry dispatch and comes back as an unknown-tool error, so `out?.result` is nil.

- [ ] **Step 4: Add the `tools/list` entry and the handler**

Append to `app/Sources/WakilKit/MCP/PermissionPrompt.swift`:

```swift
/// `approve_tool_use`'s `tools/list` entry.
///
/// **Written for the agent that will read it.** Probe §8 measured that this
/// tool cannot be hidden: a `tools/list` omitting it makes the CLI refuse at
/// the first permission check and puts the error in front of the agent. So
/// the agent will see this description, and it says plainly that calling the
/// tool directly accomplishes nothing — an agent that understands this is
/// not asking Wakil's permission for anything is an agent that does not try
/// to use it as one.
public let permissionPromptToolListEntry = JSONValue.object([
    "name": .string(permissionPromptToolName),
    "description": .string(
        "Wakil's answer to the Claude CLI when the CLI asks whether some tool may be "
        + "invoked. The CLI calls this by itself; calling it yourself does nothing, because "
        + "nothing is listening to the answer. It decides only whether a tool can be "
        + "reached, never whether what that tool does may happen — a mutation still has to "
        + "be confirmed by the operator in Wakil's window."),
    "inputSchema": .object([
        "type": .string("object"),
        "properties": .object([
            "tool_name": .object(["type": .string("string")]),
            "input": .object(["type": .string("object")]),
            "tool_use_id": .object(["type": .string("string")]),
        ]),
        "required": .array([.string("tool_name")]),
    ]),
])

/// Answers one CLI permission question in the shape probe §3 measured: a
/// `tools/call` result whose single text content block carries the JSON
/// `{"behavior":"allow","updatedInput":{…}}` or
/// `{"behavior":"deny","message":"…"}`. The JSON is the block's **text**,
/// not a JSON result object — get that wrong and the CLI cannot read the
/// answer at all.
///
/// It never returns a `JSONRPCError`. A JSON-RPC error is not an answer to
/// *may this run*, the CLI's handling of one here is unmeasured, and the
/// failure direction that costs nothing is refusal.
func permissionPromptReply(
    id: JSONRPCID,
    arguments: JSONValue,
    knownActions: [String]
) -> JSONRPCMessage {
    guard case .object(let object) = arguments,
          case .string(let toolName)? = object["tool_name"] else {
        return permissionPromptEnvelope(id: id, body: .object([
            "behavior": .string("deny"),
            "message": .string(
                "A permission request arrived with no \"tool_name\", so Wakil could not tell "
                + "what was being asked about. Nothing was allowed and nothing ran."),
        ]))
    }

    // The target tool's schema is the target tool's business. Refusing an
    // input this function cannot read would deny calls `dispatch` would
    // have handled.
    var input = JSONValue.object([:])
    if let candidate = object["input"], case .object = candidate { input = candidate }

    switch permissionDecision(toolName: toolName, knownActions: knownActions) {
    case .allow:
        // Verbatim. Probe §5: `updatedInput` replaces the tool's arguments
        // wholesale and the agent is never told, so anything rebuilt here
        // silently rewrites the call that was proposed.
        return permissionPromptEnvelope(id: id, body: .object([
            "behavior": .string("allow"),
            "updatedInput": input,
        ]))
    case .deny(let message):
        // Probe §4: this string reaches the agent verbatim, as
        // `tool_result` content with `is_error: true`.
        return permissionPromptEnvelope(id: id, body: .object([
            "behavior": .string("deny"),
            "message": .string(message),
        ]))
    }
}

/// Wraps a decision body in the `tools/call` result shape.
///
/// `.sortedKeys` so the same question renders identically twice running: two
/// otherwise identical sessions should not differ in a log because a
/// dictionary walked in a different order.
///
/// The encode cannot fail for the two bodies above — both are string-keyed
/// objects of strings and an echoed `JSONValue` — and if it somehow did, a
/// denial is the only safe thing to say.
private func permissionPromptEnvelope(id: JSONRPCID, body: JSONValue) -> JSONRPCMessage {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let text = (try? encoder.encode(body)).flatMap { String(data: $0, encoding: .utf8) }
        ?? #"{"behavior":"deny","message":"Wakil could not encode its answer."}"#
    return JSONRPCMessage(id: id, result: .object([
        "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
    ]))
}
```

- [ ] **Step 5: Wire it into `MCPServer.swift`**

In the `tools/list` case, after the two existing appends:

```swift
    case "tools/list":
        var tools = await surface.registry.all().map(toolListEntry)
        tools.append(readPaneToolListEntry)
        tools.append(readLayoutToolListEntry)
        // Not optional. Probe §8: a `tools/list` without this makes the CLI
        // refuse at its first permission check, with an error the agent reads.
        tools.append(permissionPromptToolListEntry)
        return JSONRPCMessage(id: id, result: .object(["tools": .array(tools)]))
```

In `handleToolsCall`, immediately after the `readLayoutToolName` interception:

```swift
    // The third hand-written tool, intercepted here for the reason the two
    // above are: it is not an action. It changes nothing, so there is
    // nothing for the gate to refuse, and it observes nothing, so there is
    // nothing for the journal to record — registering it would put a row in
    // the journal every time the agent reached for a tool.
    if name == permissionPromptToolName {
        return permissionPromptReply(
            id: id, arguments: arguments,
            knownActions: await surface.registry.all().map(\.name))
    }
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `cd app && ../scripts/swift-test.sh --filter "PermissionPromptTests|toolsListProjects"`
Expected: PASS.

- [ ] **Step 7: Run the whole suite**

Run: `cd app && ../scripts/swift-test.sh`
Expected: PASS. Every test that previously existed stays green — this task adds a tool and changes no dispatch path.

- [ ] **Step 8: Commit**

```bash
git add app/Sources/WakilKit/MCP/PermissionPrompt.swift \
        app/Sources/WakilKit/MCP/MCPServer.swift \
        app/Tests/WakilKitTests/PermissionPromptTests.swift \
        app/Tests/WakilKitTests/MCPServerTests.swift
git commit -m "approve_tool_use: the bridge on Wakil's MCP surface

Advertised in tools/list and answered in handleToolsCall, beside read_pane
and read_layout and for the same reason — it is not an action, so it
reaches neither the gate nor the journal.

The wire shape is probe §3's, not a guess: one text content block whose
TEXT is the JSON, which the CLI cannot read if it is a JSON result object
instead. updatedInput echoes input verbatim, because probe §5 measured it
replacing the tool's arguments wholesale with the agent never told.

The tools/list entry is load-bearing rather than cosmetic: probe §8 tried
hiding it and the CLI refused at its first permission check, putting the
error in front of the agent."
```

---

### Task 3: The launch flag

**Files:**
- Modify: `app/Sources/WakilKit/Harness/ClaudeCodeCLIHarness.swift` — `buildLaunch`'s argument array and its doc comment (~lines 43-52, 71-81)
- Modify: `app/Tests/WakilKitTests/ClaudeCodeCLIHarnessTests.swift:74-81` — `noPermissionModeAndNoPermissionPromptToolArePassed` asserts the flag is *absent* and must be inverted

**Interfaces:**
- Consumes: `permissionPromptToolName` (Task 1), `wakilShimServerName`.
- Produces: nothing new. `buildLaunch`'s signature is unchanged — the value is derived entirely from constants, and a parameter would imply a caller that might pass something else. There is none, and a harness launching without Wakil's approval surface is not a configuration this phase wants expressible.

- [ ] **Step 1: Replace the assertion that the flag is absent**

In `app/Tests/WakilKitTests/ClaudeCodeCLIHarnessTests.swift`, replace the whole of `noPermissionModeAndNoPermissionPromptToolArePassed` with:

```swift
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
/// pair that makes what is listed run silently and everything else get
/// asked about. `bypassPermissions` would switch off the layer this
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd app && ../scripts/swift-test.sh --filter ClaudeCodeCLIHarnessTests`
Expected: `thePermissionPromptToolIsNamedInTheArgv` and `thePromptToolFlagIsBuiltFromTheSameConstantsTheServerAdvertises` FAIL at `#require` — the flag is not in the argv.

- [ ] **Step 3: Add the flag**

In `buildLaunch`, inside the initial `arguments` array, immediately after `"--strict-mcp-config"`:

```swift
        "--strict-mcp-config",
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
```

- [ ] **Step 4: Rewrite `buildLaunch`'s doc-comment paragraph**

Replace the sentence fragment reading `— including why no `--permission-prompt-tool` and no `--permission-mode` are built here.` with:

```
/// — including why every entry on it is a `.read` or `.control` action and
/// never a `.mutate` one.
///
/// **`--permission-prompt-tool` is built here, and is the other half of that
/// list.** The allow list says what runs without being asked about;
/// the prompt tool is who gets asked about everything else. Until 2026-09-10
/// only the first half existed, so "everything else" — every `.mutate`
/// action, `db_run_mutation` included — was denied by the CLI before the
/// request reached Wakil's socket. `--permission-mode` is still not passed;
/// the reasoning for that is unchanged and lives with `agentAllowedTools`.
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd app && ../scripts/swift-test.sh --filter ClaudeCodeCLIHarnessTests`
Expected: PASS.

- [ ] **Step 6: Run the whole suite**

Run: `cd app && ../scripts/swift-test.sh`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add app/Sources/WakilKit/Harness/ClaudeCodeCLIHarness.swift \
        app/Tests/WakilKitTests/ClaudeCodeCLIHarnessTests.swift
git commit -m "Name the approval surface in the launch argv

--allowedTools says what runs without being asked about; the prompt tool is
who gets asked about everything else. Until now only the first half existed,
so everything else — every .mutate action, db_run_mutation included — was
denied by the CLI before the request reached Wakil's socket.

The test asserting the flag's absence is inverted. The bridge stays off the
allow list: probe §11 ran Wakil's exact shape and the CLI reaches its
designated tool regardless, so listing it would buy nothing and give the
agent a silent route to it."
```

---

### Task 4: Correct the documents that state the gap is open

The doc comments and phase map currently assert the opposite of what the code now does. In this repo those are load-bearing: the north-star's 2b-iii section is where the gap was recorded, and leaving it would make the next reader believe an agent still cannot reach `db_run_mutation`.

**Files:**
- Modify: `app/Sources/WakilKit/App/WindowModel.swift:424-448` — the *"There is still no `--permission-prompt-tool`, and it is now overdue"* passage
- Modify: `docs/wakil/north-star.md` — the 2b sub-phase table and the *"One gap in it is worth surfacing here"* paragraph
- Modify: `docs/wakil/phase-2b-iii-acceptance.md` — §3's first gap and §2's check 3b
- Modify: `docs/wakil/phase-2a-acceptance.md:278` and `:663` — added mid-execution; see Step 4d

**Interfaces:**
- Consumes: nothing. Produces: nothing. Documentation only; no test changes.

- [ ] **Step 1: Rewrite the `agentAllowedTools` passage**

In `app/Sources/WakilKit/App/WindowModel.swift`, replace the two paragraphs beginning *"**There is still no `--permission-prompt-tool`, and it is now overdue.**"* and *"**That ceased to be true on 2026-09-09**"* with:

```
/// **The `--permission-prompt-tool` this list needs now exists**
/// (`buildLaunch`, and `MCP/PermissionPrompt.swift`). It was owed from 2a,
/// which declined to build it on the grounds that a permission-prompt tool
/// is a refusal surface and 2a registered zero `.mutate` actions — there
/// was nothing for it to refuse. That ceased to be true on 2026-09-09,
/// when 2b-iii registered `db_run_mutation`, and for one day the
/// consequence was concrete rather than theoretical: `.mutate` is filtered
/// off this list, and in a `-p` session an unlisted MCP tool was denied by
/// the CLI itself, so the request never reached Wakil's socket,
/// `ConfirmationBroker` never parked it, and no confirmation plane ever
/// appeared.
///
/// **The filter below still does not name a `.mutate` action, and that has
/// not changed.** Failing closed is the direction to fail in, and
/// pre-approving a `.mutate` action here would put the write gate at the
/// mercy of an allow list nobody thought to revisit. What the prompt tool
/// supplies is the approval surface the CLI needs in order to *ask* — not
/// a wider list. The two are a pair: this list is what runs without being
/// asked about, and `permissionDecision` is who gets asked about
/// everything else.
///
/// **`approve_tool_use` is deliberately absent from this list too.**
/// `permission-prompt-probe.md` §11 ran exactly this shape — a non-empty
/// allow list that excludes the prompt tool — and the CLI reached its
/// designated tool anyway. Adding it would buy nothing and would give the
/// agent a silent route to call it directly.
```

- [ ] **Step 2: Update the north-star's sub-phase table**

In `docs/wakil/north-star.md`, insert a row after **2b-iv**'s:

```markdown
| **bridge** | The permission-prompt bridge: `--permission-prompt-tool` and `approve_tool_use` | A live agent's proposed mutation reaches the confirmation plane instead of being denied by the CLI — **implemented 2026-09-10**; its acceptance runbook carries `phase-2b-iii-acceptance.md` §2 check 3b — the live-agent mutation path — plus a live production-block check and a built-in refusal check |
```

- [ ] **Step 3: Correct the paragraph that records the gap as open**

Replace the paragraph beginning *"**One gap in it is worth surfacing here rather than leaving in that runbook**"* with:

```markdown
**That gap is closed as of 2026-09-10, and the closing is its own small
sub-phase.** It read: *a live agent still cannot reach `db_run_mutation` at all* —
`agentAllowedTools` filters the registry to `.read` and `.control` and never
`.mutate`, correctly, but the `--permission-prompt-tool` that was always meant to be
the CLI-layer half of the gate was not built, on the 2a-era grounds that there was
nothing for a refusal surface to refuse. Until it existed, an agent proposing a
mutation was denied by the CLI before the request reached Wakil's socket, so the
confirmation plane never appeared and the broker never parked it.

It is now built: `docs/superpowers/specs/2026-09-10-permission-prompt-bridge-design.md`,
against ten measured scenarios in `docs/wakil/permission-prompt-probe.md`. The filter is
unchanged — the bridge decides *reachability*, never permission, so a mutation still
reaches `dispatch`, `writeGate` and a human at the plane exactly as before. What changed
is that it arrives at all.

**This does not mark 2b-iii met.** Its six standing checks remain unwalked and remain its
own; what changed is that one of them — check 3b, the live-agent `.mutate` half of check
3 — stopped being unwalkable.
```

- [ ] **Step 4: Correct the acceptance doc, in three exact places**

All three edits **add** to the existing text rather than replacing it. The record of what was true on 2026-09-09 is the point of the document.

**4a — §2, check 3b** (`docs/wakil/phase-2b-iii-acceptance.md:295`). The check is written as *"which of two things happens, and the code predicts the second"*. The prediction has changed. Insert immediately before the `| Result | Date | Notes |` table that closes the check:

```markdown
**The prediction above was overtaken on 2026-09-10.** The permission-prompt bridge
(`docs/superpowers/specs/2026-09-10-permission-prompt-bridge-design.md`) built the
`--permission-prompt-tool` whose absence this check turns on, so **the first outcome is
now the expected one**: the plane should appear, and a permission denial is now this
check failing rather than the predicted result. `agentAllowedTools` is unchanged and
still filters `.mutate` off the allow list — the bridge is what the CLI consults because
of that filter, and it decides reachability, never permission. Read the two bullets above
as the record of what was predicted before that existed.
```

**4b — §3, the first known gap** (`docs/wakil/phase-2b-iii-acceptance.md:432`, the paragraph beginning *"**A live agent cannot reach `db_run_mutation` at all.**"*). Append to it:

```markdown
**Closed 2026-09-10.** The approval surface this paragraph asks for is
`approve_tool_use`, named to the CLI by `buildLaunch`'s `--permission-prompt-tool` and
specced in `docs/superpowers/specs/2026-09-10-permission-prompt-bridge-design.md`,
against ten measured scenarios in `docs/wakil/permission-prompt-probe.md`. The allow-list
filter stayed exactly as this paragraph says it should. Check 3b is now runnable and has
still not been run.
```

**4c — §3, the second known gap** (the paragraph beginning *"**A client that gives up first still gets the write.**"*). Append to it:

```markdown
**Narrowed, not closed, 2026-09-10.** `permission-prompt-probe.md` §10 held an ordinary
`tools/call` open for 130 seconds against a real CLI: no tool-call timeout fired and no
`notifications/cancelled` was sent, and the agent received the genuine result. So the
scenario this paragraph describes does not occur inside the window the broker can hold
(120s). Nothing here measured ten minutes, and nothing here says the CLI has no tool-call
timeout at all — only that it is longer than the broker's.
```

- [ ] **Step 4d: Correct `phase-2a-acceptance.md`, in two places**

Added to Task 4's scope mid-execution — Task 3's reviewer noticed this third document also states the gap as open, and the plan's pre-flight scan had missed it. Both edits **add** to the existing text.

**4d-i — the passage at `docs/wakil/phase-2a-acceptance.md:278`**, beginning *"**Half of that sentence's promise came due on 2026-09-09 and half did not.**"*. Append to it:

```markdown
**The other half came due on 2026-09-10.** `--permission-prompt-tool` is now built
(`docs/superpowers/specs/2026-09-10-permission-prompt-bridge-design.md`), so the
consequence described above no longer holds: a live `claude` turn asking Wakil to run a
mutation now reaches the socket, and the confirmation plane appears. The allow list is
unchanged and `db_run_mutation` is still absent from it — the bridge is what the CLI
consults *because* of that absence. The paragraph above is kept as the record of what
was true between 2026-09-09 and 2026-09-10.
```

**4d-ii — §5 row 6 at `docs/wakil/phase-2a-acceptance.md:663`**, which asserts `buildLaunch` "passes no `--permission-mode` and no `--permission-prompt-tool`". Half of that is now false. Replace that clause and its assertion count:

```markdown
and passes no `--permission-mode`, but does now pass `--permission-prompt-tool`
(added 2026-09-10; the row read "and no `--permission-prompt-tool`" before that).
Asserted by six `ClaudeCodeCLIHarnessTests` (the allow-list flag, its comma-joined
value, the prompt-tool flag, its constant-built value, the absence of the other
permission flags, and the bridge's absence from the allow list)
```

- [ ] **Step 5: Verify nothing broke**

Run: `cd app && ../scripts/swift-test.sh`
Expected: PASS, 345 tests. Doc comments only; no behaviour changed.

`git grep -n "no .--permission-prompt-tool"` should return only text explicitly marked as a historical record.

- [ ] **Step 6: Commit**

```bash
git add app/Sources/WakilKit/App/WindowModel.swift docs/wakil/north-star.md \
        docs/wakil/phase-2b-iii-acceptance.md docs/wakil/phase-2a-acceptance.md
git commit -m "Record the gap as closed where it was recorded as open

The north-star, the 2b-iii acceptance doc and agentAllowedTools' own doc
comment all state that a live agent cannot reach db_run_mutation. That was
true for one day. Left standing, the next reader believes it still is.

The filter itself is unchanged and the comment says so plainly: the bridge
decides reachability, never permission. This does not mark 2b-iii met —
its six checks remain unwalked; check 3b, the live-agent .mutate half of
check 3, merely stopped being unwalkable."
```

---

### Task 5: The acceptance runbook

The five judgements no test in this repo can make. Written for the operator, who will walk it with a real `claude` binary and a real database.

**Files:**
- Create: `docs/wakil/permission-prompt-acceptance.md`

**Interfaces:**
- Consumes: the behaviour built in Tasks 1-3. Produces: the document `phase-2b-iii-acceptance.md` §2 check 3b — the live-agent `.mutate` half — is finally walked in.

- [ ] **Step 1: Write the runbook**

Create `docs/wakil/permission-prompt-acceptance.md`:

```markdown
# The permission-prompt bridge — acceptance

**Status:** not yet walked · **Spec:** `docs/superpowers/specs/2026-09-10-permission-prompt-bridge-design.md`
· **Probe:** `docs/wakil/permission-prompt-probe.md` · **CLI pinned at:** `claude` 2.1.266

Every check here needs a running `Wakil.app`, a real `claude` binary, and a live agent
turn. None of them can be run headlessly, which is why they are here and not in
`PermissionPromptTests`.

**What this work makes runnable is `phase-2b-iii-acceptance.md` §2 check 3b** — the
`.mutate` half of the live agent turn, owed since 2026-09-08 and unreachable until now
because no `--permission-prompt-tool` existed for an agent to be offered a confirmation
through. 2a's acceptance checks 5 and 6 (the write gate and the production block, driven
from the UI and `--dispatch`) have been runnable by hand since 2026-09-09 and are **not**
what this retires — check 3 below is where that mutation's production form finally
reaches a live agent, which no check anywhere has done before.

## Before you start

Record the CLI version: `claude --version`. The spec's §13 accepts one risk — the flag is
undocumented in `--help` — and its mitigation is that this line is written down. If the
version differs from 2.1.266, say so in the result and expect check 1 to be where a change
surfaces.

## The checks

| # | Check | Result |
|---|---|---|
| 1 | Ask the agent, out loud or by typing, to delete a row from a **staging** database. The confirmation plane appears. *(The live-agent half of `phase-2b-iii-acceptance.md` §2 check 3b, first time runnable.)* | |
| 2 | Approve it. The row is gone, and the journal carries the `gated` → `ok` pair for one action. *(The approval half of the same check.)* | |
| 3 | With the active environment set to **production**, ask the agent to delete a row. It is refused outright: the journal outcome is `"blocked"`, never `"gated"`, and confirming does not help because no confirmation is offered. | |
| 4 | Ask again (non-production), and **cancel**. The agent is told it needs confirmation — not that it timed out. | |
| 5 | Ask again, and **walk away** for the broker's full 120 seconds. The agent is told the operator did not confirm in time, and the wording differs from check 4's. | |
| 6 | Ask the agent to run a shell command that **writes or deletes** — for example, create or remove a file, not `ls` or `git status`. It is refused, and the refusal is Wakil's wording rather than the CLI's. | |

## What each check is really asking

**1** is the whole sub-phase. Everything else is a variation on it. If the plane does not
appear, read the CLI's stderr first: probe §8 measured a name mismatch between the flag
and `tools/list` producing a clear error rather than a silent failure.

**2** is the only check that proves the *approved* path end to end through a live agent.
The headless test `MCPServerTests.anAgentProposedMutationParksAndRunsOnceApproved` covers
the same path with no CLI in it at all.

**3** is `writeGate`'s `.block` row reaching a live agent for the first time, and it is
the one check where a *pass* means nothing happened. The mutation must be refused before
any plane appears — `ActionRegistry.dispatch` never consults `confirmation` on a `.block`
path, so there is nothing to confirm and no plane to raise. A run that shows a
confirmation plane, or that journals `gated` instead of `blocked`, means production has
quietly become merely-gated and the second half of Invariant 8 has become the first half.

**4 and 5 are one check split in two, and the split is the point.**
`ConfirmationDecision` distinguishes `.cancelled` from `.expired` because *"an agent told
it was refused, when the truth is that nobody was at the keyboard, will go looking for a
permission to ask for instead of simply trying again."* That distinction has never reached
a real agent. Read what the agent says after each — if it reacts the same way to both, the
distinction is costing code and buying nothing, and that is worth knowing.

**6** is probe §7's widening, checked rather than argued. Naming a prompt tool made Wakil
the answerer for built-ins that would otherwise have been auto-denied. If the shell command
*runs*, the bridge's default branch is wrong and this is how you find out. This is why the
check must name a command that writes or deletes: a read-only one would run for a reason
that has nothing to do with the bridge (see below), and a pass for the wrong reason is
worse than no check at all.

**One thing check 6 cannot test.** Probe §7 and §11 measured `Read`, `Glob` and read-only
`Bash` being auto-allowed by CLI policy without the bridge being consulted at all. If you
ask the agent to read a file, or to run a read-only shell command such as `ls` or
`git status`, it will run, and the bridge is not what let it — the CLI settled the
question before the bridge was ever asked. That is true of Wakil today, is not changed by
this work, and is recorded in the spec's §12 as out of scope. Do not read a read-only
shell command succeeding as a failure of check 6; the check only means something for a
command that writes or deletes.

## Result

*(Walked: —. By: —. CLI version: —.)*
```

- [ ] **Step 2: Commit**

```bash
git add docs/wakil/permission-prompt-acceptance.md
git commit -m "The runbook the bridge owes

Five judgements no test here can make. One of them — the live-agent
mutation reaching the confirmation plane — is phase 2b-iii's acceptance
check 3b, owed since 2026-09-08 and unrunnable until now. 2a's checks 5
and 6 have been runnable by hand since 2026-09-09 and are not what this
retires; a new check exercises 2a check 6's production block from a live
agent for the first time instead.

Checks 4 and 5 are deliberately split: ConfirmationDecision distinguishes
.cancelled from .expired on the argument that an agent told the wrong one
goes looking for a permission instead of retrying, and that distinction
has never reached a real agent. If it reacts identically to both, the
distinction is costing code and buying nothing."
```

---

## Done when

- `cd app && ../scripts/swift-test.sh` passes, reporting **345 tests** — 18 more than the 327 measured at `e04a61f`. (Task 1 adds 9; Task 2 adds 6 and renames 1; Task 3 replaces 1 test with 4.) If the number differs, find out why before committing rather than adjusting this line.
- **`WindowModelTests.aMutatingActionIsNeverOnTheAllowList` and `theAllowListAdmitsControlActionsAndBothReadTools` are still green and still unedited.** This is spec §11's check 15 and the single most important regression signal in the plan: the bridge's correctness rests entirely on that filter continuing to exclude `.mutate`. A task that "fixes" one of these has broken the design rather than the test.
- `git grep -n "still no .--permission-prompt-tool"` returns nothing.
- `git grep -n "no --permission-prompt-tool was built"` returns nothing outside the historical record in `phase-2b-iii-acceptance.md`, which keeps it deliberately.
- The runbook exists and is honestly marked **not yet walked** — the code being written and the sub-phase being met are different claims, and only the operator closes the second.

## Deliberately not in this plan

- **No test asserts spec §6** (a production mutation is allowed through the bridge and refused by `dispatch`, which journals `"blocked"`). It is enforced structurally instead: `permissionDecision` takes no environment parameter, so there is no expression it could use to decide differently. If a later change gives it one, that is the change to argue with.
- **No fix for the `Connection.ingest` / `Connection.consume` naming mismatch** between `phase-2b-iii-acceptance.md` §3 and `MCPServer.swift`'s `parkForConfirmation` doc comment. Both name the same thing; one of them is wrong. Out of scope here, and worth a one-line fix by whoever touches that file next.
