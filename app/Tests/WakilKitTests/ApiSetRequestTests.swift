import Foundation
import Testing
@testable import WakilKit

/// `api_set_request` (#190) — the draft is written by **one action, not
/// ten**, and the four regions draw in wire order.
///
/// Asserted through `ActionRegistry.dispatch` and `PaneStore.readPane`,
/// which is where the spec's own seam table puts it: what a caller can
/// observe is a dispatched action's result and a published snapshot, never
/// how either was reached.

private func scratch() throws -> URL {
    let dir = testScratchRoot.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func listApisReply(_ entries: [(String, String, Bool)]) -> JSONValue {
    .object([
        "structuredContent": .object([
            "apis": .array(entries.map { name, baseURL, authenticated in
                .object([
                    "name": .string(name),
                    "baseUrl": .string(baseURL),
                    "authenticated": .bool(authenticated),
                ])
            }),
        ]),
    ])
}

private struct NoPaneIdReturned: Error {}

private struct ApiFixture {
    let registry: ActionRegistry
    let panes: PaneStore
    let layout: LayoutStore
}

private func fixture(
    entries: [(String, String, Bool)] = [("billing", "https://billing.example.com", true)]
) async throws -> ApiFixture {
    let registry = ActionRegistry(journalDirectory: try scratch(), sessionId: "t")
    let panes = PaneStore()
    let layout = LayoutStore()
    await registerApiActions(
        into: registry, panes: panes, layout: layout,
        http: RecordingToolCaller(always: listApisReply(entries)),
        activeContext: { ("initech", "proj", "staging", "/tmp") })
    return ApiFixture(registry: registry, panes: panes, layout: layout)
}

private func open(_ f: ApiFixture, entry: String = "billing") async throws -> String {
    let result = try await f.registry.dispatch(
        name: "api_open", params: .object(["entry": .string(entry)]),
        origin: .agent, caller: .test("staging"), confirmation: nil)
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
        origin: origin, caller: .test("staging"), confirmation: nil)
}

/// The `request` region of what `read_pane` would answer with.
private func request(_ f: ApiFixture, _ paneId: String) async throws -> [String: JSONValue] {
    guard case .object(let json) = await f.panes.readPane(paneId: paneId, kind: "api"),
          case .object(let request)? = json["request"]
    else { throw NoPaneIdReturned() }
    return request
}

/// The refusal a resolution produced, for a test that is about what it
/// says. A copy of `ApiResolveDraftTests`' own, because both are private
/// to their file and a shared one would be a test helper in the module.
private func refusal(_ result: Result<ApiWireRequest, ApiSendRefusal>) throws -> ApiSendRefusal {
    switch result {
    case .success(let wire):
        Issue.record("expected a refusal, got \(wire)")
        throw ApiSendRefusal(failures: [])
    case .failure(let refusal):
        return refusal
    }
}

private func literal(_ text: String) -> JSONValue { .object(["literal": .string(text)]) }
private func slot(_ name: String) -> JSONValue { .object(["slot": .string(name)]) }
private func row(_ name: String, _ value: [JSONValue]) -> JSONValue {
    .object(["name": .string(name), "value": .array(value)])
}

// MARK: - One action writes any subset

@Test func oneActionWritesEveryRegionFromEitherOrigin() async throws {
    // The agent's whole-request build. The operator's one-region edit is
    // the same call with one key set — asserted below — which is what
    // Invariant 2 asks for literally rather than approximately.
    for origin in [ActionOrigin.agent, .ui] {
        let f = try await fixture()
        let paneId = try await open(f)
        try await setRequest(f, pane: paneId, [
            "method": .string("post"),
            "path": .array([literal("/v1/bookings/"), slot("id"), literal("/confirm")]),
            "query": .array([row("expand", [literal("customer")])]),
            "headers": .array([row("x-tenant-id", [literal("acme")])]),
            "contentType": .string("application/merge-patch+json"),
            "body": .array([literal("{\"status\":\"confirmed\"}")]),
        ], origin: origin)

        let request = try await request(f, paneId)
        // Upper-cased, and nowhere else: the pane draws the method it
        // will send rather than a second spelling of it.
        #expect(request["method"] == .string("POST"), "\(origin)")
        #expect(request["path"] == .array([
            .object(["literal": .string("/v1/bookings/")]),
            .object(["slot": .string("id")]),
            .object(["literal": .string("/confirm")]),
        ]), "\(origin)")
        #expect(request["query"] == .array([
            .object(["name": .string("expand"),
                     "value": .array([.object(["literal": .string("customer")])])]),
        ]), "\(origin)")
        #expect(request["body"] == .array([
            .object(["literal": .string("{\"status\":\"confirmed\"}")]),
        ]), "\(origin)")
    }
}

@Test func anAbsentRegionIsUnchangedAndAnEmptyOneIsCleared() async throws {
    let f = try await fixture()
    let paneId = try await open(f)
    try await setRequest(f, pane: paneId, [
        "method": .string("POST"),
        "path": .array([literal("/v1/bookings")]),
        "query": .array([row("expand", [literal("customer")])]),
        "contentType": .string("application/json"),
        "body": .array([literal("{}")]),
    ])

    // The operator's one-region edit: the path alone. Everything else is
    // absent, and absent means UNCHANGED rather than cleared — which is
    // the whole reason one action can serve both writers.
    try await setRequest(f, pane: paneId, ["path": .array([literal("/v1/invoices")])])
    let afterEdit = try await request(f, paneId)
    #expect(afterEdit["path"] == .array([.object(["literal": .string("/v1/invoices")])]))
    #expect(afterEdit["method"] == .string("POST"))
    #expect(afterEdit["query"] == .array([
        .object(["name": .string("expand"),
                 "value": .array([.object(["literal": .string("customer")])])]),
    ]))
    #expect(afterEdit["body"] == .array([.object(["literal": .string("{}")])]))

    // Clearing is naming the region with an empty list — said out loud,
    // so that "absent means unchanged" leaves a way to empty a region.
    try await setRequest(f, pane: paneId, [
        "query": .array([]), "body": .array([]), "contentType": .string(""),
    ])
    let afterClear = try await request(f, paneId)
    #expect(afterClear["query"] == .array([]))
    #expect(afterClear["body"] == .array([]))
    #expect(afterClear["path"] == .array([.object(["literal": .string("/v1/invoices")])]))
}

@Test func theFourRegionsArePublishedInWireOrder() async throws {
    // Wire order — path · query · headers · body — in the JSON as on
    // screen, so the surface reads in the order the bytes leave. `method`
    // and `origin` come first because they are the line above the four.
    let f = try await fixture()
    let paneId = try await open(f)
    guard case .object(let json) = await f.panes.readPane(paneId: paneId, kind: "api"),
          case .object(let request)? = json["request"] else {
        Issue.record("no request region"); return
    }
    #expect(Array(request.keys).sorted() ==
            ["body", "headers", "method", "origin", "path", "query"])
}

@Test func theQueryRegionCarriesNameAndValueApart() async throws {
    // So that no operator types a `?` or an `&` and hopes Wakil finds the
    // boundary: a value holding both is one value, published whole.
    let f = try await fixture()
    let paneId = try await open(f)
    try await setRequest(f, pane: paneId, [
        "query": .array([row("q", [literal("a=b&c")]), row("page", [literal("2")])]),
    ])
    let request = try await request(f, paneId)
    #expect(request["query"] == .array([
        .object(["name": .string("q"), "value": .array([.object(["literal": .string("a=b&c")])])]),
        .object(["name": .string("page"), "value": .array([.object(["literal": .string("2")])])]),
    ]))
}

// MARK: - The header region

@Test func headerRowsAreNameSortedWithWakilsRowsLastOnScreenAndInTheArm() async throws {
    let f = try await fixture()
    let paneId = try await open(f)
    try await setRequest(f, pane: paneId, [
        "headers": .array([
            row("x-tenant-id", [literal("acme")]),
            row("Accept", [literal("application/json")]),
            row("x-trace", [literal("t1")]),
        ]),
        "contentType": .string("application/json"),
    ])

    // The arm. `authorization` is not a row here — structurally, because
    // the app never holds the value — and `credentialed` takes its place.
    let request = try await request(f, paneId)
    guard case .array(let headers)? = request["headers"] else {
        Issue.record("headers is not an array"); return
    }
    let names: [String] = headers.compactMap {
        guard case .object(let row) = $0, case .string(let name)? = row["name"] else { return nil }
        return name
    }
    #expect(names == ["Accept", "x-tenant-id", "x-trace", "content-type"])

    // The screen, from the same function — one list, so a re-render
    // cannot reorder what the agent reads.
    let draft = await f.panes.apiDraft(paneId: paneId)
    let region = apiHeaderRegion(draft: draft, credentialed: true)
    #expect(region.map(\.name) == ["Accept", "x-tenant-id", "x-trace", "authorization",
                                   "content-type"])
    #expect(region.map(\.rowClass) == [.authored, .authored, .authored, .supplied, .derived])
}

@Test func theAuthorizationRowIsSuppliedByTheEntryWithNoValueAndNoRef() async throws {
    let region = apiHeaderRegion(
        draft: ApiDraft(
            entry: "billing", method: "GET", path: [], query: [], headers: [],
            contentType: "", body: []),
        credentialed: true)
    guard let auth = region.first(where: { $0.name == "authorization" }) else {
        Issue.record("no authorization row"); return
    }
    #expect(auth.value == nil, "the app never holds the credential, so there is nothing to draw")
    #expect(auth.provenance == "supplied by the billing entry")
    #expect(!auth.isEditable, "the only row in the region that is not the operator's to type in")
    // And it names no ref: the whole sentence is the provenance above.
    #expect(!(auth.provenance ?? "").contains("Ref"))

    // An entry with no credential configured supplies nothing, so the row
    // is not drawn — the region claiming an Authorization that will not be
    // sent is exactly the dishonesty the duplicate rule leans on.
    let uncredentialed = apiHeaderRegion(
        draft: ApiDraft(
            entry: "billing", method: "GET", path: [], query: [], headers: [],
            contentType: "", body: []),
        credentialed: false)
    #expect(!uncredentialed.contains { $0.name == "authorization" })
}

@Test func aDuplicateHeaderNameIsRefusedNamingWhatAlreadyHoldsIt() async throws {
    // Two of the operator's own.
    let twice = try refusal(resolveDraft(
        ApiDraft(
            entry: "billing", method: "GET", path: [], query: [],
            headers: [
                ApiHeaderRow(name: "Accept", value: [.literal("a")]),
                ApiHeaderRow(name: "accept", value: [.literal("b")]),
            ],
            contentType: "", body: []),
        sources: [:], credentialed: true))
    #expect(twice.failures.count == 1)
    #expect(twice.failures[0].message.contains("already on this request"))

    // The entry's own, which is what makes the deny list enforceable with
    // no copy of `rejectedCallerHeader` in Swift to go stale.
    let auth = try refusal(resolveDraft(
        ApiDraft(
            entry: "billing", method: "GET", path: [], query: [],
            headers: [ApiHeaderRow(name: "Authorization", value: [.literal("bearer x")])],
            contentType: "", body: []),
        sources: [:], credentialed: true))
    #expect(auth.failures.count == 1)
    #expect(auth.failures[0].message.contains("supplied by the billing entry"))

    // Wakil's own. `content-type` is a field of the draft, so a second row
    // for it would be silently lost.
    let contentType = try refusal(resolveDraft(
        ApiDraft(
            entry: "billing", method: "POST", path: [], query: [],
            headers: [ApiHeaderRow(name: "Content-Type", value: [.literal("text/plain")])],
            contentType: "", body: [.literal("{}")]),
        sources: [:], credentialed: true))
    #expect(contentType.failures.contains { $0.message.contains("Wakil's own row") })

    // And an entry with no credential has no `authorization` row to
    // collide with, so the refusal is `rejectedCallerHeader`'s to make in
    // Go rather than a Swift copy of its list.
    let uncredentialed = resolveDraft(
        ApiDraft(
            entry: "billing", method: "GET", path: [], query: [],
            headers: [ApiHeaderRow(name: "Authorization", value: [.literal("bearer x")])],
            contentType: "", body: []),
        sources: [:], credentialed: false)
    #expect((try? uncredentialed.get()) != nil)
}

@Test func aBadHeaderNameIsMarkedOnItsRowRatherThanBlockedAtTheKeystroke() async throws {
    // The write lands: eating characters makes a paste behave
    // unpredictably — `X-Tenant Id` pasted from a doc, half of it gone,
    // no statement of why.
    let f = try await fixture()
    let paneId = try await open(f)
    try await setRequest(f, pane: paneId, [
        "headers": .array([
            row("X-Tenant Id", [literal("acme")]),
            row("X-Trace", [literal("t\u{0007}1")]),
        ]),
    ])
    let request = try await request(f, paneId)
    guard case .array(let headers)? = request["headers"], headers.count == 2 else {
        Issue.record("the rows were not written"); return
    }

    // And both join the ONE aggregated send refusal, with the space
    // legal in a value and the control character not.
    let draft = await f.panes.apiDraft(paneId: paneId)
    let refused = try refusal(resolveDraft(draft, sources: [:], credentialed: true))
    #expect(refused.failures.count == 2)
    #expect(refused.failures.contains { $0.message.contains("field name") })
    #expect(refused.failures.contains { $0.message.contains("control character") })
}

@Test func aSpaceIsLegalInAHeaderValueAndAnEmptyValueEmitsEmpty() throws {
    let wire = try resolveDraft(
        ApiDraft(
            entry: "billing", method: "GET", path: [], query: [],
            headers: [
                ApiHeaderRow(name: "X-Note", value: [.literal("two words")]),
                ApiHeaderRow(name: "X-Empty", value: []),
            ],
            contentType: "", body: []),
        sources: [:], credentialed: true
    ).get()
    #expect(wire.headers == [
        ApiWireHeader(name: "X-Empty", value: ""),
        ApiWireHeader(name: "X-Note", value: "two words"),
    ])
}

// MARK: - content-type, and the three wire states of a body

@Test func contentTypeIsEditableFreeTextAndAdmitsNoParts() async throws {
    let f = try await fixture()
    let paneId = try await open(f)
    // Free text, not a fixed `+json` list: a list is an affordance and
    // would be a fence, and `application/vnd.api+json` is not enumerable
    // in advance.
    try await setRequest(f, pane: paneId, [
        "contentType": .string("application/vnd.api+json"),
        "body": .array([literal("{}")]),
    ])
    let draft = await f.panes.apiDraft(paneId: paneId)
    #expect(draft.contentType == "application/vnd.api+json")

    let region = apiHeaderRegion(draft: draft, credentialed: true)
    guard let row = region.first(where: { $0.name == "content-type" }) else {
        Issue.record("no content-type row"); return
    }
    #expect(row.rowClass == .derived)
    #expect(row.isEditable, "the one derived row that is editable")
    #expect(row.value == [.literal("application/vnd.api+json")])

    // It admits no parts, which is refused as the call being the wrong
    // shape rather than silently read as a literal.
    await #expect(throws: ApiActionError.self) {
        try await setRequest(f, pane: paneId, ["contentType": .array([literal("x")])])
    }
    #expect(await f.panes.apiDraft(paneId: paneId).contentType == "application/vnd.api+json")
}

@Test func anEmptyBodySendsNoBodyAndNoContentType() async throws {
    let f = try await fixture()
    let paneId = try await open(f)
    try await setRequest(f, pane: paneId, ["method": .string("DELETE")])
    let wire = try resolveDraft(
        await f.panes.apiDraft(paneId: paneId), sources: [:], credentialed: true).get()
    // Three wire states, not two: a request with nothing to say must not
    // be given a document, and a zero-length body announced as
    // `application/json` is a document that fails to parse.
    #expect(wire.body == nil)
    #expect(wire.contentType == nil)

    // B2: a content type left beside an emptied body is omitted from the wire, not refused.
    try await setRequest(f, pane: paneId, ["contentType": .string("application/json")])
    let omitted = try resolveDraft(
        await f.panes.apiDraft(paneId: paneId), sources: [:], credentialed: true).get()
    #expect(omitted.body == nil)
    #expect(omitted.contentType == nil)
}

// MARK: - Slots, and the entrance a slot does not have

@Test func aNamedHoleIsCreatedThroughThisActionAndItsNameSurvives() async throws {
    // There is no `api_add_slot`: a slot is a PART, so making a hole is
    // this same action with a slot in the list.
    let f = try await fixture()
    let paneId = try await open(f)
    try await setRequest(f, pane: paneId, [
        "path": .array([literal("/v1/bookings/"), slot("booking_id")]),
    ])
    #expect(try await request(f, paneId)["path"] == .array([
        .object(["literal": .string("/v1/bookings/")]),
        .object(["slot": .string("booking_id")]),
    ]))

    // The name is what a refusal says while the hole is empty, and it is
    // the label the chip keeps once a row fills it — so the request still
    // reads the way the API's docs write it. Both halves of that are the
    // same string, which is why the refusal below is the assertion.
    let draft = await f.panes.apiDraft(paneId: paneId)
    let refused = try refusal(resolveDraft(draft, sources: [:], credentialed: true))
    #expect(refused.failures.count == 1)
    #expect(refused.failures[0].message.contains("booking_id"))

    // A hole with no name is refused: a refusal that cannot say which
    // hole is empty is not one the operator can act on.
    await #expect(throws: ApiActionError.self) {
        try await setRequest(f, pane: paneId, ["path": .array([slot("")])])
    }
}

@Test func aHoleIsNeverCreatedByTypedCharacters() async throws {
    // Braces in a JSON body stay literal text, and so does every template
    // spelling anyone might reach for. There is no delimiter anywhere in
    // Wakil and nothing is parsed back, so this is true by construction
    // rather than by escaping — which is the point of asserting it: a
    // future reader who adds a parser breaks this test.
    let f = try await fixture()
    let paneId = try await open(f)
    let typed = "{\"id\": \"{{id}}\", \"note\": \"${x} <%= y %> :z\"}"
    try await setRequest(f, pane: paneId, [
        "body": .array([literal(typed)]),
        "path": .array([literal("/v1/{id}/../etc")]),
    ])
    let request = try await request(f, paneId)
    #expect(request["body"] == .array([.object(["literal": .string(typed)])]),
            "one literal part, no slot, no template")
    #expect(request["path"] == .array([.object(["literal": .string("/v1/{id}/../etc")])]))
}

@Test func aBoundValueCannotBeWrittenAsText() async throws {
    // A slot never converts to a bound value or back except by a gesture.
    // A binding pins the source column's declared type and the source
    // pane's generation at the moment of the drop, and `read_pane`
    // publishes neither — so a part written back out of a snapshot would
    // be a binding with invented provenance.
    let f = try await fixture()
    let paneId = try await open(f)
    do {
        try await setRequest(f, pane: paneId, [
            "path": .array([.object([
                "name": .string("booking_id"),
                "binding": .string("live"),
                "source": .object(["pane": .string("p3"), "column": .string("reference")]),
            ])]),
        ])
        Issue.record("a bound value was written as text")
    } catch let error as ApiActionError {
        #expect("\(error)".contains("api_bind"))
    }
    #expect(try await request(f, paneId)["path"] == .array([]))
}

// MARK: - W16: a bound value locks only itself

/// Puts a binding into the pane's draft the way a drop would, without a grid.
private func holding(
    _ f: ApiFixture, _ paneId: String, path: [ApiPart] = [], body: [ApiPart] = []
) async {
    var draft = await f.panes.apiDraft(paneId: paneId)
    draft.path = path
    draft.body = body
    await f.panes.setApiDraft(paneId: paneId, draft: draft)
}

private func boundJSON(_ bound: ApiBoundValue) -> JSONValue {
    apiPartJSON(.bound(bound), sources: [:])
}

@Test func aWriteMayCarryABindingTheRegionHoldsWhereverItMoved() async throws {
    let f = try await fixture()
    let paneId = try await open(f)
    let bound = liveBinding(name: "id", generation: 3)
    await holding(f, paneId, path: [.literal("/v1/"), .bound(bound)])
    // The agent's write moves the text around the chip and carries the chip, as published.
    try await setRequest(f, pane: paneId, [
        "path": .array([literal("/v2/bookings/"), boundJSON(bound), literal("/confirm")]),
    ])
    // The binding that lands is the one the region held, with its pinned provenance
    // (generation 3, declared type), not a reconstruction from the JSON.
    #expect(await f.panes.apiDraft(paneId: paneId).path
        == [.literal("/v2/bookings/"), .bound(bound), .literal("/confirm")])
}

@Test func aBindingTheRegionDoesNotHoldIsStillRefused() async throws {
    let f = try await fixture()
    let paneId = try await open(f)
    let held = liveBinding(name: "id")
    await holding(f, paneId, path: [.literal("/v1/"), .bound(held)])
    let other = ApiBoundValue(
        name: "id", binding: .live,
        source: valueSource(name: "id", keyValues: ["100"], generation: 3))
    do {
        try await setRequest(f, pane: paneId, ["path": .array([boundJSON(other)])])
        Issue.record("a binding the region does not hold was written")
    } catch let error as ApiActionError {
        #expect("\(error)".contains("api_bind"))
    }
    #expect(await f.panes.apiDraft(paneId: paneId).path == [.literal("/v1/"), .bound(held)])
}

@Test func aBindingCannotMoveToAnotherRegion() async throws {
    let f = try await fixture()
    let paneId = try await open(f)
    let bound = liveBinding(name: "id")
    await holding(f, paneId, path: [.bound(bound)])
    await #expect(throws: ApiActionError.self) {
        try await setRequest(f, pane: paneId, ["body": .array([boundJSON(bound)])])
    }
}

@Test func aHeldBindingCannotBeWrittenTwice() async throws {
    // Review Focus 2: the second copy would be a binding no gesture made.
    let f = try await fixture()
    let paneId = try await open(f)
    let bound = liveBinding(name: "id")
    await holding(f, paneId, path: [.bound(bound)])
    await #expect(throws: ApiActionError.self) {
        try await setRequest(f, pane: paneId, ["path": .array([boundJSON(bound), boundJSON(bound)])])
    }
    #expect(await f.panes.apiDraft(paneId: paneId).path == [.bound(bound)])
}

// MARK: - The refusals of the call's own shape

@Test func aMalformedRegionRefusesTheWholeCallAndWritesNothing() async throws {
    let f = try await fixture()
    let paneId = try await open(f)
    try await setRequest(f, pane: paneId, ["path": .array([literal("/v1/ok")])])

    // The path is fine and the body is not. A draft half-written from a
    // call that turned out to be malformed is a request neither writer
    // composed.
    let malformed: [[String: JSONValue]] = [
        ["path": .array([literal("/v2/new")]), "body": .array([.string("not a part")])],
        ["path": .array([literal("/v2/new")]), "body": .string("a string, not a list")],
        ["path": .array([literal("/v2/new")]), "query": .array([.object(["value": .array([])])])],
        ["path": .array([literal("/v2/new")]), "headers": .string("not a list")],
        ["path": .array([literal("/v2/new")]), "method": .string("   ")],
        ["path": .array([literal("/v2/new")]), "body": .array([.object([
            "literal": .string("x"), "slot": .string("y"),
        ])])],
    ]
    for params in malformed {
        await #expect(throws: ApiActionError.self) {
            try await setRequest(f, pane: paneId, params)
        }
        #expect(try await request(f, paneId)["path"] ==
                .array([.object(["literal": .string("/v1/ok")])]),
                "\(params.keys.sorted()) wrote a region despite refusing")
    }
}

@Test func aPaneOfAnotherKindIsRefusedByName() async throws {
    let f = try await fixture()
    let db = await f.layout.open(kind: "db", title: "customers").id
    do {
        try await setRequest(f, pane: db, ["method": .string("POST")])
        Issue.record("api_set_request wrote into a db pane")
    } catch let error as ApiActionError {
        #expect("\(error)".contains("db"))
        #expect("\(error)".contains(db))
    }
}

@Test func aPaneThatIsNotOpenIsRefusedAndAnOmittedOneIsToo() async throws {
    let f = try await fixture()
    _ = try await open(f)
    await #expect(throws: StandardActionError.self) {
        try await setRequest(f, pane: "no-such-pane", ["method": .string("POST")])
    }
    await #expect(throws: ApiActionError.self) {
        _ = try await f.registry.dispatch(
            name: "api_set_request", params: .object(["method": .string("POST")]),
            origin: .agent, caller: .test("staging"), confirmation: nil)
    }
}

// MARK: - The entry, re-pointed without a second pane

@Test func theEntryIsRePointedKeepingEveryRegion() async throws {
    let f = try await fixture(entries: [
        ("billing", "https://billing.example.com", true),
        ("auth", "https://auth.example.com", false),
    ])
    let paneId = try await open(f)
    try await setRequest(f, pane: paneId, [
        "method": .string("POST"), "path": .array([literal("/v1/bookings")]),
    ])

    let result = try await setRequest(f, pane: paneId, ["entry": .string("auth")])
    guard case .object(let fields) = result else { Issue.record("no result"); return }
    #expect(fields["entry"] == .string("auth"))
    #expect(fields["origin"] == .string("https://auth.example.com"))
    // `credentialed` moves with the entry, so the header region's
    // `authorization` row follows what the new entry actually supplies.
    #expect(fields["credentialed"] == .bool(false))

    let request = try await request(f, paneId)
    #expect(request["path"] == .array([.object(["literal": .string("/v1/bookings")])]),
            "the entry lives on the draft; re-pointing it keeps the request")
    #expect(request["origin"] == .string("https://auth.example.com"))
    #expect(await f.layout.snapshot().panes.count == 1)

    // An unknown name fails loudly rather than falling back, and the
    // draft keeps the entry it had.
    await #expect(throws: ApiActionError.self) {
        try await setRequest(f, pane: paneId, ["entry": .string("authh")])
    }
    #expect(await f.panes.apiDraft(paneId: paneId).entry == "auth")
}

// MARK: - The price

@Test func theActionIsControlAndNeverConsultsTheWriteGate() async throws {
    // `.control`: writing a draft changes Wakil's own state and reaches
    // nothing outside it, so being pointed at production is no reason to
    // be unable to compose a request. `api_send` is the `.mutate`, and it
    // is #194's.
    let f = try await fixture()
    let paneId = try await open(f)
    let action = await f.registry.all().first { $0.name == "api_set_request" }
    #expect(action?.kind == .control)

    _ = try await f.registry.dispatch(
        name: "api_set_request",
        params: .object(["pane": .string(paneId), "method": .string("DELETE")]),
        origin: .agent, caller: .test("production"), confirmation: nil)
    #expect(try await request(f, paneId)["method"] == .string("DELETE"))
}

// MARK: - The part shape `read_pane` publishes

@Test func aBoundPartPublishesItsProvenanceAPreviewAndNoPinnedType() {
    // **Asserted against the encoder directly, because no action in this
    // build can put a bound value on a draft** — `api_bind` is #192 and
    // `api_set_request` refuses one by name above. The encoder is written
    // now anyway: the alternative is a snapshot arm that cannot encode one
    // of the three parts its own type has, and a later ticket inventing
    // the wire shape #118 already ruled.
    let source = ApiSourcePane(
        columns: ["id", "reference"],
        rows: [[.integer(8842), .string("BK-2026-8842")]],
        generation: 4)
    let bound = ApiPart.bound(ApiBoundValue(
        name: "booking_id", binding: .live,
        source: ApiValueSource(
            pane: "p3", table: "bookings", keyColumns: ["id"], keyValues: ["8842"],
            column: "reference", declaredType: "TEXT", generation: 4)))

    guard case .object(let json) = apiPartJSON(bound, sources: ["p3": source]) else {
        Issue.record("a bound part did not encode to an object"); return
    }
    #expect(json["name"] == .string("booking_id"))
    #expect(json["binding"] == .string("live"))
    // `preview`, never `value`: it is what the source holds NOW, not what
    // will be sent.
    #expect(json["preview"] == .string("BK-2026-8842"))
    #expect(json["resolves"] == .bool(true))
    #expect(json["available"] == .null)
    #expect(json["source"] == .object([
        "pane": .string("p3"), "table": .string("bookings"),
        "keyColumns": .array([.string("id")]), "keyValues": .array([.string("8842")]),
        "column": .string("reference"),
    ]))
    // Neither the pinned declared type nor the generation is published.
    // Both exist for resolution (#184, #137), neither is on the operator's
    // screen, and publishing them would invite a reader to write them back.
    guard case .object(let published)? = json["source"] else { return }
    #expect(published["declaredType"] == nil)
    #expect(published["generation"] == nil)

    // A live value that does not resolve right now says so and lists the
    // columns that WERE available — the one key in this arm that exists
    // for the agent rather than mirroring the screen, because under the
    // send's `.allow` price an agent that cannot see it learns a send will
    // be refused by making it.
    let moved = ApiSourcePane(columns: ["id", "total"], rows: [[.integer(1), .number(4.5)]],
                              generation: 4)
    guard case .object(let gone) = apiPartJSON(bound, sources: ["p3": moved]) else {
        Issue.record("a bound part did not encode to an object"); return
    }
    #expect(gone["preview"] == .null)
    #expect(gone["resolves"] == .bool(false))
    #expect(gone["available"] == .array([.string("id"), .string("total")]))
}

@Test func aSlotPublishesItsNameAndNothingElse() {
    #expect(apiPartJSON(.slot("id"), sources: [:]) == .object(["slot": .string("id")]))
    #expect(apiPartJSON(.literal("/v1/"), sources: [:]) == .object(["literal": .string("/v1/")]))
}

@Test func aHolesNameSurvivesBeingFilled() {
    // The chip's label is the hole's name before and after a row lands on
    // it, so a path reads `/v1/bookings/booking_id/confirm` throughout and
    // the request still reads the way the API's own docs write it.
    #expect(apiPartDrawing(.slot("booking_id")) == .chip("booking_id", filled: false))
    #expect(apiPartDrawing(.bound(ApiBoundValue(
        name: "booking_id", binding: .live,
        source: ApiValueSource(
            pane: "p3", table: "bookings", keyColumns: ["id"], keyValues: ["8842"],
            column: "reference", declaredType: "TEXT", generation: 1))))
            == .chip("booking_id", filled: true))
    // A literal is text, never a chip — there is no gesture that turns
    // typed characters into a hole.
    #expect(apiPartDrawing(.literal("{{id}}")) == .text("{{id}}"))
}

@Test func contentTypeRefusesAPartListInItsOwnWords() async throws {
    // Not borrowed from the part refusal: `contentType` is not a region
    // of parts that happened to be sent wrong, it is the one field that
    // admits none — so the sentence says which fact is being refused.
    let f = try await fixture()
    let paneId = try await open(f)
    do {
        try await setRequest(f, pane: paneId, ["contentType": .array([literal("x")])])
        Issue.record("contentType took a part list")
    } catch let error as ApiActionError {
        #expect("\(error)".contains("free text"))
        #expect("\(error)".contains("admits no parts"))
    }
}

// MARK: - The review's findings

@Test func anUnnamedEntryIsRefusedWhereApiOpenAdmitsOne() async throws {
    // On `api_open` an omitted entry means *the only one there is*, which
    // is the single-entry environment's whole invocation. Here the draft
    // already targets one, so the same value would be an omitted name
    // and silently re-point the request at whatever the
    // environment happens to declare — a different backend, with a
    // different credential, and nothing said about it.
    let f = try await fixture()
    let paneId = try await open(f)
    for bad in [JSONValue.string(""), .string("   "), .number(1), .null] {
        await #expect(throws: ApiActionError.self) {
            try await setRequest(f, pane: paneId, ["entry": bad])
        }
    }
    #expect(await f.panes.apiDraft(paneId: paneId).entry == "billing")
}

@Test func theHeaderOrderIsTotalAndNotMerelyCaseInsensitive() {
    // `Swift.sorted(by:)` is introsort and is NOT stable, so a
    // case-insensitive comparison alone leaves `Accept` and `accept` free
    // to swap between renders — the one thing this ordering exists to
    // prevent. A duplicate is refused at SEND and still DRAWN, adjacent to
    // what it collides with, so the order has to be defined for it.
    let drafted = ApiDraft(
        entry: "billing", method: "GET", path: [], query: [],
        headers: [
            ApiHeaderRow(name: "accept", value: [.literal("second")]),
            ApiHeaderRow(name: "Accept", value: [.literal("first")]),
            ApiHeaderRow(name: "accept", value: [.literal("third")]),
        ],
        contentType: "", body: [])
    let expected = [
        ApiHeaderRegionRow(
            name: "Accept", value: [.literal("first")], provenance: nil, rowClass: .authored),
        ApiHeaderRegionRow(
            name: "accept", value: [.literal("second")], provenance: nil, rowClass: .authored),
        ApiHeaderRegionRow(
            name: "accept", value: [.literal("third")], provenance: nil, rowClass: .authored),
    ]
    // Run it repeatedly: an unstable sort over equal keys is free to differ
    // between calls, so one pass proves nothing.
    for _ in 0..<64 {
        #expect(Array(apiHeaderRegion(draft: drafted, credentialed: false).prefix(3)) == expected)
    }
}

@Test func thePublishedHeaderRowsAreASubsequenceOfTheDrawnOnes() async throws {
    let f = try await fixture()
    let paneId = try await open(f)
    try await setRequest(f, pane: paneId, [
        "headers": .array([row("zzz-last", [literal("v")]), row("Accept", [literal("json")])]),
        "contentType": .string("application/json"),
    ])

    let drawn = await f.panes.apiSnapshot(paneId: paneId).request.headers
    #expect(drawn.map(\.name) == ["Accept", "zzz-last", "authorization", "content-type"],
            "Wakil's own rows are LAST, which beats the name sort")

    guard case .array(let published)? = try await request(f, paneId)["headers"] else {
        Issue.record("headers is not an array"); return
    }
    let names: [String] = published.compactMap {
        guard case .object(let row) = $0, case .string(let name)? = row["name"] else { return nil }
        return name
    }
    // Same order, fewer members: `authorization` has no value on this side
    // to publish and `credentialed` carries it instead.
    #expect(names == ["Accept", "zzz-last", "content-type"])
    var remaining = drawn.map(\.name)
    for name in names {
        guard let at = remaining.firstIndex(of: name) else {
            Issue.record("\(name) is published but not drawn"); return
        }
        remaining.removeFirst(at + 1)
    }
}

// MARK: - W8: the pane's title follows its entry

@Test func w8TheTitleFollowsTheEntry() async throws {
    let f = try await fixture(entries: [
        ("billing", "https://billing.example.com", true), ("catalog", "https://c.example", false),
    ])
    let paneId = try await open(f)
    try await setRequest(f, pane: paneId, ["entry": .string("catalog")])
    #expect(await f.layout.snapshot().panes.first { $0.id == paneId }?.title == "catalog")
}

@Test func w8AWriteNamingNoEntryLeavesTheTitle() async throws {
    let f = try await fixture()
    let paneId = try await open(f)
    await f.layout.retitle(id: paneId, to: "kept")
    try await setRequest(f, pane: paneId, ["method": .string("GET")])
    #expect(await f.layout.snapshot().panes.first { $0.id == paneId }?.title == "kept")
}

@Test func w8AReopenedRowRetitlesThePane() async throws {
    let f = try await fixture()
    let paneId = try await open(f)
    var sent = ApiDraft.empty
    sent.entry = "catalog"
    await f.panes.recordApiSend(paneId: paneId, draft: sent, response: .ok(ApiResponseOK(
        status: 200, url: "u", environment: "staging", headers: [:], body: "",
        durationMs: 1, byteCount: 0, truncated: false)))
    let row = try #require(await f.panes.apiSnapshot(paneId: paneId).recent.first)
    _ = try await f.registry.dispatch(
        name: "api_reopen", params: .object(["pane": .string(paneId), "row": .string(row.id)]),
        origin: .ui, caller: .test("staging"), confirmation: nil)
    #expect(await f.layout.snapshot().panes.first { $0.id == paneId }?.title == "catalog")
}

// MARK: - Final review I1: a cross-entry Reopen re-points the pane

/// Records one sent row on `paneId` whose draft targeted `entry`, and answers its id.
private func recordSent(
    _ f: ApiFixture, pane paneId: String, entry: String, credentialed: Bool
) async throws -> String {
    var sent = ApiDraft.empty
    sent.entry = entry
    sent.path = [.literal("/x")]
    await f.panes.recordApiSend(
        paneId: paneId, draft: sent,
        response: .ok(ApiResponseOK(
            status: 200, url: "u", environment: "staging", headers: [:], body: "",
            durationMs: 1, byteCount: 0, truncated: false)),
        credentialed: credentialed)
    return try #require(await f.panes.apiSnapshot(paneId: paneId).recent.first).id
}

@Test("I1: Reopen of a row sent to another entry resolves that entry — origin and credential follow")
func aCrossEntryReopenResolvesTheRowsEntry() async throws {
    let f = try await fixture(entries: [
        ("billing", "https://billing.example.com", true), ("catalog", "https://c.example", false),
    ])
    let paneId = try await open(f, entry: "catalog")
    let rowId = try await recordSent(f, pane: paneId, entry: "billing", credentialed: true)
    _ = try await f.registry.dispatch(
        name: "api_reopen", params: .object(["pane": .string(paneId), "row": .string(rowId)]),
        origin: .ui, caller: .test("staging"), confirmation: nil)
    let snap = await f.panes.apiSnapshot(paneId: paneId)
    #expect(snap.entry == "billing")
    #expect(snap.request.origin == "https://billing.example.com")
    #expect(snap.credentialed)
    #expect(apiOriginLine(snap) == .origin("https://billing.example.com"))

    // And back: a row sent to the uncredentialed entry takes the credential away.
    let back = try await recordSent(f, pane: paneId, entry: "catalog", credentialed: false)
    _ = try await f.registry.dispatch(
        name: "api_reopen", params: .object(["pane": .string(paneId), "row": .string(back)]),
        origin: .ui, caller: .test("staging"), confirmation: nil)
    let after = await f.panes.apiSnapshot(paneId: paneId)
    #expect(after.request.origin == "https://c.example")
    #expect(!after.credentialed)
}

@Test("I1: a listing overtaken by a switch writes no resolution — the reopened pane reads absent")
func aStaleCrossEntryReopenClears() async throws {
    let panes = PaneStore()
    await panes.openApi(paneId: "api-1", entry: "catalog", environment: "staging",
                        origin: "https://c.example", credentialed: false, entries: ["catalog", "billing"])
    var sent = ApiDraft.empty
    sent.entry = "billing"
    await panes.recordApiSend(paneId: "api-1", draft: sent, response: .ok(ApiResponseOK(
        status: 200, url: "u", environment: "staging", headers: [:], body: "",
        durationMs: 1, byteCount: 0, truncated: false)))
    let row = try #require(await panes.apiSnapshot(paneId: "api-1").recent.first)
    let generation = await panes.apiResolutionMark()
    await panes.switchScope(to: .initial)   // anything that moves the generation
    let listing = [ApiEntryListing(name: "billing", baseURL: "https://b.example", credentialed: true)]
    #expect(await panes.reopenApiRow(
        paneId: "api-1", rowId: row.id, listing: listing, generation: generation) != nil)
    let snap = await panes.apiSnapshot(paneId: "api-1")
    #expect(snap.request.origin == nil)
    #expect(!snap.credentialed)
}

@Test("I1: a Recent row names its entry when it is not the pane's")
func aRecentRowNamesAForeignEntry() {
    let row = ApiRecentRow(
        method: "GET", entry: "billing", environment: "staging", path: "/x",
        sentUrl: "https://b/x", status: 200, durationMs: 3, draft: ApiDraft.empty)
    #expect(apiRecentRowLabel(row, paneEntry: "billing") == "GET /x · 200 · 3 ms")
    #expect(apiRecentRowLabel(row, paneEntry: "catalog") == "billing · GET /x · 200 · 3 ms")
    #expect(apiRecentRowLabel(row) == "GET /x · 200 · 3 ms")
}
