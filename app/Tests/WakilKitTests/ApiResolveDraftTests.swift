import Foundation
import Testing
@testable import WakilKit

/// `resolveDraft` (#189) — the one new seam 2c-iv adds, and the place
/// every parts, quoting, escaping, position, lifetime and aggregated-
/// refusal ruling is asserted as a table rather than as a dispatch.

// MARK: - Fixtures

private func draft(
    entry: String = "billing",
    method: String = "GET",
    path: [ApiPart] = [],
    query: [ApiQueryRow] = [],
    headers: [ApiHeaderRow] = [],
    contentType: String = "",
    body: [ApiPart] = []
) -> ApiDraft {
    ApiDraft(
        entry: entry, method: method, path: path, query: query, headers: headers,
        contentType: contentType, body: body)
}

// MARK: - The happy path

@Test func aDraftOfLiteralsResolvesToAWireRequest() throws {
    let wire = try resolveDraft(
        draft(
            method: "GET",
            path: [.literal("/v1/bookings")],
            query: [ApiQueryRow(name: "status", value: [.literal("open")])],
            headers: [ApiHeaderRow(name: "X-Trace", value: [.literal("abc")])]),
        sources: [:], credentialed: false
    ).get()

    #expect(wire.entry == "billing")
    #expect(wire.method == "GET")
    #expect(wire.path == "/v1/bookings")
    #expect(wire.query == [ApiWireQueryItem(name: "status", value: "open")])
    #expect(wire.headers == [ApiWireHeader(name: "X-Trace", value: "abc")])
    #expect(wire.body == nil)
    #expect(wire.contentType == nil)
}

// MARK: - A live bound value

/// A source pane showing two bookings, keyed by `id`.
private func bookings(generation: Int = 1) -> ApiSourcePane {
    ApiSourcePane(
        columns: ["id", "reference", "total"],
        rows: [
            [.integer(8842), .string("BK-2026-8842"), .number(19.9)],
            [.integer(8843), .string("BK-2026-8843"), .number(4.5)],
        ],
        generation: generation)
}

/// The declared type each of `bookings`' columns was bound at. A part
/// pins its own type, so the pane holds none.
private let bookingTypes = ["id": "INTEGER", "reference": "TEXT", "total": "DECIMAL(10,2)"]

private func liveSource(
    column: String, key: String = "8842", type: String? = nil, pane: String = "p3",
    generation: Int = 1
) -> ApiValueSource {
    ApiValueSource(
        pane: pane, table: "bookings", keyColumns: ["id"], keyValues: [key],
        column: column, declaredType: type ?? bookingTypes[column] ?? "TEXT",
        generation: generation)
}

private func live(
    _ name: String, column: String? = nil, key: String = "8842", type: String? = nil,
    pane: String = "p3", generation: Int = 1
) -> ApiPart {
    .bound(ApiBoundValue(
        name: name, binding: .live,
        source: liveSource(
            column: column ?? name, key: key, type: type, pane: pane, generation: generation)))
}

@Test func aLiveValueIsFoundByItsRowKeyAndNotByItsPosition() throws {
    // The same draft against the same rows in the opposite order must send
    // the same booking: a re-sort moves the row, the key does not move.
    let reversed = ApiSourcePane(
        columns: bookings().columns, rows: bookings().rows.reversed(), generation: 1)

    for source in [bookings(), reversed] {
        let wire = try resolveDraft(
            draft(path: [.literal("/v1/bookings/"), live("reference")]),
            sources: ["p3": source], credentialed: false
        ).get()
        #expect(wire.path == "/v1/bookings/BK-2026-8842")
    }
}

@Test func aCellHoldingATraversalEmitsAsOneInertSegment() throws {
    let source = ApiSourcePane(
        columns: ["id", "name"], rows: [[.integer(1), .string("../etc/passwd")]], generation: 1)
    let wire = try resolveDraft(
        draft(path: [.literal("/v1/files/"), live("name", key: "1")]),
        sources: ["p3": source], credentialed: false
    ).get()

    // One segment. The slashes are encoded, so nothing in the cell can
    // open a second segment and climb.
    #expect(wire.path == "/v1/files/..%2Fetc%2Fpasswd")
}

// MARK: - What counts as unresolved

private func refusal(_ result: Result<ApiWireRequest, ApiSendRefusal>) throws -> ApiSendRefusal {
    switch result {
    case .success(let wire):
        Issue.record("expected a refusal, got \(wire)")
        throw ApiSendRefusal(failures: [])
    case .failure(let refusal):
        return refusal
    }
}

@Test func anUnboundSlotIsRefusedByName() throws {
    let refused = try refusal(resolveDraft(
        draft(path: [.literal("/v1/bookings/"), .slot("id")]), sources: [:], credentialed: false))

    #expect(refused.failures.count == 1)
    #expect(refused.failures[0].region == .path)
    #expect(refused.failures[0].message.contains("“id” has never been bound"))
    #expect(refused.failures[0].available == nil)
}

@Test func aBindingFromAClosedPaneKeepsItsOriginInTheRefusal() throws {
    let refused = try refusal(resolveDraft(
        draft(path: [live("reference")]), sources: [:], credentialed: false))

    #expect(refused.failures.count == 1)
    // The origin is named, so the operator knows WHICH row went missing —
    // a lost binding keeps its origin rather than degrading to a hole.
    #expect(refused.failures[0].message.contains("bookings · id 8842 · reference"))
    #expect(refused.failures[0].message.contains("closed"))
}

@Test func aPaneThatHasNotReFetchedIsNotTheSameProblemAsARowThatIsGone() throws {
    let empty = ApiSourcePane(columns: [], rows: [], generation: 1)
    let notFetched = try refusal(resolveDraft(
        draft(path: [live("reference")]), sources: ["p3": empty], credentialed: false))
    #expect(notFetched.failures[0].message.contains("has not re-fetched yet"))
    #expect(notFetched.failures[0].available == nil)

    let gone = try refusal(resolveDraft(
        draft(path: [live("reference", key: "9999")]), sources: ["p3": bookings()],
        credentialed: false))
    #expect(gone.failures[0].message.contains("no row matches that key"))
    // The columns that WERE available, so the next pass is informed.
    #expect(gone.failures[0].available == ["id", "reference", "total"])
}

@Test func aColumnTheGridNoLongerHasNamesTheColumnsItDoes() throws {
    let refused = try refusal(resolveDraft(
        draft(path: [live("note", column: "note")]), sources: ["p3": bookings()],
        credentialed: false))

    #expect(refused.failures[0].message.contains("a column note that the grid no longer has"))
    #expect(refused.failures[0].available == ["id", "reference", "total"])
}

@Test func aNullCellHasNothingToSend() throws {
    let source = ApiSourcePane(
        columns: ["id", "note"], rows: [[.integer(1), .null]], generation: 1)
    let refused = try refusal(resolveDraft(
        draft(path: [live("note", key: "1")]), sources: ["p3": source], credentialed: false))

    #expect(refused.failures[0].message.contains("that cell is NULL"))
}

// MARK: - A captured value lives as long as its rows

private func captured(
    _ name: String, token: JSONValue, type: String, column: String? = nil, generation: Int = 1
) -> ApiPart {
    .bound(ApiBoundValue(
        name: name,
        binding: .captured(ApiHeldCell(token: token, declaredType: type)),
        source: liveSource(column: column ?? name, type: type, generation: generation)))
}

@Test func aCapturedValueEmitsWhatItHoldsWhileItsRowsStand() throws {
    let wire = try resolveDraft(
        draft(path: [.literal("/v1/bookings/"), captured("reference", token: .string("BK-1"), type: "TEXT")]),
        sources: ["p3": bookings(generation: 1)], credentialed: false
    ).get()

    #expect(wire.path == "/v1/bookings/BK-1")
}

@Test func aCapturedValueDiesWhenItsSourcePaneReFetches() throws {
    let refused = try refusal(resolveDraft(
        draft(path: [captured("reference", token: .string("BK-1"), type: "TEXT")]),
        sources: ["p3": bookings(generation: 2)], credentialed: false))

    #expect(refused.failures[0].message.contains("Those rows are gone"))
    // Never an age, never a clock: the sentence is about the rows.
    #expect(!refused.failures[0].message.contains("ago"))
}

// MARK: - The two cells that refuse themselves

@Test func aBinaryTypedSourceRefusesRatherThanSendingEightBytesForFour() throws {
    // `DE AD BE EF` stored, eight bytes read back: the JSON encoder must
    // emit valid UTF-8, so the run is replaced before the pane sees it.
    let source = ApiSourcePane(
        columns: ["id", "payload"],
        rows: [[.integer(1), .string("\u{DE}\u{AD}\u{FFFD}\u{FFFD}")]], generation: 1)
    let refused = try refusal(resolveDraft(
        draft(path: [live("payload", key: "1", type: "BLOB")]), sources: ["p3": source],
        credentialed: false))

    #expect(refused.failures[0].message.contains("BLOB"))
    #expect(refused.failures[0].message.contains("corrupted"))
}

@Test func aDocumentOrAListCannotFillARequestField() throws {
    // Mongo's `bson.Binary` crosses losslessly, as an object — and an
    // object cannot fill a scalar position. Refused on the token's shape,
    // which catches arrays and sub-documents with no list of type names.
    let source = ApiSourcePane(
        columns: ["_id", "payload", "tags"],
        rows: [[
            .string("a1"),
            .object(["Data": .string("3q2+7w=="), "Subtype": .integer(0)]),
            .array([.string("x")]),
        ]],
        generation: 1)

    for column in ["payload", "tags"] {
        let part = ApiPart.bound(ApiBoundValue(
            name: column, binding: .live,
            source: ApiValueSource(
                pane: "p3", table: "orders", keyColumns: ["_id"], keyValues: ["a1"],
                column: column, declaredType: column == "tags" ? "array" : "bson.Binary",
                generation: 1)))
        let refused = try refusal(resolveDraft(
            draft(path: [part]), sources: ["p3": source], credentialed: false))
        #expect(refused.failures[0].message.contains("not a single value"))
    }
}

// MARK: - The dot segment

@Test func aPathPartResolvingToADotSegmentIsRefusedByName() throws {
    // Percent-encoding cannot reach it: PathEscape("..") == "..". So this
    // is the ONE narrow case Swift adds beside Go's own guard.
    for climb in [".", ".."] {
        let source = ApiSourcePane(
            columns: ["id", "name"], rows: [[.integer(1), .string(climb)]], generation: 1)
        let refused = try refusal(resolveDraft(
            draft(path: [.literal("/v1/files/"), live("name", key: "1")]),
            sources: ["p3": source], credentialed: false))

        #expect(refused.failures[0].region == .path)
        #expect(refused.failures[0].message.contains("“name” resolves to “\(climb)”"))
        #expect(refused.failures[0].message.contains("climbs"))
    }
}

// MARK: - The header region is a map (#158)

@Test func headersAreNameSortedSoARedrawNeverReordersThem() throws {
    let wire = try resolveDraft(
        draft(headers: [
            ApiHeaderRow(name: "X-Trace", value: [.literal("t")]),
            ApiHeaderRow(name: "Accept", value: [.literal("application/json")]),
            ApiHeaderRow(name: "idempotency-key", value: [.literal("k")]),
        ]),
        sources: [:], credentialed: false
    ).get()

    #expect(wire.headers.map(\.name) == ["Accept", "idempotency-key", "X-Trace"])
}

@Test func aNameAlreadyOnTheRequestIsRefusedRatherThanAdded() throws {
    let refused = try refusal(resolveDraft(
        draft(headers: [
            ApiHeaderRow(name: "X-Trace", value: [.literal("one")]),
            ApiHeaderRow(name: "x-trace", value: [.literal("two")]),
        ]),
        sources: [:], credentialed: false))

    #expect(refused.failures.count == 1)
    #expect(refused.failures[0].region == .header("x-trace"))
    #expect(refused.failures[0].message.contains("already on this request"))
}

@Test func aHeaderValueRefusesEveryC0ControlAndDELTabIncluded() throws {
    let cases: [(Character, String)] = [
        ("\n", "a newline"), ("\r", "a carriage return"), ("\t", "a tab"),
        ("\0", "a NUL"), ("\u{7F}", "U+007F"), ("\u{01}", "U+0001"),
    ]
    for (character, named) in cases {
        let refused = try refusal(resolveDraft(
            draft(headers: [ApiHeaderRow(name: "X-Trace", value: [.literal("a\(character)b")])]),
            sources: [:], credentialed: false))
        #expect(refused.failures.count == 1)
        #expect(refused.failures[0].message.contains(named))
    }

    // A space is legal, and an empty value emits empty — so a
    // legitimately-empty header stays expressible.
    let wire = try resolveDraft(
        draft(headers: [
            ApiHeaderRow(name: "X-Note", value: [.literal("two words")]),
            ApiHeaderRow(name: "X-Empty", value: []),
        ]),
        sources: [:], credentialed: false
    ).get()
    #expect(wire.headers == [
        ApiWireHeader(name: "X-Empty", value: ""),
        ApiWireHeader(name: "X-Note", value: "two words"),
    ])
}

@Test func aBadFieldNameJoinsTheOneAggregatedRefusal() throws {
    for name in ["", "X Trace", "X:Trace", "X\u{00E9}"] {
        let refused = try refusal(resolveDraft(
            draft(headers: [ApiHeaderRow(name: name, value: [.literal("v")])]), sources: [:],
            credentialed: false))
        #expect(refused.failures.count == 1)
        #expect(refused.failures[0].message.contains("field name"))
    }

    // The grammar's own punctuation is legal, and the pane copies no deny
    // list: `Authorization` is the send tool's refusal to make, not this
    // one's, because `rejectedCallerHeader` is the single policy list.
    let wire = try resolveDraft(
        draft(headers: [ApiHeaderRow(name: "X-Odd_Name.1~", value: [.literal("v")])]),
        sources: [:], credentialed: false
    ).get()
    #expect(wire.headers.map(\.name) == ["X-Odd_Name.1~"])
}

// MARK: - The path/query escaping asymmetry, pinned

@Test func thePathEscapesAResolvedValueAndTheQueryDoesNot() throws {
    // The same cell into both positions, over the characters that make
    // the difference visible. The path crosses as ONE joined string, so
    // this is the last place that can tell a cell's slash from an
    // operator's; the query crosses as a name and a value apart, and
    // `url.Values.Encode` in the send tool escapes it exactly once —
    // escaping here too would put `%252F` on the wire.
    let cases: [(cell: String, path: String, query: String)] = [
        ("a b", "a%20b", "a b"),
        ("c/d", "c%2Fd", "c/d"),
        ("e&f=g", "e%26f%3Dg", "e&f=g"),
        ("100%", "100%25", "100%"),
        ("%2F", "%252F", "%2F"),
        ("ünïcode", "%C3%BCn%C3%AFcode", "ünïcode"),
        ("2026-09-22T00:00:00Z", "2026-09-22T00%3A00%3A00Z", "2026-09-22T00:00:00Z"),
        ("plain", "plain", "plain"),
    ]

    for row in cases {
        let source = ApiSourcePane(
            columns: ["id", "note"], rows: [[.integer(1), .string(row.cell)]], generation: 1)
        let wire = try resolveDraft(
            draft(
                // A literal passes through BOTH emitters untouched: in
                // the path because the operator authors the slashes, in
                // the query because nothing there needs escaping at all.
                path: [.literal("/v1/notes/"), live("note", key: "1")],
                query: [ApiQueryRow(name: "note", value: [.literal("x/"), live("note", key: "1")])]),
            sources: ["p3": source], credentialed: false
        ).get()

        #expect(wire.path == "/v1/notes/\(row.path)", "path · \(row.cell)")
        #expect(wire.query == [ApiWireQueryItem(name: "note", value: "x/\(row.query)")],
                "query · \(row.cell)")
    }
}

// MARK: - The body (#116)

/// A body region wrapping one bound value in a JSON document, so the
/// quoting rule is read off a real document rather than off a fragment.
private func bodyAround(_ part: ApiPart) -> [ApiPart] {
    [.literal("{\"v\":"), part, .literal("}")]
}

@Test func quotingIsDecidedFromTheDeclaredTypeAndNeverFromTheToken() throws {
    // Every row is a cell this project has MEASURED arriving, through the
    // shipped binaries: sqlite in `2c-iv-probe.md` §5.2, MySQL and Mongo
    // in §5.4. The declared type decides the position; the token decides
    // the digits.
    let cases: [(type: String, token: JSONValue, emits: String)] = [
        // sqlite: DECIMAL carries NUMERIC affinity, so the engine
        // converted at INSERT and 19.90 is already 19.9.
        ("DECIMAL(10,2)", .number(19.9), "19.9"),
        // MySQL: real fixed point, handed back as a string. Same rule,
        // no driver branch — the token carries the difference.
        ("DECIMAL", .string("19.90"), "19.90"),
        ("bson.Decimal128", .string("19.90"), "19.90"),
        ("BIGINT", .integer(9007199254740993), "9007199254740993"),
        ("INTEGER", .integer(42), "42"),
        // A string affinity is quoted, and the encoder escapes it.
        ("TEXT", .string("19.90"), "\"19.90\""),
        ("VARCHAR(20)", .string("a\"b"), "\"a\\\"b\""),
        // sqlite hands back the number 1 for a BOOLEAN, never `true`.
        ("BOOLEAN", .integer(1), "true"),
        ("BOOLEAN", .integer(0), "false"),
        // Mongo is the only one of the three that sends a real boolean.
        ("bool", .bool(true), "true"),
        // A DATE emits what the pane DREW: the full timestamp on sqlite,
        // the date alone on MySQL. Wakil invents no third spelling.
        ("DATE", .string("2026-09-22T00:00:00Z"), "\"2026-09-22T00:00:00Z\""),
        ("DATE", .string("2026-09-22"), "\"2026-09-22\""),
    ]

    for row in cases {
        let wire = try resolveDraft(
            draft(
                method: "POST",
                body: bodyAround(captured("v", token: row.token, type: row.type))),
            sources: ["p3": bookings()], credentialed: false
        ).get()
        #expect(wire.body == "{\"v\":\(row.emits)}", "\(row.type) / \(row.token)")
    }
}

@Test func aBooleanRuleMySQLCannotExpressEmitsTheNumberItDeclared() throws {
    // MySQL erases BOOLEAN to TINYINT at DDL, so "map 1/0 through the
    // declared type" has nothing to key on there (#184). The cost is
    // named rather than papered over: the cell emits as the number 1.
    let wire = try resolveDraft(
        draft(method: "POST", body: bodyAround(captured("v", token: .integer(1), type: "TINYINT"))),
        sources: ["p3": bookings()], credentialed: false
    ).get()
    #expect(wire.body == "{\"v\":1}")
}

@Test func anEmptyBodySendsNoBodyAndNoContentType() throws {
    let wire = try resolveDraft(draft(method: "DELETE", body: []), sources: [:],
    credentialed: false).get()

    #expect(wire.body == nil)
    #expect(wire.contentType == nil)
}

@Test func aContentTypeBesideAnEmptyBodyIsOmittedNotRefused() throws {
    // B2: the send omits it, as `apiWireArguments` already does; the row dims, and no line is drawn.
    let wire = try resolveDraft(
        draft(method: "DELETE", contentType: "application/json", body: []), sources: [:],
        credentialed: false).get()
    #expect(wire.body == nil)
    #expect(wire.contentType == nil)
}

@Test func aReadSendsNoBodyAndNoContentTypeWhateverTheDraftHolds() throws {
    // B1: the body stays in the draft and is never handed to `request`, whose schema refuses it.
    let wire = try resolveDraft(
        draft(method: "GET", contentType: "application/json", body: [.slot("unfilled")]),
        sources: [:], credentialed: false).get()
    #expect(wire.body == nil)
    #expect(wire.contentType == nil)
    #expect(apiWireArguments(wire) == .object([
        "api": .string("billing"), "method": .string("GET"), "path": .string(""),
    ]))
}

@Test func aBodyCarriesItsContentTypeAndLeavesTheDefaultToTheSendTool() throws {
    let named = try resolveDraft(
        draft(method: "POST", contentType: "application/merge-patch+json",
              body: [.literal("{}")]),
        sources: [:], credentialed: false
    ).get()
    #expect(named.body == "{}")
    #expect(named.contentType == "application/merge-patch+json")

    let unnamed = try resolveDraft(
        draft(method: "POST", body: [.literal("{}")]), sources: [:], credentialed: false
    ).get()
    #expect(unnamed.contentType == nil)
}

@Test func aBodyWhosePartsAllResolveIntoAMalformedDocumentStillRefuses() throws {
    let refused = try refusal(resolveDraft(
        draft(method: "POST", body: [.literal("{\"v\": }")]), sources: [:], credentialed: false))

    #expect(refused.failures.count == 1)
    #expect(refused.failures[0].region == .body)
    #expect(refused.failures[0].message.contains("is not JSON"))
}

@Test func aNumericTypeWhoseCellIsNotANumberIsCaughtByTheDocumentAndNotBySecondGuessing() throws {
    // The emit rule is "unquoted, from the declared type", and it is not
    // re-decided per cell. A column declared DECIMAL holding `n/a` emits
    // `n/a` unquoted, and the document says so — one refusal, in the one
    // place that validates.
    let refused = try refusal(resolveDraft(
        draft(method: "POST",
              body: bodyAround(captured("v", token: .string("n/a"), type: "DECIMAL"))),
        sources: ["p3": bookings()], credentialed: false))

    #expect(refused.failures.count == 1)
    #expect(refused.failures[0].message.contains("is not JSON"))
}

@Test func fourThingsWrongReportFourFailuresAndNeverADerivedFifth() throws {
    // The prototype's own walkthrough: four wrong things used to report
    // five, because an unresolved body part leaves a GAP and the document
    // was validated unconditionally. Padding the aggregate with an entry
    // the operator cannot act on is the failure it exists to prevent.
    let refused = try refusal(resolveDraft(
        draft(
            method: "POST",
            path: [.literal("/v1/bookings/"), .slot("id")],
            query: [ApiQueryRow(name: "actor", value: [live("reference", key: "9999")])],
            headers: [ApiHeaderRow(name: "X-Trace", value: [.literal("a\nb")])],
            body: bodyAround(.slot("total"))),
        sources: ["p3": bookings()], credentialed: false))

    #expect(refused.failures.count == 4)
    #expect(refused.failures.map(\.region) == [
        .path, .query("actor"), .header("X-Trace"), .body,
    ])
    #expect(!refused.failures.contains { $0.message.contains("is not JSON") })
}

@Test func anEmittedBodyOverTheCapRefusesNamingTheByteCount() throws {
    let oversize = String(repeating: "x", count: apiOutboundBodyCap)
    let refused = try refusal(resolveDraft(
        draft(method: "POST", body: [.literal("{\"v\":\"\(oversize)\"}")]), sources: [:],
        credentialed: false))

    #expect(refused.failures.count == 1)
    #expect(refused.failures[0].region == .body)
    // The exact count first, the human label second — measured on the
    // shipped binary, a body one byte over rendered as "1.0 MiB, over the
    // 1 MiB limit", which reads as a refusal of something at the limit.
    #expect(refused.failures[0].message.contains("\(apiOutboundBodyCap + 8) bytes"))
    #expect(refused.failures[0].message.contains("1 MiB"))
    // And nothing derived rides along: the document is not also reported.
    #expect(!refused.failures[0].message.contains("is not JSON"))
}

@Test func theOutboundCapIsTheSendToolsOwnNumber() throws {
    // Two copies of one number, because this one must refuse BEFORE the
    // write gate and Go's cannot be reached from Swift. So the drift is
    // pinned against the Go SOURCE rather than against a Swift literal —
    // a test that compares a constant to itself is one that can never
    // disagree with the code, and this one has a second code to disagree
    // with.
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // WakilKitTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // app
        .deletingLastPathComponent()   // repo root
    let httpsend = try String(
        contentsOf: root.appendingPathComponent("internal/wakilcore/httpsend.go"),
        encoding: .utf8)

    #expect(goConstant(httpsend, "httpSendBodyCap") == apiOutboundBodyCap)
    #expect(goString(httpsend, "httpSendBodyCapLabel") == apiOutboundBodyCapLabel)
}

/// The integer a Go `var name = 1024 * 1024` declares, multiplied out.
private func goConstant(_ source: String, _ name: String) -> Int? {
    guard let line = source.split(separator: "\n").first(where: { $0.contains("\(name) = ") }),
          let rhs = line.components(separatedBy: "\(name) = ").last
    else { return nil }
    let factors = rhs.split(separator: "*").map {
        Int($0.trimmingCharacters(in: .whitespaces))
    }
    guard !factors.isEmpty, factors.allSatisfy({ $0 != nil }) else { return nil }
    return factors.compactMap { $0 }.reduce(1, *)
}

/// The string a Go `const name = "..."` declares.
private func goString(_ source: String, _ name: String) -> String? {
    guard let line = source.split(separator: "\n").first(where: { $0.contains("\(name) = ") }),
          let rhs = line.components(separatedBy: "\(name) = ").last,
          let open = rhs.firstIndex(of: "\""),
          let close = rhs.lastIndex(of: "\""), open < close
    else { return nil }
    return String(rhs[rhs.index(after: open)..<close])
}

// MARK: - The type a part emits by is the one it was bound at

@Test func aLiveBindingEmitsByTheTypeItPinnedAndNotByThePanesCurrentPage() throws {
    // #184: Mongo infers a type per PAGE, not per column — the same
    // column reports "" at limit 1 and "string" at limit 2. A binding
    // that re-read the type at send would quote the same cell differently
    // depending on how far the source pane happened to be paged.
    let mongo = ApiSourcePane(
        columns: ["_id", "amount"], rows: [[.string("a1"), .string("19.90")]], generation: 1)
    let pinned = ApiPart.bound(ApiBoundValue(
        name: "amount", binding: .live,
        source: ApiValueSource(
            pane: "p3", table: "orders", keyColumns: ["_id"], keyValues: ["a1"],
            column: "amount", declaredType: "bson.Decimal128", generation: 1)))

    let wire = try resolveDraft(
        draft(method: "POST", body: bodyAround(pinned)), sources: ["p3": mongo], credentialed: false
    ).get()

    // Unquoted, from the type it was bound at — and the source pane holds
    // no types at all for it to have read instead.
    #expect(wire.body == "{\"v\":19.90}")
}

// MARK: - The seam itself

@Test func aRowIsFoundByEveryOneOfItsKeyColumns() throws {
    let source = ApiSourcePane(
        columns: ["org", "id", "reference"],
        rows: [
            [.string("acme"), .integer(1), .string("ACME-1")],
            [.string("globex"), .integer(1), .string("GLOBEX-1")],
        ],
        generation: 1)
    let part = ApiPart.bound(ApiBoundValue(
        name: "reference", binding: .live,
        source: ApiValueSource(
            pane: "p3", table: "bookings", keyColumns: ["org", "id"],
            keyValues: ["globex", "1"], column: "reference", declaredType: "TEXT",
            generation: 1)))

    let wire = try resolveDraft(draft(path: [part]), sources: ["p3": source],
    credentialed: false).get()
    #expect(wire.path == "GLOBEX-1")
}

@Test func queryRowsKeepTheOperatorsOwnOrder() throws {
    let wire = try resolveDraft(
        draft(query: [
            ApiQueryRow(name: "z", value: [.literal("1")]),
            ApiQueryRow(name: "a", value: []),
        ]),
        sources: [:], credentialed: false
    ).get()

    #expect(wire.query == [
        ApiWireQueryItem(name: "z", value: "1"),
        ApiWireQueryItem(name: "a", value: ""),
    ])
}

@Test func resolutionIsAReadAndAnswersTheSameThingEveryTime() throws {
    // Pure: no actor, no store, no I/O. The signature is the assertion —
    // every call site in this file is synchronous and non-throwing, so
    // making it `async` or giving it a dependency breaks compilation
    // rather than a test — and this pins that it is also deterministic.
    let subject = draft(
        method: "POST",
        path: [.literal("/v1/bookings/"), live("reference")],
        body: bodyAround(live("total")))
    let first = resolveDraft(subject, sources: ["p3": bookings()], credentialed: false)
    let second = resolveDraft(subject, sources: ["p3": bookings()], credentialed: false)

    #expect(try first.get() == second.get())
    #expect(try first.get().body == "{\"v\":19.9}")
}
