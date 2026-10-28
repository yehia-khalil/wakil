import Testing

@testable import WakilKit

/// 3d-i walk: the pinned section — tiles, then the pinned groups, then the line — and what a drop
/// on either side of the line does.
@Suite("Browser pinned section")
struct BrowserPinnedSectionTests {
    private func tab(_ id: String, group: String? = nil, pin: String? = nil) -> BrowserTab {
        BrowserTab(id: id, url: "https://\(id).test/", title: id, loaded: true, group: group, pin: pin)
    }

    private func group(_ id: String, pin: String? = nil) -> BrowserGroup {
        BrowserGroup(id: id, name: id, colour: .blue, collapsed: false, kind: .own, pin: pin)
    }

    private func pane(_ tabs: [BrowserTab], groups: [BrowserGroup] = []) -> BrowserSnapshot {
        BrowserSnapshot(tabs: tabs, active: tabs.first?.id, find: nil, downloads: [], closed: [],
                        nextTab: tabs.count + 1, groups: groups, nextGroup: groups.count + 1)
    }

    /// t1 t2 pinned; g1 pinned (t3); g2 (t4 t5); t6 loose. Entries:
    /// 0 t1 · 1 t2 · 2 group:g1 · 3 t3 ─line─ 4 group:g2 · 5 t4 · 6 t5 · 7 t6
    private var full: BrowserSnapshot {
        pane([tab("t1", pin: "p1"), tab("t2", pin: "p2"), tab("t3", group: "g1"), tab("t4", group: "g2"),
              tab("t5", group: "g2"), tab("t6")],
             groups: [group("g1", pin: "p3"), group("g2")])
    }

    // MARK: The split

    @Test func theSectionIsThePinnedTabsThenThePinnedGroups() {
        #expect(full.stripEntries.map(\.id) == ["t1", "t2", "group:g1", "t3", "group:g2", "t4", "t5", "t6"])
        #expect(full.pinnedSection == BrowserPinnedSection(tiles: 2, count: 4))
    }

    @Test func withNothingPinnedThereIsNoSection() {
        let s = pane([tab("t1"), tab("t2", group: "g1"), tab("t3", group: "g1")], groups: [group("g1")])
        #expect(s.pinnedSection.isEmpty)
        #expect(BrowserColumnLayout(section: s.pinnedSection, entries: 3, width: 220).bandTop == nil)
    }

    @Test func aPinnedGroupAloneHasNoTilesButASection() {
        let s = pane([tab("t1", group: "g1"), tab("t2")], groups: [group("g1", pin: "p")])
        #expect(s.pinnedSection == BrowserPinnedSection(tiles: 0, count: 2))
    }

    @Test func anUnpinnedTabIsNeverAboveTheLine() {
        let s = full
        let above = s.stripEntries.prefix(s.pinnedSection.count)
        for case .tab(let t) in above { #expect(s.isPinned(t)) }
        for case .tab(let t) in s.stripEntries.dropFirst(s.pinnedSection.count) { #expect(!s.isPinned(t)) }
    }

    // MARK: Tiles per row

    @Test func fourTilesToARowAtTheDefaultWidthAndTheCountFollowsTheWidth() {
        #expect(BrowserColumnLayout.perRow(width: BrowserTabColumnRules.width) == 4)
        #expect(BrowserColumnLayout.perRow(width: 160) == 3)
        #expect(BrowserColumnLayout.perRow(width: 360) == 7)
        // Clamped like the column.
        #expect(BrowserColumnLayout.perRow(width: 40) == 3)
        let widths = stride(from: 160.0, through: 360, by: 10).map(BrowserColumnLayout.perRow)
        #expect(widths == widths.sorted())
    }

    @Test func theGridMeetsBothInsets() {
        for width in stride(from: 160.0, through: 360, by: 20) {
            let l = BrowserColumnLayout(section: BrowserPinnedSection(tiles: 9, count: 9), entries: 9, width: width)
            let last = l.tileOrigin(l.perRow - 1)
            #expect(abs(last.x + l.tileSide - (width - BrowserColumnLayout.inset)) < 0.001)
            #expect(l.tileSide >= BrowserColumnLayout.minTile)
        }
    }

    // MARK: The column's geometry

    @Test func theRowsFollowTheGridThePinnedGroupsAndTheBand() {
        let l = BrowserColumnLayout(section: full.pinnedSection, entries: 8, width: 220)
        #expect(l.tileRows == 1)
        let grid = l.tileSide + BrowserColumnLayout.tileSpacing
        #expect(l.gridHeight == grid)
        #expect(l.rowTop(2) == grid)
        #expect(l.bandTop == grid + 2 * BrowserColumnLayout.rowHeight)
        #expect(l.rowTop(4) == grid + 2 * BrowserColumnLayout.rowHeight + BrowserColumnLayout.band)
        #expect(l.height == l.rowTop(4) + 4 * BrowserColumnLayout.rowHeight)
    }

    @Test func aPointOnTheTilesIsATileSlot() {
        let l = BrowserColumnLayout(section: full.pinnedSection, entries: 8, width: 220)
        let o = l.tileOrigin(1)
        #expect(l.target(x: o.x + 2, y: 10) == (1, true))
        #expect(l.target(x: o.x + l.tileSide - 2, y: 10) == (2, true))
        // Past the last tile, in the row's empty end: after it.
        #expect(l.target(x: 200, y: 10) == (2, true))
        #expect(l.target(x: 0, y: -20) == (0, true))
    }

    @Test func theBandsHalvesAreEitherSideOfTheLine() throws {
        let l = BrowserColumnLayout(section: full.pinnedSection, entries: 8, width: 220)
        let band = try #require(l.bandTop)
        #expect(l.target(x: 50, y: band + 1) == (4, true))
        #expect(l.target(x: 50, y: band + BrowserColumnLayout.band - 1) == (4, false))
        #expect(l.target(x: 50, y: l.rowTop(5) + 2) == (5, false))
        #expect(l.target(x: 50, y: l.height + 200) == (8, false))
        #expect(l.lineY(gap: 4, inSection: true) == band)
        #expect(l.lineY(gap: 4, inSection: false) == l.rowTop(4))
    }

    @Test func withNothingPinnedTheColumnIsRowsAsBefore() {
        let l = BrowserColumnLayout(section: BrowserPinnedSection(tiles: 0, count: 0), entries: 3, width: 220)
        #expect(l.rowTop(0) == 0)
        #expect(l.target(x: 50, y: 30) == (1, false))
        #expect(l.target(x: 50, y: -10) == (0, false))
    }

    @Test func aTileSlotsLineStandsInTheSpaceBeforeOrAfterItsTile() {
        let l = BrowserColumnLayout(section: BrowserPinnedSection(tiles: 6, count: 6), entries: 6, width: 220)
        #expect(l.tileLine(1).x == l.tileOrigin(1).x - BrowserColumnLayout.tileSpacing / 2)
        // A row's end and the last tile: after the tile before.
        #expect(l.tileLine(4).y == l.tileOrigin(3).y)
        #expect(l.tileLine(6).x == l.tileOrigin(5).x + l.tileSide + BrowserColumnLayout.tileSpacing / 2)
    }

    // MARK: Drops

    @Test func aTabDroppedOnTheTilesIsPinnedThere() {
        // t6 (7) onto the tiles' first slot.
        #expect(full.drop(7, gap: 0, inSection: true)
                == BrowserTabDrop(action: "browser_pin", params: ["tab": .string("t6"), "to": .integer(0)]))
        // A group's member too, after the last tile.
        #expect(full.drop(5, gap: 2, inSection: true)
                == BrowserTabDrop(action: "browser_pin", params: ["tab": .string("t4"), "to": .integer(2)]))
    }

    @Test func aPinnedGroupsMemberOnTheTilesDoesNothing() {
        #expect(full.drop(3, gap: 0, inSection: true) == nil)
    }

    @Test func aTileMovesAmongTheTiles() {
        #expect(full.drop(0, gap: 2, inSection: true)
                == BrowserTabDrop(action: "browser_move_tab", params: ["tab": .string("t1"), "to": .integer(1)]))
        #expect(full.drop(0, gap: 1, inSection: true) == nil)
        #expect(full.drop(0, gap: 0, inSection: true) == nil)
    }

    @Test func aTileAmongThePinnedGroupsDoesNothing() {
        #expect(full.drop(0, gap: 3, inSection: true) == nil)
    }

    @Test func aTileDroppedBelowTheLineIsUnpinnedWhereItLands() {
        // Before t6, loose: t6 is index 5 of `tabs` without t1.
        #expect(full.drop(0, gap: 7, inSection: false)
                == BrowserTabDrop(action: "browser_unpin",
                                  params: ["tab": .string("t1"), "to": .integer(4), "into": .string("")]))
        // Between t4 and t5: it joins g2.
        #expect(full.drop(1, gap: 6, inSection: false)
                == BrowserTabDrop(action: "browser_unpin",
                                  params: ["tab": .string("t2"), "to": .integer(3), "into": .string("g2")]))
        // On the line's lower half.
        #expect(full.drop(1, gap: 4, inSection: false)?.action == "browser_unpin")
    }

    @Test func anUnpinnedTabMovesAsItAlwaysHas() {
        // t6 between t4 and t5 joins g2.
        #expect(full.drop(7, gap: 6, inSection: false)
                == BrowserTabDrop(action: "browser_move_tab",
                                  params: ["tab": .string("t6"), "to": .integer(4), "group": .string("g2")]))
        // Back in its place: nothing.
        #expect(full.drop(7, gap: 8, inSection: false) == nil)
        // A header never drags.
        #expect(full.drop(4, gap: 0, inSection: true) == nil)
    }

    @Test func theLinesGapOnTheSectionSideOfATilesOnlySectionPins() {
        let s = pane([tab("t1", pin: "p"), tab("t2"), tab("t3")])
        #expect(s.drop(2, gap: 1, inSection: true)?.action == "browser_pin")
        #expect(s.drop(2, gap: 1, inSection: false)?.action == "browser_move_tab")
        // With nothing pinned there is no section side.
        let none = pane([tab("t1"), tab("t2")])
        #expect(none.drop(1, gap: 0, inSection: true)?.action == "browser_move_tab")
    }

    // MARK: The strip

    @Test func theStripsDropReadsWhichSideOfTheLineThePointerIs() {
        // Two favicon entries, the line, then two tabs.
        let spans: [ClosedRange<Double>] = [0...30, 31...61, 74...274, 279...479]
        let line = BrowserStripDrop.lineX(section: 2, spans: spans)
        #expect(line == 67.5)
        // From t4 into the line's left half: the section's side of gap 2.
        #expect(BrowserStripDrop.target(from: 3, x: 64, y: 5, spans: spans, height: 26, section: 2)! == (2, true))
        #expect(BrowserStripDrop.target(from: 3, x: 70, y: 5, spans: spans, height: 26, section: 2)! == (2, false))
        // Onto an entry takes its place.
        #expect(BrowserStripDrop.target(from: 3, x: 10, y: 5, spans: spans, height: 26, section: 2)! == (0, true))
        #expect(BrowserStripDrop.target(from: 0, x: 100, y: 5, spans: spans, height: 26, section: 2)! == (3, false))
        #expect(BrowserStripDrop.target(from: 0, x: 10, y: 5, spans: spans, height: 26, section: 2) == nil)
        #expect(BrowserStripDrop.target(from: 0, x: 10, y: 40, spans: spans, height: 26, section: 2) == nil)
        // The line's gap draws on its side of the line.
        #expect(BrowserStripDrop.dropX(from: 3, gap: 2, inSection: true, section: 2, spans: spans) == 62)
        #expect(BrowserStripDrop.dropX(from: 0, gap: 2, inSection: false, section: 2, spans: spans) == 73)
    }

    @Test func withNoSectionTheStripDropsAsBefore() {
        let spans: [ClosedRange<Double>] = [0...100, 105...205]
        #expect(BrowserStripDrop.target(from: 1, x: 50, y: 5, spans: spans, height: 26, section: 0)! == (0, false))
        #expect(BrowserStripDrop.dropX(from: 1, gap: 0, inSection: false, section: 0, spans: spans) == -1)
        #expect(BrowserStripDrop.dropX(from: 0, gap: 2, inSection: false, section: 0, spans: spans) == 206)
    }
}
