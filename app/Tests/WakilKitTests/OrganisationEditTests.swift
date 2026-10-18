import Testing
import Foundation
@testable import WakilKit

/// **The settings pane's first write** (#199), and the four properties it
/// establishes for every later settings edit:
///
/// 1. It is one more `.control` action — no fourth `ActionKind`, no price,
///    and therefore no reach into the gate's gating branch or the broker.
/// 2. It is operator-only, and the refusal is journalled.
/// 3. The write is read-modify-write from disk at dispatch, which here is
///    the shape of the parameters: only what the operator changed travels.
/// 4. Edits render on the pane; this phase adds no new modal.
///
/// The Go half — that a field not in the patch survives, that an explicit
/// empty clears, that a `defaultProvider` naming nothing is refused — is
/// pinned in `internal/wakilcore/orgupdate_test.go`, against real files.
/// What is pinned here is the Swift half: which action, of which kind, for
/// whom, carrying what.

private func scratch() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// A `ToolCaller` that records what it was asked and answers success, so a
/// test can assert on the arguments that reached Go without a `wakil-ctx`
/// process.
private actor RecordingCaller: ToolCaller {
    private(set) var calls: [(tool: String, arguments: JSONValue)] = []

    func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        calls.append((name, arguments))
        return .object(["structuredContent": .object([:])])
    }

    func recorded() -> [(tool: String, arguments: JSONValue)] { calls }
}

private func registryWithRecordingContext() async throws -> (ActionRegistry, RecordingCaller) {
    let caller = RecordingCaller()
    let registry = ActionRegistry(journalDirectory: try scratch(), sessionId: "org-edit")
    await registerStandardActions(
        into: registry, context: caller, panes: PaneStore(), db: nil,
        resumes: ResumeBroker(), providerSwitches: ProviderSwitchBroker())
    return (registry, caller)
}

// MARK: - Only what changed travels

/// **The read-modify-write rule, as the wire sees it.** The pane sends the
/// field the operator changed and Go reads the rest off disk — so a save
/// of the display name must not carry a Jira site at all. A pass-through
/// of the whole record would turn every absent field into a present one
/// and silently overwrite a hand edit made while the pane was open.
@Test func savingOneFieldSendsOnlyThatFieldAndTheId() async throws {
    let (registry, caller) = try await registryWithRecordingContext()

    _ = try await registry.dispatch(
        name: "ctx_update_org",
        params: .object(["id": .string("acme"), "displayName": .string("Acme Corporation")]),
        origin: .ui, caller: .test("staging"), confirmation: nil)

    let calls = await caller.recorded()
    guard calls.count == 1, case .object(let arguments) = calls[0].arguments else {
        Issue.record("expected one update_org call, got \(calls)"); return
    }
    #expect(calls[0].tool == "update_org")
    #expect(Set(arguments.keys) == ["id", "displayName"],
            "a save of one field must not carry the other two: \(arguments.keys.sorted())")
    #expect(arguments["displayName"] == .string("Acme Corporation"))
}

/// An explicit empty string is a value — "clear this" — and must reach Go
/// as one. It is the only way an operator clears a Jira site, and a filter
/// that dropped empties would leave them unable to.
@Test func clearingAFieldSendsAnEmptyStringRatherThanOmittingIt() async throws {
    let (registry, caller) = try await registryWithRecordingContext()

    _ = try await registry.dispatch(
        name: "ctx_update_org",
        params: .object(["id": .string("acme"), "jiraBase": .string("")]),
        origin: .ui, caller: .test("staging"), confirmation: nil)

    let calls = await caller.recorded()
    guard calls.count == 1, case .object(let arguments) = calls[0].arguments else {
        Issue.record("expected one update_org call, got \(calls)"); return
    }
    #expect(arguments["jiraBase"] == .string(""))
}

/// A parameter that is not a string is dropped rather than forwarded.
/// Sending it on would have Go decode a `*string` from a number and fail
/// at the wire, which reports as a malformed call rather than as the
/// caller's mistake.
@Test func aNonStringFieldIsNotForwarded() async throws {
    let (registry, caller) = try await registryWithRecordingContext()

    _ = try await registry.dispatch(
        name: "ctx_update_org",
        params: .object(["id": .string("acme"), "displayName": .integer(7)]),
        origin: .ui, caller: .test("staging"), confirmation: nil)

    let calls = await caller.recorded()
    guard calls.count == 1, case .object(let arguments) = calls[0].arguments else {
        Issue.record("expected one update_org call, got \(calls)"); return
    }
    #expect(Set(arguments.keys) == ["id"])
}

/// No id, no write. Refused before the client is reached, so a caller that
/// forgot which organisation it meant does not land an edit in whichever
/// one Go happened to resolve.
@Test func updatingWithNoOrganisationIdIsRefusedBeforeAnythingIsSent() async throws {
    let (registry, caller) = try await registryWithRecordingContext()

    await #expect(throws: (any Error).self) {
        try await registry.dispatch(
            name: "ctx_update_org", params: .object(["displayName": .string("Acme")]),
            origin: .ui, caller: .test("staging"), confirmation: nil)
    }
    #expect(await caller.recorded().isEmpty)
}

// MARK: - The kind, the price, the gate

/// `.control`, so `price` is never consulted, the gate's gating branch is
/// never reached, and nothing parks in the broker. The write-price
/// question dissolves rather than being answered — which is why there is
/// no fourth `ActionKind`.
@Test func theOrganisationEditIsAControlActionThatDeclaresNoPrice() async throws {
    let (registry, _) = try await registryWithRecordingContext()
    guard let descriptor = await registry.all().first(where: { $0.name == "ctx_update_org" }) else {
        Issue.record("ctx_update_org is not registered"); return
    }
    #expect(descriptor.kind == .control)

    // The proof that no price is consulted: it runs in `production`
    // without a confirmation. A `.mutate` action with the default pair
    // would be blocked outright there.
    let (productionRegistry, caller) = try await registryWithRecordingContext()
    _ = try await productionRegistry.dispatch(
        name: "ctx_update_org",
        params: .object(["id": .string("acme"), "displayName": .string("Acme")]),
        origin: .ui, caller: .test("production"), confirmation: nil)
    #expect(await caller.recorded().count == 1,
            "a .control settings edit must not be gated by the environment")
}

// MARK: - Operator-only, and journalled

/// The agent may read the three strings through `ctx_config_tree` and may
/// not write them. `defaultProvider` is the strong half of the reason: it
/// names which account an organisation's projects fall back to, so setting
/// it chooses which credentials Wakil reaches for.
@Test func theOrganisationEditIsOperatorOnlyAndSaysWhy() async throws {
    #expect(operatorOnlyActions.contains("ctx_update_org"))

    let decision = permissionDecision(
        toolName: "mcp__wakil__ctx_update_org",
        knownActions: ["ctx_update_org", "ctx_config_tree"])
    guard case .deny(let reason) = decision else {
        Issue.record("ctx_update_org must be denied, got \(decision)"); return
    }
    // Names the family's own reason rather than borrowing another's — the
    // four-families rule `operatorOnlyDenialMessage` already follows.
    #expect(reason.contains("default account"))
    // And says what the agent may do instead.
    #expect(reason.contains("ctx_config_tree"))
}

/// The refusal the agent meets is `permissionDecision`'s; this is the
/// second gate, for the case where the CLI asks anyway — and it leaves a
/// journal line, so an attempt is visible rather than silent.
@Test func anAgentsOrganisationEditIsJournalled() async throws {
    let (registry, _) = try await registryWithRecordingContext()

    _ = try await registry.dispatch(
        name: "ctx_update_org",
        params: .object(["id": .string("acme"), "displayName": .string("Acme")]),
        origin: .agent, caller: .test("staging"), confirmation: nil)

    let entries = try await registry.journalEntries()
    guard let entry = entries.first(where: { $0.action == "ctx_update_org" }) else {
        Issue.record("ctx_update_org left no journal entry: \(entries)"); return
    }
    #expect(entry.origin == .agent)
    // Nothing here is secret-bearing: the three strings are a display
    // name, a public Atlassian URL and an account id, so they are
    // journalled verbatim. #207's DSN write is the first action to mark a
    // parameter.
    #expect(entry.params == .object([
        "id": .string("acme"), "displayName": .string("Acme"),
    ]))
}

// MARK: - The field enum

/// The pane names a field through an enum rather than a bare string, so it
/// cannot dispatch a field `update_org` does not have — a typo there is
/// silently a no-op, which is the worst outcome a save can have.
@Test func everyOrganisationFieldNamesAParameterTheActionAccepts() async throws {
    let (registry, _) = try await registryWithRecordingContext()
    guard let descriptor = await registry.all().first(where: { $0.name == "ctx_update_org" }),
          case .object(let schema) = descriptor.schema,
          case .object(let properties)? = schema["properties"]
    else {
        Issue.record("ctx_update_org has no object schema"); return
    }
    for field in WindowModel.OrganisationField.allCases {
        #expect(properties[field.rawValue] != nil,
                "\(field.rawValue) is not a parameter of ctx_update_org")
        #expect(!field.label.isEmpty)
    }
    #expect(WindowModel.OrganisationField.allCases.count == 4)
}

/// 2d-ii: the Speech row saves through the same action, one key at a time.
@Test func savingTheSpeechEngineSendsOnlyThatFieldAndTheId() async throws {
    let (registry, caller) = try await registryWithRecordingContext()

    _ = try await registry.dispatch(
        name: "ctx_update_org",
        params: .object(["id": .string("acme"), "speechProvider": .string("apple")]),
        origin: .ui, caller: .test("staging"), confirmation: nil)

    let calls = await caller.recorded()
    guard calls.count == 1, case .object(let arguments) = calls[0].arguments else {
        Issue.record("expected one update_org call, got \(calls)"); return
    }
    #expect(Set(arguments.keys) == ["id", "speechProvider"])
    #expect(arguments["speechProvider"] == .string("apple"))
}

@Test func organisationFieldNamesTheSpeechEngine() {
    #expect(WindowModel.OrganisationField.speechProvider.rawValue == "speechProvider")
}
