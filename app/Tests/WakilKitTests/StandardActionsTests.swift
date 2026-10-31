import Testing
import Foundation
@testable import WakilKit

@Test func paneSnapshotSerialisesColumnsAndRowsForReadPane() async throws {
    let p = PaneStore()
    await p.setRows(paneId: "db", columns: ["id", "name"], columnTypes: ["INTEGER", "TEXT"],
                    columnTypesInferred: false, rows: [[.number(1), .string("ada")]],
                    millis: 0, truncated: false, pageable: true, offset: 0, sort: [], listsTables: false, editable: nil)
    let snap = await p.readPane(paneId: "db", kind: "db")
    guard case .object(let o) = snap else { Issue.record("not an object"); return }
    #expect(o["columns"] == .array([.string("id"), .string("name")]))
    #expect(o["rowCount"] == .number(1))
}

@Test func snapshotOfAnUnknownPaneIsEmptyNotAnError() async {
    let snap = await PaneStore(kinds: PaneKinds.standard).readPane(paneId: "nope", kind: "db")
    #expect(snap == .object([
        "kind": .string("db"),
        "columns": .array([]), "columnTypes": .array([]), "columnTypesInferred": .bool(false),
        "rows": .array([]), "rowCount": .number(0), "millis": .number(0), "truncated": .bool(false),
        "pageable": .bool(false), "offset": .number(0),
        "selection": .object([
            "anchorRow": .null, "anchorColumn": .null, "rows": .array([]),
        ]),
        "sort": .array([]), "scrollTarget": .null, "failure": .null,
        "listsTables": .bool(false), "running": .bool(false), "cancelledAfterMs": .null,
    ]))
}

// MARK: - The truncation flag, from `wakilcore.Rows` to the pane

/// `wakil-db`'s `query` tool returns `wakilcore.Rows`, and
/// `wakilcore.clampReadLimit` turns an absent or out-of-range `limit` into
/// **500** — which is what every UI query takes, since `WindowModel.runQuery`
/// dispatches `{"query": ...}` with no `limit`. A 5,000-row table therefore
/// comes back as 500 rows with `Rows.Truncated` set, and that flag is the
/// only thing distinguishing it from a table that really has 500 rows.
///
/// These two payloads are not hand-written. They are the literal output of
/// `json.Marshal` on `wakilcore.Rows` values, measured on 2026-09-08 against
/// this tree (go1.27.1):
///
///     Rows{Columns: []string{"id","name"}, Rows: [][]any{{1,"ada"}}, Millis: 3, Truncated: true}
///       -> {"columns":["id","name"],"rows":[[1,"ada"]],"millis":3,"truncated":true}
///     Rows{Columns: []string{"id"}, Rows: [][]any{{1}}, Millis: 3}
///       -> {"columns":["id"],"rows":[[1]],"millis":3}
///
/// The second is the load-bearing one: the field is tagged
/// `json:"truncated,omitempty"`, so a complete result carries **no**
/// `truncated` key at all rather than `false`. A reader that required the
/// key would treat every complete result as malformed and leave the pane
/// untouched. `TestRowsJSONWireShape` (internal/wakilcore/dbdriver_test.go)
/// pins both spellings on the Go side so this literal cannot silently drift
/// from what the binary sends.
private let truncatedRowsPayload = #"{"columns":["id","name"],"rows":[[1,"ada"]],"millis":3,"truncated":true}"#
private let completeRowsPayload = #"{"columns":["id"],"rows":[[1]],"millis":3}"#

/// Wraps a `Rows` JSON text in the `CallToolResult` envelope
/// `MCPClient.callTool` hands back, which is where `db_run_query`'s handler
/// reads it from.
private func callToolResult(structuredContent: String) throws -> JSONValue {
    .object([
        "content": .array([.object(["type": .string("text"), "text": .string(structuredContent)])]),
        "structuredContent": try JSONDecoder().decode(JSONValue.self, from: Data(structuredContent.utf8)),
    ])
}

@Test func dbPaneContentsCarriesTruncatedFromACappedResult() async throws {
    let contents = dbPaneContents(from: try callToolResult(structuredContent: truncatedRowsPayload))
    #expect(contents?.columns == ["id", "name"])
    #expect(contents?.rows == [[.number(1), .string("ada")]])
    #expect(contents?.truncated == true)
}

@Test func dbPaneContentsReadsAnAbsentTruncatedKeyAsComplete() async throws {
    let contents = dbPaneContents(from: try callToolResult(structuredContent: completeRowsPayload))
    #expect(contents?.columns == ["id"])
    #expect(contents?.rows == [[.number(1)]])
    #expect(contents?.truncated == false)
}

// MARK: - `editable` reaches the pane tuple (Task 8, Fix Round 1)
//
// `PaneEditableTests.swift` exercises `paneEditable(from:)` directly, which
// proves the projection but not that `dbPaneContents` actually calls it —
// a wiring mistake (wrong dictionary passed, the call site dropped) would
// pass every one of those tests and still leave every pane with no
// editable block. These two close that gap from the one entry point a
// real result travels through.

private let editableRowsPayload =
    #"""
    {"columns":["kind","note"],"rows":[["a","b"]],"millis":1,
     "editable":{"table":"events","keyColumns":["id"],"columns":["kind","note"],
                 "rowKeys":["\"id\" = '1'"]}}
    """#

@Test func dbPaneContentsCarriesAnEditableBlockThroughToTheTuple() async throws {
    let contents = dbPaneContents(from: try callToolResult(structuredContent: editableRowsPayload))
    #expect(contents?.editable?.table == "events")
    #expect(contents?.editable?.keyColumns == ["id"])
    #expect(contents?.editable?.columns == ["kind", "note"])
    #expect(contents?.editable?.rowKeys == [#""id" = '1'"#])
}

@Test func dbPaneContentsReadsAnAbsentEditableKeyAsNil() async throws {
    // `completeRowsPayload` has no `editable` key at all — the ordinary
    // shape for a join, an aggregate, or any other read the driver did
    // not mark as writable.
    let contents = dbPaneContents(from: try callToolResult(structuredContent: completeRowsPayload))
    #expect(contents?.editable == nil)
}

@Test func dbPaneContentsIsNilForAResultThatIsNotARowsPayload() async throws {
    // A shape the handler does not recognise leaves the pane untouched
    // rather than replacing it with an empty table that would read as
    // "the query returned nothing".
    #expect(dbPaneContents(from: .object([:])) == nil)
    #expect(dbPaneContents(from: .object(["structuredContent": .object(["columns": .array([])])])) == nil)
    #expect(dbPaneContents(from: try callToolResult(structuredContent: #"{"columns":["id"]}"#)) == nil)
}

/// `Int64(1e300)` and `Int64(Double.nan)` *trap*. This function reads a
/// number off a subprocess's JSON, and until 2c-iii the view's projection
/// (`paneTable(from:)`) guarded the identical field a second time while
/// this one converted bare (final review Finding 7) — the hardened reader
/// and the unhardened one, for one value. `paneTable(from:)` is gone now
/// (Decision 24: `PaneTable(dataSurface:)` takes `millis` as an `Int64` directly,
/// with no JSON left to re-parse), so this function is the ONE place that
/// guard has to hold — `PaneStore.setRows` and everything downstream of it
/// simply trust the `Int64` this hands them.
///
/// Constructed as a `JSONValue` rather than as JSON text because
/// `JSONDecoder` rejects a non-finite literal outright, which is the whole
/// reason this reader is the last line of defence rather than the first.
@Test func dbPaneContentsFallsBackRatherThanTrappingOnAnUnusableMillis() async throws {
    for value in [1e300, Double.nan, Double.infinity] {
        let result = JSONValue.object(["structuredContent": .object([
            "columns": .array([.string("id")]),
            "rows": .array([.array([.number(1)])]),
            "millis": .number(value),
        ])])
        let contents = dbPaneContents(from: result)
        // The documented default for an absent `millis`, which is also
        // what an unusable one falls back to — and the footer draws it
        // only when it is above zero, so nothing claims a timing it does
        // not have.
        #expect(contents?.millis == 0)
        #expect(contents?.rows == [[.number(1)]])
    }
}

// MARK: - `columnTypes`: all-or-nothing against the column count
//
// `dbPaneContents`'s gate (`decoded.count == columns.count`) is the whole
// reason `columnTypes` is safe to display at all: a positionally aligned
// slice is only meaningful when it has exactly one entry per column. The
// three tests below are the accept path, the reject-because-short path (the
// one that matters most — see the payload's own comment), and the
// reject-because-long path, so a later "simplification" of the length
// check to something like `zip` or `prefix` fails one of these rather than
// sailing through with every existing test still green.

private let matchingColumnTypesPayload =
    #"{"columns":["id","name"],"columnTypes":["INTEGER","TEXT"],"rows":[[1,"ada"]],"millis":3}"#
private let shortColumnTypesPayload =
    #"{"columns":["id","name"],"columnTypes":["INTEGER"],"rows":[[1,"ada"]],"millis":3}"#
private let longColumnTypesPayload =
    #"{"columns":["id","name"],"columnTypes":["INTEGER","TEXT","EXTRA"],"rows":[[1,"ada"]],"millis":3}"#

@Test func dbPaneContentsKeepsColumnTypesWhenTheyMatchTheColumnCount() async throws {
    let contents = dbPaneContents(from: try callToolResult(structuredContent: matchingColumnTypesPayload))
    // Positionally aligned: "id" is INTEGER, "name" is TEXT, in that order.
    #expect(contents?.columnTypes == ["INTEGER", "TEXT"])
}

@Test func dbPaneContentsDropsColumnTypesEntirelyWhenShorterThanColumns() async throws {
    // One type for two columns is not "one column is annotated and one
    // isn't" — positionally, "INTEGER" would land on "id" and "name" would
    // be left with nothing, which is the correct half of this case. The
    // dangerous half is the general one: with three or more columns, a
    // short slice does not merely annotate fewer columns, it slides every
    // later column's type onto the wrong neighbour. Dropping the whole
    // slice is what keeps a plausible-looking wrong answer off the screen;
    // reporting no types at all is honest where reporting the wrong ones
    // would not be.
    let contents = dbPaneContents(from: try callToolResult(structuredContent: shortColumnTypesPayload))
    #expect(contents?.columnTypes == [])
}

@Test func dbPaneContentsDropsColumnTypesEntirelyWhenLongerThanColumns() async throws {
    // Pins today's behaviour: the gate is an exact-count match, so a slice
    // with MORE entries than columns is rejected exactly like a short one,
    // not truncated to fit.
    let contents = dbPaneContents(from: try callToolResult(structuredContent: longColumnTypesPayload))
    #expect(contents?.columnTypes == [])
}

/// The end of the chain item 1 broke: a capped result must reach
/// `read_pane`'s snapshot — the object served straight to an LLM — as
/// something distinguishable from a complete one. Without the flag an agent
/// asked "how many customers are there?" reads `rowCount: 500` and answers
/// 500.
@Test func aTruncatedResultIsMarkedTruncatedInThePaneSnapshot() async throws {
    let panes = PaneStore()
    let capped = try #require(dbPaneContents(from: try callToolResult(structuredContent: truncatedRowsPayload)))
    await panes.setRows(
        paneId: "db", columns: capped.columns, columnTypes: capped.columnTypes,
        columnTypesInferred: capped.columnTypesInferred, rows: capped.rows,
        millis: capped.millis, truncated: capped.truncated,
        pageable: capped.pageable, offset: 0, sort: [], listsTables: capped.listsTables,
        editable: capped.editable)
    guard case .object(let snap) = await panes.readPane(paneId: "db", kind: "db") else {
        Issue.record("snapshot is not an object")
        return
    }
    #expect(snap["truncated"] == .bool(true))

    // And the same pane, rewritten from a complete result, says so — the
    // flag is per-write, never sticky.
    let complete = try #require(dbPaneContents(from: try callToolResult(structuredContent: completeRowsPayload)))
    await panes.setRows(
        paneId: "db", columns: complete.columns, columnTypes: complete.columnTypes,
        columnTypesInferred: complete.columnTypesInferred, rows: complete.rows,
        millis: complete.millis, truncated: complete.truncated,
        pageable: complete.pageable, offset: 0, sort: [], listsTables: complete.listsTables,
        editable: complete.editable)
    guard case .object(let snap2) = await panes.readPane(paneId: "db", kind: "db") else {
        Issue.record("snapshot is not an object")
        return
    }
    #expect(snap2["truncated"] == .bool(false))
}

// Before `ToolCaller` existed, controlling a DB action's replies meant a
// fake MCP server in `/bin/sh`, a real handshake and a spawned process,
// because `MCPClient` was a concrete actor over a subprocess and
// `wakil-db`'s `query` tool needs Keychain-backed credentials no test here
// may touch. The port removed the subprocess; the harness kept its shape
// and its name so the tests below read unchanged.
private func standardActionsOverStubbedDatabase(
    queryResult: JSONValue, layout: LayoutStore? = nil
) async throws -> (registry: ActionRegistry, panes: PaneStore, client: RecordingToolCaller) {
    let dir = testScratchRoot.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let client = RecordingToolCaller(always: queryResult)
    let panes = PaneStore(kinds: PaneKinds.standard)
    let registry = ActionRegistry(
        journalDirectory: dir.appendingPathComponent("journal"), sessionId: "s1")
    await registerStandardActions(
        into: registry, context: nil, panes: panes, db: client, resumes: ResumeBroker(),
        layout: layout)
    return (registry, panes, client)
}

// MARK: - `db_run_query` records the subject and routes by it (Task 9)
//
// `DBActionHarness` differs from `standardActionsOverStubbedDatabase` above
// in three ways every test below needs: it owns a `LayoutStore` of its own
// rather than taking one by parameter, it builds the stubbed rows from a
// plain literal instead of a hand-written JSON payload, and it exposes the
// calls `RecordingToolCaller` recorded so a test can check what reached the
// port, not only what `LayoutStore` or `PaneStore` ended up holding.
private final class DBActionHarness: Sendable {
    let registry: ActionRegistry
    let layout: LayoutStore
    let panes: PaneStore
    private let client: RecordingToolCaller

    /// `rows`'s first element is the column names; every element after it
    /// is one data row — `[["id"], [1]]` is a single "id" column holding
    /// one row, `1`. `[[Any]]` rather than `[[JSONValue]]` because every
    /// call site writes plain literals (`["id"]`, `[1]`) and `JSONValue`
    /// has neither `ExpressibleByStringLiteral` nor
    /// `ExpressibleByIntegerLiteral` for those to resolve against.
    ///
    /// This shape is what `db_run_query` and `db_read_table` both read
    /// through `dbPaneContents(from:)`.
    convenience init(rows: [[Any]]) async throws {
        let header = (rows.first ?? []).compactMap { $0 as? String }
        let dataRows = rows.dropFirst().map { row in
            JSONValue.array(row.map(Self.jsonValue))
        }
        let resultObject = JSONValue.object([
            "content": .array([.object(["type": .string("text"), "text": .string("stub")])]),
            "structuredContent": .object([
                "columns": .array(header.map { .string($0) }),
                "rows": .array(Array(dataRows)),
                "millis": .number(0),
            ]),
        ])
        try await self.init(resultObject: resultObject)
    }

    /// One `(name, kind)` pair per table or collection — the shape
    /// `db_list_tables` reads through `containerListPaneContents(from:)`,
    /// which is `ListContainers`'s own top-level `containers` key rather
    /// than the `columns`/`rows` shape `rows:` above builds.
    convenience init(containers: [(String, String)]) async throws {
        let resultObject = JSONValue.object([
            "content": .array([.object(["type": .string("text"), "text": .string("stub")])]),
            "structuredContent": .object([
                "containers": .array(containers.map { name, kind in
                    .object(["name": .string(name), "kind": .string(kind)])
                }),
            ]),
        ])
        try await self.init(resultObject: resultObject)
    }

    /// One `(name, type)` pair per column — the shape `db_describe_table`
    /// reads through `schemaPaneContents(from:)`. This fixture never
    /// supplies `key`, so every row's `key` reads `false`, which is what
    /// `schemaPaneContents` falls back to for an absent key — the shape a
    /// keyless driver (`mongoConn.Describe`, which has no primary key to
    /// report) actually sends. `sqlConn.Describe` populates the field for
    /// real tables; this fixture just does not model that path.
    convenience init(schema: [(String, String)]) async throws {
        let resultObject = JSONValue.object([
            "content": .array([.object(["type": .string("text"), "text": .string("stub")])]),
            "structuredContent": .object([
                "columns": .array(schema.map { name, type in
                    .object(["name": .string(name), "type": .string(type)])
                }),
            ]),
        ])
        try await self.init(resultObject: resultObject)
    }

    /// The shape `db_list_databases` reads — `wakilcore.DatabaseList`'s
    /// own `{"databases":[{name, driver, writable}]}` under
    /// `structuredContent`, which is what the query line's chooser is fed
    /// from.
    convenience init(databases: [(name: String, driver: String, writable: Bool)]) async throws {
        let resultObject = JSONValue.object([
            "content": .array([.object(["type": .string("text"), "text": .string("stub")])]),
            "structuredContent": .object([
                "databases": .array(databases.map { entry in
                    .object([
                        "name": .string(entry.name),
                        "driver": .string(entry.driver),
                        "writable": .bool(entry.writable),
                    ])
                }),
            ]),
        ])
        try await self.init(resultObject: resultObject)
    }

    /// The shape `db_classify_statement` reads through `callChecked` — a
    /// bare `{"kind": ..., "reason": ...}` under `structuredContent`,
    /// `wakilcore.StatementClass`'s own JSON shape. `reason` is omitted
    /// entirely when empty, matching its Go tag `json:"reason,omitempty"`.
    convenience init(classification: (kind: String, reason: String)) async throws {
        var structured: [String: JSONValue] = ["kind": .string(classification.kind)]
        if !classification.reason.isEmpty {
            structured["reason"] = .string(classification.reason)
        }
        let resultObject = JSONValue.object([
            "content": .array([.object(["type": .string("text"), "text": .string("stub")])]),
            "structuredContent": .object(structured),
        ])
        try await self.init(resultObject: resultObject)
    }

    /// The shape `db_render_update` reads through `callChecked` — a bare
    /// `{"statement": ...}` under `structuredContent`, `render_update`'s own
    /// JSON shape.
    convenience init(renderedStatement statement: String) async throws {
        let resultObject = JSONValue.object([
            "content": .array([.object(["type": .string("text"), "text": .string(statement)])]),
            "structuredContent": .object(["statement": .string(statement)]),
        ])
        try await self.init(resultObject: resultObject)
    }

    /// A stub that answers every `tools/call` with an MCP error result —
    /// `isError: true` plus the message, which is what `callChecked`
    /// collapses into `StandardActionError.serverError`. The shape a
    /// timed-out engine, a restarted server or a refused statement all
    /// reach a handler as, and the only way to observe what a handler
    /// leaves behind when its round trip does NOT come back.
    convenience init(failingWith message: String) async throws {
        let resultObject = JSONValue.object([
            "isError": .bool(true),
            "content": .array([.object(["type": .string("text"), "text": .string(message)])]),
        ])
        try await self.init(resultObject: resultObject)
    }

    /// The shared build every convenience init above delegates to: a
    /// `RecordingToolCaller` that answers every call with `resultObject`
    /// regardless of which tool was named, and a registry wired to it.
    private init(resultObject: JSONValue) async throws {
        let dir = testScratchRoot.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        client = RecordingToolCaller(always: resultObject)

        panes = PaneStore()
        layout = LayoutStore()
        registry = ActionRegistry(
            journalDirectory: dir.appendingPathComponent("journal"), sessionId: "s1")
        await registerStandardActions(
            into: registry, context: nil, panes: panes, db: client, resumes: ResumeBroker(),
            layout: layout)
    }

    private static func jsonValue(_ any: Any) -> JSONValue {
        switch any {
        case let s as String: return .string(s)
        case let i as Int: return .number(Double(i))
        case let d as Double: return .number(d)
        case let b as Bool: return .bool(b)
        default: return .null
        }
    }

    /// The tool name of the most recent call `RecordingToolCaller` recorded.
    var lastTool: String? {
        get async { await lastCall()?.name }
    }

    /// The arguments of the most recent call `RecordingToolCaller`
    /// recorded — proof a value reached the port, not just `LayoutStore`
    /// or `PaneStore`. Empty, not `nil`, when nothing has
    /// been dispatched yet: every test that reads this has already
    /// dispatched once, and an empty dictionary fails a `["key"] ==
    /// .number(n)` comparison exactly as usefully as `nil` would.
    var lastArguments: [String: JSONValue] {
        get async { (await lastCall()?.arguments) ?? [:] }
    }

    /// Drops every recorded call, so a later `lastTool`/`lastArguments` read
    /// reports only what the dispatch under test sent — not a setup call
    /// the test made to get the harness into position (opening a pane,
    /// seeding a fetch) before the thing it means to observe.
    func resetCallLog() async {
        await client.reset()
    }

    private func lastCall() async -> (name: String, arguments: [String: JSONValue])? {
        guard let call = await client.calls.last else { return nil }
        guard case .object(let args) = call.arguments else { return (call.name, [:]) }
        return (call.name, args)
    }
}

// MARK: - DB action tests, over the `ToolCaller` port (Task 11 fix round 1)
//
// Every test below builds a `DBActionHarness` or calls
// `standardActionsOverStubbedDatabase`. Neither spawns anything today —
// see the end of this comment — but both once did, and the history is
// why this group looks the way it does.
//
// Originally both spawned a real `/bin/sh` subprocess and performed a
// real MCP `initialize` handshake (`MCPClient.start()`). Tasks 9, 10 and
// 11 had by then grown this group to roughly two dozen tests — it has
// since more than doubled, to 65 at the time of writing; a
// `--filter DBActionTests` run prints the count of the day, so trust
// that over this sentence. Under Swift Testing's default parallel
// execution those two dozen were two dozen concurrent shell
// subprocesses doing line-buffered I/O,
// contending with the rest of this target's own subprocess-heavy tests,
// and the handshake started missing its own timeout — not on every test,
// and not the same test twice in a row, which is what made it easy to wave
// away as "that flaky one again". `.serialized` was added here for the
// same reason `StopDeliversTheTailOfTheStreamSuite`
// (`ClaudeCodeCLIHarnessTests.swift`) still carries it: stop making tests
// compete for the machine rather than loosen what any of them measure.
//
// Two alternatives were considered and rejected at the time: raising the
// `initialize` timeout would have papered over a machine- and
// load-dependent race rather than fixed the contention, and extracting a
// protocol from `MCPClient` so these tests could run against an in-process
// fake was judged the structurally nicer answer but too large a change to
// justify for a flakiness fix alone. That extraction happened anyway, for
// reasons beyond this suite's flakiness — see `ToolCaller` — and this
// suite now rides it: `DBActionHarness` and
// `standardActionsOverStubbedDatabase` stub `RecordingToolCaller` rather
// than spawning a shell, so there is no subprocess left to serialize
// against. `RecordingToolCaller` holds its state in an actor, one instance
// per test, so there is nothing left to contend over, which is why
// `.serialized` came off.
@Suite
struct DBActionTests {
    // MARK: - Schema browsing is the data surface (Task 10)
    //
    // `db_list_tables`, `db_describe_table` and `db_read_table` draw metadata
    // on the same grid `db_run_query` already draws rows on — no new view, no
    // sidebar, no tree. These pin that each one routes like a query
    // (`resolvePane`/`requireOpenPane`), records the right `PaneQuery` subject,
    // and is `.read` rather than `.control` because every one of them reaches
    // a real database.

    @Test func listingTablesDrawsThemAsRows() async throws {
        let harness = try await DBActionHarness(
            containers: [("events", "table"), ("customers", "table")])
        _ = try await harness.registry.dispatch(
            name: "db_list_tables", params: .object([:]),
            origin: .agent, caller: .test("staging"), confirmation: nil)
        let pane = await harness.layout.snapshot().panes[0]
        #expect(pane.fetch?.query == .tables(database: nil))
        guard case .object(let snap) = await harness.panes.readPane(paneId: pane.id, kind: "db"),
              case .array(let columns)? = snap["columns"] else {
            Issue.record("no columns"); return
        }
        #expect(columns == [.string("name"), .string("kind")])
        #expect(snap["rowCount"] == .number(2))
        // A table list is complete by construction — the driver returns
        // everything the server reports or fails — so it is never truncated
        // and never pageable.
        #expect(snap["truncated"] == .bool(false))
        #expect(snap["pageable"] == .bool(false))
    }

    @Test func describingATableDrawsItsColumnsAsRows() async throws {
        let harness = try await DBActionHarness(
            schema: [("id", "INTEGER"), ("kind", "TEXT")])
        _ = try await harness.registry.dispatch(
            name: "db_describe_table", params: .object(["table": .string("events")]),
            origin: .agent, caller: .test("staging"), confirmation: nil)
        let pane = await harness.layout.snapshot().panes[0]
        #expect(pane.fetch?.query == .columns(database: nil, table: "events"))
        guard case .object(let snap) = await harness.panes.readPane(paneId: pane.id, kind: "db"),
              case .array(let columns)? = snap["columns"] else {
            Issue.record("no columns"); return
        }
        #expect(columns == [.string("name"), .string("type"), .string("key")])
    }

    @Test func describingATableNeedsATableName() async throws {
        let harness = try await DBActionHarness(schema: [])
        await #expect(throws: StandardActionError.self) {
            _ = try await harness.registry.dispatch(
                name: "db_describe_table", params: .object([:]),
                origin: .agent, caller: .test("staging"), confirmation: nil)
        }
    }

    @Test func readingATableRecordsItAsTheSubject() async throws {
        let harness = try await DBActionHarness(rows: [["id", "kind"], [1, "a"]])
        _ = try await harness.registry.dispatch(
            name: "db_read_table", params: .object(["table": .string("events")]),
            origin: .agent, caller: .test("staging"), confirmation: nil)
        let pane = await harness.layout.snapshot().panes[0]
        #expect(pane.fetch?.query == .table(database: nil, name: "events"))
        // Which is the whole reason .table exists as its own case rather than
        // as a composed SELECT: the subject survives, so paging and relaunch
        // can re-render it for whatever driver the pane is against.
        #expect(await harness.lastTool == "read_table")
    }

    @Test func schemaBrowsingObeysTheSameRoutingRuleAsAQuery() async throws {
        let harness = try await DBActionHarness(
            containers: [("events", "table")])
        let existing = await harness.layout.open(kind: "db", title: "main")
        _ = try await harness.registry.dispatch(
            name: "db_list_tables", params: .object(["pane": .string(existing.id)]),
            origin: .agent, caller: .test("staging"), confirmation: nil)
        #expect(await harness.layout.snapshot().panes.count == 1)
        _ = try await harness.registry.dispatch(
            name: "db_list_tables", params: .object([:]),
            origin: .agent, caller: .test("staging"), confirmation: nil)
        #expect(await harness.layout.snapshot().panes.count == 2)
    }

    @Test func allThreeSchemaActionsAreReadsNotControls() async throws {
        let harness = try await DBActionHarness(rows: [["id"], [1]])
        let descriptors = await harness.registry.all()
        for name in ["db_list_tables", "db_describe_table", "db_read_table"] {
            guard let action = descriptors.first(where: { $0.name == name }) else {
                Issue.record("\(name) is not registered"); continue
            }
            // Each one reaches a database. `.control` is for state that never
            // leaves Wakil, which is why 2c-i's six pane-content actions are
            // `.control` and these are not.
            #expect(action.kind == .read)
        }
    }

    @Test func aQueryWithNoPaneOpensOne() async throws {
        let harness = try await DBActionHarness(rows: [["id"], [1]])
        _ = try await harness.registry.dispatch(
            name: "db_run_query", params: .object(["query": .string("SELECT * FROM events")]),
            origin: .agent, caller: .test("staging"), confirmation: nil)
        let snapshot = await harness.layout.snapshot()
        #expect(snapshot.panes.count == 1)
        #expect(snapshot.panes[0].kind == "db")
    }

    @Test func aSecondQueryWithNoPaneOpensASecondPane() async throws {
        // The operator's flow: "query table B" is a different subject, so it
        // gets its own pane rather than replacing table A's.
        let harness = try await DBActionHarness(rows: [["id"], [1]])
        for _ in 0..<2 {
            _ = try await harness.registry.dispatch(
                name: "db_run_query", params: .object(["query": .string("SELECT * FROM events")]),
                origin: .agent, caller: .test("staging"), confirmation: nil)
        }
        #expect(await harness.layout.snapshot().panes.count == 2)
    }

    @Test func aQueryNamingAPaneRefinesItInPlace() async throws {
        let harness = try await DBActionHarness(rows: [["id"], [1]])
        let pane = await harness.layout.open(kind: "db", title: "main")
        _ = try await harness.registry.dispatch(
            name: "db_run_query",
            params: .object(["query": .string("SELECT * FROM events WHERE id = 1"),
                     "pane": .string(pane.id)]),
            origin: .agent, caller: .test("staging"), confirmation: nil)
        let snapshot = await harness.layout.snapshot()
        #expect(snapshot.panes.count == 1)
        #expect(snapshot.panes[0].fetch?.query
                == .sql(database: nil, raw: "SELECT * FROM events WHERE id = 1"))
    }

    @Test func aQueryRecordsTheSubjectIncludingItsDatabase() async throws {
        let harness = try await DBActionHarness(rows: [["id"], [1]])
        _ = try await harness.registry.dispatch(
            name: "db_run_query",
            params: .object(["query": .string("SELECT 1"), "database": .string("analytics")]),
            origin: .agent, caller: .test("staging"), confirmation: nil)
        let fetch = await harness.layout.snapshot().panes[0].fetch
        #expect(fetch?.query == .sql(database: "analytics", raw: "SELECT 1"))
        #expect(fetch?.offset == 0)
    }

    @Test func namingAPaneThatIsNotOpenIsStillAnError() async throws {
        // Unchanged from 2c-i and deliberately so. Under the new routing an
        // unknown id could silently become "open a new pane", which is the
        // same class of quiet failure the check was added against.
        let harness = try await DBActionHarness(rows: [["id"], [1]])
        await #expect(throws: StandardActionError.self) {
            _ = try await harness.registry.dispatch(
                name: "db_run_query",
                params: .object(["query": .string("SELECT 1"), "pane": .string("db-404")]),
                origin: .agent, caller: .test("staging"), confirmation: nil)
        }
    }

    @Test func aQueryAtAnOffsetRecordsWhereThePaneIs() async throws {
        let harness = try await DBActionHarness(rows: [["id"], [1]])
        let pane = await harness.layout.open(kind: "db", title: "main")
        _ = try await harness.registry.dispatch(
            name: "db_run_query",
            params: .object(["query": .string("SELECT 1"), "pane": .string(pane.id),
                     "offset": .number(500)]),
            origin: .agent, caller: .test("staging"), confirmation: nil)
        #expect(await harness.layout.fetch(id: pane.id)?.offset == 500)
        // And the offset reaches the server, not just the layout.
        #expect(await harness.lastArguments["offset"] == .number(500))
    }

    @Test func theResultTellsTheAgentWhichPaneItLandedIn() async throws {
        let harness = try await DBActionHarness(rows: [["id"], [1]])
        let result = try await harness.registry.dispatch(
            name: "db_run_query", params: .object(["query": .string("SELECT 1")]),
            origin: .agent, caller: .test("staging"), confirmation: nil)
        guard case .object(let obj) = result, case .string(let pane)? = obj["pane"] else {
            Issue.record("the result must name the pane"); return
        }
        #expect(pane == "db-1")
        // The routing rule only works if the agent is handed the id the rule
        // needs. This is that hand-off.
        #expect(obj["drawn"] == .bool(true))
    }

    @Test func dbRunQueryWritesToTheNamedPane() async throws {
        let (registry, panes, _) = try await standardActionsOverStubbedDatabase(
            queryResult: .object([
                "structuredContent": .object([
                    "columns": .array([.string("id")]),
                    "columnTypes": .array([.string("INTEGER")]),
                    "rows": .array([.array([.number(7)])]),
                    "millis": .number(3),
                ])
            ]))

        _ = try await registry.dispatch(
            name: "db_run_query",
            params: .object(["query": .string("select 1"), "pane": .string("db-2")]),
            origin: .agent, caller: .test("staging"), confirmation: nil)

        guard case .object(let named) = await panes.readPane(paneId: "db-2", kind: "db"),
              case .object(let fallback) = await panes.readPane(paneId: "db", kind: "db") else {
            Issue.record("snapshot is not an object")
            return
        }
        #expect(named["rowCount"] == .number(1))
        // The old hardcoded "db" must be genuinely unwritten, not merely
        // also written — two panes showing one result is the bug this
        // parameter exists to make impossible.
        #expect(fallback["rowCount"] == .number(0))
    }

    @Test func dbRunQueryStillDefaultsToTheDbPane() async throws {
        let (registry, panes, _) = try await standardActionsOverStubbedDatabase(
            queryResult: .object([
                "structuredContent": .object([
                    "columns": .array([.string("id")]),
                    "rows": .array([.array([.number(7)])]),
                ])
            ]))

        _ = try await registry.dispatch(
            name: "db_run_query", params: .object(["query": .string("select 1")]),
            origin: .agent, caller: .test("staging"), confirmation: nil)
        guard case .object(let fallback) = await panes.readPane(paneId: "db", kind: "db") else {
            Issue.record("snapshot is not an object")
            return
        }
        #expect(fallback["rowCount"] == .number(1))
    }

    // MARK: - An unnamed query must not clobber a pane that already exists
    //
    // 2c-ii's whole rationale rests on this: "query A, filter, filter, sort,
    // then query B" must not have query B land on the pane query A built up,
    // because that destroys the filter chain — the subject as well as the
    // rows. `dbRunQueryWithNoPaneOpenOpensOneAndDrawsInIt` proves an unnamed
    // query opens a pane when none exists, but a canvas with nothing open
    // cannot distinguish "opens a new pane" from "reuses the only pane there
    // is" — this is the one integration-level proof of that distinction, with
    // a pane already open and already holding rows.
    @Test func dbRunQueryWithNoPaneParamOpensANewPaneRatherThanReusingTheOneAlreadyOpen() async throws {
        let layout = LayoutStore()
        let existing = await layout.open(kind: "db", title: "Results")

        let (registry, panes, _) = try await standardActionsOverStubbedDatabase(
            queryResult: .object([
                "structuredContent": .object([
                    "columns": .array([.string("id")]),
                    "columnTypes": .array([.string("INTEGER")]),
                    "rows": .array([.array([.number(7)])]),
                    "millis": .number(3),
                ])
            ]), layout: layout)

        // The existing pane already holds a known result — the filter chain
        // an unnamed query must not be allowed to clobber.
        await panes.setRows(
            paneId: existing.id, columns: ["id"], columnTypes: ["INTEGER"],
            columnTypesInferred: false, rows: [[.number(1)]],
            millis: 0, truncated: false, pageable: true, offset: 0, sort: [], listsTables: false, editable: nil)

        _ = try await registry.dispatch(
            name: "db_run_query", params: .object(["query": .string("select 1")]),
            origin: .agent, caller: .test("staging"), confirmation: nil)

        // A second, separate pane now exists...
        let allPanes = await layout.snapshot().panes
        #expect(allPanes.count == 2)
        let opened = try #require(allPanes.first(where: { $0.id != existing.id }))

        guard case .object(let onNewPane) = await panes.readPane(paneId: opened.id, kind: "db") else {
            Issue.record("snapshot is not an object")
            return
        }
        #expect(onNewPane["rows"] == .array([.array([.number(7)])]))

        // ...and the first pane's rows are untouched.
        guard case .object(let onExisting) = await panes.readPane(paneId: existing.id, kind: "db") else {
            Issue.record("snapshot is not an object")
            return
        }
        #expect(onExisting["rows"] == .array([.array([.number(1)])]))
    }


    // MARK: - A named pane is retitled to what it is now showing (walk defect D3)

    /// **The pane that said DOCS over `events` rows.** `Pane.title` was
    /// written once by `LayoutStore.open` and never again, so a pane opened
    /// against a Mongo collection and then pointed at a SQL table by the
    /// query line kept drawing the Mongo database's name over the SQL
    /// table's rows — and the rail listed it under that name too. 2c-i's
    /// walk raised the same complaint in the other direction and it was
    /// answered by drawing the query underneath the title, which left the
    /// title itself lying.
    ///
    /// The title written is not a guess: it is the same value this pane
    /// would have been born with had the new subject opened it.
    @Test func dbRunQueryRetitlesTheNamedPaneToTheDatabaseItIsNowShowing() async throws {
        let layout = LayoutStore()
        let existing = await layout.open(kind: "db", title: "docs")

        let (registry, _, _) = try await standardActionsOverStubbedDatabase(
            queryResult: .object([
                "structuredContent": .object([
                    "columns": .array([.string("id")]),
                    "columnTypes": .array([.string("INTEGER")]),
                    "rows": .array([.array([.number(7)])]),
                    "millis": .number(3),
                ])
            ]), layout: layout)

        _ = try await registry.dispatch(
            name: "db_run_query",
            params: .object([
                "query": .string("select * from events"),
                "database": .string("events"),
                "pane": .string(existing.id),
            ]),
            origin: .ui, caller: .test("staging"), confirmation: nil)

        let pane = try #require(
            await layout.snapshot().panes.first(where: { $0.id == existing.id }))
        #expect(pane.title == "events")
        // Still the same pane, not a replacement: a retitle must not
        // cost the operator the frame, the column widths or the id an
        // agent is holding.
        #expect(await layout.snapshot().panes.count == 1)
    }

    /// **A subject with no name keeps the name it had.** `database` is
    /// optional on `db_run_query` — a one-database environment lets it go
    /// unsent — and the fallback used when OPENING a pane is the literal
    /// `"db"`. Retitling on that fallback would replace a stale-but-real
    /// name with a meaningless one, which is worse than the defect.
    @Test func dbRunQueryLeavesTheTitleAloneWhenTheCallNamesNoDatabase() async throws {
        let layout = LayoutStore()
        let existing = await layout.open(kind: "db", title: "events")

        let (registry, _, _) = try await standardActionsOverStubbedDatabase(
            queryResult: .object([
                "structuredContent": .object([
                    "columns": .array([.string("id")]),
                    "columnTypes": .array([.string("INTEGER")]),
                    "rows": .array([.array([.number(7)])]),
                    "millis": .number(3),
                ])
            ]), layout: layout)

        _ = try await registry.dispatch(
            name: "db_run_query",
            params: .object([
                "query": .string("select * from events"),
                "pane": .string(existing.id),
            ]),
            origin: .ui, caller: .test("staging"), confirmation: nil)

        let pane = try #require(
            await layout.snapshot().panes.first(where: { $0.id == existing.id }))
        #expect(pane.title == "events")
    }

    // MARK: - A pane that is not open is an error, not a silent write
    //
    // DEFECT X (acceptance §5.6) fixed the *default* pane and left the explicit
    // one able to reach the same failure: `queryTargetPane` returns an explicit
    // id unchanged, so rows went into `PaneStore` under whatever key was given
    // and a key no pane holds is a pane nothing draws. An agent that had been
    // told a pane id by no one — because `pane_open`'s reply reached it as
    // "completed with no output" — passed the titles it had chosen instead, and
    // got three panes reading "no rows" next to three tool results showing the
    // rows plainly. Both halves are fixed; this covers the second.

    @Test func dbRunQueryRefusesAPaneThatIsNotOpen() async throws {
        let layout = LayoutStore()
        let real = await layout.open(kind: "db", title: "Customers")
        let (registry, panes, _) = try await standardActionsOverStubbedDatabase(
            queryResult: .object([
                "structuredContent": .object([
                    "columns": .array([.string("id")]),
                    "columnTypes": .array([.string("INTEGER")]),
                    "rows": .array([.array([.number(7)])]),
                    "millis": .number(3),
                ])
            ]),
            layout: layout)

        do {
            _ = try await registry.dispatch(
                name: "db_run_query",
                // The title the agent chose, not the id it was minted.
                params: .object([
                    "query": .string("select 1"), "pane": .string("core.customers"),
                ]),
                origin: .agent, caller: .test("staging"), confirmation: nil)
            Issue.record("a pane id that names nothing should not have been accepted")
        } catch let error as StandardActionError {
            guard case .unknownPane(_, let named, let open) = error else {
                Issue.record("expected .unknownPane, got \(error)")
                return
            }
            #expect(named == "core.customers")
            #expect(open == [real.id])
            // The message must carry the id that WOULD have worked, so the
            // agent can retry without a second round trip to read_layout.
            #expect(error.description.contains(real.id))
        }

        // Nothing was written anywhere — not under the bad key, and not
        // into the real pane as a consolation.
        guard case .object(let dead) = await panes.readPane(paneId: "core.customers", kind: "db"),
              case .object(let good) = await panes.readPane(paneId: real.id, kind: "db") else {
            Issue.record("snapshot is not an object")
            return
        }
        #expect(dead["rows"] == .array([]))
        #expect(good["rows"] == .array([]))
    }

    /// The same call with the id the pane actually has goes through, so the
    /// check above is rejecting a wrong id rather than rejecting the parameter.
    @Test func dbRunQueryAcceptsThePaneIdThatPaneOpenMinted() async throws {
        let layout = LayoutStore()
        let real = await layout.open(kind: "db", title: "Customers")
        let (registry, panes, _) = try await standardActionsOverStubbedDatabase(
            queryResult: .object([
                "structuredContent": .object([
                    "columns": .array([.string("id")]),
                    "columnTypes": .array([.string("INTEGER")]),
                    "rows": .array([.array([.number(7)])]),
                    "millis": .number(3),
                ])
            ]),
            layout: layout)

        _ = try await registry.dispatch(
            name: "db_run_query",
            params: .object(["query": .string("select 1"), "pane": .string(real.id)]),
            origin: .agent, caller: .test("staging"), confirmation: nil)

        guard case .object(let snapshot) = await panes.readPane(paneId: real.id, kind: "db") else {
            Issue.record("snapshot is not an object")
            return
        }
        #expect(snapshot["rows"] == .array([.array([.number(7)])]))
    }

    /// The result echoes back which pane it drew into. That property is not
    /// retired by 2c-ii's inversion — `annotatedWithPaneOutcome` still sets it
    /// unconditionally — and it is load-bearing for the whole routing rule:
    /// an agent can only refine a pane (name it on a later query) if it read
    /// the id off a prior result. This is the "refine" half of the guarantee
    /// — an explicit pane, already open, so no pane opens and no `paneNote`
    /// appears; `dbRunQueryWithNoPaneOpenOpensOneAndDrawsInIt` covers the
    /// "open a new one" half, where a `paneNote` does appear.
    @Test func dbRunQueryNamesThePaneItDrewInto() async throws {
        let layout = LayoutStore()
        let real = await layout.open(kind: "db", title: "Events")
        let (registry, panes, _) = try await standardActionsOverStubbedDatabase(
            queryResult: .object([
                "structuredContent": .object([
                    "columns": .array([.string("id")]),
                    "columnTypes": .array([.string("INTEGER")]),
                    "rows": .array([.array([.number(7)])]),
                    "millis": .number(3),
                ])
            ]),
            layout: layout)

        let result = try await registry.dispatch(
            name: "db_run_query",
            params: .object(["query": .string("select 1"), "pane": .string(real.id)]),
            origin: .agent, caller: .test("staging"), confirmation: nil)

        guard case .object(let obj) = result else {
            Issue.record("db_run_query did not return an object")
            return
        }
        #expect(obj["drawn"] == .bool(true))
        #expect(obj["pane"] == .string(real.id))
        #expect(obj["paneNote"] == nil)

        guard case .object(let snapshot) = await panes.readPane(paneId: real.id, kind: "db") else {
            Issue.record("snapshot is not an object")
            return
        }
        #expect(snapshot["rows"] == .array([.array([.number(7)])]))
    }

    // MARK: - Rows with nowhere to go get somewhere to go
    //
    // With no database pane open, `queryTargetPane` falls back to the literal
    // `"db"` — an id `LayoutStore` never mints — and the rows went into
    // `PaneStore` under a key nothing draws, while the agent reported "results
    // were written to the focused DB pane" to an operator looking at an empty
    // canvas. The first fix reported the miss (`drawn: false`, a note naming
    // `pane_open` as the remedy) and stopped; the operator walk showed what
    // that buys — an agent that relays "no pane is open, here are the raw
    // results" and stops too. The operator ruled ("it says nothing is open and
    // still doesnt open them"), so the action now opens the pane itself.

    @Test func dbRunQueryWithNoPaneOpenOpensOneAndDrawsInIt() async throws {
        let layout = LayoutStore()  // no panes at all
        let (registry, panes, _) = try await standardActionsOverStubbedDatabase(
            queryResult: .object([
                "structuredContent": .object([
                    "columns": .array([.string("id")]),
                    "columnTypes": .array([.string("INTEGER")]),
                    "rows": .array([.array([.number(7)])]),
                    "millis": .number(3),
                ])
            ]),
            layout: layout)

        let result = try await registry.dispatch(
            name: "db_run_query",
            params: .object(["query": .string("select 1"), "database": .string("events")]),
            origin: .agent, caller: .test("staging"), confirmation: nil)

        // A real pane now exists — kind "db" so every route keyed on kind
        // finds it, titled after the database the rows came from, focused
        // the way `LayoutStore.open` focuses everything it mints.
        let opened = try #require(await layout.snapshot().panes.first)
        #expect(opened.kind == "db")
        #expect(opened.title == "events")
        #expect(await layout.snapshot().focusedId == opened.id)

        // The rows are in it, not under the dead `"db"` key.
        guard case .object(let snapshot) = await panes.readPane(paneId: opened.id, kind: "db"),
              case .object(let dead) = await panes.readPane(paneId: "db", kind: "db") else {
            Issue.record("snapshot is not an object")
            return
        }
        #expect(snapshot["rows"] == .array([.array([.number(7)])]))
        #expect(dead["rows"] == .array([]))

        // And the result says what happened, so the agent's account of the
        // screen is true in this direction too.
        guard case .object(let obj) = result else {
            Issue.record("db_run_query did not return an object")
            return
        }
        #expect(obj["drawn"] == .bool(true))
        #expect(obj["pane"] == .string(opened.id))
        guard case .string(let note)? = obj["paneNote"] else {
            Issue.record("no paneNote on an auto-opened result: \(obj)")
            return
        }
        #expect(note.contains(opened.id))
    }

    /// The description is the only place an agent can learn two facts the rows
    /// themselves never carry: that a pane's rows are REPLACED rather than
    /// accumulated, and that at most 1000 rows come back per query. Without
    /// them, "fetch all from events" (1,006 rows) became five batched queries
    /// naming the same pane each time, each one replacing it, ending with the
    /// last 6 rows on screen under an agent report of "all 1,006 rows fetched
    /// and drawn in pane db-1" — the incident this whole phase exists against.
    ///
    /// **The replacement fact must appear twice, not once** (fix round 1):
    /// once in the WHICH PANE paragraph ("naming a pane... it replaces that
    /// pane's rows") and again in the PAGING paragraph ("Each page REPLACES
    /// what the pane was showing... pages do not accumulate"). An agent
    /// reading only about paging — which is exactly the agent that caused the
    /// incident above — must not be able to read `offset`/`limit` as
    /// accumulating rows across calls just because the fact was stated
    /// somewhere else in the text. `replacesCount >= 2` is what pins that:
    /// trimming either paragraph's restatement back to a single mention (or
    /// deleting the PAGING one, believing WHICH PANE already "covers" the
    /// same fact) drops the count to 1 and fails here, rather than passing
    /// unnoticed because *some* substring called "replaces" is still present
    /// somewhere in the string. `"do not accumulate"` pins the PAGING
    /// paragraph's specific claim by itself, so a rewrite that keeps the word
    /// "replaces" twice but drops the "pages do not accumulate" consequence
    /// still fails.
    @Test func dbRunQuerySaysItsResultReplacesThePaneAndNamesTheCap() async throws {
        let (registry, _, _) = try await standardActionsOverStubbedDatabase(
            queryResult: .object(["structuredContent": .object([:])]))
        let action = try #require(await registry.all().first { $0.name == "db_run_query" })
        let replacesCount = action.description.lowercased()
            .components(separatedBy: "replaces").count - 1
        #expect(replacesCount >= 2, """
            the replacement fact must be stated in both the WHICH PANE and PAGING \
            paragraphs, not just one: \(action.description)
            """)
        #expect(action.description.contains("do not accumulate"))
        #expect(action.description.contains("1000"))
    }

    // MARK: - One re-fetch path, and the two actions that drive it (Task 11)
    //
    // `refetchPane` is the single home for the subject-to-tool-call mapping
    // that `db_refetch`, `db_page`, `pane_sort`'s re-query branch and the
    // window's relaunch restore all need. `pane_sort` and relaunch are covered
    // by their own tasks; these drive `refetchPane` through its two actions.
    //
    // **Adapted from the task brief's Swift, not copied verbatim.**
    // `ActionRegistry.dispatch` takes `name:`/`params:`/`confirmation:` labels
    // with no defaulted overload, so every call below spells those out; the
    // brief's positional, label-free form does not compile against the actual
    // signature. `eachSubjectRefetchesThroughItsOwnTool` also drops the
    // brief's `containers:`/`schema:` arguments to `DBActionHarness` — there is
    // no combined initializer taking rows, containers and schema at once, and
    // the test only reads `lastTool`, which one plain rows-shaped stub result
    // already proves for all four subjects: `containerListPaneContents` and
    // `schemaPaneContents` either find what they need in it or return `nil`,
    // and `refetchPane` logs the tool call before consulting either.

    @Test func refetchingRunsThePanesOwnSubject() async throws {
        let harness = try await DBActionHarness(rows: [["id"], [1]])
        let pane = await harness.layout.open(kind: "db", title: "main")
        await harness.layout.setFetch(
            PaneFetch(query: .sql(database: "main", raw: "SELECT * FROM events")), id: pane.id)
        _ = try await harness.registry.dispatch(
            name: "db_refetch", params: .object(["pane": .string(pane.id)]),
            origin: .agent, caller: .test("staging"), confirmation: nil)
        #expect(await harness.lastTool == "query")
        #expect(await harness.lastArguments["query"] == .string("SELECT * FROM events"))
        #expect(await harness.lastArguments["database"] == .string("main"))
    }

    @Test func eachSubjectRefetchesThroughItsOwnTool() async throws {
        let cases: [(PaneQuery, String)] = [
            (.sql(database: nil, raw: "SELECT 1"), "query"),
            (.table(database: nil, name: "events"), "read_table"),
            (.tables(database: nil), "list_tables"),
            (.columns(database: nil, table: "events"), "describe_table"),
        ]
        for (subject, tool) in cases {
            let harness = try await DBActionHarness(rows: [["id"], [1]])
            let pane = await harness.layout.open(kind: "db", title: "main")
            await harness.layout.setFetch(PaneFetch(query: subject), id: pane.id)
            _ = try await harness.registry.dispatch(
                name: "db_refetch", params: .object(["pane": .string(pane.id)]),
                origin: .agent, caller: .test("staging"), confirmation: nil)
            #expect(await harness.lastTool == tool)
        }
    }

    @Test func refetchingAPaneWithNoSubjectIsAnError() async throws {
        let harness = try await DBActionHarness(rows: [["id"], [1]])
        let pane = await harness.layout.open(kind: "db", title: "main")
        await #expect(throws: StandardActionError.self) {
            _ = try await harness.registry.dispatch(
                name: "db_refetch", params: .object(["pane": .string(pane.id)]),
                origin: .agent, caller: .test("staging"), confirmation: nil)
        }
    }

    @Test func pagingMovesTheOffsetAndRerunsTheSubject() async throws {
        let harness = try await DBActionHarness(rows: [["id"], [1]])
        let pane = await harness.layout.open(kind: "db", title: "main")
        await harness.layout.setFetch(
            PaneFetch(query: .sql(database: nil, raw: "SELECT 1"), pageSize: 500), id: pane.id)
        // A pageable pane, established the way a real `db_run_query` result
        // would leave it — `db_page` refuses one that was never marked
        // pageable (RULING R6, below), so paging tests must establish that
        // state explicitly rather than relying on a freshly opened pane's
        // default.
        await harness.panes.setRows(
            paneId: pane.id, columns: ["id"], columnTypes: ["INTEGER"], columnTypesInferred: false,
            rows: [[.number(1)]], millis: 0, truncated: true, pageable: true, offset: 0, sort: [], listsTables: false, editable: nil)
        _ = try await harness.registry.dispatch(
            name: "db_page", params: .object(["pane": .string(pane.id), "to": .string("next")]),
            origin: .agent, caller: .test("staging"), confirmation: nil)
        #expect(await harness.layout.fetch(id: pane.id)?.offset == 500)
        #expect(await harness.lastArguments["offset"] == .number(500))
    }

    @Test func pagingBackFromTheFirstPageStaysThereAndStillRedraws() async throws {
        let harness = try await DBActionHarness(rows: [["id"], [1]])
        let pane = await harness.layout.open(kind: "db", title: "main")
        await harness.layout.setFetch(
            PaneFetch(query: .sql(database: nil, raw: "SELECT 1")), id: pane.id)
        await harness.panes.setRows(
            paneId: pane.id, columns: ["id"], columnTypes: ["INTEGER"], columnTypesInferred: false,
            rows: [[.number(1)]], millis: 0, truncated: false, pageable: true, offset: 0, sort: [], listsTables: false, editable: nil)
        _ = try await harness.registry.dispatch(
            name: "db_page", params: .object(["pane": .string(pane.id), "to": .string("previous")]),
            origin: .agent, caller: .test("staging"), confirmation: nil)
        #expect(await harness.layout.fetch(id: pane.id)?.offset == 0)
    }

    @Test func pagingToANonsenseDestinationIsRefusedNotDefaulted() async throws {
        // The same rule pane_sort's direction already follows: silently
        // reading "sideways" as "next" would page the wrong way and tell
        // nobody.
        let harness = try await DBActionHarness(rows: [["id"], [1]])
        let pane = await harness.layout.open(kind: "db", title: "main")
        await harness.layout.setFetch(
            PaneFetch(query: .sql(database: nil, raw: "SELECT 1")), id: pane.id)
        await harness.panes.setRows(
            paneId: pane.id, columns: ["id"], columnTypes: ["INTEGER"], columnTypesInferred: false,
            rows: [[.number(1)]], millis: 0, truncated: false, pageable: true, offset: 0, sort: [], listsTables: false, editable: nil)
        await #expect(throws: LayoutActionError.self) {
            _ = try await harness.registry.dispatch(
                name: "db_page", params: .object(["pane": .string(pane.id), "to": .string("sideways")]),
                origin: .agent, caller: .test("staging"), confirmation: nil)
        }
    }

    // MARK: - RULING R6: `db_page` refuses a pane that is not pageable, before
    // the offset moves
    //
    // `refetchPane` forces `offset: 0` for `.tables`/`.columns` regardless of
    // what `PaneFetch.offset` already holds, so a table-list pane's
    // `Pane.fetch` can carry a stale, nonzero offset left over from a
    // different, earlier subject. Without this guard `db_page` would still
    // compute a moved offset and record it via `setFetch`, leaving
    // `Pane.fetch.offset` claiming a page the pane was never shown — exactly
    // what Task 13's footer would then report as fact.
    @Test func pagingAPaneWhoseResultIsNotPageableIsRefusedAndLeavesTheOffsetUntouched() async throws {
        let harness = try await DBActionHarness(containers: [("events", "table")])
        let pane = await harness.layout.open(kind: "db", title: "main")
        await harness.layout.setFetch(PaneFetch(query: .tables(database: nil)), id: pane.id)
        // The pane's last `setRows` reported `pageable: false` — exactly what
        // `db_list_tables` always writes for a table list.
        await harness.panes.setRows(
            paneId: pane.id, columns: ["name", "kind"], columnTypes: ["TEXT", "TEXT"],
            columnTypesInferred: false, rows: [[.string("events"), .string("table")]],
            millis: 0, truncated: false, pageable: false, offset: 0, sort: [], listsTables: false, editable: nil)

        do {
            _ = try await harness.registry.dispatch(
                name: "db_page", params: .object(["pane": .string(pane.id), "to": .string("next")]),
                origin: .agent, caller: .test("staging"), confirmation: nil)
            Issue.record("expected db_page to refuse a pane whose result is not pageable")
        } catch let error as StandardActionError {
            guard case .paneNotPageable(let action, let namedPane) = error else {
                Issue.record("expected .paneNotPageable, got \(error)")
                return
            }
            #expect(action == "db_page")
            #expect(namedPane == pane.id)
        }
        // Both halves, per RULING R6: the error fired AND the offset never
        // moved — a throw after the offset had already been written would
        // still leave the pane lying about which page it is on.
        #expect(await harness.layout.fetch(id: pane.id)?.offset == 0)
    }

    /// FINAL REVIEW, CRITICAL 2: the entrance half of the overflow fix.
    ///
    /// `db_page`'s `to` arrives as a STRING, so the parse is `Int(to)` —
    /// but the BOUND it has to respect is the same one every other
    /// externally supplied number in this codebase respects, and that
    /// bound has one home: `safeInt`, whose own doc comment records this
    /// exact crash class ("verified: SIGTRAP, exit 133"). A page number
    /// past it is a mistake in the request, and is refused as one rather
    /// than silently becoming the last page a pane can hold.
    ///
    /// `PaneFetch.clampedOffset` bounds the arithmetic itself, so this
    /// throw is the second of two independent guards, not the only one.
    @Test func pagingToAnAbsurdPageNumberIsRefusedAtTheEntrance() async throws {
        let harness = try await DBActionHarness(rows: [["id"], [1]])
        let pane = await harness.layout.open(kind: "db", title: "main")
        await harness.layout.setFetch(
            PaneFetch(query: .sql(database: nil, raw: "SELECT 1")), id: pane.id)
        await harness.panes.setRows(
            paneId: pane.id, columns: ["id"], columnTypes: ["INTEGER"], columnTypesInferred: false,
            rows: [[.number(1)]], millis: 0, truncated: true, pageable: true, offset: 0, sort: [], listsTables: false, editable: nil)

        // 2e16 * 500 is what used to overflow. It is refused now, and the
        // pane is left exactly where it was.
        await #expect(throws: LayoutActionError.self) {
            _ = try await harness.registry.dispatch(
                name: "db_page",
                params: .object(["pane": .string(pane.id), "to": .string("20000000000000000")]),
                origin: .agent, caller: .test("staging"), confirmation: nil)
        }
        #expect(await harness.layout.fetch(id: pane.id)?.offset == 0)
    }

    /// FINAL REVIEW, IMPORTANT 6: the offset is committed only once the
    /// re-fetch it describes has actually come back.
    ///
    /// It used to be written first. Press `›` on a pane showing rows
    /// 1-500 and have the re-fetch fail — a timeout, a restarted server —
    /// and `PaneStore` was untouched, so the footer still honestly read
    /// `rows 1-500`, while `Pane.fetch` had already moved to 500. Pressing
    /// `›` again then went to offset 1,000 and the pane jumped to rows
    /// 1,001-1,500: rows 501-1,000 skipped by a control pressed twice from
    /// a pane that never left page one.
    @Test func aFailedPageLeavesTheOffsetWhereThePaneActuallyIs() async throws {
        let harness = try await DBActionHarness(failingWith: "connection lost")
        let pane = await harness.layout.open(kind: "db", title: "main")
        await harness.layout.setFetch(
            PaneFetch(query: .sql(database: nil, raw: "SELECT 1"), pageSize: 500), id: pane.id)
        await harness.panes.setRows(
            paneId: pane.id, columns: ["id"], columnTypes: ["INTEGER"], columnTypesInferred: false,
            rows: [[.number(1)]], millis: 0, truncated: true, pageable: true, offset: 0, sort: [], listsTables: false, editable: nil)

        await #expect(throws: StandardActionError.self) {
            _ = try await harness.registry.dispatch(
                name: "db_page", params: .object(["pane": .string(pane.id), "to": .string("next")]),
                origin: .agent, caller: .test("staging"), confirmation: nil)
        }
        // The pane is still on page one, which is what it is still SHOWING.
        #expect(await harness.layout.fetch(id: pane.id)?.offset == 0)
    }

    /// FINAL REVIEW, IMPORTANT 3: `pane_sort` must not write a sort the
    /// pane can never satisfy.
    ///
    /// `db_page` got `panes.pageable(paneId:)` as its guard (RULING R6);
    /// `pane_sort`'s re-query branch is the other consumer of the same
    /// fact and had none. Run `SHOW VARIABLES` on MySQL — ~600 rows, so
    /// truncated, and `Pageable` false because the gate's verb says an
    /// unwrappable one — then click a header. The sort was stored and the
    /// re-fetch was refused by `sqlConn.Read` with "this result cannot be
    /// paged or re-sorted", so every later `db_refetch` failed the same
    /// way and relaunch brought the pane back permanently empty.
    ///
    /// On an unpageable result there is exactly one thing that can be
    /// done, so it is what is done: sort what is in hand, and leave the
    /// subject alone.
    @Test func sortingAnUnpageableResultSortsInPlaceRatherThanWritingAnUnsatisfiableSort() async throws {
        let harness = try await DBActionHarness(rows: [["id"], [1]])
        let pane = await harness.layout.open(kind: "db", title: "main")
        await harness.layout.setFetch(
            PaneFetch(query: .sql(database: nil, raw: "SHOW VARIABLES")), id: pane.id)
        // Truncated (so "incomplete") AND not pageable — the combination
        // the re-query branch could not handle.
        await harness.panes.setRows(
            paneId: pane.id, columns: ["id"], columnTypes: ["TEXT"], columnTypesInferred: false,
            rows: [[.number(2)], [.number(1)]], millis: 0, truncated: true,
            pageable: false, offset: 0, sort: [], listsTables: false, editable: nil)
        await harness.resetCallLog()

        let result = try await harness.registry.dispatch(
            name: "pane_sort",
            params: .object(["pane": .string(pane.id), "column": .string("id")]),
            origin: .ui, caller: .test("staging"), confirmation: nil)

        guard case .object(let obj) = result else { Issue.record("not an object"); return }
        #expect(obj["requeried"] == .bool(false))
        // Nothing reached the wire: no re-query was attempted at all.
        #expect(await harness.lastTool == nil)
        // And nothing unsatisfiable was recorded on the pane.
        #expect(await harness.layout.fetch(id: pane.id)?.sort == [])
        // The rows in hand were ordered, which is all that is possible.
        guard case .object(let snap) = await harness.panes.readPane(paneId: pane.id, kind: "db"),
              case .array(let rows)? = snap["rows"] else { Issue.record("no rows"); return }
        #expect(rows.first == .array([.number(1)]))
    }

    /// The complete-but-unpageable case of the same rule: a `SHOW` that
    /// came back whole still cannot carry a pushed `ORDER BY` on a later
    /// re-fetch, so the sort must not be recorded on the subject there
    /// either — otherwise relaunch's `db_refetch` fails and the pane comes
    /// back empty, which is Important 3's failure by another route.
    @Test func aSortOnACompleteUnpageableResultIsNotRecordedOnTheSubject() async throws {
        let harness = try await DBActionHarness(rows: [["id"], [1]])
        let pane = await harness.layout.open(kind: "db", title: "main")
        await harness.layout.setFetch(
            PaneFetch(query: .sql(database: nil, raw: "SHOW TABLES")), id: pane.id)
        await harness.panes.setRows(
            paneId: pane.id, columns: ["id"], columnTypes: ["TEXT"], columnTypesInferred: false,
            rows: [[.number(2)], [.number(1)]], millis: 0, truncated: false,
            pageable: false, offset: 0, sort: [], listsTables: false, editable: nil)

        _ = try await harness.registry.dispatch(
            name: "pane_sort",
            params: .object(["pane": .string(pane.id), "column": .string("id")]),
            origin: .ui, caller: .test("staging"), confirmation: nil)

        #expect(await harness.layout.fetch(id: pane.id)?.sort == [])
    }

    /// FINAL REVIEW, MINOR 6: a second header click on an unpageable pane
    /// must not discard the first sort term.
    ///
    /// `sortCanBeRecorded` is false here, so `next` is `nil` and
    /// `fetch.sort` is never written on either click — but `candidate` used
    /// to be built from that same never-updated `fetch.sort`, so the
    /// second click always built onto `[]`. Click `k`, then click `v`: `k`
    /// used to vanish from the pane's actual (client-side) sort the moment
    /// `v` was added, even though nothing on screen said so — the arrows
    /// and the rows still agreed with each other, only "and then by this"
    /// silently did not work.
    @Test func aSecondClickOnAnUnpageableResultKeepsTheFirstSortTerm() async throws {
        let harness = try await DBActionHarness(rows: [["id"], [1]])
        let pane = await harness.layout.open(kind: "db", title: "main")
        await harness.layout.setFetch(
            PaneFetch(query: .sql(database: nil, raw: "SHOW VARIABLES")), id: pane.id)
        await harness.panes.setRows(
            paneId: pane.id, columns: ["k", "v"], columnTypes: ["TEXT", "TEXT"],
            columnTypesInferred: false,
            rows: [[.string("b"), .number(2)], [.string("a"), .number(1)]],
            millis: 0, truncated: true, pageable: false, offset: 0, sort: [], listsTables: false, editable: nil)

        _ = try await harness.registry.dispatch(
            name: "pane_sort",
            params: .object(["pane": .string(pane.id), "column": .string("k")]),
            origin: .ui, caller: .test("staging"), confirmation: nil)
        _ = try await harness.registry.dispatch(
            name: "pane_sort",
            params: .object(["pane": .string(pane.id), "column": .string("v")]),
            origin: .ui, caller: .test("staging"), confirmation: nil)

        // Neither click could ever record onto the subject — this is the
        // unpageable case Important 3 already covers — so the only place
        // the accumulated sort can be read back from is the pane's own
        // client-side copy.
        guard case .object(let snap) = await harness.panes.readPane(paneId: pane.id, kind: "db"),
              case .array(let sort)? = snap["sort"] else { Issue.record("no sort"); return }
        #expect(sort == [
            .object(["column": .string("k"), "direction": .string("asc")]),
            .object(["column": .string("v"), "direction": .string("asc")]),
        ])
    }

    /// The other half of the same rule, so the guard cannot be "never
    /// record a sort": a table list is not pageable either, but
    /// `refetchPane` honours its sort CLIENT-SIDE and never pushes it into
    /// a statement — so recording it there is safe, and it is what makes a
    /// sorted schema pane survive relaunch.
    @Test func aSortOnATableListIsStillRecordedBecauseItIsNeverPushed() async throws {
        let harness = try await DBActionHarness(containers: [("events", "table")])
        let pane = await harness.layout.open(kind: "db", title: "main")
        await harness.layout.setFetch(PaneFetch(query: .tables(database: nil)), id: pane.id)
        await harness.panes.setRows(
            paneId: pane.id, columns: ["name", "kind"], columnTypes: ["TEXT", "TEXT"],
            columnTypesInferred: false, rows: [[.string("events"), .string("table")]],
            millis: 0, truncated: false, pageable: false, offset: 0, sort: [], listsTables: false, editable: nil)

        _ = try await harness.registry.dispatch(
            name: "pane_sort",
            params: .object(["pane": .string(pane.id), "column": .string("name")]),
            origin: .ui, caller: .test("staging"), confirmation: nil)

        #expect(await harness.layout.fetch(id: pane.id)?.sort
                == [PaneSort(column: "name", direction: .ascending)])
    }

    // MARK: - FINAL REVIEW, CRITICAL 1: a fetch reaches DISK, so relaunch
    // has something to restore
    //
    // `Pane.fetch` is persisted, and `restorePaneContents` walks
    // `layoutSnapshot.panes where pane.fetch != nil` at window
    // construction — but `persistLayout()` had exactly one caller,
    // `dispatchLayout`, which handles only the `pane_*` geometry actions,
    // `session_resume` and palette items. Every writer of a fetch —
    // `runQuery`, `pagePane`, `refetchPane`, `dispatchFromSurface` and the
    // agent's own dispatches — called `refreshLayout()`, which is a READ.
    // So the file on disk still held the pre-query pane: a pane came back
    // empty with an empty query line, and acceptance checks 11 and 12
    // tested a feature that was not reachable. The fetch survived only if
    // the operator happened to drag a pane afterwards, because that
    // unrelated action flushed the whole snapshot as a side effect.
    //
    // The seam is `refreshLayout()` itself — the one thing every writer
    // already calls, the pointer's and the agent's alike (the observation
    // pump calls it for every dispatch that ran, whoever made it) — so
    // there is one place that decides a layout changed and one place that
    // writes it, rather than five `persistLayout()` calls that a sixth
    // writer would forget to join.

    @Test @MainActor func aQueryRunFromTheWindowReachesDiskForTheNextLaunch() async throws {
        let harness = try await DBActionHarness(rows: [["id"], [1]])
        let (model, persistence, client) = try await windowOverHarness(harness)

        await model.runQuery("SELECT * FROM events", database: nil, pane: nil)

        // `runQuery`'s own inline `refreshLayout()` and the observation
        // pump's copy of it (fired by the same dispatch, see this
        // section's own comment) race for which one sees the change and
        // calls `persistLayout()` — and `persistLayout()`'s actual write
        // runs on a detached `Task` neither `runQuery` nor this test
        // awaits directly. With `RecordingToolCaller` answering in-memory
        // rather than over a subprocess, that race is decided fast enough
        // that the pump's copy — not `runQuery`'s own — regularly wins it,
        // exactly as it always does for an agent's dispatch below in
        // `aQueryTheAGENTRanReachesDiskToo`. So this polls for the write
        // the same way that test already does, rather than assuming
        // `runQuery`'s return means the file is already down.
        var saved: LayoutSnapshot?
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            saved = persistence.load(for: LayoutScope(organization: "acme", project: "widgets", environment: "dev")).snapshot
            if saved?.panes.contains(where: { $0.fetch != nil }) == true { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        await client.stop()
        let restored = try #require(saved, "nothing was written at all")
        // Exactly what `restorePaneContents` iterates.
        let restorable = restored.panes.filter { $0.kind == "db" && $0.fetch != nil }
        #expect(restorable.count == 1)
        #expect(restorable.first?.fetch?.query == .sql(database: nil, raw: "SELECT * FROM events"))
    }

    @Test @MainActor func aQueryTheAGENTRanReachesDiskToo() async throws {
        // The half a per-call-site fix would have missed: an agent running
        // `db_run_query` writes `Pane.fetch` through the registry without
        // touching any of the window's own methods.
        let harness = try await DBActionHarness(rows: [["id"], [1]])
        let (model, persistence, client) = try await windowOverHarness(harness)

        _ = try await harness.registry.dispatch(
            name: "db_run_query", params: .object(["query": .string("SELECT * FROM events")]),
            origin: .agent, caller: .test("dev"), confirmation: nil)

        // The observation pump is what carries an agent's dispatch back to
        // the window, and it runs on its own schedule — so this waits for
        // it rather than assuming it has already run.
        var saved: LayoutSnapshot?
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            saved = persistence.load(for: LayoutScope(organization: "acme", project: "widgets", environment: "dev")).snapshot
            if saved?.panes.contains(where: { $0.fetch != nil }) == true { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        await client.stop()
        _ = model

        let restored = try #require(saved, "nothing was written at all")
        let restorable = restored.panes.filter { $0.kind == "db" && $0.fetch != nil }
        #expect(restorable.count == 1)
        #expect(restorable.first?.fetch?.query == .sql(database: nil, raw: "SELECT * FROM events"))
    }

    @Test @MainActor func apagedPanesOffsetReachesDiskSoItComesBackOnThatPage() async throws {
        // Acceptance check 12's half of the same failure: page to page
        // three, quit, reopen, and the pane was back on page one.
        let harness = try await DBActionHarness(rows: [["id"], [1]])
        let (model, persistence, client) = try await windowOverHarness(harness)
        let pane = await harness.layout.open(kind: "db", title: "main")
        await harness.layout.setFetch(
            PaneFetch(query: .sql(database: nil, raw: "SELECT 1"), pageSize: 500), id: pane.id)
        await harness.panes.setRows(
            paneId: pane.id, columns: ["id"], columnTypes: ["INTEGER"], columnTypesInferred: false,
            rows: [[.number(1)]], millis: 0, truncated: true, pageable: true, offset: 0, sort: [], listsTables: false, editable: nil)

        await model.pagePane(id: pane.id, to: "next")

        let saved = persistence.load(for: LayoutScope(organization: "acme", project: "widgets", environment: "dev")).snapshot
        await client.stop()
        #expect(saved?.panes.first { $0.id == pane.id }?.fetch?.offset == 500)
    }

    @Test func classifyingAStatementAsksTheGates() async throws {
        let harness = try await DBActionHarness(classification: (kind: "mutation", reason: ""))
        let result = try await harness.registry.dispatch(
            name: "db_classify_statement",
            params: .object(["statement": .string("UPDATE events SET kind = 'x' WHERE id = 1")]),
            origin: .ui, caller: .test("staging"), confirmation: nil)
        guard case .object(let obj) = result,
              case .object(let structured)? = obj["structuredContent"] else {
            Issue.record("no structured result"); return
        }
        #expect(structured["kind"] == .string("mutation"))
        #expect(await harness.lastTool == "classify_statement")
    }

    @Test func allThreeTask11ActionsAreReadsNotControls() async throws {
        let harness = try await DBActionHarness(rows: [["id"], [1]])
        let descriptors = await harness.registry.all()
        for name in ["db_refetch", "db_page", "db_classify_statement"] {
            guard let action = descriptors.first(where: { $0.name == name }) else {
                Issue.record("\(name) is not registered"); continue
            }
            // Each one reaches a database, exactly like the schema-browsing
            // trio Task 10 registered alongside it.
            #expect(action.kind == .read)
        }
    }

    // MARK: - `db_render_update` composes an UPDATE and runs nothing (Task 10)

    /// The registration test the brief sketched, against the real fake
    /// client and registration helper rather than a hand-rolled one:
    /// `db_render_update` is registered, it is `.read` — a deliberate
    /// decision argued at length in its own registration comment, not an
    /// inherited default — and it reaches `wakil-db` through `render_update`.
    @Test func renderUpdateIsAReadThatComposesAStatement() async throws {
        // A quoted SQL string literal — `'b'` — is the ordinary case for
        // this action's whole subject, not an edge case, and nothing
        // between here and the canned reply is a shell: `DBActionHarness`
        // hands its `JSONValue` straight to `RecordingToolCaller`, so
        // there is no quoting layer left for a `'` to escape from. (It
        // once was one: the stub was a `/bin/sh` server echoing a
        // single-quoted string, and a `'` truncated it.)
        let harness = try await DBActionHarness(
            renderedStatement: #"UPDATE "events" SET "kind" = 'b' WHERE "id" = 1"#)
        let descriptors = await harness.registry.all()
        guard let action = descriptors.first(where: { $0.name == "db_render_update" }) else {
            Issue.record("db_render_update must be registered")
            return
        }
        // `.read`, so it is on `agentAllowedTools` and an agent can call it
        // directly — see this action's own registration comment (beside
        // `db_run_mutation`) for why that is acceptable even though the
        // connection it opens under the hood is the writable one.
        #expect(action.kind == .read)

        let result = try await harness.registry.dispatch(
            name: "db_render_update",
            params: .object([
                "table": .string("events"), "rowKey": .string(#""id" = '1'"#),
                "column": .string("kind"), "value": .string("b"),
            ]),
            origin: .agent, caller: .test("staging"), confirmation: nil)

        #expect(await harness.lastTool == "render_update")
        guard case .object(let obj) = result,
              case .object(let structured)? = obj["structuredContent"] else {
            Issue.record("no structured result"); return
        }
        #expect(structured["statement"] == .string(#"UPDATE "events" SET "kind" = 'b' WHERE "id" = 1"#))
    }

    /// Every parameter the schema declares actually reaches the wire — a
    /// dropped `database` or `columnType` would silently ask Go to compose
    /// against the wrong connection or without the type information that
    /// decides whether `value` needs quoting at all.
    @Test func renderUpdateForwardsAllItsParameters() async throws {
        let harness = try await DBActionHarness(renderedStatement: "UPDATE t SET c = 1 WHERE id = 1")
        _ = try await harness.registry.dispatch(
            name: "db_render_update",
            params: .object([
                "database": .string("analytics"), "table": .string("events"),
                "rowKey": .string(#""id" = '1'"#), "column": .string("kind"),
                "columnType": .string("INTEGER"), "value": .string("=1+1"),
            ]),
            origin: .agent, caller: .test("staging"), confirmation: nil)

        let sent = await harness.lastArguments
        #expect(sent["database"] == .string("analytics"))
        #expect(sent["table"] == .string("events"))
        #expect(sent["rowKey"] == .string(#""id" = '1'"#))
        #expect(sent["column"] == .string("kind"))
        #expect(sent["columnType"] == .string("INTEGER"))
        #expect(sent["value"] == .string("=1+1"))
    }

    /// A refusal from Go — a `;` in `value`'s raw-expression form, a `BIT`
    /// column, an unknown table, whatever `render_update` itself validates
    /// — surfaces through `callChecked` as `StandardActionError.serverError`
    /// carrying the gate's OWN sentence verbatim, not a message this layer
    /// reworded. Wakil's Swift half composes no SQL and explains no SQL
    /// refusal either; both are Go's to state.
    @Test func renderUpdateRefusalSurfacesAsTheGatesOwnSentence() async throws {
        let harness = try await DBActionHarness(
            failingWith: "render_update: BIT columns are not supported")
        do {
            _ = try await harness.registry.dispatch(
                name: "db_render_update",
                params: .object([
                    "table": .string("events"), "rowKey": .string(#""id" = '1'"#),
                    "column": .string("flags"), "value": .string("1"),
                ]),
                origin: .agent, caller: .test("staging"), confirmation: nil)
            Issue.record("expected db_render_update to surface the server's refusal")
        } catch StandardActionError.serverError(let action, let message) {
            #expect(action == "db_render_update")
            #expect(message == "render_update: BIT columns are not supported")
        }
    }

    // MARK: - `pane_sort` re-queries when it must (Task 12)
    //
    // `pane_sort` moved here from `PaneContentActions.swift` and changed
    // kind from `.control` to `.read`: sorting an incomplete result now
    // reaches a database, which is exactly what `.control` is not for. The
    // rule, spec §7 as the probe corrected it: a complete result
    // (`!truncated`, `offset == 0`) sorts client-side with no round trip;
    // an incomplete one — truncated OR a page past the first — re-queries
    // through `refetchPane`, coming back at page one.

    @Test func sortingACompleteResultOrdersItInPlaceWithNoRoundTrip() async throws {
        let harness = try await DBActionHarness(rows: [["id"], [3], [1], [2]])
        let pane = await harness.layout.open(kind: "db", title: "main")
        await harness.layout.setFetch(
            PaneFetch(query: .sql(database: nil, raw: "SELECT id FROM events")), id: pane.id)
        await harness.panes.setRows(
            paneId: pane.id, columns: ["id"], columnTypes: ["INTEGER"],
            columnTypesInferred: false,
            rows: [[.number(3)], [.number(1)], [.number(2)]],
            millis: 1, truncated: false, pageable: true, offset: 0, sort: [], listsTables: false, editable: nil)
        await harness.resetCallLog()
        _ = try await harness.registry.dispatch(
            name: "pane_sort",
            params: .object([
                "pane": .string(pane.id), "column": .string("id"),
                "direction": .string("asc"),
            ]),
            origin: .ui, caller: .test("staging"), confirmation: nil)
        #expect(await harness.lastTool == nil)   // nothing reached the database
        #expect(await harness.layout.fetch(id: pane.id)?.sort
                == [PaneSort(column: "id", direction: .ascending)])
        guard case .object(let snap) = await harness.panes.readPane(paneId: pane.id, kind: "db"),
              case .array(let rows)? = snap["rows"], case .array(let first) = rows[0],
              case .number(let n) = first[0] else { Issue.record("no rows"); return }
        #expect(n == 1)
    }

    /// D5's own gesture, dispatched through the REAL `pane_sort` handler
    /// twice, for two different columns — not by calling
    /// `PaneFetch.sorted(by:)` directly, which is where the fix's own
    /// unit tests live and which this end-to-end test does not replace.
    ///
    /// **Chooses the complete/no-round-trip fixture on purpose.** Both
    /// clicks land in the handler's non-requery branch — the one holding
    /// `let sortTerms = next?.sort ?? candidate?.sort ?? []`, the line
    /// that turns the refined `PaneFetch` back into what `PaneStore`'s
    /// `reorder` is told to apply to the rows on screen right now. That
    /// line is glue a plain type-widening pass would not need to get
    /// right, and no existing test dispatched `pane_sort` twice through
    /// the handler to reach it.
    ///
    /// **Checks both halves, because they are two different pieces of
    /// state.** `Pane.fetch.sort` — the promise a later re-fetch or
    /// relaunch keeps — comes from `next` directly and would read
    /// correctly even if the glue line above dropped every term but the
    /// one just clicked. `PaneStore`'s own cached sort — what `snapshot`
    /// (and so `read_pane`, and the rows actually drawn) reports right
    /// now — is what that line feeds, so it is the one that would go
    /// wrong.
    @Test func aSecondColumnRefinesTheFirstThroughTheHandlerTwice() async throws {
        let harness = try await DBActionHarness(rows: [["id"], [1]])
        let pane = await harness.layout.open(kind: "db", title: "main")
        await harness.layout.setFetch(
            PaneFetch(query: .sql(database: nil, raw: "SELECT kind, id FROM events")),
            id: pane.id)
        // "b" sits BETWEEN "a"'s two ids, so ordering by "id" alone (the
        // bug: dropping "kind") lands it in a different place than
        // ordering by "kind" primary, "id" secondary (the fix) would.
        await harness.panes.setRows(
            paneId: pane.id, columns: ["kind", "id"], columnTypes: ["TEXT", "INTEGER"],
            columnTypesInferred: false,
            rows: [
                [.string("a"), .number(10)], [.string("b"), .number(15)],
                [.string("a"), .number(20)],
            ],
            millis: 1, truncated: false, pageable: true, offset: 0, sort: [], listsTables: false, editable: nil)
        await harness.resetCallLog()

        // First click: "kind" ascending.
        _ = try await harness.registry.dispatch(
            name: "pane_sort",
            params: .object([
                "pane": .string(pane.id), "column": .string("kind"), "direction": .string("asc"),
            ]),
            origin: .ui, caller: .test("staging"), confirmation: nil)
        #expect(await harness.lastTool == nil)   // complete result, no round trip
        #expect(await harness.layout.fetch(id: pane.id)?.sort
                == [PaneSort(column: "kind", direction: .ascending)])

        // Second click: "id" descending. This must REFINE — "kind" stays
        // primary, "id" breaks its ties — rather than the second click
        // replacing the first, which is the walked failure itself.
        _ = try await harness.registry.dispatch(
            name: "pane_sort",
            params: .object([
                "pane": .string(pane.id), "column": .string("id"), "direction": .string("desc"),
            ]),
            origin: .ui, caller: .test("staging"), confirmation: nil)
        #expect(await harness.lastTool == nil)

        // The subject records both terms, "kind" still primary.
        #expect(await harness.layout.fetch(id: pane.id)?.sort == [
            PaneSort(column: "kind", direction: .ascending),
            PaneSort(column: "id", direction: .descending),
        ])

        // And the rows ACTUALLY ON SCREEN were ordered by both terms too
        // — not just the term the last click named. The two "a" rows are
        // the tie "kind" alone leaves; "id" descending breaks it, so
        // (a, 20) comes before (a, 10). Dropping "kind" and ordering by
        // "id" alone would put "b" (id 15) between them instead.
        guard case .object(let snap) = await harness.panes.readPane(paneId: pane.id, kind: "db"),
              case .array(let rows)? = snap["rows"] else {
            Issue.record("no rows"); return
        }
        #expect(rows == [
            .array([.string("a"), .number(20)]),
            .array([.string("a"), .number(10)]),
            .array([.string("b"), .number(15)]),
        ])
        #expect(snap["sort"] == .array([
            .object(["column": .string("kind"), "direction": .string("asc")]),
            .object(["column": .string("id"), "direction": .string("desc")]),
        ]))

        // Reachable in this fixture: a later `db_refetch` (relaunch, or
        // an agent's own re-query) sends the SAME two terms, in the same
        // order, onto the wire — the promise `Pane.fetch.sort` made above
        // is one `wakil-db` can actually keep.
        await harness.resetCallLog()
        _ = try await harness.registry.dispatch(
            name: "db_refetch", params: .object(["pane": .string(pane.id)]),
            origin: .agent, caller: .test("staging"), confirmation: nil)
        #expect(await harness.lastArguments["sort"] == .array([
            .object(["column": .string("kind"), "descending": .bool(false)]),
            .object(["column": .string("id"), "descending": .bool(true)]),
        ]))
    }

    /// Fix round 2's own gesture, dispatched through the REAL `pane_sort`
    /// handler three times — sort by `kind`, sort by `id`, then drop
    /// `id` — the end-to-end companion to `PaneFetchTests`'
    /// `droppingASecondaryTermLeavesThePrimaryIntact`, which calls
    /// `removingSort(column:)` directly and so never touches the
    /// handler's own `direction: "drop"` parsing at all.
    ///
    /// **The walked failure this replaces:** before `direction: "drop"`
    /// existed, the only way to remove `id`'s own term was to omit
    /// `column` entirely — which this same handler reads as "clear every
    /// term" — so dropping `id` took `kind` down with it too, even though
    /// `kind`'s own header was never clicked.
    @Test func droppingASecondaryColumnsOwnTermThroughTheHandlerLeavesThePrimary() async throws {
        let harness = try await DBActionHarness(rows: [["id"], [1]])
        let pane = await harness.layout.open(kind: "db", title: "main")
        await harness.layout.setFetch(
            PaneFetch(query: .sql(database: nil, raw: "SELECT kind, id FROM events")),
            id: pane.id)
        await harness.panes.setRows(
            paneId: pane.id, columns: ["kind", "id"], columnTypes: ["TEXT", "INTEGER"],
            columnTypesInferred: false,
            rows: [[.string("a"), .number(10)], [.string("b"), .number(5)]],
            millis: 1, truncated: false, pageable: true, offset: 0, sort: [], listsTables: false, editable: nil)
        await harness.resetCallLog()

        _ = try await harness.registry.dispatch(
            name: "pane_sort",
            params: .object([
                "pane": .string(pane.id), "column": .string("kind"), "direction": .string("asc"),
            ]),
            origin: .ui, caller: .test("staging"), confirmation: nil)
        _ = try await harness.registry.dispatch(
            name: "pane_sort",
            params: .object([
                "pane": .string(pane.id), "column": .string("id"), "direction": .string("desc"),
            ]),
            origin: .ui, caller: .test("staging"), confirmation: nil)

        // Drop `id`'s own term. `kind` was never named in this call.
        _ = try await harness.registry.dispatch(
            name: "pane_sort",
            params: .object([
                "pane": .string(pane.id), "column": .string("id"), "direction": .string("drop"),
            ]),
            origin: .ui, caller: .test("staging"), confirmation: nil)

        // The subject still promises `kind` — not an empty list.
        #expect(await harness.layout.fetch(id: pane.id)?.sort
                == [PaneSort(column: "kind", direction: .ascending)])

        // And the rows actually on screen were reordered by `kind` alone,
        // which is what `PaneStore`'s cached sort — what `read_pane`
        // reports right now — has to agree with.
        guard case .object(let snap) = await harness.panes.readPane(paneId: pane.id, kind: "db") else {
            Issue.record("no snapshot"); return
        }
        #expect(snap["sort"] == .array([
            .object(["column": .string("kind"), "direction": .string("asc")]),
        ]))
    }

    /// The bare `pane_sort` — no `column` at all — still clears every
    /// term, not just one, even once a secondary column ALSO has its own
    /// removal (`direction: "drop"`). The two must stay distinguishable
    /// through the real handler, not only at `PaneFetch`'s own level.
    @Test func clearingWithNoColumnThroughTheHandlerStillClearsEveryTerm() async throws {
        let harness = try await DBActionHarness(rows: [["id"], [1]])
        let pane = await harness.layout.open(kind: "db", title: "main")
        await harness.layout.setFetch(
            PaneFetch(query: .sql(database: nil, raw: "SELECT kind, id FROM events")),
            id: pane.id)
        await harness.panes.setRows(
            paneId: pane.id, columns: ["kind", "id"], columnTypes: ["TEXT", "INTEGER"],
            columnTypesInferred: false,
            rows: [[.string("a"), .number(10)], [.string("b"), .number(5)]],
            millis: 1, truncated: false, pageable: true, offset: 0, sort: [], listsTables: false, editable: nil)

        _ = try await harness.registry.dispatch(
            name: "pane_sort",
            params: .object([
                "pane": .string(pane.id), "column": .string("kind"), "direction": .string("asc"),
            ]),
            origin: .ui, caller: .test("staging"), confirmation: nil)
        _ = try await harness.registry.dispatch(
            name: "pane_sort",
            params: .object([
                "pane": .string(pane.id), "column": .string("id"), "direction": .string("desc"),
            ]),
            origin: .ui, caller: .test("staging"), confirmation: nil)
        _ = try await harness.registry.dispatch(
            name: "pane_sort", params: .object(["pane": .string(pane.id)]),
            origin: .ui, caller: .test("staging"), confirmation: nil)

        #expect(await harness.layout.fetch(id: pane.id)?.sort == [])
    }

    @Test func sortingATruncatedResultRequeriesAtPageOne() async throws {
        let harness = try await DBActionHarness(rows: [["id"], [1]])
        let pane = await harness.layout.open(kind: "db", title: "main")
        await harness.layout.setFetch(
            PaneFetch(query: .sql(database: nil, raw: "SELECT id FROM events"),
                      offset: 1000, pageSize: 500), id: pane.id)
        await harness.panes.setRows(
            paneId: pane.id, columns: ["id"], columnTypes: ["INTEGER"],
            columnTypesInferred: false, rows: [[.number(1)]],
            millis: 1, truncated: true, pageable: true, offset: 1000, sort: [], listsTables: false, editable: nil)
        await harness.resetCallLog()
        _ = try await harness.registry.dispatch(
            name: "pane_sort",
            params: .object([
                "pane": .string(pane.id), "column": .string("id"),
                "direction": .string("desc"),
            ]),
            origin: .ui, caller: .test("staging"), confirmation: nil)
        #expect(await harness.lastTool == "query")
        // D5's wire shape: a list, in precedence order — index 0 the
        // primary key — rather than the scalar `sortColumn`/
        // `sortDescending` pair Go no longer has fields for. This is the
        // one assertion that pins Swift's output to what `wakil-db`
        // actually reads; the old scalar keys would be silently ignored
        // by a real back end.
        #expect(await harness.lastArguments["sort"] == .array([
            .object(["column": .string("id"), "descending": .bool(true)]),
        ]))
        // Back to page one. Sorting page three and staying on page three
        // would show rows 1,001-1,500 of a DIFFERENT ordering.
        #expect(await harness.lastArguments["offset"] == .number(0))
        #expect(await harness.layout.fetch(id: pane.id)?.offset == 0)
    }

    @Test func sortingAPagedButUntruncatedResultStillRequeries() async throws {
        // offset > 0 with truncated false is the LAST page of a paged result.
        // The rows on screen are still a subset, so sorting them locally
        // would sort the last page and call it the table.
        let harness = try await DBActionHarness(rows: [["id"], [1]])
        let pane = await harness.layout.open(kind: "db", title: "main")
        await harness.layout.setFetch(
            PaneFetch(query: .sql(database: nil, raw: "SELECT id FROM events"),
                      offset: 500), id: pane.id)
        await harness.panes.setRows(
            paneId: pane.id, columns: ["id"], columnTypes: ["INTEGER"],
            columnTypesInferred: false, rows: [[.number(1)]],
            millis: 1, truncated: false, pageable: true, offset: 500, sort: [], listsTables: false, editable: nil)
        await harness.resetCallLog()
        _ = try await harness.registry.dispatch(
            name: "pane_sort",
            params: .object(["pane": .string(pane.id), "column": .string("id")]),
            origin: .ui, caller: .test("staging"), confirmation: nil)
        #expect(await harness.lastTool == "query")
    }

    @Test func clearingASortClearsItOnThePaneToo() async throws {
        let harness = try await DBActionHarness(rows: [["id"], [1]])
        let pane = await harness.layout.open(kind: "db", title: "main")
        await harness.layout.setFetch(
            PaneFetch(query: .sql(database: nil, raw: "SELECT 1"),
                      sort: [PaneSort(column: "id", direction: .ascending)]), id: pane.id)
        await harness.panes.setRows(
            paneId: pane.id, columns: ["id"], columnTypes: ["INTEGER"],
            columnTypesInferred: false, rows: [[.number(1)]],
            millis: 1, truncated: false, pageable: true, offset: 0,
            sort: [PaneSort(column: "id", direction: .ascending)], listsTables: false, editable: nil)
        _ = try await harness.registry.dispatch(
            name: "pane_sort", params: .object(["pane": .string(pane.id)]),
            origin: .ui, caller: .test("staging"), confirmation: nil)
        #expect(await harness.layout.fetch(id: pane.id)?.sort == [])
        guard case .object(let snap) = await harness.panes.readPane(paneId: pane.id, kind: "db") else {
            Issue.record("no snapshot"); return
        }
        #expect(snap["sort"] == .array([]))
    }

    @Test func aBadDirectionIsStillRefusedRatherThanDefaulted() async throws {
        let harness = try await DBActionHarness(rows: [["id"], [1]])
        let pane = await harness.layout.open(kind: "db", title: "main")
        await harness.layout.setFetch(
            PaneFetch(query: .sql(database: nil, raw: "SELECT 1")), id: pane.id)
        await #expect(throws: LayoutActionError.self) {
            _ = try await harness.registry.dispatch(
                name: "pane_sort",
                params: .object([
                    "pane": .string(pane.id), "column": .string("id"),
                    "direction": .string("sideways"),
                ]),
                origin: .ui, caller: .test("staging"), confirmation: nil)
        }
    }

    @Test func paneSortIsAReadNowBecauseItCanReachADatabase() async throws {
        let harness = try await DBActionHarness(rows: [["id"], [1]])
        let action = await harness.registry.all().first { $0.name == "pane_sort" }
        #expect(action?.kind == .read)
    }

    // MARK: - `WindowModel.runFromQueryLine` routes on the gate's own
    // answer, never on a Swift-side guess (Task 14)
    //
    // `runFromQueryLine` is what Return in a pane's query line calls. It
    // asks `db_classify_statement` — answered here by `DBActionHarness`'s
    // `classification:` stub, the same one `classifyingAStatementAsksTheGates`
    // above uses — and routes on the answer: `db_run_query` for a read,
    // `db_run_mutation` (which parks for confirmation) for a mutation, and
    // a refusal with nothing further dispatched for neither. A fourth case,
    // covered separately below, never asks the gate at all: an unchanged
    // non-SQL subject re-fetches as itself.
    //
    // Each test builds its own `WindowModel` directly on the harness's
    // `registry`/`panes`/`layout`, the same construction
    // `WindowModelTests.swift`'s `makeRegistry()` call sites use, because
    // `runFromQueryLine` lives on `WindowModel`, not on the harness.

    @Test @MainActor func runFromQueryLineRoutesAReadToDbRunQuery() async throws {
        let harness = try await DBActionHarness(classification: (kind: "read", reason: ""))
        let pane = await harness.layout.open(kind: "db", title: "main")
        let model = makeQueryLineModel(harness: harness, environment: "staging")

        await harness.resetCallLog()
        await model.runFromQueryLine("SELECT * FROM events", pane: pane)

        // "query" is the wire tool `db_run_query`'s handler calls — the
        // same one `classifyingAStatementAsksTheGates` proves
        // `db_classify_statement` does NOT call ("classify_statement"),
        // so this is proof the read went past classification into the run.
        #expect(await harness.lastTool == "query")
        #expect(model.queryLineRefusal(pane: pane.id) == nil)
    }

    @Test @MainActor func runFromQueryLineRoutesAMutationToDbRunMutationAndParksForConfirmation() async throws {
        let harness = try await DBActionHarness(classification: (kind: "mutation", reason: ""))
        let pane = await harness.layout.open(kind: "db", title: "main")
        // Non-production: a mutation parks rather than blocking outright,
        // which is what lets this test observe which action was proposed.
        let model = makeQueryLineModel(harness: harness, environment: "staging")

        async let run: Void = model.runFromQueryLine("DELETE FROM events WHERE id=1", pane: pane)
        while model.pending == nil { await Task.yield() }
        #expect(model.pending?.action == "db_run_mutation")
        #expect(model.pending?.statement == "DELETE FROM events WHERE id=1")

        // Cancel rather than confirm: this test is about ROUTING (which
        // action the query line proposed), not about the confirm/mutate
        // wire call, which `MutationActionTests.swift` already covers.
        await model.cancelPending()
        await run
        #expect(model.queryLineRefusal(pane: pane.id) == nil)
    }

    @Test @MainActor func runFromQueryLineRefusesNeitherAndDispatchesNothingFurther() async throws {
        let refusal = "only SELECT/EXPLAIN/SHOW queries are allowed (read-only)"
        let harness = try await DBActionHarness(classification: (kind: "neither", reason: refusal))
        let pane = await harness.layout.open(kind: "db", title: "main")
        let model = makeQueryLineModel(harness: harness, environment: "staging")

        await harness.resetCallLog()
        await model.runFromQueryLine("PRAGMA table_info(events)", pane: pane)

        #expect(model.queryLineRefusal(pane: pane.id) == refusal)
        // The gate was asked (that IS the wire call) and nothing after it:
        // neither "query" nor "mutate" ever reached the stub server.
        #expect(await harness.lastTool == "classify_statement")

        // Cleared at the very start of the next run, before anything else,
        // so a refusal never survives past the run that produced it — even
        // a run that stops at the blank-text guard immediately after.
        await model.runFromQueryLine("", pane: pane)
        #expect(model.queryLineRefusal(pane: pane.id) == nil)
    }

    // Fix round 1 (Important finding 1): `queryLineRefusal` used to be one
    // `String?` on the whole `WindowModel`, so `Canvas.paneView` handed the
    // SAME value into every open `DBPane` — a refusal raised by `db-2`'s
    // line was drawn under `db-1` too, telling the operator that a pane
    // they never touched had refused a statement they never typed there.
    // Keyed by pane id is the fix; this is the test that shape needs.
    @Test @MainActor func aRefusalRaisedInOnePaneDoesNotAppearUnderAnother() async throws {
        let refusal = "only SELECT/EXPLAIN/SHOW queries are allowed (read-only)"
        let harness = try await DBActionHarness(classification: (kind: "neither", reason: refusal))
        let paneA = await harness.layout.open(kind: "db", title: "a")
        let paneB = await harness.layout.open(kind: "db", title: "b")
        let model = makeQueryLineModel(harness: harness, environment: "staging")

        await model.runFromQueryLine("PRAGMA table_info(events)", pane: paneA)

        #expect(model.queryLineRefusal(pane: paneA.id) == refusal)
        // The pane that was never touched must read exactly as it did
        // before — nil, not the other pane's sentence.
        #expect(model.queryLineRefusal(pane: paneB.id) == nil)
    }

    // MARK: - FINAL REVIEW, IMPORTANT 9: the line goes back to the pane's
    // own query when what was typed did not become the pane's subject
    //
    // Spec §9 is right that a mutation leaves the rows and the subject
    // untouched — but nothing restored the LINE. After a confirmed
    // `UPDATE`, the line read "UPDATE ..." while `Pane.fetch` still held
    // the `SELECT` that produced the rows on screen, and
    // `shouldAdoptSubject` would not correct it because there were no
    // unsaved edits: `text == lastRendered`, both being the UPDATE. The
    // pane then claimed to be showing a statement it had never run, and
    // pressing Return again raised the confirmation plane instead of
    // re-fetching. That is the lying-pane failure the query line exists to
    // prevent.
    //
    // `WindowModel` publishes the text the line must go back to, keyed by
    // pane and stamped with a token so two identical restorations are
    // still two events; `DBPane` adopts it. The decision itself —
    // "did what was typed become the subject?" — is
    // `queryLineTextAfterRun(outcome:subject:)`, on values, in WakilKit.

    @Test @MainActor func aConfirmedMutationPutsThePanesOwnQueryBackOnTheLine() async throws {
        let harness = try await DBActionHarness(classification: (kind: "mutation", reason: ""))
        let opened = await harness.layout.open(kind: "db", title: "main")
        await harness.layout.setFetch(
            PaneFetch(query: .sql(database: nil, raw: "SELECT * FROM events")), id: opened.id)
        let pane = await harness.layout.snapshot().panes.first { $0.id == opened.id }!
        let model = makeQueryLineModel(harness: harness, environment: "staging")

        async let run: Void = model.runFromQueryLine(
            "UPDATE events SET kind = 'x' WHERE id = 1", pane: pane)
        while model.pending == nil { await Task.yield() }
        await model.confirmPending(typed: "confirm")
        await run

        // The rows and the subject are untouched, exactly as §9 says…
        #expect(await harness.layout.fetch(id: pane.id)?.query
                == .sql(database: nil, raw: "SELECT * FROM events"))
        // …and the line is told to show that subject again rather than the
        // UPDATE it just ran.
        #expect(model.queryLineRestore(pane: pane.id)?.text == "SELECT * FROM events")
    }

    // FINAL REVIEW, CRITICAL 1: a refusal must NOT publish a restore.
    //
    // This test used to assert the opposite — that a refusal restores the
    // pane's own subject onto the line, same as a mutation — which was
    // exactly the bug: `DBPane.onChange(of: restore)` sets `text = new.text`
    // UNCONDITIONALLY, so publishing a restore for a refusal wipes the
    // operator's own typed (refused) statement off the line the instant it
    // is refused. Walked scenario: type `upadte events set customer_id = 42
    // where id = 3`, press Return, get the correct refusal, and the line
    // snapped back to `events` — the typo gone, nothing left to fix.
    //
    // A mutation still must restore (`aConfirmedMutationPutsThePanesOwnQueryBackOnTheLine`
    // above) — it genuinely does not become the pane's subject, and the
    // line has to go back to what is actually on screen. A refusal is
    // different: nothing ran, so what is on screen never stopped matching
    // the pane's subject, and the only thing to preserve is the operator's
    // own draft — which is preserved by leaving the line alone entirely.
    @Test @MainActor func aRefusedStatementDoesNotDiscardTheOperatorsDraft() async throws {
        let refusal = "only SELECT/EXPLAIN/SHOW queries are allowed (read-only)"
        let harness = try await DBActionHarness(classification: (kind: "neither", reason: refusal))
        let opened = await harness.layout.open(kind: "db", title: "main")
        await harness.layout.setFetch(PaneFetch(query: .tables(database: nil)), id: opened.id)
        let pane = await harness.layout.snapshot().panes.first { $0.id == opened.id }!
        let model = makeQueryLineModel(harness: harness, environment: "staging")

        await model.runFromQueryLine("DROP TABLE events", pane: pane)

        #expect(model.queryLineRefusal(pane: pane.id) == refusal)
        // The whole point: no restore published, so `DBPane` never adopts
        // anything over the operator's still-refused draft.
        #expect(model.queryLineRestore(pane: pane.id) == nil)
    }

    @Test @MainActor func aReadLeavesTheLineAloneBecauseItBECAMEThePanesQuery() async throws {
        // The case that must NOT be restored: a read becomes the pane's
        // subject, so the line is already showing the truth and
        // `shouldAdoptSubject` is what keeps it there.
        let harness = try await DBActionHarness(classification: (kind: "read", reason: ""))
        let opened = await harness.layout.open(kind: "db", title: "main")
        await harness.layout.setFetch(
            PaneFetch(query: .sql(database: nil, raw: "SELECT 1")), id: opened.id)
        let pane = await harness.layout.snapshot().panes.first { $0.id == opened.id }!
        let model = makeQueryLineModel(harness: harness, environment: "staging")

        await model.runFromQueryLine("SELECT 2", pane: pane)

        #expect(model.queryLineRestore(pane: pane.id) == nil)
    }

    // MARK: - FINAL REVIEW, IMPORTANT 8: the database chooser spec §5
    // requires
    //
    // "The database is part of the line, chosen from `db_list_databases`.
    // This closes 2c-i §6's open item." The action half was closed —
    // `runQuery` takes a database — but the line only ever DISPLAYED a
    // database it had inherited, so the operator's only route to a second
    // one was to have the agent seed the pane first. Acceptance check 3 is
    // written as though the chooser exists, and the case it exercises is a
    // FRESH pane: `fetch == nil`, nothing to inherit from.

    @Test @MainActor func theWindowLearnsTheEnvironmentsDatabases() async throws {
        let harness = try await DBActionHarness(databases: [
            (name: "main", driver: "sqlite", writable: false),
            (name: "warehouse", driver: "mysql", writable: true),
        ])
        let model = makeQueryLineModel(harness: harness, environment: "staging")

        await model.refreshDatabases()

        #expect(model.databases == ["main", "warehouse"])
    }

    @Test @MainActor func aFreshPaneRunsAgainstTheDatabaseTheOperatorChose() async throws {
        // Acceptance check 3, at the level a test can reach it: a pane with
        // no fetch at all, a database chosen on the line, and the statement
        // reaching the wire against THAT database.
        let harness = try await DBActionHarness(classification: (kind: "read", reason: ""))
        let pane = await harness.layout.open(kind: "db", title: "main")
        #expect(pane.fetch == nil)
        let model = makeQueryLineModel(harness: harness, environment: "staging")

        model.chooseDatabase("warehouse", pane: pane)
        #expect(model.databaseForQueryLine(pane: pane) == "warehouse")

        await harness.resetCallLog()
        await model.runFromQueryLine("SELECT * FROM events", pane: pane)

        #expect(await harness.lastTool == "query")
        #expect(await harness.lastArguments["database"] == .string("warehouse"))
    }

    @Test @MainActor func aChoiceIsDroppedOnceThePaneItselfNamesAnotherDatabase() async throws {
        // The choice is the operator's until the pane's own subject moves
        // to a different database — at which point the subject is the
        // authority again, and the line shows what the pane is really
        // against rather than a stale pick.
        let harness = try await DBActionHarness(rows: [["id"], [1]])
        let opened = await harness.layout.open(kind: "db", title: "main")
        let model = makeQueryLineModel(harness: harness, environment: "staging")
        model.chooseDatabase("warehouse", pane: opened)

        await harness.layout.setFetch(
            PaneFetch(query: .sql(database: "analytics", raw: "SELECT 1")), id: opened.id)
        let moved = await harness.layout.snapshot().panes.first { $0.id == opened.id }!

        #expect(model.databaseForQueryLine(pane: moved) == "analytics")
    }

    @Test @MainActor func runFromQueryLineRerunsAnUnchangedNonSQLSubjectAsItselfRatherThanAsText() async throws {
        let harness = try await DBActionHarness(containers: [("events", "table")])
        let opened = await harness.layout.open(kind: "db", title: "main")
        await harness.layout.setFetch(PaneFetch(query: .tables(database: nil)), id: opened.id)
        // Re-read the pane after `setFetch`: `opened` is a value-type
        // snapshot from before the fetch was attached, and its `.fetch`
        // is still nil.
        let pane = await harness.layout.snapshot().panes.first { $0.id == opened.id }!
        #expect(pane.fetch?.query.describedForOperator == "tables")
        let model = makeQueryLineModel(harness: harness, environment: "staging")

        await harness.resetCallLog()
        // Unchanged: the line reads exactly what the pane's subject
        // describes itself as.
        await model.runFromQueryLine("tables", pane: pane)

        // "list_tables" is `db_refetch`'s own wire tool for a `.tables`
        // subject — proof this re-listed the tables rather than asking
        // the gate to classify the word "tables" as a statement.
        #expect(await harness.lastTool == "list_tables")
        #expect(model.queryLineRefusal(pane: pane.id) == nil)
    }

    /// The test the seam exists for: a DB read, dispatched end to end, with no
    /// subprocess, no handshake and no shell script. Before `ToolCaller` this
    /// could only be written by spawning a stub server.
    @Test func aDatabaseReadRunsAgainstAnInMemoryAdapter() async throws {
        let db = RecordingToolCaller(always: .object([
            "content": .array([.object(["type": .string("text"), "text": .string("stub")])]),
            "structuredContent": .object([
                "columns": .array([.string("id")]),
                "rows": .array([.array([.integer(1)])]),
            ]),
        ]))
        let panes = PaneStore()
        let registry = ActionRegistry(
            journalDirectory: testScratchRoot
                .appendingPathComponent(UUID().uuidString),
            sessionId: "s1")
        await registerStandardActions(
            into: registry, context: nil, panes: panes, db: db, resumes: ResumeBroker())

        _ = try await registry.dispatch(
            name: "db_run_query", params: .object(["query": .string("select 1")]),
            origin: .ui, caller: .test("staging"), confirmation: nil)

        let calls = await db.calls
        #expect(calls.count == 1)
        #expect(calls.first?.name == "query")
        #expect(calls.first?.timeout == MCPClient.readReplyTimeout)
    }
}

/// A `ProviderCredentialsLookup` that always succeeds, with credentials
/// nothing in this file's `runFromQueryLine` tests reads — they exist to
/// cover routing, not credential plumbing. Mirrors
/// `WindowModelTests.swift`'s private `AlwaysSucceedsCredentialsLookup`,
/// duplicated rather than shared because that one is `private` to its own
/// file and this file's `DBActionTests` needs the identical seam.
private struct AlwaysSucceedsCredentialsLookupForRunFromQueryLine: ProviderCredentialsLookup {
    func credentials(forProvider id: String) async throws -> ProviderCredentials {
        ProviderCredentials(claudePath: "/usr/bin/true", configDir: "/dev/null", oauthToken: "test-only")
    }
}

/// Wires a `DBActionHarness`'s own `registry`/`panes`/`layout` into a
/// `WindowModel` — the harness builds a `RecordingToolCaller` standing in
/// for `wakil-db` and everything `registerStandardActions` needs, but not
/// a `WindowModel` itself, which is what `runFromQueryLine` lives on.
///
/// The `wakil-ctx` side is the exception and is real: a started
/// `MCPClient` over the built binary, because the org and project a
/// layout file is filed under have to come from somewhere. A scratch
/// `LayoutPersistence` is where it gets filed.
///
/// `refreshContext()` is what teaches the model its org and project —
/// `persistLayout` skips the write entirely until both are known, since a
/// layout filed under an empty org is filed where no later session will
/// look for it. The fixture writes `active.json` directly rather than
/// dispatching `ctx_set_project`, because the harness's registry is wired
/// to a `RecordingToolCaller` in the database role and has no context
/// client of its own.
///
/// The caller stops the returned `MCPClient`.
@MainActor
private func windowOverHarness(
    _ harness: DBActionHarness
) async throws -> (model: WindowModel, persistence: LayoutPersistence, ctx: MCPClient) {
    let bin = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("bin/wakil-ctx")
    try #require(FileManager.default.isExecutableFile(atPath: bin.path), "run `make build` first")
    let home = try makeFixture(org: "acme", projectOrg: "acme", environments: ["dev"])
    // `ActiveContext.Project` stores the project.json PATH, not the name
    // — `wakilcore.Resolve` says so in its own comment and loads it
    // directly.
    let projectPath = home.appendingPathComponent("proj/project.json").path
    try #"{"project":"\#(projectPath)","environment":"dev"}"#
        .write(to: home.appendingPathComponent(".wakil/orgs/acme/active.json"),
               atomically: true, encoding: .utf8)
    let client = try await startedClient(bin: bin, home: home, org: "acme")

    let directory = testScratchRoot.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let persistence = LayoutPersistence(directory: directory)
    let model = WindowModel(
        registry: harness.registry, panes: harness.panes, layout: harness.layout,
        persistence: persistence, context: ContextStore(client: client),
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main",
        lookup: AlwaysSucceedsCredentialsLookupForRunFromQueryLine(), environment: "dev")
    await model.refreshContext()
    try #require(model.project == "widgets", "the fixture did not make a project active")
    return (model, persistence, client)
}

@MainActor
private func makeQueryLineModel(harness: DBActionHarness, environment: String) -> WindowModel {
    WindowModel(
        registry: harness.registry, panes: harness.panes, layout: harness.layout, context: nil,
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main",
        lookup: AlwaysSucceedsCredentialsLookupForRunFromQueryLine(), environment: environment)
}

@Test func standardActionsAreReadOrControlAndNeverMutateIn2bI() async throws {
    // Reclassified from 2a's all-.read set: the two ctx_ setters are now
    // .control (see registerStandardActions' doc comment). The zero-.mutate
    // half of the 2a pin held through 2b-i and 2b-ii, but Phase 2b-iii added
    // `db_run_mutation` — Wakil's first `.mutate` action — so this test's
    // name (frozen at "In2bI") is now historical and the expectation below
    // has grown a third kind rather than staying the two-kind set it pinned
    // at the time.
    let r = ActionRegistry(journalDirectory: testScratchRoot
        .appendingPathComponent(UUID().uuidString), sessionId: "s1")
    await registerStandardActions(into: r, context: nil, panes: PaneStore(), db: nil, resumes: ResumeBroker())
    let kinds = Set(await r.all().map(\.kind))
    #expect(kinds == [.read, .control, .mutate])
}

@Test func standardActionNamesAreStableAndNamespaced() async throws {
    let r = ActionRegistry(journalDirectory: testScratchRoot
        .appendingPathComponent(UUID().uuidString), sessionId: "s1")
    await registerStandardActions(into: r, context: nil, panes: PaneStore(), db: nil, resumes: ResumeBroker())
    // db_run_mutation added by Phase 2b-iii — Wakil's first `.mutate` action.
    // session_set_provider added by Phase 2b-vi Task 8 (fix round 1) — see
    // that action's own registration comment for why being `.control` and
    // present here does not make it agent-reachable.
    // ctx_set_provider added by Phase 2b-vi Task 9 — the persistence write
    // `WindowModel.setProvider` dispatches after a successful swap; see
    // its own registration comment for why it needs no broker unlike
    // session_set_provider above.
    // ctx_list_providers added by Phase 2b-vi Task 12 — the picker's own
    // source of what an org has registered, so ⌘P has something to list
    // besides the switch (`ctx_set_provider`) itself.
    // db_list_tables, db_describe_table and db_read_table added by Phase
    // 2c-ii Task 10 — the schema browser, drawn on the same grid a query
    // draws rows on, with no new view.
    // db_refetch, db_page and db_classify_statement added by Phase 2c-ii
    // Task 11 — the one re-fetch path (`refetchPane`) and the two actions
    // that drive it, plus the classification action the query line needs.
    // pane_sort moved here from `PaneContentActions.swift` by Phase 2c-ii
    // Task 12 and changed kind from `.control` to `.read` — sorting an
    // incomplete result now reaches a database through `refetchPane`, so it
    // needs the database client this function has and
    // `registerPaneContentActions` does not.
    // ctx_list_orgs, ctx_create_org, ctx_list_machine_providers and
    // ctx_adopt_provider added by Phase 2b-viii Task 13 — the org plane's
    // four Go-side tools, registered here and made operator-only (see
    // `operatorOnlyActions` in `PermissionPrompt.swift`).
    // db_cancel added by the db-pane copy/cancel/detail work — ends the read in flight on a pane.
    // ctx_config_tree added by Phase 2e (#198) — the settings pane's one
    // read. `.read` and agent-reachable, because Decision 30 rules that
    // the agent may READ settings and drive nothing on it, and this is
    // the reading half. Its counterpart `settings_open` is a LAYOUT
    // action and is absent here for the reason `pane_open` is: this test
    // covers `registerStandardActions` alone.
    #expect(await r.all().map(\.name).sorted() ==
            ["api_remove_entry", "api_set_entry", "api_update_entry",
             "conversation_rename",
             "ctx_add_provider", "ctx_adopt_provider", "ctx_browser_settings", "ctx_config_tree", "ctx_config_tree_for",
             "ctx_connection_add", "ctx_connection_allow_set", "ctx_connection_catalog", "ctx_connection_remove", "ctx_connection_secrets_set", "ctx_connection_signin_start", "ctx_connection_signin_wait", "ctx_connection_signout", "ctx_connection_update",
             "ctx_create_environment",
             "ctx_create_org", "ctx_create_project", "ctx_editor_settings",
             "ctx_git_account_add", "ctx_git_account_remove", "ctx_git_account_test", "ctx_git_api_access_remove",
            "ctx_git_api_access_test", "ctx_git_api_access_token_set", "ctx_git_device_poll",
             "ctx_git_device_start", "ctx_git_gh_import", "ctx_git_gh_logins", "ctx_git_host_suggestions",
             "ctx_git_key_generate", "ctx_git_key_passphrase_set", "ctx_git_ssh_keys", "ctx_git_token_set", "ctx_github_pull_requests",
             "ctx_jira_token_set", "ctx_keyboard", "ctx_list_accounts",
             "ctx_list_environments", "ctx_list_machine_providers",
             "ctx_list_orgs", "ctx_list_projects", "ctx_list_providers",
             "ctx_provider_login", "ctx_remove_environment", "ctx_remove_project",
             "ctx_rename_environment", "ctx_rename_project", "ctx_set_browser_settings", "ctx_set_editor_settings", "ctx_set_environment",
             "ctx_set_key", "ctx_set_keys",
             "ctx_set_local_provider", "ctx_set_project", "ctx_set_project_agent_instructions", "ctx_set_project_editor_settings", "ctx_set_project_pm_key", "ctx_set_provider", "ctx_unlink_provider", "ctx_update_org",
             "db_cancel", "db_classify_statement", "db_describe_table",
             "db_list_databases", "db_list_tables", "db_page", "db_read_table", "db_refetch",
             "db_remove_database",
             "db_render_update", "db_run_mutation", "db_run_query", "db_set_connection", "db_set_dsn", "db_update_database", "pane_sort", "session_close", "session_get",
             "session_list", "session_new", "session_read", "session_record_parent", "session_resume",
             "session_set_provider", "session_switch"])
}

/// `registerStandardActions` needs a `ResumeBroker` as of Task 9 — this
/// builds one alongside a registry with no MCP clients, so a test can
/// dispatch `session_resume` and then read what it parked without
/// spawning `wakil-ctx` or `wakil-db`.
private func standardRegistryWithResumeBroker() async throws -> (ActionRegistry, PaneStore, ResumeBroker) {
    let panes = PaneStore()
    let broker = ResumeBroker()
    let registry = ActionRegistry(
        journalDirectory: testScratchRoot.appendingPathComponent(UUID().uuidString),
        sessionId: "s1")
    await registerStandardActions(into: registry, context: nil, panes: panes, db: nil, resumes: broker)
    return (registry, panes, broker)
}

@Test func sessionResumeIsControlAndSessionGetIsRead() async throws {
    let (registry, _, broker) = try await standardRegistryWithResumeBroker()
    let byName = Dictionary(uniqueKeysWithValues: await registry.all().map { ($0.name, $0) })
    #expect(byName["session_resume"]?.kind == .control)
    #expect(byName["session_get"]?.kind == .read)
    _ = broker
}

@Test func sessionResumeParksTheRequestAndReturnsWithoutWaiting() async throws {
    let (registry, _, broker) = try await standardRegistryWithResumeBroker()
    let stream = await broker.requests()

    let result = try await registry.dispatch(
        name: "session_resume", params: .object(["id": .string("parent-7")]),
        origin: .agent, caller: .test("staging"), confirmation: nil)

    // The handler answered rather than blocking on the swap.
    #expect("\(result)".contains("parent-7"))

    var seen: String?
    for await r in stream {
        seen = r.sessionId
        break
    }
    #expect(seen == "parent-7")
}

@Test func sessionResumeRefusesAMissingId() async throws {
    let (registry, _, _) = try await standardRegistryWithResumeBroker()
    await #expect(throws: (any Error).self) {
        _ = try await registry.dispatch(
            name: "session_resume", params: .object([:]),
            origin: .ui, caller: .test("staging"), confirmation: nil)
    }
}

// MARK: - The Anthropic tool-name rule

/// The Anthropic API's documented rule for a tool's `name`, written here
/// exactly as the API documents it.
private let anthropicToolNameRule = #"^[a-zA-Z0-9_-]{1,128}$"#

/// Whether `name` satisfies that rule — the oracle
/// `everyRegisteredActionNameSatisfiesTheAnthropicToolNameRule` and
/// `everyProjectedMCPToolNameSatisfiesTheSameRule` below are judged against,
/// and itself covered by `theAnthropicToolNameRuleHelperRejectsWhatTheRuleRejects`.
///
/// Both halves of the implementation are load-bearing, and neither is the
/// obvious choice, so both are recorded here.
///
/// **`NSRegularExpression` rather than `String.range(of:options:
/// .regularExpression)`.** Those two are not the same engine, and they
/// disagree about exactly the input this helper most needs to reject.
/// Measured on this machine, 2026-09-08, Swift 6.3.2 / macOS 26.6.2:
/// `NSRegularExpression(pattern: rule).firstMatch(in: "abc\n", ...)` returns
/// a match of `{0, 3}` — ICU lets `$` match *before* a trailing newline —
/// while `"abc\n".range(of: rule, options: .regularExpression)` returns
/// `nil`, that Swift-string API no longer being ICU-backed on this
/// toolchain. Naming the ICU engine explicitly means this oracle judges
/// against the *more permissive* of the two — so a name it accepts is
/// accepted by either — rather than inheriting whichever engine a given
/// toolchain happens to wire up behind a `CompareOptions` flag.
///
/// **The whole-range check.** It is what turns ICU's `$` into the rule the
/// API documents. Without it `"abc\n"` matches, as `abc`, and this helper
/// says yes to a name ending in a newline.
/// `theAnthropicToolNameRuleHelperRejectsWhatTheRuleRejects` fails if it is
/// removed; that is that test's main reason for existing.
private func satisfiesAnthropicToolNameRule(_ name: String) -> Bool {
    guard let regex = try? NSRegularExpression(pattern: anthropicToolNameRule) else { return false }
    let wholeString = NSRange(name.startIndex..<name.endIndex, in: name)
    guard let match = regex.firstMatch(in: name, range: wholeString) else { return false }
    return match.range == wholeString
}

/// The helper above is itself a piece of logic, and nothing exercised it
/// directly until this test: the two tests below only ever feed it names
/// that already satisfy the rule, so all of them stay green however
/// permissive it becomes. Its rejections are asserted here, one per clause
/// of the rule.
///
/// `"abc\n"` is the case the whole-range check exists for, and the only one
/// the pattern alone does not catch. The other three fall to the pattern —
/// a character outside the class, the empty string against `{1,128}`, and
/// 129 characters against the same bound — and are asserted anyway so that
/// both halves of the rule, character set and length, are pinned rather than
/// assumed.
@Test func theAnthropicToolNameRuleHelperRejectsWhatTheRuleRejects() throws {
    #expect(satisfiesAnthropicToolNameRule("abc\n") == false,
            "a trailing newline must not pass: ICU lets `$` match before one")
    #expect(satisfiesAnthropicToolNameRule("a/b") == false)
    #expect(satisfiesAnthropicToolNameRule("") == false)
    #expect(satisfiesAnthropicToolNameRule(String(repeating: "a", count: 129)) == false)

    // Accepted: a real 2a action name, the shortest legal name, one of every
    // character class the rule allows, and exactly the maximum length.
    #expect(satisfiesAnthropicToolNameRule("ctx_list_projects"))
    #expect(satisfiesAnthropicToolNameRule("a"))
    #expect(satisfiesAnthropicToolNameRule("Zz09_-"))
    #expect(satisfiesAnthropicToolNameRule(String(repeating: "a", count: 128)))

    // The ICU behaviour the helper's doc comment cites, measured rather than
    // asserted in prose: `$` matching before a trailing newline is what makes
    // the whole-range check necessary, and if a future ICU stopped doing it,
    // this is where that shows up.
    let regex = try NSRegularExpression(pattern: anthropicToolNameRule)
    #expect(regex.firstMatch(in: "abc\n", range: NSRange(location: 0, length: 4))?.range
            == NSRange(location: 0, length: 3))
}

/// **Why an action name may not contain a dot** (or a space, or a slash, or
/// anything else outside `[a-zA-Z0-9_-]`).
///
/// Every registered action is projected onto Wakil's MCP surface by
/// `MCPServer`'s `tools/list`, so the action's own name becomes the `<tool>`
/// half of the `mcp__<server>__<tool>` name the `claude` CLI hands to the
/// Anthropic API. The API's tool-name rule is `^[a-zA-Z0-9_-]{1,128}$`, and
/// a dot does not satisfy it.
///
/// The CLI does not rescue a name that breaks the rule. `claude` 2.1.263's
/// name-construction path was **read, not run** (this repo runs no `claude`
/// from any test): it builds `` `mcp__${rn(server)}__${rn(tool)}` `` where
/// `rn` is an alias-map lookup — `Object.hasOwn(i,e)?i[e]:e` — which returns
/// the name unchanged when there is no alias. It is a rename table, not a
/// sanitiser, so a dotted name would reach the API verbatim. Whether the API
/// then rejects the request is **not** verified here and has not been
/// observed live; confirming it would mean spending the operator's Claude
/// subscription. The rename to dot-free names removes the question instead
/// of answering it.
///
/// This test is driven off `ActionRegistry.all()` rather than a hard-coded
/// list — unlike `standardActionNamesAreStableAndNamespaced` above, which
/// pins the 2a set deliberately — so an action registered in a later phase
/// is covered the moment it is registered, and a bad name fails here rather
/// than at the operator's acceptance check.
@Test func everyRegisteredActionNameSatisfiesTheAnthropicToolNameRule() async {
    let r = ActionRegistry(journalDirectory: testScratchRoot
        .appendingPathComponent(UUID().uuidString), sessionId: "s1")
    await registerStandardActions(into: r, context: nil, panes: PaneStore(), db: nil, resumes: ResumeBroker())
    await registerLayoutActions(into: r, layout: LayoutStore())

    for name in await r.all().map(\.name) {
        #expect(satisfiesAnthropicToolNameRule(name),
                "action name \"\(name)\" does not match \(anthropicToolNameRule)")
    }
    // `read_pane` and `read_layout` are hand-written rather than projected
    // from the registry (design §2.3), so `all()` does not cover either and
    // both are named here.
    #expect(satisfiesAnthropicToolNameRule(readPaneToolName),
            "read_pane does not match \(anthropicToolNameRule)")
    #expect(satisfiesAnthropicToolNameRule(readLayoutToolName),
            "read_layout does not match \(anthropicToolNameRule)")
}

/// The rule is checked on the **composite** too, and not only on the action
/// name, because the composite is the string the API actually sees. Three
/// things make that a different assertion rather than a redundant one:
///
/// 1. the server name is part of it. `wakilShimServerName` and every entry
///    in `agentFacingServers` are ordinary Swift string constants; a server
///    renamed to something with a dot in it would break the projected name
///    while every action name stayed valid.
/// 2. length composes. An action name of exactly 128 characters satisfies
///    the rule on its own and still overflows the 128-character limit once
///    `mcp__wakil__` (12 characters) is prepended.
/// 3. the joiner is `__`, which is inside the character class — so this
///    pins the fact that assembling the parts cannot itself introduce an
///    illegal character, rather than leaving it to inspection.
///
/// It runs over `agentAllowedTools`, which is the one place the composite is
/// assembled in Wakil. Two of its entries — `mcp__wakil-pm` and
/// `mcp__wakil-recall` — are the CLI's *whole-server* allow-rule form rather
/// than tool names, so they never reach the API as a tool `name` at all;
/// checking them anyway costs nothing (a hyphen is in the class) and means
/// this test needs no exception list that a future entry could fall through.
@Test func everyProjectedMCPToolNameSatisfiesTheSameRule() async {
    let r = ActionRegistry(journalDirectory: testScratchRoot
        .appendingPathComponent(UUID().uuidString), sessionId: "s1")
    await registerStandardActions(into: r, context: nil, panes: PaneStore(), db: nil, resumes: ResumeBroker())
    await registerLayoutActions(into: r, layout: LayoutStore())

    for entry in agentAllowedTools(actions: await r.all()) {
        #expect(satisfiesAnthropicToolNameRule(entry),
                "projected tool name \"\(entry)\" does not match \(anthropicToolNameRule)")
    }
}

/// Requirement from the task brief: a handler whose client is `nil` must
/// throw a clear error naming what is missing — not crash (a forced
/// unwrap), and not silently return something that looks like success.
/// Every registered action is dispatched with both clients `nil`, checked
/// against the completeness guard below so none can go uncovered
/// silently: an action needing no client is named in `needsNoClient` with
/// its own reason rather than omitted, and `db_run_mutation` is
/// dispatched separately with `confirmation: "confirm"` because
/// otherwise the write gate would throw `needsConfirmation` before its
/// handler — and its missing-client check — ever ran.
@Test func everyActionWithAMissingClientThrowsRatherThanCrashing() async throws {
    let r = ActionRegistry(journalDirectory: testScratchRoot
        .appendingPathComponent(UUID().uuidString), sessionId: "s1")
    await registerStandardActions(into: r, context: nil, panes: PaneStore(), db: nil, resumes: ResumeBroker())

    let paramsByAction: [String: JSONValue] = [
        "ctx_list_projects": .object([:]),
        // 2e (#198). It takes no parameters and reaches `wakil-ctx`
        // through `readConfigTree`, so with no context client it must
        // throw `.missingClient` naming itself rather than crash or
        // return an empty tree — the second of which would tell the
        // settings pane this machine has no projects.
        "ctx_config_tree": .object([:]),
        // 2e (#200). Takes no parameters; with no context client it must
        // throw `.missingClient` naming itself.
        "ctx_list_accounts": .object([:]),
        // 2e (#202). Needs its `id`; with no context client it must throw
        // `.missingClient` naming itself rather than derive nothing
        // quietly.
        "ctx_provider_login": .object(["id": .string("acme")]),
        // 2e (#204). Needs both required params, or it throws
        // `.missingParam` before the missing-client guard is reached.
        // 2e (#206). Needs its `id`.
        "ctx_unlink_provider": .object(["id": .string("main")]),
        // 2e (#207). All five required params, or it throws
        // `.missingParam` before the missing-client guard is reached.
        "db_set_dsn": .object([
            "projectPath": .string("/p.json"), "environment": .string("staging"),
            "name": .string("core"), "driver": .string("mysql"),
            "dsn": .string("mysql://db"),
        ]),
        "db_set_connection": .object([
            "projectPath": .string("/p.json"), "environment": .string("staging"),
            "name": .string("core"), "driver": .string("mysql"),
        ]),
        "db_remove_database": .object([
            "projectPath": .string("/p.json"), "environment": .string("staging"),
            "name": .string("core"),
        ]),
        "api_set_entry": .object([
            "projectPath": .string("/p.json"), "environment": .string("staging"),
            "name": .string("orders"), "baseUrl": .string("https://o.example"),
        ]),
        "api_update_entry": .object([
            "projectPath": .string("/p.json"), "environment": .string("staging"),
            "name": .string("orders"),
        ]),
        "api_remove_entry": .object([
            "projectPath": .string("/p.json"), "environment": .string("staging"),
            "name": .string("orders"),
        ]),
        "db_update_database": .object([
            "projectPath": .string("/p.json"), "environment": .string("staging"),
            "name": .string("core"),
        ]),
        "ctx_add_provider": .object([
            "id": .string("acme"), "configDir": .string("/Users/x/.claude-acme"),
        ]),
        // 2e (#199). Needs its `id`, or it throws `.missingParam` before
        // the missing-client guard is ever reached — which would make
        // this test pass for the wrong reason.
        "ctx_update_org": .object(["id": .string("acme"), "displayName": .string("Acme")]),
        // 2e-ii. Each needs its params, or the pin check or `.missingParam` could answer first.
        "ctx_create_project": .object(["folder": .string("/w"), "name": .string("acme")]),
        "ctx_rename_project": .object(["name": .string("acme"), "newName": .string("beta")]),
        "ctx_remove_project": .object(["name": .string("acme")]),
        "ctx_create_environment": .object(["projectPath": .string("/p.json")]),
        "ctx_rename_environment": .object([
            "project": .string("acme"), "projectPath": .string("/p.json"),
            "name": .string("dev"), "newName": .string("qa")]),
        "ctx_remove_environment": .object([
            "project": .string("acme"), "projectPath": .string("/p.json"), "name": .string("dev")]),
        "ctx_set_project": .object(["name": .string("widgets")]),
        "ctx_set_environment": .object(["name": .string("dev")]),
        "ctx_set_editor_settings": .object(["fontSize": .integer(14)]),
        "ctx_set_browser_settings": .object(["searchEngine": .string("kagi")]),
        // 3b-viii. Needs its `id`, or it throws `.missingParam` first.
        "ctx_set_local_provider": .object(["id": .string("qwen"), "baseURL": .string("http://127.0.0.1:8012")]),
        "ctx_git_account_add": .object(["id": .string("o"), "host": .string("github.com"), "provider": .string("github"), "method": .string("ssh")]),
        "ctx_git_account_remove": .object(["id": .string("o"), "host": .string("github.com")]),
        "ctx_git_account_test": .object(["id": .string("o"), "host": .string("github.com")]),
        "ctx_git_api_access_token_set": .object(["id": .string("o"), "host": .string("github.com"), "token": .string("t")]),
        "ctx_git_api_access_remove": .object(["id": .string("o"), "host": .string("github.com")]),
        "ctx_git_api_access_test": .object(["id": .string("o"), "host": .string("github.com")]),
        "ctx_git_host_suggestions": .object(["id": .string("o")]),
        "ctx_git_key_generate": .object(["id": .string("o"), "host": .string("github.com"), "comment": .string("c")]),
        "ctx_git_key_passphrase_set": .object(["id": .string("o"), "host": .string("github.com"), "passphrase": .string("p")]),
        "ctx_git_ssh_keys": .object(["id": .string("o")]),
        "ctx_git_token_set": .object(["id": .string("o"), "host": .string("github.com"), "token": .string("t")]),
        "ctx_git_device_start": .object(["id": .string("o"), "provider": .string("github")]),
        "ctx_git_device_poll": .object(["id": .string("o"), "provider": .string("github"), "host": .string("github.com"), "deviceCode": .string("d")]),
        "ctx_git_gh_logins": .object(["id": .string("o")]),
        "ctx_git_gh_import": .object(["id": .string("o"), "host": .string("github.com"), "user": .string("u")]),
        "ctx_connection_catalog": .object([:]),
        "ctx_connection_add": .object(["id": .string("o"), "kind": .string("github")]),
        "ctx_connection_update": .object(["id": .string("o"), "name": .string("github")]),
        "ctx_connection_remove": .object(["id": .string("o"), "name": .string("github")]),
        "ctx_connection_secrets_set": .object(["id": .string("o"), "name": .string("github"), "values": .object([:])]),
        "ctx_connection_allow_set": .object(["id": .string("o"), "name": .string("github"), "tool": .string("t"), "allow": .bool(true)]),
        "ctx_connection_signin_start": .object(["id": .string("o"), "name": .string("github")]),
        "ctx_connection_signin_wait": .object(["id": .string("o"), "name": .string("github")]),
        "ctx_connection_signout": .object(["id": .string("o"), "name": .string("github")]),
        "ctx_jira_token_set": .object(["id": .string("o"), "email": .string("e"), "token": .string("t")]),
        "ctx_set_project_agent_instructions": .object(["projectPath": .string("/p/project.json"), "general": .string("g")]),
        "ctx_set_project_editor_settings": .object(["projectPath": .string("/p.json"), "tabSize": .integer(2)]),
        "ctx_set_project_pm_key": .object(["projectPath": .string("/p.json"), "projectKey": .string("INI")]),
        "ctx_editor_settings": .object([:]),
        "ctx_browser_settings": .object([:]),
        "ctx_keyboard": .object([:]),
        "ctx_set_key": .object(["id": .string("pane.close"), "chord": .string("⌃⌘W")]),
        "ctx_set_keys": .object(["keys": .object([:])]),
        "ctx_github_pull_requests": .object([:]),
        "ctx_set_provider": .object(["name": .string("work")]),
        "db_list_databases": .object([:]),
        "db_run_query": .object(["query": .string("select 1")]),
        // `session_resume` itself is deliberately absent from this map: as
        // of Task 9 it needs no client at all, only `resumes` — it parks
        // into the broker and returns, so dispatching it here with both
        // clients `nil` would succeed rather than throw, breaking the
        // premise of this test. `session_get` is the action that inherited
        // the client-dependent metadata read `session_resume` used to be.
        "session_get": .object(["id": .string("abc")]),

        // The following were added to make this test earn its "every"
        // (Task 6). Every one below checks its client with `guard let
        // ... else { throw .missingClient }` as the FIRST line of its
        // handler, before any parameter is read — and the loop below
        // asserts exactly that, so none of these can quietly pass on a
        // `.missingParam` instead. Each gets its schema's required
        // fields, read from its own registration in
        // `Sources/WakilKit/Registry/StandardActions.swift`, so a
        // handler that checked params before its client would still be
        // caught rather than accidentally satisfied.
        "ctx_list_orgs": .object([:]),
        "ctx_config_tree_for": .object(["id": .string("umbrella")]),
        "ctx_create_org": .object(["id": .string("newco")]),
        "ctx_adopt_provider": .object([
            "org": .string("acme"), "id": .string("work"),
            "configDir": .string("/tmp/config"), "kind": .string("claude"),
        ]),
        "ctx_list_machine_providers": .object([:]),
        "ctx_list_providers": .object([:]),
        "db_list_tables": .object([:]),
        "db_describe_table": .object(["table": .string("users")]),
        "db_read_table": .object(["table": .string("users")]),
        "db_refetch": .object(["pane": .string("db")]),
        "db_page": .object(["pane": .string("db"), "to": .string("next")]),
        "db_render_update": .object([
            "table": .string("users"), "rowKey": .string("1"),
            "column": .string("name"), "value": .string("Ada"),
        ]),
        "db_classify_statement": .object(["statement": .string("select 1")]),
        // `db_run_mutation` needs its own dispatch below, not this loop:
        // see that call for why. Its entry stays here only so the
        // completeness check above still finds it accounted for.
        "db_run_mutation": .object(["statement": .string("update users set name='Ada' where id=1")]),
        "session_read": .object(["id": .string("abc")]),
        "session_list": .object([:]),
        "ctx_list_environments": .object([:]),
        "session_record_parent": .object(["child": .string("child-1"), "parent": .string("parent-1")]),
    ]

    /// Actions that need no client, so dispatching them with both `nil`
    /// would succeed rather than throw and break this test's premise.
    /// Every exclusion is named, and adding one is a deliberate act.
    let needsNoClient: Set<String> = [
        // Parks into `resumes` and returns; needs no client at all.
        "session_resume",
        // Never touches `context` or `db` — it only calls
        // `providerSwitches.request(...)`, which is always present (it
        // defaults to a fresh `ProviderSwitchBroker()`), and returns
        // `.object(["switching": ...])` unconditionally. Verified: with
        // both clients `nil` it succeeds rather than throwing.
        "session_set_provider",
        // Conversations 2 of 3: both park into `conversationRequests` and return, as
        // `session_set_provider` does; neither touches a client. Conversations 3 of 3:
        // `session_close` parks there too.
        "session_close", "session_new", "session_switch",
        // Names: `conversation_rename` parks there too, and checks no client.
        "conversation_rename",
        // Checks no client before touching `panes`/`layout`. With no
        // `layout` wired (this test's `registerStandardActions` call
        // passes none, so it defaults to `nil`), `requireOpenPane`
        // returns early instead of validating the pane exists, and
        // `PaneStore` hands back a fresh, empty entry for any unknown
        // pane id rather than failing — so the handler runs to
        // completion and returns a result. Verified: with both clients
        // `nil` it succeeds rather than throwing.
        "pane_sort",
        // Reaches no database: it only asks `panes` to end a read. With no `layout` wired it
        // skips the pane check, and an unknown pane has nothing in flight, so it throws
        // `nothingInFlight`, not `missingClient`.
        "db_cancel",
    ]

    let registered = Set(await r.all().map(\.name))
    let covered = Set(paramsByAction.keys).union(needsNoClient)
    #expect(registered.subtracting(covered).isEmpty,
            "every registered action must appear in paramsByAction or be named in needsNoClient")

    // Asserting `StandardActionError.self` alone would not be this test:
    // `.missingParam`, `.unknownPane` and `.paneHasNoQuery` are all
    // `StandardActionError`s an entry with the wrong params would throw
    // without the missing-client guard ever running. So each dispatch is
    // required to throw `.missingClient` **naming the action dispatched**
    // — which is the "names what is missing" this test's own requirement
    // asks for, and the only assertion that proves the guard was reached.
    for (name, params) in paramsByAction where name != "db_run_mutation" {
        await expectMissingClient(action: name) {
            _ = try await r.dispatch(
                name: name, params: params, origin: .debug,
                caller: .test("dev"), confirmation: nil)
        }
    }

    // `db_run_mutation` is `.mutate`: with `confirmation: nil` the write
    // gate throws `ActionError.needsConfirmation` before the handler ever
    // runs (verified), which is not a `StandardActionError` and would
    // fail the loop above for the wrong reason. Passing `"confirm"`
    // clears the gate so this reaches the same missing-client check every
    // other action here does.
    await expectMissingClient(action: "db_run_mutation") {
        _ = try await r.dispatch(
            name: "db_run_mutation", params: paramsByAction["db_run_mutation"]!, origin: .debug,
            caller: .test("dev"), confirmation: "confirm")
    }
}

/// Runs `dispatch` and requires it to throw
/// `StandardActionError.missingClient` whose `action` is `action`.
///
/// Split out of `everyActionWithAMissingClientThrowsRatherThanCrashing`
/// so the loop and the one separate `db_run_mutation` dispatch make the
/// identical assertion. `#expect(throws: StandardActionError.self)` is
/// deliberately not what this does: see that test's own comment.
private func expectMissingClient(
    action: String, _ dispatch: () async throws -> Void,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    do {
        try await dispatch()
        Issue.record(
            "\(action): expected .missingClient with no client wired, but the dispatch returned",
            sourceLocation: sourceLocation)
    } catch let error as StandardActionError {
        guard case .missingClient(let named, _) = error else {
            let detail = "\(action): expected .missingClient but got \(error) — this entry never "
                + "reaches the missing-client guard; give it params that do, or name it in "
                + "needsNoClient with its reason"
            Issue.record(Comment(rawValue: detail), sourceLocation: sourceLocation)
            return
        }
        #expect(named == action, "thrown .missingClient must name the action dispatched",
                sourceLocation: sourceLocation)
    } catch {
        Issue.record("\(action): expected a StandardActionError but got \(error)",
                     sourceLocation: sourceLocation)
    }
}

/// A required param that is simply absent must also throw a clear,
/// specific error rather than crashing on an unwrap of a missing key.
@Test func missingRequiredParamThrowsRatherThanCrashing() async throws {
    let r = ActionRegistry(journalDirectory: testScratchRoot
        .appendingPathComponent(UUID().uuidString), sessionId: "s1")
    await registerStandardActions(into: r, context: nil, panes: PaneStore(), db: nil, resumes: ResumeBroker())

    do {
        _ = try await r.dispatch(name: "ctx_set_project", params: .object([:]), origin: .debug, caller: .test("dev"), confirmation: nil)
        Issue.record("should have thrown for a missing \"name\" param")
    } catch let error as StandardActionError {
        // A missing client is checked before a missing param in this
        // implementation (context is nil here too), so either miss is an
        // acceptable, equally clear failure — the point is it is neither
        // a crash nor a silent success.
        switch error {
        case .missingClient, .missingParam:
            break
        case .serverError:
            Issue.record("did not expect a server error with no client configured")
        case .mutationFateUnknown:
            Issue.record("did not expect a mutation timeout from a .control action with no client")
        case .unknownPane:
            Issue.record("did not expect a pane error from an action that names no pane")
        case .paneHasNoQuery:
            Issue.record("did not expect a paneHasNoQuery error from ctx_set_project")
        case .paneNotPageable:
            Issue.record("did not expect a paneNotPageable error from ctx_set_project")
        case .readInFlight, .nothingInFlight:
            Issue.record("did not expect a db-read flight error from ctx_set_project")
        }
    }
}

private func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)          // app/Tests/WakilKitTests/StandardActionsTests.swift
        .deletingLastPathComponent()          // WakilKitTests
        .deletingLastPathComponent()          // Tests
        .deletingLastPathComponent()          // app
        .deletingLastPathComponent()          // repo root
}

// MARK: - Cross-org isolation, through the path the window takes

/// Spec §6: `ctx_set_project` must surface `Resolve()`'s refusal of a
/// project filed under another org as a first-class error, not a silent
/// no-op — and 2a must prove that "through this new path". So this
/// dispatches the action, against the real `bin/wakil-ctx`, rather than
/// calling the client or a store method directly: dispatching is what the
/// window's **Set project** button does, and a test of anything else would
/// be evidence for a path the app does not take.
///
/// Verified two ways, because a partial success is the failure that would
/// look like nothing: the throw itself, carrying `wakil-ctx`'s own text, and
/// that the active project afterwards is still unset.
///
/// Nothing here touches the real `~/.wakil` — `makeFixture` writes a scratch
/// `HOME` — and `wakil-ctx` never touches the Keychain.
@Test func ctxSetProjectRefusesAProjectFiledUnderAnotherOrg() async throws {
    let bin = repoRoot().appendingPathComponent("bin/wakil-ctx")
    try #require(FileManager.default.isExecutableFile(atPath: bin.path), "run `make build` first")
    // Registered under org "acme"'s registry, but project.json itself
    // declares org "beta" — SetProjectChecked's cross-org guard.
    let home = try makeFixture(org: "acme", projectOrg: "beta", environments: ["dev"])
    let client = try await startedClient(bin: bin, home: home, org: "acme")
    let r = ActionRegistry(journalDirectory: testScratchRoot
        .appendingPathComponent(UUID().uuidString), sessionId: "s1")
    await registerStandardActions(into: r, context: client, panes: PaneStore(), db: nil, resumes: ResumeBroker())

    do {
        _ = try await r.dispatch(
            name: "ctx_set_project", params: .object(["name": .string("widgets")]),
            origin: .ui, caller: .test("dev"), confirmation: nil)
        Issue.record("expected ctx_set_project to refuse a project filed under another org")
    } catch StandardActionError.serverError(let action, let message) {
        #expect(action == "ctx_set_project")
        #expect(message.contains("filed under org"))
        #expect(message.contains("\"acme\""))
        #expect(message.contains("\"beta\""))
    }

    // No active project was ever successfully set, so the context still
    // reports that rather than some partially-applied state.
    do {
        _ = try await ContextStore(client: client).current()
        Issue.record("expected current() to still report no active project")
    } catch ContextStoreError.serverError(let message, let partial) {
        #expect(message.contains("no active project"))
        // The error names the org even though it could not resolve the
        // project — spec §6.1's Go half (`wakilcore.PartialResolved`),
        // arriving intact. This fixture's HOME holds org "acme".
        #expect(partial.org == "acme")
    }

    await client.stop()
}

/// The same never-silently-succeed contract on the other context action.
@Test func ctxSetEnvironmentRefusesAnEnvironmentTheProjectDoesNotDeclare() async throws {
    let bin = repoRoot().appendingPathComponent("bin/wakil-ctx")
    try #require(FileManager.default.isExecutableFile(atPath: bin.path), "run `make build` first")
    let home = try makeFixture(org: "acme", projectOrg: "acme", environments: ["dev"])
    let client = try await startedClient(bin: bin, home: home, org: "acme")
    let r = ActionRegistry(journalDirectory: testScratchRoot
        .appendingPathComponent(UUID().uuidString), sessionId: "s1")
    await registerStandardActions(into: r, context: client, panes: PaneStore(), db: nil, resumes: ResumeBroker())

    _ = try await r.dispatch(
        name: "ctx_set_project", params: .object(["name": .string("widgets")]),
        origin: .ui, caller: .test("dev"), confirmation: nil)

    do {
        _ = try await r.dispatch(
            name: "ctx_set_environment", params: .object(["name": .string("staging")]),
            origin: .ui, caller: .test("dev"), confirmation: nil)
        Issue.record("expected ctx_set_environment to refuse an environment the project doesn't declare")
    } catch StandardActionError.serverError(let action, let message) {
        #expect(action == "ctx_set_environment")
        #expect(message == "unknown environment: staging")
    }

    await client.stop()
}

/// End-to-end: dispatch `ctx_list_projects` and `session_resume` through
/// the registry against the real `bin/wakil-ctx` binary (a scratch `HOME`
/// with no org configured at all — nothing here touches the real
/// `~/.wakil`, and wakil-ctx never touches the Keychain, so this is safe
/// to run without spawning `wakil-db` or the `claude` binary). Confirms
/// the standard action set is wired to a real client end-to-end, not just
/// checked against a `nil` one.
@Test func ctxListProjectsDispatchesThroughToTheRealBinary() async throws {
    let bin = repoRoot().appendingPathComponent("bin/wakil-ctx")
    try #require(FileManager.default.isExecutableFile(atPath: bin.path),
                 "run `make build` first")
    let home = testScratchRoot.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

    let client = MCPClient(executable: bin, arguments: [],
                           environment: ["HOME": home.path, "WAKIL_ORG": "probe", "PATH": "/usr/bin:/bin"])
    try await client.start()

    let r = ActionRegistry(journalDirectory: testScratchRoot
        .appendingPathComponent(UUID().uuidString), sessionId: "s1")
    await registerStandardActions(into: r, context: client, panes: PaneStore(), db: nil, resumes: ResumeBroker())

    // No org "probe" has ever been created in this scratch HOME, so
    // list_projects reports its own error rather than an empty list —
    // still a normal dispatch outcome (the handler ran and returned),
    // not a hang or a crash.
    do {
        _ = try await r.dispatch(name: "ctx_list_projects", params: .object([:]), origin: .debug, caller: .test("dev"), confirmation: nil)
        Issue.record("expected ctx_list_projects to report an error for an org that was never created")
    } catch is StandardActionError {
        // expected: the server reported isError, surfaced as .serverError
    }

    await client.stop()
}

@Test func contextSettersAreControlAndOnlyTheEnvironmentOneNamesATarget() async {
    let directory = testScratchRoot
        .appendingPathComponent("std-kinds-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let registry = ActionRegistry(journalDirectory: directory, sessionId: "s")
    await registerStandardActions(into: registry, context: nil, panes: PaneStore(), db: nil, resumes: ResumeBroker())

    let byName = Dictionary(uniqueKeysWithValues: await registry.all().map { ($0.name, $0) })
    #expect(byName["ctx_set_project"]?.kind == .control)
    #expect(byName["ctx_set_environment"]?.kind == .control)
    #expect(byName["ctx_set_provider"]?.kind == .control)
    // Reads stay reads.
    #expect(byName["ctx_list_projects"]?.kind == .read)
    #expect(byName["db_run_query"]?.kind == .read)
    #expect(byName["session_get"]?.kind == .read)
    #expect(byName["session_list"]?.kind == .read)
    // db_run_mutation (Phase 2b-iii) is the one deliberate exception to
    // "nothing here is ever a mutation" — it is Wakil's first `.mutate`
    // action, and the only one.
    #expect(byName["db_run_mutation"]?.kind == .mutate)
    #expect(await registry.all().filter { $0.kind == .mutate }.map(\.name) == ["db_run_mutation"])
}

@Test func sessionListIsRegisteredAndFailsLoudlyWithoutAClient() async {
    let directory = testScratchRoot
        .appendingPathComponent("std-sessions-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let registry = ActionRegistry(journalDirectory: directory, sessionId: "s")
    await registerStandardActions(into: registry, context: nil, panes: PaneStore(), db: nil, resumes: ResumeBroker())

    await #expect(
        throws: StandardActionError.missingClient(action: "session_list", role: "context")
    ) {
        _ = try await registry.dispatch(
            name: "session_list", params: .object([:]),
            origin: .ui, caller: .test("staging"), confirmation: nil)
    }
}

/// Pins the Phase 1 behaviour `writeGate` leans on: switching project
/// preserves the environment name when the incoming project defines it and
/// clears it otherwise. It never substitutes a *different* environment, and
/// in particular never selects `production`.
///
/// This is why `ctx_set_project` declares no `targetEnvironmentParam` while
/// `ctx_set_environment` does. If this test fails, the setter needs one and
/// `writeGate`'s agent rule needs to cover it — do not simply update the
/// expectation.
@Test func ctxSetProjectCannotElevateIntoProduction() async throws {
    let bin = repoRoot().appendingPathComponent("bin/wakil-ctx")
    try #require(FileManager.default.isExecutableFile(atPath: bin.path), "run `make build` first")
    let home = try makeTwoProjectFixture(org: "acme", projects: [
        (name: "alpha", environments: ["staging", "production"]),
        (name: "beta", environments: ["production"]),
    ])
    let client = try await startedClient(bin: bin, home: home, org: "acme")
    let registry = ActionRegistry(journalDirectory: testScratchRoot
        .appendingPathComponent(UUID().uuidString), sessionId: "s1")
    await registerStandardActions(into: registry, context: client, panes: PaneStore(), db: nil, resumes: ResumeBroker())

    func dispatch(_ name: String, _ value: String) async throws {
        _ = try await registry.dispatch(
            name: name, params: .object(["name": .string(value)]),
            origin: .ui, caller: .test("staging"), confirmation: nil)
    }

    try await dispatch("ctx_set_project", "alpha")
    try await dispatch("ctx_set_environment", "staging")
    #expect(try await ContextStore(client: client).current().environment == "staging")

    // beta does not define `staging`, so the environment clears. It does
    // NOT become beta's only environment, `production`.
    try await dispatch("ctx_set_project", "beta")
    #expect(try await ContextStore(client: client).current().environment == "")

    await client.stop()
}

// MARK: - `ctx_set_provider` (Phase 2b-vi Task 9)

/// Writes a minimal provider record directly to a scratch `HOME`, without
/// spawning the `wakil` CLI's `provider add` — enough for `LoadProviderFor`
/// (`internal/wakilcore/provider.go`) to find `id` registered under `org`,
/// which `setActiveProvider` (`cmd/wakil-ctx/main.go`) requires before it
/// will persist a switch to it. `local` needs no `configDir`
/// (`AddProvider`'s own validation), so this fixture needs nothing more
/// than the file existing.
private func writeProviderFixture(home: URL, org: String, id: String) throws {
    let dir = home.appendingPathComponent(".wakil/orgs/\(org)/providers")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try #"{"kind":"local"}"#.write(
        to: dir.appendingPathComponent("\(id).json"), atomically: true, encoding: .utf8)
}

/// The persistence half of Task 9's swap: dispatching `ctx_set_provider`
/// through the registry — the exact call `WindowModel.setProvider` makes
/// after a successful swap — against the real `bin/wakil-ctx` binary
/// leaves `get_context`'s `ActiveProvider` reporting the new id
/// afterwards, read back the same way
/// `currentReflectsProjectAndEnvironmentAfterTheActionsSetThem`
/// (`ContextStoreTests.swift`) reads project and environment: through
/// `ContextStore.current()`, not a raw file read, so this proves the wire
/// round trip end to end rather than just that `active.json` changed on
/// disk underneath it.
@Test func ctxSetProviderPersistsThroughTheRealBinaryAndIsVisibleToGetContext() async throws {
    let bin = repoRoot().appendingPathComponent("bin/wakil-ctx")
    try #require(FileManager.default.isExecutableFile(atPath: bin.path), "run `make build` first")
    let home = try makeFixture(org: "acme", projectOrg: "acme", environments: ["dev"])
    try writeProviderFixture(home: home, org: "acme", id: "work")
    let client = try await startedClient(bin: bin, home: home, org: "acme")
    let r = ActionRegistry(journalDirectory: testScratchRoot
        .appendingPathComponent(UUID().uuidString), sessionId: "s1")
    await registerStandardActions(into: r, context: client, panes: PaneStore(), db: nil, resumes: ResumeBroker())

    // `get_context` (hence `ContextStore.current()`) refuses outright with
    // no active project (`Resolve()`'s own "no active project" error) —
    // exactly the refusal `currentReflectsProjectAndEnvironmentAfterThe
    // ActionsSetThem` in `ContextStoreTests.swift` works around the same
    // way, so this sets one before ever calling `current()`.
    _ = try await r.dispatch(
        name: "ctx_set_project", params: .object(["name": .string("widgets")]),
        origin: .ui, caller: .test("dev"), confirmation: nil)
    #expect(try await ContextStore(client: client).current().activeProvider == "")

    _ = try await r.dispatch(
        name: "ctx_set_provider", params: .object(["name": .string("work")]),
        origin: .ui, caller: .test("dev"), confirmation: nil)

    #expect(try await ContextStore(client: client).current().activeProvider == "work")

    await client.stop()
}

/// The refusal companion: an id nothing registered must never reach
/// `active.json`, exactly as `ctxSetProjectRefusesAProjectFiledUnderAnotherOrg`
/// and `ctxSetEnvironmentRefusesAnEnvironmentTheProjectDoesNotDeclare` pin
/// the same never-silently-succeed contract for the other two setters.
@Test func ctxSetProviderRefusesAnUnregisteredProviderId() async throws {
    let bin = repoRoot().appendingPathComponent("bin/wakil-ctx")
    try #require(FileManager.default.isExecutableFile(atPath: bin.path), "run `make build` first")
    let home = try makeFixture(org: "acme", projectOrg: "acme", environments: ["dev"])
    let client = try await startedClient(bin: bin, home: home, org: "acme")
    let r = ActionRegistry(journalDirectory: testScratchRoot
        .appendingPathComponent(UUID().uuidString), sessionId: "s1")
    await registerStandardActions(into: r, context: client, panes: PaneStore(), db: nil, resumes: ResumeBroker())

    do {
        _ = try await r.dispatch(
            name: "ctx_set_provider", params: .object(["name": .string("ghost")]),
            origin: .ui, caller: .test("dev"), confirmation: nil)
        Issue.record("expected ctx_set_provider to refuse an unregistered provider id")
    } catch StandardActionError.serverError(let action, let message) {
        #expect(action == "ctx_set_provider")
        #expect(message.contains("ghost"))
    }

    // Confirmed through the same `get_context` round trip the success case
    // uses — an active project is required before `current()` will answer
    // at all (see the success test's comment) — rather than a raw file
    // read, so a refusal that partially wrote something would still show
    // up here.
    _ = try await r.dispatch(
        name: "ctx_set_project", params: .object(["name": .string("widgets")]),
        origin: .ui, caller: .test("dev"), confirmation: nil)
    #expect(try await ContextStore(client: client).current().activeProvider == "")
    await client.stop()
}


// MARK: - 2e-ii: projects and environments from Settings

private let projectEnvironmentActions = [
    "ctx_create_project", "ctx_rename_project", "ctx_remove_project",
    "ctx_create_environment", "ctx_rename_environment", "ctx_remove_environment",
]

/// A registry over a recording context client, with `agentIn` answering as the test says.
private func projectEnvironmentRegistry(
    agentIn: (@Sendable (String, String?) async -> String?)? = nil
) async throws -> (ActionRegistry, RecordingToolCaller) {
    let dir = testScratchRoot.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let client = RecordingToolCaller(always: .object(["ok": .bool(true)]))
    let registry = ActionRegistry(
        journalDirectory: dir.appendingPathComponent("journal"), sessionId: "s1")
    await registerStandardActions(
        into: registry, context: client, panes: PaneStore(), db: nil, resumes: ResumeBroker(),
        agentIn: agentIn)
    return (registry, client)
}

@Test func theSixProjectAndEnvironmentActionsAreOperatorOnlyControls() async throws {
    let (registry, _) = try await projectEnvironmentRegistry()
    let byName = Dictionary(uniqueKeysWithValues: await registry.all().map { ($0.name, $0) })
    for name in projectEnvironmentActions {
        #expect(byName[name]?.kind == .control, "\(name)")
        #expect(byName[name]?.audience == .operatorOnly, "\(name)")
        #expect(operatorOnlyActions.contains(name), "\(name)")
    }
}

@Test func theSixActionsForwardToTheirToolsWithTheToolsArguments() async throws {
    let (registry, client) = try await projectEnvironmentRegistry()
    let cases: [(String, [String: JSONValue], String, [String: JSONValue])] = [
        ("ctx_create_project", ["folder": .string("/w"), "name": .string("acme")],
         "create_project", ["folder": .string("/w"), "name": .string("acme")]),
        ("ctx_rename_project", ["name": .string("acme"), "newName": .string("beta")],
         "rename_project", ["name": .string("acme"), "newName": .string("beta")]),
        ("ctx_remove_project", ["name": .string("acme")],
         "remove_project", ["name": .string("acme")]),
        ("ctx_create_environment", ["projectPath": .string("/p.json")],
         "create_environment", ["projectPath": .string("/p.json")]),
        // `project` is the pin check's, not the tool's: it must not be forwarded.
        ("ctx_rename_environment",
         ["project": .string("acme"), "projectPath": .string("/p.json"),
          "name": .string("dev"), "newName": .string("qa")],
         "rename_environment",
         ["projectPath": .string("/p.json"), "name": .string("dev"), "newName": .string("qa")]),
        ("ctx_remove_environment",
         ["project": .string("acme"), "projectPath": .string("/p.json"), "name": .string("dev")],
         "remove_environment", ["projectPath": .string("/p.json"), "name": .string("dev")]),
    ]
    for (action, params, tool, expected) in cases {
        await client.reset()
        _ = try await registry.dispatch(
            name: action, params: .object(params), origin: .ui, caller: .test("dev"),
            confirmation: nil)
        let calls = await client.calls
        #expect(calls.count == 1, "\(action)")
        #expect(calls.first?.name == tool, "\(action)")
        #expect(calls.first?.arguments == .object(expected), "\(action)")
    }
}

@Test func renameProjectAndRemoveEnvironmentAreRefusedWhereAnAgentRuns() async throws {
    let (registry, client) = try await projectEnvironmentRegistry(agentIn: { project, environment in
        project == "acme" && (environment == nil || environment == "dev") ? "agent-1" : nil
    })
    do {
        _ = try await registry.dispatch(
            name: "ctx_rename_project",
            params: .object(["name": .string("acme"), "newName": .string("beta")]),
            origin: .ui, caller: .test("dev"), confirmation: nil)
        Issue.record("expected the rename to be refused")
    } catch {
        let text = "\(error)"
        #expect(text.contains("agent-1 is running in acme"))
        #expect(text.contains("an agent keeps its own place"))
    }
    do {
        _ = try await registry.dispatch(
            name: "ctx_remove_environment",
            params: .object([
                "project": .string("acme"), "projectPath": .string("/p.json"),
                "name": .string("dev"),
            ]),
            origin: .ui, caller: .test("dev"), confirmation: nil)
        Issue.record("expected the removal to be refused")
    } catch {
        let text = "\(error)"
        #expect(text.contains("agent-1 is running in acme / dev"))
        #expect(text.contains("an agent keeps its own place"))
    }
    // An environment the agent is not in, and a project it is not in, go through.
    _ = try await registry.dispatch(
        name: "ctx_remove_environment",
        params: .object([
            "project": .string("acme"), "projectPath": .string("/p.json"), "name": .string("qa"),
        ]),
        origin: .ui, caller: .test("dev"), confirmation: nil)
    _ = try await registry.dispatch(
        name: "ctx_remove_project", params: .object(["name": .string("other")]),
        origin: .ui, caller: .test("dev"), confirmation: nil)
    #expect(await client.calls.map(\.name) == ["remove_environment", "remove_project"])
}

@Test func createActionsAreNeverPinned() async throws {
    let (registry, client) = try await projectEnvironmentRegistry(agentIn: { _, _ in "agent-1" })
    _ = try await registry.dispatch(
        name: "ctx_create_project",
        params: .object(["folder": .string("/w"), "name": .string("acme")]),
        origin: .ui, caller: .test("dev"), confirmation: nil)
    _ = try await registry.dispatch(
        name: "ctx_create_environment", params: .object(["projectPath": .string("/p.json")]),
        origin: .ui, caller: .test("dev"), confirmation: nil)
    #expect(await client.calls.map(\.name) == ["create_project", "create_environment"])
}

@Test func theAgentLookupAnswersNilUntilWiredThenAsksTheWindow() async {
    let lookup = ActiveAgentLookup()
    #expect(await lookup.agent(in: "acme", environment: nil) == nil)
    lookup.use { project, environment in "agent-\(project)-\(environment ?? "any")" }
    #expect(await lookup.agent(in: "acme", environment: "dev") == "agent-acme-dev")
    #expect(await lookup.agent(in: "acme", environment: nil) == "agent-acme-any")
}

@Test func theRunningAgentPredicateMatchesLiveAgentsOfThisOrgByProjectAndEnvironment() {
    let dev = Place(organization: "initech", project: "acme", environment: "dev")
    let other = Place(organization: "globex", project: "acme", environment: "dev")
    let agents: [(place: Place, live: Bool, providerId: String)] = [
        (dev, true, "claude"), (other, true, "codex"),
    ]
    // Project match, any environment.
    #expect(runningAgentName(among: agents, organization: "initech", project: "acme", environment: nil)
        == "agent (claude)")
    // Environment match, and mismatch.
    #expect(runningAgentName(among: agents, organization: "initech", project: "acme", environment: "dev")
        == "agent (claude)")
    #expect(runningAgentName(among: agents, organization: "initech", project: "acme", environment: "qa") == nil)
    // A different project.
    #expect(runningAgentName(among: agents, organization: "initech", project: "beta", environment: nil) == nil)
    // No live harness: not running.
    #expect(runningAgentName(among: [(dev, false, "claude")], organization: "initech",
                             project: "acme", environment: nil) == nil)
    // Same project name in another org does not block this org.
    #expect(runningAgentName(among: [(other, true, "codex")], organization: "initech",
                             project: "acme", environment: nil) == nil)
}
