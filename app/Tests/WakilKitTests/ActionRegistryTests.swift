import Testing
import Foundation
@testable import WakilKit

private func testAction(_ name: String, _ kind: ActionKind) -> Action {
    Action(name: name, description: "test", kind: kind, schema: .object([:])) { params in
        .object(["echo": params])
    }
}

@Test func dispatchRunsTheHandlerAndReturnsItsValue() async throws {
    let r = ActionRegistry(journalDirectory: testScratchRoot
        .appendingPathComponent(UUID().uuidString), sessionId: "s1")
    await r.register(testAction("db_run_query", .read))
    let out = try await r.dispatch(name: "db_run_query", params: .string("sql"),
                                   origin: .ui, caller: .test("staging"), confirmation: nil)
    #expect(out == .object(["echo": .string("sql")]))
}

@Test func unknownActionThrowsRatherThanSilentlySucceeding() async throws {
    let r = ActionRegistry(journalDirectory: testScratchRoot
        .appendingPathComponent(UUID().uuidString), sessionId: "s1")
    await #expect(throws: ActionError.unknown("nope")) {
        try await r.dispatch(name: "nope", params: .null, origin: .agent,
                             caller: .test("staging"), confirmation: nil)
    }
    // Probing for a nonexistent action name must still leave a trace: an
    // audit trail that only records recognized names would miss exactly
    // the attempts most worth reviewing.
    let entries = try await r.journalEntries()
    // Guarded, not `#expect`-ed then indexed: `entries[0]` on an empty list
    // traps, and a trap takes the whole test process down — every test that
    // has not yet reported never reports at all — rather than failing this
    // one test. Same shape at every count-then-index site in this file.
    guard entries.count == 1 else {
        Issue.record("expected 1 journal entry, got \(entries.count)"); return
    }
    #expect(entries[0].action == "nope")
    #expect(entries[0].outcome == "unknown")
}

@Test func allReturnsNonExecutableDescriptorsOnly() async throws {
    let r = ActionRegistry(journalDirectory: testScratchRoot
        .appendingPathComponent(UUID().uuidString), sessionId: "s1")
    await r.register(testAction("test.mutate", .mutate))
    let descriptors = await r.all()
    guard descriptors.count == 1 else {
        Issue.record("expected 1 descriptor, got \(descriptors.count)"); return
    }
    let d = descriptors[0]
    #expect(d.name == "test.mutate")
    #expect(d.description == "test")
    #expect(d.kind == .mutate)
    #expect(d.schema == .object([:]))

    // `ActionDescriptor` has no `handler` member — `d.handler` is a compile
    // error, not merely inaccessible — so the only way this file could
    // compile a call to a registered action's handler is through
    // `dispatch`. As a second, runtime-checkable guard against handler ever
    // creeping back onto the returned type as a stored property, reflect
    // over the value and assert no member named "handler" is present.
    let memberNames = Mirror(reflecting: d).children.compactMap(\.label)
    #expect(!memberNames.contains("handler"))
}

@Test func journalEntriesAreIdenticalAcrossOriginsExceptForOrigin() async throws {
    let dir = testScratchRoot.appendingPathComponent(UUID().uuidString)
    let r = ActionRegistry(journalDirectory: dir, sessionId: "s1")
    await r.register(testAction("db_run_query", .read))
    _ = try await r.dispatch(name: "db_run_query", params: .string("q"),
                             origin: .ui, caller: .test("staging"), confirmation: nil)
    _ = try await r.dispatch(name: "db_run_query", params: .string("q"),
                             origin: .agent, caller: .test("staging"), confirmation: nil)
    let entries = try await r.journalEntries()
    guard entries.count == 2 else {
        Issue.record("expected 2 journal entries, got \(entries.count)"); return
    }
    #expect(entries[0].origin == .ui)
    #expect(entries[1].origin == .agent)
    #expect(entries[0].action == entries[1].action)
    #expect(entries[0].params == entries[1].params)
    #expect(entries[0].outcome == entries[1].outcome)
}

@Test func mutationWithoutConfirmationIsRefusedAndJournalledAsGated() async throws {
    let dir = testScratchRoot.appendingPathComponent(UUID().uuidString)
    let r = ActionRegistry(journalDirectory: dir, sessionId: "s1")
    await r.register(testAction("test.mutate", .mutate))   // test-only: 2a ships no .mutate actions
    await #expect(throws: ActionError.needsConfirmation("test.mutate")) {
        try await r.dispatch(name: "test.mutate", params: .null, origin: .ui,
                             caller: .test("staging"), confirmation: nil)
    }
    let entries = try await r.journalEntries()
    guard entries.count == 1 else {
        Issue.record("expected 1 journal entry, got \(entries.count)"); return
    }
    #expect(entries[0].outcome == "gated")
}

@Test func mutationInProductionIsBlockedEvenWithCorrectConfirmation() async throws {
    let dir = testScratchRoot.appendingPathComponent(UUID().uuidString)
    let r = ActionRegistry(journalDirectory: dir, sessionId: "s1")
    await r.register(testAction("test.mutate", .mutate))
    await #expect(throws: ActionError.blockedInProduction("test.mutate")) {
        try await r.dispatch(name: "test.mutate", params: .null, origin: .ui,
                             caller: .test("production"), confirmation: "confirm")
    }
}

@Test func journalIsAppendedAsOneJSONLineEach() async throws {
    let dir = testScratchRoot.appendingPathComponent(UUID().uuidString)
    let r = ActionRegistry(journalDirectory: dir, sessionId: "s1")
    await r.register(testAction("a.b", .read))
    _ = try await r.dispatch(name: "a.b", params: .null, origin: .debug,
                             caller: .test("staging"), confirmation: nil)
    let text = try String(contentsOf: dir.appendingPathComponent("s1.jsonl"), encoding: .utf8)
    #expect(text.hasSuffix("\n"))
    #expect(text.split(separator: "\n").count == 1)
}

@Test func mirrorReflectingARegistryYieldsNoChildren() async throws {
    // Defends against the casual `Mirror(reflecting: registry)` walk a
    // reviewer used to recover the private `actions` dictionary (and, from
    // it, a live handler) during this task's review. This is not a claim
    // that reflection in general can't reach `actions` — see the doc
    // comment on `ActionRegistry` — only that this specific, easy route is
    // closed.
    let r = ActionRegistry(journalDirectory: testScratchRoot
        .appendingPathComponent(UUID().uuidString), sessionId: "s1")
    await r.register(testAction("test.mutate", .mutate))
    let mirror = Mirror(reflecting: r)
    #expect(mirror.children.isEmpty)
}

@Test func dispatchGatesAnAgentControlActionNamingProduction() async throws {
    let directory = testScratchRoot
        .appendingPathComponent("registry-gate-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let registry = ActionRegistry(journalDirectory: directory, sessionId: "s")

    let ran = Ran()
    await registry.register(Action(
        name: "ctx_set_environment_stub",
        description: "stub",
        kind: .control,
        schema: .object([:]),
        handler: { _ in await ran.mark(); return .object([:]) },
        targetEnvironmentParam: "name"
    ))

    // Agent, target production: gated, and the handler never runs.
    await #expect(throws: ActionError.needsConfirmation("ctx_set_environment_stub")) {
        _ = try await registry.dispatch(
            name: "ctx_set_environment_stub",
            params: .object(["name": .string("production")]),
            origin: .agent, caller: .test("staging"), confirmation: nil)
    }
    #expect(await ran.count == 0)

    // Same call with the confirmation: runs.
    _ = try await registry.dispatch(
        name: "ctx_set_environment_stub",
        params: .object(["name": .string("production")]),
        origin: .agent, caller: .test("staging"), confirmation: "confirm")
    #expect(await ran.count == 1)

    // Same call from the UI: runs with no confirmation.
    _ = try await registry.dispatch(
        name: "ctx_set_environment_stub",
        params: .object(["name": .string("production")]),
        origin: .ui, caller: .test("staging"), confirmation: nil)
    #expect(await ran.count == 2)

    // Agent, target staging: runs with no confirmation.
    _ = try await registry.dispatch(
        name: "ctx_set_environment_stub",
        params: .object(["name": .string("staging")]),
        origin: .agent, caller: .test("staging"), confirmation: nil)
    #expect(await ran.count == 3)

    let entries = try await registry.journalEntries()
    #expect(entries.map(\.outcome) == ["gated", "ok", "ok", "ok"])
}

@Test func aControlActionWithNoTargetParamIsNeverGated() async throws {
    let directory = testScratchRoot
        .appendingPathComponent("registry-gate-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let registry = ActionRegistry(journalDirectory: directory, sessionId: "s")

    let ran = Ran()
    await registry.register(Action(
        name: "pane_move_stub",
        description: "stub",
        kind: .control,
        schema: .object([:]),
        handler: { _ in await ran.mark(); return .object([:]) }
    ))

    // A layout action carrying a params value that happens to read
    // "production" must still not be gated: it names no target
    // environment, so there is no key for the gate to read.
    _ = try await registry.dispatch(
        name: "pane_move_stub",
        params: .object(["name": .string("production")]),
        origin: .agent, caller: .test("production"), confirmation: nil)
    #expect(await ran.count == 1)
}

/// A counter an escaping `@Sendable` handler can bump.
actor Ran {
    private(set) var count = 0
    func mark() { count += 1 }
}

// MARK: - The environment a decision was made against (issue #15)

@Test func everyJournalOutcomeCarriesTheEnvironmentTheGateJudged() async throws {
    // One test across all five outcomes rather than five, because the claim
    // is precisely that no outcome is exempt: an audit record that carried
    // the environment on some lines and not others would be worse than one
    // that never carried it, since the absence would read as a fact.
    let dir = testScratchRoot.appendingPathComponent(UUID().uuidString)
    let r = ActionRegistry(journalDirectory: dir, sessionId: "s1")
    await r.register(testAction("db_run_query", .read))
    await r.register(testAction("test.mutate", .mutate))
    await r.register(Action(name: "test.throws", description: "t", kind: .read,
                            schema: .object([:])) { _ in throw ActionError.unknown("boom") })

    _ = try? await r.dispatch(name: "nope", params: .null, origin: .agent,
                              caller: .test("dev"), confirmation: nil)                    // unknown
    _ = try? await r.dispatch(name: "test.mutate", params: .null, origin: .ui,
                              caller: .test("production"), confirmation: "confirm")       // blocked
    _ = try? await r.dispatch(name: "test.mutate", params: .null, origin: .ui,
                              caller: .test("staging"), confirmation: nil)                // gated
    _ = try? await r.dispatch(name: "db_run_query", params: .null, origin: .ui,
                              caller: .test("staging"), confirmation: nil)                // ok
    _ = try? await r.dispatch(name: "test.throws", params: .null, origin: .ui,
                              caller: .test("local"), confirmation: nil)                  // error

    let entries = try await r.journalEntries()
    guard entries.count == 5 else {
        Issue.record("expected 5 journal entries, got \(entries.count)"); return
    }
    #expect(entries.map(\.outcome) == ["unknown", "blocked", "gated", "ok", "error"])
    #expect(entries.map(\.environment) == ["dev", "production", "staging", "staging", "local"])
}

@Test func uncertainMutationCarriesTheEnvironmentToo() async throws {
    // The `"error"` → `"uncertain"` pair is read together, so the second
    // line must be able to answer the same question as the first.
    let dir = testScratchRoot.appendingPathComponent(UUID().uuidString)
    let r = ActionRegistry(journalDirectory: dir, sessionId: "s1")
    try await r.journalUncertainMutation(action: "db_run_mutation", params: .null,
                                         origin: .agent, caller: .test("staging"))
    let entries = try await r.journalEntries()
    guard entries.count == 1 else {
        Issue.record("expected 1 journal entry, got \(entries.count)"); return
    }
    #expect(entries[0].outcome == "uncertain")
    #expect(entries[0].environment == "staging")
}

@Test func journalLinesWrittenBeforeThisFieldExistedStillDecode() async throws {
    // Every line in every journal on disk today predates `environment`.
    // Making the field non-optional would make the whole of that history
    // undecodable — `journalEntries()` throws on the first such line and
    // returns nothing at all, so one old file would hide every new entry
    // after it. `nil` means "not recorded", which is the truth.
    let dir = testScratchRoot.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let legacy = #"""
    {"id":"0086447B","ts":810722821.858347,"action":"db_run_mutation","params":{},"origin":"agent","outcome":"blocked"}
    """#
    try (legacy + "\n").write(to: dir.appendingPathComponent("s1.jsonl"),
                              atomically: true, encoding: .utf8)
    let r = ActionRegistry(journalDirectory: dir, sessionId: "s1")
    let entries = try await r.journalEntries()
    guard entries.count == 1 else {
        Issue.record("expected 1 journal entry, got \(entries.count)"); return
    }
    #expect(entries[0].action == "db_run_mutation")
    #expect(entries[0].environment == nil)
}

// MARK: - The write price is actually wired through dispatch (Decision 25)

@Test func dispatchUsesTheActionsOwnPriceRatherThanWriteGatesDefault() async throws {
    // If `price: action.price` were dropped from `dispatch`'s `writeGate`
    // call (reverting to the four-argument call), `writeGate` would fall
    // back to its own default parameter — `(.block, .gate)`, identical to
    // this action's own default — and this dispatch would throw
    // `.needsConfirmation` instead of running. Every existing action uses
    // that same default pair, so no test that only ever registers default
    // actions can catch the wiring being dropped; this one declares a
    // non-default price specifically to make the two cases diverge.
    let directory = testScratchRoot
        .appendingPathComponent("registry-price-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let registry = ActionRegistry(journalDirectory: directory, sessionId: "s")

    let ran = Ran()
    await registry.register(Action(
        name: "cheap_write_stub",
        description: "stub",
        kind: .mutate,
        schema: .object([:]),
        handler: { _ in await ran.mark(); return .object([:]) },
        price: (production: .block, otherwise: .allow)
    ))

    // Outside production, no confirmation supplied. The default pair would
    // gate this and throw `.needsConfirmation` without running the handler;
    // the declared price allows it outright.
    _ = try await registry.dispatch(
        name: "cheap_write_stub", params: .null,
        origin: .agent, caller: .test("staging"), confirmation: nil)
    #expect(await ran.count == 1)
}

@Test func dispatchUsesTheActionsOwnPriceInProductionToo() async throws {
    // The mirror case: a non-default `production` answer of `.gate`, where
    // the default pair would `.block` outright and no confirmation string
    // could change that.
    let directory = testScratchRoot
        .appendingPathComponent("registry-price-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let registry = ActionRegistry(journalDirectory: directory, sessionId: "s")

    let ran = Ran()
    await registry.register(Action(
        name: "confirmable_in_production_stub",
        description: "stub",
        kind: .mutate,
        schema: .object([:]),
        handler: { _ in await ran.mark(); return .object([:]) },
        price: (production: .gate, otherwise: .gate)
    ))

    _ = try await registry.dispatch(
        name: "confirmable_in_production_stub", params: .null,
        origin: .ui, caller: .test("production"), confirmation: "confirm")
    #expect(await ran.count == 1)
}
