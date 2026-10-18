import Foundation
import Testing

@testable import WakilKit

// MARK: - Registration

@Test func dbRunMutationIsRegisteredAsTheFirstMutateAction() async throws {
    let registry = ActionRegistry(journalDirectory: testScratchRoot
        .appendingPathComponent("wakil-test-\(UUID().uuidString)"), sessionId: "t")
    await registerStandardActions(into: registry, context: nil, panes: PaneStore(), db: nil, resumes: ResumeBroker())
    // **The api actions are registered here too, and they were not
    // before.** This assertion says "it is the ONLY `.mutate` action",
    // and a registry built from `registerStandardActions` alone cannot
    // see `api_send` — so the pin would have stayed green through 2c-iv
    // shipping a second one, which is the drift it exists to catch.
    await registerApiActions(into: registry, panes: PaneStore())

    let all = await registry.all()
    guard let mutation = all.first(where: { $0.name == "db_run_mutation" }) else {
        Issue.record("db_run_mutation must be registered; got \(all.map(\.name))")
        return
    }
    #expect(mutation.kind == .mutate)

    // **Two, as of 2c-iv, and the second one is deliberate.** `api_send`
    // is Phase 2's exit clause — "production costs a typed confirmation
    // that staging does not" — and Decision 25's first shipped price: the
    // first action anywhere to declare its own `(production: .gate,
    // otherwise: .allow)` rather than take the default `(.block, .gate)`.
    // A third landing here is the place to decide deliberately again.
    let mutations = all.filter { $0.kind == .mutate }.map(\.name).sorted()
    #expect(mutations == ["api_send", "db_run_mutation"])
}

@Test func dbRunMutationRequiresAStatement() async throws {
    let registry = ActionRegistry(journalDirectory: testScratchRoot
        .appendingPathComponent("wakil-test-\(UUID().uuidString)"), sessionId: "t")
    await registerStandardActions(into: registry, context: nil, panes: PaneStore(), db: nil, resumes: ResumeBroker())

    let all = await registry.all()
    let mutation = all.first { $0.name == "db_run_mutation" }
    guard case .object(let schema)? = mutation?.schema,
          case .array(let required)? = schema["required"]
    else {
        Issue.record("db_run_mutation's schema must declare required params")
        return
    }
    #expect(required == [.string("statement")])
}

// MARK: - The gate now has a live subject

@Test func theFirstMutationIsBlockedInProductionAndGatedElsewhere() {
    for origin in [ActionOrigin.ui, .agent, .debug] {
        #expect(
            writeGate(environment: "production", kind: .mutate, origin: origin, targetEnvironment: nil, production: .undeclared)
                == .block)
        #expect(
            writeGate(environment: "staging", kind: .mutate, origin: origin, targetEnvironment: nil, production: .undeclared)
                == .gate)
    }
}

// MARK: - Dispatch reaches the gate, not the handler

@Test func dispatchingTheMutationInProductionJournalsBlockedAndNeverRunsTheHandler() async throws {
    let dir = testScratchRoot
        .appendingPathComponent("wakil-test-\(UUID().uuidString)")
    let registry = ActionRegistry(journalDirectory: dir, sessionId: "t")
    // db is nil, so if the handler ever ran it would throw
    // StandardActionError.missingClient — a different error than the one
    // expected below, which is how this test distinguishes "the gate
    // stopped it" from "it failed for another reason".
    await registerStandardActions(into: registry, context: nil, panes: PaneStore(), db: nil, resumes: ResumeBroker())

    await #expect(throws: ActionError.blockedInProduction("db_run_mutation")) {
        _ = try await registry.dispatch(
            name: "db_run_mutation",
            params: .object(["statement": .string("DELETE FROM t WHERE id=1")]),
            origin: .agent, caller: .test("production"), confirmation: "confirm")
    }

    let entries = try await registry.journalEntries()
    #expect(entries.last?.outcome == "blocked")
}

@Test func dispatchingTheMutationWithoutConfirmationJournalsGated() async throws {
    let dir = testScratchRoot
        .appendingPathComponent("wakil-test-\(UUID().uuidString)")
    let registry = ActionRegistry(journalDirectory: dir, sessionId: "t")
    await registerStandardActions(into: registry, context: nil, panes: PaneStore(), db: nil, resumes: ResumeBroker())

    await #expect(throws: ActionError.needsConfirmation("db_run_mutation")) {
        _ = try await registry.dispatch(
            name: "db_run_mutation",
            params: .object(["statement": .string("DELETE FROM t WHERE id=1")]),
            origin: .agent, caller: .test("staging"), confirmation: nil)
    }

    let entries = try await registry.journalEntries()
    #expect(entries.last?.outcome == "gated")
}

// MARK: - A mutation is not bounded by a read's reply budget

// Finding 1 of the whole-branch review. `MCPClient.sendRequest` used to
// apply one hard-coded 10-second timeout to every request, and
// `db_run_mutation` reached `wakil-db` through it — so a confirmed
// `DELETE` on a large table was abandoned at 10s, reported as a failure and
// journalled `"error"` while the statement went on to commit.
//
// The numbers themselves are judgement calls and this test does not pin
// them. What it pins is the property the bug violated: the write budget is
// not the read budget, and it is the larger of the two.
@Test func aMutationGetsALongerReplyBudgetThanARead() {
    #expect(MCPClient.mutationReplyTimeout > MCPClient.readReplyTimeout)
    // Neither is unbounded: an unbounded wait hangs the window, since
    // `WindowModel`'s dispatches await these calls on the main actor.
    #expect(MCPClient.readReplyTimeout > 0)
    #expect(MCPClient.mutationReplyTimeout.isFinite)
}

// The other half of Finding 1: a longer budget makes a timeout rarer, not
// impossible, so what Wakil SAYS when one happens has to be true. Wakil
// stopped waiting; it did not stop the statement.
//
// `mutationCallFailure` is a free function so the translation has one
// definition; this test pins it directly rather than through the handler.
// `aTimedOutMutationIsJournalledUncertainBesideItsError` below drives the
// same translation through the real `db_run_mutation` handler over a
// `RecordingToolCaller`, now that `ToolCaller` makes that driveable too.
@Test func aMutationTimeoutIsReportedAsUnknownRatherThanAsAFailure() throws {
    let translated = mutationCallFailure(
        MCPClientError.timeout(method: "tools/call"),
        action: "db_run_mutation",
        statement: "DELETE FROM orders WHERE created_at < '2020-01-01'",
        seconds: 300)

    let error = try #require(translated as? StandardActionError)
    guard case .mutationFateUnknown = error else {
        Issue.record("a mutation timeout must become .mutationFateUnknown, got \(error)")
        return
    }

    // The wording is the fix, so the wording is what is asserted. An
    // operator reading this must not come away believing nothing ran and
    // re-confirming — which for an INSERT would apply it twice.
    let text = error.description
    #expect(text.contains("MAY STILL BE RUNNING"))
    #expect(text.contains("MAY ALREADY HAVE COMMITTED"))
    #expect(text.contains("NOT a report that nothing happened"))
    #expect(text.contains("Check the database"))
    // The statement is echoed, so the operator knows what to go and check.
    #expect(text.contains("DELETE FROM orders"))
}

// Every other failure of the `mutate` call is a fact about something that
// did NOT happen — the server said so — so there is nothing to reinterpret
// and nothing may be reinterpreted. Reporting a refused statement as
// "it may have committed" would be its own lie, in the other direction.
@Test func anOrdinaryMutationFailurePassesThroughUnchanged() throws {
    let original = StandardActionError.serverError(
        action: "db_run_mutation", message: "only INSERT/UPDATE/DELETE statements are allowed")
    let translated = mutationCallFailure(
        original, action: "db_run_mutation", statement: "DROP TABLE t", seconds: 300)
    #expect(translated as? StandardActionError == original)

    let transport = MCPClientError.notRunning
    let passed = mutationCallFailure(
        transport, action: "db_run_mutation", statement: "DELETE FROM t WHERE id=1", seconds: 300)
    guard case MCPClientError.notRunning = passed else {
        Issue.record("a non-timeout MCPClientError must pass through, got \(passed)")
        return
    }
}

// The journal is the only record of what Wakil did, and `dispatch` — which
// is deliberately indifferent to which error a handler threw — writes
// `"error"` for this one like any other. `"uncertain"` is written beside it
// so the pair cannot be read as "the mutation did not run".
@Test func aMutationOfUnknownFateIsJournalledUncertainBesideTheError() async throws {
    let dir = testScratchRoot
        .appendingPathComponent("wakil-test-\(UUID().uuidString)")
    let registry = ActionRegistry(journalDirectory: dir, sessionId: "t")
    let params = JSONValue.object(["statement": .string("DELETE FROM t WHERE id=1")])

    // A handler that fails the way a timed-out `mutate` call fails, so the
    // ordering this test cares about — `dispatch`'s own `"error"` first,
    // then `"uncertain"` — is produced by the real code path rather than
    // by two hand-written appends.
    await registry.register(Action(
        name: "db_run_mutation", description: "test", kind: .mutate,
        schema: .object(["type": .string("object"), "properties": .object([:])]),
        handler: { _ in
            throw mutationCallFailure(
                MCPClientError.timeout(method: "tools/call"),
                action: "db_run_mutation", statement: "DELETE FROM t WHERE id=1", seconds: 300)
        }))

    let lines = await runDebugScript(
        [#"{"action":"db_run_mutation","params":{"statement":"DELETE FROM t WHERE id=1"},"confirmation":"confirm"}"#],
        registry: registry, environment: "staging")
    #expect(lines.first?.contains("MAY ALREADY HAVE COMMITTED") == true)

    let entries = try await registry.journalEntries()
    // Forced, not chosen: `dispatch` writes `"error"` synchronously as the
    // handler throws. Only after `dispatch` itself has returned (by
    // throwing) does the caller reach its own `catch` and append
    // `"uncertain"` — so `"error"` cannot help but be written first.
    #expect(entries.map(\.outcome) == ["error", "uncertain"])
    #expect(entries.allSatisfy { $0.action == "db_run_mutation" })
    #expect(entries.allSatisfy { $0.origin == .debug })
    #expect(entries.first?.params == params)
}

/// A mutation whose reply never arrives is NOT a failed mutation: the
/// statement may well have run. The pair of journal lines that says so —
/// `dispatch`'s own `"error"`, then `"uncertain"` from the caller's catch
/// — could not be driven before `ToolCaller`, because it needs a client
/// that times out on demand. Unlike
/// `aMutationOfUnknownFateIsJournalledUncertainBesideTheError` above, this
/// one drives the real `db_run_mutation` handler registered by
/// `registerStandardActions` — through `runDebugScriptReportingFailures`,
/// not `dispatch` directly, since `dispatch` alone never writes
/// `"uncertain"`.
@Test func aTimedOutMutationIsJournalledUncertainBesideItsError() async throws {
    let db = RecordingToolCaller(reply: { _, _ in
        throw MCPClientError.timeout(method: "tools/call")
    })
    let dir = testScratchRoot.appendingPathComponent(UUID().uuidString)
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

// Nothing else may earn an `"uncertain"` line. A gated refusal, a block, a
// constraint violation — each of those is a known outcome, and blurring one
// into "we don't know" would make the honest line meaningless.
@Test func anOrdinaryHandlerFailureJournalsErrorAloneWithNoUncertainLine() async throws {
    let dir = testScratchRoot
        .appendingPathComponent("wakil-test-\(UUID().uuidString)")
    let registry = ActionRegistry(journalDirectory: dir, sessionId: "t")
    await registry.register(Action(
        name: "db_run_mutation", description: "test", kind: .mutate,
        schema: .object(["type": .string("object"), "properties": .object([:])]),
        handler: { _ in
            throw StandardActionError.serverError(action: "db_run_mutation", message: "refused")
        }))

    _ = await runDebugScript(
        [#"{"action":"db_run_mutation","params":{"statement":"DELETE FROM t"},"confirmation":"confirm"}"#],
        registry: registry, environment: "staging")

    let entries = try await registry.journalEntries()
    #expect(entries.map(\.outcome) == ["error"])
}

// MARK: - mutationAffectsEveryRow agrees with its Go counterpart

// Ported verbatim from `internal/wakilcore/mutation_test.go`'s
// `TestMutationAffectsEveryRow`, case for case, so the two implementations
// cannot drift apart in silence again — the finding this closes was
// exactly that silent drift: Go strips SQL comments before scanning for a
// `WHERE` and the Swift mirror did not, so `DELETE FROM t -- WHERE id=1`
// read as `false` here and `true` there.
@Test func mutationAffectsEveryRowAgreesWithTheGoFixtureTable() {
    let cases: [(sql: String, want: Bool)] = [
        ("DELETE FROM t", true),
        ("UPDATE t SET x=1", true),
        ("delete from t", true),
        ("DELETE FROM t WHERE id=1", false),
        ("UPDATE t SET x=1 WHERE id=1", false),
        ("update t set x=1 where id=1", false),
        // INSERT never affects existing rows, so it is never flagged.
        ("INSERT INTO t VALUES (1)", false),
        // A WHERE surviving only inside a COMMENT does not suppress the
        // warning, because stripSQLComments removes it first.
        ("DELETE FROM t -- WHERE id=1", true),
        ("DELETE FROM t /* WHERE id=1 */", true),
        // A WHERE inside a STRING LITERAL does suppress it, because
        // stripSQLComments preserves literals verbatim and this is a
        // regexp scan, not a parser. That is an UNDER-warning — the
        // operator is shown the full statement regardless — and
        // under-warning is the safe direction for an advisory. Pinned
        // here, exactly as it is in Go, so the weakness is a recorded
        // property rather than a surprise.
        ("UPDATE t SET note='WHERE'", false),
    ]
    for c in cases {
        #expect(mutationAffectsEveryRow(c.sql) == c.want, "mutationAffectsEveryRow(\(c.sql.debugDescription))")
    }
}
