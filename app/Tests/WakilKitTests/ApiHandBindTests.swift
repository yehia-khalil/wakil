import Foundation
import Testing
@testable import WakilKit

/// The hand bind — the operator's half of G4 (#179 stories 31, 33–35).

private func request(path: [ApiPart], body: [ApiPart] = [],
                     query: [ApiQueryRow] = []) -> ApiRequestSnapshot {
    ApiRequestSnapshot(
        method: "POST", origin: nil, path: path, query: query,
        headers: ApiRequestSnapshot.empty.headers, body: body)
}

private func pathParts(_ json: JSONValue?) -> [JSONValue]? {
    guard case .object(let fields)? = json, case .array(let parts)? = fields["path"] else {
        return nil
    }
    return parts
}

@Test("A held field writes the whole field and carries its holes as slots")
func aLiteralCommitCarriesItsNeighbours() {
    let draft = request(path: [.literal("/v1/bookings/"), .slot("id"), .literal("/confirm")])
    let written = apiHeldWrite(
        draft: draft, field: .path,
        parts: [.literal("/v1/bookings/"), .slot("id"), .literal("/cancel")], pane: "api-1")
    #expect(pathParts(written) == [
        .object(["literal": .string("/v1/bookings/")]),
        .object(["slot": .string("id")]),
        .object(["literal": .string("/cancel")]),
    ])
}

@Test("A hole is written as its slot, and an empty literal after it is not written")
func appendingAHoleLeavesSomewhereToType() {
    let draft = request(path: [.literal("/v1/bookings/")])
    let written = apiHeldWrite(
        draft: draft, field: .path, parts: [.literal("/v1/bookings/"), .slot("id"), .literal("")],
        pane: "api-1")
    // The empty literal is not WRITTEN — an empty literal is not a wire state.
    #expect(pathParts(written) == [
        .object(["literal": .string("/v1/bookings/")]),
        .object(["slot": .string("id")]),
    ])
}

@Test("A hole's name is kept exactly as typed", arguments: [" id", "id ", "ID", "booking id"])
func aHoleNameIsKeptExactly(name: String) {
    let written = apiHeldWrite(
        draft: request(path: []), field: .path, parts: [.slot(name)], pane: "api-1")
    #expect(pathParts(written) == [.object(["slot": .string(name)])])
}

@Test("A blank hole name is refused before anything is dispatched", arguments: ["", "   ", "\t"])
func aBlankHoleNameIsRefused(name: String) {
    #expect(apiHoleNameRefused(name) == apiHoleNameRefusal)
}

@Test("An emptied literal between two holes is dropped, and both holes survive")
func anEmptiedLiteralBetweenHolesIsDropped() {
    let draft = request(path: [.slot("a"), .literal("-"), .slot("b")])
    let written = apiHeldWrite(
        draft: draft, field: .path, parts: [.slot("a"), .literal(""), .slot("b")], pane: "p")
    #expect(pathParts(written) == [
        .object(["slot": .string("a")]), .object(["slot": .string("b")]),
    ])
}

@Test("× on an unbound hole removes that part, and the text either side joins into one")
func removingAHoleRemovesOnlyIt() {
    // Final review I2: two literals left side by side were two boxes, and the caret a key's
    // remove put back landed after the second.
    let draft = request(path: [.literal("/x/"), .slot("id"), .literal("/y")])
    guard case .write(let written) = apiPendingWrite(
        draft, box: ApiFieldRow(.path), holding: [.literal("/x/"), .literal("/y")], pane: "p")
    else { Issue.record("the remove wrote nothing"); return }
    #expect(pathParts(written) == [.object(["literal": .string("/x//y")])])
}

@Test("A query row's value is written with the whole region, the row's holes carried")
func aQueryRowCarriesItsRegion() {
    let draft = request(path: [], query: [
        ApiQueryRow(name: "expand", value: [.literal("lines")]),
        ApiQueryRow(name: "id", value: [.slot("id")]),
    ])
    let written = apiHeldWrite(
        draft: draft, field: .query("expand"), parts: [.literal("guest")], pane: "p")
    guard case .object(let fields)? = written, case .array(let rows)? = fields["query"] else {
        Issue.record("no query region written"); return
    }
    #expect(rows.count == 2)
    #expect(rows[1] == .object(["name": .string("id"),
                                "value": .array([.object(["slot": .string("id")])])]))
}

@Test("W16: a bound value locks only itself — the field and its region stay typable")
func aBoundValueLocksOnlyItself() {
    let bound = ApiPart.bound(liveBinding(name: "id"))
    #expect(apiFieldIsTypable(request(path: [.literal("/b/"), bound]), .path))
    #expect(apiFieldIsTypable(request(path: [], body: [bound]), .body))
    let draft = request(path: [], query: [
        ApiQueryRow(name: "expand", value: [.literal("lines")]),
        ApiQueryRow(name: "id", value: [bound]),
    ])
    #expect(apiFieldIsTypable(draft, .query("expand")))
}

@Test("W16: a gesture beside a binding writes the field and carries the binding unchanged")
func aGestureBesideABindingCarriesIt() {
    let bound = liveBinding(name: "id")
    // The walk's case: an unfilled hole removed while the value beside it is bound.
    let draft = request(path: [.literal("/b/"), .bound(bound), .slot("v")])
    #expect(pathParts(apiHeldWrite(
        draft: draft, field: .path, parts: [.literal("/b/"), .bound(bound)], pane: "p"))
        == [.object(["literal": .string("/b/")]), apiPartJSON(.bound(bound), sources: [:])])
    let rows = request(path: [], query: [
        ApiQueryRow(name: "expand", value: [.literal("lines")]),
        ApiQueryRow(name: "id", value: [.bound(bound)]),
    ])
    guard case .object(let fields)? = apiHeldWrite(
        draft: rows, field: .query("expand"), parts: [.literal("guest")], pane: "p"),
        case .array(let written)? = fields["query"]
    else { Issue.record("no query region written"); return }
    #expect(written[1] == .object([
        "name": .string("id"), "value": .array([apiPartJSON(.bound(bound), sources: [:])]),
    ]))
}

private func row(_ id: Int, _ values: [JSONValue]) -> PaneRow {
    PaneRow(id: id, cells: values.map(PaneCell.init))
}

@Test("An unchanged row is the row picked up")
func anUnchangedRowDrops() {
    let rows = [row(0, [.integer(8842), .string("BK-2026-8842")]),
                row(1, [.integer(8843), .string("BK-2026-8843")])]
    #expect(apiDropRow(ApiDragPayload(pane: "db-1", row: rows[1]), current: rows) == 1)
}

@Test("A re-sort that put another row at the index is not the row picked up")
func aResortedRowIsNotTheRowPickedUp() {
    let before = [row(0, [.integer(8842)]), row(1, [.integer(8843)])]
    let after = [row(0, [.integer(8843)]), row(1, [.integer(8842)])]
    #expect(apiDropRow(ApiDragPayload(pane: "db-1", row: before[0]), current: after) == nil)
}

@Test("An index past the end refuses")
func anIndexPastTheEndRefuses() {
    let before = [row(0, [.integer(1)]), row(1, [.integer(2)])]
    #expect(apiDropRow(ApiDragPayload(pane: "db-1", row: before[1]),
                       current: [before[0]]) == nil)
}

@Test("A null is not an empty string")
func aNullIsNotAnEmptyString() {
    let picked = ApiDragPayload(pane: "db-1", row: row(0, [.null]))
    #expect(apiDropRow(picked, current: [row(0, [.string("")])]) == nil)
}

@Test("The result line", arguments: [
    (#"{"filled":2,"rebound":0,"unmatched":[]}"#, "Filled 2", false),
    (#"{"filled":2,"rebound":1,"unmatched":[]}"#, "Filled 2 · re-bound 1", false),
    (#"{"filled":1,"rebound":0,"unmatched":["booking_ref","guest"]}"#,
     "Filled 1 · no column for booking_ref, guest", false),
    (#"{"filled":0,"rebound":0,"unmatched":["id"]}"#, "No hole matches a column of this row", true),
    // Re-walk #6: what was filled, and from where — one line.
    (#"{"filled":1,"rebound":0,"unmatched":[],"filledNames":["id"],"source":"db-17","table":"events","row":0}"#,
     "Filled id from events · row 1", false),
    (#"{"filled":3,"rebound":1,"unmatched":["guest"],"filledNames":["id","name"],"source":"db-2","table":"","row":4}"#,
     "Filled id, name from db-2 · row 5 · re-bound 1 · no column for guest", false),
    // Review minors: a join names the source pane by its title, and a drop that only re-bound
    // says so rather than "Filled 0".
    (#"{"filled":1,"rebound":0,"unmatched":[],"filledNames":["id"],"source":"db-2","sourceTitle":"bookings ⋈ guests","table":"","row":0}"#,
     "Filled id from bookings ⋈ guests · row 1", false),
    (#"{"filled":0,"rebound":2,"unmatched":[],"filledNames":[],"source":"db-17","table":"events","row":2}"#,
     "Re-bound 2 from events · row 3", false),
    (#"{"filled":0,"rebound":2,"unmatched":[]}"#, "Re-bound 2", false),
])
func theResultLine(json: String, text: String, caution: Bool) throws {
    let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    #expect(apiBindSummary(.result(value)) == ApiBindLine(text: text, caution: caution))
}

@Test("A refusal is drawn in its own words")
func aRefusalIsItsOwnWords() {
    #expect(apiBindSummary(.refused("api_bind: no such row")).text == "api_bind: no such row")
}

@Test("Each field names the region api_unbind reads it as", arguments: [
    (ApiDraftField.path, "path", nil as String?, ApiRegion.path),
    (ApiDraftField.body, "body", nil as String?, ApiRegion.body),
    (ApiDraftField.query("expand"), "query", "expand" as String?, ApiRegion.query("expand")),
    (ApiDraftField.header("x-trace"), "header", "x-trace" as String?, ApiRegion.header("x-trace")),
])
func aFieldNamesItsUnbindRegion(
    field: ApiDraftField, name: String, row: String?, region: ApiRegion
) {
    #expect(apiRegionName(field) == name)
    // The handler's own parser is the other half: a name it does not read back is a refusal.
    #expect(apiRegion(named: name, row: row) == region)
}

@Test("The two fields that hold no parts name no region")
func aPartlessFieldNamesNoRegion() {
    #expect(apiRegionName(.method) == nil)
    #expect(apiRegionName(.contentType) == nil)
    #expect(apiUnbindParams(field: .contentType, index: 0, pane: "api-1") == nil)
}

@Test("A path chip's × unbinds by region and index")
func aPathUnbindNamesNoRow() {
    #expect(apiUnbindParams(field: .path, index: 1, pane: "api-1") == .object([
        "pane": .string("api-1"), "region": .string("path"), "index": .integer(1),
    ]))
}

@Test("A row chip's × names its row, which api_unbind refuses without")
func aRowUnbindNamesItsRow() {
    #expect(apiUnbindParams(field: .query("id"), index: 0, pane: "api-1") == .object([
        "pane": .string("api-1"), "region": .string("query"), "name": .string("id"),
        "index": .integer(0),
    ]))
}

@Test("A blank hole name is refused in these words")
func theBlankHoleRefusalReads() {
    #expect(apiHoleNameRefusal == "a hole needs a name")
}

// MARK: - Every box of a field is one field (fix round 1)

@Test("Committing one box carries another box's uncommitted text in the same write")
func aCommitCarriesTheOtherBoxes() {
    let draft = request(path: [.literal("/v1/bookings/"), .slot("id"), .literal("/confirm")])
    let written = apiHeldWrite(
        draft: draft, field: .path,
        parts: [.literal("/v2/bookings/"), .slot("id"), .literal("/cancel")], pane: "api-1")
    #expect(pathParts(written) == [
        .object(["literal": .string("/v2/bookings/")]),
        .object(["slot": .string("id")]),
        .object(["literal": .string("/cancel")]),
    ])
}

@Test("+ hole carries the trailing box's text ahead of the new hole")
func aHoleCarriesTheTrailingText() {
    let draft = request(path: [.literal("/v1/bookings/"), .slot("id")])
    let written = apiHeldWrite(
        draft: draft, field: .path,
        parts: [.literal("/v1/bookings/"), .slot("id"), .literal("/"), .slot("action")],
        pane: "api-1")
    #expect(pathParts(written) == [
        .object(["literal": .string("/v1/bookings/")]),
        .object(["slot": .string("id")]),
        .object(["literal": .string("/")]),
        .object(["slot": .string("action")]),
    ])
}

@Test("Removing a hole carries an emptied box as removed, and indices name the draft's parts")
func aRemoveCarriesTypedText() {
    let draft = request(path: [.literal("/a/"), .slot("id"), .literal("/b")])
    // The first literal emptied, the last edited, then the hole removed.
    let written = apiHeldWrite(
        draft: draft, field: .path, parts: [.literal(""), .literal("/c")], pane: "api-1")
    #expect(pathParts(written) == [.object(["literal": .string("/c")])])
}

@Test("A drop whose row moved says so once, in caution's colour, in the refusal's own words")
func aMovedRowIsTheCautionLine() {
    #expect(apiDropMovedLine == ApiBindLine(text: apiDropMovedRefusal, caution: true))
}

// MARK: - Same-named rows are each their own field (final review, Important 2)

private func authored(_ name: String, _ value: [ApiPart]) -> ApiHeaderRegionRow {
    ApiHeaderRegionRow(name: name, value: value, provenance: nil, rowClass: .authored)
}

private func twoAccepts(_ second: [ApiPart] = [.literal("text/csv")]) -> ApiRequestSnapshot {
    ApiRequestSnapshot(
        method: "GET", origin: nil, path: [], query: [],
        headers: [authored("accept", [.literal("application/json")]), authored("accept", second)]
            + ApiRequestSnapshot.empty.headers,
        body: [])
}

@Test("Two header rows sharing a name each draw their own parts")
func sameNamedHeaderRowsDrawTheirOwnParts() {
    let request = twoAccepts()
    #expect(apiFieldParts(request, .header("accept")) == [.literal("application/json")])
    #expect(apiFieldParts(request, .header("accept"), row: 0) == [.literal("application/json")])
    #expect(apiFieldParts(request, .header("accept"), row: 1) == [.literal("text/csv")])
    #expect(apiFieldParts(request, .header("accept"), row: 2) == [])
}

@Test("Two query rows sharing a name each draw their own parts")
func sameNamedQueryRowsDrawTheirOwnParts() {
    let request = request(path: [], query: [
        ApiQueryRow(name: "tag", value: [.literal("a")]),
        ApiQueryRow(name: "page", value: [.literal("1")]),
        ApiQueryRow(name: "tag", value: [.literal("b")]),
    ])
    #expect(apiFieldParts(request, .query("tag"), row: 1) == [.literal("b")])
    #expect(apiRowOccurrence(request, .query("tag"), at: 2) == 1)
    #expect(apiRowOccurrence(request, .query("page"), at: 1) == 0)
    #expect(apiRowOccurrence(request, .query("tag"), at: 0) == 0)
}

@Test("A header row's occurrence counts only the operator's rows of that exact name")
func aHeaderOccurrenceCountsTheOperatorsRows() {
    let request = twoAccepts()
    #expect(apiRowOccurrence(request, .header("accept"), at: 0) == 0)
    #expect(apiRowOccurrence(request, .header("accept"), at: 1) == 1)
}

@Test("A write to the second same-named header row leaves the first untouched")
func aWriteToRowTwoLeavesRowOne() {
    let written = apiHeldWrite(
        draft: twoAccepts(), field: .header("accept"), parts: [.literal("text/plain")],
        pane: "p", row: 1)
    guard case .object(let fields)? = written, case .array(let rows)? = fields["headers"] else {
        Issue.record("no header region written"); return
    }
    #expect(rows == [
        .object(["name": .string("accept"),
                 "value": .array([.object(["literal": .string("application/json")])])]),
        .object(["name": .string("accept"),
                 "value": .array([.object(["literal": .string("text/plain")])])]),
    ])
}

// MARK: - Fix round 1: apiDraftForWrite never carries Wakil's own derived rows as the operator's

@Test("Editing a header row never carries Wakil's own content-type row along")
func editingAHeaderRowExcludesContentType() {
    let draft = ApiRequestSnapshot(
        method: "GET", origin: nil, path: [], query: [],
        headers: [authored("x-a", [.literal("1")])]
            + apiWakilHeaderRows(entry: "", contentType: "application/json", credentialed: false),
        body: [])
    let written = apiHeldWrite(
        draft: draft, field: .header("x-a"), parts: [.literal("2")], pane: "p")
    guard case .object(let fields)? = written, case .array(let rows)? = fields["headers"] else {
        Issue.record("no header region written"); return
    }
    #expect(rows == [
        .object(["name": .string("x-a"), "value": .array([.object(["literal": .string("2")])])]),
    ])
}

@Test("A write to the second same-named query row leaves the first untouched")
func aQueryWriteToRowTwoLeavesRowOne() {
    let draft = request(path: [], query: [
        ApiQueryRow(name: "tag", value: [.literal("a")]),
        ApiQueryRow(name: "tag", value: [.literal("b")]),
    ])
    let written = apiHeldWrite(
        draft: draft, field: .query("tag"), parts: [.literal("c"), .slot("id")], pane: "p",
        row: 1)
    guard case .object(let fields)? = written, case .array(let rows)? = fields["query"] else {
        Issue.record("no query region written"); return
    }
    #expect(rows == [
        .object(["name": .string("tag"), "value": .array([.object(["literal": .string("a")])])]),
        .object(["name": .string("tag"), "value": .array([
            .object(["literal": .string("c")]), .object(["slot": .string("id")]),
        ])]),
    ])
}

@Test("The second same-named row's unbind names its row; the first's does not need to")
func aSecondRowsUnbindCarriesItsRow() {
    #expect(apiUnbindParams(field: .header("accept"), index: 0, pane: "api-1", row: 1)
        == .object([
            "pane": .string("api-1"), "region": .string("header"), "name": .string("accept"),
            "index": .integer(0), "row": .integer(1),
        ]))
    #expect(apiUnbindParams(field: .header("accept"), index: 0, pane: "api-1", row: 0)
        == apiUnbindParams(field: .header("accept"), index: 0, pane: "api-1"))
}

@Test("The second row's unbind params reach the second row through api_unbind's own parser")
func aSecondRowsUnbindReachesIt() throws {
    let bound = ApiPart.bound(liveBinding(name: "id"))
    var draft = ApiDraft.empty
    draft.headers = [ApiHeaderRow(name: "accept", value: [bound]),
                     ApiHeaderRow(name: "accept", value: [bound])]
    let params = try #require(
        apiUnbindParams(field: .header("accept"), index: 0, pane: "p", row: 1))
    guard case .object(let fields) = params else { Issue.record("not an object"); return }
    let unbound = try apiUnbind(
        draft: draft, region: .header("accept"), index: 0, row: fields["row"]?.intValue)
    #expect(unbound.headers[0].value == [bound])
    #expect(unbound.headers[1].value == [.slot("id")])
}

@Test("A shipped field keeps its identifier; a second same-named row takes a disjoint one")
func aSecondRowsKeyIsDisjoint() {
    #expect(apiFieldKey(.path, row: 0) == "path")
    #expect(apiFieldKey(.body, row: 0) == "body")
    #expect(apiFieldKey(.query("page"), row: 0) == "query.page")
    #expect(apiFieldKey(.header("accept"), row: 0) == "header.accept")
    #expect(apiFieldKey(.header("accept"), row: 1) == "header[1].accept")
    #expect(apiFieldKey(.query("ids[]"), row: 2) == "query[2].ids[]")
    // A row literally named `accept.1` stays on the ordinary family, never the bracketed one.
    #expect(apiFieldKey(.header("accept.1"), row: 0) != apiFieldKey(.header("accept"), row: 1))
}

@Test("W16: a bound header row locks only its own value")
func aBoundHeaderLocksOnlyItself() {
    let bound = ApiPart.bound(liveBinding(name: "id"))
    let request = ApiRequestSnapshot(
        method: "GET", origin: nil, path: [.literal("/x")], query: [],
        headers: [authored("accept", [.literal("a")]), authored("x-id", [bound])]
            + ApiRequestSnapshot.empty.headers,
        body: [])
    #expect(apiFieldIsTypable(request, .header("accept")))
    #expect(apiFieldIsTypable(request, .header("x-id")))
}

// MARK: - Task 5: the body is an editor (Amendment 8c)

@Test("A GET sends through api_request, the typed body still written first")
func aReadSendsThroughApiRequest() {
    let draft = ApiRequestSnapshot(
        method: "GET", origin: nil, path: [], query: [],
        headers: ApiRequestSnapshot.empty.headers, body: [])
    #expect(apiSendPlan(draft: draft, pane: "p", held: [ApiFieldRow(.body): [.literal("x")]])
        .calls.map(\.0)
        == ["api_set_request", "api_request"])
}

@Test("W16: Send flushes a body beside a binding and carries the binding as published")
func sendFlushesABodyBesideABinding() {
    let bound = liveBinding(name: "id")
    let draft = request(path: [], body: [.literal("{\"id\":"), .bound(bound)])
    let calls = apiSendPlan(
        draft: draft, pane: "p", held: [ApiFieldRow(.body): [.literal("{\"x\":"), .bound(bound)]])
        .calls
    #expect(calls.map(\.0) == ["api_set_request", "api_send"])
    #expect(calls.first?.1 == .object(["pane": .string("p"), "body": .array([
        .object(["literal": .string("{\"x\":")]), apiPartJSON(.bound(bound), sources: [:]),
    ])]))
}

@Test("Format writes the body re-indented, its typed text composed in first")
func formatWritesTheTypedBody() {
    let draft = request(path: [], body: [.literal(#"{"z":1}"#)])
    #expect(apiFormatBodyWrite(draft: draft, pane: "p", holding: draft.body) == .object([
        "pane": .string("p"),
        "body": .array([.object(["literal": .string("{\n  \"z\": 1\n}")])]),
    ]))
    #expect(apiFormatBodyWrite(draft: draft, pane: "p", holding: [.literal("[1,2]")]) == .object([
        "pane": .string("p"),
        "body": .array([.object(["literal": .string("[\n  1,\n  2\n]")])]),
    ]))
    // A hole is carried as its slot, the text around it formatted.
    let holed = request(path: [], body: [.literal(#"{"id":"#), .slot("id"), .literal("}")])
    #expect(apiFormatBodyWrite(draft: holed, pane: "p", holding: holed.body) == .object([
        "pane": .string("p"),
        "body": .array([
            .object(["literal": .string("{\n  \"id\": ")]), .object(["slot": .string("id")]),
            .object(["literal": .string("\n}")]),
        ]),
    ]))
}

@Test("Format on a body that is not JSON writes nothing")
func formatRefusesNotJSON() {
    let draft = request(path: [], body: [.literal("{")])
    #expect(apiFormatBodyWrite(draft: draft, pane: "p", holding: draft.body) == nil)
    #expect(apiFormatBodyWrite(draft: draft, pane: "p", holding: [.literal("{\"a\":}")]) == nil)
}

@Test("Format is live over a body, typed or committed, a bound one too, and not an empty one")
func formatIsLiveOverABody() {
    #expect(!apiFormatIsEnabled(draft: request(path: []), holding: []))
    #expect(!apiFormatIsEnabled(draft: request(path: []), holding: [.literal("")]))
    #expect(apiFormatIsEnabled(draft: request(path: []), holding: [.literal("{}")]))
    #expect(apiFormatIsEnabled(
        draft: request(path: [], body: [.literal("{}")]), holding: [.literal("{}")]))
    // Emptied by typing is empty.
    #expect(!apiFormatIsEnabled(
        draft: request(path: [], body: [.literal("{}")]), holding: [.literal("")]))
    // W16: a binding is one opaque value token, and Format carries it.
    let bound = liveBinding(name: "id")
    let body = request(path: [], body: [.literal("{\"a\": "), .bound(bound), .literal("}")])
    #expect(apiFormatIsEnabled(draft: body, holding: body.body))
    guard case .object(let fields)? = apiFormatBodyWrite(draft: body, pane: "p", holding: body.body),
          case .array(let written)? = fields["body"]
    else { Issue.record("Format wrote nothing"); return }
    #expect(written.contains(apiPartJSON(.bound(bound), sources: [:])))
}
