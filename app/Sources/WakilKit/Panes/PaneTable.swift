import Foundation

/// One row of a data surface, identified by its position in the order
/// currently displayed.
public struct PaneRow: Sendable, Equatable, Identifiable {
    public let id: Int
    public let cells: [PaneCell]

    public init(id: Int, cells: [PaneCell]) {
        self.id = id
        self.cells = cells
    }
}

/// Everything a pane's data surface needs to draw itself, built from a
/// `DataSurfaceSnapshot` (`PaneTable.init(grid:)`). Until 2c-iii this was
/// projected out of `PaneStore.snapshot`'s JSON; the parse is gone, not
/// moved — `DataSurfaceSnapshot` is already typed, so there is no JSON shape here
/// to fail to recognise.
public struct PaneTable: Sendable, Equatable {
    public let columns: [PaneColumn]
    /// True when `columns`' types were worked out from the values rather
    /// than declared by the engine. The footer says so, because an
    /// annotation the operator cannot tell from a guess is worse than none.
    public let columnTypesInferred: Bool
    public let rows: [PaneRow]
    /// How long the query behind these rows took. §8's footer wants it, and
    /// `wakilcore.Rows` has carried it since Phase 1.
    public let millis: Int64
    /// True when the query behind these rows returned more than were kept.
    /// Drawn in the footer, because a human reading 500 rows has exactly the
    /// same way of being wrong about them as the agent reading `read_pane`.
    public let truncated: Bool
    public let selection: PaneSelection
    /// The pane's sort intent, in precedence order: index 0 is the
    /// primary key and later terms break its ties. An array rather than
    /// one optional term for the same reason `PaneFetch.sort` is (D5): a
    /// second header click means "and then by this".
    public let sort: [PaneSort]
    public let scrollTarget: Int?
    /// Whether this result can be asked for a second page —
    /// `wakilcore.Rows.Pageable`, carried through `PaneStore`.
    public let pageable: Bool
    /// How many rows were skipped to produce it.
    public let offset: Int
    /// Why the last fetch failed, or `nil`. Drawn in place of the rows —
    /// see `DBPane`. Never conflated with an empty result (D12).
    public var failure: String?
    /// Whether this result's rows name tables in the pane's own database —
    /// `wakilcore.Rows.ListsTables`, carried through `PaneStore`. True for a
    /// bare `SHOW TABLES` the operator typed; false for a `.columns` pane,
    /// which never produces a `Rows` at all.
    ///
    /// **True for a `.tables` pane too (final review, Minor 5) — this used
    /// to say `false` here, which the code has never actually done.**
    /// `db_list_tables` and `refetchPane`'s `.tables` case both pass `true`
    /// explicitly (`StandardActions.swift`), even though neither reads a
    /// `Rows` to get it from — `containerListPaneContents` reads a
    /// different result shape entirely. That makes `offersDrill`'s own
    /// `.tables`/`.columns` subject branch dead for `.tables` in
    /// production, since `offersDrill` checks `listsTables` first and a
    /// `.tables` pane always carries `true` by the time it gets there; the
    /// subject branch only still matters for `.columns`, which never sets
    /// this field. The value is harmless (the drill is offered either way)
    /// — only this comment, and its siblings on
    /// `PaneStore.DataSurfaceContents` and in
    /// `dbdriver.go`, claimed otherwise.
    public let listsTables: Bool
    /// When the read in flight started, or nil.
    public let runningSince: Date?
    /// How long the last read ran before it was cancelled, or nil.
    public let cancelledAfterMs: Int?

    public static let empty = PaneTable(
        columns: [], columnTypesInferred: false, rows: [], millis: 0, truncated: false,
        selection: .empty, sort: [], scrollTarget: nil, pageable: false, offset: 0,
        failure: nil, listsTables: false)

    public init(
        columns: [PaneColumn], columnTypesInferred: Bool, rows: [PaneRow], millis: Int64,
        truncated: Bool, selection: PaneSelection, sort: [PaneSort], scrollTarget: Int?,
        pageable: Bool, offset: Int, failure: String?, listsTables: Bool,
        runningSince: Date? = nil, cancelledAfterMs: Int? = nil
    ) {
        self.columns = columns
        self.columnTypesInferred = columnTypesInferred
        self.rows = rows
        self.millis = millis
        self.truncated = truncated
        self.selection = selection
        self.sort = sort
        self.scrollTarget = scrollTarget
        self.pageable = pageable
        self.offset = offset
        self.failure = failure
        self.listsTables = listsTables
        self.runningSince = runningSince
        self.cancelledAfterMs = cancelledAfterMs
    }

    /// "rows 501–1,000 · more remain", or `nil` when there is nothing
    /// useful to say.
    ///
    /// **Silent on page one of a complete result**, because "rows 1–6"
    /// beside "6 rows" is noise, and the footer's job is to carry facts a
    /// reader could otherwise get wrong. It speaks as soon as the rows on
    /// screen are a subset — which is the same condition every other piece
    /// of honesty in §8 turns on.
    ///
    /// **No total.** A total needs `SELECT count(*)` over the same
    /// statement — a second full scan on a large table, and one that can
    /// honestly disagree with the page beside it because the two ran at
    /// different instants. "more remain" is what `Truncated` knows for
    /// free, and §8's whole argument is that a data surface must not claim
    /// more than it knows.
    public var rowRangeDescription: String? {
        guard pageable, truncated || offset > 0, !rows.isEmpty else { return nil }
        let first = offset + 1
        let last = offset + rows.count
        let tail = truncated ? "more remain" : "end"
        return "rows \(Self.grouped(first))–\(Self.grouped(last)) · \(tail)"
    }

    /// A grouped decimal ("1,000"), formatted locally rather than through a
    /// shared static `NumberFormatter` — `PaneTable` is `Sendable`, and a
    /// `static let` `NumberFormatter` (a reference type Foundation does not
    /// mark `Sendable`) would be shared mutable state under Swift 6 strict
    /// concurrency. One short-lived formatter per call costs nothing a
    /// footer redraw would notice.
    private static func grouped(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: n)) ?? String(n)
    }

    /// The table a drill from `row` would open, or `nil` when this result
    /// is not a schema browse.
    ///
    /// **The subject decides, never the column names.** A query returning
    /// a column called `name` is not a table list, and offering to open
    /// row 3 of it would open a pane on a table that does not exist —
    /// which is the same class of inference 2c-i's walk refused when it
    /// ruled out parsing SQL to guess a table.
    ///
    /// **On `.columns` every row drills to the same place, and that is not
    /// a shortcut**: a column list has exactly one table, named by the
    /// subject, and each row is one of ITS columns — so the row decides
    /// nothing and the subject supplies the answer directly. The row is
    /// still bounds-checked, so a drill from a row that does not exist
    /// opens nothing, exactly as on a table list.
    public func drillTarget(row: Int, subject: PaneQuery?) -> String? {
        guard offersDrill(subject: subject, listsTables: listsTables) else { return nil }
        guard row >= 0, row < rows.count else { return nil }
        if case .columns(_, let table) = subject {
            return table.isEmpty ? nil : table
        }
        guard let first = rows[row].cells.first, !first.isNull, !first.text.isEmpty
        else { return nil }
        return first.text
    }
}

extension PaneTable {
    /// Projects a `DataSurfaceSnapshot` into a drawable table.
    ///
    /// **This replaced `paneTable(from: JSONValue)`**, which re-parsed the
    /// agent-facing JSON once per pane per change. The parse is gone, not
    /// moved: the store hands back a typed value, so there is no shape
    /// this can fail to recognise and no silently empty pane to produce.
    public init(dataSurface grid: DataSurfaceSnapshot) {
        self.init(
            columns: zip(grid.columns, grid.columnTypes + Array(
                repeating: "", count: max(0, grid.columns.count - grid.columnTypes.count)))
                .map { PaneColumn(name: $0.0, type: $0.1) },
            columnTypesInferred: grid.columnTypesInferred,
            rows: grid.rows.enumerated().map { PaneRow(id: $0.offset, cells: $0.element.map(PaneCell.init)) },
            millis: grid.millis,
            truncated: grid.truncated,
            selection: grid.selection,
            sort: grid.sort,
            scrollTarget: grid.scrollTarget,
            pageable: grid.pageable,
            offset: grid.offset,
            failure: nil,
            listsTables: grid.listsTables,
            runningSince: grid.runningSince, cancelledAfterMs: grid.cancelledAfterMs)
    }
}

// MARK: - Width and accessibility for the pane's rows

/// The narrowest a data surface column may be drawn, in points.
///
/// One constant, named once, because three separate things floor on it and
/// a drift between any two of them is a column that cannot be read:
/// `paneColumnWidth` and `paneColumnLayout` floor the widths they compute,
/// and `paneColumnWidthAfterDrag` floors what a header-edge drag commits —
/// so an operator cannot drag a column narrower than the arithmetic would
/// ever draw it.
public let paneColumnMinimumWidth: Double = 60

/// The width a header-edge drag commits, given the column's width when the
/// drag began and how far the pointer has moved.
///
/// **Used for the live preview and for the commit alike**, so the width the
/// operator watches and the width that reaches `pane_set_column_width`
/// cannot be two different numbers — a drag that stopped at the floor while
/// the pointer kept going would otherwise commit whatever the pointer said.
///
/// The dispatch happens **once, on release**, not per frame, matching how
/// pane resize already commits: `LayoutActions`' commit-granularity comment
/// has the reasoning — a 400-frame drag that dispatched per frame is either
/// an unreadable journal or an `await` on the frame path, and §7's 8.33ms
/// budget does not survive the latter.
public func paneColumnWidthAfterDrag(startWidth: Double, translation: Double) -> Double {
    max(paneColumnMinimumWidth, startWidth + translation)
}

/// The maximum width one column of the pane's `Grid` may take, given how
/// much horizontal space is actually available.
///
/// Extracted from `WakilWindow` so it is a plain, testable function rather
/// than logic buried in a SwiftUI body: `WakilApp` has no test target of
/// its own (see `WakilWindow`'s doc comment), so anything that can be
/// framed as arithmetic belongs here instead, where `WakilKitTests` can
/// hold it to a contract.
///
/// **Why this exists at all.** `Grid`, unlike `Table`, does not size its
/// own columns to the space it is given — a cell with no width constraint
/// grows to fit its content, so one long value stretches its whole column
/// (and the row after it) past the edge of whatever is showing it, with no
/// way to reach the rest of that value. Capping every column at an equal
/// share of the available width, and truncating what does not fit (the
/// view applies `.lineLimit(1)` and `.help(_:)` with the cap this returns),
/// is what keeps a single wide cell from doing that.
///
/// Floored at `minimum` rather than allowed to reach zero or negative — a
/// pane with enough columns to starve each one below a legible width still
/// draws *something* legible per column, at the cost of the row overall no
/// longer fitting `availableWidth`. That trade only applies to a column
/// count nothing here has been asked to handle (2b-i and 2c's data surface
/// both draw a handful of columns); a single long value never triggers it,
/// which is the case this function exists for.
public func paneColumnWidth(
    availableWidth: Double, columnCount: Int, horizontalSpacing: Double,
    minimum: Double = paneColumnMinimumWidth
) -> Double {
    guard columnCount > 0, availableWidth > 0 else { return minimum }
    let totalSpacing = horizontalSpacing * Double(max(0, columnCount - 1))
    return max(minimum, (availableWidth - totalSpacing) / Double(columnCount))
}

/// The horizontal offset a data surface's column header must draw at,
/// given where the row content's leading edge is and where the surface's
/// own leading edge is — both measured in the **same** coordinate space.
///
/// **Why it is a difference and not a latch** (final review Finding 4).
/// §2.1 forbids a pinned `Section` header, because a `Section` under-reports
/// the scroll view's document height by 2.8% — a scrollbar thumb of the
/// wrong size and a `pane_scroll_to_row` that lands in the wrong place. So
/// the header is drawn above the `ScrollView`, in a different scroll
/// context from the rows, and their horizontal offset is shared by hand.
/// The first version of that shared it by reporting the content's `.global`
/// leading edge and subtracting an origin latched from the first report.
/// `.global` moves for reasons that are not scrolling: `Canvas` positions a
/// pane with `.offset(x: pane.frame.x + drag)`, so dragging a pane 200pt
/// right moved the content's global origin 200pt with no horizontal scroll
/// at all — and because the subtrahend was latched, the header drew 200pt
/// off its columns and stayed there. Values under the wrong column name is
/// the exact failure §8's data surface exists to prevent.
///
/// A difference of two edges in one space cannot have that fault: moving
/// the pane moves both by the same amount and cancels, and only a scroll
/// moves one without the other. There is nothing latched to go stale.
///
/// **Clamped at zero.** The rows are leading-aligned inside the scroll
/// view, so their leading edge can sit level with the surface's or left of
/// it, never right of it. A positive difference is therefore a measurement
/// taken mid-layout rather than a real position, and drawing the header
/// right of its columns on the strength of one is the failure this function
/// exists to prevent, in a smaller place.
///
/// `nil` before the first measurement arrives, which draws the header where
/// an unscrolled surface wants it.
///
/// It lives here rather than in `DataSurface` for the same reason
/// `paneColumnLayout` does: `WakilApp` has no test target, so anything that
/// can be framed as arithmetic belongs where `WakilKitTests` can hold it to
/// a contract.
public func paneHeaderOffset(contentLeadingEdge: Double?, surfaceLeadingEdge: Double) -> Double {
    guard let contentLeadingEdge else { return 0 }
    return min(0, contentLeadingEdge - surfaceLeadingEdge)
}

/// A row's background opacity, given whether it is selected and whether
/// the pointer is currently over it — the arithmetic behind `DataSurface`'s
/// `rowBackground`, extracted here for the same reason `paneColumnWidthAfterDrag`
/// above is: `WakilApp` has no test target, so a decision that can be
/// framed as arithmetic on two booleans belongs where `WakilKitTests` can
/// hold it to a contract instead of living untested in a SwiftUI body.
///
/// **Ordered weakest to strongest: hover alone < selection alone < both.**
/// `design-language.md` §8 permits exactly one LUMINOUS element inside a
/// data surface — the anchor row's left edge, drawn separately by
/// `DataSurface` — so hover and selection both have to be made out of a
/// flat, non-luminous lifted background instead (§8's own phrase for the
/// selected-row treatment). Hover has to read as visibly weaker than
/// selection ("you are here" vs. "this is chosen"), which is why it is not
/// simply reused at the same strength, and a row that is both selected and
/// hovered has to read as visibly MORE than either alone or the two states
/// collapse into one look — which is why "both" is not just "selected".
public func paneRowBackgroundOpacity(selected: Bool, hovered: Bool) -> Double {
    switch (selected, hovered) {
    case (true, true): return 0.09
    case (true, false): return 0.06
    case (false, true): return 0.03
    case (false, false): return 0
    }
}

/// The width of the leading gutter a data surface's row grip sits in (spec Amendment 5).
///
/// **A gutter of its own, never an overlay on a cell.** The operator rejected the spike's
/// grip — a solid bar laid over the first column — on sight; a grip drawn over a cell hides
/// the start of a value and competes with the cell for the pointer. So every row, and the
/// header row with it, reserves this much before its first column, and the columns are laid
/// out in what is left (`paneColumnsWidth`).
public let paneGripGutter: Double = 14

/// The width of the trailing gutter a data surface's hover actions sit in: the row's ⓘ, 20 pt
/// in from the edge so an overlay scroller does not cover it.
///
/// **The grip's rule, on the other edge.** Drawn over the last column, the ⓘ hid the end of a
/// value and sat on top of its text (operator, 2c-ii-c walk); reserved here, the columns end
/// before it and it never covers a cell.
public let paneRowActionGutter: Double = 36

/// The width a data surface's columns are laid out in: the row's, less the grip's gutter and
/// the hover actions' gutter.
///
/// **Taken off before `paneColumnLayout` divides the width, not after**, so the columns
/// plus the gutter still sum to the row viewport exactly — the same arithmetic D1 fixed for
/// the scroller (`paneContentWidth`). Floored the way `paneContentWidth` is, so a pane
/// narrower than a gutter and one column still lays out a column.
public func paneColumnsWidth(rowWidth: Double) -> Double {
    max(paneColumnMinimumWidth, rowWidth - paneGripGutter - paneRowActionGutter)
}

/// The grip's ink opacity, given whether the pointer is over its row.
///
/// **Dim at rest, and never hidden.** Drawn only on hover, the grip would be missing from
/// the accessibility tree for every row the pointer is not over — Task 1 measured that the
/// e2e resolves it by identifier — and an operator could not find a control that only
/// appears once they are already on it. Rising under the pointer is what says it is the
/// thing to pick up.
public func paneGripOpacity(hovered: Bool) -> Double {
    hovered ? 0.55 : 0.30
}

/// How far inside a row's full height an editable cell's hover outline is
/// drawn, given that row's height — the arithmetic behind `DataSurface`'s
/// `editHoverOutline`, extracted here for the same reason
/// `paneRowBackgroundOpacity` above is.
///
/// **The outline is a field, not a slab.** A border run flush to the row's
/// full height reads as a filled band the row already owns, which is the
/// treatment the operator rejected; inset, it reads as what it is — the
/// text field that will appear in that exact place on a double-click. So
/// the outline aims at a constant height (`editHoverOutlineHeight`) rather
/// than at a constant inset: the affordance has to look the same at both
/// densities, and the two row heights differ by nearly a factor of two.
///
/// Dense rows are shorter than that target, so the inset floors at a hair
/// rather than going negative — an outline drawn OUTSIDE its own row would
/// overlap its neighbours and the row above would appear to be editable
/// too.
public let editHoverOutlineHeight: Double = 24

public func paneEditHoverInset(rowHeight: Double) -> Double {
    max(2, (rowHeight - editHoverOutlineHeight) / 2)
}

/// The footer's row-count segment — 2c-ii-b walk defect D4.
///
/// `"\(count) rows"` read `1 rows` for the CTE check's single row, which is
/// the kind of thing a walk catches and a test suite never will: nothing was
/// wrong, it just did not read like the rest of the surface does. The zero
/// case stays plural, which is the English rule and not an oversight.
public func paneRowCountLabel(_ count: Int) -> String {
    "\(count) \(count == 1 ? "row" : "rows")"
}

/// How much of a data surface's own width the rows may actually occupy.
///
/// **The surface is wider than the viewport its rows are laid out in, and
/// the difference is a scrollbar** — 2c-ii-b walk defect D1. `DataSurface`
/// measures itself with a `GeometryReader` and hands that width to
/// `paneColumnLayout` below, which divides it so the columns plus their
/// spacing sum to *exactly* it; the rows are then pinned to the same number
/// by `.frame(minWidth:)`. That is correct arithmetic against the wrong
/// number. The rows live inside a two-axis `ScrollView`, and under macOS's
/// **legacy** scroller style the vertical scroller is not an overlay — it
/// takes layout width out of the document's visible rect. So the content
/// came out exactly one scroller wider than the space it had, and a pane
/// showing three columns in 700pt scrolled sideways by 15pt.
///
/// The walk caught it as a correlation no test would have: a pane with one
/// row had no scrollbars at all, and the *same two columns* with 500 rows
/// had a horizontal one. Nothing about the columns changed between those
/// two panes — only whether the vertical scroller existed.
///
/// **The allowance is subtracted whether or not the scroller is currently
/// showing**, which is the deliberate half of this. Predicting visibility
/// means knowing the rows' total height against a viewport height this
/// function cannot see, and getting it wrong the other way re-opens the
/// defect. Always reserving it costs a short result `allowance` points of
/// unused width to the right of its last column — invisible, because §8's
/// surface draws no rule and no fill there — and it means the layout does
/// not jump when a result crosses the height at which the scroller appears.
///
/// Under the **overlay** style (a trackpad-only machine, where the scroller
/// floats above the content and takes no width) the caller passes 0 and
/// this is the identity.
public func paneContentWidth(surfaceWidth: Double, verticalScrollerAllowance: Double) -> Double {
    max(paneColumnMinimumWidth, surfaceWidth - max(0, verticalScrollerAllowance))
}

/// Each column's width, in order, given which ones the operator has
/// resized.
///
/// Overridden columns keep exactly what they were dragged to; the rest
/// divide whatever horizontal space is left, floored by `paneColumnWidth`'s
/// own minimum. The two rules do not compete: the division is what shares
/// the width fairly when the columns fit, and the floor plus the surface's
/// horizontal `ScrollView` is what happens when they cannot.
///
/// **`availableWidth` is the ROW viewport's width, not the surface's** —
/// see `paneContentWidth` above, and 2c-ii-b walk defect D1 for what
/// passing the latter costs.
public func paneColumnLayout(
    columns: [String], overrides: [String: Double], availableWidth: Double,
    horizontalSpacing: Double, minimum: Double = paneColumnMinimumWidth
) -> [Double] {
    guard !columns.isEmpty else { return [] }
    let spacing = horizontalSpacing * Double(columns.count - 1)
    let overridden = columns.filter { overrides[$0] != nil }
    let overriddenTotal = overridden.reduce(0.0) { $0 + (overrides[$1] ?? 0) }
    let free = columns.count - overridden.count
    let remaining = availableWidth - spacing - overriddenTotal
    let each = free > 0 ? max(minimum, remaining / Double(free)) : 0
    return columns.map { overrides[$0] ?? each }
}

/// Whether a pane row, drawn with every column at `paneColumnWidth`, is
/// wider than the space actually available for it.
///
/// **Why this exists at all — Task 10's fix round found a second cause of
/// the same original defect (Finding 1), not a corner case of the first
/// fix.** `paneColumnWidth`'s floor (`minimum`, 60pt by default) is what
/// keeps a column from shrinking into illegibility, but once there are
/// enough columns that even every column sitting at the floor still adds
/// up to more than `availableWidth`, the row overflows regardless of how
/// well the cap divided the space — truncation inside each cell does not
/// help a row that is too wide *in total*. `select *` against a table
/// with twenty-odd columns is an ordinary query, not a corner case, so
/// this is reachable well before 2c's real database surface is exercised
/// hard. This function is what makes that condition a fact
/// `WakilKitTests` can assert, instead of something left implicit in
/// `WakilWindow`'s choice to make its `ScrollView` scroll horizontally as
/// well as vertically — which is the fix: the escape hatch for exactly
/// the case this returns `true` for, since a floored column cannot shrink
/// any further and truncation has already done everything it can.
/// **`internal`, not `public`** (final review Finding 7a, 2026-09-09):
/// nothing outside this module calls it — `WakilWindow`'s horizontal
/// `ScrollView` decision is made elsewhere — and its only callers are its
/// own two tests in `WindowModelTests`, which reach it through
/// `@testable import WakilKit`.
func paneRowOverflowsAvailableWidth(
    availableWidth: Double, columnCount: Int, horizontalSpacing: Double,
    minimum: Double = paneColumnMinimumWidth
) -> Bool {
    guard columnCount > 0 else { return false }
    let totalSpacing = horizontalSpacing * Double(max(0, columnCount - 1))
    let columnWidth = paneColumnWidth(
        availableWidth: availableWidth, columnCount: columnCount,
        horizontalSpacing: horizontalSpacing, minimum: minimum)
    return columnWidth * Double(columnCount) + totalSpacing > availableWidth
}

/// The row-level VoiceOver label for one pane row: every column paired with
/// its value, in column order.
///
/// **Why this exists at all.** `Table`'s `NSTableView` backing gave
/// VoiceOver real row and column enumeration for free; `Grid` of `Text`
/// views gives it nothing. `WakilWindow` hands this to a row's
/// `.accessibilityLabel` (with the row's own cells hidden from the
/// accessibility tree via `.accessibilityElement(children: .ignore)`) so a
/// screen reader announces one row as one coherent thing — "id: 1, name:
/// widgets" — rather than a sequence of unlabelled text fragments. This is
/// not `NSTableView`'s full semantics: there is no per-cell row/column
/// position announced the way AppKit's real table gives it, and no
/// column-by-column navigation. It is what stops the pane from being an
/// undifferentiated pile of text, not a replacement for what was lost.
///
/// A cell shorter than `columns` — the same case `WakilWindow` draws as
/// `""` — reads as "empty" rather than as a blank that would vanish
/// between two commas and read as one missing word instead of a value.
public func paneRowAccessibilityLabel(columns: [String], row: PaneRow) -> String {
    columns.indices.map { index in
        let value = index < row.cells.count ? row.cells[index].text : ""
        return "\(columns[index]): \(value.isEmpty ? "empty" : value)"
    }.joined(separator: ", ")
}
