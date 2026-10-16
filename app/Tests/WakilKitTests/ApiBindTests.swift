import Testing
@testable import WakilKit

/// The drop — `api_bind` (#192), Phase 1 of the 2c-iv send-path plan.
///
/// **The plan's Task 1 sketches a `DBPaneSnapshot` and a `PaneAnchor`.
/// Neither exists**, and what the bind actually needs is split across
/// three shipped types: `ApiSourcePane` carries `columns`, `rows` and
/// `generation`; `PaneEditable` carries `table` and `keyColumns`; and
/// `PaneSnapshot` carries `columnTypes`. `ApiDropSource` is that
/// composition and nothing more — it is the drop's payload, named for
/// what it is rather than for a pane kind, because the gesture is "a row
/// was dropped" and not "a database was consulted".
///
/// **`keyValues` are read off the dropped ROW, never off `rowKeys`.**
/// `PaneEditable` is explicit that a `rowKey` is an opaque `WHERE`
/// predicate the driver rendered, and that Swift's only permitted
/// operations on one are to store, reorder and hand it back. A key
/// *value* is a different fact, and the row holds it — so the bind reads
/// `row[keyColumns]` and crosses it as text, which is what
/// `ApiValueSource.keyValues` already is and for the same #242 reason.

// MARK: - Fixtures

/// A bookings row as a db pane would hand it to a drop: keyed by `id`,
/// editable, so a value taken out of it binds `.live`.
private func bookingsDrop(
    generation: Int = 7, editable: Bool = true, row: [JSONValue]? = nil
) -> ApiDropSource {
    ApiDropSource(
        pane: "p3",
        table: "bookings",
        keyColumns: ["id"],
        columns: ["id", "reference", "guest"],
        columnTypes: ["INTEGER", "TEXT", "TEXT"],
        row: row ?? [.integer(41), .string("BK-41"), .string("Ada")],
        generation: generation,
        editable: editable)
}

/// The bound value at `part`, or `nil` when the part is not a binding.
/// The plan's sketch spells this `part.boundName`; it is a test affordance
/// rather than product surface, so it lives here.
private func boundName(_ part: ApiPart) -> String? {
    guard case .bound(let value) = part else { return nil }
    return value.name
}

private func bound(_ part: ApiPart) -> ApiBoundValue? {
    guard case .bound(let value) = part else { return nil }
    return value
}

// MARK: - Task 1

@Test("One drop fills every hole whose name exactly matches a column, and reports the miss once")
func oneDropFillsEveryExactMatch() throws {
    var draft = ApiDraft.empty
    draft.path = [.literal("/bookings/"), .slot("id"), .literal("/confirm")]
    draft.query = [ApiQueryRow(name: "ref", value: [.slot("reference")])]
    draft.headers = [ApiHeaderRow(name: "x-guest", value: [.slot("guest")])]
    draft.body = [.slot("guest"), .slot("nonesuch")]

    let (filled, missed) = try apiBind(
        draft: draft, source: bookingsDrop(),
        holes: ["id", "reference", "guest", "nonesuch"], sources: [:])

    // The miss is reported once, in the aggregate, and stays a hole.
    #expect(missed == ["nonesuch"])
    #expect(filled.body[1] == .slot("nonesuch"))

    // Every region is walked — path, query, headers and body alike.
    #expect(boundName(filled.path[1]) == "id")
    #expect(boundName(filled.query[0].value[0]) == "reference")
    #expect(boundName(filled.headers[0].value[0]) == "guest")
    #expect(boundName(filled.body[0]) == "guest")

    // Literals either side of a filled hole are untouched.
    #expect(filled.path[0] == .literal("/bookings/"))
    #expect(filled.path[2] == .literal("/confirm"))
}

@Test("A hole's own name selects its column, and the drop's column is discarded")
func eachHoleNamesItsOwnColumn() throws {
    var draft = ApiDraft.empty
    draft.path = [.slot("guest")]

    let (filled, missed) = try apiBind(
        draft: draft, source: bookingsDrop(), holes: ["guest"], sources: [:])

    #expect(missed.isEmpty)
    // The drop landed on a row, not on a cell: `guest` is bound because the
    // HOLE says `guest`, whatever column the pointer happened to be over.
    #expect(bound(filled.path[0])?.source.column == "guest")
}

@Test("A binding pins the source pane's generation and the column's declared type at bind time")
func bindingPinsGenerationAndDeclaredType() throws {
    var draft = ApiDraft.empty
    draft.path = [.slot("reference")]

    let (filled, _) = try apiBind(
        draft: draft, source: bookingsDrop(generation: 7), holes: ["reference"], sources: [:])

    let value = try #require(bound(filled.path[0]))
    #expect(value.source.generation == 7)
    #expect(value.source.declaredType == "TEXT")
    #expect(value.source.pane == "p3")
    #expect(value.source.table == "bookings")
}

@Test("Key values are read off the dropped row and cross as text")
func keyValuesComeFromTheRowAsText() throws {
    var draft = ApiDraft.empty
    draft.path = [.slot("reference")]

    let (filled, _) = try apiBind(
        draft: draft, source: bookingsDrop(), holes: ["reference"], sources: [:])

    let value = try #require(bound(filled.path[0]))
    #expect(value.source.keyColumns == ["id"])
    // 41 is an INTEGER in the row and "41" in the binding — a key above
    // 2^53 cannot cross as a number (#242), so every key crosses as text.
    #expect(value.source.keyValues == ["41"])
}

@Test("An editable source binds live; one that is not binds captured, holding the cell")
func editabilityDecidesLiveOrCaptured() throws {
    var draft = ApiDraft.empty
    draft.path = [.slot("reference")]

    let (live, _) = try apiBind(
        draft: draft, source: bookingsDrop(editable: true), holes: ["reference"], sources: [:])
    #expect(bound(live.path[0])?.binding == .live)

    let (captured, _) = try apiBind(
        draft: draft, source: bookingsDrop(editable: false), holes: ["reference"], sources: [:])
    #expect(
        bound(captured.path[0])?.binding
            == .captured(ApiHeldCell(token: .string("BK-41"), declaredType: "TEXT")))
}

// MARK: - Task 2

/// The source pane the bindings below point at: one row, keyed by `id`.
private func bookingsPane(generation: Int = 7) -> ApiSourcePane {
    ApiSourcePane(
        columns: ["id", "guest"],
        rows: [[.integer(99), .string("Grace")]],
        generation: generation)
}

/// A capture taken at a generation the pane has since moved past — dead by
/// `resolvePart`'s own rule, because a capture lives exactly as long as
/// the rows it came from.
private func deadBinding(name: String) -> ApiBoundValue {
    ApiBoundValue(
        name: name,
        binding: .captured(ApiHeldCell(token: .string("stale"), declaredType: "TEXT")),
        source: valueSource(name: name, generation: 1))
}

@Test("A drop re-binds a binding that does not resolve, and leaves a working one alone")
func aDropRebindsOnlyTheDead() throws {
    var draft = ApiDraft.empty
    draft.path = [
        .literal("/b/"), .bound(deadBinding(name: "id")),
        .literal("/"), .bound(liveBinding(name: "guest")),
    ]

    let pane = bookingsPane(generation: 7)
    // Both bindings are checked before the drop lands, so the premise of
    // this test is itself asserted rather than assumed.
    #expect(!resolvePart(draft.path[1], sources: ["p3": pane]).isResolved)
    #expect(resolvePart(draft.path[3], sources: ["p3": pane]).isResolved)

    let (filled, missed) = try apiBind(
        draft: draft,
        source: ApiDropSource(
            pane: "p3", table: "bookings", keyColumns: ["id"], columns: ["id", "guest"],
            columnTypes: ["INTEGER", "TEXT"], row: [.integer(99), .string("Grace")],
            generation: 7, editable: true),
        holes: [], sources: ["p3": pane])

    #expect(missed.isEmpty)
    // The dead one is repointed at the dropped row — its generation moves
    // to the pane's.
    #expect(bound(filled.path[1])?.source.generation == 7)
    #expect(bound(filled.path[1])?.binding == .live)
    // The live one is untouched. Silently repointing a working binding is
    // the opposite failure, so its generation must not move.
    #expect(bound(filled.path[3])?.source.generation == 3)
    #expect(filled.path[3] == .bound(liveBinding(name: "guest")))
}

@Test("A dead binding the dropped row has no column for is left alone, not cleared")
func aDeadBindingTheDropCannotFillKeepsItsOrigin() throws {
    var draft = ApiDraft.empty
    draft.path = [.bound(deadBinding(name: "nosuchcolumn"))]

    let pane = bookingsPane(generation: 7)
    let (filled, missed) = try apiBind(
        draft: draft,
        source: ApiDropSource(
            pane: "p3", table: "bookings", keyColumns: ["id"], columns: ["id", "guest"],
            columnTypes: ["INTEGER", "TEXT"], row: [.integer(99), .string("Grace")],
            generation: 7, editable: true),
        holes: [], sources: ["p3": pane])

    // #112: a bound value whose row is gone keeps its origin rather than
    // degrading into a clean hole — so an unfillable dead binding stays
    // exactly as it was, still nameable in the refusal.
    #expect(missed.isEmpty)
    #expect(filled.path[0] == .bound(deadBinding(name: "nosuchcolumn")))
}

// MARK: - Task 3

/// A binding made by dropping on an empty position — it filled no hole, so
/// there is no name for an unbind to return to.
private func fillFirstBinding(generation: Int = 1) -> ApiBoundValue {
    ApiBoundValue(
        name: "guest", binding: .live,
        source: valueSource(name: "guest", generation: generation),
        namedHole: false)
}

@Test("Unbind returns a named hole to a hole and deletes a fill-first binding")
func unbindDistinguishesTheTwoCases() throws {
    var named = ApiDraft.empty
    named.path = [.literal("/b/"), .bound(liveBinding(name: "id", generation: 1))]
    #expect(
        try apiUnbind(draft: named, region: .path, index: 1).path
            == [.literal("/b/"), .slot("id")])

    var fillFirst = ApiDraft.empty
    fillFirst.path = [.literal("/b/"), .bound(fillFirstBinding(generation: 1))]
    #expect(try apiUnbind(draft: fillFirst, region: .path, index: 1).path == [.literal("/b/")])
}

@Test("Unbind reaches every region, and addresses a query or header row by name")
func unbindReachesEveryRegion() throws {
    var draft = ApiDraft.empty
    draft.query = [
        ApiQueryRow(name: "ref", value: [.bound(liveBinding(name: "reference", generation: 1))]),
        ApiQueryRow(name: "other", value: [.slot("untouched")]),
    ]
    draft.headers = [ApiHeaderRow(name: "x-guest", value: [.bound(liveBinding(name: "guest", generation: 1))])]
    draft.body = [.bound(liveBinding(name: "total", generation: 1))]

    let unQuery = try apiUnbind(draft: draft, region: .query("ref"), index: 0)
    #expect(unQuery.query[0].value == [.slot("reference")])
    // The row that was not named is untouched.
    #expect(unQuery.query[1].value == [.slot("untouched")])

    let unHeader = try apiUnbind(draft: draft, region: .header("x-guest"), index: 0)
    #expect(unHeader.headers[0].value == [.slot("guest")])

    let unBody = try apiUnbind(draft: draft, region: .body, index: 0)
    #expect(unBody.body == [.slot("total")])
}

@Test("Unbind refuses a position that is out of range or holds no binding")
func unbindRefusesWhatItCannotUnbind() throws {
    var draft = ApiDraft.empty
    draft.path = [.literal("/b/"), .slot("id")]

    // Out of range: the pane and the draft disagree about the shape of the
    // region, and guessing which is right would remove the wrong part.
    #expect(throws: (any Error).self) {
        try apiUnbind(draft: draft, region: .path, index: 9)
    }
    // A literal and a hole are not bindings. Refusing says so rather than
    // silently succeeding and leaving the operator's gesture unexplained.
    #expect(throws: (any Error).self) {
        try apiUnbind(draft: draft, region: .path, index: 0)
    }
    #expect(throws: (any Error).self) {
        try apiUnbind(draft: draft, region: .path, index: 1)
    }
    // A query row the draft does not hold.
    #expect(throws: (any Error).self) {
        try apiUnbind(draft: draft, region: .query("nosuchrow"), index: 0)
    }
}

@Test("apiBind marks what it fills as a named hole, so unbind can give the name back")
func bindMarksTheHolesItFilled() throws {
    var draft = ApiDraft.empty
    draft.path = [.slot("reference")]

    let (filled, _) = try apiBind(
        draft: draft, source: bookingsDrop(), holes: ["reference"], sources: [:])

    #expect(bound(filled.path[0])?.namedHole == true)
    #expect(try apiUnbind(draft: filled, region: .path, index: 0).path == [.slot("reference")])
}

// MARK: - Task 4, the encoder half

/// **These do not follow a red-then-green cycle, and saying so is the
/// point.** #190 built the bound-value encoder ahead of #192 — its own
/// comment says `sources` exists "so that the encoder #190 writes is the
/// one #192 fills, rather than one that ticket has to rewrite" — and it
/// noted that `sources` is "empty in every snapshot this build can
/// produce", because nothing could make a binding. `apiBind` can. So the
/// encoder is not written here; it is *exercised with a real binding for
/// the first time*, which is what the plan's Task 4 actually owes.

@Test("read_pane gives a bound value full provenance, and preview rather than value")
func readPanePublishesProvenance() throws {
    var draft = ApiDraft.empty
    draft.path = [.literal("/bookings/"), .slot("id")]
    let (filled, _) = try apiBind(
        draft: draft, source: bookingsDrop(), holes: ["id"], sources: [:])

    let pane = ApiSourcePane(
        columns: ["id", "reference", "guest"],
        rows: [[.integer(41), .string("BK-41"), .string("Ada")]],
        generation: 7)
    guard case .object(let part) = apiPartJSON(filled.path[1], sources: ["p3": pane]),
        case .object(let source)? = part["source"]
    else {
        Issue.record("a bound part did not serialise to an object with a source"); return
    }

    #expect(source["pane"] == .string("p3"))
    #expect(source["table"] == .string("bookings"))
    #expect(source["keyColumns"] == .array([.string("id")]))
    #expect(source["keyValues"] == .array([.string("41")]))
    #expect(source["column"] == .string("id"))
    #expect(part["binding"] == .string("live"))

    // `preview`, never `value` — what the source holds now, not what will
    // be sent.
    #expect(part["preview"] == .string("41"))
    #expect(part["value"] == nil)
    #expect(part["resolves"] == .bool(true))

    // **Neither is published**, and #184/#137 are why: both are pinned at
    // bind time for resolution's own use, neither is on the operator's
    // screen, and publishing them would invite a reader to write them back.
    #expect(source["declaredType"] == nil)
    #expect(source["generation"] == nil)
}

@Test("An unbound slot has its own shape, so a hole never reads as a binding that failed")
func anUnboundSlotIsItsOwnShape() {
    guard case .object(let slot) = apiPartJSON(.slot("id"), sources: [:]) else {
        Issue.record("a slot did not serialise to an object"); return
    }
    #expect(slot == ["slot": .string("id")])
    // The discriminators a binding carries are absent entirely — a reader
    // tells the two apart by shape rather than by a false `resolves`.
    #expect(slot["resolves"] == nil)
    #expect(slot["binding"] == nil)
}

@Test("A binding whose source pane has moved on publishes resolves:false and what was available")
func aDeadBindingPublishesWhyAndWhatIsThere() throws {
    let stale = ApiSourcePane(
        columns: ["id", "guest"], rows: [[.integer(99), .string("Grace")]], generation: 9)

    guard case .object(let part) = apiPartJSON(
        .bound(deadBinding(name: "id")), sources: ["p3": stale])
    else {
        Issue.record("a bound part did not serialise to an object"); return
    }
    // The capture was taken at generation 1 and the pane is at 9: those
    // rows are gone, so the value is too.
    #expect(part["resolves"] == .bool(false))
    #expect(part["preview"] == .null)
    // #112: it keeps its origin rather than degrading into a clean hole,
    // so the strip can still say what was lost.
    guard case .object(let source)? = part["source"] else {
        Issue.record("a dead binding published no source"); return
    }
    #expect(source["table"] == .string("bookings"))
}

@Test("W17: a binary column is refused at the drop, naming it")
func aBinaryColumnIsRefusedAtTheDrop() {
    let source = ApiDropSource(
        pane: "db-1", table: "t", keyColumns: ["id"], columns: ["id", "k"],
        columnTypes: ["INTEGER", "VARBINARY"], row: [.integer(1), .string("\u{FFFD}")],
        generation: 1, editable: true)
    var draft = ApiDraft.empty
    draft.path = [.literal("/x/"), .slot("k")]
    let thrown = #expect(throws: ApiActionError.self) {
        _ = try apiBind(draft: draft, source: source, holes: ["k"], sources: [:])
    }
    #expect(String(describing: thrown!).contains(
        "k is a VARBINARY column — binary values arrive corrupted, so they can't be bound"))
}

@Test("A binary column no hole names does not stop the drop")
func aBinaryColumnNoHoleNamesIsIgnored() throws {
    let source = ApiDropSource(
        pane: "db-1", table: "t", keyColumns: ["id"], columns: ["id", "k"],
        columnTypes: ["INTEGER", "VARBINARY"], row: [.integer(1), .string("x")],
        generation: 1, editable: true)
    var draft = ApiDraft.empty
    draft.path = [.literal("/x/"), .slot("id")]
    let (bound, missed) = try apiBind(draft: draft, source: source, holes: ["id"], sources: [:])
    #expect(missed.isEmpty)
    guard case .bound = bound.path[1] else { Issue.record("not bound"); return }
}

@Test("F11: Mongo's lossless binary (a document token) is not given the corrupted sentence")
func aMongoBinaryIsNotRefusedAsCorrupted() throws {
    let source = ApiDropSource(
        pane: "db-1", table: "t", keyColumns: ["id"], columns: ["id", "k"],
        columnTypes: ["INTEGER", "BINARY"],
        row: [.integer(1), .object(["$binary": .string("3q2+7w==")])],
        generation: 1, editable: true)
    var draft = ApiDraft.empty
    draft.path = [.literal("/x/"), .slot("k")]
    _ = try apiBind(draft: draft, source: source, holes: ["k"], sources: [:])
}
