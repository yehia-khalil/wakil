import Testing

@testable import WakilKit

/// 3d-i: the grouping rules (rulings 4–11, 21), pure on `BrowserSnapshot`.
@Suite("Browser grouping")
struct BrowserGroupingTests {
    private func tab(
        _ id: String, _ url: String, _ title: String = "", group: String? = nil, opener: String? = nil,
        pin: String? = nil, keptLoose: Bool = false, pullRequest: String? = nil
    ) -> BrowserTab {
        BrowserTab(id: id, url: url, title: title, loaded: true, group: group, opener: opener, pin: pin,
                   keptLoose: keptLoose, pullRequest: pullRequest)
    }

    private func pane(_ tabs: [BrowserTab], groups: [BrowserGroup] = [], active: String? = nil,
                      nextGroup: Int = 1) -> BrowserSnapshot {
        BrowserSnapshot(tabs: tabs, active: active ?? tabs.first?.id, find: nil, downloads: [], closed: [],
                        nextTab: tabs.count + 1, groups: groups, nextGroup: nextGroup)
    }

    private func auto(_ id: String, _ key: String?, name: String = "Site", colour: BrowserGroupColour = .blue)
        -> BrowserGroup {
        BrowserGroup(id: id, name: name, colour: colour, kind: .automatic, siteKey: key)
    }

    private func groupOf(_ s: BrowserSnapshot, _ id: String) -> String? { s.tabs.first { $0.id == id }?.group }
    private func ids(_ s: BrowserSnapshot) -> [String] { s.tabs.map(\.id) }

    private let yt1 = "https://www.youtube.com/watch?v=1"
    private let yt2 = "https://www.youtube.com/watch?v=2"
    private let yt3 = "https://youtu.be/3"

    @Test func twoTabsOfASiteFormAGroupOneStaysLoose() {
        var s = pane([tab("t1", yt1), tab("t2", "https://example.com/a")])
        s.placeLoaded(tab: "t1")
        #expect(s.groups.isEmpty)
        #expect(groupOf(s, "t1") == nil)

        s.tabs.append(tab("t3", yt2))
        s.placeLoaded(tab: "t3")
        #expect(s.groups.count == 1)
        let g = s.groups[0]
        #expect(g.id == "g1")
        #expect(g.kind == .automatic)
        #expect(g.siteKey == "family:youtube")
        #expect(g.name == "YouTube")
        #expect(s.nextGroup == 2)
        #expect(groupOf(s, "t1") == "g1")
        #expect(groupOf(s, "t3") == "g1")
        #expect(groupOf(s, "t2") == nil)
    }

    @Test func aThirdTabJoinsTheSitesGroup() {
        var s = pane([tab("t1", "https://github.com/initech/a"), tab("t2", "https://github.com/initech/b")])
        s.placeLoaded(tab: "t2")
        s.tabs.append(tab("t3", "https://gist.github.com/x"))
        s.placeLoaded(tab: "t3")
        #expect(s.groups.count == 1)
        #expect(["t1", "t2", "t3"].allSatisfy { groupOf(s, $0) == "g1" })
    }

    @Test func familySitesShareAGroup() {
        var s = pane([
            tab("t1", "https://initech.atlassian.net/browse/X-1", "X-1 Jira"),
            tab("t2", "https://initech.atlassian.net/wiki/spaces/X", "Confluence"),
        ])
        s.placeLoaded(tab: "t2")
        s.tabs.append(tab("t3", "https://www.atlassian.com/software/jira"))
        s.placeLoaded(tab: "t3")
        #expect(s.groups.count == 1)
        #expect(s.groups[0].name == "Atlassian")
        #expect(["t1", "t2", "t3"].allSatisfy { groupOf(s, $0) == "g1" })
    }

    @Test func aPopupJoinsItsOpenersGroupWhateverItsSite() {
        var s = pane([tab("t1", yt1, group: "g1"), tab("t2", yt2, group: "g1")],
                     groups: [auto("g1", "family:youtube")], nextGroup: 2)
        s.tabs.append(tab("t3", "https://www.google.com/search?q=x"))
        s.placeOpened(tab: "t3", opener: "t1")
        #expect(groupOf(s, "t3") == "g1")
        #expect(s.tabs.first { $0.id == "t3" }?.opener == "t1")
        #expect(s.groups.count == 1)
    }

    @Test func aLooseOpenerAndItsOtherSitePopupFormAChainGroupNamedFromTheOpener() {
        var s = pane([tab("t1", "https://www.amazon.com/s?k=usb+c+hub", "Amazon.com : usb c hub 4 port")])
        s.tabs.append(tab("t2", "https://www.example.com/hub"))
        s.placeOpened(tab: "t2", opener: "t1")
        #expect(s.groups.count == 1)
        let g = s.groups[0]
        #expect(g.kind == .automatic)
        #expect(g.siteKey == nil)
        #expect(g.name == "Amazon.com : usb")
        #expect(groupOf(s, "t1") == "g1")
        #expect(groupOf(s, "t2") == "g1")
        #expect(s.tabs.first { $0.id == "t2" }?.opener == "t1")

        // The opener navigating keeps the chain: a chain group has no site to leave.
        s.tabs[s.tabs.firstIndex { $0.id == "t1" }!].url = "https://www.amazon.com/s?k=dock"
        s.placeLoaded(tab: "t1")
        #expect(groupOf(s, "t1") == "g1")
    }

    @Test func aPopupOfThePullRequestGroupWaitsForTheSiteRule() {
        let pr = BrowserGroup(id: "pr", name: "Pull Requests", colour: .blue, collapsed: true, kind: .pullRequests)
        var s = pane([
            tab("p1", "https://github.com/initech/a/pull/1", group: "pr",
                pullRequest: "https://github.com/initech/a/pull/1"),
            tab("t2", "https://github.com/initech/b"),
        ], groups: [pr])
        s.tabs.append(tab("t3", "https://github.com/initech/a/issues/9"))
        s.placeOpened(tab: "t3", opener: "p1")
        #expect(groupOf(s, "t3") == nil)
        #expect(s.tabs.first { $0.id == "t3" }?.opener == nil)

        s.placeLoaded(tab: "t3")
        let site = s.groups.first { $0.kind == .automatic }
        #expect(site?.siteKey == "family:github")
        #expect(groupOf(s, "t3") == site?.id)
        #expect(groupOf(s, "t2") == site?.id)
        #expect(groupOf(s, "p1") == "pr")

        s.placeLoaded(tab: "p1")
        #expect(groupOf(s, "p1") == "pr")
    }

    @Test func aTabNavigatingToAnotherSiteLeavesItsSiteGroup() {
        var s = pane([tab("t1", yt1, group: "g1"), tab("t2", yt2, group: "g1")],
                     groups: [auto("g1", "family:youtube")], nextGroup: 2)
        s.tabs[1].url = "https://www.google.com/"
        s.placeLoaded(tab: "t2")
        #expect(s.groups.isEmpty)
        #expect(groupOf(s, "t1") == nil)
        #expect(groupOf(s, "t2") == nil)
    }

    @Test func aTabThatCameByOpenerStaysWhenItNavigates() {
        var s = pane([tab("t1", yt1, group: "g1"), tab("t2", yt2, group: "g1")],
                     groups: [auto("g1", "family:youtube")], nextGroup: 2)
        s.tabs.append(tab("t3", "https://example.com/a"))
        s.placeOpened(tab: "t3", opener: "t1")
        s.tabs[s.tabs.firstIndex { $0.id == "t3" }!].url = "https://www.google.com/"
        s.placeLoaded(tab: "t3")
        #expect(groupOf(s, "t3") == "g1")
        #expect(s.tabs.first { $0.id == "t3" }?.opener == "t1")
    }

    @Test func ownGroupsAreNeverRegrouped() {
        let own = BrowserGroup(id: "g1", name: "Mine", colour: .teal, kind: .own)
        var s = pane([
            tab("t1", yt1, group: "g1"),
            tab("t2", "https://github.com/initech/a", group: "g1"),
            tab("t3", yt2),
        ], groups: [own], nextGroup: 2)
        s.placeLoaded(tab: "t2")
        #expect(groupOf(s, "t2") == "g1")
        s.tabs[0].url = "https://www.google.com/"
        s.placeLoaded(tab: "t1")
        #expect(groupOf(s, "t1") == "g1")

        // A loose tab of the own group's sites never joins it; it forms its own site group.
        s.tabs.append(tab("t4", yt3))
        s.placeLoaded(tab: "t4")
        #expect(groupOf(s, "t4") == "g2")
        #expect(groupOf(s, "t3") == "g2")
        #expect(s.group("g1")?.kind == .own)
        #expect(s.group("g1")?.name == "Mine")

        // An own group of one stays.
        s.moveTab("t1", into: nil, at: nil)
        #expect(s.group("g1") != nil)
        #expect(groupOf(s, "t2") == "g1")
    }

    @Test func aKeptLooseTabIsNeverPulledIn() {
        var s = pane([tab("t1", yt1, keptLoose: true), tab("t2", yt2)])
        s.placeLoaded(tab: "t2")
        #expect(s.groups.isEmpty)

        s.tabs.append(tab("t3", yt3))
        s.placeLoaded(tab: "t3")
        #expect(groupOf(s, "t2") == "g1")
        s.placeLoaded(tab: "t1")
        #expect(groupOf(s, "t1") == nil)

        // A kept-loose opener never starts a chain group either.
        s.tabs.append(tab("t4", "https://example.com/a"))
        s.placeOpened(tab: "t4", opener: "t1")
        #expect(groupOf(s, "t4") == nil)
    }

    @Test func draggingIntoAGroupClearsKeptLooseAndMakesItOwn() {
        var s = pane([
            tab("t1", yt1, group: "g1"), tab("t2", yt2, group: "g1"), tab("t3", yt3, group: "g1"),
            tab("t4", "https://www.google.com/", keptLoose: true),
        ], groups: [auto("g1", "family:youtube"), auto("g2", "example.com")], nextGroup: 3)
        s.moveTab("t4", into: "g1", at: nil)
        #expect(groupOf(s, "t4") == "g1")
        #expect(s.tabs.first { $0.id == "t4" }?.keptLoose == false)
        #expect(s.group("g1")?.kind == .own)
        #expect(ids(s) == ["t1", "t2", "t3", "t4"])

        // Dragging one out marks it kept loose.
        s.moveTab("t1", into: nil, at: nil)
        #expect(groupOf(s, "t1") == nil)
        #expect(s.tabs.first { $0.id == "t1" }?.keptLoose == true)

        // Leaving an automatic group makes it own too.
        var t = pane([tab("a", yt1, group: "g1"), tab("b", yt2, group: "g1"), tab("c", yt3, group: "g1")],
                     groups: [auto("g1", "family:youtube")], nextGroup: 2)
        t.moveTab("c", into: nil, at: nil)
        #expect(t.group("g1")?.kind == .own)
        #expect(t.tabs.first { $0.id == "c" }?.keptLoose == true)

        // Reordering a loose tab does not mark it kept loose.
        var u = pane([tab("a", yt1), tab("b", "https://example.com/")])
        u.moveTab("b", into: nil, at: 0)
        #expect(ids(u) == ["b", "a"])
        #expect(u.tabs.allSatisfy { !$0.keptLoose })

        // Never into the pull-request group.
        var v = pane([tab("p", "https://github.com/initech/a/pull/1", group: "pr", pullRequest: "x"), tab("a", yt1)],
                     groups: [BrowserGroup(id: "pr", name: "Pull Requests", colour: .blue, kind: .pullRequests)])
        v.moveTab("a", into: "pr", at: nil)
        #expect(groupOf(v, "a") == nil)
    }

    @Test func makeOwnTurnsAnAutomaticGroupOwnAndKeepsItsPlace() {
        var s = pane([
            tab("a", yt1, group: "g1"), tab("b", yt2, group: "g1"),
            tab("c", "https://github.com/a", group: "g2"), tab("d", "https://github.com/b", group: "g2"),
        ], groups: [auto("g1", "family:youtube"), auto("g2", "family:github")], nextGroup: 3)
        let before = ids(s)
        s.makeOwn("g2")
        #expect(s.group("g2")?.kind == .own)
        #expect(s.groups.map(\.id) == ["g1", "g2"])
        #expect(ids(s) == before)
    }

    @Test func arrangeOrdersPinnedThenPullRequestsThenGroupsByAgeThenLoose() {
        var pinnedGroup = BrowserGroup(id: "g3", name: "Pinned", colour: .sand, kind: .own)
        pinnedGroup.pin = "p2"
        var s = pane([
            tab("loose", "https://example.com/"),
            tab("b1", "https://github.com/a", group: "g2"),
            tab("pr1", "https://github.com/a/pull/1", group: "pr", pullRequest: "https://github.com/a/pull/1"),
            tab("a1", yt1, group: "g1"),
            tab("pinned", "https://example.org/", pin: "p1"),
            tab("c1", "https://example.net/", group: "g3"),
            tab("b2", "https://github.com/b", group: "g2"),
            tab("a2", yt2, group: "g1"),
        ], groups: [
            auto("g1", "family:youtube"), auto("g2", "family:github"),
            BrowserGroup(id: "pr", name: "Pull Requests", colour: .blue, kind: .pullRequests), pinnedGroup,
        ], active: "b2", nextGroup: 4)
        s.arrange()
        #expect(ids(s) == ["pinned", "c1", "pr1", "a1", "a2", "b1", "b2", "loose"])
        #expect(s.active == "b2")
        #expect(s.groups.map(\.id) == ["g1", "g2", "pr", "g3"])
    }

    @Test func becomingOwnDoesNotMoveAGroup() {
        var s = pane([
            tab("a", yt1, group: "g1"), tab("b", yt2, group: "g1"),
            tab("c", "https://github.com/a", group: "g2"), tab("d", "https://github.com/b", group: "g2"),
            tab("e", "https://example.com/"),
        ], groups: [auto("g1", "family:youtube"), auto("g2", "family:github")], nextGroup: 3)
        s.makeOwn("g2")
        #expect(ids(s) == ["a", "b", "c", "d", "e"])
        s.moveTab("e", into: "g2", at: nil)
        #expect(groupOf(s, "e") == "g2")
        #expect(ids(s) == ["a", "b", "c", "d", "e"])
        #expect(s.groups.map(\.id) == ["g1", "g2"])
    }

    @Test func pinnedTabsAreNeverGrouped() {
        var s = pane([tab("t1", yt1, pin: "p1"), tab("t2", yt2)])
        s.placeLoaded(tab: "t2")
        s.placeLoaded(tab: "t1")
        #expect(s.groups.isEmpty)

        s.tabs.append(tab("t3", "https://example.com/"))
        s.placeOpened(tab: "t3", opener: "t1")
        #expect(s.groups.isEmpty)
        #expect(s.tabs.first { $0.id == "t3" }?.opener == nil)
    }

    @Test func theCollapsedGroupShowsTheTabLastOpen() {
        var g = auto("g1", "family:youtube")
        g.collapsed = true
        var s = pane([tab("t1", yt1, group: "g1"), tab("t2", yt2, group: "g1"), tab("t3", "https://example.com/")],
                     groups: [g], active: "t2", nextGroup: 2)
        s.arrange()
        #expect(s.group("g1")?.lastOpen == "t2")
        s.active = "t3"
        s.arrange()
        #expect(s.group("g1")?.lastOpen == "t2")
        #expect(s.group("g1")?.collapsed == true)
    }

    @Test func coloursTakeTheFirstFreeSwatchThenCycle() {
        var s = pane([], groups: [auto("g1", nil, colour: .blue), auto("g2", nil, colour: .teal)])
        #expect(s.nextColour() == .steel)
        s.groups = BrowserGroupColour.allCases.enumerated().map { auto("g\($0)", nil, colour: $1) }
        #expect(s.nextColour() == .blue)
        s.groups.append(auto("g9", nil, colour: .blue))
        #expect(s.nextColour() == .steel)

        // A new group takes it.
        var t = pane([tab("a", yt1), tab("b", yt2)], groups: [auto("g1", "x", colour: .blue)], nextGroup: 2)
        let id = t.newGroup(tabs: ["a", "b"], name: "New Group", kind: .own, siteKey: nil)
        #expect(id == "g2")
        #expect(t.group("g2")?.colour == .steel)
    }

    @Test func dropGroupIsTheGroupOfTheTabLandedBefore() {
        let s = pane([
            tab("a", yt1, group: "g1"), tab("b", yt2, group: "g1"),
            tab("c", "https://github.com/a", group: "g2"), tab("d", "https://example.com/"),
        ], groups: [auto("g1", "family:youtube"), auto("g2", "family:github")], nextGroup: 3)
        #expect(s.dropGroup(moving: "d", before: 0) == "g1")
        #expect(s.dropGroup(moving: "d", before: 1) == "g1")
        #expect(s.dropGroup(moving: "d", before: 2) == "g2")
        #expect(s.dropGroup(moving: "d", before: 3) == nil)
        #expect(s.dropGroup(moving: "a", before: 2) == nil)
        #expect(s.dropGroup(moving: "a", before: 1) == "g2")
    }

    @Test func fallbackNameIsTheSiteThenTheOpenersTitleThenNewGroup() {
        #expect(BrowserSnapshot.fallbackName(siteKey: "amazon.com", openerTitle: "x y z w") == "Amazon")
        #expect(BrowserSnapshot.fallbackName(siteKey: nil, openerTitle: "Amazon.com : usb c hub") == "Amazon.com : usb")
        #expect(BrowserSnapshot.fallbackName(siteKey: nil, openerTitle: "  ") == "New Group")
        #expect(BrowserSnapshot.fallbackName(siteKey: nil, openerTitle: nil) == "New Group")
    }

    @Test func aDissolvedGroupsLastTabBecomesTheFirstLooseTab() {
        var s = pane([
            tab("a", yt1, group: "g1"), tab("b", yt2, group: "g1"),
            tab("c", "https://github.com/a", group: "g2"), tab("d", "https://github.com/b", group: "g2"),
            tab("e", "https://example.com/"),
        ], groups: [auto("g1", "family:youtube"), auto("g2", "family:github")], nextGroup: 3)
        s.tabs[1].url = "https://www.google.com/"
        s.placeLoaded(tab: "b")
        #expect(s.groups.map(\.id) == ["g2"])
        #expect(ids(s) == ["c", "d", "a", "b", "e"])
    }

    @Test func aPinnedTabCannotBeMovedIntoAGroup() {
        var s = pane([
            tab("a", yt1, group: "g1"), tab("b", yt2, group: "g1"), tab("p", "https://example.com/", pin: "p1"),
        ], groups: [auto("g1", "family:youtube")], nextGroup: 2)
        s.moveTab("p", into: "g1", at: nil)
        #expect(groupOf(s, "p") == nil)
        #expect(s.group("g1")?.kind == .automatic)
        let id = s.newGroup(tabs: ["p"], name: "Mine", kind: .own, siteKey: nil)
        #expect(groupOf(s, "p") == nil)
        #expect(s.group(id) == nil)
    }

    @Test func lastOpenFallsBackToTheGroupsFirstTabWhenItsTabIsGone() {
        var g = auto("g1", "family:youtube")
        g.lastOpen = "gone"
        var s = pane([tab("a", yt1, group: "g1"), tab("b", yt2, group: "g1"), tab("x", "https://example.com/")],
                     groups: [g], active: "x", nextGroup: 2)
        s.arrange()
        #expect(s.group("g1")?.lastOpen == "a")
    }
}
