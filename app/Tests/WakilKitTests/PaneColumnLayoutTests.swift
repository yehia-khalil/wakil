import Foundation
import Testing
@testable import WakilKit

@Test func columnsWithNoOverrideDivideTheSpaceEvenly() {
    let widths = paneColumnLayout(
        columns: ["a", "b", "c"], overrides: [:], availableWidth: 332, horizontalSpacing: 16)
    // (332 - 32) / 3 = 100 each, the same arithmetic paneColumnWidth does.
    #expect(widths == [100, 100, 100])
}

@Test func anOverriddenColumnKeepsItsWidthAndTheRestDivideWhatIsLeft() {
    let widths = paneColumnLayout(
        columns: ["a", "b", "c"], overrides: ["b": 200], availableWidth: 432,
        horizontalSpacing: 16)
    // 432 - 32 spacing = 400; b takes 200; a and c split the remaining 200.
    #expect(widths == [100, 200, 100])
}

@Test func overridesAreKeyedByNameSoReorderingDoesNotMisapplyThem() {
    // The reason columnWidths is a dictionary and not an array: a query
    // returning the same columns in a different order must not hand one
    // column's width to another.
    let forward = paneColumnLayout(
        columns: ["a", "b"], overrides: ["b": 200], availableWidth: 316, horizontalSpacing: 16)
    let reversed = paneColumnLayout(
        columns: ["b", "a"], overrides: ["b": 200], availableWidth: 316, horizontalSpacing: 16)
    #expect(forward == [100, 200])
    #expect(reversed == [200, 100])
}

@Test func aColumnNeverShrinksBelowTheFloor() {
    // Once there are enough columns the floored total exceeds the pane's
    // width on its own — `select *` against a twenty-column table is an
    // ordinary query, not a corner case. The floor is what makes horizontal
    // scrolling the escape hatch rather than a fallback: the cap divides
    // the width fairly when the columns fit, and the ScrollView carries
    // them when the floor says they cannot.
    let widths = paneColumnLayout(
        columns: (0..<20).map { "c\($0)" }, overrides: [:], availableWidth: 400,
        horizontalSpacing: 16)
    #expect(widths.allSatisfy { $0 == 60 })
}

@Test func overridesAloneCanExceedTheWidthAndAreStillHonoured() {
    // An operator who dragged a column to 400pt meant it. The surface
    // scrolls horizontally; it does not silently undo the drag.
    let widths = paneColumnLayout(
        columns: ["a", "b"], overrides: ["a": 400, "b": 400], availableWidth: 300,
        horizontalSpacing: 16)
    #expect(widths == [400, 400])
}

@Test func noColumnsIsNoWidths() {
    #expect(paneColumnLayout(
        columns: [], overrides: [:], availableWidth: 400, horizontalSpacing: 16).isEmpty)
}

// MARK: - The content width the columns are divided across (walk defect D1)

/// **The defect, stated as arithmetic.** `paneColumnLayout` divides its
/// `availableWidth` so the columns plus their spacing sum to exactly it, and
/// `DataSurface` pins the row's `minWidth` to the same number — so if that
/// number is the surface's width rather than the row viewport's, the content
/// is wider than the space it has by however much the vertical scroller
/// took, and the pane scrolls sideways with room to spare.
///
/// Three columns in 700pt is the walk's own case: they fit, and it scrolled.
@Test func columnsAreDividedAcrossTheViewportRatherThanTheWholeSurface() {
    let surface = 700.0
    let scroller = 15.0
    let content = paneContentWidth(
        surfaceWidth: surface, verticalScrollerAllowance: scroller)
    #expect(content == 685)

    let widths = paneColumnLayout(
        columns: ["id", "customer_id", "kind"], overrides: [:],
        availableWidth: content, horizontalSpacing: 16)
    // What the rows will actually occupy: every column, plus the gaps
    // between them.
    let occupied = widths.reduce(0, +) + 16 * Double(widths.count - 1)
    #expect(occupied == content)
    // The whole point: it fits inside the viewport, with the scroller's
    // width still unspent.
    #expect(occupied <= surface - scroller)
}

/// An overlay scroller floats above the content and takes no layout width,
/// so on a machine set that way there is nothing to reserve and this must
/// not quietly shrink every pane by 15pt.
@Test func anOverlayScrollerCostsTheSurfaceNothing() {
    #expect(paneContentWidth(surfaceWidth: 700, verticalScrollerAllowance: 0) == 700)
}

/// A pane narrower than one column's floor cannot be made narrower still by
/// the allowance — the layout below it already refuses to go under the
/// floor, and returning a negative width here would put the two in
/// disagreement about the same pane.
@Test func theAllowanceCannotDriveTheContentWidthBelowOneColumn() {
    #expect(paneContentWidth(surfaceWidth: 10, verticalScrollerAllowance: 15)
        == paneColumnMinimumWidth)
    // A nonsense negative allowance is clamped rather than trusted: it
    // would otherwise GROW the content past the surface, which is the
    // defect again in the other direction.
    #expect(paneContentWidth(surfaceWidth: 700, verticalScrollerAllowance: -40) == 700)
}
