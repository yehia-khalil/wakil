import Foundation
import Testing
@testable import WakilKit

private func object(_ value: JSONValue) -> [String: JSONValue] {
    guard case .object(let o) = value else { return [:] }
    return o
}

/// `snapshot`'s "sort" is a precedence list now (D5): an array of
/// `{"column", "direction"}` objects rather than one object or `null`.
private func sortTerms(_ value: JSONValue) -> [[String: JSONValue]] {
    guard case .array(let terms) = value else { return [] }
    return terms.map(object)
}

@Test func anUntouchedPaneAnswersWithEveryKeyPresent() async {
    let store = PaneStore(kinds: PaneKinds.standard)
    let snap = object(await store.readPane(paneId: "nothing-here", kind: "db"))
    // An unknown pane id is not an error — it is a pane with nothing in it
    // yet — and every key is present rather than omitted, because an absent
    // key is a thing a reader has to know to interpret whereas an explicit
    // empty value is an answer. This object is read by an LLM.
    for key in ["columns", "columnTypes", "columnTypesInferred", "rows", "rowCount",
                "millis", "truncated", "pageable", "offset", "selection", "sort",
                "scrollTarget", "listsTables"] {
        #expect(snap[key] != nil, "missing key \(key)")
    }
    #expect(snap["sort"] == .array([]))
    #expect(snap["scrollTarget"] == .null)
    // Every key always present, including when false or zero.
    #expect(snap["pageable"] == .bool(false))
    #expect(snap["offset"] == .number(0))
    #expect(snap["listsTables"] == .bool(false))
}

@Test func rowsAndTypesRoundTripPerPane() async {
    let store = PaneStore()
    await store.setRows(
        paneId: "db-1", columns: ["id", "name"], columnTypes: ["INTEGER", "TEXT"],
        columnTypesInferred: false, rows: [[.number(1), .string("widgets")]],
        millis: 12, truncated: true, pageable: true, offset: 0, sort: [], listsTables: false, editable: nil)
    await store.setRows(
        paneId: "db-2", columns: ["k"], columnTypes: [], columnTypesInferred: false,
        rows: [], millis: 0, truncated: false, pageable: true, offset: 0, sort: [], listsTables: false, editable: nil)

    let one = object(await store.readPane(paneId: "db-1", kind: "db"))
    #expect(one["columnTypes"] == .array([.string("INTEGER"), .string("TEXT")]))
    #expect(one["millis"] == .number(12))
    #expect(one["truncated"] == .bool(true))
    #expect(one["rowCount"] == .number(1))

    // The second pane is untouched by the first. Before 2c-i exactly one
    // pane id was ever read, so "per pane" was a claim the store made and
    // nothing tested.
    let two = object(await store.readPane(paneId: "db-2", kind: "db"))
    #expect(two["rowCount"] == .number(0))
    #expect(two["columnTypes"] == .array([]))
}

@Test func selectionRoundTripsAndAlwaysContainsItsAnchor() async {
    let store = PaneStore()
    await store.setSelection(
        paneId: "db", PaneSelection(anchorRow: 7, anchorColumn: "name", rows: [2, 3]))
    let snap = object(await store.readPane(paneId: "db", kind: "db"))
    let selection = object(snap["selection"] ?? .null)
    #expect(selection["anchorRow"] == .number(7))
    #expect(selection["anchorColumn"] == .string("name"))
    guard case .array(let rows)? = selection["rows"] else {
        Issue.record("selection.rows is not an array")
        return
    }
    // Sorted on the way out. A Set has no order, and an agent diffing two
    // read_pane calls must not see a change that is only the hash seed.
    #expect(rows == [.number(2), .number(3), .number(7)])
}

@Test func sortIsRecordedAsIntentAndIsEmptyUntilSet() async {
    let store = PaneStore(kinds: PaneKinds.standard)
    #expect(object(await store.readPane(paneId: "db", kind: "db"))["sort"] == .array([]))
    // `setSort` is gone (2c-ii): `reorder` is the store's own writer of the
    // cached copy now that the authority lives on `Pane.fetch.sort`.
    await store.reorder(paneId: "db", sort: [PaneSort(column: "balance", direction: .descending)])
    let terms = sortTerms(object(await store.readPane(paneId: "db", kind: "db"))["sort"] ?? .null)
    #expect(terms.count == 1)
    #expect(terms[0]["column"] == .string("balance"))
    #expect(terms[0]["direction"] == .string("desc"))
}

@Test func settingRowsDoesNotDisturbSelectionOrSort() async {
    // These have different writers and different lifetimes: a query replaces
    // rows, and a click replaces selection. Folding them into one setter
    // would make every refresh silently clear what the operator picked.
    //
    // **Rewritten for 2c-ii.** `setRows` now takes `sort` as a required
    // parameter — a copy of the authority the caller must thread through —
    // so it no longer "leaves sort alone" the way it leaves selection
    // alone: it is told the sort on every call. What this still pins is
    // that a caller supplying the SAME sort it already had (as
    // `WindowModel` does) sees it come back unchanged, and that the
    // selection genuinely is untouched by a `setRows` that never mentions
    // it.
    let store = PaneStore()
    await store.setSelection(paneId: "db", PaneSelection(anchorRow: 1, anchorColumn: "id", rows: [1]))
    await store.reorder(paneId: "db", sort: [PaneSort(column: "id", direction: .ascending)])
    await store.setRows(
        // Two rows, so that row 1 is a row these results actually have.
        // The fixture used to hand one row to a selection anchored on row
        // 1, which made this test pass on a selection pointing at nothing
        // — see `aSelectionIsClampedToWhatTheNewRowsCanCarry` for the
        // behaviour that separates the two. The assertion below is
        // unchanged.
        paneId: "db", columns: ["id"], columnTypes: ["INTEGER"], columnTypesInferred: false,
        rows: [[.number(1)], [.number(2)]], millis: 1, truncated: false,
        pageable: true, offset: 0, sort: [PaneSort(column: "id", direction: .ascending)], listsTables: false, editable: nil)
    let snap = object(await store.readPane(paneId: "db", kind: "db"))
    #expect(object(snap["selection"] ?? .null)["anchorRow"] == .number(1))
    #expect(sortTerms(snap["sort"] ?? .null).first?["column"] == .string("id"))
}

@Test func paneIdsListsEveryPaneWrittenTo() async {
    let store = PaneStore()
    await store.setRows(paneId: "b", columns: [], columnTypes: [], columnTypesInferred: false,
                        rows: [], millis: 0, truncated: false, pageable: true, offset: 0, sort: [], listsTables: false, editable: nil)
    await store.setSelection(paneId: "a", PaneSelection(anchorRow: 0, anchorColumn: nil, rows: []))
    // Sorted, for the same reason selection.rows is.
    #expect(await store.paneIds() == ["a", "b"])
}

// MARK: - Displayed order (final review Finding 1)

/// `read_pane`'s own description promises that every row index — in
/// `selection`, in `scrollTarget`, and in the `rows` array itself — is an
/// index into the order currently DISPLAYED. Before this fix the sort was
/// applied only in the view's projection, so `snapshot` emitted rows in
/// insertion order while `selection.rows` indexed the sorted order on
/// screen: an agent that sorted a pane, read row 0 and then selected row 0
/// put the operator's luminous edge on a row it never meant.
@Test func snapshotReportsRowsInTheDisplayedOrder() async {
    let store = PaneStore()
    await store.setRows(
        paneId: "db-1", columns: ["name"], columnTypes: ["TEXT"], columnTypesInferred: false,
        rows: [[.string("c")], [.string("a")], [.string("b")]], millis: 0, truncated: false,
        pageable: true, offset: 0, sort: [], listsTables: false, editable: nil)
    await store.reorder(paneId: "db-1", sort: [PaneSort(column: "name", direction: .ascending)])
    let snap = object(await store.readPane(paneId: "db-1", kind: "db"))
    #expect(snap["rows"] == .array([
        .array([.string("a")]), .array([.string("b")]), .array([.string("c")]),
    ]))
    #expect(snap["rowCount"] == .number(3))
}

/// The order follows whichever sort is recorded *last*, in either
/// direction, and clearing the sort restores the order the query gave.
@Test func changingOrClearingTheSortRestatesTheDisplayedOrder() async {
    let store = PaneStore()
    await store.setRows(
        paneId: "db-1", columns: ["name"], columnTypes: ["TEXT"], columnTypesInferred: false,
        rows: [[.string("c")], [.string("a")], [.string("b")]], millis: 0, truncated: false,
        pageable: true, offset: 0, sort: [], listsTables: false, editable: nil)
    await store.reorder(paneId: "db-1", sort: [PaneSort(column: "name", direction: .descending)])
    #expect(object(await store.readPane(paneId: "db-1", kind: "db"))["rows"] == .array([
        .array([.string("c")]), .array([.string("b")]), .array([.string("a")]),
    ]))
    await store.reorder(paneId: "db-1", sort: [])
    #expect(object(await store.readPane(paneId: "db-1", kind: "db"))["rows"] == .array([
        .array([.string("c")]), .array([.string("a")]), .array([.string("b")]),
    ]))
}

/// Rows arriving already tagged with a sort come out ordered by it.
///
/// **Rewritten for 2c-ii.** Before this phase the store remembered a sort
/// set independently of `setRows` (via the now-deleted `setSort`) and
/// silently reapplied it to whatever rows arrived next — a "standing
/// sort" the store itself maintained across calls. `setRows` now requires
/// `sort:` on every call, because the authority lives in `Pane.fetch.sort`
/// and what the store holds is only a copy: there is no longer a standing
/// sort a caller can rely on the store to remember for it, so the
/// scenario this test pins is the caller explicitly threading the sort
/// through, not the store inferring it.
@Test func rowsArrivingUnderAStandingSortAreOrderedToo() async {
    let store = PaneStore()
    await store.setRows(
        paneId: "db-1", columns: ["name"], columnTypes: ["TEXT"], columnTypesInferred: false,
        rows: [[.string("z")], [.string("m")]], millis: 0, truncated: false,
        pageable: true, offset: 0, sort: [PaneSort(column: "name", direction: .ascending)], listsTables: false, editable: nil)
    #expect(object(await store.readPane(paneId: "db-1", kind: "db"))["rows"] == .array([
        .array([.string("m")]), .array([.string("z")]),
    ]))
}

// MARK: - One project's rows stay in that project (final review Finding 6)

/// Pane ids are unique within one process but not across sessions:
/// `LayoutStore.load` raises its counter only from the snapshot it is
/// loading, so two projects saved on disk can each contain a pane called
/// `db-1`. Keyed by pane id alone and never cleared, this store answered
/// project B's `db-1` with project A's rows — a different project's, and
/// possibly a different environment's, database, on screen and in
/// `read_pane` alike.
@Test func anotherProjectsPaneOfTheSameNameIsEmpty() async {
    let store = PaneStore(kinds: PaneKinds.standard)
    await store.switchScope(to: LayoutScope(organization: "acme", project: "alpha", environment: "dev"))
    await store.setRows(
        paneId: "db-1", columns: ["secret"], columnTypes: ["TEXT"], columnTypesInferred: false,
        rows: [[.string("alpha's production rows")]], millis: 3, truncated: true,
        pageable: true, offset: 0, sort: [], listsTables: false, editable: nil)
    await store.setSelection(paneId: "db-1", PaneSelection(
        anchorRow: 0, anchorColumn: "secret", rows: [0]))

    await store.switchScope(to: LayoutScope(organization: "acme", project: "beta", environment: "dev"))
    let snap = object(await store.readPane(paneId: "db-1", kind: "db"))
    #expect(snap["rowCount"] == .number(0))
    #expect(snap["rows"] == .array([]))
    #expect(snap["columns"] == .array([]))
    #expect(snap["truncated"] == .bool(false))
    #expect(object(snap["selection"] ?? .null)["anchorRow"] == .null)
    // And the pane is not merely empty to `read_pane` — it is not there at
    // all, so nothing draws it either.
    #expect(await store.paneIds() == [])
}

/// The other half of the same rule: `design-language.md` §13 requires that
/// panes are never torn down on a project switch and that their state stays
/// warm. Namespacing rather than clearing is what keeps both — the leak is
/// impossible AND coming back finds the project as it was left.
@Test func comingBackToAProjectFindsItsRowsWhereTheyWereLeft() async {
    let store = PaneStore()
    await store.switchScope(to: LayoutScope(organization: "acme", project: "alpha", environment: "dev"))
    await store.setRows(
        paneId: "db-1", columns: ["id"], columnTypes: [], columnTypesInferred: false,
        rows: [[.number(1)], [.number(2)]], millis: 0, truncated: false,
        pageable: true, offset: 0, sort: [], listsTables: false, editable: nil)
    await store.switchScope(to: LayoutScope(organization: "acme", project: "beta", environment: "dev"))
    await store.setRows(
        paneId: "db-1", columns: ["other"], columnTypes: [], columnTypesInferred: false,
        rows: [[.string("beta")]], millis: 0, truncated: false,
        pageable: true, offset: 0, sort: [], listsTables: false, editable: nil)
    await store.switchScope(to: LayoutScope(organization: "acme", project: "alpha", environment: "dev"))

    let snap = object(await store.readPane(paneId: "db-1", kind: "db"))
    #expect(snap["rowCount"] == .number(2))
    #expect(snap["columns"] == .array([.string("id")]))
}

/// A closed pane's rows went nowhere: they stayed in memory for the life of
/// the process — every result set an operator ever looked at — and were
/// waiting for whatever pane was next handed that id.
@Test func droppingAPaneForgetsEverythingItHeld() async {
    let store = PaneStore(kinds: PaneKinds.standard)
    await store.setRows(
        paneId: "db-1", columns: ["id"], columnTypes: [], columnTypesInferred: false,
        rows: [[.number(1)]], millis: 0, truncated: true,
        pageable: true, offset: 0, sort: [], listsTables: false, editable: nil)
    // `setSort` is gone (2c-ii): `reorder` is the store's own writer now.
    await store.reorder(paneId: "db-1", sort: [PaneSort(column: "id", direction: .descending)])
    await store.setScrollTarget(paneId: "db-1", row: 0)
    #expect(await store.paneIds() == ["db-1"])

    await store.drop(paneId: "db-1")
    #expect(await store.paneIds() == [])
    let snap = object(await store.readPane(paneId: "db-1", kind: "db"))
    #expect(snap["rowCount"] == .number(0))
    #expect(snap["sort"] == .array([]))
    #expect(snap["scrollTarget"] == .null)
}

/// Dropping one pane leaves its neighbours alone — closing a pane must not
/// blank the one beside it.
@Test func droppingOnePaneLeavesTheOthersAlone() async {
    let store = PaneStore()
    for id in ["db-1", "db-2"] {
        await store.setRows(
            paneId: id, columns: ["id"], columnTypes: [], columnTypesInferred: false,
            rows: [[.number(1)]], millis: 0, truncated: false,
            pageable: true, offset: 0, sort: [], listsTables: false, editable: nil)
    }
    await store.drop(paneId: "db-1")
    #expect(await store.paneIds() == ["db-2"])
}

// MARK: - Selection against a smaller result (final review Finding 8)

/// Preserving the selection across a `setRows` is deliberate and pinned by
/// `settingRowsDoesNotDisturbSelectionOrSort`. What it must not do is
/// preserve indices the new rows cannot carry: after a different query,
/// `read_pane` reported `anchorRow: 480` on a three-row result — a claim
/// about a row that does not exist, made to an LLM, with the surface
/// drawing a luminous edge on nothing.
@Test func aSelectionIsClampedToWhatTheNewRowsCanCarry() async {
    let store = PaneStore()
    await store.setRows(
        paneId: "db", columns: ["id"], columnTypes: [], columnTypesInferred: false,
        rows: (0..<500).map { [.number(Double($0))] }, millis: 0, truncated: false,
        pageable: true, offset: 0, sort: [], listsTables: false, editable: nil)
    await store.setSelection(paneId: "db", PaneSelection(
        anchorRow: 480, anchorColumn: "id", rows: [1, 480, 499]))
    await store.setScrollTarget(paneId: "db", row: 480)

    await store.setRows(
        paneId: "db", columns: ["id"], columnTypes: [], columnTypesInferred: false,
        rows: [[.number(7)], [.number(8)], [.number(9)]], millis: 0, truncated: false,
        pageable: true, offset: 0, sort: [], listsTables: false, editable: nil)

    let snap = object(await store.readPane(paneId: "db", kind: "db"))
    let selection = object(snap["selection"] ?? .null)
    // Row 1 is a row this result has, so it survives; 480 and 499 are not.
    #expect(selection["rows"] == .array([.number(1)]))
    // The anchor was out of range, so it moves to the smallest survivor
    // rather than being renumbered to some row nobody picked.
    #expect(selection["anchorRow"] == .number(1))
    #expect(snap["scrollTarget"] == .null)
}

/// Nothing survives a result that has no room for any of it, and the
/// answer is the empty selection rather than a half-filled one.
@Test func aSelectionWithNoSurvivingRowsBecomesEmpty() async {
    let store = PaneStore()
    await store.setSelection(paneId: "db", PaneSelection(
        anchorRow: 9, anchorColumn: "id", rows: [9]))
    await store.setRows(
        paneId: "db", columns: ["id"], columnTypes: [], columnTypesInferred: false,
        rows: [], millis: 0, truncated: false, pageable: true, offset: 0, sort: [], listsTables: false, editable: nil)
    let selection = object(object(await store.readPane(paneId: "db", kind: "db"))["selection"] ?? .null)
    #expect(selection["anchorRow"] == .null)
    #expect(selection["anchorColumn"] == .null)
    #expect(selection["rows"] == .array([]))
}

/// The preserve-on-refresh half, stated against a re-run of the same query:
/// every index still fits, so nothing is touched.
@Test func rerunningTheSameQueryKeepsTheWholeSelection() async {
    let store = PaneStore()
    let rows: [[JSONValue]] = [[.number(1)], [.number(2)], [.number(3)]]
    await store.setRows(
        paneId: "db", columns: ["id"], columnTypes: [], columnTypesInferred: false,
        rows: rows, millis: 0, truncated: false, pageable: true, offset: 0, sort: [], listsTables: false, editable: nil)
    await store.setSelection(paneId: "db", PaneSelection(
        anchorRow: 2, anchorColumn: "id", rows: [0, 2]))
    await store.setScrollTarget(paneId: "db", row: 2)
    await store.setRows(
        paneId: "db", columns: ["id"], columnTypes: [], columnTypesInferred: false,
        rows: rows, millis: 4, truncated: false, pageable: true, offset: 0, sort: [], listsTables: false, editable: nil)

    let snap = object(await store.readPane(paneId: "db", kind: "db"))
    let selection = object(snap["selection"] ?? .null)
    #expect(selection["anchorRow"] == .number(2))
    #expect(selection["anchorColumn"] == .string("id"))
    #expect(selection["rows"] == .array([.number(0), .number(2)]))
    #expect(snap["scrollTarget"] == .number(2))
}

@Test func rowsArriveOrderedByTheSortTheyWereGiven() async {
    let store = PaneStore()
    await store.setRows(
        paneId: "db-1", columns: ["id"], columnTypes: ["INTEGER"],
        columnTypesInferred: false,
        rows: [[.number(3)], [.number(1)], [.number(2)]],
        millis: 4, truncated: false, pageable: true, offset: 0,
        sort: [PaneSort(column: "id", direction: .ascending)], listsTables: false, editable: nil)
    let snap = object(await store.readPane(paneId: "db-1", kind: "db"))
    guard case .array(let rows)? = snap["rows"] else {
        Issue.record("no rows in the snapshot"); return
    }
    #expect(rows.count == 3)
    if case .array(let first) = rows[0], case .number(let n) = first[0] {
        #expect(n == 1)
    } else {
        Issue.record("first row is not 1")
    }
}

@Test func reorderingUsesTheUnsortedRowsSoASecondSortIsNotBuiltOnTheFirst() async {
    let store = PaneStore()
    await store.setRows(
        paneId: "db-1", columns: ["id", "kind"], columnTypes: ["INTEGER", "TEXT"],
        columnTypesInferred: false,
        rows: [[.number(3), .string("a")], [.number(1), .string("b")], [.number(2), .string("a")]],
        millis: 4, truncated: false, pageable: true, offset: 0, sort: [], listsTables: false, editable: nil)
    await store.reorder(paneId: "db-1", sort: [PaneSort(column: "kind", direction: .ascending)])
    await store.reorder(paneId: "db-1", sort: [PaneSort(column: "id", direction: .ascending)])
    let snap = object(await store.readPane(paneId: "db-1", kind: "db"))
    guard case .array(let rows)? = snap["rows"],
          case .array(let first) = rows[0], case .number(let n) = first[0] else {
        Issue.record("no rows"); return
    }
    // If the second sort had been applied to the OUTPUT of the first,
    // ties would be broken by the previous ordering rather than by the
    // database's. Sorting by a unique column makes the bug invisible, so
    // the check is that the result is the database's own order.
    #expect(n == 1)
}

/// D5, at the store: a two-term sort is ONE `reorder` call carrying both
/// terms, and the second term must actually break the first's ties rather
/// than being silently ignored. A test that only sorted by `kind` could
/// pass on a store that dropped every term but the first — the same
/// "small type" failure this whole task exists to close — so this pins
/// that `id` decides between the two `"a"` rows.
@Test func aTwoTermSortBreaksTiesWithTheSecondTerm() async {
    let store = PaneStore()
    await store.setRows(
        paneId: "db-1", columns: ["kind", "id"], columnTypes: ["TEXT", "INTEGER"],
        columnTypesInferred: false,
        rows: [
            [.string("a"), .number(3)], [.string("b"), .number(1)],
            [.string("a"), .number(2)],
        ],
        millis: 0, truncated: false, pageable: true, offset: 0, sort: [], listsTables: false, editable: nil)
    await store.reorder(paneId: "db-1", sort: [
        PaneSort(column: "kind", direction: .ascending),
        PaneSort(column: "id", direction: .ascending),
    ])
    let snap = object(await store.readPane(paneId: "db-1", kind: "db"))
    // Both "a" rows sort before "b" (primary term), and between them the
    // one with the smaller id comes first (the second term breaking the
    // tie the first left).
    #expect(snap["rows"] == .array([
        .array([.string("a"), .number(2)]),
        .array([.string("a"), .number(3)]),
        .array([.string("b"), .number(1)]),
    ]))
}

@Test func aSnapshotReportsWhetherItCanBePagedAndWhereItIs() async {
    let store = PaneStore()
    await store.setRows(
        paneId: "db-1", columns: ["id"], columnTypes: ["INTEGER"],
        columnTypesInferred: false, rows: [[.number(1)]],
        millis: 4, truncated: true, pageable: true, offset: 500, sort: [], listsTables: false, editable: nil)
    let snap = object(await store.readPane(paneId: "db-1", kind: "db"))
    #expect(snap["pageable"] == .bool(true))
    #expect(snap["offset"] == .number(500))
    // Every key always present, including when false or zero — the rule
    // `truncated` already established for this payload.
    #expect(snap["truncated"] == .bool(true))
}

@Test func anUnpageableResultSaysSoRatherThanOmittingTheKey() async {
    let store = PaneStore()
    await store.setRows(
        paneId: "db-1", columns: ["Tables_in_x"], columnTypes: ["VARCHAR"],
        columnTypesInferred: false, rows: [[.string("events")]],
        millis: 1, truncated: false, pageable: false, offset: 0, sort: [], listsTables: false, editable: nil)
    let snap = object(await store.readPane(paneId: "db-1", kind: "db"))
    #expect(snap["pageable"] == .bool(false))
    #expect(snap["offset"] == .number(0))
}

@Test func aNewResultStillLeavesTheSelectionAloneWhenItCanCarryIt() async {
    // Unchanged by this phase, re-pinned because setRows grew three
    // parameters and the rule it is famous for must survive them.
    let store = PaneStore()
    await store.setRows(
        paneId: "db-1", columns: ["id"], columnTypes: ["INTEGER"],
        columnTypesInferred: false,
        rows: [[.number(1)], [.number(2)], [.number(3)]],
        millis: 1, truncated: false, pageable: true, offset: 0, sort: [], listsTables: false, editable: nil)
    await store.setSelection(paneId: "db-1", PaneSelection(anchorRow: 2, anchorColumn: "id", rows: [2]))
    await store.setRows(
        paneId: "db-1", columns: ["id"], columnTypes: ["INTEGER"],
        columnTypesInferred: false,
        rows: [[.number(1)], [.number(2)], [.number(3)]],
        millis: 1, truncated: false, pageable: true, offset: 0, sort: [], listsTables: false, editable: nil)
    let snap = object(await store.readPane(paneId: "db-1", kind: "db"))
    guard case .object(let selection)? = snap["selection"] else {
        Issue.record("no selection"); return
    }
    #expect(selection["anchorRow"] == .number(2))
}

/// D12, the fifth cause of "rows returned, nothing on screen". A pane that
/// could not fetch and a pane that fetched nothing are different facts, and
/// before this they shared one empty `columns` array.
@Test func aFailureIsRememberedWithoutErasingTheLastGoodResult() async {
    let store = PaneStore()
    await store.setRows(
        paneId: "db-1", columns: ["id"], columnTypes: ["integer"],
        columnTypesInferred: false, rows: [[.number(1)]], millis: 3,
        truncated: false, pageable: true, offset: 0, sort: [], listsTables: false, editable: nil)

    await store.setFailure(paneId: "db-1", message: "no such database: docs")

    #expect(await store.failure(paneId: "db-1") == "no such database: docs")
    // The rows survive. A pane showing its last good result under a line
    // saying the refetch failed is honest; a pane blanked by a transient
    // failure has thrown away the only thing it knew.
    let snap = object(await store.readPane(paneId: "db-1", kind: "db"))
    guard case .array(let rows)? = snap["rows"] else {
        Issue.record("no rows"); return
    }
    #expect(rows == [.array([.number(1)])])
}

/// A result arriving IS the success signal — there is no path where rows
/// and a live failure are both true.
@Test func rowsClearAPreviousFailure() async {
    let store = PaneStore()
    await store.setFailure(paneId: "db-1", message: "connection refused")
    await store.setRows(
        paneId: "db-1", columns: ["id"], columnTypes: ["integer"],
        columnTypesInferred: false, rows: [[.number(1)]], millis: 3,
        truncated: false, pageable: true, offset: 0, sort: [], listsTables: false, editable: nil)
    #expect(await store.failure(paneId: "db-1") == nil)
}

/// Emitted unconditionally, for `pageable`'s reason: a reader — the agent
/// included — must not have to tell "did not fail" from "this build is too
/// old to say".
@Test func theSnapshotAlwaysCarriesFailure() async {
    let store = PaneStore()
    await store.setRows(
        paneId: "db-1", columns: ["id"], columnTypes: ["integer"],
        columnTypesInferred: false, rows: [], millis: 0,
        truncated: false, pageable: true, offset: 0, sort: [], listsTables: false, editable: nil)
    let snap = object(await store.readPane(paneId: "db-1", kind: "db"))
    #expect(snap["failure"] == .null)
}

// MARK: - Keys travel with their rows (Task 9)

/// The failure this exists against: a client-side sort reorders the rows,
/// and an unpermuted key array then names a DIFFERENT row than the one on
/// screen — so editing the top row would update whichever row happened to
/// be first before the sort.
@Test func sortingAPaneCarriesEachRowKeyWithItsRow() async {
    let panes = PaneStore()
    await panes.setRows(
        paneId: "db", columns: ["id", "kind"], columnTypes: ["INTEGER", "TEXT"],
        columnTypesInferred: false,
        rows: [[.integer(3), .string("c")], [.integer(1), .string("a")],
               [.integer(2), .string("b")]],
        millis: 1, truncated: false, pageable: true, offset: 0, sort: [], listsTables: false,
        editable: PaneEditable(
            table: "events", keyColumns: ["id"], columns: ["kind"],
            rowKeys: [#""id" = '3'"#, #""id" = '1'"#, #""id" = '2'"#]))

    await panes.reorder(paneId: "db", sort: [PaneSort(column: "id", direction: .ascending)])

    let editable = await panes.editable(paneId: "db")
    // Display order is now 1, 2, 3 — and so are the keys.
    #expect(editable?.rowKeys == [#""id" = '1'"#, #""id" = '2'"#, #""id" = '3'"#])
    #expect(editableCell(editable, column: "kind", row: 0) == #""id" = '1'"#)
}

/// read_pane feeds an LLM's context; five hundred WHERE fragments in it
/// buy the agent nothing it cannot see in the key column itself.
@Test func theSnapshotNamesTheTableButNotEveryRowKey() async {
    let panes = PaneStore()
    await panes.setRows(
        paneId: "db", columns: ["id", "kind"], columnTypes: ["INTEGER", "TEXT"],
        columnTypesInferred: false, rows: [[.integer(1), .string("a")]],
        millis: 1, truncated: false, pageable: true, offset: 0, sort: [], listsTables: false,
        editable: PaneEditable(
            table: "events", keyColumns: ["id"], columns: ["kind"],
            rowKeys: [#""id" = '1'"#]))
    let snapshot = object(await panes.readPane(paneId: "db", kind: "db"))
    guard case .object(let block)? = snapshot["editable"]
    else { return #expect(Bool(false), "expected an editable block") }
    #expect(block["table"] == .string("events"))
    #expect(block["columns"] == .array([.string("kind")]))
    #expect(block["rowKeys"] == nil)
}

// MARK: - The typed union (Decision 24)

@Test func aGridPanesSnapshotCarriesItsKindAndEveryKeyOfThatKind() async {
    let store = PaneStore()
    await store.setRows(
        paneId: "db-1", columns: ["id"], columnTypes: ["int"], columnTypesInferred: false,
        rows: [[.integer(1)]], millis: 3, truncated: false, pageable: true, offset: 0,
        sort: [], listsTables: false, editable: nil)

    let snapshot = await store.snapshot(paneId: "db-1", kind: "db")

    #expect(snapshot.kind == "db")
    guard let grid = snapshot.dataSurface else {
        Issue.record("expected a grid snapshot, got \(String(describing: snapshot.contents))")
        return
    }
    #expect(grid.rowCount == 1)
    // The always-present rule, now scoped to the kind: every key of THIS
    // kind is present in the wire form, including when false or empty.
    let wire = object(await store.readPane(paneId: "db-1", kind: "db"))
    for key in ["columns", "columnTypes", "columnTypesInferred", "rows", "rowCount",
                "millis", "truncated", "pageable", "offset", "selection", "sort",
                "scrollTarget", "listsTables", "kind", "failure"] {
        #expect(wire[key] != nil, "missing \(key)")
    }
}

@Test func anUnknownPaneIdAnswersWithANullKindRatherThanAnError() async {
    let store = PaneStore()

    let snapshot = await store.snapshot(paneId: "no-such-pane", kind: nil)

    #expect(snapshot.kind == nil)
    #expect(snapshot.contents == nil)
    // `kind` is present and null, not absent — an absent key is a thing a
    // reader has to know how to interpret; an explicit null is an answer.
    #expect(object(await store.readPane(paneId: "no-such-pane", kind: nil))["kind"] == .null)
}

@Test func anOpenPaneNothingHasWrittenToStillReportsItsKind() async {
    // The freshly launched window: a `db` pane drawing "no rows" before
    // any query. `read_pane("db-1")` on it must say "db", not null — the
    // pane exists, the layout knows it, and only its contents are empty.
    let store = PaneStore(kinds: PaneKinds.standard)

    let snapshot = await store.snapshot(paneId: "db-1", kind: "db")

    #expect(snapshot.kind == "db")
    guard let grid = snapshot.dataSurface else {
        Issue.record("expected an empty grid snapshot")
        return
    }
    #expect(grid.rowCount == 0)
}

// MARK: - The terminal kind's own always-present rule (final review, I3)

/// **Every key of the answered kind is present**, and for a terminal pane
/// that includes `backfilledAt`, which was declared on `TerminalSnapshot`
/// and never emitted at all — so the agent could not distinguish a replayed
/// mirror batch from a live one, which is the whole reason the backfill is
/// declared rather than silently performed.
@Test func aTerminalPaneAnswersWithEveryKeyOfItsKindIncludingTheBackfillMarker() async {
    let store = PaneStore()
    await store.setTerminalLiveState(
        paneId: "terminal-1", cwd: "/tmp", shell: "zsh", cols: 80, rows: 24,
        screen: .blocks, grid: ["$ "])

    let wire = object(await store.readPane(paneId: "terminal-1", kind: "terminal"))

    for key in ["screen", "cwd", "shell", "cols", "rows", "blocks", "blocksTruncated",
                "grid", "scrollTarget", "backfilledAt", "kind", "failure"] {
        #expect(wire[key] != nil, "missing \(key)")
    }
    // Never backfilled is an explicit null, not an absent key — the same
    // rule `scrollTarget` beside it follows.
    #expect(wire["backfilledAt"] == .null)
}

@Test func aBackfilledTerminalPaneReportsWhenItWasBackfilled() async {
    let store = PaneStore()
    let moment = Date(timeIntervalSince1970: 1_789_628_647.5)
    await store.setTerminalLiveState(
        paneId: "terminal-1", cwd: "/tmp", shell: "zsh", cols: 80, rows: 24,
        screen: .blocks, grid: [])
    await store.setTerminalBackfilledAt(paneId: "terminal-1", moment)

    let wire = object(await store.readPane(paneId: "terminal-1", kind: "terminal"))

    // ISO 8601, UTC, fractional seconds — a value an LLM can compare
    // against the prose around it, rather than an epoch number it has to
    // be told how to read.
    #expect(wire["backfilledAt"] == .string("2026-09-17T07:04:07.500Z"))
}

/// The contents half of the same rule. Two organisations each holding a
/// project called `core` used to share one set of pane contents, so
/// globex's `db-1` answered with acme's rows — a different credential
/// boundary's database (Invariant 4), on screen and in `read_pane` alike.
@Test func anotherOrganisationsPaneOfTheSameProjectAndNameIsEmpty() async {
    let store = PaneStore(kinds: PaneKinds.standard)
    await store.switchScope(to: LayoutScope(organization: "acme", project: "core", environment: "dev"))
    await store.setRows(
        paneId: "db-1", columns: ["secret"], columnTypes: ["TEXT"], columnTypesInferred: false,
        rows: [[.string("acme's production rows")]], millis: 3, truncated: true,
        pageable: true, offset: 0, sort: [], listsTables: false, editable: nil)

    await store.switchScope(to: LayoutScope(organization: "globex", project: "core", environment: "dev"))
    #expect(await store.paneIds() == [])
    let snap = object(await store.readPane(paneId: "db-1", kind: "db"))
    #expect(snap["rowCount"] == .number(0))

    await store.switchScope(to: LayoutScope(organization: "acme", project: "core", environment: "dev"))
    #expect(object(await store.readPane(paneId: "db-1", kind: "db"))["rowCount"] == .number(1))
}

/// #147: "Pane contents follow the arrangement, so a pane restored for one
/// conversation never shows another's rows."
///
/// Pane ids restart at `db-1` for every arrangement loaded off disk —
/// `LayoutStore.load` raises its counter only from the snapshot it is
/// loading — so two conversations in one project each hold a `db-1`, and
/// they are different panes against possibly different databases. The
/// scope carries the conversation, so this store answers each with its own
/// rows for the same reason it already does across projects and orgs.
@Test func anotherConversationsPaneOfTheSameNameIsEmpty() async {
    let store = PaneStore(kinds: PaneKinds.standard)
    let database = LayoutScope(organization: "acme", project: "core", environment: "dev", lineageRoot: "root-database")
    let tickets = LayoutScope(organization: "acme", project: "core", environment: "dev", lineageRoot: "root-tickets")

    await store.switchScope(to: database)
    await store.setRows(
        paneId: "db-1", columns: ["secret"], columnTypes: ["TEXT"], columnTypesInferred: false,
        rows: [[.string("the database conversation's rows")]], millis: 3, truncated: true,
        pageable: true, offset: 0, sort: [], listsTables: false, editable: nil)

    await store.switchScope(to: tickets)
    #expect(await store.paneIds() == [])
    #expect(object(await store.readPane(paneId: "db-1", kind: "db"))["rowCount"] == .number(0))

    // And the project's own arrangement is a third thing again, not either
    // conversation's — a brand-new conversation seeds FROM it, and must not
    // inherit rows that belonged to a conversation.
    await store.switchScope(to: LayoutScope(organization: "acme", project: "core", environment: "dev"))
    #expect(await store.paneIds() == [])

    await store.switchScope(to: database)
    #expect(object(await store.readPane(paneId: "db-1", kind: "db"))["rowCount"] == .number(1))
}
