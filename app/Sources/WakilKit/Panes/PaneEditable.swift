import Foundation

/// What a result reported about being written back to —
/// `wakilcore.Editable`, carried through.
///
/// **`nil` means "not editable", and the driver is the only thing that
/// decides it.** Nothing in Swift parses SQL, names a table, or knows what
/// a primary key is; this type holds an answer rather than computing one.
///
/// **`rowKeys` are opaque.** Each is a `WHERE` predicate the driver
/// rendered at read time from the values the engine returned, and Swift's
/// only permitted operations on one are to store it, reorder it with its
/// row, and hand it back. It must never be parsed, split, concatenated or
/// built — that is 2c-ii's "Swift never composes SQL" rule, and the reason
/// these are text at all: a key above 2^53 could not cross as a number.
public struct PaneEditable: Sendable, Equatable {
    public let table: String
    public let keyColumns: [String]
    /// The result columns that may be written to. Never includes a key
    /// column: editing a key changes the row's identity and invalidates
    /// every `rowKey` this value holds.
    public let columns: [String]
    /// Positionally aligned with the pane's rows **in the order they are
    /// displayed** — see `PaneStore`, which permutes these with the rows
    /// whenever a client-side sort reorders them.
    public let rowKeys: [String]

    public init(table: String, keyColumns: [String], columns: [String], rowKeys: [String]) {
        self.table = table
        self.keyColumns = keyColumns
        self.columns = columns
        self.rowKeys = rowKeys
    }

    /// This value with its row keys in another order — the permutation a
    /// client-side sort produced.
    ///
    /// **An out-of-range index fails the WHOLE reorder closed, rather than
    /// being dropped (Fix Round 1 Critical).** `rowKeys` is `[String]`, not
    /// `[String?]`, so there is no "hole" to leave in a bad slot's place —
    /// and `compactMap`-ing the bad slot out, which is what this did before
    /// the fix, shifts every later key down by one index. That is not a
    /// cosmetic gap: `editableCell(row: i)` would then hand back row
    /// `i+1`'s key, and a write composed from it edits the wrong row. So
    /// one invalid index invalidates every row in the result — no row
    /// becomes editable under a key that might not be its own — rather
    /// than only the bad one being dropped and the rest silently
    /// misaligning.
    ///
    /// A permutation SHORTER than `rowKeys` is the safe, ordinary case and
    /// is not this failure: every index it contains is still valid, so the
    /// rows past the permutation's end simply have no entry — exactly like
    /// an ordinary short `rowKeys`, which `editableCell` already treats as
    /// "not editable" rather than an error.
    public func reordered(by permutation: [Int]) -> PaneEditable {
        guard permutation.allSatisfy({ rowKeys.indices.contains($0) }) else {
            return PaneEditable(table: table, keyColumns: keyColumns, columns: columns, rowKeys: [])
        }
        return PaneEditable(
            table: table, keyColumns: keyColumns, columns: columns,
            rowKeys: permutation.map { rowKeys[$0] })
    }
}

/// The row key for a cell that may be edited, or `nil`.
///
/// **The one predicate the view asks, and it lives here** for the reason
/// `shouldAdoptSubject`, `offersDrill` and `queryLineDatabase` do:
/// `WakilApp` has no test target and cannot have one, and this decides
/// whether a double-click turns a cell into an input.
///
/// **`!editable.keyColumns.contains(column)` is defence in depth, not the
/// only guard.** `paneEditable(from:)` already builds `columns` to exclude
/// every key column, so a driver that honours its own contract never
/// offers one here. But `editableCell` is the last thing standing between
/// a double-click and a composed `UPDATE`, and it should not depend on the
/// driver alone having gotten that right.
public func editableCell(_ editable: PaneEditable?, column: String, row: Int) -> String? {
    guard let editable, editable.columns.contains(column),
          !editable.keyColumns.contains(column),
          row >= 0, editable.rowKeys.indices.contains(row)
    else { return nil }
    return editable.rowKeys[row]
}

/// The footer's trailing label.
///
/// **The footer has always ended with a fixed `read-only`.** It is one of
/// the three segments D9 established must survive narrowing, and it is now
/// carrying a fact rather than a constant: `design-language.md` §8's rule
/// is that a surface which cannot do the thing must not look like it can —
/// and its other half, which this is, is that one which can must not look
/// like it cannot.
///
/// **Two states, not four.** The spec sketches per-reason wording
/// (`read-only · more than one table`, `· no primary key`, `· key not in
/// result`, `· derived column`), but composing that needs the driver to
/// say *why* it declined, and `wakilcore.Editable` carries no such reason
/// — it is `nil` or it is not. Inventing four sentences here would be
/// guessing at an explanation the code does not have. Adding one would
/// mean a `reason` field on the Go side, beside the recogniser that
/// already decides `nil` vs. not; until then this stays two states, and
/// whether an operator can live without the "why" is a question for the
/// acceptance walk, not this function.
public func editabilityLabel(_ editable: PaneEditable?) -> String {
    editable == nil ? "read-only" : "editable"
}

/// Reads `key` out of `block` as an array of strings.
///
/// **`strict` decides what a non-string element inside the array does,
/// and the choice matters because `compactMap`-ing it away is only
/// sometimes free.** `keyColumns` and `columns` pass `false`: a stray
/// non-string entry there just isn't a key or a writable column, so
/// dropping it costs nothing — the array's MEANING does not depend on
/// its position. `rowKeys` MUST pass `true`, because its meaning is
/// nothing BUT position: `rowKeys[i]` names row `i`. Dropping a bad
/// element at index 4 does not just lose row 4 — it retitles row 5 as
/// row 4, row 6 as row 5, and so on for everything after it, which is
/// silent, plausible-looking, and exactly the wrong-row write this
/// whole feature exists to prevent. A strict array therefore fails
/// CLOSED as a whole (`nil`) the moment it meets one non-string element,
/// rather than compacting around the hole. (Do not "simplify" this back
/// to one `compactMap` shared by all three keys — that is the bug.)
///
/// Absent or not-an-array is not itself malformed here, `strict` or not:
/// that reads as `[]`, matching every caller's existing "empty means no
/// columns / no keys / no rows" fallback.
private func stringArray(_ block: [String: JSONValue], _ key: String, strict: Bool) -> [String]? {
    guard case .array(let values)? = block[key] else { return [] }
    if strict {
        var out: [String] = []
        out.reserveCapacity(values.count)
        for value in values {
            guard case .string(let s) = value else { return nil }
            out.append(s)
        }
        return out
    }
    return values.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
}

/// Reads `wakilcore.Editable` out of a tool result's `structuredContent`.
///
/// Anything missing, malformed, or naming no table / no key / no writable
/// column yields `nil` — a surface that trusted a half-formed block would
/// offer an edit it cannot compose. A `rowKeys` array with a non-string
/// element is the same "malformed" outcome, for the reason `stringArray`'s
/// doc comment gives: there is no safe way to drop just that element.
public func paneEditable(from structured: [String: JSONValue]) -> PaneEditable? {
    guard case .object(let block)? = structured["editable"],
          case .string(let table)? = block["table"], !table.isEmpty
    else { return nil }
    // `??` never fires here — `stringArray` only returns `nil` when
    // `strict` is `true` — but the type stays `[String]?` regardless of
    // the call site, so the fallback is written to be honest about that
    // rather than force-unwrapped on an invariant future code could break.
    let keyColumns = stringArray(block, "keyColumns", strict: false) ?? []
    let columns = stringArray(block, "columns", strict: false) ?? []
    guard !keyColumns.isEmpty, !columns.isEmpty else { return nil }
    guard let rowKeys = stringArray(block, "rowKeys", strict: true) else { return nil }
    return PaneEditable(table: table, keyColumns: keyColumns, columns: columns, rowKeys: rowKeys)
}
