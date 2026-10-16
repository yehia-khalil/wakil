import Foundation
import Testing
@testable import WakilKit

/// Amendment 8a: the path box is a view of path AND query, parsed back on commit.

private func q(_ name: String, _ value: [ApiPart]) -> ApiQueryRow { ApiQueryRow(name: name, value: value) }

/// Strips empty literals, so a round-trip assertion can compare against what `apiPathQueryParse`
/// actually hands back — an empty literal and no part are the same value (ruling 3), and
/// `apiPathQueryParse` never reconstructs the empty literal itself.
private func stripEmptyLiterals(_ parts: [ApiPart]) -> [ApiPart] {
    parts.filter { part in
        if case .literal("") = part { return false }
        return true
    }
}

private func stripEmptyLiterals(_ query: [ApiQueryRow]) -> [ApiQueryRow] {
    query.map { ApiQueryRow(name: $0.name, value: stripEmptyLiterals($0.value)) }
}

@Test("An empty query draws no question mark")
func anEmptyQueryDrawsNoQuestionMark() {
    #expect(apiPathQueryView(path: [.literal("/orders")], query: []) == [.literal("/orders")])
}

@Test("Rows draw as name=value joined by &, adjacent literals merged")
func rowsDrawAsAQueryString() {
    let view = apiPathQueryView(
        path: [.literal("/orders")],
        query: [q("status", [.literal("open")]), q("limit", [.literal("5")])])
    #expect(view == [.literal("/orders?status=open&limit=5")])
}

@Test("A hole in a query value draws as its chip in place")
func aHoleInAValueIsAChip() {
    let view = apiPathQueryView(path: [.literal("/o")], query: [q("id", [.slot("id")])])
    #expect(view == [.literal("/o?id="), .slot("id")])
}

@Test("The view parses back to the same path and rows", arguments: [
    ([ApiPart.literal("/orders")], [ApiQueryRow]()),
    ([.literal("/o")], [q("a", [.literal("1")]), q("b", [])]),
    ([.literal("/o/"), .slot("id"), .literal("/x")], [q("k", [.literal("v"), .slot("s"), .literal("w")])]),
    ([.literal("/o")], [q("tag", [.literal("a")]), q("tag", [.literal("b")])]),
    // An empty literal next to a chip: the same value as the chip alone (ruling 3), so the
    // comparison strips empty literals before checking — see `stripEmptyLiterals`.
    ([.literal("/o")], [q("k", [.literal(""), .slot("s")])]),
])
func theViewRoundTrips(path: [ApiPart], query: [ApiQueryRow]) throws {
    let parsed = try apiPathQueryParse(apiPathQueryView(path: path, query: query)).get()
    #expect(parsed.path == stripEmptyLiterals(path))
    #expect(parsed.query == stripEmptyLiterals(query))
}

@Test("Only the first question mark splits")
func onlyTheFirstQuestionMarkSplits() throws {
    let parsed = try apiPathQueryParse([.literal("/a?x=1?y=2")]).get()
    #expect(parsed.path == [.literal("/a")])
    #expect(parsed.query == [q("x", [.literal("1?y=2")])])
}

@Test("A trailing question mark is no rows")
func aTrailingQuestionMarkIsNoRows() throws {
    let parsed = try apiPathQueryParse([.literal("/a?")]).get()
    #expect(parsed.path == [.literal("/a")])
    #expect(parsed.query.isEmpty)
}

@Test("Empty pairs from && are dropped")
func emptyPairsAreDropped() throws {
    let parsed = try apiPathQueryParse([.literal("/a?x=1&&y=2&")]).get()
    #expect(parsed.query == [q("x", [.literal("1")]), q("y", [.literal("2")])])
}

@Test("A name with no = is a row with an empty value")
func aBareNameIsAnEmptyValue() throws {
    let parsed = try apiPathQueryParse([.literal("/a?debug")]).get()
    #expect(parsed.query == [q("debug", [])])
}

@Test("A hole in a query name is refused")
func aHoleInANameIsRefused() {
    switch apiPathQueryParse([.literal("/a?"), .slot("k"), .literal("=1")]) {
    case .failure(.holeInName): break
    default: Issue.record("expected .failure(.holeInName)")
    }
}

@Test("A nameless row is refused")
func aNamelessRowIsRefused() {
    switch apiPathQueryParse([.literal("/a?=x")]) {
    case .failure(.namelessRow): break
    default: Issue.record("expected .failure(.namelessRow)")
    }
}

@Test("A # in a query name is refused")
func aHashInANameIsRefused() {
    switch apiPathQueryParse([.literal("/a?x#y=1")]) {
    case .failure(.forbiddenInName("#")): break
    default: Issue.record("expected .failure(.forbiddenInName(\"#\"))")
    }
}

@Test("What is typed is what is meant: no percent-decoding")
func nothingIsDecoded() throws {
    let parsed = try apiPathQueryParse([.literal("/a?q=a%20b")]).get()
    #expect(parsed.query == [q("q", [.literal("a%20b")])])
}

@Test("A value with an ampersand does not round-trip")
func aValueWithAnAmpersandDoesNotRoundTrip() {
    #expect(!apiPathQueryRoundTrips([q("q", [.literal("a&b")])]))
    #expect(!apiPathQueryRoundTrips([q("a=b", [.literal("1")])]))
    #expect(apiPathQueryRoundTrips([q("q", [.literal("a=b")]), q("id", [.slot("id")])]))
}

@Test("An empty literal round-trips as no part — the two are the same value on the wire")
func anEmptyLiteralRoundTripsAsNoPart() throws {
    #expect(apiPathQueryRoundTrips([q("x", [.literal("")])]))
    let parsed = try apiPathQueryParse(
        apiPathQueryView(path: [.literal("/a")], query: [q("x", [.literal("")])])
    ).get()
    #expect(parsed.query == [q("x", [])])
}

@Test("A path-box commit writes path and query in one write")
func oneWriteCarriesBoth() {
    let written = apiPathQueryWrite(
        path: [.literal("/o")], query: [q("id", [.slot("id")])], pane: "api-1")
    guard case .object(let fields) = written else { Issue.record("not an object"); return }
    #expect(fields["path"] == .array([.object(["literal": .string("/o")])]))
    #expect(fields["query"] == .array([.object([
        "name": .string("id"), "value": .array([.object(["slot": .string("id")])]),
    ])]))
    #expect(fields["pane"] == .string("api-1"))
}

// MARK: - Task 4: the path box on screen is the view

private func req(path: [ApiPart], query: [ApiQueryRow]) -> ApiRequestSnapshot {
    ApiRequestSnapshot(method: "GET", origin: nil, path: path, query: query,
                       headers: ApiRequestSnapshot.empty.headers, body: [])
}

@Test("W16: the path box locks only over an &, never over a binding")
func thePathBoxLocks() {
    let bound = ApiPart.bound(liveBinding(name: "id"))
    #expect(apiPathBoxIsTypable(req(path: [.literal("/o/"), bound], query: [])))
    #expect(apiPathBoxIsTypable(req(path: [.literal("/o")], query: [q("id", [bound])])))
    #expect(!apiPathBoxIsTypable(req(path: [.literal("/o")], query: [q("q", [.literal("a&b")])])))
    #expect(apiPathBoxIsTypable(req(path: [.literal("/o/"), .slot("id")], query: [q("k", [.slot("s")])])))
}

@Test("The & note is drawn whenever an & locks the box, a binding or not")
func theAmpersandNote() {
    let bound = ApiPart.bound(liveBinding(name: "id"))
    #expect(apiPathBoxNote(req(path: [.literal("/o")], query: [q("q", [.literal("a&b")])]))
        == apiPathQueryAmpersandNote)
    #expect(apiPathBoxNote(req(path: [.literal("/o")], query: [q("q", [.literal("ab")])])) == nil)
    #expect(apiPathBoxNote(req(path: [bound], query: [q("q", [.literal("a&b")])]))
        == apiPathQueryAmpersandNote)
    #expect(apiPathQueryAmpersandNote == "a query value holds & — edit it in the Query region")
}

@Test("Review Focus 1: a bound chip cannot move between the Query region and the path")
func aBindingCannotMoveBetweenPathAndQuery() {
    let bound = ApiPart.bound(liveBinding(name: "id"))
    let r = req(path: [.literal("/o")], query: [q("id", [bound])])
    #expect(apiPathQueryView(path: r.path, query: r.query) == [.literal("/o?id="), bound])
    // Deleting the `?` would parse the chip into the path.
    #expect(apiPathViewWrite(r, view: [.literal("/oid="), bound], pane: "p")
        == .refused(ApiPathQueryRefusal.boundMoved.line))
    #expect(ApiPathQueryRefusal.boundMoved.line
        == "a bound value stays in the region it was dropped in — unbind it to move it")
    // Text beside it writes, the chip carried in its own region.
    guard case .write = apiPathViewWrite(r, view: [.literal("/orders?id="), bound], pane: "p")
    else { Issue.record("text beside a binding was refused"); return }
}

@Test("A view position maps back to its region, its row among same-named rows, and its own index")
func aViewPositionMapsBack() {
    let path: [ApiPart] = [.literal("/o/"), .slot("id")]
    let query = [q("tag", [.slot("a")]), q("k", [.literal("x"), .slot("s")]), q("tag", [.slot("b")])]
    // view: [/o/] [id] [?tag=] [a] [&k=x] [s] [&tag=] [b]
    let view = apiPathQueryView(path: path, query: query)
    #expect(view.count == 8)
    #expect(apiPathQueryOrigin(path: path, query: query, viewIndex: 1)! == (.path, 0, 1))
    #expect(apiPathQueryOrigin(path: path, query: query, viewIndex: 3)! == (.query("tag"), 0, 0))
    #expect(apiPathQueryOrigin(path: path, query: query, viewIndex: 5)! == (.query("k"), 0, 1))
    #expect(apiPathQueryOrigin(path: path, query: query, viewIndex: 7)! == (.query("tag"), 1, 0))
    // A literal box is not a chip, and past the end is nobody's.
    #expect(apiPathQueryOrigin(path: path, query: query, viewIndex: 2) == nil)
    #expect(apiPathQueryOrigin(path: path, query: query, viewIndex: 8) == nil)
}

@Test("An empty literal before a chip counts in the row's own index, which is api_unbind's")
func anEmptyLiteralCountsInTheRowIndex() {
    let query = [q("k", [.literal(""), .slot("s")])]
    // view: [/o?k=] [s]
    #expect(apiPathQueryOrigin(path: [.literal("/o")], query: query, viewIndex: 1)! == (.query("k"), 0, 1))
}

private func written(_ outcome: ApiPathBoxOutcome) -> (path: JSONValue?, query: JSONValue?) {
    guard case .write(.object(let fields)) = outcome else { return (nil, nil) }
    return (fields["path"], fields["query"])
}

@Test("Typing ?a=1 into the path box writes the path and a query row, together")
func typingAQueryIntoThePathBox() {
    let outcome = apiPathViewWrite(
        req(path: [.literal("/o")], query: []), view: [.literal("/o?a=1")], pane: "api-1")
    let w = written(outcome)
    #expect(w.path == .array([.object(["literal": .string("/o")])]))
    #expect(w.query == .array([.object([
        "name": .string("a"), "value": .array([.object(["literal": .string("1")])]),
    ])]))
}

@Test("A hole in the path view before the ? is written in the PATH")
func aHoleLandsInThePath() {
    // Final review I4: `+ hole` on the URL line means the path; each query row has its own.
    let outcome = apiPathViewWrite(
        req(path: [.literal("/o")], query: [q("id", [])]),
        view: [.literal("/o"), .slot("id"), .literal("?id=")], pane: "api-1")
    let w = written(outcome)
    #expect(w.path == .array([.object(["literal": .string("/o")]), .object(["slot": .string("id")])]))
    #expect(w.query == .array([.object(["name": .string("id"), "value": .array([])])]))
}

@Test("A hole in the path carries the path view's typed text, path and query both")
func aHoleCarriesTheTypedText() {
    let outcome = apiPathViewWrite(
        req(path: [.literal("/o")], query: [q("k", [.literal("1")])]),
        view: [.literal("/p/"), .slot("id"), .literal("?k=2&m=3")], pane: "p")
    let w = written(outcome)
    #expect(w.path == .array([.object(["literal": .string("/p/")]), .object(["slot": .string("id")])]))
    #expect(w.query == .array([
        .object(["name": .string("k"), "value": .array([.object(["literal": .string("2")])])]),
        .object(["name": .string("m"), "value": .array([.object(["literal": .string("3")])])]),
    ]))
}

@Test("+ hole with a blank name is refused before anything is dispatched")
func aBlankHoleIsRefused() {
    #expect(apiHoleNameRefused("  ") == apiHoleNameRefusal)
}

@Test("A hole in a query name is refused in the parse's own words")
func aHoleInANameIsRefusedOnScreen() {
    // view: [/o/] [id] — a `?` typed before the chip puts the chip where a query NAME is read.
    let outcome = apiPathViewWrite(
        req(path: [.literal("/o/"), .slot("id")], query: []),
        view: [.literal("/o/?"), .slot("id")], pane: "p")
    #expect(outcome == .refused(ApiPathQueryRefusal.holeInName.line))
}

@Test("Removing a hole from the path view removes it from the query value it sits in")
func removingAHoleByViewIndex() {
    // view: [/o/] [id] [?k=] [s], and `s` removed.
    let outcome = apiPathViewWrite(
        req(path: [.literal("/o/"), .slot("id")], query: [q("k", [.slot("s")])]),
        view: [.literal("/o/"), .slot("id"), .literal("?k=")], pane: "p")
    let w = written(outcome)
    #expect(w.path == .array([.object(["literal": .string("/o/")]), .object(["slot": .string("id")])]))
    #expect(w.query == .array([.object(["name": .string("k"), "value": .array([])])]))
}

@Test("Text typed on both sides of a chip rides one path-view write")
func typedTextRidesTheCommit() {
    // view: [/o/] [id] [?k=v], typed to [/p/] [id] [?k=w]
    let outcome = apiPathViewWrite(
        req(path: [.literal("/o/"), .slot("id")], query: [q("k", [.literal("v")])]),
        view: [.literal("/p/"), .slot("id"), .literal("?k=w")], pane: "p")
    let w = written(outcome)
    #expect(w.path == .array([.object(["literal": .string("/p/")]), .object(["slot": .string("id")])]))
    #expect(w.query == .array([.object([
        "name": .string("k"), "value": .array([.object(["literal": .string("w")])]),
    ])]))
}

// MARK: - Ruling 7: the key that stands for the whole Query region

@Test("The region mark reads as the Query region, not as a row with no name")
func theRegionMarkLabel() {
    #expect(apiQueryRegionMark.label == "Query")
}

// MARK: - Final review I2: a commit that parses back to the draft is a no-op

@Test("A path-box commit that parses back to the draft unchanged is a no-op")
func aCommitThatParsesBackUnchangedIsANoOp() {
    // `/o?` over `/o`: a trailing `?` means no rows.
    let bare = req(path: [.literal("/o")], query: [])
    #expect(apiPathBoxWriteIsNoOp(request: bare, path: [.literal("/o")], query: []))
    #expect(apiPathViewWrite(bare, view: [.literal("/o?")], pane: "p") == .unchanged)
    // `/o?a` over `/o?a=`: `a` and `a=` are the same row.
    let named = req(path: [.literal("/o")], query: [q("a", [])])
    #expect(apiPathViewWrite(named, view: [.literal("/o?a")], pane: "p") == .unchanged)
    // `?a=1&` over `?a=1`: a trailing `&` adds no row.
    let one = req(path: [], query: [q("a", [.literal("1")])])
    #expect(apiPathViewWrite(one, view: [.literal("?a=1&")], pane: "p") == .unchanged)
}

@Test("A commit that changes the draft is not a no-op, and empty literals do not count")
func aRealChangeIsNotANoOp() {
    let draft = req(path: [.literal("/o"), .literal("")], query: [q("a", [.literal("1")])])
    #expect(apiPathBoxWriteIsNoOp(request: draft, path: [.literal("/o")], query: [q("a", [.literal("1")])]))
    #expect(!apiPathBoxWriteIsNoOp(request: draft, path: [.literal("/p")], query: [q("a", [.literal("1")])]))
    #expect(!apiPathBoxWriteIsNoOp(request: draft, path: [.literal("/o")], query: [q("a", [.literal("2")])]))
    #expect(!apiPathBoxWriteIsNoOp(request: draft, path: [.literal("/o")], query: []))
    #expect(!apiPathBoxWriteIsNoOp(request: draft, path: [.literal("/o")],
                                   query: [q("a", [.literal("1")]), q("b", [])]))
    if case .write = apiPathViewWrite(draft, view: [.literal("/o?a=2")], pane: "p") {
    } else { Issue.record("a changed value must write") }
}

// MARK: - Final review M6, revised by Ruling 23: a `?` in a path literal is noted, not locked

@Test("A path literal holding ? keeps the box typable, with a note saying what a commit does")
func aQuestionMarkInThePathIsNoted() {
    let request = req(path: [.literal("/o?x=1")], query: [])
    #expect(apiPathBoxIsTypable(request))
    #expect(apiPathBoxNote(request) == apiPathQuestionNote)
    // Behind a slot too: any path literal.
    let behindSlot = req(path: [.slot("id"), .literal("?")], query: [q("k", [])])
    #expect(apiPathBoxIsTypable(behindSlot))
    #expect(apiPathBoxNote(behindSlot) == apiPathQuestionNote)
    // W16: a bound value no longer locks the box, so the note is drawn over it too.
    let bound = ApiPart.bound(liveBinding(name: "id"))
    #expect(apiPathBoxNote(req(path: [bound, .literal("?x")], query: [])) == apiPathQuestionNote)
    // A `?` in a query VALUE is only text there: no lock and no note.
    let inValue = req(path: [.literal("/o")], query: [q("k", [.literal("a?b")])])
    #expect(apiPathBoxIsTypable(inValue))
    #expect(apiPathBoxNote(inValue) == nil)
    // An `&` in a query value still locks, and its note is the one drawn.
    let both = req(path: [.literal("/o?")], query: [q("k", [.literal("a&b")])])
    #expect(!apiPathBoxIsTypable(both))
    #expect(apiPathBoxNote(both) == apiPathQueryAmpersandNote)
}

@Test("Committing over a path literal holding ? moves what follows it into a query row, as drawn")
func aCommitOverAQuestionMarkParsesIntoTheQuery() {
    let request = req(path: [.literal("/o?x=1")], query: [])
    // The view draws `/o?x=1`; committing it as drawn writes what the view shows.
    let w = written(apiPathViewWrite(request, view: [.literal("/o?x=1")], pane: "p"))
    #expect(w.path == .array([.object(["literal": .string("/o")])]))
    #expect(w.query == .array([.object([
        "name": .string("x"), "value": .array([.object(["literal": .string("1")])]),
    ])]))
}
