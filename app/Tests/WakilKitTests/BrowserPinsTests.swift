import Foundation
import Testing

@testable import WakilKit

/// 3d-i: a pane brought in line with its project's pins (ruling 14), on the store.
@Suite("Browser pins")
struct BrowserPinsTests {
    private let pane = "browser-1"
    private let tabPin = BrowserPin(id: "p0000000a", kind: .tab, url: "https://example.com/a", title: "A")
    private let groupPin = BrowserPin(
        id: "p0000000b", kind: .group, name: "Docs", colour: .sand,
        tabs: [BrowserPinTab(url: "https://example.com/1", title: "One"),
               BrowserPinTab(url: "https://example.com/2", title: "Two")])

    /// A store whose pane holds a loose tab `t1` (active, loaded) and a pinned tab `t2` (pin `p0000000a`).
    private func store() async -> PaneStore {
        let panes = PaneStore(kinds: PaneKinds.standard)
        await panes.updateBrowser(paneId: pane, create: true) { s in
            s.tabs = [BrowserTab(id: "t1", url: "https://example.org/", title: "Org", loaded: true),
                      BrowserTab(id: "t2", url: "https://example.com/a", title: "A", loaded: true, pin: "p0000000a")]
            s.active = "t1"
            s.nextTab = 3
            s.arrange()
        }
        return panes
    }

    @Test func reconcileRemovesNothingWhenThePinsFileIsUnreadable() async {
        let panes = await store()
        let before = await panes.browserSnapshot(paneId: pane)
        let reason = "The data couldn’t be read because it isn’t in the correct format."
        await panes.browserReconcilePins(paneId: pane, pins: .failure(BrowserPinsUnreadable(reason: reason)))
        var after = await panes.browserSnapshot(paneId: pane)
        #expect(after.pinsError == reason)
        after.pinsError = nil
        #expect(after == before)

        // A readable file later clears it, and only then are stale pins removed.
        await panes.browserReconcilePins(paneId: pane, pins: .success([]))
        let cleared = await panes.browserSnapshot(paneId: pane)
        #expect(cleared.pinsError == nil)
        #expect(cleared.tabs.map(\.id) == ["t1"])
    }

    @Test func fullReconcileAddsWhatThePaneLacksUnloadedAndUnselected() async {
        let panes = await store()
        await panes.browserReconcilePins(paneId: pane, pins: .success([tabPin, groupPin]))
        let s = await panes.browserSnapshot(paneId: pane)
        #expect(s.active == "t1")
        #expect(s.tabs.map(\.id) == ["t2", "t3", "t4", "t1"])
        let g = s.groups.first
        #expect(g?.pin == "p0000000b")
        #expect(g?.name == "Docs")
        #expect(g?.colour == .sand)
        #expect(g?.kind == .own)
        for id in ["t3", "t4"] {
            let t = s.tabs.first { $0.id == id }
            #expect(t?.loaded == false)
            #expect(t?.command == nil)
            #expect(t?.group == g?.id)
        }
        // Again: nothing doubles.
        await panes.browserReconcilePins(paneId: pane, pins: .success([tabPin, groupPin]))
        #expect(await panes.browserSnapshot(paneId: pane) == s)
    }

    @Test func aClosedPinnedTabComesBackAtTheNextFullReconcile() async {
        let panes = await store()
        await panes.updateBrowser(paneId: pane) { s in s.closeTabs(["t2"]) }
        #expect(await panes.browserSnapshot(paneId: pane).tabs.map(\.id) == ["t1"])
        await panes.browserReconcilePins(paneId: pane, pins: .success([tabPin]))
        let s = await panes.browserSnapshot(paneId: pane)
        #expect(s.tabs.map(\.pin) == ["p0000000a", nil])
        #expect(s.tabs.first?.url == "https://example.com/a")
        #expect(s.tabs.first?.loaded == false)
        #expect(s.active == "t1")
    }

    @Test func aStalePinnedActiveTabIsReplacedAsCloseDoes() async {
        let panes = await store()
        await panes.updateBrowser(paneId: pane) { s in s.active = "t2" }
        await panes.browserReconcilePins(paneId: pane, pins: .success([]))
        let s = await panes.browserSnapshot(paneId: pane)
        #expect(s.tabs.map(\.id) == ["t1"])
        #expect(s.active == "t1")
        #expect(s.closed.isEmpty)
    }

    @Test func aPullRequestGroupLosesOnlyItsPin() async {
        let panes = await store()
        await panes.updateBrowser(paneId: pane) { s in
            s.groups.append(BrowserGroup(id: "pr", name: "Pull Requests", colour: .blue, collapsed: true,
                                         kind: .pullRequests, pin: "p0000000c"))
            s.tabs.append(BrowserTab(id: "t9", url: "https://github.com/x/y/pull/1", title: "PR", group: "pr",
                                     pullRequest: "https://github.com/x/y/pull/1"))
            s.arrange()
        }
        await panes.browserApplyPin(paneId: pane, add: nil, remove: "p0000000c")
        let s = await panes.browserSnapshot(paneId: pane)
        #expect(s.group("pr")?.pin == nil)
        #expect(s.tabs.contains { $0.id == "t9" })
    }

    @Test func deltaLeavesAPaneItHoldsNothingFor() async {
        let panes = PaneStore(kinds: PaneKinds.standard)
        #expect(await panes.browserApplyPin(paneId: "browser-9", add: tabPin, remove: nil) == nil)
        #expect(await panes.browserSnapshot(paneId: "browser-9").tabs.isEmpty)
    }
}
