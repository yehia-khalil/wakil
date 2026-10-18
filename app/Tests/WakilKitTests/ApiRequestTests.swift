import Foundation
import Testing
@testable import WakilKit

/// The read send — `api_request` (#193), Phase 2 of the 2c-iv plan.
///
/// **The plan's table of which state carries which key is enforced by the
/// TYPE rather than by a convention.** It says the absence of keys is
/// load-bearing: a refusal must not carry a status, a timing or a size,
/// and a transport failure must not carry a status, headers or a body.
/// Written as one struct with optional fields, every one of those is a
/// rule somebody has to keep; written as cases with only the fields each
/// may hold, a refusal that carried a status would not compile.

// MARK: - Fixtures

/// A draft with a hole nothing has filled — the request cannot be
/// resolved, so it cannot be sent.
private func draftWithAnUnfilledHole() -> ApiDraft {
    var draft = ApiDraft.empty
    draft.entry = "billing"
    draft.method = "GET"
    draft.path = [.literal("/bookings/"), .slot("id")]
    return draft
}

private func sendableDraft() -> ApiDraft {
    var draft = ApiDraft.empty
    draft.entry = "billing"
    draft.method = "GET"
    draft.path = [.literal("/bookings/41")]
    return draft
}

/// A `wakil-http` stand-in that answers every send with one reply.
private struct StubHTTP: ToolCaller, Sendable {
    let reply: JSONValue
    func callTool(
        name: String, arguments: JSONValue, timeout: TimeInterval
    ) async throws -> JSONValue { reply }
}

/// One that fails the way a transport does — nothing came back at all.
private struct FailingHTTP: ToolCaller, Sendable {
    struct Dead: Error {}
    func callTool(
        name: String, arguments: JSONValue, timeout: TimeInterval
    ) async throws -> JSONValue { throw Dead() }
}

// MARK: - The refusal is not a response

@Test("A refusal draws no status, no timing and no size, and clears nothing")
func aRefusalIsNotAResponse() async throws {
    let before = draftWithAnUnfilledHole()

    let outcome = await apiRequest(draft: before, sources: [:], environment: "staging", http: nil)

    guard case .refusal(let refusal) = outcome.response else {
        Issue.record("an unresolvable draft did not refuse: \(outcome.response.state)"); return
    }
    #expect(!refusal.failures.isEmpty)
    // The three the plan's table forbids, asserted through the accessors a
    // reader would use.
    #expect(outcome.response.status == nil)
    #expect(outcome.response.durationMs == nil)
    #expect(outcome.response.byteCount == nil)
    // A refused send clears nothing — the draft still holds the only copy
    // of what the operator meant.
    #expect(outcome.draft == before)
}

@Test("A refusal names every failure at once, never only the first")
func aRefusalIsAggregated() async throws {
    var draft = draftWithAnUnfilledHole()
    draft.method = "POST"  // B1: a read's body is not sent, so only a mutation's holes refuse
    draft.query = [ApiQueryRow(name: "ref", value: [.slot("reference")])]
    draft.body = [.slot("guest")]

    let outcome = await apiRequest(draft: draft, sources: [:], environment: "staging", http: nil)
    guard case .refusal(let refusal) = outcome.response else {
        Issue.record("no refusal"); return
    }
    // Three holes, three failures — fixing the request is one pass rather
    // than three sends.
    #expect(refusal.failures.count == 3)
    #expect(Set(refusal.failures.map { $0.region?.label }) == ["Path", "Query · ref", "Body"] as Set<String?>)
}

@Test("B3: a tool's own refusal names no region")
func aToolRefusalNamesNoRegion() {
    let reply: JSONValue = .object([
        "isError": .bool(true),
        "content": .array([.object(["type": .string("text"), "text": .string("validating…")])]),
    ])
    guard case .refusal(let refusal) = apiResponse(
        from: reply, environment: "staging", started: Date(), url: "")
    else { Issue.record("not a refusal"); return }
    #expect(refusal.failures[0].region == nil)
    #expect(apiFailureLine(refusal.failures[0]) == "validating…")
    #expect(apiFailureLine(ApiSendFailure(region: .body, message: "m")) == "Body · m")
    #expect(apiResponseJSON(.refusal(refusal)) == .object([
        "state": .string("refusal"),
        "failures": .array([.object(["message": .string("validating…")])]),
    ]))
}

// MARK: - The send

@Test("A GET that resolves is sent, and the reply lands as the response")
func aResolvedGetIsSent() async throws {
    // **Exactly what `HTTPResult` encodes, and nothing else.** This stub
    // used to answer with `url`, `millis` and `bytes` — three fields the
    // real result does not have — so the assertions below were pinned to
    // a reply nothing sends. `status` is a Go `int` and therefore an
    // integer on the wire, not a `.number`.
    let http = StubHTTP(reply: .object([
        "structuredContent": .object([
            "status": .integer(200),
            "headers": .object(["content-type": .string("application/json")]),
            "body": .string("{\"id\":41}"),
            "truncated": .bool(false),
        ]),
    ]))

    let outcome = await apiRequest(
        draft: sendableDraft(), sources: [:], environment: "staging", http: http,
        origin: "https://billing.example.com")

    guard case .ok(let reply) = outcome.response else {
        Issue.record("a resolvable GET did not send: \(outcome.response.state)"); return
    }
    #expect(reply.status == 200)
    // Composed from what was sent, because the reply carries no URL.
    #expect(reply.url == "https://billing.example.com/bookings/41")
    #expect(reply.body == "{\"id\":41}")
    // Wakil's own measurement — the tool reports no timing — so this is
    // asserted as "a duration was measured" rather than as a number the
    // server sent.
    #expect(reply.durationMs >= 0)
    #expect(reply.byteCount == "{\"id\":41}".utf8.count)
    // **Every record carries the environment it ran against**, so a
    // staging reply and a production one are never confusable after the
    // fact.
    #expect(reply.environment == "staging")
    #expect(outcome.response.status == 200)
}

@Test("A transport failure draws its stage and reason, and no status, headers or body")
func aTransportFailureCarriesNoReply() async throws {
    let outcome = await apiRequest(
        draft: sendableDraft(), sources: [:], environment: "staging", http: FailingHTTP())

    guard case .transport(let failure) = outcome.response else {
        Issue.record("a dead transport did not report one: \(outcome.response.state)"); return
    }
    #expect(!failure.reason.isEmpty)
    #expect(failure.environment == "staging")
    // The three the table forbids — and they are absent structurally, not
    // by being set to nil somewhere.
    #expect(outcome.response.status == nil)
    #expect(outcome.response.byteCount == nil)
}

@Test("A send with no http client at all is fate-unknown, not a refusal and not a failure")
func aSendWithNowhereToGoIsFateUnknown() async throws {
    // Resolvable, so not a refusal; but the window holds no `wakil-http`,
    // so nothing can say whether anything left. That is a third thing.
    let outcome = await apiRequest(
        draft: sendableDraft(), sources: [:], environment: "staging", http: nil)

    guard case .unknown(let record) = outcome.response else {
        Issue.record("expected fate-unknown, got \(outcome.response.state)"); return
    }
    #expect(record.environment == "staging")
    #expect(!record.reason.isEmpty)
}

// MARK: - The states are distinct, and the wire says which

@Test("Every state names itself on the wire, and no two share a name")
func theStatesAreDistinctOnTheWire() {
    let states: [ApiResponseSnapshot] = [
        .none,
        .ok(ApiResponseOK(
            status: 200, url: "u", environment: "e", headers: [:], body: "",
            durationMs: 1, byteCount: 0, truncated: false)),
        .transport(ApiTransportFailure(stage: "connect", waitedMs: 1, reason: "r", environment: "e")),
        .unknown(ApiFateUnknown(reason: "r", environment: "e")),
        .refusal(ApiSendRefusal(failures: [])),
        .cleared(environment: "staging"),
    ]
    let names = states.map(\.state)
    #expect(Set(names).count == names.count)
    #expect(names == ["none", "ok", "transport", "unknown", "refusal", "cleared"])
}

@Test("Only ok carries a status, a timing and a size")
func onlyOkCarriesTheReplysNumbers() {
    let notOk: [ApiResponseSnapshot] = [
        .none,
        .transport(ApiTransportFailure(stage: "connect", waitedMs: 9, reason: "r", environment: "e")),
        .unknown(ApiFateUnknown(reason: "r", environment: "e")),
        .refusal(ApiSendRefusal(failures: [])),
        .cleared(environment: "staging"),
    ]
    for state in notOk {
        #expect(state.status == nil)
        #expect(state.durationMs == nil)
        #expect(state.byteCount == nil)
    }
}

// MARK: - Through the registry

@Test("api_request refuses a mutation method and names the action that owns it")
func apiRequestRefusesAMutationMethod() async throws {
    let (registry, panes, _, paneId) = try await requestFixture()
    var draft = ApiDraft.empty
    draft.entry = "billing"
    draft.method = "POST"
    draft.path = [.literal("/bookings")]
    await panes.setApiDraft(paneId: paneId, draft: draft)

    await #expect(throws: (any Error).self) {
        _ = try await registry.dispatch(
            name: "api_request", params: .object(["pane": .string(paneId)]),
            origin: .agent, caller: .test("staging"), confirmation: nil)
    }
    // Nothing was sent, so nothing was recorded.
    #expect(await panes.apiResponse(paneId: paneId).state == "none")
}

@Test("api_request is .read — it reaches no gate, in production or out of it")
func apiRequestIsNeverGated() async throws {
    let (registry, _, _, _) = try await requestFixture()
    let descriptor = try #require(await registry.all().first { $0.name == "api_request" })
    // A GET costs nothing, in any environment. `.read` is what says so,
    // and it is why the send is two actions rather than one.
    #expect(descriptor.kind == .read)
}

@Test("api_request records a refusal on the pane without clearing the draft")
func apiRequestRecordsTheRefusal() async throws {
    let (registry, panes, _, paneId) = try await requestFixture()
    var draft = ApiDraft.empty
    draft.entry = "billing"
    draft.method = "GET"
    draft.path = [.literal("/bookings/"), .slot("id")]
    await panes.setApiDraft(paneId: paneId, draft: draft)

    let result = try await registry.dispatch(
        name: "api_request", params: .object(["pane": .string(paneId)]),
        origin: .agent, caller: .test("staging"), confirmation: nil)

    guard case .object(let fields) = result else { Issue.record("no object"); return }
    #expect(fields["state"] == .string("refusal"))
    #expect(fields["status"] == .null)
    // The draft is untouched — it holds the only copy of what was meant.
    #expect(await panes.apiDraft(paneId: paneId) == draft)
}

private func requestFixture() async throws -> (ActionRegistry, PaneStore, LayoutStore, String) {
    let registry = ActionRegistry(
        journalDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("api-request-\(UUID().uuidString)"),
        sessionId: "t")
    let panes = PaneStore()
    let layout = LayoutStore()
    let http = StubHTTP(reply: .object([
        "structuredContent": .object([
            "apis": .array([
                .object([
                    "name": .string("billing"),
                    "baseUrl": .string("https://billing.example.com"),
                    "authenticated": .bool(true),
                ])
            ]),
        ]),
    ]))
    await registerApiActions(
        into: registry, panes: panes, layout: layout, http: http,
        activeContext: { ("initech", "proj", "staging", "/tmp") })
    let opened = try await registry.dispatch(
        name: "api_open", params: .object([:]), origin: .agent, caller: .test("staging"),
        confirmation: nil)
    guard case .object(let fields) = opened, case .string(let paneId)? = fields["pane"] else {
        throw NoPane()
    }
    return (registry, panes, layout, paneId)
}

private struct NoPane: Error {}

// MARK: - Task 6: the environment switch

@Test("A switch clears the response, keeps the draft, and sends nothing")
func aSwitchClearsOnlyThePresent() async throws {
    let panes = PaneStore()
    await panes.openApi(
        paneId: "api1", entry: "billing", environment: "staging", origin: nil,
        credentialed: true)
    var draft = ApiDraft.empty
    draft.entry = "billing"
    draft.method = "GET"
    draft.path = [.literal("/bookings/41")]
    await panes.setApiDraft(paneId: "api1", draft: draft)
    await panes.setApiResponse(paneId: "api1", response: .ok(ApiResponseOK(
        status: 200, url: "https://billing-staging.example.com/bookings/41",
        environment: "staging", headers: [:], body: "{}", durationMs: 12, byteCount: 2,
        truncated: false)))

    await panes.clearApiResponses(to: "production")

    // The reply on screen described the environment we just left, so it
    // goes; it is replaced by a state that says why rather than by
    // `.none`, which would read as a pane that had never sent.
    guard case .cleared(let environment) = await panes.apiResponse(paneId: "api1") else {
        Issue.record("the response was not cleared"); return
    }
    #expect(environment == "production")
    // **The draft is kept**, and nothing was sent. A switch that re-sent
    // would put an unattended request on the wire in the new environment.
    #expect(await panes.apiDraft(paneId: "api1") == draft)
}

@Test("A switch clears a pane that has never sent to nothing new")
func aSwitchLeavesAnUnsentPaneAlone() async throws {
    let panes = PaneStore()
    await panes.openApi(
        paneId: "api1", entry: "billing", environment: "staging", origin: nil, credentialed: true)

    await panes.clearApiResponses(to: "production")

    // A pane that has sent nothing has nothing to clear, and saying
    // "cleared" about it would invent a history it does not have.
    #expect(await panes.apiResponse(paneId: "api1").state == "none")
}

@Test("A switch reaches every api pane and leaves other pane kinds alone")
func aSwitchReachesEveryApiPane() async throws {
    let panes = PaneStore()
    for id in ["api1", "api2"] {
        await panes.openApi(
            paneId: id, entry: "billing", environment: "staging", origin: nil, credentialed: true)
        await panes.setApiResponse(paneId: id, response: .unknown(ApiFateUnknown(
            reason: "r", environment: "staging")))
    }
    await panes.setRows(
        paneId: "db1", columns: ["id"], columnTypes: ["INTEGER"], columnTypesInferred: false,
        rows: [[.integer(1)]], millis: 1, truncated: false, pageable: false, offset: 0,
        sort: [], listsTables: false, editable: nil)

    await panes.clearApiResponses(to: "production")

    #expect(await panes.apiResponse(paneId: "api1").state == "cleared")
    #expect(await panes.apiResponse(paneId: "api2").state == "cleared")
    // The db pane is untouched — it is the switch's own refetch that
    // replaces its rows, not this.
    #expect(await panes.sourcePane(paneId: "db1")?.rows.count == 1)
}
