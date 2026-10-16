import AppKit
import WakilKit
import SwiftUI
import UniformTypeIdentifiers

/// `design-language.md` §8's data surface: the one place the aesthetic
/// yields to utility.
///
/// **Why this construction and not another**, measured in
/// `docs/wakil/phase-2c-i-probe.md`:
///
/// - A `LazyVStack` of rows at `.frame(height:)` measures **exactly**
///   23.0000 and 40.0000 pt/row, which is what makes §8's dense row
///   reachable at all. `Table`'s `NSTableView` floors at 24pt (2b-ii), and
///   a `Grid` builds every row it is given — 5,000 rows cost a 5.3-second
///   first layout and missed the 8.33ms frame budget on 300 steps of 300.
///   This construction builds ~1,086 row bodies for 50,000 rows and misses
///   the budget once in 300.
/// - **No `Section`.** A `Section`'s pinned header is the obvious way to
///   get a header that scrolls horizontally with its columns, and it
///   under-reports the scroll view's document height by 2.8% — pinned or
///   not, so pinning is not the cause. That is a scrollbar of the wrong
///   size and a `pane_scroll_to_row` that lands in the wrong place. The
///   header is therefore drawn *above* the `ScrollView`, measured exact,
///   and its horizontal offset is shared by hand through
///   `HorizontalOffsetKey` below.
/// Identifies the cell being edited — row position and column index, the
/// same pair `editingCell` already carried as a tuple before fix round 2.
/// A distinct `Hashable` type rather than the tuple: Swift tuples have a
/// structural `==` when their elements are `Equatable`, but that is not a
/// protocol conformance, and `FocusState<Value: Hashable>` needs an actual
/// one to bind `.focused($x, equals:)` against — which is the whole point,
/// see `editingFieldFocused`'s doc comment.
private struct EditingCellID: Hashable {
    let row: Int
    let column: Int
}

struct DataSurface: View {
    let table: PaneTable
    let pane: Pane
    /// Dispatches an action by name. Every interaction in this view goes
    /// through it — there is no path from a click to state that does not
    /// journal, which is Invariant 2 in one sentence.
    let dispatch: (String, JSONValue) -> Void
    /// Whether this surface's pane is the focused one, and how many times anything has asked
    /// for a pane to be focused (`WindowModel.keyboardFocusRequests`) — the git pane's and the
    /// terminal's hook, for the same reason: the rail, ⌘K, a canvas click and `pane_focus` are
    /// how an operator, VoiceOver or the e2e harness puts the keyboard in a pane, and SwiftUI's
    /// `.focusable()` surface refuses `AXFocused` (measured: axresolve `not_focusable`), so
    /// without this nothing but a tap on a cell gave the grid its keys. No default, so no
    /// caller can leave it unwired.
    let isFocusedPane: Bool
    let keyboardFocusRequests: Int

    /// §8's first hover-revealed row action. `nil` on every surface whose
    /// subject is not a table list — `DBPane` is the only caller that ever
    /// passes non-`nil`, and it decides by asking the pane's subject
    /// directly, not by probing this table's rows. Defaulted to `nil` so
    /// every existing construction of this view is unchanged.
    var drill: ((Int) -> Void)? = nil

    /// This pane's `PaneEditable`, or `nil` when its current subject
    /// cannot be written back to a single table. Handed to `editableCell`
    /// — the only thing that decides whether a cell may be edited, so it
    /// is never re-derived here.
    ///
    /// **Read per pane id by the caller, not window-scoped.** `Canvas`
    /// asks `WindowModel.editable(paneId:)` for THIS pane's id, the same
    /// discipline `DBPane`'s `refusal` doc comment records for
    /// `queryLineRefusal(pane:)`: a value shared across every open pane
    /// painted one pane's state under all the others. Defaulted to `nil`
    /// so every existing construction of this view still compiles.
    var editable: PaneEditable? = nil

    /// Enter in an edited cell, wired to `WindowModel.commitCellEdit`.
    /// `nil` on every surface that never offers an editor at all — the
    /// same defaulting `drill` already uses, and for the same reason:
    /// every existing construction of this view must still compile.
    var editing: (
        (_ rowKey: String, _ column: String, _ columnType: String?, _ value: String) async
            -> WindowModel.CellEditOutcome
    )? = nil

    /// Where the row content's leading edge currently is, reported out of
    /// the `ScrollView` by `HorizontalOffsetKey`. `nil` until the first
    /// measurement arrives.
    @State private var contentLeadingEdge: CGFloat?

    /// Which column's trailing edge is being dragged, and how far — `nil`
    /// when no width drag is in flight.
    ///
    /// `@State` while the pointer moves and **one dispatch on release**,
    /// the same rule `Canvas`'s pane-resize gesture follows and for the
    /// same reason `LayoutActions`' commit-granularity comment gives: the
    /// gesture is not the action, its commit is.
    @State private var widthDragColumn: String?
    @State private var widthDragTranslation: CGFloat = 0

    /// Which header cell the pointer is over, or `nil`. Drives the
    /// hover-revealed column edge — see `widthHandle` for why the edge has
    /// to be revealed at all.
    @State private var hoveredColumn: String?

    /// Which row the pointer is over, or `nil`. Same pattern as
    /// `hoveredColumn` above: drives a control that is otherwise invisible,
    /// so §8's "row separation by whitespace, not rules" holds at rest.
    @State private var hoveredRow: Int?

    /// Which *cell* the pointer is over, or `nil` — distinct from
    /// `hoveredRow` above and not derivable from it.
    ///
    /// **Why a second piece of hover state at all.** The editable-cell
    /// affordance used to key on `hoveredRow`, which meant every editable
    /// cell in the row lit up at once: pointing at one cell claimed the
    /// others. A row hover and a cell hover are answering two different
    /// questions — "which row are you on" (which the row's own lift
    /// answers) and "which cell would a double-click open" (this) — and
    /// only the second can be answered by the row that owns the pointer,
    /// because a row does not know where inside itself the pointer is.
    @State private var hoveredCell: EditingCellID?

    /// Which cell is being edited — row index and column index — and the
    /// text in it. `nil` when nothing is.
    ///
    /// **One cell at a time**: a second double-click abandons the first.
    /// Two live editors would be two uncommitted values with one
    /// confirmation plane between them.
    @State private var editingCell: EditingCellID?
    /// The row key captured at the moment the editor opened — **fix round
    /// 1, Critical**. `editingCell.row` is `PaneRow.id`, which is a
    /// position in the currently displayed order, not a stable identity;
    /// a sort or a re-fetch between the double-click and Enter can put a
    /// different row at that same position. Re-deriving a row key from
    /// `editingCell.row` at commit time (what this used to do) reads
    /// whatever row is NOW at that position and hands its key to
    /// `commitCellEdit` — which then has no way to tell "the row this was
    /// typed for" from "the row that happens to be there now", because
    /// membership in `editable.rowKeys` is all it can check, and the new
    /// row's own key is of course a member. Capturing the key here, once,
    /// and carrying it forward unchanged is what lets that guard do the
    /// job it was written for: a key that is no longer current gets
    /// refused, rather than silently re-targeted.
    @State private var editingRowKey: String?
    @State private var editingText: String = ""
    /// The gate's or the driver's own sentence for the cell being edited.
    @State private var editingRefusal: String?
    /// **Keyed on the cell's own identity, not a bare `Bool` — fix round 2,
    /// the open review finding.** A single shared `Bool` cannot tell "cell A
    /// wants focus" from "cell B wants focus": it can only say yes or no,
    /// so a double-click on cell B while cell A is still editing can lose
    /// focus entirely if A's field is removed from the tree after B's
    /// `.onAppear` already ran — whichever field tore down last "wins" the
    /// shared flag regardless of which one the operator actually double-
    /// clicked. Keying this on `EditingCellID` and binding each `TextField`
    /// with `.focused($editingFieldFocused, equals:)` instead makes it a
    /// statement about WHICH cell wants focus, so there is nothing for two
    /// cells to race over — only one identity can match at a time.
    ///
    /// **Re-asserted after a `.refused` or `.cancelled` outcome, not only
    /// on `.onAppear`.** `ConfirmationPlane` raises its own `@FocusState`
    /// (`ConfirmationPlane.swift:29`) and takes first responder the moment
    /// it appears — that is correct, an operator has to be able to type
    /// "confirm" without clicking first. But when a refusal or a cancel
    /// leaves this cell's editor open (see `commit` below), the plane
    /// dismisses and nothing hands focus back: this cell's `TextField`
    /// never left the tree, so its `.onAppear` never fires again, and
    /// without an explicit re-assertion `Return`/`Escape` stop reaching it
    /// until the operator clicks back in by hand — exactly what the prior
    /// implementer's own live-app account reported.
    @FocusState private var editingFieldFocused: EditingCellID?

    /// The surface's own focus anchor — D2. One per surface, not one per
    /// cell: `.focusable()` on every cell would put all 500 rows' worth of
    /// them in the window's key-view loop, and Tab would walk the grid.
    @FocusState private var surfaceFocused: Bool

    private var rowHeight: Double { pane.density.rowHeight }

    /// How much width the row `ScrollView`'s vertical scroller takes out of
    /// the surface, which is either all of it or none — 2c-ii-b walk defect
    /// D1, and `paneContentWidth`'s parameter.
    ///
    /// **A `legacy` scroller is laid out; an `overlay` one is not.** Under
    /// `.legacy` (System Settings → Appearance → "Show scroll bars" set to
    /// *Always*, and also what *Automatic* resolves to the moment a mouse is
    /// attached) `NSScrollView` insets its document view by the scroller's
    /// width. Under `.overlay` the scroller floats above the content and
    /// costs nothing, so the surface and the viewport are the same width and
    /// this is zero. That difference is why the defect is invisible on a
    /// laptop with no mouse and permanent with one, and why this is asked of
    /// AppKit per render rather than hardcoded to 15.
    ///
    /// Read on each `body` evaluation rather than observed: the style
    /// changes only when a pointing device is plugged in or the setting is
    /// changed by hand, and any subsequent interaction with the window
    /// re-renders. A pane already on screen at the moment a mouse is
    /// attached keeps the old arithmetic until it is next touched.
    private var verticalScrollerAllowance: Double {
        guard NSScroller.preferredScrollerStyle == .legacy else { return 0 }
        return Double(NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy))
    }

    var body: some View {
        GeometryReader { geometry in
            // D1. Not `geometry.size.width` — see `paneContentWidth`. The
            // surface measures wider than the viewport its rows scroll in
            // by exactly the vertical scroller, under the scroller style
            // this machine is set to right now.
            // The strip takes its width off the grid, not off the top of it: the
            // columns, the header and the hover actions all lay out in what is left.
            let stripWidth = max(220, geometry.size.width / 3)
            let gridWidth = showsDetail ? max(0, geometry.size.width - stripWidth) : geometry.size.width
            let content = paneContentWidth(
                surfaceWidth: Double(gridWidth),
                verticalScrollerAllowance: verticalScrollerAllowance)
            // The grip's gutter comes off first (Amendment 5), so the columns start after it
            // and the gutter plus the columns still sum to the row viewport exactly.
            let widths = paneColumnLayout(
                columns: table.columns.map(\.name), overrides: pane.columnWidths,
                availableWidth: paneColumnsWidth(rowWidth: content), horizontalSpacing: 16)
            // Both edges in the same space, differenced here — see
            // `paneHeaderOffset` for why that and not an offset latched
            // from the first measurement (final review Finding 4). The
            // surface's own leading edge stands in for the row
            // `ScrollView`'s: they are the same edge, since the rows are
            // the middle row of a zero-spacing, leading-aligned `VStack`
            // that this `GeometryReader` measures.
            let offset = paneHeaderOffset(
                contentLeadingEdge: contentLeadingEdge.map(Double.init),
                surfaceLeadingEdge: Double(geometry.frame(in: .global).minX))
            // The in-flight width drag is applied to the header and the
            // rows together — a header that widened while its column did
            // not would be showing the operator something that is not
            // going to happen.
            let live = liveWidths(widths)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        header(base: widths, live: live, offset: offset)
                        rows(live, minimumRowWidth: content)
                    }
                    .frame(width: gridWidth, alignment: .leading)
                    if showsDetail {
                        RowDetailStrip(table: table, pane: pane, close: {
                            showsDetail = false
                            // Rule 3: closing the strip returns focus to the grid, as Esc does.
                            if editingCell == nil { surfaceFocused = true }
                        })
                            .frame(width: stripWidth)
                    }
                }
                // The cell editor's own refusal line, matching `DBPane`'s
                // treatment of `queryLineRefusal(pane:)` exactly — same
                // color, same size, same one-line placement beneath the
                // surface it refused inside.
                if let editingRefusal {
                    Text(editingRefusal)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color(red: 0.910, green: 0.361, blue: 0.361).opacity(0.75))
                }
                footer()
            }
            // D2's anchor. `.focusable()` makes the surface a thing focus
            // can rest on at all; the binding is what the double-click that
            // opens no editor moves it to. Declared on the container rather
            // than on a cell so there is exactly one of them per pane.
            .focusable()
            .focused($surfaceFocused)
            // **The ring is AppKit's, and it is the one thing on screen
            // whose colour Wakil does not choose.** `.focusable()` above
            // makes the surface a first-responder target, and macOS
            // answers that by drawing its standard focus ring in the
            // *system accent colour* — green, blue, whatever System
            // Settings says. `design-language.md` §2 gives the environment
            // sole ownership of which colours are in the room, so a hard
            // accent-coloured rectangle is a colour decision taken
            // somewhere outside this app, drawn over a room that is meant
            // to be staging-violet or production-red. It is also the only
            // hard-edged rectangle in a surface built from half-pixel
            // luminous borders and vignettes.
            //
            // **Nothing is lost by removing it**, which is what makes this
            // a deletion rather than a redesign: `surfaceFocused` is
            // write-only. Its single write (the double-click that opens no
            // editor) exists to keep first responder inside the clicked
            // pane so the next keystroke does not land in the project
            // field at the top of the window — it is never read to drive
            // anything on screen. Which cell is selected is drawn by the
            // selection treatment, independently and in Wakil's own
            // palette, and that is unaffected.
            //
            // Should focus itself ever need to be *visible* here — a
            // reason to read `surfaceFocused` rather than only write it —
            // it gets Wakil's own treatment (§3's luminous slab border at
            // a raised opacity), not this.
            .focusEffectDisabled()
            // The grid's keys (↑↓, Space, Esc, ⌘C) reach it only through this focus, and
            // nothing but a tap on a cell gave it — so the surface is named, and a keyboard
            // or accessibility client can put focus here (e2e: `do.focus db.<pane>.grid`).
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("db.\(pane.id).grid")
            // Focus follows the pane (the git pane's hook): a move to this pane, or a request
            // naming it while it is already focused, gives the grid the keyboard. Never on
            // appear — the surface first appears when a query typed in the query line lands,
            // and taking the keyboard then would pull it out of the line mid-edit. And never
            // with a cell editor open, which owns Return and Esc (as `select` does).
            .onChange(of: isFocusedPane) { _, now in
                if now && editingCell == nil { surfaceFocused = true }
            }
            .onChange(of: keyboardFocusRequests) { _, _ in
                if isFocusedPane && editingCell == nil { surfaceFocused = true }
            }
            .onKeyPress(phases: .down) { press in
                let key: String
                switch press.key {
                case .upArrow: key = "up"
                case .downArrow: key = "down"
                case .escape: key = "escape"
                case .space: key = " "
                default: key = press.characters.lowercased()
                }
                guard let claim = dataSurfaceKeyClaim(
                    key: key, command: press.modifiers.contains(.command),
                    editing: editingCell != nil, detailOpen: showsDetail)
                else { return .ignored }
                switch claim {
                case .copy: if let text = copyText() { writePasteboard(text) }
                case .toggleDetail: showsDetail.toggle()
                case .closeDetail: showsDetail = false
                case .move(let delta): moveAnchor(by: delta)
                }
                return .handled
            }
            // Edit ▸ Copy's ⌘C can reach the surface before `.onKeyPress` does; this answers it
            // with the same text (`copyText`), so the two paths cannot disagree. A cell being
            // edited owns ⌘C, so nothing is offered then.
            .onCopyCommand {
                guard editingCell == nil, let text = copyText() else { return [] }
                return [NSItemProvider(object: text as NSString)]
            }
            // The strip shows the anchor row; with none left (a re-query removed it, or the
            // selection was cleared) it closes (spec edge).
            .onChange(of: table.selection.anchorRow) { _, anchor in
                if showsDetail && (anchor.map { $0 >= table.rows.count } ?? true) { showsDetail = false }
            }
            // A cell editor names a position (`editingCell.row`/`.column`)
            // in the CURRENT display, and `editingRefusal` is a sentence
            // about the row that was being edited when it was raised — fix
            // round 1, Minor. If the rows or the columns underneath change
            // (a sort, a page turn, a re-fetch that lands a different
            // subject), whatever now sits at that position is not what
            // opened the editor, and an editor or a refusal that stayed
            // open would be drawn over — or about — the wrong thing.
            // Selection changes alone do not touch either watched value,
            // so this cannot fight the same double-click's own `select`.
            .onChange(of: table.rows) { _, _ in
                editingCell = nil
                editingRowKey = nil
                editingRefusal = nil
                editingFieldFocused = nil
            }
            .onChange(of: table.columns) { _, _ in
                editingCell = nil
                editingRowKey = nil
                editingRefusal = nil
                editingFieldFocused = nil
            }
        }
    }

    // MARK: - Header

    /// Outside the vertical `ScrollView` — see the type's doc comment — and
    /// offset horizontally to match the rows beneath it.
    private func header(base: [Double], live: [Double], offset headerOffset: Double) -> some View {
        HStack(spacing: 16) {
            ForEach(Array(table.columns.enumerated()), id: \.offset) { index, column in
                headerCell(column)
                    .frame(
                        width: live.indices.contains(index)
                            ? live[index] : paneColumnMinimumWidth,
                        alignment: .leading)
                    // The grab strip sits on the trailing edge, over the
                    // cell rather than beside it, so it costs the header
                    // no layout width and cannot push the columns out of
                    // step with the rows below them. `base`, not `live`:
                    // the drag's own effect must not feed back into the
                    // width it is measured from.
                    .overlay(alignment: .trailing) {
                        widthHandle(
                            column,
                            startWidth: base.indices.contains(index)
                                ? base[index] : paneColumnMinimumWidth)
                    }
                    // Revealed by hovering anywhere in the cell, not only
                    // over the 6pt strip that actually grabs: the strip is
                    // what you drag, this is what tells you it is there.
                    .overlay(alignment: .trailing) { columnEdge(column) }
                    .onHover { inside in
                        if inside {
                            hoveredColumn = column.name
                        } else if hoveredColumn == column.name {
                            hoveredColumn = nil
                        }
                    }
            }
        }
        // **The same gutter the rows' grips sit in, empty**, so the header's columns stay
        // over the rows' columns (Amendment 5).
        .padding(.leading, CGFloat(paneGripGutter))
        .offset(x: CGFloat(headerOffset))
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .padding(.bottom, 6)
    }

    private func headerCell(_ column: PaneColumn) -> some View {
        HStack(spacing: 5) {
            // §6 micro-label, the same treatment a pane's title gets.
            Text(column.name.uppercased())
                .font(.system(size: 9, weight: .medium))
                .tracking(1.7)
                .foregroundStyle(Color(red: 0.910, green: 0.925, blue: 0.965).opacity(0.45))
            if let type = column.type {
                // §8's column type annotation. Dimmer than the name: it is
                // context for the name, not a second label competing with it.
                Text(type.lowercased())
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Color(red: 0.910, green: 0.925, blue: 0.965).opacity(0.25))
            }
            // `table.sort` is a precedence list now (D5): index 0 is the
            // primary term. One arrow per term, with its ordinal when
            // more than one column is sorted — see `sortIndicator(for:)`.
            if let indicator = sortIndicator(for: column.name) {
                Text(indicator)
                    .font(.system(size: 7))
                    .foregroundStyle(Color(red: 0.910, green: 0.925, blue: 0.965).opacity(0.45))
            }
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .accessibilityAddTraits(.isHeader)
        .contentShape(Rectangle())
        .onTapGesture { sort(column.name) }
    }

    /// The sort indicator for one column: its direction, and its position
    /// when more than one column is sorted.
    ///
    /// **The ordinal is not decoration.** Two arrows with no precedence
    /// shown would replace the old ambiguity (a sort that was sometimes
    /// text and sometimes a glyph) with a new one — which column breaks
    /// the tie. With one term there is no precedence to state, so none is
    /// drawn.
    private func sortIndicator(for column: String) -> String? {
        guard let index = table.sort.firstIndex(where: { $0.column == column }) else {
            return nil
        }
        let arrow = table.sort[index].direction == .descending ? "▼" : "▲"
        return table.sort.count > 1 ? "\(arrow)\(index + 1)" : arrow
    }

    /// `widths` with the in-flight width drag applied. Floored by
    /// `paneColumnWidthAfterDrag`, which is the same function the release
    /// commits through — so the width the operator watches and the width
    /// that reaches `pane_set_column_width` are one number.
    private func liveWidths(_ widths: [Double]) -> [Double] {
        guard let widthDragColumn,
              let index = table.columns.firstIndex(where: { $0.name == widthDragColumn }),
              widths.indices.contains(index)
        else { return widths }
        var live = widths
        live[index] = paneColumnWidthAfterDrag(
            startWidth: widths[index], translation: Double(widthDragTranslation))
        return live
    }

    /// The drag that sets one column's width — §8's "drag a header edge",
    /// and until the 2c-i final review the missing half of
    /// `pane_set_column_width`: the action existed, was registered, was
    /// reachable from ⌘K and from an agent, and had no pointer path at all
    /// (Finding 5). The header cells carried a tap-to-sort gesture and
    /// nothing else, so the plan's claim that width is reachable from the
    /// pointer was not true of the shipped surface, and
    /// `dispatchFromSurface`'s `pane_set_column_width` branch was dead
    /// code.
    ///
    /// **`.global`, like `Canvas`'s resize handle and for the same reason.**
    /// This handle is laid out on the trailing edge of a cell whose width
    /// this gesture is changing, so in the default `.local` space the
    /// handle is moved out from under the pointer by its own effect and
    /// `translation` jitters instead of tracking.
    ///
    /// **One dispatch, on release.** Spec §4.1 and `LayoutActions`'
    /// commit-granularity comment: a 400-frame drag journals one entry
    /// saying where the column ended up, not four hundred saying it moved a
    /// point — and a dispatch on the frame path is an `await` §7's 8.33ms
    /// budget does not survive.
    /// §8's hover-reveal, applied to the column edge. The surface at rest
    /// keeps "row separation by whitespace, not rules" — this is a rule
    /// only while the pointer is in the cell that owns it, which is the
    /// same treatment §8 already gives row actions.
    private func columnEdge(_ column: PaneColumn) -> some View {
        Rectangle()
            .fill(Color(red: 0.910, green: 0.925, blue: 0.965)
                .opacity(hoveredColumn == column.name || widthDragColumn == column.name
                    ? 0.22 : 0))
            .frame(width: 1)
            .allowsHitTesting(false)
    }

    private func widthHandle(_ column: PaneColumn, startWidth: Double) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 6)
            .contentShape(Rectangle())
            // The pointer says what the strip does. Acceptance check 6
            // found the drag unusable without this — "i dont see the edge
            // of the column so i cant drag and resize it" — because a
            // 6pt transparent strip with no cursor and no mark is a
            // control that exists only for someone who already knows it is
            // there. `.set()` rather than `push()`/`pop()`: an unbalanced
            // stack leaves the resize cursor stuck over the whole window,
            // and a pane can be torn down mid-hover.
            .onHover { inside in
                if inside {
                    NSCursor.resizeLeftRight.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        widthDragColumn = column.name
                        widthDragTranslation = value.translation.width
                    }
                    .onEnded { value in
                        let width = paneColumnWidthAfterDrag(
                            startWidth: startWidth, translation: Double(value.translation.width))
                        // Cleared before the dispatch, not after: the
                        // dispatch is async and the committed width
                        // arrives back through `pane.columnWidths`, so a
                        // preview still applied on top of it would double
                        // the drag for a frame.
                        widthDragColumn = nil
                        widthDragTranslation = 0
                        dispatch("pane_set_column_width", .object([
                            "pane": .string(pane.id),
                            "column": .string(column.name),
                            "width": .number(width),
                        ]))
                    })
    }

    /// A click cycles ascending → descending → dropped on the clicked
    /// column, wherever in the precedence list it currently sits, and
    /// starts ascending on a column that is not sorted at all. Dropped is
    /// reachable because a sort is a claim about the data and the operator
    /// must be able to withdraw it — but only ITS OWN term: clearing every
    /// column's sort is not something a single column's click can cause.
    ///
    /// **"Any other" used to mean "not `.first`", which was wrong for a
    /// sorted SECONDARY column** (Task 15 fix round 1): the header draws
    /// an ordinal arrow — `▼2` — for a column that already has a term
    /// past the primary, so clicking it has to continue that column's own
    /// cycle, not start a new one. The old check only ever matched the
    /// primary term, so a click on a `▼2` column fell into the "starts
    /// ascending" branch and `PaneFetch.sorted(by:descending:)` (before
    /// its own fix) promoted it to primary — the badge advertised a
    /// precedence the click did not honour.
    ///
    /// **A descending click used to omit `column` entirely, which
    /// `pane_sort` reads as "clear every term"** (fix round 2): harmless
    /// while a sort held one term, and a live defect the moment
    /// `removingSort(column:)`'s absence became reachable through a
    /// secondary column's own click — sort by `kind`, then `id`, click
    /// `id` twice, and `kind` vanished too, though its own header was
    /// never touched. `direction: "drop"` names the column being removed,
    /// so `pane_sort` can tell "drop this one" from "drop everything"
    /// apart.
    private func sort(_ column: String) {
        var params: [String: JSONValue] = ["pane": .string(pane.id)]
        // `table.sort` is a precedence list now (D5); the clicked column
        // may be the primary term or a later one, so it is looked up
        // anywhere in the list rather than only at `.first`.
        if let currentSort = table.sort.first(where: { $0.column == column }) {
            switch currentSort.direction {
            case .ascending:
                params["column"] = .string(column)
                params["direction"] = .string("desc")
            case .descending:
                params["column"] = .string(column)
                params["direction"] = .string("drop")
            }
        } else {
            params["column"] = .string(column)
            params["direction"] = .string("asc")
        }
        dispatch("pane_sort", .object(params))
    }

    // MARK: - Rows

    private func rows(_ widths: [Double], minimumRowWidth: Double) -> some View {
        ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(table.rows) { row in
                        rowView(row, widths, minimumRowWidth: minimumRowWidth)
                            .id(row.id)
                    }
                }
                .background(
                    // Reports where the row content's leading edge is, so
                    // the header above can follow it. Differenced against
                    // the surface's own leading edge in `body`, measured in
                    // the same space — which is the fix for final review
                    // Finding 4. This used to be the whole answer on its
                    // own, with a `contentOrigin` latched from the first
                    // delivery subtracted from it; `Canvas` positions a
                    // pane with `.offset(x: pane.frame.x + drag)`, so
                    // dragging a pane 200pt right moved this number 200pt
                    // with no horizontal scroll at all, and the latch made
                    // that permanent — the header drew 200pt off its
                    // columns and stayed there, values under the wrong
                    // column name.
                    GeometryReader { inner in
                        Color.clear.preference(
                            key: HorizontalOffsetKey.self,
                            value: inner.frame(in: .global).minX)
                    })
            }
            // Rows start at the top-left of the scroll area, not in the
            // middle of it. A two-axis `ScrollView` *centres* content that
            // is smaller than its viewport in whichever axis has room, so a
            // one-row result drew halfway down an empty pane with its
            // header stranded at the top. This anchor is also the initial
            // scroll position, which is where it was already going.
            .defaultScrollAnchor(.topLeading)
            .onPreferenceChange(HorizontalOffsetKey.self) { minX in
                contentLeadingEdge = minX
            }
            .onChange(of: table.scrollTarget) { _, target in
                guard let target else { return }
                withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(target, anchor: .center) }
                // Cleared so the same row can be asked for twice. This is
                // why scrollTarget is runtime state in PaneStore and not
                // persisted: it describes a scroll about to happen.
                dispatch("pane_scroll_clear", .object(["pane": .string(pane.id)]))
            }
            .onChange(of: table.offset) { _, _ in
                // D4. A new page is a new result and starts at its first
                // row. Keyed on `offset` rather than `scrollTarget`
                // because two consecutive pages both want row 0, and
                // `scrollTarget` would not change between them — so the
                // existing handler cannot serve this.
                //
                // Unanimated, unlike `scrollTarget`'s: that one follows a
                // selection the operator can see moving, while this
                // replaces every row at once. Animating a scroll through
                // rows that are already gone would draw motion that means
                // nothing.
                guard let first = table.rows.first?.id else { return }
                proxy.scrollTo(first, anchor: .top)
            }
        }
    }

    /// One row: the grip's gutter, then the row's own cells.
    ///
    /// **The grip is outside the row's accessibility element, beside it rather than in it.**
    /// Task 1 measured that a grip inside the view carrying
    /// `.accessibilityElement(children: .ignore)` is absorbed into the row's one element and
    /// never resolves by its identifier — so the gutter and the cells are siblings here, and
    /// only the cells are the row element. The hover, the lift and the anchor's edge are on
    /// the pair, so the whole row, gutter included, still reads as one row.
    private func rowView(_ row: PaneRow, _ widths: [Double], minimumRowWidth: Double) -> some View {
        HStack(spacing: 0) {
            RowGrip(
                payload: ApiDragPayload(pane: pane.id, row: row),
                rowHovered: hoveredRow == row.id, height: rowHeight)
                .accessibilityIdentifier("db.row.\(row.id).grip")
            rowCells(row, widths, minimumRowWidth: minimumRowWidth - paneGripGutter)
        }
        .frame(height: rowHeight)
        .background(rowBackground(row))
        .overlay(alignment: .leading) {
            // §8 permits exactly one luminous element inside a data
            // surface, and this is it: the anchor row's left edge. **At the
            // very edge, outside the grip** (Amendment 5): the gutter is the
            // grip's, and the edge marks the row, not the handle.
            if table.selection.anchorRow == row.id {
                Rectangle()
                    .fill(Color(red: 0.62, green: 0.51, blue: 1.0))
                    .frame(width: 2)
                    .shadow(color: Color(red: 0.62, green: 0.51, blue: 1.0).opacity(0.7), radius: 4)
                    .allowsHitTesting(false)
            }
        }
        .onHover { inside in
            if inside {
                hoveredRow = row.id
            } else if hoveredRow == row.id {
                hoveredRow = nil
            }
        }
    }

    private func rowCells(_ row: PaneRow, _ widths: [Double], minimumRowWidth: Double) -> some View {
        HStack(spacing: 16) {
            ForEach(table.columns.indices, id: \.self) { index in
                cellView(
                    row, index,
                    width: widths.indices.contains(index) ? widths[index] : paneColumnMinimumWidth)
            }
        }
        // `paneColumnLayout` divides `availableWidth` across the free
        // columns, so in the ordinary case the columns' own widths already
        // sum to the pane's full width and this is a no-op. It only bites
        // once every column has been dragged narrower than the pane has
        // room for (`widthHandle`'s per-column override with no free
        // column left to absorb the rest) — the one layout that leaves real
        // dead space to the right of the last column. `minWidth`, not
        // `maxWidth: .infinity`: an unbounded frame inside a horizontally
        // scrolling `ScrollView` (this row's own ancestor two levels up)
        // has nothing to measure its natural width against and the scroll
        // range collapses — `minWidth` only ever grows the row, never
        // shrinks the natural width scrolling depends on.
        .frame(minWidth: minimumRowWidth, alignment: .leading)
        // Exact in both directions, which is the whole reason this is not a
        // Table. Never padding: padding can only grow a row past a floor.
        .frame(height: rowHeight)
        .overlay(alignment: .trailing) {
            // §8's first hover-revealed row action. Visible only while the
            // pointer is over this row and only when a drill was offered
            // at all — `drill` is `nil` on every surface whose subject is
            // not a table list.
            if hoveredRow == row.id {
                HStack(spacing: 6) {
                    // The row detail strip's toggle. On the anchor row with the strip
                    // open it closes the strip; anywhere else it selects this row
                    // (keeping the anchor's column) and opens the strip.
                    Button {
                        toggleDetail(row)
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(Color(red: 0.62, green: 0.51, blue: 1.0))
                    .accessibilityIdentifier("db.\(pane.id).row.\(row.id).detail")
                    if let drill {
                        Button("open") { drill(row.id) }
                            .buttonStyle(.plain)
                            .font(.system(size: 9, weight: .medium))
                            .tracking(1.0)
                            .foregroundStyle(Color(red: 0.62, green: 0.51, blue: 1.0))
                    }
                }
                // D6. The vertical scroller is drawn over this edge and
                // clipped "open" to "ope". Not fixed by hiding the
                // scroller: it is the only indication of position in a
                // 500-row page.
                .padding(.trailing, 20)
            }
        }
        .contentShape(Rectangle())
        // A click that lands in the row but on no cell: the `HStack`'s
        // 16pt inter-column gaps (`spacing: 16` above), or the strip
        // `.frame(minWidth:)` above adds past the last column. Every pixel
        // that belongs to an actual cell is already owned by that cell's
        // own `.onTapGesture`s in `cellView` — SwiftUI gives a descendant
        // view's gesture priority over an ancestor's covering the same
        // point, so this one only ever recognizes where no cell's own
        // `.contentShape` reaches, and a click or a double-click on a cell
        // is unaffected by this existing at all.
        .onTapGesture { selectRow(row.id) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rowAccessibilityLabel(row))
        .accessibilityAddTraits(table.selection.rows.contains(row.id) ? [.isSelected] : [])
        // The ⓘ is hover-only and ignored children hide it from VoiceOver, so the
        // same behaviour is a named action on the row's one element.
        .accessibilityAction(named: "Show details") { toggleDetail(row) }
    }

    /// The row detail strip's toggle. On the anchor row with the strip open it closes the
    /// strip; anywhere else it selects this row (keeping the anchor's column) and opens it.
    private func toggleDetail(_ row: PaneRow) {
        if showsDetail && table.selection.anchorRow == row.id {
            showsDetail = false
        } else {
            let column = table.selection.anchorColumn
                .flatMap { name in table.columns.firstIndex { $0.name == name } } ?? 0
            select(row: row.id, column: column)
            showsDetail = true
        }
    }

    /// A click in the row that landed on no cell at all — see the
    /// `.onTapGesture` above this call site for which pixels that can be.
    ///
    /// **Anchored at the first column**, the same convention a
    /// spreadsheet's row-number gutter uses: a click with no cell under it
    /// has no value to anchor a selection at, so it anchors at the first
    /// column instead of anchoring nowhere. Routed through `select` rather
    /// than dispatching directly so shift- and command-click extend or
    /// toggle the selection here exactly as they do from a cell — one rule
    /// for what a modified click means, not two.
    private func selectRow(_ row: Int) {
        guard !table.columns.isEmpty else { return }
        select(row: row, column: 0)
    }

    /// The row's background: a flat, non-luminous lift for hover and for
    /// selection, never a glow — §8's single-luminous-element rule (the
    /// anchor row's edge is the one exception) holds, and the amendment
    /// recording the selected-row treatment is in the spec's §7.
    ///
    /// **The opacity itself is `paneRowBackgroundOpacity` (`WakilKit`), not
    /// decided here** — the house pattern this file already follows for
    /// `paneColumnWidthAfterDrag` and `paneHeaderOffset`: `WakilApp` has no
    /// test target, so a decision that can be framed as arithmetic on two
    /// booleans belongs where `WakilKitTests` can hold it to a contract.
    /// Hover reads weaker than selection ("you are here" vs. "this is
    /// chosen"), and a row that is both stays legible as both rather than
    /// collapsing into the plain selected look.
    private func rowBackground(_ row: PaneRow) -> some View {
        Color(red: 0.910, green: 0.925, blue: 0.965)
            .opacity(paneRowBackgroundOpacity(
                selected: table.selection.rows.contains(row.id), hovered: hoveredRow == row.id))
    }

    /// A cell as drawn at rest, or as an input while it is being edited.
    ///
    /// **Whether this cell may be edited at all is `editableCell`'s answer,
    /// never re-derived here** — it already excludes key columns and
    /// bounds-checks the row, and duplicating that rule in the view is
    /// exactly the failure mode the house pattern (`editableCell`,
    /// `offersDrill`, `shouldAdoptSubject`) exists to avoid: a value-level
    /// decision with no test target to catch it drifting from the one in
    /// `WakilKit`.
    private func cellView(_ row: PaneRow, _ index: Int, width: Double) -> some View {
        let columnName = table.columns.indices.contains(index) ? table.columns[index].name : ""
        let rowKey = editableCell(editable, column: columnName, row: row.id)
        let thisCell = EditingCellID(row: row.id, column: index)
        return Group {
            if editingCell == thisCell {
                TextField("", text: $editingText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .focused($editingFieldFocused, equals: thisCell)
                    // The field does not exist in the tree until this
                    // branch draws, so it cannot be focused any earlier
                    // than its own appearance — fix round 1, Important.
                    // Re-asserted (not just set) after a `.refused` or
                    // `.cancelled` outcome too, in `commit` below — this
                    // `.onAppear` alone does not refire then, because the
                    // field never left the tree.
                    .onAppear { editingFieldFocused = thisCell }
                    // No `.keyboardShortcut`, ever — `DBPane`'s standing
                    // prohibition, recorded on its own doc comment. A
                    // per-pane shortcut is window-scoped and fires the
                    // FIRST REGISTERED pane's control whatever has focus,
                    // so typing in one pane's cell would commit another
                    // pane's edit. `.onSubmit` on the focused field is
                    // what routes Return to the pane it was typed in.
                    .onSubmit { commit(row: row.id, column: index, columnName: columnName) }
                    .onExitCommand {
                        // Escape abandons — the only way out of edit mode
                        // that does not run anything at all.
                        editingCell = nil
                        editingRowKey = nil
                        editingRefusal = nil
                        editingFieldFocused = nil
                    }
            } else {
                existingCellContent(row, index)
                // The cell's full box, so a right-click anywhere in it opens the menu; the
                // outer frame below is the same size, so nothing moves.
                .frame(width: width, height: rowHeight, alignment: .leading)
                .contentShape(Rectangle())
                .contextMenu {
                    let indexes = gridCopyRows(selection: table.selection, clickedRow: row.id, rowCount: table.rows.count)
                    Button("Copy cell") {
                        if index < row.cells.count { writePasteboard(gridCopyCell(row.cells[index])) }
                    }
                    Button(indexes.count > 1 ? "Copy \(indexes.count) rows" : "Copy row") {
                        writePasteboard(gridCopyText(columns: table.columns, rows: indexes.map { table.rows[$0] }))
                    }
                    Button("Copy as JSON") {
                        writePasteboard(gridCopyJSON(columns: table.columns, rows: indexes.map { table.rows[$0] }))
                    }
                }
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .monospacedDigit()
        .lineLimit(1)
        .truncationMode(.tail)
        // **The whole column width, not the text's own bounds — fix round
        // 2.** This used to be framed by the CALLER (`rowView`) after
        // `.contentShape(Rectangle())` below had already been applied here,
        // which describes the content shape at the text's own natural
        // size — clicking the empty part of a wide column hit nothing,
        // because the frame that widened the view arrived one modifier too
        // late to be part of what `contentShape` captured. Framing here,
        // before `.contentShape` and every gesture below it, makes the
        // full column width part of the shape those gestures — including
        // the double-click that opens the editor, not just the plain
        // click that selects — actually hit-test against.
        //
        // **`height` too, and it is not cosmetic.** A cell's natural
        // height is its one line of 12pt monospaced text — about 15pt —
        // while the row it sits in is 40pt (airy) or 23pt (dense); the
        // `HStack` centres the short cells inside the tall row, so
        // two-thirds of an airy row was empty space belonging to no cell
        // at all. That cost two things: the vertical middle third was the
        // only part of a row where a click landed on a cell rather than
        // falling through to `rowView`'s catch-all, and the hover outline
        // below, inset from a 15pt box, came out at negative height and
        // drew nothing whatsoever. Matching the row's height fixes both at
        // once and is what makes `paneEditHoverInset` mean what it says.
        .frame(width: width, height: rowHeight, alignment: .leading)
        .contentShape(Rectangle())
        // **One tap gesture, and the click count read off the event** (2c-ii-c walk). Any
        // `TapGesture(count: 2)` on the cell — exclusive or simultaneous — made SwiftUI hold
        // every single click for the system double-click interval (~0.5 s) before selecting;
        // measured, the selection itself takes 5–20 ms once the handler runs. So the cell
        // selects on every click at once, and the second click of a double-click also opens
        // the editor.
        //
        // **A double-click still selects too, deliberately.** A double-click is a
        // click first: the same cell becoming both selected and editable
        // is the ordinary multi-click convention (Finder selects, then
        // opens), and `select`'s own dispatch touches only
        // `table.selection`, which the edit-invalidation `onChange` below
        // does not watch — so the two cannot fight over the editor.
        .onTapGesture {
            select(row: row.id, column: index)
            guard (NSApp.currentEvent?.clickCount ?? 1) >= 2 else { return }
            guard let rowKey else {
                // **D2. A double-click that opens no editor must still
                // land somewhere.** A key column, or any cell in a
                // read-only result, has no `rowKey` and so opens nothing —
                // and a click that takes no focus leaves the window free
                // to hand key focus to its first focusable control, which
                // is the 2b-i `TextField("project")` scaffolding row at
                // the top of `WakilWindow`. The operator's next keystroke
                // then edits the project name. Anchoring focus on the
                // surface itself is what keeps a click inside the pane
                // that was clicked.
                //
                // Only on this branch. Asserting it on the editable branch
                // would fight the cell `TextField` for first responder,
                // and asserting it on the plain tap below would steal
                // `Return`/`Escape` from an editor that is already open
                // one cell over — the exact shape of the regression check
                // 5 exists to catch. The plain tap therefore takes the
                // grid's focus only when no editor is open (`select`).
                surfaceFocused = true
                return
            }
            // A second double-click, on a different cell, abandons the
            // first: there is one confirmation plane, so there can only
            // ever be one editor waiting on it.
            editingCell = thisCell
            editingRowKey = rowKey
            // NULL seeds as empty — `PaneCell.text` is already "" for a
            // null value (`PaneCell.init(_:)`), so this reads exactly
            // like any other empty string here. An empty field commits
            // the empty string, not NULL; `=NULL` is what asks for NULL.
            editingText = row.cells.indices.contains(index) ? row.cells[index].text : ""
            editingRefusal = nil
        }
        // Tracks the pointer at CELL granularity, which the row's own
        // `.onHover` cannot: a row knows the pointer is somewhere inside
        // it, not which of its cells. Declared after `.frame(width:)`
        // above, so the tracked area is the whole column — the same area
        // the tap gestures hit-test against, and the same area the outline
        // below is drawn around. All three agreeing is what makes the
        // affordance honest: the outline appears exactly where a
        // double-click would in fact open an editor.
        .onHover { inside in
            if inside {
                hoveredCell = thisCell
            } else if hoveredCell == thisCell {
                hoveredCell = nil
            }
        }
        // The affordance: revealed under the pointer, invisible at rest,
        // the same pattern `hoveredRow` already drives for the drill
        // button — so §8's "row separation by whitespace, not rules"
        // holds at rest, and a cell that CAN be edited stops looking like
        // one that cannot only once the pointer is on it.
        //
        // **An outline, not a fill, and only on the cell under the
        // pointer.** This used to be a `.background` tint keyed on
        // `hoveredRow`, which made every editable cell in the row a filled
        // slab running the row's full height — it read as a band the row
        // had grown rather than as an invitation to type, and it pointed
        // at cells the pointer was not on. A hairline border inset from
        // the row's edges reads as the thing it is promising: the text
        // field that will appear in this exact place on a double-click.
        // Non-luminous, so §8's one-luminous-element rule (the anchor
        // row's edge) is untouched.
        .overlay {
            if rowKey != nil && hoveredCell == thisCell {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(
                        Color(red: 0.910, green: 0.925, blue: 0.965).opacity(0.30),
                        lineWidth: 1)
                    // Vertically: inset so the outline floats inside the
                    // row — `paneEditHoverInset` (`WakilKit`) decides how
                    // far, because it has to hold at both densities and
                    // `WakilApp` has no test target.
                    //
                    // Horizontally: NEGATIVE, growing the outline out into
                    // the `HStack`'s 16pt inter-column gap rather than in.
                    // An outline flush to the column width would sit right
                    // against its own text on the leading edge, which is
                    // the "needs some padding" complaint; taking 4pt of
                    // the 16pt gap on each side leaves 8pt still between
                    // two adjacent outlines, so they cannot touch. Safe
                    // inside an `.overlay`, which does not participate in
                    // layout — nothing moves, the outline just draws
                    // wider.
                    .padding(.vertical, paneEditHoverInset(rowHeight: rowHeight))
                    .padding(.horizontal, -4)
                    // Purely decorative, and drawn over the neighbouring
                    // gap — without this it would swallow clicks aimed at
                    // the 4pt it overhangs into.
                    .allowsHitTesting(false)
            }
        }
    }

    /// The cell content at rest — extracted unchanged from what was, before
    /// this task, `cellView`'s whole body: NULL rendering, chips and the
    /// `.help` tooltip all stay exactly as they were.
    private func existingCellContent(_ row: PaneRow, _ index: Int) -> some View {
        Group {
            if index >= row.cells.count {
                // Cells shorter than the column list are not padded; the
                // view draws only where the index exists.
                Text("")
            } else if row.cells[index].isNull {
                // §8's explicit null rendering. Before 2c-i this drew as ""
                // and a real NULL was indistinguishable from an empty
                // string — which is the confusion the rule exists against.
                Text("NULL")
                    .foregroundStyle(Color(red: 0.910, green: 0.925, blue: 0.965).opacity(0.30))
            } else if isChip(row.cells[index], column: index) {
                chip(row.cells[index].text)
            } else {
                Text(row.cells[index].text)
                    .help(row.cells[index].text)
            }
        }
    }

    /// Enter in an edited cell. The outcome decides whether the editor
    /// closes: only a confirmed run changed anything, so only a confirmed
    /// run leaves edit mode. A refusal and a cancel both keep the
    /// operator's text, because at this range the discarded text is the
    /// value they just typed — D7's lesson, at close range.
    ///
    /// **Uses the row key captured at the double-click, never re-derives
    /// one from `row` — fix round 1, Critical.** `row` is only still a
    /// parameter because `.onSubmit` is wired per-cell and needs SOME way
    /// to name which cell's `TextField` fired it; the key that actually
    /// goes to `commitCellEdit` is `editingRowKey`, which does not move
    /// when a sort or a re-fetch reorders the display between the
    /// double-click and this call. If that key is no longer current,
    /// `commitCellEdit`'s own `rowKeys.contains(rowKey)` guard is what
    /// catches it — a membership check against a key that has not been
    /// silently swapped out from under it.
    private func commit(row: Int, column index: Int, columnName: String) {
        guard let editing, let rowKey = editingRowKey else { return }
        let type = table.columns.indices.contains(index) ? table.columns[index].type : nil
        let value = editingText
        // Captured now, compared against current state once the `await`
        // returns — fix round 1, Important. Without this, a second
        // double-click opened on a different cell while this round trip
        // is still in flight would have its editor closed by a `.committed`
        // that was never about it, or would draw this call's `.refused`
        // sentence under a cell that never made this request.
        let target = EditingCellID(row: row, column: index)
        Task {
            let outcome = await editing(rowKey, columnName, type, value)
            guard editingCell == target, editingRowKey == rowKey else { return }
            switch outcome {
            case .committed:
                editingCell = nil
                editingRowKey = nil
                editingRefusal = nil
                editingFieldFocused = nil
            case .refused(let reason):
                editingRefusal = reason
                // **The open review finding.** `ConfirmationPlane` raised
                // its own `@FocusState` while it was on screen and took
                // first responder away from this field; now that the plane
                // has dismissed (`outcome` only arrives after it does) and
                // the editor is staying open, nothing else hands focus
                // back — this field's `.onAppear` will not refire, because
                // it never left the tree. Without this line `Return` and
                // `Escape` stop reaching the field until the operator
                // clicks back into it by hand.
                editingFieldFocused = target
            case .cancelled:
                // Same reasoning as `.refused` above: the editor stays
                // open, so focus has to be re-asserted here too, not left
                // to an `.onAppear` that will not fire again.
                editingFieldFocused = target
            }
        }
    }

    /// §8's status chips, scoped to what can be identified honestly: a
    /// boolean. Guessing which *string* columns are "statuses" would put a
    /// chip on a `name` column that happens to read "active", which is a
    /// worse failure than no chip at all.
    ///
    /// **Requires both the text AND the column's declared type** (fix
    /// round 1, Finding 2). `PaneCell` collapses a driver's `.bool` and
    /// `.string` into the same `text`, so `cell.text == "true"` alone
    /// cannot tell a real boolean from a VARCHAR that happens to hold the
    /// word "true" — precisely the failure this method's own doc comment
    /// already claimed to avoid, reproduced with a different literal. The
    /// column's own reported type is what closes that gap, matched
    /// case-insensitively against `bool`/`boolean` only.
    ///
    /// **Deliberately does not try to catch MySQL's `TINYINT`.** MySQL
    /// spells a boolean as `TINYINT(1)` and an ordinary small integer as
    /// `TINYINT` — the two are indistinguishable from the type name alone,
    /// so a MySQL boolean column gets no chip here. That is a *missing*
    /// chip, not a *wrong* one, and a missing chip is the failure direction
    /// this rule must prefer: it costs a decoration, where guessing wrong
    /// costs the same false confidence a "name column that reads active"
    /// would.
    private func isChip(_ cell: PaneCell, column index: Int) -> Bool {
        guard cell.text == "true" || cell.text == "false" else { return false }
        guard table.columns.indices.contains(index), let type = table.columns[index].type else {
            return false
        }
        let normalized = type.lowercased()
        return normalized == "bool" || normalized == "boolean"
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(
                Capsule().fill(Color(red: 0.910, green: 0.925, blue: 0.965)
                    .opacity(text == "true" ? 0.14 : 0.06)))
    }

    @State var showsDetail = false

    private func writePasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// ⌘C's text: one row selected copies its anchor cell; several copy as TSV with a header.
    /// `nil` with nothing selected. Read by the key path and by `.onCopyCommand` alike.
    private func copyText() -> String? {
        let indexes = gridCopyRows(selection: table.selection, clickedRow: nil, rowCount: table.rows.count)
        guard !indexes.isEmpty else { return nil }
        if indexes.count == 1,
           let column = table.selection.anchorColumn,
           let columnIndex = table.columns.firstIndex(where: { $0.name == column }),
           columnIndex < table.rows[indexes[0]].cells.count {
            return gridCopyCell(table.rows[indexes[0]].cells[columnIndex])
        }
        return gridCopyText(columns: table.columns, rows: indexes.map { table.rows[$0] })
    }

    private func moveAnchor(by delta: Int) {
        guard !table.rows.isEmpty else { return }
        let current = table.selection.anchorRow ?? (delta > 0 ? -1 : table.rows.count)
        let next = min(max(current + delta, 0), table.rows.count - 1)
        let column = table.selection.anchorColumn ?? table.columns.first?.name ?? ""
        dispatch("pane_select_cell", .object([
            "pane": .string(pane.id), "row": .number(Double(next)), "column": .string(column),
        ]))
        // Selection alone does not scroll; pane_scroll_to_row sets the scrollTarget the
        // ScrollViewReader follows, so the moved anchor stays in view.
        dispatch("pane_scroll_to_row", .object(["pane": .string(pane.id), "row": .number(Double(next))]))
    }

    /// Shift extends the selection from the anchor; command toggles one
    /// row; a plain click starts a new selection at that cell.
    ///
    /// **The arithmetic itself lives in `paneSelectionAfterClick`**
    /// (`WakilKit`), not here — fix round 1, Finding 1. This method's only
    /// jobs are reading `NSEvent.modifierFlags` (which is why it, and not
    /// `paneSelectionAfterClick`, needs `AppKit`) and turning the resulting
    /// `PaneSelection` into a dispatch.
    private func select(row: Int, column index: Int) {
        // The grid takes the keyboard on a tap only when no editor is open; with one open, focus
        // stays in its field so Return and Esc still reach it.
        if editingCell == nil { surfaceFocused = true }
        let name = table.columns.indices.contains(index) ? table.columns[index].name : ""
        let modifiers = NSEvent.modifierFlags
        let clickModifier: PaneClickModifier =
            modifiers.contains(.shift) ? .shift : modifiers.contains(.command) ? .command : .plain

        // A plain click is still `pane_select_cell` rather than
        // `pane_select_rows` with one element — the two actions are not
        // interchangeable at the schema boundary an agent reads, and a
        // plain click is exactly the case `pane_select_cell` documents
        // itself as being for.
        guard clickModifier != .plain else {
            dispatch("pane_select_cell", .object([
                "pane": .string(pane.id), "row": .number(Double(row)), "column": .string(name),
            ]))
            return
        }

        let next = paneSelectionAfterClick(
            current: table.selection, row: row, column: name, modifier: clickModifier)
        var params: [String: JSONValue] = [
            "pane": .string(pane.id),
            "rows": .array(next.rows.sorted().map { .number(Double($0)) }),
            "column": .string(name),
        ]
        // Omitted rather than sent as some placeholder when there is no
        // longer an anchor (command-click emptied the selection entirely):
        // `pane_select_rows` already treats a missing `anchor` as "pick
        // one from `rows`", which for an empty `rows` is itself `nil` —
        // the same answer `next.anchorRow` gives here.
        if let anchor = next.anchorRow {
            params["anchor"] = .number(Double(anchor))
        }
        dispatch("pane_select_rows", .object(params))
    }

    private func rowAccessibilityLabel(_ row: PaneRow) -> String {
        zip(table.columns, row.cells)
            .map { "\($0.name): \($1.isNull ? "null" : $1.text)" }
            .joined(separator: ", ")
    }

    // MARK: - Footer

    /// §8's footer: row count, timing, and every claim the surface is
    /// making about the rows above it.
    private func footer() -> some View {
        TimelineView(.periodic(from: .now, by: table.runningSince == nil ? 3600 : 0.1)) { context in
            HStack(spacing: 10) {
                if let line = dbFlightLine(
                    runningSince: table.runningSince, cancelledAfterMs: table.cancelledAfterMs,
                    now: context.date) {
                    Text(line)
                        .layoutPriority(2)
                        .accessibilityIdentifier("db.\(pane.id).flight")
                }
                if table.runningSince != nil {
                    Button("Cancel") {
                        dispatch("db_cancel", .object(["pane": .string(pane.id)]))
                    }
                    .buttonStyle(.plain)
                    .modifier(Verb(heading: false, enabled: true))
                    .fixedSize()
                    .accessibilityIdentifier("db.\(pane.id).cancel")
                }
                // **Final review, Minor 7.** `rows`, the range (or its
                // untruncated-range fallback) and `read-only` are the three
                // segments the comment below has always claimed survive
                // narrowing — but nothing made that true: every segment shared
                // `HStack`'s default layout priority, so SwiftUI was free to
                // truncate whichever it pleased first. `.layoutPriority(1)` on
                // exactly these three, and none of the others, is what the
                // comment was describing.
                Text(paneRowCountLabel(table.rows.count))
                    .layoutPriority(1)
                if table.millis > 0 { Text("\(table.millis) ms") }
                if let range = table.rowRangeDescription {
                    // "rows 501–1,000 · more remain". Replaces the bare "more
                    // matched than were returned" as soon as a result is paged:
                    // it says the same thing and also says where you are.
                    Text(range)
                        .layoutPriority(1)
                } else if table.truncated {
                    Text("more matched than were returned")
                        .layoutPriority(1)
                }
                if !table.sort.isEmpty, table.truncated {
                    // Spec §7, as the probe corrected it, now naming every
                    // term: a sort the operator asked for and a warning that
                    // mentioned only its first column would understate what
                    // the result is ordered by. This survives a re-query: an
                    // outer ORDER BY cannot see past an inner bound, so a
                    // statement the operator capped at 5,000 rows and Wakil
                    // capped at 500 comes back sorted over 5,000 and showing
                    // 500 — still a subset, still owed the warning.
                    let columns = table.sort.map(\.column).joined(separator: ", ")
                    Text("sorted by \(columns) within the \(table.rows.count) returned")
                }
                if !table.pageable && !table.columns.isEmpty {
                    // An EXPLAIN or a SHOW. Said plainly, because the page
                    // controls are absent and their absence would otherwise
                    // read as a bug.
                    Text("this result cannot be paged")
                }
                if table.columnTypesInferred {
                    Text("types inferred from values")
                }
                Spacer()
                Text(editabilityLabel(editable))
                    .layoutPriority(1)
            }
            .font(.system(size: 9, weight: .medium))
            .tracking(1.0)
            .lineLimit(1)
            // D9. Without this every segment wrapped to one character per line
            // at small widths, turning the footer into a column of vertical
            // letters. `rows`, the range and `read-only` are the claims an
            // operator checks a result against, so they are what must survive
            // narrowing — the `.layoutPriority(1)` on each of those three,
            // above, is what actually makes that so; without it SwiftUI is
            // free to truncate any segment it likes first, this HStack's
            // default priority being equal on all of them.
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(Color(red: 0.910, green: 0.925, blue: 0.965).opacity(0.35))
            .padding(.top, 6)
        }
    }
}

// MARK: - The grip

extension UTType {
    /// A grid row on its way to an api pane. **Exported, so the bundle declares it**
    /// (`scripts/make-app-bundle.sh`'s `UTExportedTypeDeclarations`), and private to Wakil:
    /// nothing else offers it, so nothing dragged in from outside is accepted as a row.
    static let wakilDragRow = UTType(exportedAs: "com.wakil.drag-row")
}

/// **`Transferable` here, not in WakilKit**, which is where `ApiDragPayload` is stated and
/// tested: this conformance needs `CoreTransferable` and `UniformTypeIdentifiers`, and it
/// belongs to the target that draws the drag.
extension ApiDragPayload: Transferable {
    public static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .wakilDragRow)
    }
}

/// The grip a row is picked up by (spec §2, Amendment 5): one dimmed `⋮` in the row's own
/// leading gutter.
///
/// **A `.draggable` of its own, and it wins over the pane's drag.** Task 1 measured 43 clean
/// drags started on a grip without the canvas's `DragGesture` moving the pane once, so no
/// `.highPriorityGesture` is needed. **The whole gutter cell is the hit area**
/// (`.contentShape`): the glyph alone is a hairline to aim at.
///
/// **The open hand is pushed and popped, never `.set()`**, and only by this grip.
/// `.pointerStyle` is macOS 15 and the target is 14.4, so the cursor is AppKit's stack. A row
/// the `LazyVStack` recycles mid-hover never sees the pointer leave, so `.onDisappear` pops —
/// but only if THIS grip pushed, which `pushed` records; a grip that never pushed must not
/// pop a cursor someone else put there.
private struct RowGrip: View {
    let payload: ApiDragPayload
    let rowHovered: Bool
    let height: Double

    @State private var pushed = false

    var body: some View {
        Text("\u{22EE}")
            .font(.system(size: 11))
            .foregroundStyle(
                Color(red: 0.910, green: 0.925, blue: 0.965)
                    .opacity(paneGripOpacity(hovered: rowHovered)))
            .frame(width: CGFloat(paneGripGutter), height: CGFloat(height))
            .contentShape(Rectangle())
            .onHover { inside in
                if inside, !pushed {
                    NSCursor.openHand.push()
                    pushed = true
                } else if !inside, pushed {
                    NSCursor.pop()
                    pushed = false
                }
            }
            .onDisappear {
                if pushed {
                    NSCursor.pop()
                    pushed = false
                }
            }
            .draggable(payload)
    }
}

/// Carries the row content's leading edge out of the `ScrollView` so the
/// header outside it can follow. This is the hand-built half of what a
/// pinned `Section` header would have given for free, and the price of the
/// 2.8% document-height error that construction costs.
///
/// **A position, not an offset.** It is differenced against the surface's
/// own leading edge in `body`; turning it into an offset here, against
/// something latched the first time this fired, is what put the header
/// permanently out of alignment after a pane drag (final review Finding 4).
///
/// **Whether this needed the `NSViewRepresentable` fallback.** The brief for
/// this task named a known risk: mutating `@State` from `.onPreferenceChange`
/// can fail Swift 6's strict concurrency checking on some SDKs, because the
/// closure is `@Sendable` on some and not on others, with the fix being to
/// replace this mechanism with a small `NSViewRepresentable` that walks up to
/// the enclosing `NSScrollView` (the way `VoidView` reaches AppKit from
/// SwiftUI). On this toolchain (Swift 6.3.3, Xcode 26.6, as `swift build`
/// reports it) the code below compiles cleanly with no errors and no
/// concurrency warnings, so the `PreferenceKey` construction as written here
/// was kept rather than replaced.
private struct HorizontalOffsetKey: PreferenceKey {
    /// **Optional, and `reduce` keeps the last *real* value.** With a
    /// non-optional `CGFloat = 0` default and a `reduce` that took
    /// `nextValue()` unconditionally, every view in the `ScrollView`'s
    /// subtree that does not set this key still contributes the default,
    /// and the last such contribution overwrote the one measurement that
    /// meant anything. The key reported 0 while the rows' leading edge was
    /// at 16, so the header was offset by `0 - 16 = -16` — the pane's own
    /// padding — and with a pane at x=60 the error was the whole 76pt: the
    /// first column's name clipped away entirely by `.clipped()`, and
    /// every other column name sitting 76pt left of the values beneath it.
    /// That is the failure Finding 4 named, re-entering through the
    /// reduction rather than through the latch that fix removed.
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}
