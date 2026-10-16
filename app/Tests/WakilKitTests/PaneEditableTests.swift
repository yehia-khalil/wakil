import Testing
@testable import WakilKit

private let sample = PaneEditable(
    table: "events", keyColumns: ["id"], columns: ["kind", "note"],
    rowKeys: [#""id" = '1'"#, #""id" = '2'"#])

@Test func anEditableCellReportsItsRowKey() {
    #expect(editableCell(sample, column: "kind", row: 0) == #""id" = '1'"#)
    #expect(editableCell(sample, column: "note", row: 1) == #""id" = '2'"#)
}

@Test func aKeyColumnIsNotEditable() {
    #expect(editableCell(sample, column: "id", row: 0) == nil)
}

@Test func aKeyColumnIsRefusedEvenIfItWereMistakenlyListedAsWritable() {
    // `sample.columns` never includes "id" (`paneEditable(from:)` builds
    // it that way), so `aKeyColumnIsNotEditable` above passes on the
    // `columns.contains` check alone and never exercises the
    // `keyColumns.contains` guard `editableCell` also carries. This
    // constructs the case that guard exists for: a value whose `columns`
    // wrongly includes a key column, to confirm `editableCell` still
    // refuses it rather than trusting the driver alone to have gotten
    // that right.
    let misdeclared = PaneEditable(
        table: "events", keyColumns: ["id"], columns: ["id", "kind"],
        rowKeys: [#""id" = '1'"#])
    #expect(editableCell(misdeclared, column: "id", row: 0) == nil)
}

@Test func anUnknownColumnOrRowIsNotEditable() {
    #expect(editableCell(sample, column: "nope", row: 0) == nil)
    #expect(editableCell(sample, column: "kind", row: 9) == nil)
    #expect(editableCell(sample, column: "kind", row: -1) == nil)
    #expect(editableCell(nil, column: "kind", row: 0) == nil)
}

@Test func theProjectionReadsAnEditableBlock() {
    let structured: [String: JSONValue] = [
        "editable": .object([
            "table": .string("events"),
            "keyColumns": .array([.string("id")]),
            "columns": .array([.string("kind")]),
            "rowKeys": .array([.string(#""id" = '1'"#)]),
        ]),
    ]
    let editable = paneEditable(from: structured)
    #expect(editable?.table == "events")
    #expect(editable?.columns == ["kind"])
    #expect(editable?.rowKeys == [#""id" = '1'"#])
}

@Test func anAbsentOrMalformedBlockIsNotEditable() {
    #expect(paneEditable(from: [:]) == nil)
    #expect(paneEditable(from: ["editable": .null]) == nil)
}

// The three cases below used to be one `#expect`, over a block naming an
// empty table AND no `keyColumns` — which fails for two reasons at once
// and so proved neither one. Split so each fails for exactly one: naming
// no table, naming no key column, and naming no writable column, with
// everything else present and valid.

@Test func aBlockNamingNoTableIsNotEditable() {
    #expect(paneEditable(from: [
        "editable": .object([
            "table": .string(""),
            "keyColumns": .array([.string("id")]),
            "columns": .array([.string("kind")]),
        ]),
    ]) == nil)
}

@Test func aBlockNamingNoKeyColumnIsNotEditable() {
    #expect(paneEditable(from: [
        "editable": .object([
            "table": .string("events"),
            "keyColumns": .array([]),
            "columns": .array([.string("kind")]),
        ]),
    ]) == nil)
}

@Test func aBlockNamingNoWritableColumnIsNotEditable() {
    #expect(paneEditable(from: [
        "editable": .object([
            "table": .string("events"),
            "keyColumns": .array([.string("id")]),
            "columns": .array([]),
        ]),
    ]) == nil)
}

@Test func aRowKeysArrayWithANonStringElementFailsTheWholeBlockClosed() {
    // `stringArray`'s doc comment: dropping the bad element with
    // `compactMap` would shift every later row's key down one index,
    // which is the wrong-row write this whole feature exists to prevent.
    // The safe answer is not "drop the bad one" — it is "trust none of
    // them", so the entire block reads as not editable.
    #expect(paneEditable(from: [
        "editable": .object([
            "table": .string("events"),
            "keyColumns": .array([.string("id")]),
            "columns": .array([.string("kind")]),
            "rowKeys": .array([.string(#""id" = '1'"#), .number(2), .string(#""id" = '3'"#)]),
        ]),
    ]) == nil)
}

// MARK: - `reordered(by:)`

@Test func reorderedAppliesAValidPermutation() {
    let reordered = sample.reordered(by: [1, 0])
    #expect(reordered.rowKeys == [#""id" = '2'"#, #""id" = '1'"#])
    // Everything but the row keys is untouched by a reorder.
    #expect(reordered.table == sample.table)
    #expect(reordered.keyColumns == sample.keyColumns)
    #expect(reordered.columns == sample.columns)
}

@Test func reorderedByAShorterPermutationLeavesTheTailRowsUneditable() {
    // Every index here is valid — this is not the failure case below,
    // it is the ordinary "fewer rows than before" case, and it must not
    // be confused with one. The result is simply shorter, exactly like
    // any other short `rowKeys` `editableCell` already treats as
    // "nothing past here is editable".
    let reordered = sample.reordered(by: [1])
    #expect(reordered.rowKeys == [#""id" = '2'"#])
    #expect(editableCell(reordered, column: "kind", row: 1) == nil)
}

@Test func reorderedByAPermutationWithAnOutOfRangeIndexFailsClosed() {
    // The Fix Round 1 Critical: `[0, 9, 2]` over two keys used to
    // `compactMap` the out-of-range `9` and the out-of-range `2` away,
    // leaving `[rowKeys[0]]` — which silently hands display row 0 the
    // key for logical row 0 while rows 1 and 2 vanish rather than
    // erroring, and a permutation with the bad index NOT at the end
    // (e.g. `[9, 0]`) would instead misalign every row after it. Either
    // way, no row's key may be trusted once one index doesn't resolve —
    // so every row in the result becomes uneditable, not just the row
    // named by the bad index.
    let reordered = sample.reordered(by: [0, 9])
    #expect(reordered.rowKeys == [])
    #expect(editableCell(reordered, column: "kind", row: 0) == nil)
}

@Test func reorderedByAnEmptyPermutationIsEmptyAndSafe() {
    let reordered = sample.reordered(by: [])
    #expect(reordered.rowKeys == [])
}

// MARK: - `editabilityLabel`

@Test func theFooterSaysWhetherTheResultCanBeEdited() {
    #expect(editabilityLabel(sample) == "editable")
    #expect(editabilityLabel(nil) == "read-only")
}
