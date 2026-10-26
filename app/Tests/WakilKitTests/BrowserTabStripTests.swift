import Testing
@testable import WakilKit

/// **The browser's tab strip when its tabs do not fit** (3c-i, the overflow ruling): shrink
/// first, then scroll with a count on each side that hides entries.
@Suite struct BrowserTabStripTests {
    /// `count` entries `width` wide, `gap` between each two, from x = 0.
    private func spans(_ count: Int, width: Double = 100, gap: Double = 5) -> [ClosedRange<Double>] {
        (0..<count).map { i in
            let x = Double(i) * (width + gap)
            return x...(x + width)
        }
    }

    @Test func entriesKeepTheirWidthWhileTheyFit() {
        let w = BrowserTabStrip.widths(count: 3, available: 800, separator: 5)
        #expect(w == .init(active: 200, other: 200, overflows: false))
        // Exactly full: 4 × 200 + 3 × 5.
        #expect(BrowserTabStrip.widths(count: 4, available: 815, separator: 5).other == 200)
    }

    @Test func entriesShrinkEvenlyBeforeTheActiveMinimum() {
        // 5 entries in 800: (800 − 20) / 5 = 156, all alike.
        let w = BrowserTabStrip.widths(count: 5, available: 800, separator: 5)
        #expect(w == .init(active: 156, other: 156, overflows: false))
    }

    @Test func theActiveEntryStaysReadableWhileTheOthersShrink() {
        // 7 entries in 800: even would be 110; the active keeps 140, the six others share
        // 800 − 30 − 140 = 630, 105 each.
        let w = BrowserTabStrip.widths(count: 7, available: 800, separator: 5)
        #expect(w == .init(active: 140, other: 105, overflows: false))
        #expect(w.active == BrowserTabStrip.activeMinWidth)
    }

    @Test func belowTheMinimumTheStripOverflows() {
        // 15 entries in 800, the operator's screenshot: 96 each, the active 140, and scrolling.
        let w = BrowserTabStrip.widths(count: 15, available: 800, separator: 5)
        #expect(w == .init(active: 140, other: 96, overflows: true))
        // The last count that fits: 140 + (n − 1) × 101 − 5 ≤ 800 → n = 7.
        #expect(!BrowserTabStrip.widths(count: 7, available: 800, separator: 5).overflows)
        #expect(BrowserTabStrip.widths(count: 8, available: 800, separator: 5).overflows)
    }

    @Test func oneEntryAndNoEntries() {
        #expect(BrowserTabStrip.widths(count: 1, available: 800, separator: 5).active == 200)
        #expect(BrowserTabStrip.widths(count: 1, available: 160, separator: 5).active == 160)
        #expect(!BrowserTabStrip.widths(count: 0, available: 10, separator: 5).overflows)
    }

    @Test func aFoldedStripOverflowsPastItsFixedWidths() {
        #expect(!BrowserTabStrip.overflows(count: 5, width: 68, available: 400, separator: 5))
        #expect(BrowserTabStrip.overflows(count: 6, width: 68, available: 400, separator: 5))
    }

    @Test func hiddenCountsFollowTheScroll() {
        let s = spans(10) // 0…100, 105…205, … 945…1045
        #expect(BrowserTabStrip.hidden(spans: s, offset: 0, viewport: 1045) == .none)
        // At the start, 420 wide: four wholly shown (the fourth ends at 415), six to the right.
        #expect(BrowserTabStrip.hidden(spans: s, offset: 0, viewport: 420) == .init(left: 0, right: 6))
        // A cut entry counts as hidden: 400 wide cuts the fourth (315…415).
        #expect(BrowserTabStrip.hidden(spans: s, offset: 0, viewport: 400) == .init(left: 0, right: 7))
        // Scrolled to 210: the first two are gone on the left (the second ends at 205).
        #expect(BrowserTabStrip.hidden(spans: s, offset: 210, viewport: 420) == .init(left: 2, right: 4))
        // At the end.
        #expect(BrowserTabStrip.hidden(spans: s, offset: 625, viewport: 420) == .init(left: 6, right: 0))
        // Half a point of rounding is not hiding.
        #expect(BrowserTabStrip.hidden(spans: s, offset: 0.5, viewport: 1045) == .none)
    }

    @Test func hiddenCountsFollowTabsOpeningAndClosing() {
        #expect(BrowserTabStrip.hidden(spans: spans(10), offset: 0, viewport: 420).right == 6)
        #expect(BrowserTabStrip.hidden(spans: spans(12), offset: 0, viewport: 420).right == 8)
        #expect(BrowserTabStrip.hidden(spans: spans(4), offset: 0, viewport: 420) == .none)
    }

    @Test func aCountPagesTowardTheHiddenEntries() {
        let s = spans(10)
        // Right from the start: the first entry not wholly shown (index 4, at 420 wide) leads.
        #expect(BrowserTabStrip.pageTarget(.right, spans: s, offset: 0, viewport: 420) == 4)
        #expect(BrowserTabStrip.pageTarget(.left, spans: s, offset: 0, viewport: 420) == nil)
        // Left from 420 (index 4 at the left edge): index 3 comes in at the right edge.
        #expect(BrowserTabStrip.pageTarget(.left, spans: s, offset: 420, viewport: 420) == 3)
        // Cut on the left counts: at 450, index 4 (420…520) is cut, and it is the target.
        #expect(BrowserTabStrip.pageTarget(.left, spans: s, offset: 450, viewport: 420) == 4)
        #expect(BrowserTabStrip.pageTarget(.right, spans: s, offset: 625, viewport: 420) == nil)
    }

    @Test func onlyAnEntryOutOfViewIsScrolledTo() {
        let span = 420.0...520.0
        #expect(!BrowserTabStrip.needsReveal(span, offset: 300, viewport: 420, margin: 24))
        #expect(BrowserTabStrip.needsReveal(span, offset: 0, viewport: 420, margin: 24))
        #expect(BrowserTabStrip.needsReveal(span, offset: 500, viewport: 420, margin: 24))
        // Under the faded edge is not in view.
        #expect(BrowserTabStrip.needsReveal(span, offset: 110, viewport: 420, margin: 24))
        #expect(!BrowserTabStrip.needsReveal(span, offset: 130, viewport: 420, margin: 24))
        // Before the strip has a width, nothing moves.
        #expect(!BrowserTabStrip.needsReveal(span, offset: 0, viewport: 0, margin: 24))
    }
}
