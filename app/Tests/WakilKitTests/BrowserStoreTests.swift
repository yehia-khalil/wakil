import Foundation
import Testing
@testable import WakilKit

private let pane = "b1"

private func tab(_ id: String, _ url: String = "https://example.com/") -> BrowserTab {
    BrowserTab(id: id, url: url, title: id)
}

/// A store holding a browser pane with `ids` as its tabs, the first one active.
private func browserStore(_ ids: [String] = ["t1", "t2"]) async -> PaneStore {
    let store = PaneStore(kinds: PaneKinds.standard)
    await store.updateBrowser(paneId: pane, create: true) { s in
        s.tabs = ids.map { tab($0) }; s.active = ids.first; s.nextTab = ids.count + 1
    }
    return store
}

private func report(_ url: String, title: String = "Page", loading: Bool = false) -> BrowserPageReport {
    BrowserPageReport(url: url, title: title, isLoading: loading, progress: loading ? 0.5 : 1,
                      canGoBack: true, canGoForward: false, failure: nil)
}

@Test func aReportUpdatesOnlyItsTab() async {
    let store = await browserStore()
    let before = await store.browserSnapshot(paneId: pane)
    await store.browserPageDidReport(paneId: pane, tab: "t2", report("https://b.test/", title: "B", loading: true))
    let s = await store.browserSnapshot(paneId: pane)
    #expect(s.tabs[0] == before.tabs[0])
    let t = s.tabs[1]
    #expect(t.url == "https://b.test/" && t.title == "B" && t.isLoading && t.progress == 0.5)
    #expect(t.canGoBack && !t.canGoForward && t.failure == nil && t.loaded)
    #expect(s.active == "t1")
}

@Test func aReportForAClosedTabIsDropped() async {
    let store = await browserStore()
    await store.updateBrowser(paneId: pane) { s in s.tabs.removeAll { $0.id == "t2" } }
    let before = await store.browserSnapshot(paneId: pane)
    await store.browserPageDidReport(paneId: pane, tab: "t2", report("https://b.test/"))
    #expect(await store.browserSnapshot(paneId: pane) == before)
    #expect(await store.browserSnapshot(paneId: pane).active == "t1")
}

@Test func aReportForAPaneThatHoldsNoBrowserCreatesNothing() async {
    let store = PaneStore(kinds: PaneKinds.standard)
    await store.browserPageDidReport(paneId: "nope", tab: "t1", report("https://b.test/"))
    #expect(await store.snapshot(paneId: "nope", kind: "browser").browser == .empty)
    #expect(await !store.holdsContents(paneId: "nope"))
}

@Test func aReportDoesNotIssueACommand() async {
    let store = await browserStore()
    await store.updateBrowser(paneId: pane) { s in
        s.tabs[0].command = BrowserCommand(seq: 3, verb: .reload)
    }
    await store.browserPageDidReport(paneId: pane, tab: "t1", report("https://a.test/"))
    await store.browserPageDidReport(paneId: pane, tab: "t2", report("https://b.test/"))
    let s = await store.browserSnapshot(paneId: pane)
    #expect(s.tabs[0].command == BrowserCommand(seq: 3, verb: .reload))
    #expect(s.tabs[1].command == nil)
    #expect(s.tabs.map(\.id) == ["t1", "t2"] && s.active == "t1")
}

private let readPaneKeys: Set<String> = [
    "kind", "failure", "tabs", "active", "url", "title", "loading", "canGoBack", "canGoForward",
    "zoom", "find", "downloads", "bookmarked", "groups", "tabColumnHidden", "pinsError",
]

@Test func readPaneHasEveryKeyAndNoPageText() async {
    let store = PaneStore(kinds: PaneKinds.standard)
    guard case .object(let empty) = await store.readPane(paneId: "empty", kind: "browser") else {
        Issue.record("not an object"); return
    }
    #expect(Set(empty.keys) == readPaneKeys)
    #expect(empty["tabs"] == .array([]) && empty["active"] == .null && empty["find"] == .null)
    #expect(empty["downloads"] == .array([]) && empty["failure"] == .null)

    let full = await browserStore()
    await full.browserPageDidReport(paneId: pane, tab: "t1", report("https://a.test/", title: "A"))
    await full.updateBrowser(paneId: pane) { s in
        s.find = BrowserFind(query: "x", current: 1, total: 4, seq: 1, forward: true)
        s.downloads = [BrowserDownload(id: "d1", filename: "f.zip", received: 5, expected: 10, state: .running)]
    }
    guard case .object(let o) = await full.readPane(paneId: pane, kind: "browser") else {
        Issue.record("not an object"); return
    }
    #expect(Set(o.keys) == readPaneKeys)
    #expect(o["active"] == .string("t1") && o["url"] == .string("https://a.test/") && o["title"] == .string("A"))
    #expect(o["loading"] == .bool(false) && o["canGoBack"] == .bool(true) && o["zoom"] == .number(1))
    #expect(o["find"] == .object(["query": .string("x"), "current": .number(1), "total": .number(4)]))
    guard case .array(let tabs) = o["tabs"], tabs.count == 2, case .object(let t0) = tabs[0] else {
        Issue.record("tabs"); return
    }
    #expect(Set(t0.keys) == ["id", "url", "title", "loading", "active", "site", "environment", "production",
                             "group", "pinned"])
    #expect(t0["active"] == .bool(true))
    guard case .array(let downloads) = o["downloads"], case .object(let d0) = downloads.first else {
        Issue.record("downloads"); return
    }
    #expect(Set(d0.keys) == ["id", "filename", "state", "received", "expected"])
    #expect(d0["state"] == .string("running"))
}

@Test func theKindsFailureIsTheActiveTabs() async {
    let store = await browserStore()
    await store.browserPageDidReport(paneId: pane, tab: "t2", BrowserPageReport(
        url: "https://b.test/", title: "", isLoading: false, progress: 0, canGoBack: false,
        canGoForward: false, failure: "offline"))
    #expect(await store.snapshot(paneId: pane, kind: "browser").failure == nil)
    await store.updateBrowser(paneId: pane) { s in s.active = "t2" }
    #expect(await store.snapshot(paneId: pane, kind: "browser").failure == "offline")
}

@Test func restoreLoadsOnlyTheActiveTab() async {
    let store = PaneStore(kinds: PaneKinds.standard)
    let saved = [BrowserSavedTab(id: "t1", url: "https://a.test/", title: "A"),
                 BrowserSavedTab(id: "t4", url: "https://b.test/", title: "B"),
                 BrowserSavedTab(id: "t2", url: "https://c.test/", title: "C")]
    await store.browserRestore(paneId: pane, tabs: saved, active: "t4", groups: [], columnHidden: false)
    let s = await store.browserSnapshot(paneId: pane)
    #expect(s.tabs.map(\.id) == ["t1", "t4", "t2"] && s.active == "t4")
    #expect(s.tabs.allSatisfy { !$0.loaded })
    #expect(s.tabs.map(\.title) == ["A", "B", "C"] && s.tabs.map(\.url) == saved.map(\.url))
    #expect(s.tabs[0].command == nil && s.tabs[2].command == nil)
    #expect(s.tabs[1].command?.verb == .load("https://b.test/"))
    #expect(s.nextTab == 5)

    await store.browserRestore(paneId: "b2", tabs: saved, active: "gone", groups: [], columnHidden: false)
    let other = await store.browserSnapshot(paneId: "b2")
    #expect(other.active == "t1" && other.tabs[0].command?.verb == .load("https://a.test/"))
    #expect(other.tabs[1].command == nil)
}

@Test func theKindRestoresAPaneWithSavedTabsOnly() {
    var p = Pane(id: "b1", kind: "browser", title: "Browser", frame: PaneFrame(x: 0, y: 0, width: 1, height: 1))
    #expect(BrowserPaneKind.restoreStep(for: p) == nil)
    p.browserTabs = []
    #expect(BrowserPaneKind.restoreStep(for: p) == nil)
    p.browserTabs = [BrowserSavedTab(id: "t1", url: "https://a.test/", title: "A")]
    #expect(BrowserPaneKind.restoreStep(for: p) == PaneRestoreStep(
        action: "browser_restore", params: .object(["pane": .string("b1")]), recordsFailure: false))
}

@Test func aPopupOpensBesideItsOpener() async {
    let store = await browserStore(["t1", "t2", "t3"])
    // Its opener's site (3d-i): the opener rule forms no group, so it stays beside its opener.
    let id = await store.browserPageOpenedTab(paneId: pane, opener: "t2", url: "https://example.com/pop")
    #expect(id == "t4")
    let s = await store.browserSnapshot(paneId: pane)
    #expect(s.tabs.map(\.id) == ["t1", "t2", "t4", "t3"] && s.active == "t4" && s.nextTab == 5)
    #expect(s.tabs[2].url == "https://example.com/pop" && s.tabs[2].loaded && s.tabs[2].command == nil)
    #expect(s.groups.isEmpty)
    #expect(await store.browserPageOpenedTab(paneId: pane, opener: "t9", url: "https://x.test/") == nil)
    #expect(await store.browserSnapshot(paneId: pane) == s)
}

@Test func downloadsKeepTheirOrder() async {
    let store = await browserStore()
    func d(_ id: String, _ received: Int64, _ state: BrowserDownload.State = .running) -> BrowserDownload {
        BrowserDownload(id: id, filename: "\(id).zip", received: received, expected: 100, state: state)
    }
    await store.browserDownloadDidChange(paneId: pane, d("d1", 0))
    await store.browserDownloadDidChange(paneId: pane, d("d2", 0))
    await store.browserDownloadDidChange(paneId: pane, d("d1", 100, .finished))
    await store.browserDownloadDidChange(paneId: pane, d("d3", 0))
    let s = await store.browserSnapshot(paneId: pane)
    #expect(s.downloads.map(\.id) == ["d1", "d2", "d3"])
    #expect(s.downloads[0].state == .finished && s.downloads[0].received == 100)
}

@Test func aFindReportLandsOnlyWhileTheBarIsOpen() async {
    let store = await browserStore()
    await store.browserFindDidReport(paneId: pane, current: 1, total: 2)
    #expect(await store.browserSnapshot(paneId: pane).find == nil)
    await store.updateBrowser(paneId: pane) { s in s.find = BrowserFind(query: "a", current: 0, total: 0, seq: 1, forward: true) }
    await store.browserFindDidReport(paneId: pane, current: 1, total: 2)
    let f = await store.browserSnapshot(paneId: pane).find
    #expect(f?.current == 1 && f?.total == 2 && f?.query == "a")
}

/// 3c-i Task 8: a page that arrives on a host with a remembered zoom says so, and the store keeps it,
/// so `read_pane`'s zoom and the next ⌘+ start from what the page shows. A report that names no zoom
/// leaves the tab's alone (a report read before a `browser_zoom` applied must not undo it).
@Test func aReportCarriesTheHostsZoomOnlyWhenItNamesOne() async {
    let store = await browserStore()
    var withZoom = report("https://a.test/")
    withZoom.zoom = 1.25
    await store.browserPageDidReport(paneId: pane, tab: "t1", withZoom)
    #expect(await store.browserSnapshot(paneId: pane).tabs[0].zoom == 1.25)
    await store.browserPageDidReport(paneId: pane, tab: "t1", report("https://a.test/"))
    #expect(await store.browserSnapshot(paneId: pane).tabs[0].zoom == 1.25)
    #expect(await store.browserSnapshot(paneId: pane).tabs[0].command == nil)
}

/// Final review I2: only a tab put back from the saved layout may take a saved state; a tab made
/// this launch (a new tab, a pop-up) never does, whatever file a reissued id finds.
@Test func onlyARestoredTabIsMarkedAsFromTheSavedLayout() async {
    let store = PaneStore(kinds: PaneKinds.standard)
    await store.browserRestore(paneId: pane, tabs: [BrowserSavedTab(id: "t1", url: "https://a.test/", title: "A"),
                                                    BrowserSavedTab(id: "t2", url: "https://b.test/", title: "B")],
                               active: "t1", groups: [], columnHidden: false)
    #expect(await store.browserSnapshot(paneId: pane).tabs.allSatisfy(\.fromSavedLayout))
    let popup = await store.browserPageOpenedTab(paneId: pane, opener: "t1", url: "https://c.test/")
    let s = await store.browserSnapshot(paneId: pane)
    #expect(s.tabs.first { $0.id == popup }?.fromSavedLayout == false)
    #expect(BrowserTab(id: "t9", url: "", title: "").fromSavedLayout == false)
}

// MARK: - 3d-i: groups, pins and the column, saved with a pane's tabs

/// Save (`browserSavedTabs` into the layout) → read back → restore keeps every 3d-i field.
@Test func savedTabsRoundTripGroupsPinsAndColumn() async throws {
    let store = PaneStore(kinds: PaneKinds.standard)
    let groups = [
        BrowserGroup(id: "g2", name: "Docs", colour: .teal, collapsed: true, lastOpen: "t3", kind: .own,
                     siteKey: nil, named: true, pin: "pabc12345"),
        BrowserGroup(id: "g7", name: "Amazon", colour: .sand, collapsed: false, lastOpen: nil, kind: .automatic,
                     siteKey: "amazon.com", named: false, pin: nil),
    ]
    await store.updateBrowser(paneId: pane, create: true) { s in
        s.tabs = [
            BrowserTab(id: "t1", url: "https://a.test/", title: "A", pin: "p00000001"),
            BrowserTab(id: "t3", url: "https://b.test/", title: "B", group: "g2", opener: "t1"),
            BrowserTab(id: "t4", url: "https://amazon.com/", title: "C", group: "g7"),
            BrowserTab(id: "t5", url: "https://d.test/", title: "D", keptLoose: true),
        ]
        s.active = "t4"; s.nextTab = 6
        s.groups = groups; s.nextGroup = 8
        s.tabColumnHidden = true
    }
    let layout = LayoutStore()
    let p = await layout.open(kind: "browser", title: "Browser")
    let before = await store.browserSnapshot(paneId: pane)
    await layout.setBrowserTabs(id: p.id, to: browserSavedTabs(before), active: before.active,
                                groups: before.groups, columnHidden: before.tabColumnHidden)
    // Through the file's JSON too, so the `Pane` coding keys are covered.
    let pane2 = try #require(await layout.snapshot().panes.first { $0.id == p.id })
    let decoded = try JSONDecoder().decode(Pane.self, from: JSONEncoder().encode(pane2))
    #expect(decoded.browserGroups == groups && decoded.browserColumnHidden == true)

    let saved = try #require(await layout.browserTabs(id: p.id))
    #expect(saved.groups == groups && saved.columnHidden)
    await store.browserRestore(paneId: "b2", tabs: saved.tabs, active: saved.active, groups: saved.groups,
                               columnHidden: saved.columnHidden)
    let s = await store.browserSnapshot(paneId: "b2")
    #expect(s.tabs.map(\.group) == [nil, "g2", "g7", nil])
    #expect(s.tabs.map(\.opener) == [nil, "t1", nil, nil])
    #expect(s.tabs.map(\.pin) == ["p00000001", nil, nil, nil])
    #expect(s.tabs.map(\.keptLoose) == [false, false, false, true])
    #expect(s.groups == groups, "in order, with collapsed, lastOpen, named, kind, siteKey and pin")
    #expect(s.nextGroup == 8, "one past the highest g<n>")
    #expect(s.tabColumnHidden)
    #expect(s.active == "t4" && s.nextTab == 6)
}

/// Ruling 18: the pull-request group's tabs are not saved; the group, and its `collapsed`, is.
@Test func pullRequestTabsAreNotSaved() {
    var s = BrowserSnapshot.empty
    s.tabs = [
        BrowserTab(id: "t1", url: "https://a.test/", title: "A"),
        BrowserTab(id: "t2", url: "https://github.com/initech/app/pull/4", title: "Fix · initech/app#4",
                   group: "pr", pullRequest: "https://github.com/initech/app/pull/4"),
    ]
    s.groups = [BrowserGroup(id: "pr", name: "Pull Requests", colour: .blue, collapsed: false, lastOpen: "t2",
                             kind: .pullRequests, siteKey: nil, named: true, pin: nil)]
    #expect(browserSavedTabs(s).map(\.id) == ["t1"])
}

/// A layout written by a later build keeps its groups: an unknown kind is yours, an unknown colour blue.
@Test func anUnknownGroupKindOrColourDecodesAsOwnAndBlue() throws {
    let json = #"{"id":"g1","name":"X","colour":"violet","collapsed":false,"kind":"smart","named":true}"#
    let g = try JSONDecoder().decode(BrowserGroup.self, from: Data(json.utf8))
    #expect(g.kind == .own && g.colour == .blue)
    #expect(g.lastOpen == nil && g.siteKey == nil && g.pin == nil && g.named)
    #expect(BrowserGroupColour.allCases.map(\.hex) == [0x7f97b2, 0x8d98a8, 0x77a0a3, 0xad9f86, 0xa0938b, 0x9b9da6])
    #expect(BrowserGroupColour.allCases.map { $0.rawValue } == ["blue", "steel", "teal", "sand", "stone", "smoke"])
}

// MARK: - 3d-i Task 7: tabs placed at the seam

/// A load on `url` that starts, then finishes without a failure.
private func load(_ store: PaneStore, _ tab: String, _ url: String, via hop: String? = nil) async {
    await store.browserPageDidReport(paneId: pane, tab: tab, report(hop ?? url, loading: true))
    await store.browserPageDidReport(paneId: pane, tab: tab, report(url, loading: true))
    await store.browserPageDidReport(paneId: pane, tab: tab, report(url))
}

private func object(_ value: JSONValue?) -> [String: JSONValue] {
    if case .object(let o)? = value { return o }
    return [:]
}

private func array(_ value: JSONValue?) -> [JSONValue] {
    if case .array(let a)? = value { return a }
    return []
}

@Test func aFinishedLoadPlacesTheTabBySite() async {
    let store = await browserStore(["t1", "t2", "t3"])
    await store.updateBrowser(paneId: pane) { s in for i in s.tabs.indices { s.tabs[i].url = "" } }
    await load(store, "t1", "https://www.example.com/a")
    #expect(await store.browserSnapshot(paneId: pane).groups.isEmpty, "one tab of a site is no group")
    await load(store, "t2", "https://shop.example.com/b")
    // A report that is not the end of a load places nothing.
    await store.browserPageDidReport(paneId: pane, tab: "t3", report("https://example.com/c"))
    let s = await store.browserSnapshot(paneId: pane)
    #expect(s.tabs.first { $0.id == "t3" }?.group == nil)
    #expect(s.groups.map(\.id) == ["g1"] && s.groups[0].kind == .automatic && s.groups[0].siteKey == "example.com")
    #expect(s.groups[0].name == "Example")
    #expect(s.tabs.filter { $0.group == "g1" }.map(\.id) == ["t1", "t2"])
    #expect(s.active == "t1")
    let read = object(await store.readPane(paneId: pane, kind: "browser"))
    let groups = array(read["groups"])
    #expect(groups.count == 1)
    #expect(object(groups.first)["tabs"] == .array([.string("t1"), .string("t2")]))
    #expect(object(array(read["tabs"]).first)["group"] == .string("g1"))
}

/// Review Focus 1: a GitHub tab that redirects through a sign-in host and back neither leaves its
/// group nor starts one — the site rule runs only when a load finishes.
@Test func aRedirectThroughAnotherHostDoesNotRegroup() async {
    let store = await browserStore(["t1", "t2", "t3"])
    await load(store, "t1", "https://github.com/initech/app")
    await load(store, "t2", "https://github.com/initech/api")
    await load(store, "t3", "https://accounts.google.com/x")
    let before = await store.browserSnapshot(paneId: pane)
    #expect(before.groups.map(\.siteKey) == ["family:github"])
    #expect(before.tabs.first { $0.id == "t2" }?.group == "g1")
    // The hop: loading on accounts.google.com, then finished back on github.com.
    await load(store, "t2", "https://github.com/initech/api/pulls", via: "https://accounts.google.com/signin")
    let s = await store.browserSnapshot(paneId: pane)
    #expect(s.groups == before.groups, "no new group, none dissolved")
    #expect(s.tabs.first { $0.id == "t2" }?.group == "g1")
    #expect(s.tabs.first { $0.id == "t3" }?.group == nil)
}

/// Review Focus 1, a sign-in page that finishes loading: a grouped GitHub tab whose load ends on
/// accounts.google.com, then on github.com, keeps its group — and starts no Google group with a
/// loose Gmail tab. Two finished loads elsewhere do move it.
@Test func aSignInPageThatFinishesLoadingKeepsTheTabsGroup() async {
    let store = await browserStore(["t1", "t2", "t3"])
    await load(store, "t1", "https://github.com/initech/app")
    await load(store, "t2", "https://github.com/initech/api")
    await load(store, "t3", "https://mail.google.com/mail/u/0/")
    let before = await store.browserSnapshot(paneId: pane)
    #expect(before.groups.map(\.siteKey) == ["family:github"])
    await load(store, "t2", "https://accounts.google.com/signin")
    var s = await store.browserSnapshot(paneId: pane)
    #expect(s.groups == before.groups, "the sign-in page moves nothing")
    #expect(s.tabs.first { $0.id == "t2" }?.group == "g1")
    await load(store, "t2", "https://github.com/initech/api/pulls")
    s = await store.browserSnapshot(paneId: pane)
    #expect(s.groups == before.groups, "same group, same id, no Google group")
    #expect(s.tabs.first { $0.id == "t2" }?.group == "g1")
    #expect(s.tabs.first { $0.id == "t3" }?.group == nil)

    await load(store, "t2", "https://accounts.google.com/a")
    await load(store, "t2", "https://www.google.com/")
    s = await store.browserSnapshot(paneId: pane)
    #expect(s.tabs.first { $0.id == "t2" }?.group != "g1", "a second finished load elsewhere moves it")
    #expect(s.groups.first { $0.siteKey == "google.com" } != nil, "with the Gmail tab it forms Google's group")
}

@Test func aPopupJoinsItsOpenersGroup() async {
    let store = await browserStore(["t1", "t2", "t3"])
    await store.updateBrowser(paneId: pane) { s in
        s.tabs[2].url = "https://other.org/"
        s.groups = [BrowserGroup(id: "g1", name: "Example", colour: .blue, kind: .automatic, siteKey: "example.com")]
        s.nextGroup = 2
        s.tabs[0].group = "g1"; s.tabs[1].group = "g1"
    }
    let id = await store.browserPageOpenedTab(paneId: pane, opener: "t1", url: "https://login.example.net/")
    let s = await store.browserSnapshot(paneId: pane)
    let popup = s.tabs.first { $0.id == id }
    #expect(popup?.group == "g1" && popup?.opener == "t1", "joins its opener's group, whatever its site")
    #expect(s.tabs.map(\.id) == ["t1", "t4", "t2", "t3"])
    #expect(s.active == "t4", "a pop-up is selected, as before")
    // Its first finished load on another site does not take it out: it came by opener.
    await load(store, "t4", "https://login.example.net/done")
    #expect(await store.browserSnapshot(paneId: pane).tabs.first { $0.id == "t4" }?.group == "g1")
}

/// A pop-up with no address yet (`window.open()`) from a loose opener starts no chain group: its
/// site is unknown. It waits for the site rule.
@Test func aBlankPopupFromALooseOpenerWaitsForTheSiteRule() async {
    let store = await browserStore(["t1"])
    let id = await store.browserPageOpenedTab(paneId: pane, opener: "t1", url: "")
    var s = await store.browserSnapshot(paneId: pane)
    #expect(s.groups.isEmpty)
    #expect(s.tabs.first { $0.id == id }?.opener == nil)
    await load(store, "t2", "https://example.com/next")
    s = await store.browserSnapshot(paneId: pane)
    #expect(s.groups.map(\.siteKey) == ["example.com"], "the site rule groups it with its opener's site")
    // A pop-up on about:blank from a grouped opener still joins.
    await store.updateBrowser(paneId: pane) { s in s.tabs.append(tab("t3", "https://other.org/")); s.nextTab = 4 }
    let blank = await store.browserPageOpenedTab(paneId: pane, opener: "t1", url: "about:blank")
    #expect(await store.browserSnapshot(paneId: pane).tabs.first { $0.id == blank }?.group == "g1")
}

/// Ruling 12's guard: the name lands only on a group that still exists, is automatic and unnamed.
@Test func browserNameGroupLandsOnlyOnAnUnnamedAutomaticGroup() async {
    let store = await browserStore(["t1", "t2", "t3", "t4"])
    await store.updateBrowser(paneId: pane) { s in
        s.groups = [
            BrowserGroup(id: "g1", name: "Example", colour: .blue, kind: .automatic, siteKey: "example.com"),
            BrowserGroup(id: "g2", name: "Mine", colour: .steel, kind: .own),
            BrowserGroup(id: "g3", name: "Named", colour: .teal, kind: .automatic, siteKey: "other.org", named: true),
        ]
        s.tabs[0].group = "g1"; s.tabs[1].group = "g1"; s.tabs[2].group = "g2"; s.tabs[3].group = "g3"
        s.nextGroup = 4
    }
    #expect(await store.browserNameGroup(paneId: pane, group: "g1", name: "Trip Planning"))
    var s = await store.browserSnapshot(paneId: pane)
    #expect(s.group("g1")?.name == "Trip Planning" && s.group("g1")?.named == true && s.group("g1")?.kind == .automatic)
    #expect(!(await store.browserNameGroup(paneId: pane, group: "g1", name: "Again")), "named already")
    #expect(!(await store.browserNameGroup(paneId: pane, group: "g2", name: "X")), "the operator's own")
    #expect(!(await store.browserNameGroup(paneId: pane, group: "g3", name: "X")))
    #expect(!(await store.browserNameGroup(paneId: pane, group: "g9", name: "X")), "dissolved")
    #expect(!(await store.browserNameGroup(paneId: "nope", group: "g1", name: "X")))
    s = await store.browserSnapshot(paneId: pane)
    #expect(s.group("g1")?.name == "Trip Planning" && s.group("g2")?.name == "Mine" && s.group("g3")?.name == "Named")
    #expect(await !store.holdsContents(paneId: "nope"))
}

@Test func readPaneCarriesGroupsAndPins() async {
    let store = await browserStore(["t1", "t2", "t3", "t4"])
    await store.updateBrowser(paneId: pane) { s in
        s.tabs[0].pin = "p00000001"
        s.groups = [
            BrowserGroup(id: "g1", name: "Docs", colour: .teal, collapsed: true, kind: .own, pin: "p00000002"),
            BrowserGroup(id: "g2", name: "Example", colour: .sand, kind: .automatic, siteKey: "example.com"),
        ]
        s.tabs[1].group = "g1"; s.tabs[2].group = "g2"; s.tabs[3].group = "g2"
        s.tabColumnHidden = true
        s.pinsError = "line 1: not JSON"
    }
    let o = object(await store.readPane(paneId: pane, kind: "browser"))
    #expect(o["tabColumnHidden"] == .bool(true) && o["pinsError"] == .string("line 1: not JSON"))
    let tabs = array(o["tabs"]).map(object)
    #expect(tabs.map { $0["group"] } == [.null, .string("g1"), .string("g2"), .string("g2")])
    #expect(tabs.map { $0["pinned"] } == [.bool(true), .bool(true), .bool(false), .bool(false)],
            "a tab of a pinned group counts as pinned")
    #expect(array(o["groups"]).map(object) == [
        ["id": .string("g1"), "name": .string("Docs"), "colour": .string("teal"), "collapsed": .bool(true),
         "kind": .string("own"), "pinned": .bool(true), "tabs": .array([.string("t2")])],
        ["id": .string("g2"), "name": .string("Example"), "colour": .string("sand"), "collapsed": .bool(false),
         "kind": .string("automatic"), "pinned": .bool(false), "tabs": .array([.string("t3"), .string("t4")])],
    ])
    let empty = object(await PaneStore(kinds: PaneKinds.standard).readPane(paneId: "x", kind: "browser"))
    #expect(empty["groups"] == .array([]) && empty["tabColumnHidden"] == .bool(false) && empty["pinsError"] == .null)
}
