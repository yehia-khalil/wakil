import Foundation
import Testing
@testable import WakilKit

/// The bridge from a db pane to a drop — the half of Task 4 that Tasks 1
/// and 3 deferred.
///
/// **Registration waited for this on purpose.** `apiBind` is a pure
/// function over an `ApiDropSource`, and until something could assemble
/// one from a pane id, registering `api_bind` would have been an action
/// whose only caller could not call it. That is the never-wired-parameter
/// shape this repo has paid for before, and it is only visible by running
/// the app.
///
/// **A pane needs a `generation` before any of it works.**
/// `ApiValueSource.generation` and `ApiSourcePane.generation` have been in
/// the model since #137 with nothing producing one: a capture dies when
/// its source pane replaces its rows, and `setRows` is the single writer
/// that does. So the counter lives on the data surface and is bumped
/// there, which is the only place it can be right.

private func store() -> PaneStore { PaneStore() }

private func loadBookings(
    _ panes: PaneStore, paneId: String = "db1", editable: Bool = true,
    rows: [[JSONValue]]? = nil
) async {
    await panes.setRows(
        paneId: paneId,
        columns: ["id", "reference", "guest"],
        columnTypes: ["INTEGER", "TEXT", "TEXT"],
        columnTypesInferred: false,
        rows: rows ?? [
            [.integer(41), .string("BK-41"), .string("Ada")],
            [.integer(42), .string("BK-42"), .string("Grace")],
        ],
        millis: 3, truncated: false, pageable: true, offset: 0, sort: [], listsTables: false,
        editable: editable
            ? PaneEditable(
                table: "bookings", keyColumns: ["id"], columns: ["reference", "guest"],
                rowKeys: ["k41", "k42"])
            : nil)
}

// MARK: - The generation

@Test("A data surface's generation moves every time it replaces its rows, and not otherwise")
func theGenerationMovesWithTheRows() async {
    let panes = store()
    await loadBookings(panes)
    let first = await panes.sourcePane(paneId: "db1")?.generation
    #expect(first != nil)

    // A read changes nothing.
    _ = await panes.snapshot(paneId: "db1", kind: "db")
    #expect(await panes.sourcePane(paneId: "db1")?.generation == first)

    // A re-fetch does. Those rows are gone, whatever they came back as —
    // which is exactly what a capture has to die on (#137 ruling 2).
    await loadBookings(panes)
    let second = await panes.sourcePane(paneId: "db1")?.generation
    #expect(second != nil)
    #expect(second != first)
}

@Test("Sorting a pane does not move its generation — the rows are the same rows")
func sortingDoesNotKillACapture() async {
    let panes = store()
    await loadBookings(panes)
    let before = await panes.sourcePane(paneId: "db1")?.generation

    await panes.reorder(paneId: "db1", sort: [PaneSort(column: "reference", direction: .descending)])

    // A re-sort reorders what is on screen; it does not re-read anything.
    // A capture that died here would die on the operator tidying the view.
    #expect(await panes.sourcePane(paneId: "db1")?.generation == before)
}

// MARK: - The drop source

@Test("A drop assembles table, key columns, declared types and the row that was dropped")
func aDropCarriesEverythingABindingPins() async throws {
    let panes = store()
    await loadBookings(panes)

    let drop = try #require(await panes.dropSource(paneId: "db1", row: 1))
    #expect(drop.pane == "db1")
    #expect(drop.table == "bookings")
    #expect(drop.keyColumns == ["id"])
    #expect(drop.columns == ["id", "reference", "guest"])
    #expect(drop.columnTypes == ["INTEGER", "TEXT", "TEXT"])
    #expect(drop.row == [.integer(42), .string("BK-42"), .string("Grace")])
    #expect(drop.editable == true)
    // The keys read off that row, as text.
    #expect(drop.keyValues == ["42"])
}

@Test("The dropped row is the row on SCREEN, so a sorted grid drops what the operator sees")
func theDropFollowsTheDisplayedOrder() async throws {
    let panes = store()
    await loadBookings(panes)
    await panes.reorder(paneId: "db1", sort: [PaneSort(column: "id", direction: .descending)])

    // Row 0 on screen is now booking 42. A drop that read the unsorted
    // rows would bind 41 while the operator watched themselves drag 42.
    let drop = try #require(await panes.dropSource(paneId: "db1", row: 0))
    #expect(drop.keyValues == ["42"])
}

@Test("A pane that is not editable yields a drop that binds captured")
func anUneditablePaneDropsCaptured() async throws {
    let panes = store()
    await loadBookings(panes, editable: false)

    let drop = try #require(await panes.dropSource(paneId: "db1", row: 0))
    #expect(drop.editable == false)
    // With no `editable`, the driver named no table and no key columns —
    // a join, most often — so the value is held rather than re-resolved.
    #expect(drop.keyColumns.isEmpty)

    var draft = ApiDraft.empty
    draft.path = [.slot("guest")]
    let (filled, _) = try apiBind(draft: draft, source: drop, holes: ["guest"], sources: [:])
    guard case .bound(let value)? = filled.path.first else {
        Issue.record("the drop did not bind"); return
    }
    #expect(value.binding == .captured(ApiHeldCell(token: .string("Ada"), declaredType: "TEXT")))
}

@Test("A drop refuses a pane that holds no rows and a row index the pane does not have")
func aDropRefusesWhatItCannotRead() async {
    let panes = store()
    #expect(await panes.dropSource(paneId: "nosuchpane", row: 0) == nil)

    await loadBookings(panes)
    #expect(await panes.dropSource(paneId: "db1", row: 2) == nil)
    #expect(await panes.dropSource(paneId: "db1", row: -1) == nil)
}

// MARK: - End to end, through the store

@Test("A live value bound through the bridge resolves, and dies when the source re-fetches")
func aBindingThroughTheBridgeResolvesAndThenDies() async throws {
    let panes = store()
    await loadBookings(panes)

    var draft = ApiDraft.empty
    draft.path = [.literal("/bookings/"), .slot("id"), .literal("/confirm")]
    let drop = try #require(await panes.dropSource(paneId: "db1", row: 0))
    let sources = await panes.apiSources()
    let (filled, missed) = try apiBind(
        draft: draft, source: drop, holes: ["id"], sources: sources)
    #expect(missed.isEmpty)

    // It resolves against the pane it came from.
    #expect(resolvePart(filled.path[1], sources: await panes.apiSources()).isResolved)

    // A live binding survives a re-fetch that still holds its row: it is
    // found by key values, not by generation.
    await loadBookings(panes)
    #expect(resolvePart(filled.path[1], sources: await panes.apiSources()).isResolved)

    // It does not survive its row leaving the result.
    await loadBookings(panes, rows: [[.integer(42), .string("BK-42"), .string("Grace")]])
    #expect(!resolvePart(filled.path[1], sources: await panes.apiSources()).isResolved)
}

// MARK: - The two actions, driven through the registry

private func scratchDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("api-bind-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func bindFixture() async throws -> (ActionRegistry, PaneStore, LayoutStore, String) {
    let registry = ActionRegistry(journalDirectory: try scratchDir(), sessionId: "t")
    let panes = PaneStore()
    let layout = LayoutStore()
    let http = RecordingToolCaller(always: .object([
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
        name: "api_open", params: .object([:]), origin: .agent, environment: "staging",
        confirmation: nil)
    guard case .object(let fields) = opened, case .string(let paneId)? = fields["pane"] else {
        throw NoApiPaneOpened()
    }
    await loadBookings(panes)
    return (registry, panes, layout, paneId)
}

private struct NoApiPaneOpened: Error {}

@Test("api_bind fills the draft's own holes from a dropped row, and names the miss once")
func apiBindIsReachableAndFillsTheDraft() async throws {
    let (registry, panes, _, paneId) = try await bindFixture()

    // A draft with three holes, one of which no column matches.
    var draft = ApiDraft.empty
    draft.path = [.literal("/bookings/"), .slot("id"), .literal("/confirm")]
    draft.query = [ApiQueryRow(name: "ref", value: [.slot("reference")])]
    draft.body = [.slot("nonesuch")]
    await panes.setApiDraft(paneId: paneId, draft: draft)

    let result = try await registry.dispatch(
        name: "api_bind",
        params: .object([
            "pane": .string(paneId), "source": .string("db1"), "row": .number(0),
        ]),
        origin: .agent, environment: "staging", confirmation: nil)

    guard case .object(let fields) = result else {
        Issue.record("api_bind returned no object"); return
    }
    #expect(fields["filled"] == .number(2))
    #expect(fields["unmatched"] == .array([.string("nonesuch")]))

    let bound = await panes.apiDraft(paneId: paneId)
    guard case .bound(let id) = bound.path[1] else {
        Issue.record("the path hole was not filled"); return
    }
    #expect(id.source.pane == "db1")
    #expect(id.source.keyValues == ["41"])
    #expect(id.binding == .live)
    // The unmatched hole is still a hole.
    #expect(bound.body == [.slot("nonesuch")])
}

@Test("api_bind refuses a row the source pane does not have, and binds nothing")
func apiBindRefusesAnAbsentRow() async throws {
    let (registry, panes, _, paneId) = try await bindFixture()
    var draft = ApiDraft.empty
    draft.path = [.slot("id")]
    await panes.setApiDraft(paneId: paneId, draft: draft)

    await #expect(throws: (any Error).self) {
        _ = try await registry.dispatch(
            name: "api_bind",
            params: .object([
                "pane": .string(paneId), "source": .string("db1"), "row": .number(99),
            ]),
            origin: .agent, environment: "staging", confirmation: nil)
    }
    // A refusal applies no part of the call.
    #expect(await panes.apiDraft(paneId: paneId).path == [.slot("id")])
}

@Test("api_unbind gives the name back through the registry")
func apiUnbindIsReachableAndReturnsTheHole() async throws {
    let (registry, panes, _, paneId) = try await bindFixture()
    var draft = ApiDraft.empty
    draft.path = [.literal("/bookings/"), .slot("id")]
    await panes.setApiDraft(paneId: paneId, draft: draft)

    _ = try await registry.dispatch(
        name: "api_bind",
        params: .object([
            "pane": .string(paneId), "source": .string("db1"), "row": .number(0),
        ]),
        origin: .agent, environment: "staging", confirmation: nil)

    _ = try await registry.dispatch(
        name: "api_unbind",
        params: .object([
            "pane": .string(paneId), "region": .string("path"), "index": .number(1),
        ]),
        origin: .agent, environment: "staging", confirmation: nil)

    #expect(await panes.apiDraft(paneId: paneId).path == [.literal("/bookings/"), .slot("id")])
}

@Test("A bound value cannot be written back through api_set_request — the gesture is the only door")
func aBindingStillCannotBeAuthored() async throws {
    let (registry, panes, _, paneId) = try await bindFixture()

    await #expect(throws: (any Error).self) {
        _ = try await registry.dispatch(
            name: "api_set_request",
            params: .object([
                "pane": .string(paneId),
                "path": .array([
                    .object([
                        "name": .string("id"),
                        "binding": .string("live"),
                        "source": .object(["pane": .string("db1")]),
                    ])
                ]),
            ]),
            origin: .agent, environment: "staging", confirmation: nil)
    }
    #expect(await panes.apiDraft(paneId: paneId).path.isEmpty)
}

// MARK: - The bound-values strip

@Test("The strip indexes every region in wire order, and says where each value came from")
func theStripIndexesEveryRegionInWireOrder() async throws {
    let panes = store()
    await loadBookings(panes)
    let drop = try #require(await panes.dropSource(paneId: "db1", row: 0))

    var draft = ApiDraft.empty
    draft.path = [.literal("/bookings/"), .slot("id")]
    draft.query = [ApiQueryRow(name: "ref", value: [.slot("reference")])]
    draft.body = [.slot("guest")]
    let (filled, _) = try apiBind(
        draft: draft, source: drop, holes: ["id", "reference", "guest"], sources: [:])

    let request = ApiRequestSnapshot(
        method: "POST", origin: nil, path: filled.path, query: filled.query,
        headers: [], body: filled.body)
    let rows = apiBoundValues(in: request)

    // Wire order — path, query, headers, body — so the strip is an index
    // of the request rather than a second list free to disagree with it.
    #expect(rows.map(\.name) == ["id", "reference", "guest"])
    #expect(rows.map(\.region) == ["Path", "Query · ref", "Body"])
    #expect(rows.allSatisfy { $0.kind == "live" })
    #expect(rows[0].table == "bookings")
}

@Test("The strip states no age for a captured value, and never names the pane id")
func theStripStatesNoAgeAndNoPaneId() async throws {
    let panes = store()
    await loadBookings(panes, editable: false)
    let drop = try #require(await panes.dropSource(paneId: "db1", row: 0))

    var draft = ApiDraft.empty
    draft.path = [.slot("guest")]
    let (filled, _) = try apiBind(draft: draft, source: drop, holes: ["guest"], sources: [:])

    let rows = apiBoundValues(in: ApiRequestSnapshot(
        method: "GET", origin: nil, path: filled.path, query: [], headers: [], body: []))

    #expect(rows.count == 1)
    #expect(rows[0].kind == "captured")
    // #137 ruling 3: no age, no clock, no expiry — a number Wakil cannot
    // stand behind would read as a guarantee nothing checks.
    let line = try #require(apiBoundLines(rows).first)
    #expect(!line.contains("ago"))
    #expect(!line.contains(":"))
    // The operator does not know panes by id.
    #expect(!line.contains("db1"))
}

@Test("A draft with no bindings has an empty strip, and a header binding is indexed by its row")
func theStripCoversHeadersAndEmptiness() async throws {
    #expect(apiBoundValues(in: .empty).isEmpty)

    let panes = store()
    await loadBookings(panes)
    let drop = try #require(await panes.dropSource(paneId: "db1", row: 0))
    var draft = ApiDraft.empty
    draft.path = [.slot("guest")]
    let (filled, _) = try apiBind(draft: draft, source: drop, holes: ["guest"], sources: [:])

    let rows = apiBoundValues(in: ApiRequestSnapshot(
        method: "GET", origin: nil, path: [], query: [],
        headers: [ApiHeaderRegionRow(
            name: "x-guest", value: filled.path, provenance: nil, rowClass: .authored)],
        body: []))
    #expect(rows.map(\.region) == ["Header · x-guest"])
}

// MARK: - The footer that must not contradict the strip

/// Phase 1's gate asks that *"a source pane with a live value drawn out of
/// it stops claiming `read-only`"* (#192, spec story 44).
///
/// **It is structurally satisfied rather than separately implemented, and
/// this test is what keeps that true.** A live binding is only made from
/// an editable pane, and `editabilityLabel` reads the same
/// `PaneEditable?`, so a pane that yielded a live value cannot be drawing
/// `read-only`. The invariant is the tie between the two, and it would
/// break the moment someone let a live value out of a pane the driver
/// declined to make editable — which is why this asserts the tie rather
/// than the label.
@Test("A pane that yields a live value never draws read-only; one that yields captured does")
func aLiveSourceIsNotReadOnly() async throws {
    let panes = store()

    // Editable: binds live, and the footer says so.
    await loadBookings(panes, editable: true)
    let liveDrop = try #require(await panes.dropSource(paneId: "db1", row: 0))
    var draft = ApiDraft.empty
    draft.path = [.slot("guest")]
    let (live, _) = try apiBind(draft: draft, source: liveDrop, holes: ["guest"], sources: [:])
    guard case .bound(let liveValue)? = live.path.first else {
        Issue.record("the editable drop did not bind"); return
    }
    #expect(liveValue.binding == .live)
    #expect(editabilityLabel(await panes.editable(paneId: "db1")) != "read-only")

    // Not editable: the value is held, and the footer keeps its claim —
    // the two surfaces agree in both directions rather than one.
    let readOnly = PaneStore()
    await loadBookings(readOnly, editable: false)
    let heldDrop = try #require(await readOnly.dropSource(paneId: "db1", row: 0))
    let (captured, _) = try apiBind(
        draft: draft, source: heldDrop, holes: ["guest"], sources: [:])
    guard case .bound(let value)? = captured.path.first else {
        Issue.record("the drop did not bind"); return
    }
    if case .live = value.binding {
        Issue.record("a read-only pane yielded a LIVE value — the footer now contradicts the strip")
    }
    #expect(editabilityLabel(await readOnly.editable(paneId: "db1")) == "read-only")
}

// MARK: - The review's findings, each with the test that would have caught it

/// Decodes params the way a real MCP client's JSON arrives, rather than
/// hand-building `JSONValue` cases.
///
/// **This is the harness defect the review found.** `JSONValue.init(from:)`
/// tries `Int64` before `Double`, so `{"row": 0}` on the wire is
/// `.integer(0)` — and every test here built `.number(0)` by hand, which
/// no client ever sends. Both new actions were unreachable in production
/// while their tests passed.
private func wireParams(_ json: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
}

/// A value source pointing at `db1`, for the review-finding tests below.
private func bridgeSource(name: String, generation: Int) -> ApiValueSource {
    ApiValueSource(
        pane: "db1", table: "bookings", keyColumns: ["id"], keyValues: ["41"],
        column: name, declaredType: "TEXT", generation: generation)
}

@Test("An integer off the wire decodes as .integer, and both actions accept it")
func integersOffTheWireReachBothActions() async throws {
    let params = try wireParams(#"{"pane":"p","source":"db1","row":0}"#)
    guard case .object(let fields) = params else { Issue.record("not an object"); return }
    // The premise, asserted rather than assumed.
    guard case .integer = fields["row"] else {
        Issue.record("row decoded as \(String(describing: fields["row"])), expected .integer")
        return
    }

    let (registry, panes, _, paneId) = try await bindFixture()
    var draft = ApiDraft.empty
    draft.path = [.slot("id")]
    await panes.setApiDraft(paneId: paneId, draft: draft)

    _ = try await registry.dispatch(
        name: "api_bind",
        params: try wireParams(#"{"pane":"PANE","source":"db1","row":0}"#
            .replacingOccurrences(of: "PANE", with: paneId)),
        origin: .agent, environment: "staging", confirmation: nil)
    guard case .bound = await panes.apiDraft(paneId: paneId).path[0] else {
        Issue.record("api_bind did not bind from wire-decoded params"); return
    }

    _ = try await registry.dispatch(
        name: "api_unbind",
        params: try wireParams(#"{"pane":"PANE","region":"path","index":0}"#
            .replacingOccurrences(of: "PANE", with: paneId)),
        origin: .agent, environment: "staging", confirmation: nil)
    #expect(await panes.apiDraft(paneId: paneId).path == [.slot("id")])
}

@Test("A row index far beyond Int is refused, not trapped")
func anAbsurdRowIsRefusedRatherThanTrapping() async throws {
    let (registry, panes, _, paneId) = try await bindFixture()
    await panes.setApiDraft(paneId: paneId, draft: ApiDraft.empty)
    // `1e30` does decode as `.number`, and `Int(_:)` on it traps — which
    // would take the window down rather than refuse a bad call.
    await #expect(throws: (any Error).self) {
        _ = try await registry.dispatch(
            name: "api_bind",
            params: try wireParams(#"{"pane":"PANE","source":"db1","row":1e30}"#
                .replacingOccurrences(of: "PANE", with: paneId)),
            origin: .agent, environment: "staging", confirmation: nil)
    }
}

@Test("A drop is refused while the operator's cursor is in the draft — Decision 27 covers this door too")
func aDropIsRefusedUnderTheOperatorsHand() async throws {
    let (registry, panes, _, paneId) = try await bindFixture()
    var draft = ApiDraft.empty
    draft.path = [.slot("id")]
    await panes.setApiDraft(paneId: paneId, draft: draft)
    await panes.setApiFocus(paneId: paneId, fields: apiFocusMarks(.path), generation: 1)

    await #expect(throws: (any Error).self) {
        _ = try await registry.dispatch(
            name: "api_bind",
            params: .object([
                "pane": .string(paneId), "source": .string("db1"), "row": .integer(0),
            ]),
            origin: .agent, environment: "staging", confirmation: nil)
    }
    // The field under the operator's cursor is not rewritten, and the draft is untouched.
    #expect(await panes.apiDraft(paneId: paneId).path == [.slot("id")])
}

@Test("read_pane publishes a binding as resolving, not as one from a closed pane")
func readPaneResolvesAgainstThePanesOnScreen() async throws {
    let panes = store()
    await loadBookings(panes)
    let drop = try #require(await panes.dropSource(paneId: "db1", row: 0))
    var draft = ApiDraft.empty
    draft.path = [.slot("id")]
    let (filled, _) = try apiBind(draft: draft, source: drop, holes: ["id"], sources: [:])

    // What the server does: encode with the panes on screen.
    guard case .object(let part) = apiPartJSON(
        filled.path[0], sources: await panes.apiSources())
    else { Issue.record("not an object"); return }

    #expect(part["resolves"] == .bool(true))
    #expect(part["preview"] == .string("41"))
}

@Test("An open pane holding no result is a source that has not re-fetched, not a closed one")
func anEmptyOpenPaneIsNotAClosedPane() async throws {
    let panes = store()
    await loadBookings(panes)
    let drop = try #require(await panes.dropSource(paneId: "db1", row: 0))
    var draft = ApiDraft.empty
    draft.path = [.slot("id")]
    let (filled, _) = try apiBind(draft: draft, source: drop, holes: ["id"], sources: [:])

    // The pane is still open; its result is gone.
    await panes.setRows(
        paneId: "db1", columns: [], columnTypes: [], columnTypesInferred: false, rows: [],
        millis: 0, truncated: false, pageable: false, offset: 0, sort: [], listsTables: false,
        editable: nil)

    let sources = await panes.apiSources()
    #expect(sources["db1"] != nil)
    guard case .unresolved(let message, _) = resolvePart(filled.path[0], sources: sources) else {
        Issue.record("an emptied pane still resolved"); return
    }
    // It must not claim the pane is closed — it is open and has not
    // re-fetched, which is a different sentence and a different remedy.
    #expect(!message.contains("closed"))
}

@Test("A repointed fill-first binding stays fill-first, so unbind still removes it")
func aRepointKeepsNamedHole() async throws {
    let panes = store()
    await loadBookings(panes)
    let drop = try #require(await panes.dropSource(paneId: "db1", row: 0))

    var draft = ApiDraft.empty
    draft.path = [.bound(ApiBoundValue(
        name: "guest", binding: .captured(ApiHeldCell(token: .string("old"), declaredType: "TEXT")),
        source: bridgeSource(name: "guest", generation: 1),
        namedHole: false))]

    let (filled, _) = try apiBind(
        draft: draft, source: drop, holes: [], sources: await panes.apiSources())
    guard case .bound(let value) = filled.path[0] else { Issue.record("not repointed"); return }
    #expect(value.namedHole == false)
    // And so unbinding removes the part rather than inventing a hole.
    #expect(try apiUnbind(draft: filled, region: .path, index: 0).path.isEmpty)
}

@Test("A second row sharing a header name can be unbound, and the first is left alone")
func aDuplicateRowIsReachableByItsOwnIndex() async throws {
    let panes = store()
    await loadBookings(panes)
    let drop = try #require(await panes.dropSource(paneId: "db1", row: 0))
    var one = ApiDraft.empty
    one.path = [.slot("guest")]
    let (boundOne, _) = try apiBind(draft: one, source: drop, holes: ["guest"], sources: [:])

    var draft = ApiDraft.empty
    draft.headers = [
        ApiHeaderRow(name: "accept", value: boundOne.path),
        ApiHeaderRow(name: "accept", value: boundOne.path),
    ]

    let second = try apiUnbind(draft: draft, region: .header("accept"), index: 0, row: 1)
    #expect(second.headers[1].value == [.slot("guest")])
    // The first row is untouched — it was not the one pointed at.
    #expect(second.headers[0].value == boundOne.path)

    // A row index nobody has is refused rather than silently editing the first.
    #expect(throws: (any Error).self) {
        try apiUnbind(draft: draft, region: .header("accept"), index: 0, row: 5)
    }
}

@Test("A drop that only re-binds reports what it did, not an empty result")
func aPureRepointIsReported() async throws {
    let (registry, panes, _, paneId) = try await bindFixture()
    var draft = ApiDraft.empty
    // No holes left — every position is already bound, and dead. The
    // generation is deliberately one the pane has never been at: a capture
    // taken at the pane's CURRENT generation still resolves, and repointing
    // it would be the "overwrites a working binding" failure.
    draft.path = [.bound(ApiBoundValue(
        name: "guest",
        binding: .captured(ApiHeldCell(token: .string("old"), declaredType: "TEXT")),
        source: bridgeSource(name: "guest", generation: 99)))]
    await panes.setApiDraft(paneId: paneId, draft: draft)

    let result = try await registry.dispatch(
        name: "api_bind",
        params: .object([
            "pane": .string(paneId), "source": .string("db1"), "row": .integer(0),
        ]),
        origin: .agent, environment: "staging", confirmation: nil)

    guard case .object(let fields) = result else { Issue.record("no object"); return }
    // Without `rebound` this is byte-identical to a call that did nothing,
    // while the draft changed under the caller.
    #expect(fields["filled"] == .number(0))
    #expect(fields["rebound"] == .number(1))
}

// MARK: - The window's drop

private struct DropBridgeLookup: ProviderCredentialsLookup {
    func credentials(forProvider id: String) async throws -> ProviderCredentials {
        ProviderCredentials(
            claudePath: "/usr/bin/true", configDir: "/dev/null", oauthToken: "test-only")
    }
}

/// A window over the bind fixture's own registry, panes and layout — so a drop through
/// the window and a dispatch from a test land in one draft.
@MainActor
private func dropWindow() async throws -> (WindowModel, PaneStore, String) {
    let (registry, panes, layout, paneId) = try await bindFixture()
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: NSTemporaryDirectory(), providerId: "main", lookup: DropBridgeLookup())
    return (model, panes, paneId)
}

@Test("The window's drop binds through api_bind, keeps its counts, and redraws the pane")
@MainActor
func theWindowsDropKeepsWhatApiBindSaid() async throws {
    let (model, panes, paneId) = try await dropWindow()
    var draft = ApiDraft.empty
    draft.path = [.literal("/bookings/"), .slot("id")]
    draft.body = [.slot("nonesuch")]
    await panes.setApiDraft(paneId: paneId, draft: draft)

    let outcome = await model.bindFromSurface(pane: paneId, source: "db1", row: 1)

    guard case .result(let result) = outcome else {
        Issue.record("the drop was refused: \(outcome)"); return
    }
    #expect(apiBindSummary(outcome) == ApiBindLine(
        text: "Filled id from bookings · row 2 · no column for nonesuch", caution: false))
    guard case .object(let fields) = result else { Issue.record("no object"); return }
    #expect(fields["filled"]?.intValue == 1)
    // Row 1, not row 0: the row the operator picked up.
    guard case .bound(let id)? = await panes.apiDraft(paneId: paneId).path.last else {
        Issue.record("the hole was not filled"); return
    }
    #expect(id.source.keyValues == ["42"])
    // `refreshPanes` ran: the window's own snapshot already shows the binding.
    guard case .bound? = model.api(paneId)?.request.path.last else {
        Issue.record("the window did not redraw the pane"); return
    }
    // The line is the pane's; the window-wide status says nothing.
    #expect(model.status == "")
}

@Test("A refused drop comes back in its own words, and not on the window's status line")
@MainActor
func aRefusedDropIsThePanesToSay() async throws {
    let (model, panes, paneId) = try await dropWindow()
    var draft = ApiDraft.empty
    draft.path = [.slot("id")]
    await panes.setApiDraft(paneId: paneId, draft: draft)

    let outcome = await model.bindFromSurface(pane: paneId, source: "db1", row: 99)

    guard case .refused(let message) = outcome else {
        Issue.record("a row the pane does not have was bound: \(outcome)"); return
    }
    #expect(message.contains("api_bind"))
    #expect(model.status == "")
    #expect(await panes.apiDraft(paneId: paneId).path == [.slot("id")])
}
