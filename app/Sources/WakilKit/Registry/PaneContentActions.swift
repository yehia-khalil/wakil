import Foundation

/// The refusal these five actions owe a pane they cannot drive.
public enum PaneContentActionError: Error, Sendable, Equatable, CustomStringConvertible {
    case notADataSurfacePane(action: String, pane: String, kind: String)

    public var description: String {
        switch self {
        case .notADataSurfacePane(let action, let pane, let kind):
            return "\(action): pane \"\(pane)\" is a \"\(kind)\" pane, and this action drives "
                + "a data surface — its row index is a position in a sorted order that a "
                + "\"\(kind)\" pane does not have. Read the pane to see what it is showing."
        }
    }
}

/// Refuses `paneId` when the canvas says it is not a **data surface** —
/// the database pane, which is what `design-language.md` §8 and
/// `DataSurface.swift` already call that surface. It used to be spelled
/// `requireGridPane`, which collided with the charter's §9, where *live
/// grid* belongs to the TERMINAL pane (two-axis review, Standards 3). The
/// predicate is unchanged and is still `pane.kind != "db"`; the refusal's
/// own text already said "data surface" and is untouched, so nothing an
/// agent reads changed.
///
/// **No-op'ing is what shipped before 2c-iii and it is a failure this
/// repository has already recorded from three causes.** An agent calling
/// `pane_select_cell` on a terminal id wrote a selection and a
/// `scrollTarget` into a `PaneStore` entry nothing draws and got a success
/// back.
///
/// **Reinterpreting the parameter was the interesting alternative and it
/// loses on one word.** `row` is documented three times over as a
/// zero-based index into a *displayed order that a sort changes*. A
/// terminal has no sort, so `row` would then mean a table row, a block, or
/// a terminal line depending on kind and current screen — three
/// incompatible meanings behind one name. `term_scroll` is the terminal's
/// own answer.
///
/// **A layout that does not hold the pane is not refused.** `--dispatch`
/// and the module's own tests register against a `LayoutStore` holding
/// nothing; inventing a failure there would break every one of them, and
/// `requireOpenPane` is what already refuses an id no pane holds where
/// that check belongs.
private func requireDataSurfacePane(_ paneId: String, action: String, layout: LayoutStore) async throws {
    guard let pane = await layout.snapshot().panes.first(where: { $0.id == paneId }),
          pane.kind != "db"
    else { return }
    throw PaneContentActionError.notADataSurfacePane(action: action, pane: paneId, kind: pane.kind)
}

/// Registers the five actions that drive a pane's *contents* — as distinct
/// from `LayoutActions`, which drives its geometry.
///
/// **`pane_sort` used to be here and is not any more.** It moved to
/// `StandardActions.swift` in 2c-ii and changed kind from `.control` to
/// `.read`, because a pane that can re-query re-queries (spec §7) and
/// sorting a truncated result now reaches a database. `.control` is for
/// state that never leaves Wakil; an action has one kind, and `pane_sort`
/// takes the kind of the strongest thing it can do.
///
/// **Why these are actions at all.** Invariant 2 says every pane is
/// dual-driven, and selecting a row is driving a pane: "use the id from the
/// row you just highlighted" is a thing to say out loud, and an agent that
/// can neither see nor set the selection can only answer half of "what's on
/// screen?". Registering them also puts them in ⌘K for free, since the
/// palette is `registry.all()`.
///
/// **Why `.control` and why none names a target environment.** They change
/// Wakil's own state and nothing outside it, so the write gate's production
/// rule must not apply — being pointed at a production database is no
/// reason to be unable to select a row. And none of them changes which
/// environment is active, so none can be an agent walking into production.
///
/// **Why `row` is an index into the displayed order.** A sort reorders what
/// is on screen, so a displayed index and an underlying one diverge the
/// moment one is applied, and only one of them can be what these actions
/// and `read_pane` both mean. Invariant 3 settles it: the surface reflects
/// what is actually on screen. A sort therefore invalidates a
/// previously-held index, which is correct — after re-sorting, row 4 *is* a
/// different row, to the operator's eye as much as to the agent's.
public func registerPaneContentActions(
    into registry: ActionRegistry, panes: PaneStore, layout: LayoutStore
) async {
    await registry.register(Action(
        name: "pane_select_cell",
        description: "Select one cell in a pane: its row becomes the anchor and the "
            + "selection collapses to that row. row is a ZERO-BASED index into the order "
            + "currently displayed, which a sort changes — row 0 is the top row on screen. "
            + "It is a position, never a value in the data: to act on the row whose id is "
            + "1, read the pane and find which position that row currently occupies, or "
            + "run a query that returns only it.",
        kind: .control,
        audience: .agentReachable,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "pane": .object(["type": .string("string")]),
                "row": .object(["type": .string("number")]),
                "column": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("pane"), .string("row")]),
        ]),
        handler: { params in
            let pane = try requireString(params, "pane", action: "pane_select_cell")
            try await requireDataSurfacePane(pane, action: "pane_select_cell", layout: layout)
            let row = try requireRowIndex(params, "row", action: "pane_select_cell")
            let column = optionalString(params, "column")
            await panes.setSelection(
                paneId: pane,
                PaneSelection(anchorRow: row, anchorColumn: column, rows: [row]))
            return .object(["pane": .string(pane), "row": .number(Double(row))])
        }
    ))

    await registry.register(Action(
        name: "pane_select_rows",
        description: "Select several rows in a pane. anchor names which of them carries "
            + "the anchor, and is added to the set if it is not already in it. Row indices "
            + "are ZERO-BASED positions in the order currently displayed, which a sort "
            + "changes — [0,1,2] is the top three rows on screen. They are positions, never "
            + "values in the data: to select the rows whose ids are 1, 2 and 3, read the "
            + "pane and find which positions those rows currently occupy, or run a query "
            + "that returns only them.",
        kind: .control,
        audience: .agentReachable,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "pane": .object(["type": .string("string")]),
                "rows": .object([
                    "type": .string("array"), "items": .object(["type": .string("number")]),
                ]),
                "anchor": .object(["type": .string("number")]),
                "column": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("pane"), .string("rows")]),
        ]),
        handler: { params in
            let pane = try requireString(params, "pane", action: "pane_select_rows")
            try await requireDataSurfacePane(pane, action: "pane_select_rows", layout: layout)
            guard case .object(let obj) = params, case .array(let rowValues)? = obj["rows"] else {
                throw LayoutActionError.missingParam(action: "pane_select_rows", param: "rows")
            }
            var rows: Set<Int> = []
            for value in rowValues {
                // `intValue` plus an explicit `>= 0` rather than an inline
                // `Int(number)`: a `1e300` inside this array trapped
                // exactly as surely as one in `row` did (final review
                // Finding 2), and one element being unusable must refuse
                // the call rather than end the process.
                guard let row = value.intValue, row >= 0 else {
                    throw LayoutActionError.badParam(
                        action: "pane_select_rows", param: "rows", value: "\(value)")
                }
                rows.insert(row)
            }
            var anchor: Int?
            if obj["anchor"] != nil {
                anchor = try requireRowIndex(params, "anchor", action: "pane_select_rows")
            } else {
                anchor = rows.min()
            }
            await panes.setSelection(
                paneId: pane,
                PaneSelection(
                    anchorRow: anchor, anchorColumn: optionalString(params, "column"), rows: rows))
            return .object(["pane": .string(pane), "rowCount": .number(Double(rows.count))])
        }
    ))

    await registry.register(Action(
        name: "pane_set_column_width",
        description: "Set one column's width in a pane, in points. Persisted with the pane.",
        kind: .control,
        audience: .agentReachable,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "pane": .object(["type": .string("string")]),
                "column": .object(["type": .string("string")]),
                "width": .object(["type": .string("number")]),
            ]),
            "required": .array([.string("pane"), .string("column"), .string("width")]),
        ]),
        handler: { params in
            let pane = try requireString(params, "pane", action: "pane_set_column_width")
            try await requireDataSurfacePane(pane, action: "pane_set_column_width", layout: layout)
            let column = try requireString(params, "column", action: "pane_set_column_width")
            guard case .object(let obj) = params, let width = obj["width"]?.doubleValue,
                  width > 0
            else {
                throw LayoutActionError.badParam(
                    action: "pane_set_column_width", param: "width", value: "\(params)")
            }
            await layout.setColumnWidth(id: pane, column: column, width: width)
            return .object(["pane": .string(pane), "column": .string(column),
                            "width": .number(width)])
        }
    ))

    await registry.register(Action(
        name: "pane_scroll_to_row",
        description: "Bring a row into view in a pane. row is a ZERO-BASED position in "
            + "the order currently displayed, which a sort changes — row 0 is the top row.",
        kind: .control,
        audience: .agentReachable,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "pane": .object(["type": .string("string")]),
                "row": .object(["type": .string("number")]),
            ]),
            "required": .array([.string("pane"), .string("row")]),
        ]),
        handler: { params in
            let pane = try requireString(params, "pane", action: "pane_scroll_to_row")
            try await requireDataSurfacePane(pane, action: "pane_scroll_to_row", layout: layout)
            let row = try requireRowIndex(params, "row", action: "pane_scroll_to_row")
            await panes.setScrollTarget(paneId: pane, row: row)
            return .object(["pane": .string(pane), "row": .number(Double(row))])
        }
    ))

    await registry.register(Action(
        name: "pane_scroll_clear",
        description: "Clear a pane's pending scroll target. The data surface dispatches "
            + "this itself once it has scrolled, so the same row can be asked for again.",
        kind: .control,
        audience: .agentReachable,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "pane": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("pane")]),
        ]),
        handler: { params in
            let pane = try requireString(params, "pane", action: "pane_scroll_clear")
            try await requireDataSurfacePane(pane, action: "pane_scroll_clear", layout: layout)
            await panes.setScrollTarget(paneId: pane, row: nil)
            return .object(["pane": .string(pane)])
        }
    ))
}

/// A row index: present, a number, non-negative, whole, and small enough to
/// *be* an index.
///
/// Whole matters as much as non-negative. A `row` of 3.5 from an agent is a
/// mistake, and `Int(3.5)` would silently make it 3 — a selection one row
/// off from what was asked for, with nothing anywhere saying so.
///
/// **The magnitude check is what keeps this a refusal rather than a
/// crash** (final review Finding 2). `Int(1e300)` and `Int(Double.nan)`
/// trap: they do not return a wrong index, they take the process down.
/// This is the surface an agent types a row number into, over MCP or
/// through `--dispatch`, so `1e300` here was a remotely reachable SIGTRAP
/// (verified: exit 133). `safeInt` — written for the *projection* against
/// this exact hazard and, until now, not used on the way in — is the same
/// guard, shared rather than copied, so the two cannot drift.
private func requireRowIndex(_ params: JSONValue, _ key: String, action: String) throws -> Int {
    guard case .object(let obj) = params else {
        throw LayoutActionError.missingParam(action: action, param: key)
    }
    guard let value = obj[key] else {
        throw LayoutActionError.missingParam(action: action, param: key)
    }
    guard let row = value.intValue, row >= 0 else {
        throw LayoutActionError.badParam(action: action, param: key, value: "\(value)")
    }
    return row
}
