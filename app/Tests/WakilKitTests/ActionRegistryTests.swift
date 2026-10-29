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

// MARK: - A dispatch can say how it came (3b-ix)

@Test func aDispatchTaggedFastPathIsJournalledWithVia() async throws {
    let r = ActionRegistry(journalDirectory: testScratchRoot
        .appendingPathComponent(UUID().uuidString), sessionId: "s1")
    await r.register(testAction("noop_read", .read))
    let place = Place(organization: "org", project: "proj", environment: "staging")
    _ = try await r.dispatch(name: "noop_read", params: .object([:]), origin: .ui,
                             caller: DispatchCaller(place: place, session: nil, via: "fastPath"),
                             confirmation: nil)
    let entries = try await r.journalEntries()
    #expect(entries.last?.via == "fastPath")
    #expect(await r.descriptor(named: "noop_read")?.kind == .read)
    #expect(await r.descriptor(named: "nope") == nil)
}

@Test func aDispatchWithoutViaWritesNoViaKey() async throws {
    let dir = testScratchRoot.appendingPathComponent(UUID().uuidString)
    let r = ActionRegistry(journalDirectory: dir, sessionId: "s1")
    await r.register(testAction("noop_read", .read))
    _ = try await r.dispatch(name: "noop_read", params: .object([:]), origin: .ui,
                             caller: .test("staging"), confirmation: nil)
    let line = try String(contentsOf: dir.appendingPathComponent("s1.jsonl"), encoding: .utf8)
    #expect(!line.contains("\"via\""))
    #expect(try await r.journalEntries().last?.via == nil)
}

/// An operator-only action is refused at `dispatch` when the agent asks, whatever let the call
/// through the permission prompt: registered `.operatorOnly`, or named in `operatorOnlyActions`.
/// The operator's own origins still run it. Must fail if `dispatch` stops reading the audience.
@Test(arguments: ["ctx_connection_allow_set", "ctx_connection_update", "ctx_config_tree_for", "ctx_list_orgs"])
func dispatchRefusesAnOperatorOnlyActionFromTheAgent(name: String) async throws {
    let r = ActionRegistry(journalDirectory: testScratchRoot
        .appendingPathComponent(UUID().uuidString), sessionId: "s1")
    await r.register(Action(name: name, description: "test", kind: .control, audience: .operatorOnly,
                            schema: .object([:])) { _ in .string("ran") })
    await #expect(throws: ActionError.operatorOnly(name)) {
        try await r.dispatch(name: name, params: .object([:]), origin: .agent,
                             caller: .test("staging"), confirmation: nil)
    }
    for origin in [ActionOrigin.ui, .debug] {
        let out = try await r.dispatch(name: name, params: .object([:]), origin: origin,
                                       caller: .test("staging"), confirmation: nil)
        #expect(out == .string("ran"))
    }
    let outcomes = try await r.journalEntries().map(\.outcome)
    #expect(outcomes == ["refused", "ok", "ok"])
    #expect(ActionError.operatorOnly(name).description.hasPrefix("\(name): only the operator"))
}

/// The name alone is enough: an action on `operatorOnlyActions` with no audience said is still
/// refused to the agent.
@Test func dispatchRefusesANameOnTheOperatorOnlyListFromTheAgent() async throws {
    let r = ActionRegistry(journalDirectory: testScratchRoot
        .appendingPathComponent(UUID().uuidString), sessionId: "s1")
    await r.register(testAction("ctx_list_orgs", .read))
    await #expect(throws: ActionError.operatorOnly("ctx_list_orgs")) {
        try await r.dispatch(name: "ctx_list_orgs", params: .null, origin: .agent,
                             caller: .test("staging"), confirmation: nil)
    }
}
// MARK: - A price per call (3c-ii)

private func pricedRegistry() -> ActionRegistry {
    ActionRegistry(journalDirectory: testScratchRoot
        .appendingPathComponent("registry-call-price-\(UUID().uuidString)", isDirectory: true),
        sessionId: "s")
}

/// Counts how often a call price is asked and records what it was handed.
private actor PriceProbe {
    private(set) var asked = 0
    private(set) var params: JSONValue?
    private(set) var caller: DispatchCaller?
    private(set) var origin: ActionOrigin?
    private(set) var boundCaller: DispatchCaller?
    private(set) var boundOrigin: ActionOrigin?
    private(set) var boundHome: LayoutScope?
    func record(_ params: JSONValue, _ caller: DispatchCaller, _ origin: ActionOrigin,
                boundCaller: DispatchCaller?, boundOrigin: ActionOrigin, boundHome: LayoutScope?) {
        asked += 1
        self.params = params
        self.caller = caller
        self.origin = origin
        self.boundCaller = boundCaller
        self.boundOrigin = boundOrigin
        self.boundHome = boundHome
    }
}

private func pricedAction(_ name: String, _ kind: ActionKind, ran: Ran, probe: PriceProbe,
                          answer: GateDecision) -> Action {
    var action = Action(name: name, description: "stub", kind: kind, schema: .object([:]),
                        handler: { _ in await ran.mark(); return .object([:]) })
    action.callPrice = { params, caller, origin in
        await probe.record(params, caller, origin,
                           boundCaller: ActionRegistry.dispatchCaller,
                           boundOrigin: ActionRegistry.dispatchOrigin,
                           boundHome: ScopeRouting.home)
        return answer
    }
    return action
}

@Test func aCallPriceDecidesTheGateForThatCall() async throws {
    let registry = pricedRegistry()
    let ran = Ran()
    let probe = PriceProbe()
    await registry.register(pricedAction("gated_call", .mutate, ran: ran, probe: probe, answer: .gate))
    await registry.register(pricedAction("allowed_call", .mutate, ran: ran, probe: probe, answer: .allow))
    await registry.register(pricedAction("blocked_call", .mutate, ran: ran, probe: probe, answer: .block))

    await #expect(throws: ActionError.needsConfirmation("gated_call")) {
        try await registry.dispatch(name: "gated_call", params: .null, origin: .agent,
                                    caller: .test("staging"), confirmation: nil)
    }
    #expect(await ran.count == 0)
    _ = try await registry.dispatch(name: "allowed_call", params: .null, origin: .agent,
                                    caller: .test("staging"), confirmation: nil)
    #expect(await ran.count == 1)
    // A per-call `.block` stands outside production too: the price is the call's, not the place's.
    await #expect(throws: ActionError.blockedInProduction("blocked_call")) {
        try await registry.dispatch(name: "blocked_call", params: .null, origin: .ui,
                                    caller: .test("staging"), confirmation: nil)
    }
    await #expect(throws: ActionError.blockedInProduction("blocked_call")) {
        try await registry.dispatch(name: "blocked_call", params: .null, origin: .ui,
                                    caller: .test("staging"), confirmation: "confirm")
    }
    #expect(await ran.count == 1)
    #expect(try await registry.journalEntries().map(\.outcome) == ["gated", "ok", "blocked", "blocked"])
}

@Test func aCallPriceIsNeverAskedForAReadOrAControl() async throws {
    let registry = pricedRegistry()
    let ran = Ran()
    let probe = PriceProbe()
    await registry.register(pricedAction("a_read", .read, ran: ran, probe: probe, answer: .block))
    await registry.register(pricedAction("a_control", .control, ran: ran, probe: probe, answer: .block))
    _ = try await registry.dispatch(name: "a_read", params: .null, origin: .agent,
                                    caller: .test("production"), confirmation: nil)
    _ = try await registry.dispatch(name: "a_control", params: .null, origin: .agent,
                                    caller: .test("production"), confirmation: nil)
    #expect(await ran.count == 2)
    #expect(await probe.asked == 0)
}

@Test func theCallPriceSeesParamsCallerAndOrigin() async throws {
    let registry = pricedRegistry()
    let home = LayoutScope(organization: "initech", project: "b", environment: "staging")
    let screen = LayoutScope(organization: "initech", project: "a", environment: "staging")
    // C5a: an agent session's call is priced in its own canvas, never the one on screen.
    registry.setScopeLookup { caller in caller.session == nil ? nil : home }
    registry.setScreenScope { screen }
    let ran = Ran()
    let probe = PriceProbe()
    await registry.register(pricedAction("seen_call", .mutate, ran: ran, probe: probe, answer: .allow))
    let params = JSONValue.object(["ref": .string("e7")])
    let caller = DispatchCaller.test("staging", session: "bg-1", conversation: "conv")
    _ = try await registry.dispatch(name: "seen_call", params: params, origin: .agent,
                                    caller: caller, confirmation: nil)
    #expect(await probe.asked == 1)
    #expect(await probe.params == params)
    #expect(await probe.caller?.session == "bg-1")
    #expect(await probe.caller?.conversation == "conv")
    #expect(await probe.caller?.place == caller.place)
    #expect(await probe.origin == .agent)
    // The same task-locals the handler runs under.
    #expect(await probe.boundCaller?.session == "bg-1")
    #expect(await probe.boundOrigin == .agent)
    #expect(await probe.boundHome?.project == "b")

    // The operator's own call is priced in the canvas on screen, and says it is the operator's.
    _ = try await registry.dispatch(name: "seen_call", params: params, origin: .ui,
                                    caller: .test("staging"), confirmation: nil)
    #expect(await probe.origin == .ui)
    #expect(await probe.boundOrigin == .ui)
    #expect(await probe.boundHome?.project == "a")
}

@Test func aConfirmedCallStillAsksTheCallPrice() async throws {
    let registry = pricedRegistry()
    let ran = Ran()
    let probe = PriceProbe()
    await registry.register(pricedAction("revoked_call", .mutate, ran: ran, probe: probe, answer: .block))
    await #expect(throws: ActionError.blockedInProduction("revoked_call")) {
        try await registry.dispatch(name: "revoked_call", params: .null, origin: .agent,
                                    caller: .test("staging"), confirmation: "confirm")
    }
    #expect(await probe.asked == 1)
    #expect(await ran.count == 0)
}

// MARK: - A proposal of the action's own (3c-ii)

@Test func theProposalIsTheActionsOwnAndRunsInTheCallersCanvas() async throws {
    let registry = pricedRegistry()
    let home = LayoutScope(organization: "initech", project: "b", environment: "staging")
    registry.setScopeLookup { caller in caller.session == nil ? nil : home }
    registry.setScreenScope { LayoutScope(organization: "initech", project: "a", environment: "staging") }
    var action = Action(name: "proposing", description: "stub", kind: .mutate, schema: .object([:]),
                        handler: { _ in .object([:]) })
    action.proposal = { params in
        guard case .object(let fields) = params, case .string(let label)? = fields["label"] else { return nil }
        let where_ = "\(ScopeRouting.home?.project ?? "-")/\(ActionRegistry.dispatchCaller?.session ?? "-")"
        return ActionProposal(statement: "click \"\(label)\" \(where_)", ask: .site("staging.initech.dev"))
    }
    await registry.register(action)
    await registry.register(testAction("plain", .mutate))

    let caller = DispatchCaller.test("staging", session: "bg-1", conversation: "conv")
    let proposal = await registry.proposal(
        name: "proposing", params: .object(["label": .string("Save")]), caller: caller)
    #expect(proposal == ActionProposal(statement: "click \"Save\" b/bg-1", ask: .site("staging.initech.dev")))
    #expect(await registry.proposal(name: "plain", params: .null, caller: caller) == nil)
    #expect(await registry.proposal(name: "nope", params: .null, caller: caller) == nil)
}

// MARK: - A handed agent's git writes (ticket noticing, Task 9)

private let handedGitWrites = ["editor_changes_push", "editor_changes_sync", "editor_changes_publish",
                               "editor_changes_merge", "editor_changes_rebase"]

/// A registry holding the five git writes priced as shipped (allow everywhere, Decision 44) and a
/// handed lookup answering `handoff` for conversation `c-handed` only.
private func handedRegistry(_ handoff: PlaceAgentHandoff?) async -> ActionRegistry {
    let r = ActionRegistry(journalDirectory: testScratchRoot.appendingPathComponent(UUID().uuidString), sessionId: "s1")
    for name in handedGitWrites + ["editor_changes_commit"] {
        await r.register(Action(name: name, description: "test", kind: .mutate, audience: .agentReachable,
                                schema: .object([:]), handler: { _ in .object(["ok": .bool(true)]) },
                                price: (production: .allow, otherwise: .allow)))
    }
    r.setHandedLookup { caller in caller.conversation == "c-handed" ? handoff : nil }
    return r
}

private func handOff(mayPush: Bool) -> PlaceAgentHandoff {
    PlaceAgentHandoff(key: "INI-142", pr: 212, thread: "PRRT_1", root: "/p/api", branch: "ini-142-login", mayPush: mayPush)
}

/// Whether an unconfirmed dispatch ran (`true`) or was gated (`false`).
private func runs(_ r: ActionRegistry, _ name: String, origin: ActionOrigin, conversation: String) async throws -> Bool {
    do {
        _ = try await r.dispatch(name: name, params: .object([:]), origin: origin,
                                 caller: .test("staging", session: "s", conversation: conversation), confirmation: nil)
        return true
    } catch ActionError.needsConfirmation {
        return false
    }
}

/// Every git write × May push × handed or not: a handed agent's publish, merge and rebase ask
/// always, its push and sync unless May push; an agent not handed and the operator run them all.
@Test func handedGitWritesMatrix() async throws {
    for mayPush in [false, true] {
        let r = await handedRegistry(handOff(mayPush: mayPush))
        for name in handedGitWrites {
            let pushLike = name == "editor_changes_push" || name == "editor_changes_sync"
            #expect(try await runs(r, name, origin: .agent, conversation: "c-handed") == (pushLike && mayPush),
                    "\(name) mayPush \(mayPush), handed")
            #expect(try await runs(r, name, origin: .agent, conversation: "c-other"), "\(name) mayPush \(mayPush), not handed")
            #expect(try await runs(r, name, origin: .ui, conversation: "c-handed"), "\(name) mayPush \(mayPush), operator")
        }
        #expect(try await runs(r, "editor_changes_commit", origin: .agent, conversation: "c-handed"))
    }
}

/// A handed agent's push parks on the confirmation plane (`ConfirmationBroker`) with a sentence of
/// its own — as do its sync, publish, merge and rebase — and runs once approved; the operator's push
/// runs.
@Test func registryGatesAHandedAgentsPush() async throws {
    let r = await handedRegistry(handOff(mayPush: false))
    let broker = ConfirmationBroker(timeout: .seconds(60))
    let surface = MCPSurface(registry: r, panes: PaneStore(), layout: LayoutStore(), confirmations: broker)
    let statements = [
        "editor_changes_push": "push api's current branch to its upstream",
        "editor_changes_sync": "pull api's upstream, then push its current branch",
        "editor_changes_publish": "publish api's current branch to origin and set it as the upstream",
        "editor_changes_merge": "merge main into api's current branch",
        "editor_changes_rebase": "rebase api's current branch onto main",
    ]
    for name in handedGitWrites {
        let call = JSONRPCMessage(id: .number(1), method: "tools/call", params: .object([
            "name": .string(name),
            "arguments": .object(["root": .string("/p/api"), "branch": .string("main"), "onto": .string("main")])]))
        let reply = Task { await handle(call, surface: surface, caller: { .test("staging", session: "s", conversation: "c-handed") }) }
        let deadline = Date().addingTimeInterval(5)
        while await broker.all().isEmpty, Date() < deadline { await Task.yield() }
        guard let parked = await broker.all().values.first else {
            Issue.record("\(name) did not park: \(String(describing: await reply.value?.error))"); return
        }
        #expect(parked.origin == .agent)
        #expect(parked.statement == statements[name], "\(name)")
        await broker.approve(id: parked.id)
        #expect(await reply.value?.error == nil, "\(name)")
        let outcomes = try await r.journalEntries().filter { $0.action == name }.map(\.outcome)
        #expect(outcomes == ["gated", "ok"], "\(name)")
    }
    #expect(try await runs(r, "editor_changes_push", origin: .ui, conversation: "c-handed"))
}

/// May push on: the handed agent's push runs unasked, its publish still asks.
@Test func mayPushAllowsPushButNotPublish() async throws {
    let r = await handedRegistry(handOff(mayPush: true))
    #expect(try await runs(r, "editor_changes_push", origin: .agent, conversation: "c-handed"))
    #expect(!(try await runs(r, "editor_changes_publish", origin: .agent, conversation: "c-handed")))
}
