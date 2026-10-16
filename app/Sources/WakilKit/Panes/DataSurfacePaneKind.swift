import Foundation

/// A read in flight on a db pane — the shape of `ApiFlight`. One per pane: a second read is
/// refused (Interaction Rule 5). Writes are never flights; a cancelled write may still land.
struct DBFlight {
    let token: UUID
    let since: Date
    /// Cancels the read's task. `nil` until `armDBRead`. Unlike `ApiFlight` there is no
    /// `cancelRequested`: a cancel clears the flight, so an arm that finds none cancels itself.
    var cancel: (@Sendable () -> Void)?
}

struct DataSurfaceContents {
    /// How many times this pane has replaced its rows.
    ///
    /// **A capture dies when this moves** (#137 ruling 2). The model
    /// has carried `ApiValueSource.generation` since that ruling with
    /// nothing producing one, because until a row could be dropped
    /// there was nothing to kill. `setRows` is the single writer that
    /// replaces a result, so it is the only place this can be right.
    ///
    /// **A re-sort does not move it, and that is the distinction the
    /// counter exists to draw.** `reorder` changes which row is drawn
    /// where; it re-reads nothing. A capture that died on a re-sort
    /// would die on the operator tidying the view.
    var generation: Int = 0
    var columns: [String] = []
    var columnTypes: [String] = []
    var columnTypesInferred = false
    var rows: [[JSONValue]] = []
    /// `rows` in the order actually on screen — `sortedRows` applied.
    ///
    /// **Derived and cached rather than recomputed in `snapshot`.**
    /// `snapshot` is read on every `refreshPanes` as well as by every
    /// `read_pane`, and re-sorting 50,000 rows per read would put an
    /// O(n log n) sort on a path that runs whenever anything changes.
    /// `rows` and `sort` are the only inputs, and `setRows`/`reorder`
    /// are the only writers of either, so this is refreshed exactly
    /// where those two are set.
    ///
    /// The unsorted `rows` is kept alongside rather than replaced so
    /// that re-sorting by a second column orders the result the
    /// database gave, not the result of the previous sort — otherwise
    /// ties would be broken by whatever ordering happened to precede
    /// them.
    var displayRows: [[JSONValue]] = []
    var millis: Int64 = 0
    var truncated = false
    /// Whether this result can be asked for a second page at all —
    /// `wakilcore.Rows.Pageable`, carried through. False for an
    /// `EXPLAIN` and a `SHOW`, which the read-only gate permits and
    /// which cannot survive the subquery paging wraps them in.
    var pageable = false
    /// How many rows were skipped to produce this page. The footer's
    /// "rows 501–1,000" is this plus one, through this plus the row
    /// count.
    var offset = 0
    var selection: PaneSelection = .empty
    var sort: [PaneSort] = []
    /// The row the surface has been asked to bring into view, cleared
    /// once it has been. Runtime state: it describes a scroll that is
    /// about to happen, and a persisted one would scroll a pane on
    /// launch for a request nobody made.
    var scrollTarget: Int?
    /// Why this pane's last fetch did not produce rows, or `nil` if it
    /// succeeded.
    ///
    /// **Beside `rows` rather than replacing them.** A pane showing its
    /// last good result under a line saying the refetch failed is
    /// honest; a pane blanked by a transient failure has thrown away
    /// the only thing it knew.
    var failure: String?
    /// Whether this result's rows name tables in this pane's own
    /// database — `wakilcore.Rows.ListsTables`, carried through so
    /// `offersDrill` can answer for a `.sql` pane without inferring one
    /// from the shape of the rows. False for a `.columns` pane, which
    /// never produces a `Rows` at all.
    ///
    /// **True for a `.tables` pane too (final review, Minor 5).**
    /// `db_list_tables` and `refetchPane`'s `.tables` case both write
    /// `true` here explicitly — see `PaneTable.listsTables`'s own doc
    /// comment (`Panes/PaneTable.swift`) for why that makes `offersDrill`'s
    /// subject branch dead for `.tables` without being wrong.
    var listsTables = false
    /// What the driver said about writing this result back, with its
    /// `rowKeys` in the SAME order as `displayRows`.
    ///
    /// It is refreshed exactly where `displayRows` is, and by the same
    /// permutation, because a key that is not in its row's position
    /// names a different row.
    var editable: PaneEditable?
    /// `editable` as it arrived, before any client-side sort — the
    /// same reason `rows` is kept beside `displayRows`: re-sorting by
    /// a second column must order what the database gave, not the
    /// result of the previous sort.
    var sourceEditable: PaneEditable?
    var flight: DBFlight?
    /// How long the last read ran before it was cancelled. Cleared when a read lands.
    var cancelledAfterMs: Int?

    /// Builds this pane's `DataSurfaceSnapshot`, moved verbatim out of the
    /// old `snapshot(paneId:)` body.
    func snapshot() -> DataSurfaceSnapshot {
        DataSurfaceSnapshot(
            columns: columns, columnTypes: columnTypes,
            columnTypesInferred: columnTypesInferred,
            // In DISPLAYED order — `read_pane`'s description promises
            // every index is one into that order, and
            // `selection`/`scrollTarget` below index it too.
            rows: displayRows, rowCount: displayRows.count, millis: millis,
            truncated: truncated, pageable: pageable, offset: offset,
            selection: selection, sort: sort, scrollTarget: scrollTarget,
            listsTables: listsTables,
            // `table`, `keyColumns` and `columns` are facts about the
            // pane worth the agent knowing. `rowKeys` are not:
            // `read_pane` feeds an LLM's context, and five hundred
            // WHERE fragments buy nothing the key column does not
            // already show.
            editable: editable.map {
                PaneEditableSummary(
                    table: $0.table, keyColumns: $0.keyColumns, columns: $0.columns)
            },
            runningSince: flight?.since, cancelledAfterMs: cancelledAfterMs)
    }
}

/// The data surface: a grid read from a database (the `db` pane).
enum DataSurfacePaneKind: PaneKind {
    static let names = ["db"]
    static var emptyContents: DataSurfaceContents { DataSurfaceContents() }
    static var emptySnapshot: DataSurfaceSnapshot? { .empty }
    /// Its subject is a read; re-running it is how a reopened pane is current.
    static let rerunsSubjectOnRestore = true
    static func snapshot(of contents: DataSurfaceContents, in store: isolated PaneStore) -> DataSurfaceSnapshot {
        contents.snapshot()
    }
    static func failure(of contents: DataSurfaceContents) -> String? { contents.failure }
    /// `columns`, `rows`, `rowCount` and the rest, flat: the word `grid` appears on the wire only
    /// under the terminal kind, where §9 of the charter puts it.
    static func readPane(_ snapshot: DataSurfaceSnapshot, in store: isolated PaneStore) -> [String: JSONValue] {
        var object: [String: JSONValue] = [:]
        object["columns"] = .array(snapshot.columns.map { .string($0) })
        object["columnTypes"] = .array(snapshot.columnTypes.map { .string($0) })
        object["columnTypesInferred"] = .bool(snapshot.columnTypesInferred)
        object["rows"] = .array(snapshot.rows.map { .array($0) })
        object["rowCount"] = .number(Double(snapshot.rowCount))
        object["millis"] = .number(Double(snapshot.millis))
        object["truncated"] = .bool(snapshot.truncated)
        object["pageable"] = .bool(snapshot.pageable)
        object["offset"] = .number(Double(snapshot.offset))
        object["selection"] = .object([
            "anchorRow": snapshot.selection.anchorRow.map { .number(Double($0)) } ?? .null,
            "anchorColumn": snapshot.selection.anchorColumn.map { .string($0) } ?? .null,
            "rows": .array(snapshot.selection.rows.sorted().map { .number(Double($0)) }),
        ])
        object["sort"] = .array(snapshot.sort.map {
            .object(["column": .string($0.column), "direction": .string($0.direction.rawValue)])
        })
        object["scrollTarget"] = snapshot.scrollTarget.map { .number(Double($0)) } ?? .null
        object["listsTables"] = .bool(snapshot.listsTables)
        // The one standing exception to "every key of the answered kind is
        // always present": `editable` is omitted rather than emitted as
        // `null` when a pane cannot be written back to a single table.
        // Verbatim, pre-2c-iii behaviour, carried through unchanged rather
        // than "fixed" here — not a bug this file introduced.
        if let editable = snapshot.editable {
            object["editable"] = .object([
                "table": .string(editable.table),
                "keyColumns": .array(editable.keyColumns.map { .string($0) }),
                "columns": .array(editable.columns.map { .string($0) }),
            ])
        }
        object["running"] = .bool(snapshot.runningSince != nil)
        object["cancelledAfterMs"] = snapshot.cancelledAfterMs.map { .number(Double($0)) } ?? .null
        return object
    }
}
