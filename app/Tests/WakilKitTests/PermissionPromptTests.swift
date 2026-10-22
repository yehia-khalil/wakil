import Testing
import Foundation
@testable import WakilKit

/// The action names a Wakil session actually registers, in the bare form
/// `permissionDecision` compares against. Deliberately includes a `.mutate`
/// name: `db_run_mutation` is the whole reason this function exists, and a
/// fixture that omitted it would let the one row that matters go untested.
private let known = ["db_run_query", "db_run_mutation", "pane_move", "pane_set_density"]

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
/// character. Loosening the prefix test to `contains` or to a shorter
/// literal would not make this fail — the bare-name extraction still mangles
/// the lookalike into something no known action matches, so it is still
/// denied either way. What this guards against is a more dangerous
/// refactor: splitting `toolName` on `__` and taking the *last* component
/// instead of stripping a fixed prefix, which would resolve
/// `mcp__wakil-evil__db_run_mutation` to the bare action `db_run_mutation`
/// and allow it.
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
        journalDirectory: testScratchRoot
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

// MARK: - The wire shape the CLI measured (probe §2, §3)

private func bridgeReply(toolName: String, input: JSONValue) async throws -> [String: JSONValue] {
    let registry = ActionRegistry(
        journalDirectory: testScratchRoot
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
    let out = await handle(message, surface: surface, caller: { .test("staging") })
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
        journalDirectory: testScratchRoot
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
    let out = await handle(message, surface: surface, caller: { .test("staging") })
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
    let journal = testScratchRoot.appendingPathComponent(UUID().uuidString)
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
    _ = await handle(message, surface: surface, caller: { .test("staging") })
    let after = (try? FileManager.default.contentsOfDirectory(atPath: journal.path))?.count ?? 0
    #expect(after == before)
}

// MARK: - The four org actions (2b-viii Task 13)
//
// 2026-09-15 acceptance ruling (T13-R1): the brief's own draft test for
// this task asserted only `reason.contains("operator")`. The EXISTING
// `session_set_provider` / `ctx_set_provider` denial reads "the operator
// chooses which account a session runs under; you cannot switch it" —
// that sentence contains the word "operator", so a naive reuse of it for
// `ctx_list_orgs` would make this test PASS while telling an agent that
// asked to list organisations that it may not switch which account a
// session runs under, an answer to a question it did not ask. The two
// tests below assert the ORG-SPECIFIC wording instead, and each checks
// the OTHER family's wording is absent, so a reused/generic message fails
// both — not just one of them, which would still let a shared sentence
// slip through undetected.

/// The strong case: `ctx_create_org` and `ctx_adopt_provider` could each
/// move Invariant 4's own credential boundary — the first by minting a
/// new one, the second by binding an account into one. Must fail if
/// `operatorOnlyActions` loses either entry, or if the denial reverts to
/// the provider family's "account a session runs under" wording.
@Test func theAgentCannotMoveTheCredentialBoundary() {
    for name in ["ctx_create_org", "ctx_adopt_provider"] {
        let decision = permissionDecision(
            toolName: "mcp__\(wakilShimServerName)__\(name)", knownActions: [name])
        guard case .deny(let reason) = decision else {
            Issue.record("\(name) must be operator-only, got \(decision)")
            continue
        }
        #expect(reason.contains("credential boundary"),
                "\(name): reason must name the boundary it could move — got: \(reason)")
        #expect(!reason.contains("account a session runs under"),
                "\(name) must not reuse the provider family's wording — got: \(reason)")
    }
}

/// The weaker case, stated rather than inherited by association:
/// `ctx_list_orgs` and `ctx_list_machine_providers` move no boundary —
/// reading across orgs is established practice (`provider add` has
/// always done it) — they are denied only because enumerating every org
/// and config dir on the machine is not something a session scoped to
/// ONE org has any business doing. Must fail if `operatorOnlyActions`
/// loses either entry, or if the denial reuses the provider family's
/// account-switch wording, or the strong case's credential-boundary
/// wording — neither is the reason these two are refused.
@Test func theAgentCannotEnumerateEveryOrgOnTheMachine() {
    for name in ["ctx_list_orgs", "ctx_list_machine_providers"] {
        let decision = permissionDecision(
            toolName: "mcp__\(wakilShimServerName)__\(name)", knownActions: [name])
        guard case .deny(let reason) = decision else {
            Issue.record("\(name) must be operator-only, got \(decision)")
            continue
        }
        #expect(reason.contains("one organisation") || reason.contains("scoped to"),
                "\(name): reason must explain the single-org scope — got: \(reason)")
        #expect(!reason.contains("account a session runs under"),
                "\(name) must not reuse the provider family's wording — got: \(reason)")
        #expect(!reason.contains("credential boundary"),
                "\(name) moves no boundary and must not claim it does — got: \(reason)")
    }
}

/// The provider family's wording must survive this task unchanged — this
/// task adds a second and third denial family, but must not regress the
/// first. Pins the literal sentence rather than a substring, so a
/// refactor that quietly reworded it is caught here rather than only in
/// `ProviderSwitchTests`, which checks reachability but not wording.
@Test func theProviderFamilysWordingIsUnchanged() {
    for name in ["session_set_provider", "ctx_set_provider"] {
        let decision = permissionDecision(
            toolName: "mcp__\(wakilShimServerName)__\(name)", knownActions: [name])
        guard case .deny(let reason) = decision else {
            Issue.record("\(name) must be operator-only, got \(decision)")
            continue
        }
        #expect(reason.contains(
            "the operator chooses which account a session runs under; you cannot switch it"))
    }
}

/// §9.2: `ctx_get_context` is not an action at all
/// (`ContextStore.swift:38`) and it is how the window reads its own
/// context — adding it here would be meaningless and would invite an
/// implementer to skip the amendment that keeps it working.
@Test func getContextIsNotOperatorOnly() {
    #expect(!operatorOnlyActions.contains("ctx_get_context"))
}

// MARK: - `term_run`, the fourth family (2c-iii Task 12)
//
// T13-R1 (2b-viii's acceptance ruling) found a draft test asserting only
// `reason.contains("operator")`, which the provider family's existing
// wording already satisfies. The test below asserts on `term_run`'s own
// distinctive words instead, and checks each other family's wording is
// absent, so a reused/generic message fails rather than slipping through.

/// Asserted on THIS refusal's own words, not a substring the other three
/// families already satisfy.
@Test func termRunIsDeniedToTheAgentInItsOwnWordsAndNotAnotherFamilys() {
    let decision = permissionDecision(
        toolName: "mcp__\(wakilShimServerName)__term_run",
        knownActions: ["term_run", "term_open", "term_propose", "term_scroll"])

    guard case .deny(let reason) = decision else {
        Issue.record("term_run must be denied"); return
    }
    #expect(reason.contains("term_propose"))
    // The refusal's own stated ground, corrected by the two-axis review's
    // Spec 2: the shell carries the active organisation, project and
    // environment — three `WAKIL_*` variables, no Keychain material — so
    // what the agent would gain is the INSIDE of the boundary that context
    // establishes, not the credentials themselves. The message used to say
    // the shell "carries the organisation's credentials", which claimed
    // more than `terminalChildEnvironment` exports. The refusal is
    // unchanged in strength; only its stated reason is now true.
    #expect(reason.contains("active organisation, project and environment"))
    #expect(reason.contains("credential boundary that context establishes"))
    // Not the provider family's sentence, nor either org family's. The org
    // family's own distinctive words are the ACT it names, not the phrase
    // "credential boundary", which both families may legitimately use —
    // this refusal defends that boundary, the other refuses to move it.
    #expect(!reason.contains("account a session runs under"))
    #expect(!reason.contains("Enumerating every organisation"))
    #expect(!reason.contains("creating an organisation or adopting an account"))
}

/// An agent that could not open a pane or propose into it could not use
/// this pane at all — the refusal is about the RUN, not about the pane.
@Test func theOtherThreeTerminalActionsAreAllowed() {
    for name in ["term_open", "term_propose", "term_scroll"] {
        #expect(permissionDecision(
            toolName: "mcp__\(wakilShimServerName)__\(name)",
            knownActions: [name]) == .allow)
    }
}

/// Two places, and both matter: §6 of the permission probe measured that
/// an ALLOW-LISTED tool never reaches `approve_tool_use` at all, so a name
/// left on `--allowedTools` could never be refused above no matter what
/// that function said.
@Test func termRunIsAlsoOffTheAgentsPreApprovalList() {
    let allowed = agentAllowedTools(actions: [
        ActionDescriptor(name: "term_run", description: "", kind: .control, schema: .object([:])),
        ActionDescriptor(name: "term_open", description: "", kind: .control, schema: .object([:])),
    ])
    #expect(!allowed.contains { $0.hasSuffix("term_run") })
    #expect(allowed.contains { $0.hasSuffix("term_open") })
}

// MARK: - Projects and environments are the operator's (2e-ii, Invariant 5)

/// The six lifecycle actions get a sentence of their own: what they do, why the agent may not
/// (Invariant 5), and where it can read instead. Must fail if any falls back to the org family's
/// "creating an organisation" sentence, the `default:` the final review found them in.
@Test func theAgentIsToldProjectsAndEnvironmentsAreTheOperators() {
    for name in ["ctx_create_project", "ctx_rename_project", "ctx_remove_project",
                 "ctx_create_environment", "ctx_rename_environment", "ctx_remove_environment"] {
        let decision = permissionDecision(
            toolName: "mcp__\(wakilShimServerName)__\(name)", knownActions: [name])
        guard case .deny(let reason) = decision else {
            Issue.record("\(name) must be operator-only, got \(decision)")
            continue
        }
        #expect(reason.contains("adds, renames and removes projects and environments"), "\(name): got: \(reason)")
        #expect(reason.contains("Invariant 5") && reason.contains("ctx_config_tree"), "\(name): got: \(reason)")
        #expect(!reason.contains("creating an organisation"), "\(name) reused the org family: \(reason)")
    }
}

// MARK: - The agent's place is fixed (background agents, Invariant 5)

/// An agent's place (organisation, project, environment) is fixed when its
/// session starts, so it cannot switch project or environment at all: the
/// refusal is outright, not a held confirmation. Must fail if either name
/// leaves `operatorOnlyActions` or `agentAllowedTools` stops excluding it.
@Test func theAgentCannotMoveItsOwnPlace() {
    for name in ["ctx_set_project", "ctx_set_environment"] {
        let decision = permissionDecision(
            toolName: "mcp__\(wakilShimServerName)__\(name)", knownActions: [name])
        guard case .deny(let reason) = decision else {
            Issue.record("\(name) must be operator-only, got \(decision)")
            continue
        }
        #expect(reason.contains("place is fixed"), "\(name): got: \(reason)")
        #expect(!reason.contains("confirm"), "\(name) is refused, not held: \(reason)")
    }
    let allowed = agentAllowedTools(actions: [
        ActionDescriptor(name: "ctx_set_project", description: "", kind: .control, schema: .object([:])),
        ActionDescriptor(name: "ctx_set_environment", description: "", kind: .control, schema: .object([:])),
        ActionDescriptor(name: "term_open", description: "", kind: .control, schema: .object([:])),
    ])
    #expect(!allowed.contains { $0.hasSuffix("ctx_set_project") || $0.hasSuffix("ctx_set_environment") })
    #expect(allowed.contains { $0.hasSuffix("term_open") })
}
