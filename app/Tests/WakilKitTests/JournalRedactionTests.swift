import Testing
import Foundation
@testable import WakilKit

/// **The journal's first redaction rule.**
///
/// `JournalEntry.params` is written verbatim on every dispatch — allowed,
/// gated, blocked, unknown and errored alike. That is the property the
/// journal exists for, and it is also why *"delegate the credential
/// through an action"* and *"the secret rides in the params"* cannot both
/// be true: 2e mints provider credentials in Go, carrying identifiers
/// only, precisely so nothing travels. One parameter in the phase is still
/// a secret a human typed — a database DSN — and that one needs the
/// journal to record that it happened without recording what it was.
///
/// **The mark is on `Action`, not `ActionDescriptor`.** `dispatch` holds
/// the former and never builds the latter, so a mark on the descriptor
/// would be a mark nothing on the write path can read.
///
/// **Redaction is positional, not byte-matching** — the opposite of the Go
/// scrubber, and correctly so. The Go scrubber is handed a blob it did not
/// compose and has to go looking for the secret's bytes in it. The journal
/// is handed the action's own parameters and *knows which one is the
/// secret*, so looking is both unnecessary and wrong: a byte search
/// redacts an innocent parameter that happens to equal the secret, and
/// misses a secret that arrived re-encoded.

private func scratchJournal() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
}

private func secretBearing(_ name: String, secretParams: Set<String>) -> Action {
    Action(
        name: name, description: "test", kind: .control,
        audience: .operatorOnly, schema: .object([:]),
        handler: { _ in .null },
        secretParams: secretParams)
}

/// The rule itself: the parameter's **name** survives, its value reads
/// `[redacted]`, and every unmarked parameter beside it is untouched.
@Test func aMarkedParametersNameSurvivesAndItsValueReadsRedacted() async throws {
    let registry = ActionRegistry(journalDirectory: scratchJournal(), sessionId: "s1")
    await registry.register(secretBearing("db_set_dsn", secretParams: ["dsn"]))

    _ = try await registry.dispatch(
        name: "db_set_dsn",
        params: .object([
            "database": .string("orders"),
            "dsn": .string("mysql://root:hunter2@db.internal:3306/orders"),
            "driver": .string("mysql"),
        ]),
        origin: .ui, caller: .test("staging"), confirmation: nil)

    let entries = try await registry.journalEntries()
    guard entries.count == 1, case .object(let params) = entries[0].params else {
        Issue.record("expected one entry with object params, got \(entries)"); return
    }
    // The name is what makes the entry legible: "a DSN was set on orders"
    // is the fact the journal is for, and it is unreadable if the key
    // disappears along with the value.
    #expect(params["dsn"] == .string("[redacted]"))
    #expect(params["database"] == .string("orders"))
    #expect(params["driver"] == .string("mysql"))
    #expect(Set(params.keys) == ["database", "dsn", "driver"])
}

/// **Positional, not byte-matching.** An *unmarked* parameter whose value
/// happens to equal the secret's bytes is journalled verbatim. If this
/// test ever passes by finding `[redacted]` in `note`, the implementation
/// has started searching for the secret rather than reading the mark —
/// which is the Go scrubber's job and not this one's.
@Test func anUnmarkedParameterEqualToTheSecretsBytesIsStillJournalledVerbatim() async throws {
    let registry = ActionRegistry(journalDirectory: scratchJournal(), sessionId: "s1")
    await registry.register(secretBearing("db_set_dsn", secretParams: ["dsn"]))

    let shared = "mysql://root:hunter2@db.internal:3306/orders"
    _ = try await registry.dispatch(
        name: "db_set_dsn",
        params: .object(["dsn": .string(shared), "note": .string(shared)]),
        origin: .ui, caller: .test("staging"), confirmation: nil)

    let entries = try await registry.journalEntries()
    guard entries.count == 1, case .object(let params) = entries[0].params else {
        Issue.record("expected one entry with object params, got \(entries)"); return
    }
    #expect(params["dsn"] == .string("[redacted]"))
    #expect(params["note"] == .string(shared))
}

/// A refused dispatch journals too, and a refusal is exactly when a secret
/// is most likely to be in the parameters of something that never ran. The
/// mark has to be read before the gate's verdict is written, not after the
/// handler's.
@Test func aRefusedDispatchRedactsTheSameParameterTheAllowedOneDoes() async throws {
    let registry = ActionRegistry(journalDirectory: scratchJournal(), sessionId: "s1")
    // `.mutate` with the default price, in `production`: blocked outright,
    // so the handler is never reached and only the journal line exists.
    await registry.register(
        Action(
            name: "db_write_dsn", description: "test", kind: .mutate,
            audience: .operatorOnly, schema: .object([:]),
            handler: { _ in .null },
            secretParams: ["dsn"]))

    await #expect(throws: ActionError.blockedInProduction("db_write_dsn")) {
        try await registry.dispatch(
            name: "db_write_dsn",
            params: .object(["dsn": .string("postgres://u:p@h/db")]),
            origin: .ui, caller: .test("production"), confirmation: nil)
    }

    let entries = try await registry.journalEntries()
    guard entries.count == 1, case .object(let params) = entries[0].params else {
        Issue.record("expected one entry with object params, got \(entries)"); return
    }
    #expect(entries[0].outcome == "blocked")
    #expect(params["dsn"] == .string("[redacted]"))
}

/// **The unknown-action-name hole.** This path has no registered action, so
/// it has no mark to read — and it wrote `params` verbatim, which makes it
/// the one dispatch path that would journal a secret in the clear from the
/// first secret-bearing action onward. A near-miss on the name is enough:
/// the caller still sends the DSN.
///
/// The close is the only one available without a registry-wide list of
/// parameter names (which would be byte-matching by another route): **keys
/// survive, every value is redacted.** The attempt stays legible — who
/// asked, for what name, with which parameters — and none of it is worth
/// anything to a reader of the file.
@Test func anUnknownActionNameJournalsItsParameterNamesAndNoneOfTheirValues() async throws {
    let registry = ActionRegistry(journalDirectory: scratchJournal(), sessionId: "s1")

    await #expect(throws: ActionError.unknown("db_set_dsnn")) {
        try await registry.dispatch(
            name: "db_set_dsnn",
            params: .object([
                "database": .string("orders"),
                "dsn": .string("mysql://root:hunter2@db.internal:3306/orders"),
            ]),
            origin: .agent, caller: .test("staging"), confirmation: nil)
    }

    let entries = try await registry.journalEntries()
    guard entries.count == 1, case .object(let params) = entries[0].params else {
        Issue.record("expected one entry with object params, got \(entries)"); return
    }
    #expect(entries[0].outcome == "unknown")
    #expect(Set(params.keys) == ["database", "dsn"])
    #expect(params["dsn"] == .string("[redacted]"))
    #expect(params["database"] == .string("[redacted]"))
}

/// A marked action whose parameters are not an object at all has no
/// position to redact, so the whole value goes. Silently journalling it
/// verbatim would be the hole this rule exists to close, reached by a
/// shape rather than by a name.
@Test func aMarkedActionCalledWithNonObjectParamsRedactsTheWholeValue() async throws {
    let registry = ActionRegistry(journalDirectory: scratchJournal(), sessionId: "s1")
    await registry.register(secretBearing("db_set_dsn", secretParams: ["dsn"]))

    _ = try await registry.dispatch(
        name: "db_set_dsn", params: .string("mysql://root:hunter2@db/orders"),
        origin: .ui, caller: .test("staging"), confirmation: nil)

    let entries = try await registry.journalEntries()
    guard entries.count == 1 else {
        Issue.record("expected one entry, got \(entries.count)"); return
    }
    #expect(entries[0].params == .string("[redacted]"))
}

/// An action that marks nothing is journalled exactly as it always was.
/// This is the "nothing else changed" pin: 45 actions register today and
/// none of them marks a parameter.
@Test func anActionThatMarksNothingIsJournalledVerbatim() async throws {
    let registry = ActionRegistry(journalDirectory: scratchJournal(), sessionId: "s1")
    await registry.register(
        Action(
            name: "pane_open", description: "test", kind: .control,
            audience: .agentReachable, schema: .object([:])) { _ in .null })

    _ = try await registry.dispatch(
        name: "pane_open", params: .object(["kind": .string("db"), "title": .string("orders")]),
        origin: .agent, caller: .test("staging"), confirmation: nil)

    let entries = try await registry.journalEntries()
    guard entries.count == 1 else {
        Issue.record("expected one entry, got \(entries.count)"); return
    }
    #expect(entries[0].params == .object(["kind": .string("db"), "title": .string("orders")]))
}

/// The second journal line a mutation can leave — `"uncertain"` — is
/// written by a different method, from the caller's own copy of the
/// parameters. It reads the same mark, or the rule would hold on the line
/// `dispatch` writes and not on the line beside it.
@Test func theUncertainMutationLineRedactsTheSameParameter() async throws {
    let registry = ActionRegistry(journalDirectory: scratchJournal(), sessionId: "s1")
    await registry.register(secretBearing("db_set_dsn", secretParams: ["dsn"]))

    try await registry.journalUncertainMutation(
        action: "db_set_dsn",
        params: .object(["dsn": .string("mysql://root:hunter2@db/orders")]),
        origin: .ui, caller: .test("staging"))

    let entries = try await registry.journalEntries()
    guard entries.count == 1, case .object(let params) = entries[0].params else {
        Issue.record("expected one entry with object params, got \(entries)"); return
    }
    #expect(entries[0].outcome == "uncertain")
    #expect(params["dsn"] == .string("[redacted]"))
}

// MARK: - The rule's first real caller (#207)

/// **`db_set_dsn` is why #197 shipped**, and this is the test that proves
/// the two halves meet.
///
/// `JournalEntry.params` is written verbatim on every dispatch — refused
/// and blocked ones included — so without the mark a database password
/// lands in the audit log on the first attempt. The parameter's NAME
/// survives, because *"a DSN was set on `core`"* is the fact the journal
/// is for; its value reads `[redacted]`.
@Test func theDatabaseDSNIsJournalledRedactedAndEverythingElseVerbatim() async throws {
    let registry = ActionRegistry(journalDirectory: scratchJournal(), sessionId: "dsn")
    await registerStandardActions(
        into: registry, context: nil, panes: PaneStore(), db: nil,
        resumes: ResumeBroker(), providerSwitches: ProviderSwitchBroker())

    // The handler throws (no context client), which is exactly the case
    // that matters: a REFUSED dispatch is journalled too.
    _ = try? await registry.dispatch(
        name: "db_set_dsn",
        params: .object([
            "projectPath": .string("/src/orders/project.json"),
            "environment": .string("staging"),
            "name": .string("core"),
            "driver": .string("mysql"),
            "dsn": .string("mysql://root:hunter2@db.internal:3306/orders"),
        ]),
        origin: .ui, caller: .test("staging"), confirmation: nil)

    let entries = try await registry.journalEntries()
    guard let entry = entries.first(where: { $0.action == "db_set_dsn" }),
          case .object(let params) = entry.params
    else {
        Issue.record("db_set_dsn left no journal entry: \(entries)"); return
    }

    // The name survives; the value does not.
    #expect(params["dsn"] == .string("[redacted]"))
    // Everything else is verbatim — a project path and a driver are not
    // secrets, and losing them would cost the journal its legibility.
    #expect(params["name"] == .string("core"))
    #expect(params["environment"] == .string("staging"))
    #expect(params["driver"] == .string("mysql"))
    #expect(params["projectPath"] == .string("/src/orders/project.json"))

    // And the password appears in NO parameter, which is the claim the
    // operator actually cares about — checked across every value rather
    // than only the marked one, because a redaction that moved the secret
    // somewhere else would still be a leak.
    for (key, value) in params {
        if case .string(let text) = value {
            #expect(!text.contains("hunter2"), "the password survived in \(key): \(text)")
        }
    }
}

/// The write credential is no less a secret than the read one.
@Test func theWriteCredentialIsRedactedToo() async throws {
    let registry = ActionRegistry(journalDirectory: scratchJournal(), sessionId: "dsn")
    await registerStandardActions(
        into: registry, context: nil, panes: PaneStore(), db: nil,
        resumes: ResumeBroker(), providerSwitches: ProviderSwitchBroker())

    _ = try? await registry.dispatch(
        name: "db_set_dsn",
        params: .object([
            "projectPath": .string("/src/orders/project.json"),
            "environment": .string("staging"), "name": .string("core"),
            "driver": .string("mysql"),
            "dsn": .string("mysql://ro:pw@db/orders"),
            "grantWrite": .bool(true),
            "writeDsn": .string("mysql://rw:otherpw@db/orders"),
        ]),
        origin: .ui, caller: .test("staging"), confirmation: nil)

    let entries = try await registry.journalEntries()
    guard let entry = entries.first(where: { $0.action == "db_set_dsn" }),
          case .object(let params) = entry.params
    else {
        Issue.record("no entry"); return
    }
    #expect(params["dsn"] == .string("[redacted]"))
    #expect(params["writeDsn"] == .string("[redacted]"))
    // The flag itself is not a secret and stays readable — it is the one
    // thing about this call an auditor most needs to see.
    #expect(params["grantWrite"] == .bool(true))
}

/// 2e-iii. An API entry's token is a secret in the action's own parameters.
@Test func theApiEntryTokenIsRedactedAndTheFourActionsAreOperatorOnly() async throws {
    let registry = ActionRegistry(journalDirectory: scratchJournal(), sessionId: "api-token")
    await registerStandardActions(
        into: registry, context: nil, panes: PaneStore(), db: nil,
        resumes: ResumeBroker(), providerSwitches: ProviderSwitchBroker())

    _ = try? await registry.dispatch(
        name: "api_set_entry",
        params: .object([
            "projectPath": .string("/src/orders/project.json"),
            "environment": .string("staging"), "name": .string("orders"),
            "baseUrl": .string("https://orders.example"), "token": .string("hunter2"),
        ]),
        origin: .ui, caller: .test("staging"), confirmation: nil)

    let entries = try await registry.journalEntries()
    guard let entry = entries.first(where: { $0.action == "api_set_entry" }),
          case .object(let params) = entry.params
    else { Issue.record("no entry"); return }
    #expect(params["token"] == .string("[redacted]"))
    #expect(params["baseUrl"] == .string("https://orders.example"))
    for name in ["api_set_entry", "api_update_entry", "api_remove_entry", "db_update_database"] {
        #expect(operatorOnlyActions.contains(name))
    }
}

/// **The reason new to the operator-only set.** Every other member objects
/// to what the agent could REACH; this one objects to what it would
/// CARRY — and the denial sentence says so rather than borrowing another
/// family's words.
@Test func theDatabaseWriteIsOperatorOnlyBecauseTheAgentWouldCarryTheSecret() throws {
    #expect(operatorOnlyActions.contains("db_set_dsn"))
    #expect(operatorOnlyActions.contains("db_remove_database"))

    let decision = permissionDecision(
        toolName: "mcp__wakil__db_set_dsn",
        knownActions: ["db_set_dsn", "ctx_config_tree"])
    guard case .deny(let reason) = decision else {
        Issue.record("db_set_dsn must be denied, got \(decision)"); return
    }
    // Its own reason: what the agent would carry.
    #expect(reason.contains("your own tool"))
    // And what it may do instead.
    #expect(reason.contains("ctx_config_tree"))
    #expect(reason.contains("never a value"))
}
