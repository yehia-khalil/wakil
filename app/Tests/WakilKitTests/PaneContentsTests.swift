import Foundation
import Testing
@testable import WakilKit

@Test func aNullCellIsDistinguishableFromAnEmptyString() {
    let null = PaneCell(.null)
    let empty = PaneCell(.string(""))
    #expect(null.isNull)
    #expect(!empty.isNull)
    // The text is empty for both; `isNull` is the whole difference, and it
    // is what lets the view draw one as a dimmed NULL and the other as
    // nothing. Before this type existed both rendered as "" and a real NULL
    // was indistinguishable from an empty string on screen.
    #expect(null.text.isEmpty)
    #expect(empty.text.isEmpty)
}

@Test func cellTextMatchesTheOldProjectionForEveryNonNullKind() {
    #expect(PaneCell(.string("widgets")).text == "widgets")
    #expect(PaneCell(.bool(true)).text == "true")
    #expect(PaneCell(.bool(false)).text == "false")
    // An integral number prints without the ".0" String(Double) would add —
    // database ids are the commonest cell here and "1.0" is wrong on sight.
    #expect(PaneCell(.number(1)).text == "1")
    #expect(PaneCell(.number(2.5)).text == "2.5")
    // Past 1e15 a Double stops representing every integer exactly, so an
    // Int64 conversion there would assert precision the value lacks.
    #expect(PaneCell(.number(1e16)).text.contains("e+16"))
    #expect(PaneCell(.array([.number(1)])).text == "[1]")
}

@Test func aColumnWithNoTypeCarriesNil() {
    #expect(PaneColumn(name: "id", type: "INTEGER").type == "INTEGER")
    // An empty type string from the wire is "the driver could not say",
    // which is nil here rather than "" so a view cannot draw an empty
    // annotation and call it an annotation.
    #expect(PaneColumn(name: "id", type: "").type == nil)
    #expect(PaneColumn(name: "id", type: nil).type == nil)
}

@Test func anEmptySelectionHasNoAnchorAndNoRows() {
    #expect(PaneSelection.empty.anchorRow == nil)
    #expect(PaneSelection.empty.anchorColumn == nil)
    #expect(PaneSelection.empty.rows.isEmpty)
}

@Test func aSelectionAlwaysContainsItsAnchorRow() {
    // The anchor is the row §8's luminous edge is drawn on, so a selection
    // whose anchor is outside its own row set would draw that edge on a row
    // the set says is not selected.
    let s = PaneSelection(anchorRow: 4, anchorColumn: "name", rows: [1, 2])
    #expect(s.rows.contains(4))
}

@Test func sortDirectionRoundTripsThroughItsWireName() {
    #expect(PaneSortDirection(rawValue: "asc") == .ascending)
    #expect(PaneSortDirection(rawValue: "desc") == .descending)
    #expect(PaneSortDirection.descending.rawValue == "desc")
}

// MARK: - Client-side sort (Task 12; moved here in the final fix wave)
//
// `sortedRows` moved out of `App/WindowModel.swift` and beside the value
// types it operates on, so `PaneStore` can produce the displayed order
// itself without the pane layer depending on the window layer (final
// review Finding 1). Its tests moved with it, and its comparator is
// unchanged: the assertions below are the ones it was hard-won against.

/// The sorted column's text, which is what every assertion below reads.
private func text(_ rows: [[JSONValue]]) -> [String] {
    rows.map { PaneCell($0[0]).text }
}

@Test func sortingPutsRowsIntoTheirDisplayedPosition() {
    let sorted = sortedRows(
        [[.string("c")], [.string("a")], [.string("b")]],
        by: [PaneSort(column: "name", direction: .ascending)], columns: ["name"])
    #expect(text(sorted) == ["a", "b", "c"])
    // A row's index IS its position in this result. Every row index in
    // this codebase — read_pane's, pane_select_cell's,
    // pane_scroll_to_row's — indexes what is displayed, and this is the
    // one place that order is decided, so the agent and the operator
    // cannot mean different rows by the same number.
    #expect(sorted.firstIndex(of: [.string("a")]) == 0)
}

@Test func numericColumnsSortNumericallyNotLexically() {
    let sorted = sortedRows(
        [[.number(10)], [.number(9)], [.number(100)]],
        by: [PaneSort(column: "id", direction: .ascending)], columns: ["id"])
    // Lexical would give 10, 100, 9 — which looks like a bug to anyone
    // reading it and is one.
    #expect(text(sorted) == ["9", "10", "100"])
}

@Test func nullsSortLastInBothDirections() {
    // A NULL is the absence of a value, so it has no place in an ordering
    // of values. Putting it at the end both ways means a sort never buries
    // the rows the operator asked to see under the rows that have nothing.
    let source: [[JSONValue]] = [[.string("b")], [.null], [.string("a")]]
    let ascending = sortedRows(
        source, by: [PaneSort(column: "name", direction: .ascending)], columns: ["name"])
    let descending = sortedRows(
        source, by: [PaneSort(column: "name", direction: .descending)], columns: ["name"])
    #expect(PaneCell(ascending.last![0]).isNull)
    #expect(PaneCell(descending.last![0]).isNull)
}

@Test func noSortAndAnUnknownColumnBothLeaveTheOrderAlone() {
    let source: [[JSONValue]] = [[.string("c")], [.string("a")]]
    #expect(text(sortedRows(source, by: [], columns: ["name"])) == ["c", "a"])
    // An unknown column is not an error to throw in a projection that has
    // to be total — it is a sort with nothing to sort by.
    #expect(text(sortedRows(
        source, by: [PaneSort(column: "nope", direction: .ascending)],
        columns: ["name"])) == ["c", "a"])
}

/// A column mixing numbers and non-numbers must still give `sorted` a
/// strict weak ordering, or its result is unspecified. `"10"` before
/// `"abc"` (numeric vs. text falls back to `localizedStandardCompare`, and
/// a digit sorts before a letter) and `"9"` before `"10"` (both numeric)
/// compose into one consistent chain: 9 < 10 < abc.
@Test func mixedNumericAndTextValuesStillFormAConsistentOrder() {
    let sorted = sortedRows(
        [[.string("10")], [.string("abc")], [.string("9")]],
        by: [PaneSort(column: "v", direction: .ascending)], columns: ["v"])
    #expect(text(sorted) == ["9", "10", "abc"])
}

/// `Double("nan")` parses successfully in Swift, and IEEE 754 says every
/// comparison against NaN — `<`, `>`, `==` — is `false`. A naive numeric
/// branch that only gates on `ln != rn` would treat the literal text "nan"
/// as a number, compare `false` in both directions against everything else,
/// and so present "nan" as simultaneously "equivalent" to two values that
/// are *not* equivalent to each other — a strict-weak-ordering violation
/// `sorted` does not promise well-defined behaviour under. Guarding the
/// numeric branch on `isFinite` routes it to the text comparison instead,
/// where it sorts like any other three-letter word.
@Test func aTextColumnContainingTheWordNaNSortsConsistently() {
    let sorted = sortedRows(
        [[.string("nan")], [.string("5")], [.string("inf")], [.string("Infinity")]],
        by: [PaneSort(column: "v", direction: .ascending)], columns: ["v"])
    #expect(text(sorted) == ["5", "inf", "Infinity", "nan"])
}

/// A row shorter than the sorted column's index is not a reason to trap or
/// to drop it: it sorts as a NULL, which is where a value that is not
/// there belongs.
@Test func aRowTooShortForTheSortedColumnSortsAsANull() {
    let sorted = sortedRows(
        [[.string("a"), .string("x")], [.string("b")], [.string("a"), .string("a")]],
        by: [PaneSort(column: "second", direction: .ascending)], columns: ["first", "second"])
    #expect(sorted.count == 3)
    #expect(sorted.last == [.string("b")])
}

// MARK: - Multi-term sort (D5): a list, in precedence order

/// The mechanism the whole task exists for: a second term breaks only the
/// ties the first term left, rather than reordering everything or being
/// dropped. Sorting by `kind` alone would leave the two `"a"` rows in
/// whatever order they arrived; adding `id` decides between them.
@Test func aSecondTermBreaksOnlyTheFirstTermsTies() {
    let rows: [[JSONValue]] = [
        [.string("a"), .number(3)], [.string("b"), .number(1)], [.string("a"), .number(2)],
    ]
    let sorted = sortedRows(
        rows,
        by: [
            PaneSort(column: "kind", direction: .ascending),
            PaneSort(column: "id", direction: .ascending),
        ],
        columns: ["kind", "id"])
    #expect(sorted == [
        [.string("a"), .number(2)], [.string("a"), .number(3)], [.string("b"), .number(1)],
    ])
}

/// The order the terms are given in is the order they are consulted in —
/// naming `id` first makes it decide everything and `kind` never gets a
/// chance to. A test that passed with the terms in either order would not
/// actually be pinning precedence.
@Test func termsAreConsultedInTheOrderGiven() {
    let rows: [[JSONValue]] = [
        [.string("a"), .number(3)], [.string("b"), .number(1)], [.string("a"), .number(2)],
    ]
    let sorted = sortedRows(
        rows,
        by: [
            PaneSort(column: "id", direction: .ascending),
            PaneSort(column: "kind", direction: .ascending),
        ],
        columns: ["kind", "id"])
    #expect(sorted == [
        [.string("b"), .number(1)], [.string("a"), .number(2)], [.string("a"), .number(3)],
    ])
}

/// A term naming a column the pane does not have does not throw — it
/// simply cannot participate — and the terms after it still can.
@Test func anUnknownTermIsSkippedRatherThanStoppingTheWholeSort() {
    let rows: [[JSONValue]] = [[.string("b")], [.string("a")]]
    let sorted = sortedRows(
        rows,
        by: [PaneSort(column: "nope", direction: .ascending),
             PaneSort(column: "name", direction: .ascending)],
        columns: ["name"])
    #expect(text(sorted) == ["a", "b"])
}
