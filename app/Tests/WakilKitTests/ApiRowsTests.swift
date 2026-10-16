import Foundation
import Testing
@testable import WakilKit

/// Amendment 8b: + query, + header, and × on a row.

private func draft(
    query: [ApiQueryRow] = [], headers: [(String, [ApiPart])] = [], contentType: String = ""
) -> ApiRequestSnapshot {
    var rows = apiWakilHeaderRows(entry: "", contentType: contentType, credentialed: false)
    rows.append(contentsOf: headers.map { ApiHeaderRegionRow.operatorRow(name: $0.0, value: $0.1) })
    return ApiRequestSnapshot(method: "GET", origin: nil, path: [], query: query, headers: rows, body: [])
}

private func region(_ result: ApiRowAdd, _ key: String) -> [JSONValue]? {
    guard case .write(.object(let f)) = result, case .array(let rows)? = f[key] else { return nil }
    return rows
}

@Test("+ query appends a named row with an empty value, keeping the others")
func addingAQueryRowAppends() {
    let rows = region(apiRowAdd(draft: draft(query: [ApiQueryRow(name: "a", value: [.slot("x")])]),
                                region: .query, name: "limit", pane: "p"), "query")
    #expect(rows?.count == 2)
    #expect(rows?.last == .object(["name": .string("limit"), "value": .array([])]))
    #expect(rows?.first == .object(["name": .string("a"), "value": .array([.object(["slot": .string("x")])])]))
}

@Test("+ header appends a custom header, name exactly as typed")
func addingAHeaderKeepsTheName() {
    let rows = region(apiRowAdd(draft: draft(), region: .header, name: "X-Trace-Id", pane: "p"), "headers")
    #expect(rows?.last == .object(["name": .string("X-Trace-Id"), "value": .array([])]))
}

@Test("A blank name is refused", arguments: ["", "  ", "\t"])
func aBlankNameIsRefused(name: String) {
    guard case .refused = apiRowAdd(draft: draft(), region: .header, name: name, pane: "p") else {
        Issue.record("not refused"); return
    }
}

@Test("The deny list is refused at the gesture", arguments: ["authorization", "Authorization", "cookie", "HOST", "proxy-authorization", "Proxy-Foo"])
func theDenyListIsRefused(name: String) {
    guard case .refused = apiRowAdd(draft: draft(), region: .header, name: name, pane: "p") else {
        Issue.record("\(name) not refused"); return
    }
}

@Test("authorization's refusal names the honest route")
func authorizationTeachesTheRoute() {
    #expect(apiRowAdd(draft: draft(), region: .header, name: "Authorization", pane: "p")
        == .refused(apiAuthorizationRefusal))
    #expect(apiAuthorizationRefusal.contains("wakil secrets set-api"))
}

@Test("content-type is not refused: it goes to Wakil's own row", arguments: ["content-type", "Content-Type"])
func contentTypeRoutesToItsRow(name: String) {
    #expect(apiRowAdd(draft: draft(), region: .header, name: name, pane: "p") == .focusContentType)
}

@Test("A duplicate header is admitted at the gesture")
func aDuplicateHeaderIsAdmitted() {
    let rows = region(apiRowAdd(draft: draft(headers: [("x-a", [])]), region: .header, name: "X-A", pane: "p"), "headers")
    #expect(rows?.count == 2)
}

@Test("A query name with = & ? # is refused", arguments: ["a=b", "a&b", "a?b", "a#b"])
func aQueryNameWithASeparatorIsRefused(name: String) {
    guard case .refused = apiRowAdd(draft: draft(), region: .query, name: name, pane: "p") else {
        Issue.record("\(name) not refused"); return
    }
}

@Test("× removes that occurrence and keeps every other row")
func removingARowKeepsTheRest() {
    let d = draft(query: [ApiQueryRow(name: "t", value: [.literal("a")]), ApiQueryRow(name: "t", value: [.literal("b")]),
                          ApiQueryRow(name: "u", value: [.slot("s")])])
    guard case .object(let f)? = apiRowRemoveWrite(draft: d, region: .query, name: "t", row: 1, pane: "p"),
          case .array(let rows)? = f["query"] else { Issue.record("no write"); return }
    #expect(rows.count == 2)
    #expect(rows[0] == .object(["name": .string("t"), "value": .array([.object(["literal": .string("a")])])]))
    #expect(rows[1] == .object(["name": .string("u"), "value": .array([.object(["slot": .string("s")])])]))
}

@Test("Wakil's own header rows are never removed")
func wakilsRowsAreNotRemovable() {
    #expect(apiRowRemoveWrite(draft: draft(), region: .header, name: "content-type", row: 0, pane: "p") == nil)
}

// MARK: - Fix round 1: Wakil's own content-type row never rides along as an operator row

@Test("+ header, with a content type set, never carries Wakil's own content-type row")
func addingAHeaderExcludesContentType() {
    let rows = region(
        apiRowAdd(draft: draft(contentType: "application/json"), region: .header, name: "x-a", pane: "p"),
        "headers")
    #expect(rows == [.object(["name": .string("x-a"), "value": .array([])])])
}

@Test("× on a header, with a content type set, never carries Wakil's own content-type row")
func removingAHeaderExcludesContentType() {
    let d = draft(headers: [("x-a", [])], contentType: "application/json")
    guard case .object(let f)? = apiRowRemoveWrite(draft: d, region: .header, name: "x-a", row: 0, pane: "p"),
          case .array(let rows)? = f["headers"] else { Issue.record("no write"); return }
    #expect(rows.isEmpty)
}

// MARK: - Fix round 1: header occurrence is exact-name, same as apiRowOccurrence

/// **Order matters here, deliberately.** `X-A` is written first and `x-a` second, so a
/// case-insensitive counter and an exact one disagree about which row is "occurrence 0 of
/// x-a": the view assigns `row` by `apiRowOccurrence`, which counts the EXACT name, so the
/// `×` on the `x-a` row (the second one) is `row: 0` among `x-a`'s own rows — a
/// case-insensitive counter would instead see `X-A` as `x-a`'s occurrence 0 and remove the
/// wrong row.
@Test("× on a header counts the exact name: x-a and X-A are different rows")
func removingAHeaderCountsTheExactName() {
    let d = draft(headers: [("X-A", [.literal("1")]), ("x-a", [.literal("2")])])
    guard case .object(let f)? = apiRowRemoveWrite(draft: d, region: .header, name: "x-a", row: 0, pane: "p"),
          case .array(let rows)? = f["headers"] else { Issue.record("no write"); return }
    #expect(rows == [.object(["name": .string("X-A"), "value": .array([.object(["literal": .string("1")])])])])
}

// MARK: - Task 5: the rulings the row controls draw from

@Test("W16: + query and + header stay live over a bound row")
func addingStaysLiveOverABinding() {
    let bound = ApiPart.bound(liveBinding(name: "id"))
    #expect(apiRowAddIsEnabled(draft(), .query))
    #expect(apiRowAddIsEnabled(draft(), .header))
    #expect(apiRowAddIsEnabled(draft(query: [ApiQueryRow(name: "a", value: [bound])]), .query))
    #expect(apiRowAddIsEnabled(draft(headers: [("x-a", [bound])]), .header))
    guard case .write(.object(let f)) = apiRowAdd(
        draft: draft(query: [ApiQueryRow(name: "a", value: [bound])]),
        region: .query, name: "b", pane: "p"),
        case .array(let rows)? = f["query"]
    else { Issue.record("no write"); return }
    #expect(rows.first == .object([
        "name": .string("a"), "value": .array([apiPartJSON(bound, sources: [:])]),
    ]))
}

@Test("× is drawn on the operator's rows, and not on a row holding a binding of its own")
func theRemoveIsDrawnOnTheOperatorsRows() {
    let d = draft(query: [ApiQueryRow(name: "a", value: [.literal("1")])],
                  headers: [("x-a", [.literal("v")])], contentType: "application/json")
    #expect(apiRowDrawsRemove(d, .query, at: 0))
    // `draft` puts Wakil's own rows first: content-type and the operator's x-a.
    let index = d.headers.firstIndex { $0.name == "x-a" }!
    #expect(apiRowDrawsRemove(d, .header, at: index))
    let ct = d.headers.firstIndex { $0.name == "content-type" }!
    #expect(!apiRowDrawsRemove(d, .header, at: ct))
    #expect(!apiRowDrawsRemove(d, .query, at: 5))
    let bound = ApiPart.bound(liveBinding(name: "id"))
    let mixed = draft(query: [ApiQueryRow(name: "a", value: [.literal("1")]),
                              ApiQueryRow(name: "b", value: [bound])])
    // The neighbour of a bound row is removable now; the bound row unbinds first (8b).
    #expect(apiRowDrawsRemove(mixed, .query, at: 0))
    #expect(!apiRowDrawsRemove(mixed, .query, at: 1))
    let headed = draft(headers: [("x-a", [.literal("v")]), ("x-b", [bound])])
    let xb = headed.headers.firstIndex { $0.name == "x-b" }!
    #expect(!apiRowDrawsRemove(headed, .header, at: xb))
    #expect(apiRowDrawsRemove(headed, .header, at: headed.headers.firstIndex { $0.name == "x-a" }!))
}

@Test("The added row's key is the one its value box will carry, a duplicate's included")
func theAddedRowsKey() {
    #expect(apiRowAddedKey(draft(), .query, name: "limit") == "query.limit")
    #expect(apiRowAddedKey(draft(query: [ApiQueryRow(name: "t", value: [])]), .query, name: "t")
        == "query[1].t")
    #expect(apiRowAddedKey(draft(headers: [("x-a", [])]), .header, name: "x-a") == "header[1].x-a")
    // Exact names, as apiRowOccurrence counts: X-A is not a second x-a.
    #expect(apiRowAddedKey(draft(headers: [("X-A", [])]), .header, name: "x-a") == "header.x-a")
}

@Test("After ×, the removed row's held parts and its later twins' keys are forgotten, nothing else")
func removingForgetsTheShiftedKeys() {
    let held: ApiHeld = [
        ApiFieldRow(.query("t"), row: 0): [.literal("a")],
        ApiFieldRow(.query("t"), row: 1): [.literal("b")],
        ApiFieldRow(.query("t"), row: 2): [.literal("c")],
        ApiFieldRow(.query("u")): [.literal("u")],
        ApiFieldRow(.header("t")): [.literal("h")],
    ]
    let after = apiBoxesRemovingRow(held, region: .query, name: "t", row: 1)
    #expect(after == [
        ApiFieldRow(.query("t"), row: 0): [.literal("a")],
        ApiFieldRow(.query("u")): [.literal("u")],
        ApiFieldRow(.header("t")): [.literal("h")],
    ])
}

// MARK: - Final review I3: the content-type field follows the draft

private func contentTypeRequest(_ contentType: String) -> ApiRequestSnapshot {
    ApiRequestSnapshot(
        method: "POST", origin: nil, path: [], query: [],
        headers: apiWakilHeaderRows(entry: "billing", contentType: contentType, credentialed: true),
        body: [])
}

@Test("The content-type field's text is the derived row's value, and empty while unset")
func theContentTypeTextIsTheDerivedRow() {
    #expect(apiContentTypeText(contentTypeRequest("application/json")) == "application/json")
    #expect(apiContentTypeText(contentTypeRequest("")) == "")
    #expect(apiContentTypeText(contentTypeRequest("  text/plain ")) == "text/plain")
}

@Test("A content-type commit that leaves the draft as it is, is a no-op")
func aContentTypeCommitCanBeANoOp() {
    let request = contentTypeRequest("application/json")
    #expect(apiContentTypeCommitIsNoOp(request, text: "application/json"))
    // The region draws it trimmed, so trailing space changes nothing the operator sees.
    #expect(apiContentTypeCommitIsNoOp(request, text: "application/json "))
    #expect(!apiContentTypeCommitIsNoOp(request, text: "application/xml"))
    #expect(!apiContentTypeCommitIsNoOp(request, text: ""))
    #expect(apiContentTypeCommitIsNoOp(contentTypeRequest(""), text: "  "))
}
