import Foundation
import Testing
@testable import WakilKit

/// Fix round 1, Finding 1 (Critical): `DataSurface.select(row:column:)`'s
/// command-click branch computed `rows.remove(row)` and then dispatched
/// `"anchor": .number(Double(row))` — the very row just removed.
/// `PaneSelection.init` unconditionally unions `anchorRow` back into
/// `rows`, so the removal was undone the instant it landed and command-click
/// could only ever ADD rows. These tests pin the correct behaviour in
/// `WakilKit`, where it can be tested — the same reason `paneColumnLayout`
/// lives here rather than in the view.

@Test func plainClickCollapsesAMultiRowSelectionToTheClickedRow() {
    let current = PaneSelection(anchorRow: 2, anchorColumn: "id", rows: [1, 2, 3])
    let next = paneSelectionAfterClick(current: current, row: 5, column: "name", modifier: .plain)
    #expect(next.rows == [5])
    #expect(next.anchorRow == 5)
    #expect(next.anchorColumn == "name")
}

@Test func shiftExtendsDownwardFromTheAnchor() {
    let current = PaneSelection(anchorRow: 2, anchorColumn: "id", rows: [2])
    let next = paneSelectionAfterClick(current: current, row: 5, column: "id", modifier: .shift)
    #expect(next.rows == [2, 3, 4, 5])
    // Shift never moves the anchor — only the clicked click's own row does.
    #expect(next.anchorRow == 2)
}

@Test func shiftExtendsUpwardWhenTheClickedRowIsAboveTheAnchor() {
    let current = PaneSelection(anchorRow: 8, anchorColumn: "id", rows: [8])
    let next = paneSelectionAfterClick(current: current, row: 5, column: "id", modifier: .shift)
    #expect(next.rows == [5, 6, 7, 8])
    #expect(next.anchorRow == 8)
}

@Test func shiftWithNoExistingAnchorBehavesLikeAPlainClick() {
    let current = PaneSelection.empty
    let next = paneSelectionAfterClick(current: current, row: 4, column: "id", modifier: .shift)
    #expect(next.rows == [4])
    #expect(next.anchorRow == 4)
}

/// The bug, pinned directly: command-clicking a row already in the
/// selection must actually remove it, and the removal must not be undone
/// by the anchor `PaneSelection.init` unions back in.
@Test func commandClickDeselectsANonAnchorRowAndKeepsTheExistingAnchor() {
    let current = PaneSelection(anchorRow: 1, anchorColumn: "id", rows: [1, 2, 3])
    let next = paneSelectionAfterClick(current: current, row: 3, column: "id", modifier: .command)
    #expect(next.rows == [1, 2])
    // Row 3 was not the anchor, so the anchor the operator already set
    // stays put — it is still a member of `rows`, so there is no reason to
    // move it.
    #expect(next.anchorRow == 1)
}

@Test func commandClickDeselectingTheAnchorRowItselfMovesTheAnchorToASurvivor() {
    let current = PaneSelection(anchorRow: 1, anchorColumn: "id", rows: [1, 2, 3])
    let next = paneSelectionAfterClick(current: current, row: 1, column: "id", modifier: .command)
    #expect(next.rows == [2, 3])
    // The old anchor is gone, so the anchor must move to a row that
    // survives — `rows.min()`, the smallest surviving index. See the
    // function's own doc comment for why `min()` and not, say, "the
    // nearest row below the one removed".
    #expect(next.anchorRow == 2)
}

@Test func commandClickDeselectingTheLastRemainingRowLeavesNoAnchor() {
    let current = PaneSelection(anchorRow: 4, anchorColumn: "id", rows: [4])
    let next = paneSelectionAfterClick(current: current, row: 4, column: "id", modifier: .command)
    #expect(next.rows.isEmpty)
    #expect(next.anchorRow == nil)
}

@Test func commandClickOnARowNotYetSelectedAddsItAndMakesItTheAnchor() {
    let current = PaneSelection(anchorRow: 1, anchorColumn: "id", rows: [1, 2])
    let next = paneSelectionAfterClick(current: current, row: 9, column: "id", modifier: .command)
    #expect(next.rows == [1, 2, 9])
    #expect(next.anchorRow == 9)
}
