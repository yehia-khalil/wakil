import Foundation

/// One cell of a data surface: the single line of text it shows, and
/// whether the value behind it was JSON `null`.
///
/// **`isNull` is the reason this type exists.** Until 2c-i the projection
/// rendered `null` as the empty string, which made a real database NULL and
/// an empty string identical on screen — the exact confusion
/// `design-language.md` §8's "explicit null rendering" exists to prevent.
/// The text alone cannot carry the distinction, because both are empty; the
/// flag can.
public struct PaneCell: Sendable, Equatable {
    public let text: String
    public let isNull: Bool
    /// The value this cell was built from. `text` is its display form and loses types — a
    /// number and a numeric string draw alike — so anything that must keep them (Copy as JSON,
    /// the row detail strip) reads this.
    public let value: JSONValue

    public init(_ value: JSONValue) {
        self.value = value
        switch value {
        case .null:
            text = ""
            isNull = true
        case .bool(let flag):
            text = flag ? "true" : "false"
            isNull = false
        case .integer(let i):
            // No bound and no fallback, unlike the `.number` branch below:
            // that one guards at 1e15 because a Double cannot be trusted
            // past it, and an Int64 can be trusted everywhere. A database
            // key of 9007199254740993 used to draw as
            // "9.007199254740992e+15" — wrong digits, unreadable format —
            // because it had been a Double since it left the driver.
            text = String(i)
            isNull = false
        case .number(let number):
            // The `< 1e15` bound is where a Double stops being able to
            // represent every integer exactly; past it, printing an Int64
            // conversion would assert precision the value does not have.
            if number == number.rounded(), abs(number) < 1e15 {
                text = String(Int64(number))
            } else {
                text = String(number)
            }
            isNull = false
        case .string(let value):
            text = value
            isNull = false
        case .array, .object:
            if let data = try? JSONEncoder().encode(value),
               let encoded = String(data: data, encoding: .utf8) {
                text = encoded
            } else {
                text = ""
            }
            isNull = false
        }
    }
}

/// One column of a data surface: its name, and the database's own name for
/// its type when there is one.
///
/// `type` is `nil` rather than `""` when the driver could not say, so that
/// a view cannot draw an empty annotation and have it read as an
/// annotation. The conversion happens here, once, rather than at each of
/// the several places that will ask.
public struct PaneColumn: Sendable, Equatable {
    public let name: String
    public let type: String?

    public init(name: String, type: String?) {
        self.name = name
        self.type = (type?.isEmpty ?? true) ? nil : type
    }
}

/// Which way a sort runs. The raw values are the wire names an action
/// parameter and `read_pane` both use.
public enum PaneSortDirection: String, Sendable, Equatable, Codable, CaseIterable {
    case ascending = "asc"
    case descending = "desc"
}

/// A pane's current sort *intent* — which column, which way.
///
/// Intent, not result: the grid never sorts. It records this, and the
/// pane's owner decides how to honour it (spec §6). A pane that can
/// re-query re-queries; one that cannot sorts the rows it holds and says
/// so in its footer.
///
/// **`Codable`, so `PaneFetch` — which persists with the layout — can
/// encode a pane's sort intent.** Added for 2c-ii; nothing about the
/// type's own meaning changes.
public struct PaneSort: Sendable, Equatable, Codable {
    public let column: String
    public let direction: PaneSortDirection

    public init(column: String, direction: PaneSortDirection) {
        self.column = column
        self.direction = direction
    }
}

/// Orders `rows` by `sort`, given the pane's column names.
///
/// **This is the only place rows are ordered, and it is called where the
/// rows are stored rather than where they are drawn** (final review
/// Finding 1, 2026-09-12). It used to live beside `paneTable(from:)` in
/// the window layer and be applied only to the view's projection, while
/// `PaneStore.snapshot` — which is what `read_pane` hands the agent —
/// emitted rows exactly as they were written. `read_pane`'s own
/// description promises every index is an index into the order currently
/// DISPLAYED, and `selection.rows` and `scrollTarget` do index that order;
/// so after a `pane_sort` the agent read rows in insertion order, said
/// "select row 0", and the operator's luminous edge landed on a row the
/// agent did not mean. Producing the displayed order once, at the store,
/// is what makes the two readers see the same thing.
///
/// **This is the client-side branch of spec §6, and it is not the whole
/// answer.** A pane that can re-query should re-query with an `ORDER BY`,
/// because sorting 500 rows of a 50,000-row table orders what is on screen
/// and *looks* like it ordered the table — the same class of dishonesty
/// `truncated` exists to prevent, one layer up. 2c-i had no re-querying
/// owner yet; `DataSurface`'s footer says "sorted within the N returned"
/// whenever the result is truncated.
///
/// **2c-ii ADDS the other branch and keeps this one** (spec §7 and §11).
/// `pane_sort`'s handler is what chooses between them: an incomplete
/// result — truncated, or a page past the first — re-queries with a pushed
/// `ORDER BY`, and everything else is ordered here. This is not dead code
/// and is not a fallback: when every row that matches is already in hand,
/// ordering them locally produces exactly what the engine would return,
/// without a round trip, and an unpageable result has no other answer
/// available at all.
///
/// On an untruncated result this *is* correct and is the right answer.
///
/// Every row index in this codebase — `read_pane`'s, `pane_select_cell`'s,
/// `pane_scroll_to_row`'s — indexes what is *displayed*, and a row's index
/// here is simply its position in what this returns. So a selection made
/// before the sort now points at whatever row lands on that index
/// afterward; that is intended, not a gap — after re-sorting, row 4 *is* a
/// different row.
///
/// **`sort` is a list, in precedence order (D5).** Index 0 is the primary
/// term; a later term only decides anything between two rows the earlier
/// terms called equal. A column named that the pane does not have is
/// dropped rather than thrown on — the same "not an error" the empty case
/// already was — so an unknown term simply does not participate and the
/// terms after it still can.
///
/// **The sort key for every term is built once per row, not once per
/// comparison.** `PaneCell` encodes an array or object value to JSON text
/// in order to render it, and a comparison sort would pay that
/// O(n log n) times where keying up front pays it O(n).
///
/// The order `rows` should be displayed in, as indices into `rows`.
///
/// **Indices rather than reordered rows, because rows are not the only
/// thing that has to move.** A pane's `rowKeys` are positionally aligned
/// with its rows, and an ordering applied to one but not the other pairs
/// every key with the wrong row — which would make editing the top row
/// update whichever row happened to be first before the sort. One
/// permutation, computed once, applied to everything aligned with a row.
///
/// Every rule `sortedRows` documents holds unchanged: nulls last in both
/// directions, numeric comparison for two numbers, `localizedStandardCompare`
/// otherwise, sort keys built once per row, and a term naming an unknown
/// column dropped rather than thrown on.
public func sortedRowOrder(
    _ rows: [[JSONValue]], by sort: [PaneSort], columns: [String]
) -> [Int] {
    let terms = sort.compactMap { term -> (index: Int, direction: PaneSortDirection)? in
        guard let index = columns.firstIndex(of: term.column) else { return nil }
        return (index, term.direction)
    }
    guard !terms.isEmpty else { return Array(rows.indices) }

    // -1 when `l` sorts before `r` under `direction`, 1 when after, 0 when
    // the two cells are equal — the tri-state a single term needs so a
    // later term can decide what an earlier one called a tie. Four rules,
    // in order: nulls last in both directions; two exact integers compare
    // as integers, so a pair that ties as `Double` past 2^53 still orders
    // correctly; two finite numbers otherwise compare numerically; and
    // everything else falls to `localizedStandardCompare`.
    func compare(_ l: PaneCell, _ r: PaneCell, direction: PaneSortDirection) -> Int {
        if l.isNull != r.isNull { return l.isNull ? 1 : -1 }
        if l.isNull && r.isNull { return 0 }
        // Two exact integers compare as integers. Parsing both into Double
        // first would tie 9007199254740992 and ...993, which is the defect
        // the `.integer` case was added to remove, surviving one layer
        // down where no visible symptom would point at it.
        if let li = Int64(l.text), let ri = Int64(r.text) {
            if li == ri { return 0 }
            let ascending = li < ri
            return (direction == .ascending) == ascending ? -1 : 1
        }
        // `isFinite` (excluding NaN and the infinities) is load-bearing,
        // not decorative: `Double("nan")` parses successfully in Swift, and
        // IEEE 754 defines every comparison against NaN — `<`, `>`, `==`
        // alike — as `false`. Without the guard, a text column holding the
        // literal string "nan" would take the numeric branch and compare
        // `false` against everything in both directions, making it appear
        // "equivalent" to every other value while those values are not
        // equivalent to each other — a strict-weak-ordering violation
        // `sorted` does not promise well-defined behaviour under. Falling
        // through to the text comparison for non-finite values keeps the
        // ordering total.
        if let ln = Double(l.text), let rn = Double(r.text), ln.isFinite, rn.isFinite, ln != rn {
            let ascending = ln < rn ? -1 : 1
            return direction == .ascending ? ascending : -ascending
        }
        let comparison = l.text.localizedStandardCompare(r.text)
        guard comparison != .orderedSame else { return 0 }
        let ascending = comparison == .orderedAscending ? -1 : 1
        return direction == .ascending ? ascending : -ascending
    }

    let keyed = rows.enumerated().map { index, row -> (keys: [PaneCell], index: Int) in
        (terms.map { term in
            term.index < row.count ? PaneCell(row[term.index]) : PaneCell(.null)
        }, index)
    }
    let ordered = keyed.sorted { left, right in
        for (position, term) in terms.enumerated() {
            let result = compare(left.keys[position], right.keys[position], direction: term.direction)
            if result != 0 { return result < 0 }
        }
        // Every term tied — `sorted` is stable (SE-0372: the standard
        // library's doc comment guarantees it, as of Swift 5.8), so
        // leaving this `false` keeps rows that tie on every term in
        // whatever order they already were, rather than reshuffling them.
        return false
    }
    return ordered.map(\.index)
}

/// Orders `rows` by `sort`, given the pane's column names.
///
/// A one-line wrapper over `sortedRowOrder`, kept as its own entry point
/// so every existing caller and test — none of which need the permutation
/// itself — is untouched by `rowKeys` needing it.
public func sortedRows(
    _ rows: [[JSONValue]], by sort: [PaneSort], columns: [String]
) -> [[JSONValue]] {
    sortedRowOrder(rows, by: sort, columns: columns).map { rows[$0] }
}

/// What is selected in a pane: an anchor cell, and the set of rows.
///
/// **Two things and not one.** The anchor is a (row, column) pair because
/// `design-language.md` §11 has the API client pane consuming *values* from
/// other panes, and a value lives in a cell rather than a row. The row set
/// is what copy — and, in 2c-ii, a multi-row delete — operates on.
///
/// The anchor's row is always a member of `rows`. §8 draws its luminous
/// left edge on the anchor's row, and an anchor outside the selection would
/// put that edge on a row the selection says is not selected.
///
/// Multi-row selection is here in 2c-i rather than deferred because this
/// shape is published — it is in `read_pane`'s payload and in the schemas
/// of `pane_select_cell` and `pane_select_rows`, both of which an agent
/// reads. Widening it later changes a contract, not a data structure.
public struct PaneSelection: Sendable, Equatable {
    public let anchorRow: Int?
    public let anchorColumn: String?
    public let rows: Set<Int>

    public static let empty = PaneSelection(anchorRow: nil, anchorColumn: nil, rows: [])

    public init(anchorRow: Int?, anchorColumn: String?, rows: Set<Int>) {
        self.anchorRow = anchorRow
        self.anchorColumn = anchorColumn
        if let anchorRow {
            self.rows = rows.union([anchorRow])
        } else {
            self.rows = rows
        }
    }
}

/// Which kind of click drove `paneSelectionAfterClick`. AppKit-free on
/// purpose — the view reads `NSEvent.modifierFlags` and narrows to one of
/// these, so this function (and its tests) never need AppKit.
public enum PaneClickModifier: Sendable, Equatable {
    case plain, shift, command
}

/// The selection that results from clicking one cell, given the selection
/// that existed before the click.
///
/// **Why this is here, in `WakilKit`, and not in `DataSurface`'s own
/// `select(row:column:)`.** The first version of that method computed the
/// command-click branch's new anchor as the row just removed —
/// `PaneSelection.init` then unconditionally unioned that row straight back
/// into `rows`, so a deselect was undone the instant it landed and
/// command-click could only ever add rows. It sat in the view, untested,
/// which is exactly what this task's own split rule (`paneColumnLayout`
/// belongs here, not in the view, because `WakilApp` has no test target)
/// exists to prevent. This function is free of `AppKit` — the view reads
/// `NSEvent.modifierFlags`, narrows to a `PaneClickModifier`, and calls
/// this — so it is exactly as testable as `paneColumnLayout`.
public func paneSelectionAfterClick(
    current: PaneSelection, row: Int, column: String, modifier: PaneClickModifier
) -> PaneSelection {
    switch modifier {
    case .plain:
        // A plain click starts a new selection: anchor at the clicked
        // cell, collapsed to just its row.
        return PaneSelection(anchorRow: row, anchorColumn: column, rows: [row])
    case .shift:
        // Extends from the existing anchor to the clicked row, inclusive;
        // the anchor itself does not move. With no anchor there is nothing
        // to extend from, so this degrades to a plain click.
        guard let anchor = current.anchorRow else {
            return paneSelectionAfterClick(current: current, row: row, column: column, modifier: .plain)
        }
        let span = Set(min(anchor, row)...max(anchor, row))
        return PaneSelection(anchorRow: anchor, anchorColumn: column, rows: span)
    case .command:
        var rows = current.rows
        if rows.contains(row) {
            rows.remove(row)
            guard !rows.isEmpty else {
                // The last row went with it — no survivor to anchor on.
                return PaneSelection(anchorRow: nil, anchorColumn: column, rows: [])
            }
            // The anchor only needs to move when the row just removed WAS
            // the anchor: any other existing anchor is still a member of
            // `rows` and stays exactly where the operator left it. When it
            // does need to move, `rows.min()` — the smallest surviving row
            // index — is what it moves to: `rows` is an unordered `Set`
            // here, so "the nearest row below the one removed" has no
            // cheaper a definition than "the smallest index that
            // survived", and `min()` is simpler to compute and to test.
            let anchor = current.anchorRow == row ? rows.min() : current.anchorRow
            return PaneSelection(anchorRow: anchor, anchorColumn: column, rows: rows)
        } else {
            // Not yet selected: command-click adds it and makes it the
            // anchor, the same as a fresh selection would.
            rows.insert(row)
            return PaneSelection(anchorRow: row, anchorColumn: column, rows: rows)
        }
    }
}
