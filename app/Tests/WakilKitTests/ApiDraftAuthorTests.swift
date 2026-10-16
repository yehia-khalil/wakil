import Foundation
import Testing
@testable import WakilKit

/// **One draft, one author** (#191, Decision 27, amended 2026-10-03 by
/// Amendment 9a) — an agent's write to a draft request is refused whole
/// while the operator's cursor is in a field it names.
///
/// Asserted at two seams, which is what the ticket asks for: the policy
/// function directly, because the rule lives in one function rather than
/// spread across a handler; and `ActionRegistry.dispatch`, because what a
/// caller can observe is a dispatched action's result and a published
/// snapshot.

// MARK: - The policy function

@Test func anAgentWriteNamingTheFieldTheCursorIsInCollidesWithIt() {
    #expect(apiDraftCollisions(origin: .agent, writing: [.path], focused: [.path]) == [.path])
}

@Test func theOperatorsOwnWriteLandsInTheFieldTheyAreIn() {
    #expect(apiDraftCollisions(origin: .ui, writing: [.path, .body], focused: [.path, .body]).isEmpty)
}

@Test func aDebugWriteContendsLikeAnAgent() {
    // `--dispatch` contends like an agent. It runs with no window and so
    // with no focus, which makes the branch unreachable there rather than
    // wrong; where it were reachable, a scripted write is not the hand
    // this protects.
    #expect(apiDraftCollisions(origin: .debug, writing: [.path], focused: [.path]) == [.path])
}

@Test func thePathBoxMarksThePathAndTheWholeQueryRegion() {
    // 8a's view: the path box shows the query, so an agent may write neither under the cursor.
    let marks = apiFocusMarks(.path)
    #expect(marks == [.path, apiQueryRegionMark])
    #expect(apiDraftCollisions(origin: .agent, writing: [.query], focused: marks) == [apiQueryRegionMark])
    #expect(apiDraftCollisions(origin: .agent, writing: [.path, .query], focused: marks).map(\.label)
        == ["Path", "Query"])
}

@Test func anyOtherBoxMarksOnlyItsOwnField() {
    #expect(apiFocusMarks(.body) == [.body])
    #expect(apiFocusMarks(.query("expand")) == [.query("expand")])
    #expect(apiFocusMarks(.header("x-tenant-id")) == [.header("x-tenant-id")])
    #expect(apiFocusMarks(.contentType) == [.contentType])
}

@Test func everyCollidingFieldIsNamedInOneAnswerInWireOrder() {
    // Aggregated, never field by field: fixing the request is one pass
    // rather than four calls. Wire order with the row name breaking the
    // tie, so the same collision reads the same way on every call — a
    // set's own order would not.
    let focused: Set<ApiDraftField> = [
        .body, .query("region"), .query("expand"), .path, .header("x-tenant-id"),
    ]
    #expect(apiDraftCollisions(
        origin: .agent, writing: [.path, .query, .headers, .body], focused: focused)
        == [.path, .query("expand"), .query("region"), .header("x-tenant-id"), .body])
}

@Test func aWriteNamingOnlyFieldsTheCursorIsNotInLands() {
    #expect(apiDraftCollisions(origin: .agent, writing: [.method, .body], focused: [.path]).isEmpty)
}

@Test func aWriteThatNamesOnlyTheEntryCollidesWithNothing() {
    // `entry` is not an `ApiWriteKey` at all: re-pointing the draft keeps
    // every region and overwrites nothing anyone can be typing in. So the
    // keys such a call resolves to are none.
    #expect(apiDraftCollisions(origin: .agent, writing: [], focused: [.path, .body]).isEmpty)
}

// MARK: - Where the marks live

@Test func theStoreHoldsTheFocusAndALateReleaseNeverClearsANewerOne() async {
    let panes = PaneStore()
    await panes.setApiFocus(paneId: "api-1", fields: [.body], generation: 2)
    // A release from an earlier focus arrives late, after the cursor moved on.
    await panes.setApiFocus(paneId: "api-1", fields: [], generation: 1)
    #expect(await panes.apiFocus(paneId: "api-1") == [.body])
    await panes.setApiFocus(paneId: "api-1", fields: [], generation: 3)
    #expect(await panes.apiFocus(paneId: "api-1").isEmpty)
}

@Test func aFocusArrivingIsAddedToWhatTheChainStillHolds() async {
    // Preflight F6: moving from the path to the body, the body's focus-in is noted at once, and
    // the path stays marked until the chain lands the body's own setting behind the path's flush.
    let panes = PaneStore()
    await panes.setApiFocus(paneId: "api-1", fields: apiFocusMarks(.path), generation: 1)
    await panes.addApiFocus(paneId: "api-1", fields: [.body], generation: 2)
    #expect(await panes.apiFocus(paneId: "api-1") == [.path, apiQueryRegionMark, .body])
    await panes.setApiFocus(paneId: "api-1", fields: [.body], generation: 2)
    #expect(await panes.apiFocus(paneId: "api-1") == [.body])
}

@Test func anArrivalNewerThanTheChainsSettingSurvivesIt() async {
    // The cursor went on to a third field before the chain caught up: the chain setting the
    // second field (2) does not drop the third (3), which only its own setting replaces.
    let panes = PaneStore()
    await panes.addApiFocus(paneId: "api-1", fields: [.body], generation: 2)
    await panes.addApiFocus(paneId: "api-1", fields: [.contentType], generation: 3)
    await panes.setApiFocus(paneId: "api-1", fields: [.body], generation: 2)
    #expect(await panes.apiFocus(paneId: "api-1") == [.body, .contentType])
    await panes.setApiFocus(paneId: "api-1", fields: [.contentType], generation: 3)
    #expect(await panes.apiFocus(paneId: "api-1") == [.contentType])
}

@Test func anArrivalOlderThanTheChainsSettingIsIgnored() async {
    // The immediate note is a Task and may arrive after the chain has already settled past it.
    let panes = PaneStore()
    await panes.setApiFocus(paneId: "api-1", fields: [], generation: 3)
    await panes.addApiFocus(paneId: "api-1", fields: [.body], generation: 2)
    #expect(await panes.apiFocus(paneId: "api-1").isEmpty)
}

// MARK: - Which box holds the cursor (preflight F5)

private let focusRequest = ApiRequestSnapshot(
    method: "GET", origin: nil, path: [.literal("/v1")], query: [], headers: [], body: [])

@Test func theFocusIsKeyedByTheBoxNotTheField() {
    // The path boxes around a hole share one field. Moving from one to the other with the
    // second's focus-in first, the first's late focus-out must not release the field.
    var focus = ApiFocusTracker()
    #expect(focus.took(ApiFieldRow(.path), identifier: "api.path.part.0", request: focusRequest)
        == .arrived(fields: apiFocusMarks(.path), left: nil))
    let first = ApiFocusedField(box: ApiFieldRow(.path), request: focusRequest)
    #expect(focus.took(ApiFieldRow(.path), identifier: "api.path.part.2", request: focusRequest)
        == .arrived(fields: apiFocusMarks(.path), left: first))
    #expect(focus.lost(identifier: "api.path.part.0") == .ignored)
    #expect(focus.focused?.box == ApiFieldRow(.path))
    #expect(focus.lost(identifier: "api.path.part.2") == .released(left: first))
    #expect(focus.focused == nil)
}

@Test func aFocusOutInTheUsualOrderReleasesAndTheNextFocusInArrivesClean() {
    var focus = ApiFocusTracker()
    _ = focus.took(ApiFieldRow(.path), identifier: "api.path", request: focusRequest)
    let path = ApiFocusedField(box: ApiFieldRow(.path), request: focusRequest)
    #expect(focus.lost(identifier: "api.path") == .released(left: path))
    #expect(focus.took(ApiFieldRow(.body), identifier: "api.body", request: focusRequest)
        == .arrived(fields: [.body], left: nil))
}

@Test func aRepeatedFocusInOfTheSameBoxChangesNothing() {
    var focus = ApiFocusTracker()
    _ = focus.took(ApiFieldRow(.body), identifier: "api.body", request: focusRequest)
    #expect(focus.took(ApiFieldRow(.body), identifier: "api.body", request: focusRequest) == .ignored)
    #expect(focus.identifier == "api.body")
}

// MARK: - The Escape baseline, rebased on the chain (plan B preflight P7)

private let rebasedRequest = ApiRequestSnapshot(
    method: "GET", origin: nil, path: [.literal("/v1")],
    query: [ApiQueryRow(name: "page", value: [.literal("5")])], headers: [], body: [])

@Test("P7: a rebase for the box holding the cursor replaces its Escape baseline")
func aRebaseForTheFocusedBoxReplacesTheBaseline() {
    var focus = ApiFocusTracker()
    _ = focus.took(ApiFieldRow(.path), identifier: "api.path", request: focusRequest)
    let took = focus.rebased(identifier: "api.path", request: rebasedRequest)
    #expect(took)
    #expect(focus.focused == ApiFocusedField(box: ApiFieldRow(.path), request: rebasedRequest))
    #expect(focus.identifier == "api.path")
}

@Test("P7: a rebase after the cursor moved on or left does nothing")
func aRebaseAfterTheCursorMovedDoesNothing() {
    var focus = ApiFocusTracker()
    _ = focus.took(ApiFieldRow(.path), identifier: "api.path", request: focusRequest)
    _ = focus.took(ApiFieldRow(.body), identifier: "api.body", request: focusRequest)
    // The path box's rebase comes to its turn after the cursor went to the body.
    let took = focus.rebased(identifier: "api.path", request: rebasedRequest)
    #expect(!took)
    #expect(focus.focused == ApiFocusedField(box: ApiFieldRow(.body), request: focusRequest))
    _ = focus.lost(identifier: "api.body")
    let tookBody = focus.rebased(identifier: "api.body", request: rebasedRequest)
    #expect(!tookBody)
    #expect(focus.focused == nil)
}

@Test("P7: a repeated focus-in keeps the rebased baseline")
func aRepeatedFocusInKeepsTheRebasedBaseline() {
    var focus = ApiFocusTracker()
    _ = focus.took(ApiFieldRow(.path), identifier: "api.path", request: focusRequest)
    _ = focus.rebased(identifier: "api.path", request: rebasedRequest)
    #expect(focus.took(ApiFieldRow(.path), identifier: "api.path", request: focusRequest) == .ignored)
    #expect(focus.focused?.request == rebasedRequest)
}

@Test func aFocusOutWithNothingFocusedIsIgnored() {
    var focus = ApiFocusTracker()
    #expect(focus.lost(identifier: "api.body") == .ignored)
    #expect(focus.identifier == nil)
}

// MARK: - Through the action

// The fixture is a copy of `ApiSetRequestTests`' own, for the reason that
// file's `refusal` helper is a copy of `ApiResolveDraftTests`': both are
// private to their file, and a shared one would be a test helper living in
// the module under test.

private func scratch() throws -> URL {
    let dir = testScratchRoot.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private struct NoPaneIdReturned: Error {}

private struct ApiFixture {
    let registry: ActionRegistry
    let panes: PaneStore
    let layout: LayoutStore
}

private func fixture() async throws -> ApiFixture {
    let registry = ActionRegistry(journalDirectory: try scratch(), sessionId: "t")
    let panes = PaneStore()
    let layout = LayoutStore()
    await registerApiActions(
        into: registry, panes: panes, layout: layout,
        http: RecordingToolCaller(always: .object([
            "structuredContent": .object([
                "apis": .array([.object([
                    "name": .string("billing"),
                    "baseUrl": .string("https://billing.example.com"),
                    "authenticated": .bool(true),
                ])]),
            ]),
        ])),
        activeContext: { ("initech", "proj", "staging", "/tmp") })
    return ApiFixture(registry: registry, panes: panes, layout: layout)
}

private func open(_ f: ApiFixture) async throws -> String {
    let result = try await f.registry.dispatch(
        name: "api_open", params: .object(["entry": .string("billing")]),
        origin: .agent, environment: "staging", confirmation: nil)
    guard case .object(let fields) = result, case .string(let paneId)? = fields["pane"] else {
        throw NoPaneIdReturned()
    }
    return paneId
}

@discardableResult
private func setRequest(
    _ f: ApiFixture, pane: String, _ params: [String: JSONValue], origin: ActionOrigin = .agent
) async throws -> JSONValue {
    var all = params
    all["pane"] = .string(pane)
    return try await f.registry.dispatch(
        name: "api_set_request", params: .object(all),
        origin: origin, environment: "staging", confirmation: nil)
}

private func literal(_ text: String) -> JSONValue { .object(["literal": .string(text)]) }
private func row(_ name: String, _ value: [JSONValue]) -> JSONValue {
    .object(["name": .string(name), "value": .array(value)])
}

@Test func anAgentsWriteUnderTheOperatorsHandIsRefusedWhole() async throws {
    let f = try await fixture()
    let paneId = try await open(f)
    try await setRequest(f, pane: paneId, [
        "path": .array([literal("/v1/bookings")]),
        "headers": .array([row("x-tenant-id", [literal("acme")])]),
    ])
    // The operator's cursor is in the path.
    await f.panes.setApiFocus(paneId: paneId, fields: [.path], generation: 1)

    await #expect(throws: ApiActionError.self) {
        try await setRequest(f, pane: paneId, [
            "path": .array([literal("/v2/bookings")]),
            "headers": .array([row("x-tenant-id", [literal("globex")])]),
        ])
    }

    // WHOLE: the header region the same call named did not land either,
    // so what is on the screen is still a request one writer composed.
    let draft = await f.panes.apiDraft(paneId: paneId)
    #expect(draft.path == [.literal("/v1/bookings")])
    #expect(draft.headers == [ApiHeaderRow(name: "x-tenant-id", value: [.literal("acme")])])
}

@Test func leavingTheFieldReleasesItAndTheAgentsRetryLands() async throws {
    let f = try await fixture()
    let paneId = try await open(f)
    await f.panes.setApiFocus(paneId: paneId, fields: apiFocusMarks(.path), generation: 1)
    await #expect(throws: ApiActionError.self) {
        try await setRequest(f, pane: paneId, ["path": .array([literal("/agent")])])
    }
    await f.panes.setApiFocus(paneId: paneId, fields: [], generation: 2)
    try await setRequest(f, pane: paneId, ["path": .array([literal("/agent")])])
    #expect(await f.panes.apiDraft(paneId: paneId).path == [.literal("/agent")])
}

@Test func theOperatorsOwnWriteLandsWhileTheirCursorIsInTheField() async throws {
    // The pane saves as typed: every pause, Return and focus-out is a `.ui` write to the very
    // field the cursor is in, and the mark must never refuse it.
    let f = try await fixture()
    let paneId = try await open(f)
    await f.panes.setApiFocus(paneId: paneId, fields: apiFocusMarks(.path), generation: 1)
    try await setRequest(f, pane: paneId, ["path": .array([literal("/mine")])], origin: .ui)
    #expect(await f.panes.apiDraft(paneId: paneId).path == [.literal("/mine")])
    #expect(await f.panes.apiFocus(paneId: paneId) == [.path, apiQueryRegionMark])
}

@Test func aDropIsRefusedWhileTheCursorIsInAFieldItWouldRewrite() async throws {
    // `api_bind` and `api_unbind` rewrite the draft whole, so `refuseIfUnderTheOperatorsHand`
    // reads focus too. An agent's unbind under the cursor is refused.
    let f = try await fixture()
    let paneId = try await open(f)
    try await setRequest(f, pane: paneId, [
        "path": .array([literal("/v1/"), .object(["slot": .string("id")])]),
    ])
    await f.panes.setApiFocus(paneId: paneId, fields: [.body], generation: 1)
    let thrown = await #expect(throws: ApiActionError.self) {
        try await f.registry.dispatch(
            name: "api_unbind",
            params: .object([
                "pane": .string(paneId), "region": .string("path"), "index": .integer(1),
            ]),
            origin: .agent, environment: "staging", confirmation: nil)
    }
    let message = String(describing: try #require(thrown))
    #expect(message.contains("the operator is editing Body"))
}

// MARK: - The three refusals of new surface

@Test func readPanePublishesNoFocusKey() async throws {
    // A focus key would report where the operator's CURSOR is rather
    // than the screen, and an agent that polled it would be reading the
    // operator's hand. Asserted as identity rather than by naming a key: the
    // published pane is the same pane, byte for byte, whatever the
    // operator is in the middle of.
    let f = try await fixture()
    let paneId = try await open(f)
    try await setRequest(f, pane: paneId, [
        "path": .array([literal("/v1/bookings")]),
        "headers": .array([row("x-tenant-id", [literal("acme")])]),
        "contentType": .string("application/json"),
    ])
    let clean = await f.panes.readPane(paneId: paneId, kind: "api")

    let all: Set<ApiDraftField> = [.path, .query("expand"), .header("x-tenant-id"),
                                   .contentType, .body, .method]
    await f.panes.setApiFocus(paneId: paneId, fields: all, generation: 1)
    #expect(await f.panes.apiFocus(paneId: paneId).count == 6, "the marks are really set")
    #expect(await f.panes.readPane(paneId: paneId, kind: "api") == clean)
}

@Test func theSendPathConsultsNoDirtinessState() async throws {
    // Invariant 3 makes the screen the truth: a send puts what is on the
    // screen on the wire. A dirtiness check there would be a second gate
    // over #107's price, and it is unnecessary — the write rule has
    // already guaranteed the draft is single-authored. `resolveDraft` is
    // handed a draft and its sources and is given no way to ask.
    let f = try await fixture()
    let paneId = try await open(f)
    try await setRequest(f, pane: paneId, [
        "method": .string("GET"),
        "path": .array([literal("/v1/bookings")]),
        "query": .array([row("expand", [literal("customer")])]),
    ])
    let draft = await f.panes.apiDraft(paneId: paneId)
    let before = try resolveDraft(draft, sources: [:], credentialed: true).get()

    await f.panes.setApiFocus(
        paneId: paneId, fields: [.path, .query("expand"), .body, .method], generation: 1)
    let after = try resolveDraft(
        await f.panes.apiDraft(paneId: paneId), sources: [:], credentialed: true).get()
    #expect(after == before)
}

@Test func theRefusalNamesEveryCollidingFieldAndTheEscape() async throws {
    let f = try await fixture()
    let paneId = try await open(f)
    await f.panes.setApiFocus(
        paneId: paneId, fields: [.path, .header("x-tenant-id")], generation: 1)

    let thrown = await #expect(throws: ApiActionError.self) {
        try await setRequest(f, pane: paneId, [
            "path": .array([literal("/v3")]),
            "headers": .array([row("x-tenant-id", [literal("globex")])]),
        ])
    }
    let message = String(describing: try #require(thrown))

    // ONE message, every colliding field in it — so fixing the call is
    // one pass rather than one refusal per field.
    #expect(message.contains("Path"))
    #expect(message.contains("Header \u{00B7} x-tenant-id"))

    // And the escape named in it: a collision is opt-in for the agent,
    // because only one that named a pane id can contend at all. That is
    // what makes this cost a turn rather than the request.
    #expect(message.contains("api_open"))
    #expect(message.contains("names no pane"))
}

@Test func everyWriteKeyIsOneTheActionActuallyTakes() async throws {
    // `ApiWriteKey`'s raw values are a THIRD spelling of the region keys,
    // beside the action's schema and its decode cascade. A key that drifts
    // from the schema is a region the operator can write and the rule
    // cannot see — which is silent, and is the failure this pins.
    let f = try await fixture()
    let schema = try #require(await f.registry.all()
        .first { $0.name == "api_set_request" }?.schema)
    guard case .object(let top) = schema, case .object(let properties)? = top["properties"]
    else { Issue.record("no properties on the schema"); return }

    for key in ApiWriteKey.allCases {
        #expect(properties[key.rawValue] != nil, "the schema takes \(key.rawValue)")
    }
    // The two params the schema takes that name no field, stated so that
    // this reads as the whole key set rather than a subset of it: `pane`
    // says which draft, and `entry` re-points it without overwriting
    // anything anyone can have typed.
    #expect(Set(properties.keys).subtracting(ApiWriteKey.allCases.map(\.rawValue))
        == ["pane", "entry"])
}

@Test("A pane appearing re-notes the field its tracker still holds, and holds nothing otherwise")
func aReappearingPaneReNotesItsFocus() {
    var focus = ApiFocusTracker()
    #expect(focus.held == nil)
    _ = focus.took(ApiFieldRow(.path), identifier: "api.path", request: .empty)
    #expect(focus.held == [.path, apiQueryRegionMark])
    _ = focus.lost(identifier: "api.path")
    #expect(focus.held == nil)
}
