import Testing
@testable import WakilKit

/// **A pane's tab strip when its tabs do not fit** (3c-i's overflow ruling, shared with the editor
/// since the compact chrome): shrink first (or keep each width), then scroll with a count on each
/// side that hides entries.
@Suite struct TabStripLayoutTests {
    /// `count` entries `width` wide, `gap` between each two, from x = 0.
    private func spans(_ count: Int, width: Double = 100, gap: Double = 5) -> [ClosedRange<Double>] {
        (0..<count).map { i in
            let x = Double(i) * (width + gap)
            return x...(x + width)
        }
    }

    @Test func entriesKeepTheirWidthWhileTheyFit() {
        let w = TabStripLayout.widths(count: 3, available: 800, separator: 5)
        #expect(w == .init(active: 200, other: 200, overflows: false))
        // Exactly full: 4 × 200 + 3 × 5.
        #expect(TabStripLayout.widths(count: 4, available: 815, separator: 5).other == 200)
    }

    @Test func entriesShrinkEvenlyBeforeTheActiveMinimum() {
        // 5 entries in 800: (800 − 20) / 5 = 156, all alike.
        let w = TabStripLayout.widths(count: 5, available: 800, separator: 5)
        #expect(w == .init(active: 156, other: 156, overflows: false))
    }

    @Test func theActiveEntryStaysReadableWhileTheOthersShrink() {
        // 7 entries in 800: even would be 110; the active keeps 140, the six others share
        // 800 − 30 − 140 = 630, 105 each.
        let w = TabStripLayout.widths(count: 7, available: 800, separator: 5)
        #expect(w == .init(active: 140, other: 105, overflows: false))
        #expect(w.active == TabStripLayout.activeMinWidth)
    }

    @Test func belowTheMinimumTheStripOverflows() {
        // 15 entries in 800, the operator's screenshot: 96 each, the active 140, and scrolling.
        let w = TabStripLayout.widths(count: 15, available: 800, separator: 5)
        #expect(w == .init(active: 140, other: 96, overflows: true))
        // The last count that fits: 140 + (n − 1) × 101 − 5 ≤ 800 → n = 7.
        #expect(!TabStripLayout.widths(count: 7, available: 800, separator: 5).overflows)
        #expect(TabStripLayout.widths(count: 8, available: 800, separator: 5).overflows)
    }

    @Test func oneEntryAndNoEntries() {
        #expect(TabStripLayout.widths(count: 1, available: 800, separator: 5).active == 200)
        #expect(TabStripLayout.widths(count: 1, available: 160, separator: 5).active == 160)
        #expect(!TabStripLayout.widths(count: 0, available: 10, separator: 5).overflows)
    }

    @Test func aFoldedStripOverflowsPastItsFixedWidths() {
        #expect(!TabStripLayout.overflows(count: 5, width: 68, available: 400, separator: 5))
        #expect(TabStripLayout.overflows(count: 6, width: 68, available: 400, separator: 5))
    }

    @Test func entriesThatKeepTheirWidthOverflowOnlyPastTheirWhole() {
        // The editor's strip: names at their own width, 5 pt between them.
        let s = spans(4) // 0…100 … 315…415
        let content = s.last!.upperBound
        #expect(!TabStripLayout.overflows(contentWidth: content, available: 415))
        // Half a point of rounding is not an overflow.
        #expect(!TabStripLayout.overflows(contentWidth: content, available: 414.5))
        #expect(TabStripLayout.overflows(contentWidth: content, available: 400))
        // Nothing open overflows nothing.
        #expect(!TabStripLayout.overflows(contentWidth: 0, available: 0))
    }

    @Test func hiddenCountsFollowTheScroll() {
        let s = spans(10) // 0…100, 105…205, … 945…1045
        #expect(TabStripLayout.hidden(spans: s, offset: 0, viewport: 1045) == .none)
        // At the start, 420 wide: four wholly shown (the fourth ends at 415), six to the right.
        #expect(TabStripLayout.hidden(spans: s, offset: 0, viewport: 420) == .init(left: 0, right: 6))
        // A cut entry counts as hidden: 400 wide cuts the fourth (315…415).
        #expect(TabStripLayout.hidden(spans: s, offset: 0, viewport: 400) == .init(left: 0, right: 7))
        // Scrolled to 210: the first two are gone on the left (the second ends at 205).
        #expect(TabStripLayout.hidden(spans: s, offset: 210, viewport: 420) == .init(left: 2, right: 4))
        // At the end.
        #expect(TabStripLayout.hidden(spans: s, offset: 625, viewport: 420) == .init(left: 6, right: 0))
        // Half a point of rounding is not hiding.
        #expect(TabStripLayout.hidden(spans: s, offset: 0.5, viewport: 1045) == .none)
    }

    @Test func hiddenCountsFollowTabsOpeningAndClosing() {
        #expect(TabStripLayout.hidden(spans: spans(10), offset: 0, viewport: 420).right == 6)
        #expect(TabStripLayout.hidden(spans: spans(12), offset: 0, viewport: 420).right == 8)
        #expect(TabStripLayout.hidden(spans: spans(4), offset: 0, viewport: 420) == .none)
    }

    @Test func aCountPagesTowardTheHiddenEntries() {
        let s = spans(10)
        // Right from the start: the first entry not wholly shown (index 4, at 420 wide) leads.
        #expect(TabStripLayout.pageTarget(.right, spans: s, offset: 0, viewport: 420) == 4)
        #expect(TabStripLayout.pageTarget(.left, spans: s, offset: 0, viewport: 420) == nil)
        // Left from 420 (index 4 at the left edge): index 3 comes in at the right edge.
        #expect(TabStripLayout.pageTarget(.left, spans: s, offset: 420, viewport: 420) == 3)
        // Cut on the left counts: at 450, index 4 (420…520) is cut, and it is the target.
        #expect(TabStripLayout.pageTarget(.left, spans: s, offset: 450, viewport: 420) == 4)
        #expect(TabStripLayout.pageTarget(.right, spans: s, offset: 625, viewport: 420) == nil)
    }

    @Test func onlyAnEntryOutOfViewIsScrolledTo() {
        let span = 420.0...520.0
        func needs(_ offset: Double, viewport: Double = 420) -> Bool {
            TabStripLayout.needsReveal(span, offset: offset, viewport: viewport, margin: 24, contentWidth: 1045)
        }
        #expect(!needs(300))
        #expect(needs(0))
        #expect(needs(500))
        // Under the faded edge is not in view.
        #expect(needs(110))
        #expect(!needs(130))
        // Before the strip has a width, nothing moves.
        #expect(!needs(0, viewport: 0))
    }

    @Test func anEntryWhollyOutOfSightIsScrolledTo() {
        // The fifteenth of fifteen, a new tab, while the strip is still at its start.
        let s = spans(15) // the last at 1470…1570
        #expect(TabStripLayout.needsReveal(s[14], offset: 0, viewport: 600, margin: 24, contentWidth: 1570))
        // Centred is past the end, so it is held at the end: 1570 − 600.
        #expect(TabStripLayout.revealOffset(s[14], viewport: 600, contentWidth: 1570) == 970)
        // There it is in view: the content's end has no fade.
        #expect(!TabStripLayout.needsReveal(s[14], offset: 970, viewport: 600, margin: 24, contentWidth: 1570))
        // The first from the end: held at 0, and in view there.
        #expect(TabStripLayout.revealOffset(s[0], viewport: 600, contentWidth: 1570) == 0)
        #expect(!TabStripLayout.needsReveal(s[0], offset: 0, viewport: 600, margin: 24, contentWidth: 1570))
        // A middle one is centred: 735…835 → 785 − 300.
        #expect(TabStripLayout.revealOffset(s[7], viewport: 600, contentWidth: 1570) == 485)
    }

    @Test func aPageScrollsTheTargetClearOfTheFade() {
        let s = spans(10)
        // Right from the start: index 4 (420…520) to the left edge, less the fade.
        #expect(TabStripLayout.pageOffset(.right, spans: s, offset: 0, viewport: 420, margin: 24) == 396)
        // Left from 420: index 3 (315…415) to the right edge, plus the fade.
        #expect(TabStripLayout.pageOffset(.left, spans: s, offset: 420, viewport: 420, margin: 24) == 19)
        // Held inside the content, and nothing to do at the ends.
        #expect(TabStripLayout.pageOffset(.right, spans: s, offset: 600, viewport: 420, margin: 24) == 625)
        #expect(TabStripLayout.pageOffset(.right, spans: s, offset: 625, viewport: 420, margin: 24) == nil)
        #expect(TabStripLayout.pageOffset(.left, spans: s, offset: 0, viewport: 420, margin: 24) == nil)
    }
}
