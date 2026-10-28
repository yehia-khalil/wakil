import Testing

@testable import WakilKit

/// 3d-i walk: which entries the tab list draws, with a collapsed group showing its active tab.
@Suite("Browser strip entries")
struct BrowserStripEntriesTests {
    private func tab(_ id: String, group: String? = nil, pin: String? = nil) -> BrowserTab {
        BrowserTab(id: id, url: "https://\(id).test/", title: id, loaded: true, group: group, pin: pin)
    }

    private func pane(_ tabs: [BrowserTab], groups: [BrowserGroup], active: String?) -> BrowserSnapshot {
        BrowserSnapshot(tabs: tabs, active: active, find: nil, downloads: [], closed: [],
                        nextTab: tabs.count + 1, groups: groups, nextGroup: groups.count + 1)
    }

    private func own(_ id: String, collapsed: Bool) -> BrowserGroup {
        BrowserGroup(id: id, name: id, colour: .blue, collapsed: collapsed, kind: .own)
    }

    private func ids(_ s: BrowserSnapshot) -> [String] { s.stripEntries.map(\.id) }

    @Test func anExpandedGroupShowsEveryTab() {
        let s = pane([tab("t1", group: "g1"), tab("t2", group: "g1"), tab("t3")], groups: [own("g1", collapsed: false)],
                     active: "t3")
        #expect(ids(s) == ["group:g1", "t1", "t2", "t3"])
    }

    @Test func aCollapsedGroupShowsOnlyTheActiveTabUnderItsHeader() {
        let s = pane([tab("t1", group: "g1"), tab("t2", group: "g1"), tab("t3", group: "g1"), tab("t4")],
                     groups: [own("g1", collapsed: true)], active: "t2")
        #expect(ids(s) == ["group:g1", "t2", "t4"])
        #expect(s.stripActive == "t2")
    }

    @Test func whenTheActiveTabIsOutsideTheGroupItShowsItsHeaderOnly() {
        let s = pane([tab("t1", group: "g1"), tab("t2", group: "g1"), tab("t3")],
                     groups: [own("g1", collapsed: true)], active: "t3")
        #expect(ids(s) == ["group:g1", "t3"])
        #expect(s.stripActive == "t3")
    }

    @Test func eachCollapsedGroupIsJudgedOnItsOwn() {
        let s = pane([tab("t1", group: "g1"), tab("t2", group: "g1"), tab("t3", group: "g2"), tab("t4", group: "g2")],
                     groups: [own("g1", collapsed: true), own("g2", collapsed: true)], active: "t4")
        #expect(ids(s) == ["group:g1", "group:g2", "t4"])
    }

    @Test func aPinnedCollapsedGroupAndTheEmptyPullRequestGroupKeepTheirPlaces() {
        var pinned = own("g1", collapsed: true)
        pinned.pin = "p"
        let pr = BrowserGroup(id: "pr", name: "Pull Requests", colour: .steel, collapsed: true, kind: .pullRequests)
        let s = pane([tab("t1", group: "g1"), tab("t2", group: "g1"), tab("t3")], groups: [pinned, pr], active: "t1")
        #expect(ids(s) == ["group:g1", "t1", "group:pr", "t3"])
    }

    @Test func aMiddleClickClosesATabEvenAPinnedOneAndNeverAGroupHeader() {
        var pinned = own("g2", collapsed: false)
        pinned.pin = "p"
        let s = pane([tab("t1", pin: "p"), tab("t2", group: "g1"), tab("t3", group: "g2")],
                     groups: [own("g1", collapsed: false), pinned], active: "t1")
        let closes = s.stripEntries.map { [$0.id: $0.middleClickCloses] }
        #expect(closes.contains { $0["t1"] == "t1" }, "a pinned tab: in one press, as its ×")
        #expect(closes.contains { $0["t2"] == "t2" })
        #expect(closes.contains { $0["t3"] == "t3" }, "a tab of a pinned group")
        #expect(closes.contains { $0["group:g1"] == .some(nil) }, "a header does nothing")
        #expect(closes.contains { $0["group:g2"] == .some(nil) })
    }

    @Test func showsTabAnswersPerTab() {
        let s = pane([tab("t1", group: "g1"), tab("t2", group: "g1"), tab("t3")], groups: [own("g1", collapsed: true)],
                     active: "t1")
        #expect(s.showsTab(s.tabs[0]))
        #expect(!s.showsTab(s.tabs[1]))
        #expect(s.showsTab(s.tabs[2]))
    }
}
