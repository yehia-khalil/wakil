import Foundation
import Testing
@testable import WakilKit

private let pane = "b1"

private func store(_ urls: [String] = ["https://example.com/"]) async -> PaneStore {
    let store = PaneStore(kinds: PaneKinds.standard)
    await store.updateBrowser(paneId: pane, create: true) { s in
        s.tabs = urls.enumerated().map { BrowserTab(id: "t\($0.offset + 1)", url: $0.element, title: "T") }
        s.active = "t1"; s.nextTab = urls.count + 1
    }
    return store
}

private func el(_ ref: String, _ label: String = "Name") -> BrowserElement {
    BrowserElement(ref: ref, role: "textbox", label: label)
}

private func report(_ url: String, title: String = "Page") -> BrowserPageReport {
    BrowserPageReport(url: url, title: title, isLoading: false, progress: 1, canGoBack: false,
                      canGoForward: false, failure: nil)
}

@Test func consentIsPerConversation() async {
    let s = await store()
    await s.browserAllow(site: "example.com", conversation: "c1")
    #expect(await s.browserAllowed(conversation: "c1") == ["example.com"])
    #expect(await s.browserAllowed(conversation: "c2").isEmpty)
}

@Test func forgetDropsOnlyThatConversation() async {
    let s = await store()
    await s.browserAllow(site: "example.com", conversation: "c1")
    await s.browserAllow(site: "initech.dev", conversation: "c2")
    await s.browserForget(conversation: "c1")
    #expect(await s.browserAllowed(conversation: "c1").isEmpty)
    #expect(await s.browserAllowed(conversation: "c2") == ["initech.dev"])
}

@Test func revokeOfASiteNotAllowedChangesNothing() async {
    let s = await store()
    await s.browserAllow(site: "example.com", conversation: "c1")
    await s.browserRevoke(site: "other.com", conversation: "c1")
    #expect(await s.browserAllowed(conversation: "c1") == ["example.com"])
    await s.browserRevoke(site: "example.com", conversation: "c1")
    #expect(await s.browserAllowed(conversation: "c1").isEmpty)
}

@Test func aReportWithANewURLDropsTheRead() async {
    let s = await store()
    #expect(await s.browserRecordRead(paneId: pane, tab: "t1", url: "https://example.com/", site: "example.com", elements: [el("e1")]))
    await s.browserPageDidReport(paneId: pane, tab: "t1", report("https://example.com/", title: "New title"))
    #expect(await s.browserSnapshot(paneId: pane).tabs[0].lastRead != nil)
    await s.browserPageDidReport(paneId: pane, tab: "t1", report("https://example.com/#frag"))
    #expect(await s.browserSnapshot(paneId: pane).tabs[0].lastRead == nil)
}

@Test func refsAreNeverReusedInATab() async {
    let s = await store()
    _ = await s.browserRecordRead(paneId: pane, tab: "t1", url: "https://example.com/", site: "example.com",
                                  elements: [el("e1"), el("e2"), el("e3")])
    #expect(await s.browserSnapshot(paneId: pane).tabs[0].refsIssued == 3)
    await s.browserDropRead(paneId: pane, tab: "t1")
    let t = await s.browserSnapshot(paneId: pane).tabs[0]
    #expect(t.lastRead == nil && t.refsIssued == 3)
    _ = await s.browserRecordRead(paneId: pane, tab: "t1", url: "https://example.com/", site: "example.com",
                                  elements: [el("e4")])
    #expect(await s.browserSnapshot(paneId: pane).tabs[0].refsIssued == 4)
}

@Test func aReadForAClosedTabIsDropped() async {
    let s = await store()
    #expect(await s.browserRecordRead(paneId: pane, tab: "t9", url: "https://example.com/", site: "example.com", elements: []) == false)
    #expect(await s.browserRecordRead(paneId: "nope", tab: "t1", url: "https://example.com/", site: "example.com", elements: []) == false)
}

@Test func readPaneTagsEachTabAndHoldsNoPageText() async {
    let s = await store(["https://staging.initech.dev/", "https://api.initech.com/", "about:blank"])
    await s.browserSetSites(org: LayoutScope.initial.organization, BrowserSites(
        environment: ["staging.initech.dev": "staging"], production: ["api.initech.com"], read: true))
    _ = await s.browserRecordRead(paneId: pane, tab: "t1", url: "https://staging.initech.dev/",
                                  site: "staging.initech.dev", elements: [el("e1", "Secret label")])
    let reply = await s.readPane(paneId: pane, kind: "browser")
    guard case .object(let o) = reply, case .array(let tabs) = o["tabs"], tabs.count == 3,
          case .object(let a) = tabs[0], case .object(let b) = tabs[1], case .object(let c) = tabs[2]
    else { Issue.record("shape"); return }
    #expect(a["site"] == .string("staging.initech.dev") && a["environment"] == .string("staging") && a["production"] == .bool(false))
    #expect(b["site"] == .string("api.initech.com") && b["environment"] == .null && b["production"] == .bool(true))
    #expect(c["site"] == .null && c["environment"] == .null && c["production"] == .bool(false))
    let encoded = String(decoding: try! JSONEncoder().encode(reply), as: UTF8.self)
    #expect(!encoded.contains("Secret label") && !encoded.contains("lastRead") && !encoded.contains("elements"))
}

@Test func sitesAreKeptPerOrganisation() async {
    let s = await store()
    let a = BrowserSites(environment: [:], production: ["a.com"], read: true)
    #expect(await s.browserSites(org: "initech") == .unread)
    await s.browserSetSites(org: "initech", a)
    #expect(await s.browserSites(org: "initech") == a)
    #expect(await s.browserSites(org: "other") == .unread)
}

@Test func aReadWhoseRefsAnotherReadIssuedIsRefused() async {
    let s = await store()
    #expect(await s.browserRecordRead(paneId: pane, tab: "t1", url: "https://example.com/", site: "example.com",
                                      elements: [el("e1", "Delete")], firstRef: 1, highestRef: 5))
    // Began at e1 too, before the first was recorded: refused, and the first read stands.
    #expect(await s.browserRecordRead(paneId: pane, tab: "t1", url: "https://example.com/", site: "example.com",
                                      elements: [el("e1", "Cancel")], firstRef: 1) == false)
    let tab = await s.browserSnapshot(paneId: pane).tabs[0]
    #expect(tab.lastRead?.elements["e1"]?.label == "Delete")
    #expect(tab.refsIssued == 5)
}
