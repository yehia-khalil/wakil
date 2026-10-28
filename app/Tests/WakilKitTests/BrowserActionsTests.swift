import Foundation
import Testing
@testable import WakilKit

/// The settings a fixture's actions read; a test changes them between dispatches.
final class BrowserSettingsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: SettingsBrowser
    init(_ value: SettingsBrowser) { self.value = value }
    var current: SettingsBrowser {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// What a fixture's `copyText` put on its pasteboard, in order.
final class BrowserCopies: @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String] = []
    var all: [String] { lock.withLock { texts } }
    func add(_ text: String) { lock.withLock { texts.append(text) } }
}

struct BrowserFixture {
    let registry: ActionRegistry
    let panes: PaneStore
    let layout: LayoutStore
    let settings: BrowserSettingsBox
    var pane: String

    /// Dispatches `name`, naming the fixture's pane unless `params` names one or `named` is false.
    @discardableResult
    func dispatch(_ name: String, _ params: [String: JSONValue] = [:], named: Bool = true,
                  origin: ActionOrigin = .agent, confirmation: String? = nil) async throws -> JSONValue {
        var p = params
        if named, p["pane"] == nil { p["pane"] = .string(pane) }
        return try await registry.dispatch(name: name, params: .object(p), origin: origin,
                                           caller: .test("staging"), confirmation: confirmation)
    }
    func snapshot() async -> BrowserSnapshot { await panes.browserSnapshot(paneId: pane) }
    func active() async -> BrowserTab? { await snapshot().activeTab }
}

/// A layout with one browser pane (no tabs yet) and the browser actions over it — `editorFixture`'s
/// shape. `open` false leaves the canvas empty.
func browserFixture(startPage: String = "", open: Bool = true, orgFiles: BrowserOrgFiles? = nil,
                    removeData: BrowserDataRemover? = nil,
                    pullRequests: @escaping BrowserPullRequestsRead = { nil },
                    copyText: BrowserTextCopier? = nil) async throws -> BrowserFixture {
    let dir = testScratchRoot.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let registry = ActionRegistry(journalDirectory: dir, sessionId: "t")
    let layout = LayoutStore()
    let pane = open ? await layout.open(kind: "browser", title: "Browser").id : ""
    let panes = PaneStore(kinds: PaneKinds.standard)
    let settings = BrowserSettingsBox(SettingsBrowser(searchEngine: "google", startPage: startPage))
    await registerBrowserActions(into: registry, panes: panes, layout: layout, settings: { settings.current },
                                 orgFiles: { orgFiles }, removeData: removeData, pullRequests: pullRequests,
                                 copyText: copyText)
    return BrowserFixture(registry: registry, panes: panes, layout: layout, settings: settings, pane: pane)
}

/// A fixture whose pane holds tabs on `urls`, the first active, every one loaded.
private func withTabs(_ urls: [String]) async throws -> BrowserFixture {
    let f = try await browserFixture()
    for u in urls { try await f.dispatch("browser_new_tab", ["url": .string(u)]) }
    await f.panes.updateBrowser(paneId: f.pane) { s in
        for i in s.tabs.indices { s.tabs[i].loaded = true }
        s.active = s.tabs.first?.id
    }
    return f
}

private func refusal(_ body: () async throws -> Void) async -> String? {
    do { try await body(); return nil } catch { return String(describing: error) }
}

@Test func navigateResolvesTypedText() async throws {
    let f = try await withTabs(["https://a.test/"])
    try await f.dispatch("browser_navigate", ["input": .string("localhost:3000")])
    let t = try #require(await f.active())
    #expect(t.command?.verb == .load("http://localhost:3000"))
    #expect(t.url == "http://localhost:3000")
}

@Test func navigateRefusesBlank() async throws {
    let f = try await withTabs(["https://a.test/"])
    let before = await f.snapshot()
    let why = await refusal { try await f.dispatch("browser_navigate", ["input": .string("   ")]) }
    #expect(why == "Type an address or words to search.")
    #expect(await f.snapshot() == before)
}

@Test func navigateRefusesJavascript() async throws {
    let f = try await withTabs(["https://a.test/"])
    let before = await f.snapshot()
    let why = await refusal { try await f.dispatch("browser_navigate", ["input": .string("javascript:alert(1)")]) }
    #expect(why == "javascript: addresses don't run here — open the page and use Inspect Element.")
    #expect(await f.snapshot() == before)
}

@Test func openAndNewTabRefuseAsNavigateDoes() async throws {
    let f = try await withTabs(["https://a.test/"])
    let before = await f.snapshot()
    for (name, key) in [("browser_open", "url"), ("browser_new_tab", "url"), ("browser_navigate", "input")] {
        #expect(await refusal { try await f.dispatch(name, [key: .string("javascript:alert(1)")]) }
            == "javascript: addresses don't run here — open the page and use Inspect Element.", "\(name)")
    }
    for name in ["browser_open", "browser_new_tab"] {
        #expect(await refusal { try await f.dispatch(name, ["url": .string("  ")]) }
            == "Type an address or words to search.", "\(name)")
    }
    #expect(await f.snapshot() == before)
    let g = try await browserFixture(open: false)
    #expect(await refusal { try await g.dispatch("browser_open", ["url": .string("javascript:x")], named: false) } != nil)
    #expect(await g.layout.snapshot().panes.isEmpty, "a refused open opens no pane")
}

@Test func focusAddressIsACommand() async throws {
    let f = try await withTabs(["https://a.test/"])
    let seq = await f.active()?.command?.seq ?? 0
    try await f.dispatch("browser_focus_address")
    #expect(await f.active()?.command == BrowserCommand(seq: seq + 1, verb: .focusAddress))
}

@Test func commandSeqsRiseFromARestoredTab() async throws {
    let f = try await browserFixture()
    await f.layout.setBrowserTabs(id: f.pane, to: [BrowserSavedTab(id: "t3", url: "https://a.test/", title: "A")], active: "t3", groups: [], columnHidden: false)
    try await f.dispatch("browser_restore", origin: .ui)
    #expect(await f.active()?.command == BrowserCommand(seq: 1, verb: .load("https://a.test/")))
    try await f.dispatch("browser_reload")
    #expect(await f.active()?.command?.seq == 2)
    try await f.dispatch("browser_back")
    #expect(await f.active()?.command == BrowserCommand(seq: 3, verb: .back))
    // New tabs keep counting from the restored ids.
    try await f.dispatch("browser_new_tab", ["url": .string("https://b.test/")])
    #expect(await f.active()?.id == "t4")
}

@Test func closingTheLastTabClosesThePane() async throws {
    let f = try await withTabs(["https://a.test/"])
    let reply = try await f.dispatch("browser_close_tab")
    #expect(reply == .object(["pane": .string(f.pane), "closed": .bool(true)]))
    #expect(await !f.layout.snapshot().panes.contains { $0.id == f.pane })
    #expect(await !f.panes.holdsContents(paneId: f.pane))
}

@Test func closingSelectsTheRightNeighbourThenLeft() async throws {
    let f = try await withTabs(["https://a.test/", "https://b.test/", "https://c.test/"])
    try await f.dispatch("browser_select_tab", ["tab": .string("t2")])
    try await f.dispatch("browser_close_tab")
    #expect(await f.snapshot().active == "t3", "the right neighbour")
    try await f.dispatch("browser_close_tab")
    #expect(await f.snapshot().active == "t1", "no right neighbour: the left")
    // Closing a tab that is not selected leaves the selection.
    try await f.dispatch("browser_new_tab", ["url": .string("https://d.test/")])
    try await f.dispatch("browser_close_tab", ["tab": .string("t1")])
    #expect(await f.snapshot().active == "t4")
    #expect(await f.snapshot().closed.map(\.url) == ["https://b.test/", "https://c.test/", "https://a.test/"])
}

@Test func reopenRestoresTheLastClosed() async throws {
    let g = try await withTabs(["https://a.test/", "https://b.test/", "https://c.test/"])
    try await g.dispatch("browser_close_tab", ["tab": .string("t1")])
    try await g.dispatch("browser_close_tab", ["tab": .string("t2")])
    try await g.dispatch("browser_reopen_tab")
    let t = try #require(await g.active())
    #expect(t.url == "https://b.test/" && t.command?.verb == .load("https://b.test/") && !t.loaded)
    #expect(await g.snapshot().closed.map(\.url) == ["https://a.test/"])
    try await g.dispatch("browser_reopen_tab")
    #expect(await g.active()?.url == "https://a.test/")
    let why = await refusal { try await g.dispatch("browser_reopen_tab") }
    #expect(why == "browser_reopen_tab: no closed tab to reopen in this pane")
}

@Test func selectingAnUnloadedTabLoadsIt() async throws {
    let f = try await browserFixture()
    await f.layout.setBrowserTabs(id: f.pane, to: [
        BrowserSavedTab(id: "t1", url: "https://a.test/", title: "A"),
        BrowserSavedTab(id: "t2", url: "https://b.test/", title: "B"),
    ], active: "t1", groups: [], columnHidden: false)
    try await f.dispatch("browser_restore", origin: .ui)
    #expect(await f.snapshot().tabs[1].command == nil)
    try await f.dispatch("browser_select_tab", ["index": .integer(-1)])
    let t = try #require(await f.active())
    #expect(t.id == "t2" && t.command == BrowserCommand(seq: 1, verb: .load("https://b.test/")))
    // Selected again while its load still waits: no second load.
    try await f.dispatch("browser_select_tab", ["index": .integer(0)])
    try await f.dispatch("browser_select_tab", ["tab": .string("t2")])
    #expect(await f.active()?.command?.seq == 1)
    // A loaded tab is only selected.
    await f.panes.browserPageDidReport(paneId: f.pane, tab: "t1", BrowserPageReport(
        url: "https://a.test/", title: "A", isLoading: false, progress: 1, canGoBack: false, canGoForward: false, failure: nil))
    try await f.dispatch("browser_select_tab", ["tab": .string("t1")])
    #expect(await f.active()?.command?.seq == 1)
}

@Test func zoomStepsThroughTheFixedLadder() async throws {
    let f = try await withTabs(["https://a.test/"])
    try await f.dispatch("browser_zoom", ["step": .string("in")])
    #expect(await f.active()?.zoom == 1.1)
    try await f.dispatch("browser_zoom", ["step": .string("in")])
    #expect(await f.active()?.zoom == 1.25)
    #expect(await f.active()?.command?.verb == .zoom(1.25))
    try await f.dispatch("browser_zoom", ["step": .string("reset")])
    #expect(await f.active()?.zoom == 1.0)
    await f.panes.updateBrowser(paneId: f.pane) { s in s.tabs[0].zoom = 0.5 }
    try await f.dispatch("browser_zoom", ["step": .string("out")])
    #expect(await f.active()?.zoom == 0.5)
    await f.panes.updateBrowser(paneId: f.pane) { s in s.tabs[0].zoom = 3.0 }
    try await f.dispatch("browser_zoom", ["step": .string("in")])
    #expect(await f.active()?.zoom == 3.0)
}

@Test func newTabUsesTheStartPage() async throws {
    let f = try await browserFixture(startPage: "https://example.com")
    try await f.dispatch("browser_new_tab")
    #expect(await f.active()?.command?.verb == .load("https://example.com"))
    f.settings.current = SettingsBrowser(searchEngine: "google", startPage: "")
    try await f.dispatch("browser_new_tab")
    let t = try #require(await f.active())
    #expect(t.url == "" && t.command?.verb == .focusAddress)
    #expect(await f.snapshot().tabs.count == 2)
}

@Test func browserOpenOpensAPaneWhenNoneIsOpen() async throws {
    let f = try await browserFixture(open: false)
    let reply = try await f.dispatch("browser_open", ["url": .string("https://a.test/")], named: false)
    let panes = await f.layout.snapshot().panes
    #expect(panes.count == 1 && panes[0].kind == "browser" && panes[0].title == "Browser")
    let pane = panes[0].id
    guard case .object(let o) = reply else { Issue.record("no reply"); return }
    #expect(o["pane"] == .string(pane))
    let s = await f.panes.browserSnapshot(paneId: pane)
    #expect(s.tabs.count == 1 && s.activeTab?.command?.verb == .load("https://a.test/"))
    // A second open adds a tab to that pane rather than opening another.
    try await f.dispatch("browser_open", ["url": .string("https://b.test/")], named: false)
    #expect(await f.layout.snapshot().panes.count == 1)
    #expect(await f.panes.browserSnapshot(paneId: pane).tabs.count == 2)
    // newTab false loads into the active tab.
    try await f.dispatch("browser_open", ["url": .string("https://c.test/"), "newTab": .bool(false)], named: false)
    let after = await f.panes.browserSnapshot(paneId: pane)
    #expect(after.tabs.count == 2 && after.activeTab?.url == "https://c.test/")
}

/// The 3c spec's call 11, the rule a link from elsewhere in Wakil opens by: a new tab in the focused
/// browser pane, else the one most recently focused (not merely the last opened), else a new pane.
@Test func browserOpenPicksTheFocusedThenTheMostRecentlyFocusedBrowserPane() async throws {
    let f = try await browserFixture()
    let first = f.pane
    let second = await f.layout.open(kind: "browser", title: "Browser").id
    let editor = await f.layout.open(kind: "editor", title: "Editor").id
    func tabs(_ pane: String) async -> Int { await f.panes.browserSnapshot(paneId: pane).tabs.count }

    try await f.layout.focus(id: first)
    try await f.dispatch("browser_open", ["url": .string("https://a.test/")], named: false)
    #expect(await tabs(first) == 1)
    #expect(await tabs(second) == 0)

    // The editor holds focus: the browser pane focused last takes the link, though another was opened after it.
    try await f.layout.focus(id: editor)
    try await f.dispatch("browser_open", ["url": .string("https://b.test/")], named: false)
    #expect(await tabs(first) == 2)
    #expect(await tabs(second) == 0)
    #expect(await f.layout.snapshot().focusedId == editor)

    try await f.layout.focus(id: second)
    try await f.layout.focus(id: editor)
    try await f.dispatch("browser_open", ["url": .string("https://c.test/")], named: false)
    #expect(await tabs(first) == 2)
    #expect(await tabs(second) == 1)

    // The most recent one closed: the other browser pane, not a new one.
    try await f.layout.close(id: second)
    try await f.dispatch("browser_open", ["url": .string("https://d.test/")], named: false)
    #expect(await tabs(first) == 3)
    #expect(await f.layout.snapshot().panes.filter { $0.kind == "browser" }.count == 1)
}

/// Fix round I3: the rule itself, in one LayoutStore call — focused, else most recently focused, else
/// last opened — for any kind; and a reload with no pane named follows it as browser_open does.
@Test func thePreferredPaneIsTheFocusedThenTheMostRecentlyFocusedThenTheLastOpened() async throws {
    let layout = LayoutStore()
    #expect(await layout.preferredPane(kind: "browser") == nil)
    let a = await layout.open(kind: "browser", title: "Browser").id
    let b = await layout.open(kind: "browser", title: "Browser").id
    let e = await layout.open(kind: "editor", title: "Editor").id
    #expect(await layout.preferredPane(kind: "browser") == b)   // b took focus last when it opened
    try await layout.focus(id: a)
    #expect(await layout.preferredPane(kind: "browser") == a)   // focused
    try await layout.focus(id: e)
    #expect(await layout.preferredPane(kind: "browser") == a)   // most recently focused
    #expect(await layout.preferredPane(kind: "editor") == e)
    // A restored arrangement has no focus history: the last opened.
    await layout.load(await layout.snapshot(), for: .initial)
    try await layout.focus(id: e)
    #expect(await layout.preferredPane(kind: "browser") == b)
    // A pane opened without focus (a link from another surface) is in no focus order and moves no focus.
    let c = await layout.open(kind: "browser", title: "Browser", focus: false).id
    #expect(await layout.snapshot().focusedId == e)
    #expect(await layout.preferredPane(kind: "browser") == c)
}

/// 3c-iii walk: browser_open with focus — openLinkInWakil's — brings the pane it used forward, the one
/// it opened and one already open alike; without it (the agent's, the palette's) a pane it opens is
/// focused and one already open is left where it is.
@Test func browserOpenWithFocusFocusesThePaneItUsed() async throws {
    let f = try await browserFixture(open: false)
    let editor = await f.layout.open(kind: "editor", title: "Editor").id
    try await f.dispatch("browser_open", ["url": .string("https://a.test/"), "focus": .bool(true)], named: false)
    let browser = try #require(await f.layout.snapshot().panes.first { $0.kind == "browser" }).id
    #expect(await f.layout.snapshot().focusedId == browser)
    try await f.layout.focus(id: editor)
    try await f.dispatch("browser_open", ["url": .string("https://b.test/"), "focus": .bool(true)], named: false)
    #expect(await f.layout.snapshot().focusedId == browser)
    #expect(await f.panes.browserSnapshot(paneId: browser).tabs.count == 2)
    try await f.layout.focus(id: editor)
    try await f.dispatch("browser_open", ["url": .string("https://c.test/")], named: false)
    #expect(await f.layout.snapshot().focusedId == editor)
    try await f.layout.close(id: browser)
    try await f.dispatch("browser_open", ["url": .string("https://d.test/")], named: false)
    let after = await f.layout.snapshot()
    #expect(after.focusedId != editor && after.panes.first { $0.id == after.focusedId }?.kind == "browser")
}

@Test func actionsOtherThanOpenRefuseWithNoBrowserPane() async throws {
    let f = try await browserFixture(open: false)
    let why = await refusal { try await f.dispatch("browser_reload", named: false) }
    #expect(why == "No browser pane is open.")
    #expect(await f.layout.snapshot().panes.isEmpty)
}

@Test func theFocusedBrowserPaneIsTheDefault() async throws {
    let f = try await browserFixture()
    let second = await f.layout.open(kind: "browser", title: "Browser").id
    try await f.dispatch("browser_new_tab", ["url": .string("https://a.test/")], named: false)
    #expect(await f.panes.browserSnapshot(paneId: second).tabs.count == 1)
    try await f.layout.focus(id: f.pane)
    try await f.dispatch("browser_new_tab", ["url": .string("https://b.test/")], named: false)
    #expect(await f.snapshot().tabs.count == 1)
}

@Test func moveFindAndDownloads() async throws {
    let f = try await withTabs(["https://a.test/", "https://b.test/", "https://c.test/"])
    try await f.dispatch("browser_move_tab", ["tab": .string("t1"), "to": .integer(9)])
    #expect(await f.snapshot().tabs.map(\.id) == ["t2", "t3", "t1"])
    try await f.dispatch("browser_find", ["query": .string("x")])
    try await f.dispatch("browser_find_step", ["forward": .bool(false)])
    let find = try #require(await f.snapshot().find)
    #expect(find.query == "x" && find.seq == 2 && !find.forward)
    try await f.dispatch("browser_find_close")
    #expect(await f.snapshot().find == nil)
    #expect(await refusal { try await f.dispatch("browser_find_step") } == BrowserActionError.findClosed.description)
    await f.panes.browserDownloadDidChange(paneId: f.pane, BrowserDownload(id: "d1", filename: "a", received: 1, expected: 2, state: .running))
    await f.panes.browserDownloadDidChange(paneId: f.pane, BrowserDownload(id: "d2", filename: "b", received: 2, expected: 2, state: .finished))
    try await f.dispatch("browser_download_cancel", ["download": .string("d1")])
    try await f.dispatch("browser_download_cancel", ["download": .string("d2")])
    var d = await f.snapshot().downloads
    #expect(d.map(\.state) == [.running, .finished], "the ask alone changes no state")
    #expect(d.map(\.cancelRequested) == [true, false], "an ended download is left as it is")
    #expect(await refusal { try await f.dispatch("browser_download_cancel", ["download": .string("nope")]) }
        == BrowserActionError.noDownload(id: "nope").description)
    // Progress while the host is stopping it keeps the ask; the host's final report ends it.
    await f.panes.browserDownloadDidChange(paneId: f.pane, BrowserDownload(id: "d1", filename: "a", received: 2, expected: 2, state: .running))
    #expect(await f.snapshot().downloads[0].cancelRequested)
    await f.panes.browserDownloadDidChange(paneId: f.pane, BrowserDownload(id: "d1", filename: "a", received: 2, expected: 2, state: .cancelled))
    d = await f.snapshot().downloads
    #expect(d[0].state == .cancelled && !d[0].cancelRequested)
    await f.panes.browserDownloadDidChange(paneId: f.pane, BrowserDownload(id: "d3", filename: "c", received: 0, expected: 2, state: .running))
    try await f.dispatch("browser_downloads_clear")
    #expect(await f.snapshot().downloads.map(\.id) == ["d3"])
}

@Test func savedTabsFollowTheActions() async throws {
    let f = try await withTabs(["https://a.test/", "https://b.test/"])
    try await f.dispatch("browser_select_tab", ["tab": .string("t2")])
    var saved = try #require(await f.layout.browserTabs(id: f.pane))
    #expect(saved.tabs.map(\.url) == ["https://a.test/", "https://b.test/"] && saved.active == "t2")
    try await f.dispatch("browser_close_tab")
    saved = try #require(await f.layout.browserTabs(id: f.pane))
    #expect(saved.tabs.map(\.id) == ["t1"] && saved.active == "t1")
}

@Test func browserRestoreIsTheOperatorsAlone() async throws {
    #expect(operatorOnlyActions.contains("browser_restore"))
    let f = try await browserFixture()
    let all = await f.registry.all()
    #expect(all.first { $0.name == "browser_restore" }?.audience == .operatorOnly)
    // browser_print too (final review I6): its panel is the operator's window's. 3c-ii's reach into
    // the page (a read, five priced acts, the operator's revoke) is pinned in BrowserReachActionsTests.
    let reach = ["browser_read_page", "browser_click", "browser_type", "browser_select", "browser_press",
                 "browser_scroll", "browser_revoke_site"]
    #expect(all.filter { $0.name.hasPrefix("browser_") && !(["browser_restore", "browser_clear_data", "browser_print"] + reach).contains($0.name) }
        .allSatisfy { $0.audience == .agentReachable && $0.kind == .control })
}

// MARK: browser_clear_data

private final class Removed: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [UUID] = []
    func add(_ id: UUID) { lock.withLock { ids.append(id) } }
    var all: [UUID] { lock.withLock { ids } }
}

private func clearFixture(removed: Removed?, org: String? = "acme") async throws -> (BrowserFixture, BrowserOrgFiles?) {
    let home = testScratchRoot.appendingPathComponent(UUID().uuidString)
    let files = try org.map { try BrowserOrgFiles(home: home, org: $0) }
    var remover: BrowserDataRemover?
    // As the window's remover does: the store, then the files it is handed.
    if let removed { remover = { @Sendable id, deleteFiles in removed.add(id); try deleteFiles() } }
    return (try await browserFixture(orgFiles: files, removeData: remover), files)
}

@Test func clearDataRemovesTheStoreAndTheFilesButKeepsTheIdentifier() async throws {
    let removed = Removed()
    let (f, maybe) = try await clearFixture(removed: removed)
    let files = try #require(maybe)
    let id = try files.identifier()
    try files.setZoom(1.5, host: "a.test")
    let state = files.stateURL(tab: "t1")
    try FileManager.default.createDirectory(at: state.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: state)
    try await f.dispatch("browser_clear_data", ["org": .string("acme")], named: false, origin: .ui, confirmation: "confirm")
    #expect(removed.all == [id])
    #expect(!FileManager.default.fileExists(atPath: state.deletingLastPathComponent().path))
    #expect(files.zoom(host: "a.test") == 1.0)
    #expect(try files.identifier() == id)
}

@Test func clearDataAsksFirstInEveryEnvironment() async throws {
    let removed = Removed()
    let (f, _) = try await clearFixture(removed: removed)
    for caller in [DispatchCaller.test("staging"), .test("production")] {
        do {
            _ = try await f.registry.dispatch(name: "browser_clear_data", params: .object(["org": .string("acme")]), origin: .ui,
                                              caller: caller, confirmation: nil)
            Issue.record("ran without a confirmation")
        } catch let error as ActionError {
            #expect(error == .needsConfirmation("browser_clear_data"))
        } catch {
            Issue.record("refused for another reason: \(error)")
        }
    }
    #expect(removed.all.isEmpty)
}

@Test func clearDataIsRefusedWhereNothingCanRemoveTheStore() async throws {
    let (f, _) = try await clearFixture(removed: nil)
    let why = await refusal { try await f.dispatch("browser_clear_data", ["org": .string("acme")], named: false, origin: .ui, confirmation: "confirm") }
    #expect(why == "Browsing data can only be cleared from the app.")
}

@Test func clearDataIsRefusedWithNoOrganisation() async throws {
    let removed = Removed()
    let (f, _) = try await clearFixture(removed: removed, org: nil)
    let why = await refusal { try await f.dispatch("browser_clear_data", ["org": .string("acme")], named: false, origin: .ui, confirmation: "confirm") }
    #expect(why == "No organisation is active.")
    #expect(removed.all.isEmpty)
}

/// Task 10 (must-fix, destructive): the confirmation named an organisation; if another one is
/// active by the time the yes arrives, nothing is deleted — the operator was asked about the first.
@Test func clearDataRefusesWhenTheOrganisationTheQuestionNamedIsNotActive() async throws {
    let removed = Removed()
    let (f, _) = try await clearFixture(removed: removed)
    let why = await refusal {
        try await f.dispatch("browser_clear_data", ["org": .string("globex")], named: false, origin: .ui, confirmation: "confirm")
    }
    #expect(why == "The organisation changed; ask again.")
    #expect(removed.all.isEmpty, "nothing deleted")
    let unnamed = await refusal { try await f.dispatch("browser_clear_data", named: false, origin: .ui, confirmation: "confirm") }
    // The registry does not hold params to the schema, so this reaches the handler's own guard:
    // a yes that names no organisation is not a yes for the active one.
    #expect(unnamed == "The organisation changed; ask again.", "an unnamed organisation is refused by the guard")
    #expect(removed.all.isEmpty)
}

/// `pane_open {kind: "browser"}` gives the pane its first tab (spec: it arrives with one tab), the
/// way a terminal opens with its shell: `browser_new_tab`'s handler, run by `pane_open`.
@Test func paneOpenGivesABrowserItsFirstTab() async throws {
    let dir = testScratchRoot.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let registry = ActionRegistry(journalDirectory: dir, sessionId: "t")
    let layout = LayoutStore()
    let panes = PaneStore(kinds: PaneKinds.standard)
    let browser = browserActions(panes: panes, layout: layout, settings: { .defaults })
    await registerLayoutActions(into: registry, layout: layout, panes: panes,
                                openBrowserTab: browser.first { $0.name == "browser_new_tab" }?.handler)
    for action in browser { await registry.register(action) }
    let opened = try await registry.dispatch(name: "pane_open", params: .object(["kind": .string("browser")]),
                                             origin: .agent, caller: .test("staging"), confirmation: nil)
    guard case .object(let o) = opened, case .string(let pane)? = o["id"] else {
        Issue.record("pane_open answered \(opened)")
        return
    }
    let s = await panes.browserSnapshot(paneId: pane)
    #expect(s.tabs.count == 1 && s.active == s.tabs[0].id)
    #expect(s.activeTab?.command?.verb == .focusAddress, "a blank start page: the address field takes the keyboard")
    #expect(await layout.browserTabs(id: pane)?.tabs.count == 1, "saved with the layout")
    // Another kind is opened as before.
    _ = try await registry.dispatch(name: "pane_open", params: .object(["kind": .string("editor")]),
                                    origin: .agent, caller: .test("staging"), confirmation: nil)
    #expect(await layout.snapshot().panes.count == 2)
}

/// The action deletes the files only when the remover asks (`deleteFiles`) — the window does once
/// the store's web views are gone and the store with them (`browserRemoveStoreThenFiles`), so no
/// page left alive can write a tab state after. Nothing is deleted after the remover returns: a page
/// rebuilt by then may have written its new state.
@Test func clearDataHandsTheRemoverTheFileDeletion() async throws {
    let home = testScratchRoot.appendingPathComponent(UUID().uuidString)
    let files = try BrowserOrgFiles(home: home, org: "acme")
    _ = try files.identifier()
    let state = files.stateURL(tab: "t1")
    func writeState() throws {
        try FileManager.default.createDirectory(at: state.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: state)
    }
    try writeState()
    let steps = Removed()
    let mark = UUID()
    let f = try await browserFixture(orgFiles: files, removeData: { @Sendable id, deleteFiles in
        // The window's views are gone by here: the state is still on disk until it asks.
        if FileManager.default.fileExists(atPath: state.path) { steps.add(mark) }
        try deleteFiles()
        if !FileManager.default.fileExists(atPath: state.path) { steps.add(id) }
    })
    try await f.dispatch("browser_clear_data", ["org": .string("acme")], named: false, origin: .ui, confirmation: "confirm")
    #expect(steps.all == [mark, try files.identifier()], "files deleted when the remover asks, and only then")

    // A page rebuilt once the store is gone writes its new state; the action deletes nothing after
    // the remover, so that state stays (Task 7's carry: the files go once, in the remover's order).
    let rebuilt = try await browserFixture(orgFiles: files, removeData: { @Sendable _, deleteFiles in
        try deleteFiles()
        try FileManager.default.createDirectory(at: state.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: state)
    })
    try await rebuilt.dispatch("browser_clear_data", ["org": .string("acme")], named: false, origin: .ui, confirmation: "confirm")
    #expect(FileManager.default.fileExists(atPath: state.path), "a rebuilt page's state is not deleted after the remover")
}

/// Fix round 1 (Ruling: browser_zoom persists): the action writes the factor for the active tab's
/// host into the organisation's zoom.json — no web view needed (Invariant 2: the agent's zoom and
/// the operator's take one path). The host is the URL's, lowercased, as the web view reads it.
@Test func zoomPersistsForTheTabsHostWithNoLiveView() async throws {
    let home = testScratchRoot.appendingPathComponent(UUID().uuidString)
    let files = try BrowserOrgFiles(home: home, org: "acme")
    let f = try await browserFixture(orgFiles: files)
    try await f.dispatch("browser_new_tab", ["url": .string("https://Docs.A.test/page")])
    try await f.dispatch("browser_zoom", ["step": .string("in")])
    #expect(files.zoom(host: "docs.a.test") == 1.1)
    try await f.dispatch("browser_zoom", ["step": .string("reset")])
    #expect(files.zoom(host: "docs.a.test") == 1.0)
    #expect(BrowserOrgFiles.zoomHost(of: URL(string: "https://Docs.A.test/x")!) == "docs.a.test")
    #expect(BrowserOrgFiles.zoomHost(of: URL(string: "about:blank")!) == nil)
}

/// A blank tab has no host: its zoom changes, nothing is written.
@Test func zoomOnABlankTabWritesNothing() async throws {
    let home = testScratchRoot.appendingPathComponent(UUID().uuidString)
    let files = try BrowserOrgFiles(home: home, org: "acme")
    let f = try await browserFixture(orgFiles: files)
    try await f.dispatch("browser_new_tab", [:])
    try await f.dispatch("browser_zoom", ["step": .string("in")])
    #expect(await f.active()?.zoom == 1.1)
    #expect(!FileManager.default.fileExists(atPath: files.directory.appendingPathComponent("zoom.json").path))
}

/// Task 10 fix round 1: the receipt after Delete names the organisation the question named, not the
/// one active when it is drawn (a clear can take two seconds; the org can change meanwhile).
@Test func theClearReceiptNamesTheOrganisationTheQuestionAsked() {
    #expect(BrowserClearDataQuestion.receipt(asked: "Acme", current: "Globex") == "Deleted Acme's browsing data.")
    #expect(BrowserClearDataQuestion.receipt(asked: nil, current: "Globex") == "Deleted Globex's browsing data.")
}

/// Fix round 1 ruling: a clear removes the WebKit store first, then the organisation's tab states
/// and zoom. A store removal that fails deletes nothing, and its error comes back whole.
@Test func aClearRemovesTheStoreFirstAndThenTheFiles() async throws {
    let steps = Removed()
    let store = UUID(), files = UUID()
    try await browserRemoveStoreThenFiles(store, removeStore: { steps.add($0) }, deleteFiles: { steps.add(files) })
    #expect(steps.all == [store, files])
}

private struct StoreInUse: Error, CustomStringConvertible {
    var description: String { #"Error Domain=WKWebSiteDataStore Code=1 "Data store is in use""# }
}

@Test func aStoreThatWillNotGoDeletesNothingAndSaysWhyWhole() async throws {
    let home = testScratchRoot.appendingPathComponent(UUID().uuidString)
    let files = try BrowserOrgFiles(home: home, org: "acme")
    try files.setZoom(1.5, host: "a.test")
    let f = try await browserFixture(orgFiles: files, removeData: { @Sendable id, deleteFiles in
        try await browserRemoveStoreThenFiles(id, removeStore: { _ in throw StoreInUse() }, deleteFiles: deleteFiles)
    })
    let why = await refusal {
        try await f.dispatch("browser_clear_data", ["org": .string("acme")], named: false, origin: .ui, confirmation: "confirm")
    }
    #expect(why == #"Error Domain=WKWebSiteDataStore Code=1 "Data store is in use""#)
    #expect(files.zoom(host: "a.test") == 1.5, "the store stayed, so its files stay too")
}

// MARK: - Final review I4: an app's link is asked about, never opened unasked

/// `browser_open` opens web pages and files only: an app's scheme (zoommtg:, mailto:) is refused
/// with a sentence, and no pane opens.
@Test func openRefusesASchemeThatIsNotAWebPage() async throws {
    let f = try await withTabs(["https://a.test/"])
    let before = await f.snapshot()
    for url in ["zoommtg://zoom.us/join?confno=1", "mailto:a@b.test", "about:blank"] {
        #expect(await refusal { try await f.dispatch("browser_open", ["url": .string(url)]) }
            == BrowserActionError.notAWebPage(scheme: String(url.prefix { $0 != ":" })).description, "\(url)")
    }
    #expect(await f.snapshot() == before)
    for url in ["https://a.test/x", "http://localhost:3000/", "file:///tmp/x.html"] {
        try await f.dispatch("browser_open", ["url": .string(url), "newTab": .bool(false)])
        #expect(await f.active()?.url == url)
    }
    let g = try await browserFixture(open: false)
    #expect(await refusal { try await g.dispatch("browser_open", ["url": .string("zoommtg://x")], named: false) } != nil)
    #expect(await g.layout.snapshot().panes.isEmpty, "a refused open opens no pane")
}

@Test func onlyWebSchemesOpenInThePage() {
    for s in ["http", "https", "file", "about", "data", "blob", "HTTPS"] {
        #expect(BrowserAddress.opensInPage(URL(string: "\(s):x")!), "\(s)")
    }
    for s in ["mailto", "zoommtg", "slack", "tel", "javascript"] {
        #expect(!BrowserAddress.opensInPage(URL(string: "\(s):x")!), "\(s)")
    }
    #expect(BrowserAddress.openInAppQuestion(app: "Zoom") == "Open in Zoom?")
    #expect(BrowserAddress.noAppLine(scheme: "zoommtg") == "No app on this Mac opens zoommtg: links.")
}

// MARK: - Final review I6: print (⌘K → Print page)

/// `browser_print` asks the active tab's page to print — one more command, which the window's
/// web view answers with the system's print panel.
@Test func printIsACommandOnTheActiveTab() async throws {
    let f = try await withTabs(["https://a.test/"])
    let seq = await f.active()?.command?.seq ?? 0
    try await f.dispatch("browser_print", origin: .ui)
    #expect(await f.active()?.command == BrowserCommand(seq: seq + 1, verb: .print))
}

@Test func browserSettingsDecodeSearchSuggestions() throws {
    let off = try JSONDecoder().decode(SettingsBrowser.self, from: Data("{}".utf8))
    #expect(off.searchSuggestions == false)
    let on = try JSONDecoder().decode(SettingsBrowser.self, from: Data(#"{"searchSuggestions": true}"#.utf8))
    #expect(on.searchSuggestions == true)
}

@Test func browserSettingsDecodeTabsAndNaming() throws {
    let d = try JSONDecoder().decode(SettingsBrowser.self, from: Data("{}".utf8))
    #expect(d.tabs == "horizontal")
    #expect(d.nameGroups == true)
    let v = try JSONDecoder().decode(
        SettingsBrowser.self, from: Data(#"{"tabs":"vertical","nameGroups":false}"#.utf8))
    #expect(v.tabs == "vertical")
    #expect(v.nameGroups == false)
}

// MARK: - Bookmarks (3c-iii Task 3)

private func bookmarkFixture(org: String = "initech") async throws -> (BrowserFixture, BrowserOrgFiles) {
    let files = try BrowserOrgFiles(home: testScratchRoot.appendingPathComponent(UUID().uuidString), org: org)
    return (try await browserFixture(orgFiles: files), files)
}


private func bookmarkFixture() async throws -> (BrowserFixture, BrowserOrgFiles) {
    let files = try BrowserOrgFiles(home: testScratchRoot.appendingPathComponent(UUID().uuidString), org: "initech")
    var f = try await browserFixture(open: false, orgFiles: files)
    let scope = LayoutScope(organization: "initech", project: "p", environment: "e")
    await f.layout.switchScope(to: scope)
    await f.panes.switchScope(to: scope)
    f.pane = await f.layout.open(kind: "browser", title: "Browser").id
    return (f, files)
}

private func bookmarked(_ reply: JSONValue) -> Bool? {
    guard case .object(let o) = reply, case .bool(let b)? = o["bookmarked"] else { return nil }
    return b
}

@Test func browserBookmarkTogglesTheActiveTabAndReadPaneSaysSo() async throws {
    let (f, files) = try await bookmarkFixture()
    try await f.dispatch("browser_new_tab", ["url": .string("https://example.com/a")])
    #expect(bookmarked(await f.panes.readPane(paneId: f.pane, kind: "browser")) == false)
    #expect(bookmarked(try await f.dispatch("browser_bookmark")) == true)
    #expect(try files.bookmarks().map(\.url) == ["https://example.com/a"])
    #expect(await f.panes.browserBookmarks(org: "initech").map(\.url) == ["https://example.com/a"])
    #expect(bookmarked(await f.panes.readPane(paneId: f.pane, kind: "browser")) == true)
    #expect(bookmarked(try await f.dispatch("browser_bookmark", ["on": .bool(true)])) == true)
    #expect(try files.bookmarks().count == 1)
    #expect(bookmarked(try await f.dispatch("browser_bookmark")) == false)
    #expect(await f.panes.browserBookmarks(org: "initech") == [])
}

@Test func browserBookmarkRefusesANonWebPage() async throws {
    let (f, files) = try await bookmarkFixture()
    try await f.dispatch("browser_new_tab", ["url": .string("about:blank")])
    await #expect(throws: BrowserActionError.notBookmarkable(scheme: "about")) {
        try await f.dispatch("browser_bookmark")
    }
    #expect(BrowserActionError.notBookmarkable(scheme: "about").description
            == "browser_bookmark: only a web page can be bookmarked, not about:")
    #expect(try files.bookmarks() == [])
}

@Test func browserBookmarkRefusesAnUnreadableFileWithTheCopy() async throws {
    let (f, files) = try await bookmarkFixture()
    try FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true)
    try Data("oops".utf8).write(to: files.directory.appendingPathComponent("bookmarks.json"))
    try await f.dispatch("browser_new_tab", ["url": .string("https://example.com/a")])
    do { try await f.dispatch("browser_bookmark"); Issue.record("should refuse") }
    catch let error as BrowserActionError {
        let text = error.description
        #expect(text.hasPrefix("browser_bookmark: bookmarks.json can't be read ("))
        #expect(text.hasSuffix(") — fix or move it; Wakil won't write over it."))
    }
}

@Test func readPaneAlwaysCarriesBookmarked() async throws {
    let (f, _) = try await bookmarkFixture()
    #expect(bookmarked(await f.panes.readPane(paneId: f.pane, kind: "browser")) == false)
}

@Test func selectTabWithFocusFocusesThePane() async throws {
    let f = try await browserFixture()
    let editor = await f.layout.open(kind: "editor", title: "Editor").id
    try await f.dispatch("browser_new_tab", ["url": .string("https://a.test/")])
    try await f.dispatch("browser_new_tab", ["url": .string("https://b.test/")])
    try await f.layout.focus(id: editor)
    try await f.dispatch("browser_select_tab", ["index": .integer(0)])
    #expect(await f.layout.snapshot().focusedId == editor)
    try await f.dispatch("browser_select_tab", ["index": .integer(1), "focus": .bool(true)])
    #expect(await f.layout.snapshot().focusedId == f.pane)
}

@Test func tabLabelFallsBackToHostThenNewTab() {
    #expect(BrowserTab(id: "t1", url: "https://example.com/x", title: "Docs").label == "Docs")
    #expect(BrowserTab(id: "t1", url: "https://www.example.com/x", title: "").label == BrowserAddress.displayHost(URL(string: "https://www.example.com/x")!))
    #expect(BrowserTab(id: "t1", url: "", title: "").label == "New Tab")
}

// MARK: - 3d-i Task 7: browser_group, browser_move_tab into a group, browser_new_tab's opener

private func fields(_ value: JSONValue?) -> [String: JSONValue] {
    if case .object(let o)? = value { return o }
    return [:]
}

/// The reply's `groups`, each as an object.
private func replyGroups(_ reply: JSONValue) -> [[String: JSONValue]] {
    guard case .array(let a)? = fields(reply)["groups"] else { return [] }
    return a.map { fields($0) }
}

/// Tabs t1–t4 (t1 active): t1 and t2 on example.com in automatic group g1, t3 and t4 loose.
private func groupedFixture() async throws -> BrowserFixture {
    let f = try await withTabs(["https://example.com/a", "https://example.com/b", "https://other.org/c",
                                "https://third.net/d"])
    await f.panes.updateBrowser(paneId: f.pane) { s in
        s.groups = [BrowserGroup(id: "g1", name: "Example", colour: .blue, kind: .automatic, siteKey: "example.com")]
        s.nextGroup = 2
        s.tabs[0].group = "g1"; s.tabs[1].group = "g1"
    }
    return f
}

@Test func newTabWithOpenerUsesTheOpenerRule() async throws {
    let f = try await withTabs(["https://example.com/a"])
    // ⌘-click from a loose tab to another site: the two form a chain group, named after the opener.
    try await f.dispatch("browser_new_tab", ["url": .string("https://other.org/x"), "opener": .string("t1")])
    var s = await f.snapshot()
    #expect(s.groups.count == 1 && s.groups[0].kind == .automatic && s.groups[0].siteKey == nil)
    #expect(s.groups[0].name == "Example")
    #expect(s.tabs.map(\.group) == ["g1", "g1"] && s.tabs[1].opener == "t1")
    #expect(s.active == "t2", "browser_new_tab still selects the new tab")
    // From a grouped tab: it joins.
    try await f.dispatch("browser_new_tab", ["url": .string("https://third.net/"), "opener": .string("t2")])
    s = await f.snapshot()
    #expect(s.tabs.map(\.group) == ["g1", "g1", "g1"])
    // The same site from a loose opener: no group; the site rule decides when it loads.
    try await f.dispatch("browser_new_tab", ["url": .string("https://fourth.net/")])
    try await f.dispatch("browser_new_tab", ["url": .string("https://fourth.net/b"), "opener": .string("t4")])
    s = await f.snapshot()
    #expect(s.tabs.suffix(2).map(\.group) == [nil, nil] && s.tabs.last?.opener == nil)
    // An opener that has closed meanwhile is no opener.
    try await f.dispatch("browser_new_tab", ["url": .string("https://fifth.net/"), "opener": .string("t99")])
    #expect(await f.snapshot().tabs.last?.group == nil)
    // Saved with the layout.
    #expect(try #require(await f.layout.browserTabs(id: f.pane)).groups.map(\.id) == ["g1"])
}

@Test func groupCreateMakesAnOwnGroup() async throws {
    let f = try await withTabs(["https://a.test/", "https://b.test/", "https://c.test/"])
    let reply = try await f.dispatch("browser_group", ["action": .string("create"),
                                                       "tabs": .array([.string("t1"), .string("t3")]),
                                                       "name": .string("Trip")])
    #expect(fields(reply)["group"] == .string("g1") && fields(reply)["pane"] == .string(f.pane))
    #expect(replyGroups(reply).first?["kind"] == .string("own") && replyGroups(reply).first?["name"] == .string("Trip"))
    #expect(replyGroups(reply).first?["tabs"] == .array([.string("t1"), .string("t3")]))
    #expect(await f.snapshot().tabs.map(\.id) == ["t1", "t3", "t2"], "a group's tabs sit together")
    // No tabs: the active tab, named New Group.
    try await f.dispatch("browser_select_tab", ["tab": .string("t2")])
    let second = try await f.dispatch("browser_group", ["action": .string("create")])
    #expect(fields(second)["group"] == .string("g2"))
    #expect(replyGroups(second).last?["name"] == .string("New Group"))
    #expect(replyGroups(second).last?["tabs"] == .array([.string("t2")]))
    #expect(try #require(await f.layout.browserTabs(id: f.pane)).groups.map(\.id) == ["g1", "g2"])
    #expect(await refusal { try await f.dispatch("browser_group", ["action": .string("create"),
                                                                   "tabs": .array([.string("t9")])]) }
        == "browser_group: the browser pane has no tab t9")
}

@Test func groupRenameMakesItOwn() async throws {
    let f = try await groupedFixture()
    let reply = try await f.dispatch("browser_group", ["action": .string("rename"), "group": .string("g1"),
                                                       "name": .string("Shopping")])
    #expect(replyGroups(reply).first?["name"] == .string("Shopping") && replyGroups(reply).first?["kind"] == .string("own"))
    #expect(await f.snapshot().group("g1")?.named == true)
}

@Test func groupRecolourMakesItOwn() async throws {
    let f = try await groupedFixture()
    let reply = try await f.dispatch("browser_group", ["action": .string("recolour"), "group": .string("g1"),
                                                       "colour": .string("sand")])
    #expect(replyGroups(reply).first?["colour"] == .string("sand") && replyGroups(reply).first?["kind"] == .string("own"))
}

@Test func groupCollapseAndExpandLeaveItAutomatic() async throws {
    let f = try await groupedFixture()
    var reply = try await f.dispatch("browser_group", ["action": .string("collapse"), "group": .string("g1")])
    #expect(replyGroups(reply).first?["collapsed"] == .bool(true) && replyGroups(reply).first?["kind"] == .string("automatic"))
    #expect(try #require(await f.layout.browserTabs(id: f.pane)).groups.first?.collapsed == true)
    reply = try await f.dispatch("browser_group", ["action": .string("expand"), "group": .string("g1")])
    #expect(replyGroups(reply).first?["collapsed"] == .bool(false) && replyGroups(reply).first?["kind"] == .string("automatic"))
}

@Test func groupUngroupKeepsItsTabsLoose() async throws {
    let f = try await groupedFixture()
    let reply = try await f.dispatch("browser_group", ["action": .string("ungroup"), "group": .string("g1")])
    #expect(replyGroups(reply).isEmpty)
    let s = await f.snapshot()
    #expect(s.tabs.allSatisfy { $0.group == nil })
    #expect(s.tabs.filter(\.keptLoose).map(\.id).sorted() == ["t1", "t2"])
    // The site rule never pulls them back.
    await f.panes.browserPageDidReport(paneId: f.pane, tab: "t2", BrowserPageReport(
        url: "https://example.com/b", title: "", isLoading: true, progress: 0.5, canGoBack: false, canGoForward: false, failure: nil))
    await f.panes.browserPageDidReport(paneId: f.pane, tab: "t2", BrowserPageReport(
        url: "https://example.com/b", title: "", isLoading: false, progress: 1, canGoBack: false, canGoForward: false, failure: nil))
    #expect(await f.snapshot().groups.isEmpty)
}

@Test func groupCloseClosesItsTabs() async throws {
    let f = try await groupedFixture()
    let reply = try await f.dispatch("browser_group", ["action": .string("close"), "group": .string("g1")])
    #expect(replyGroups(reply).isEmpty)
    let s = await f.snapshot()
    #expect(s.tabs.map(\.id) == ["t3", "t4"] && s.active == "t3", "the tab right of the group is selected")
    #expect(s.closed.map(\.url) == ["https://example.com/a", "https://example.com/b"])
    #expect(try #require(await f.layout.browserTabs(id: f.pane)).tabs.map(\.id) == ["t3", "t4"])
}

@Test func closingAGroupClosesItsTabsAndTheLastClosesThePane() async throws {
    let f = try await withTabs(["https://a.test/", "https://b.test/"])
    try await f.dispatch("browser_group", ["action": .string("create"), "tabs": .array([.string("t1"), .string("t2")])])
    let reply = try await f.dispatch("browser_group", ["action": .string("close"), "group": .string("g1")])
    #expect(reply == .object(["pane": .string(f.pane), "closed": .bool(true)]))
    #expect(await !f.layout.snapshot().panes.contains { $0.id == f.pane })
    #expect(await !f.panes.holdsContents(paneId: f.pane))
}

/// A pull-request tab is never saved, so it is never the saved active tab: the nearest saved tab
/// before it is, else the first saved tab, else none.
@Test func aSelectedPullRequestTabIsNotSavedAsActive() async throws {
    let f = try await withTabs(["https://a.test/", "https://b.test/"])
    await f.panes.updateBrowser(paneId: f.pane) { s in
        s.tabs.append(BrowserTab(id: "t3", url: "https://github.com/initech/app/pull/4", title: "Fix · initech/app#4",
                                 group: "pr", pullRequest: "https://github.com/initech/app/pull/4"))
        s.groups = [BrowserGroup(id: "pr", name: "Pull Requests", colour: .blue, kind: .pullRequests, named: true)]
        s.nextTab = 4
        s.arrange()
    }
    try await f.dispatch("browser_select_tab", ["tab": .string("t3")])
    #expect(await f.snapshot().active == "t3")
    let saved = try #require(await f.layout.browserTabs(id: f.pane))
    #expect(saved.active == "t1", "the PR group leads, so the first saved tab stands in")
    #expect(!saved.tabs.contains { $0.id == "t3" })

    var s = BrowserSnapshot(tabs: [
        BrowserTab(id: "t1", url: "https://a.test/", title: "a"),
        BrowserTab(id: "t2", url: "https://github.com/x/y/pull/1", title: "p", pullRequest: "https://github.com/x/y/pull/1"),
        BrowserTab(id: "t3", url: "https://b.test/", title: "b"),
    ], active: "t2", find: nil, downloads: [], closed: [], nextTab: 4)
    #expect(browserSavedActive(s) == "t1", "the nearest saved tab before it")
    s.tabs.removeAll { $0.pullRequest == nil }
    #expect(browserSavedActive(s) == nil, "no saved tab: none")
    s.active = "t2"
    s.tabs[0].pullRequest = nil
    #expect(browserSavedActive(s) == "t2")
}

@Test func thePullRequestGroupRefusesRename() async throws {
    let f = try await withTabs(["https://a.test/"])
    await f.panes.updateBrowser(paneId: f.pane) { s in
        s.tabs.append(BrowserTab(id: "t2", url: "https://github.com/initech/app/pull/4", title: "Fix · initech/app#4",
                                 group: "pr", pullRequest: "https://github.com/initech/app/pull/4"))
        s.groups = [BrowserGroup(id: "pr", name: "Pull Requests", colour: .blue, collapsed: true,
                                 kind: .pullRequests, named: true)]
        s.nextTab = 3
    }
    let before = await f.snapshot()
    for (verb, word, extra) in [("rename", "renamed", ["name": JSONValue.string("X")]),
                                ("recolour", "recoloured", ["colour": .string("teal")]),
                                ("ungroup", "ungrouped", [:]), ("close", "closed", [:])] {
        var params: [String: JSONValue] = ["action": .string(verb), "group": .string("pr")]
        params.merge(extra) { a, _ in a }
        #expect(await refusal { try await f.dispatch("browser_group", params) }
            == "browser_group: the pull-request group can't be \(word)", "\(verb)")
    }
    #expect(await f.snapshot() == before)
    let reply = try await f.dispatch("browser_group", ["action": .string("expand"), "group": .string("pr")])
    #expect(replyGroups(reply).first?["collapsed"] == .bool(false) && replyGroups(reply).first?["kind"] == .string("pullRequests"))
}

@Test func anUnknownColourIsRefusedWithTheList() async throws {
    let f = try await groupedFixture()
    let before = await f.snapshot()
    #expect(await refusal { try await f.dispatch("browser_group", ["action": .string("recolour"), "group": .string("g1"),
                                                                   "colour": .string("red")]) }
        == "browser_group: colour is one of blue, steel, teal, sand, stone, smoke")
    #expect(await refusal { try await f.dispatch("browser_group", ["action": .string("collapse"), "group": .string("g7")]) }
        == "browser_group: this pane has no group g7")
    #expect(await f.snapshot() == before)
}

@Test func moveTabIntoAndOutOfAGroup() async throws {
    let f = try await groupedFixture()
    try await f.dispatch("browser_move_tab", ["tab": .string("t4"), "group": .string("g1")])
    var s = await f.snapshot()
    #expect(s.tabs.map(\.id) == ["t1", "t2", "t4", "t3"] && s.tabs[2].group == "g1")
    #expect(s.group("g1")?.kind == .own, "a tab dragged in makes it yours")
    try await f.dispatch("browser_move_tab", ["tab": .string("t1"), "group": .string("")])
    s = await f.snapshot()
    #expect(s.tabs.first { $0.id == "t1" }?.group == nil && s.tabs.first { $0.id == "t1" }?.keptLoose == true)
    #expect(s.tabs.filter { $0.group == "g1" }.map(\.id) == ["t2", "t4"], "an own group of two stays")
    #expect(try #require(await f.layout.browserTabs(id: f.pane)).tabs.first { $0.id == "t1" }?.keptLoose == true)
    // Plain reordering is still today's, then arranged: a loose tab cannot land inside a group.
    try await f.dispatch("browser_move_tab", ["tab": .string("t3"), "to": .integer(0)])
    s = await f.snapshot()
    #expect(s.tabs.map(\.id).prefix(2) == ["t2", "t4"])
    #expect(await refusal { try await f.dispatch("browser_move_tab", ["tab": .string("t3"), "group": .string("g9")]) }
        == "browser_move_tab: this pane has no group g9")
    #expect(await refusal { try await f.dispatch("browser_move_tab", ["tab": .string("t3")]) }
        == StandardActionError.missingParam(action: "browser_move_tab", param: "to").description)
}

/// Ruling 22: a reopened tab returns to its group while the pane still has it.
@Test func aReopenedTabReturnsToItsGroup() async throws {
    let f = try await groupedFixture()
    try await f.dispatch("browser_group", ["action": .string("rename"), "group": .string("g1"), "name": .string("Mine")])
    try await f.dispatch("browser_move_tab", ["tab": .string("t3"), "group": .string("g1")])
    try await f.dispatch("browser_close_tab", ["tab": .string("t2")])
    try await f.dispatch("browser_reopen_tab")
    var s = await f.snapshot()
    #expect(s.tabs.first { $0.url == "https://example.com/b" }?.group == "g1")
    // Its group gone, it comes back loose.
    try await f.dispatch("browser_close_tab", ["tab": .string("t3")])
    try await f.dispatch("browser_group", ["action": .string("ungroup"), "group": .string("g1")])
    try await f.dispatch("browser_reopen_tab")
    s = await f.snapshot()
    #expect(s.tabs.first { $0.url == "https://other.org/c" }?.group == nil)
}

/// A closed pinned tab reopened with ⌘⇧T keeps its pin, so the next full reconcile finds the pin
/// held and adds no second copy — unless the pane already holds that pin again, then it is plain.
@Test func aReopenedPinnedTabKeepsItsPin() async throws {
    let f = try await withTabs(["https://example.com/a", "https://example.com/b"])
    await f.panes.updateBrowser(paneId: f.pane) { s in
        s.tabs[1].pin = "p1234abcd"
        s.arrange()
    }
    try await f.dispatch("browser_close_tab", ["tab": .string("t2")])
    try await f.dispatch("browser_reopen_tab")
    var s = await f.snapshot()
    let back = try #require(s.tabs.first { $0.url == "https://example.com/b" })
    #expect(back.pin == "p1234abcd", "the pin comes back with it")
    #expect(s.tabs.first?.id == back.id, "into the pinned section")
    #expect(back.group == nil)

    // Closed again; meanwhile the pane holds that pin once more (a reconcile put it back).
    try await f.dispatch("browser_close_tab", ["tab": .string(back.id)])
    await f.panes.updateBrowser(paneId: f.pane) { s in
        s.tabs.append(BrowserTab(id: s.takeTabId(), url: "https://example.com/b", title: "b", pin: "p1234abcd"))
        s.arrange()
    }
    try await f.dispatch("browser_reopen_tab")
    s = await f.snapshot()
    #expect(s.tabs.filter { $0.pin == "p1234abcd" }.count == 1, "never two tabs of one pin")
    #expect(s.tabs.filter { $0.url == "https://example.com/b" }.count == 2)
}

/// Rule 6: no grouping rule or action changes the selection; a tab moved into a group stays selected.
@Test func groupingNeverChangesTheActiveTab() async throws {
    let f = try await groupedFixture()
    try await f.dispatch("browser_select_tab", ["tab": .string("t3")])
    let steps: [[String: JSONValue]] = [
        ["action": .string("rename"), "group": .string("g1"), "name": .string("A")],
        ["action": .string("recolour"), "group": .string("g1"), "colour": .string("teal")],
        ["action": .string("collapse"), "group": .string("g1")],
        ["action": .string("expand"), "group": .string("g1")],
        ["action": .string("create"), "tabs": .array([.string("t4")])],
    ]
    for p in steps {
        try await f.dispatch("browser_group", p)
        #expect(await f.snapshot().active == "t3", "\(p)")
    }
    try await f.dispatch("browser_move_tab", ["tab": .string("t3"), "group": .string("g1")])
    #expect(await f.snapshot().active == "t3", "moved into a group, still selected")
    try await f.dispatch("browser_move_tab", ["tab": .string("t3"), "group": .string("")])
    #expect(await f.snapshot().active == "t3")
    try await f.dispatch("browser_group", ["action": .string("ungroup"), "group": .string("g2")])
    #expect(await f.snapshot().active == "t3")
    try await f.dispatch("browser_new_tab", ["url": .string("https://x.org/"), "opener": .string("t1")])
    try await f.dispatch("browser_select_tab", ["tab": .string("t3")])
    await f.panes.browserPageDidReport(paneId: f.pane, tab: "t4", BrowserPageReport(
        url: "https://example.com/z", title: "", isLoading: true, progress: 0.5, canGoBack: false, canGoForward: false, failure: nil))
    await f.panes.browserPageDidReport(paneId: f.pane, tab: "t4", BrowserPageReport(
        url: "https://example.com/z", title: "", isLoading: false, progress: 1, canGoBack: false, canGoForward: false, failure: nil))
    try await f.dispatch("browser_group", ["action": .string("close"), "group": .string("g1")])
    #expect(await f.snapshot().active == "t3", "closing a group the selection is not in")
}

// MARK: - Pins per project (3d-i Task 8)

/// Two browser panes on project `web`'s canvas, each with one loaded tab: `f.pane` on example.com/a,
/// `other` on example.org/b.
private func pinFixture() async throws -> (f: BrowserFixture, other: String, files: BrowserOrgFiles) {
    let files = try BrowserOrgFiles(home: testScratchRoot.appendingPathComponent(UUID().uuidString), org: "initech")
    var f = try await browserFixture(open: false, orgFiles: files)
    let scope = LayoutScope(organization: "initech", project: "web", environment: "e")
    await f.layout.switchScope(to: scope)
    await f.panes.switchScope(to: scope)
    f.pane = await f.layout.open(kind: "browser", title: "Browser").id
    let other = await f.layout.open(kind: "browser", title: "Browser").id
    try await f.dispatch("browser_new_tab", ["url": .string("https://example.com/a")])
    try await f.dispatch("browser_new_tab", ["url": .string("https://example.org/b"), "pane": .string(other)])
    for p in [f.pane, other] {
        await f.panes.updateBrowser(paneId: p) { s in for i in s.tabs.indices { s.tabs[i].loaded = true } }
    }
    return (f, other, files)
}

@Test func anUnreadablePinsFileIsNeverWrittenOver() async throws {
    let (f, _, files) = try await pinFixture()
    let url = files.pinsURL(project: "web")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let bytes = Data("{\"items\": [oops".utf8)
    try bytes.write(to: url)
    let why = await refusal { try await f.dispatch("browser_pin") }
    #expect(why?.hasPrefix("browser_pin: pins/web.json can't be read (") == true)
    #expect(why?.hasSuffix(") — fix or move it; Wakil won't write over it.") == true)
    _ = await refusal { try await f.dispatch("browser_unpin") }
    #expect(try Data(contentsOf: url) == bytes)
    #expect(await f.snapshot().tabs.allSatisfy { $0.pin == nil })
}

@Test func anUnreadablePinsFileRefusesAnUnpinOfAPinnedTab() async throws {
    let (f, other, files) = try await pinFixture()
    try await f.dispatch("browser_pin")
    let url = files.pinsURL(project: "web")
    let bytes = Data("{\"items\": [oops".utf8)
    try bytes.write(to: url)
    let why = await refusal { try await f.dispatch("browser_unpin") }
    #expect(why?.hasPrefix("browser_unpin: pins/web.json can't be read (") == true)
    #expect(try Data(contentsOf: url) == bytes)
    #expect(await f.snapshot().tabs.first?.pin != nil)
    #expect(await f.panes.browserSnapshot(paneId: other).tabs.first?.pin != nil)
}

@Test func aRestoreThatLeavesAPaneWithNoTabClosesIt() async throws {
    let (f, _, files) = try await pinFixture()
    try await f.dispatch("browser_pin")
    #expect(await f.snapshot().tabs.count == 1)
    try files.setPins([], project: "web")
    let reply = try await f.dispatch("browser_restore", ["pane": .string(f.pane)], named: false)
    #expect(reply == .object(["pane": .string(f.pane), "closed": .bool(true)]))
    #expect(await !f.layout.snapshot().panes.contains { $0.id == f.pane })
}

@Test func pinningRefusesWithNoProject() async throws {
    let files = try BrowserOrgFiles(home: testScratchRoot.appendingPathComponent(UUID().uuidString), org: "initech")
    let f = try await browserFixture(orgFiles: files)
    try await f.dispatch("browser_new_tab", ["url": .string("https://example.com/a")])
    #expect(await refusal { try await f.dispatch("browser_pin") } == "browser_pin: no project is active")
}

@Test func pinningATabShowsItInTheOtherBrowserPaneUnloaded() async throws {
    let (f, other, files) = try await pinFixture()
    try await f.dispatch("browser_pin")
    let pins = try files.pins(project: "web")
    #expect(pins.count == 1)
    let pin = try #require(pins.first)
    #expect(pin.kind == .tab)
    #expect(pin.url == "https://example.com/a")
    #expect(pin.id.count == 9 && pin.id.hasPrefix("p"))
    #expect(await f.snapshot().tabs.first?.pin == pin.id)

    let o = await f.panes.browserSnapshot(paneId: other)
    #expect(o.tabs.map(\.url) == ["https://example.com/a", "https://example.org/b"])
    let copy = try #require(o.tabs.first)
    #expect(copy.pin == pin.id)
    #expect(copy.loaded == false)
    #expect(o.active != copy.id)
    // Saved in the other pane's layout too.
    #expect(await f.layout.browserTabs(id: other)?.tabs.first?.pin == pin.id)
}

@Test func pinningAGroupWritesItsTabs() async throws {
    let (f, other, files) = try await pinFixture()
    try await f.dispatch("browser_new_tab", ["url": .string("https://example.net/c")])
    let ids = await f.snapshot().tabs.map(\.id)
    guard case .object(let made) = try await f.dispatch(
        "browser_group", ["action": .string("create"), "name": .string("Work"), "colour": .string("stone"),
                          "tabs": .array(ids.map { .string($0) })]),
        case .string(let group)? = made["group"] else { Issue.record("no group"); return }
    try await f.dispatch("browser_pin", ["group": .string(group)])
    let pin = try #require(try files.pins(project: "web").first)
    #expect(pin.kind == .group)
    #expect(pin.name == "Work")
    #expect(pin.colour == .stone)
    #expect(pin.tabs == [BrowserPinTab(url: "https://example.com/a", title: ""),
                         BrowserPinTab(url: "https://example.net/c", title: "")])
    #expect(await f.snapshot().group(group)?.pin == pin.id)

    let o = await f.panes.browserSnapshot(paneId: other)
    let copy = try #require(o.groups.first { $0.pin == pin.id })
    #expect(copy.name == "Work")
    #expect(o.tabs.filter { $0.group == copy.id }.map(\.url) == ["https://example.com/a", "https://example.net/c"])
    #expect(o.tabs.last?.url == "https://example.org/b")
}

@Test func pinMakesAnAutomaticGroupOwn() async throws {
    let (f, _, files) = try await pinFixture()
    try await f.dispatch("browser_new_tab", ["url": .string("https://example.com/b")])
    let group = await f.panes.updateBrowser(paneId: f.pane) { s -> String in
        s.newGroup(tabs: s.tabs.map(\.id), name: "Example", kind: .automatic, siteKey: "example.com")
    }
    #expect(await f.snapshot().group(group)?.kind == .automatic)
    try await f.dispatch("browser_pin", ["group": .string(group)])
    #expect(await f.snapshot().group(group)?.kind == .own)
    #expect(try files.pins(project: "web").first?.name == "Example")
}

@Test func unpinKeepsItHereAndRemovesItFromTheOtherPane() async throws {
    let (f, other, files) = try await pinFixture()
    try await f.dispatch("browser_pin")
    let tab = try #require(await f.snapshot().tabs.first)
    #expect(await f.panes.browserSnapshot(paneId: other).tabs.count == 2)
    try await f.dispatch("browser_unpin", ["tab": .string(tab.id)])
    #expect(try files.pins(project: "web") == [])
    let here = await f.snapshot()
    #expect(here.tabs.map(\.id) == [tab.id])
    #expect(here.tabs.first?.pin == nil)
    #expect(await f.panes.browserSnapshot(paneId: other).tabs.map(\.url) == ["https://example.org/b"])
}

@Test func aTabPinnedByADropLandsWhereItWasDropped() async throws {
    let (f, other, files) = try await pinFixture()
    try await f.dispatch("browser_pin")
    try await f.dispatch("browser_new_tab", ["url": .string("https://example.net/c")])
    let ids = await f.snapshot().tabs.map(\.id)
    // Dropped before the pinned tab: pinned, and first.
    try await f.dispatch("browser_pin", ["tab": .string(ids[1]), "to": .integer(0)])
    let here = await f.snapshot()
    #expect(here.tabs.map(\.id) == [ids[1], ids[0]])
    #expect(here.tabs.allSatisfy { $0.pin != nil })
    #expect(try files.pins(project: "web").count == 2)
    // The other pane gains it, unloaded, after its own pinned tabs.
    #expect(await f.panes.browserSnapshot(paneId: other).tabs.map(\.url)
            == ["https://example.com/a", "https://example.net/c", "https://example.org/b"])
}

@Test func aPinnedTabDroppedBelowTheLineIsUnpinnedWhereItLands() async throws {
    let (f, other, files) = try await pinFixture()
    try await f.dispatch("browser_new_tab", ["url": .string("https://example.net/c")])
    try await f.dispatch("browser_new_tab", ["url": .string("https://example.edu/d")])
    let ids = await f.snapshot().tabs.map(\.id)
    guard case .object(let made) = try await f.dispatch(
        "browser_group", ["action": .string("create"), "name": .string("Net"),
                          "tabs": .array([.string(ids[1]), .string(ids[2])])]),
        case .string(let group)? = made["group"] else { Issue.record("no group"); return }
    try await f.dispatch("browser_pin", ["tab": .string(ids[0])])
    // Between the group's two tabs: `to` 1 counted without it, into the group.
    try await f.dispatch("browser_unpin", ["tab": .string(ids[0]), "to": .integer(1), "into": .string(group)])
    let here = await f.snapshot()
    #expect(here.tabs.map(\.id) == [ids[1], ids[0], ids[2]])
    #expect(here.tabs[1].group == group)
    #expect(here.tabs[1].pin == nil)
    #expect(try files.pins(project: "web") == [])
    #expect(await f.panes.browserSnapshot(paneId: other).tabs.map(\.url) == ["https://example.org/b"])
    // A group that isn't there is refused before anything is unpinned.
    try await f.dispatch("browser_pin", ["tab": .string(ids[2])])
    let why = await refusal {
        try await f.dispatch("browser_unpin", ["tab": .string(ids[2]), "to": .integer(0), "into": .string("g99")])
    }
    #expect(why?.contains("g99") == true)
    #expect(try files.pins(project: "web").count == 1)
}

@Test func pinCurrentPageRewritesTheEntryOnly() async throws {
    let (f, other, files) = try await pinFixture()
    try await f.dispatch("browser_pin")
    try await f.dispatch("browser_navigate", ["input": .string("https://example.com/moved")])
    try await f.dispatch("browser_pin", ["update": .bool(true)])
    let pins = try files.pins(project: "web")
    #expect(pins.count == 1)
    #expect(pins.first?.url == "https://example.com/moved")
    // The other pane's live tab keeps its page.
    #expect(await f.panes.browserSnapshot(paneId: other).tabs.first?.url == "https://example.com/a")
}

@Test func aNewBrowserPaneOpensWithTheProjectsPins() async throws {
    let files = try BrowserOrgFiles(home: testScratchRoot.appendingPathComponent(UUID().uuidString), org: "initech")
    try files.setPins([BrowserPin(id: "p0000000a", kind: .tab, url: "https://example.com/pinned", title: "Pinned")],
                      project: "web")
    let f = try await browserFixture(open: false, orgFiles: files)
    let scope = LayoutScope(organization: "initech", project: "web", environment: "e")
    await f.layout.switchScope(to: scope)
    await f.panes.switchScope(to: scope)
    guard case .object(let o) = try await f.dispatch("browser_open", ["url": .string("https://example.org/")], named: false),
          case .string(let pane)? = o["pane"] else { Issue.record("no pane"); return }
    let s = await f.panes.browserSnapshot(paneId: pane)
    #expect(s.tabs.map(\.url) == ["https://example.com/pinned", "https://example.org/"])
    #expect(s.tabs.first?.loaded == false)
    #expect(s.activeTab?.url == "https://example.org/")

    // A restored pane is reconciled too: a pin the file no longer holds goes.
    try files.setPins([], project: "web")
    try await f.dispatch("browser_restore", ["pane": .string(pane)], named: false)
    #expect(await f.panes.browserSnapshot(paneId: pane).tabs.map(\.url) == ["https://example.org/"])
}

// MARK: - The pull-request group (3d-i Task 11)

/// What `ctx_github_pull_requests` answers in a test: a list, an absent reason, or a failure; counts
/// the reads, and holds each until released when gated.
final class PullRequestsReader: @unchecked Sendable {
    private let lock = NSLock()
    private var reply: Result<JSONValue, Error>
    private var gated: Bool
    private var count = 0
    init(_ items: [BrowserPullRequest] = [], gated: Bool = false) {
        reply = .success(Self.reply(items))
        self.gated = gated
    }
    static func reply(_ items: [BrowserPullRequest], absent: String? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["pullRequests": .array(items.map { pr in .object([
            "number": .integer(Int64(pr.number)), "title": .string(pr.title), "url": .string(pr.url),
            "repository": .string(pr.repository), "reason": .string(pr.reason),
        ]) })]
        if let absent { o["absent"] = .string(absent) }
        return .object(["structuredContent": .object(o)])
    }
    func answer(_ items: [BrowserPullRequest]) { lock.withLock { reply = .success(Self.reply(items)) } }
    func answer(absent: String) { lock.withLock { reply = .success(Self.reply([], absent: absent)) } }
    func fail(_ error: Error) { lock.withLock { reply = .failure(error) } }
    func release() { lock.withLock { gated = false } }
    func hold() { lock.withLock { gated = true } }
    var reads: Int { lock.withLock { count } }
    var read: BrowserPullRequestsRead {
        { [self] in
            lock.withLock { count += 1 }
            for _ in 0..<5_000 where lock.withLock({ gated }) { try await Task.sleep(nanoseconds: 1_000_000) }
            return try lock.withLock { try reply.get() }
        }
    }
}

func pr(_ n: Int, _ title: String = "Fix", repo: String = "initech/app") -> BrowserPullRequest {
    BrowserPullRequest(number: n, title: "\(title) \(n)", url: "https://github.com/\(repo)/pull/\(n)",
                       repository: repo, reason: "author")
}

/// A browser pane on organisation `initech`'s canvas with one loaded loose tab, its pull requests
/// read by `reader`.
private func prFixture(_ reader: PullRequestsReader) async throws -> BrowserFixture {
    var f = try await browserFixture(open: false, pullRequests: reader.read)
    let scope = LayoutScope(organization: "initech", project: "web", environment: "e")
    await f.layout.switchScope(to: scope)
    await f.panes.switchScope(to: scope)
    f.pane = await f.layout.open(kind: "browser", title: "Browser").id
    try await f.dispatch("browser_new_tab", ["url": .string("https://example.com/a")])
    await f.panes.updateBrowser(paneId: f.pane) { s in for i in s.tabs.indices { s.tabs[i].loaded = true } }
    return f
}

private func prTabs(_ s: BrowserSnapshot) -> [BrowserTab] { s.tabs.filter { $0.group == "pr" } }

@Test func pullRequestsFillAGroupCollapsedOfUnloadedTabs() async throws {
    let reader = PullRequestsReader([pr(4), pr(9, repo: "initech/api")])
    let f = try await prFixture(reader)
    let reply = try await f.dispatch("browser_pull_requests_refresh", [:], named: false)
    #expect(reply == .object(["org": .string("initech"), "count": .integer(2), "absent": .null, "error": .null,
                              "refreshing": .bool(false)]))
    let s = await f.snapshot()
    let group = try #require(s.group("pr"))
    #expect(group.kind == .pullRequests && group.name == "Pull Requests" && group.collapsed)
    let tabs = prTabs(s)
    #expect(tabs.map(\.title) == ["Fix 4 · initech/app#4", "Fix 9 · initech/api#9"])
    #expect(tabs.map(\.pullRequest) == [pr(4).url, pr(9, repo: "initech/api").url])
    #expect(tabs.allSatisfy { !$0.loaded && $0.command == nil })
    #expect(s.activeTab?.url == "https://example.com/a", "a new pull-request tab never becomes the selected one")
    // Not saved as tabs; the group is, collapsed.
    let saved = try #require(await f.layout.browserTabs(id: f.pane))
    #expect(saved.tabs.map(\.url) == ["https://example.com/a"])
    #expect(saved.groups.first { $0.id == "pr" }?.collapsed == true)
    // read_pane carries the group's error and refreshing.
    let group2 = replyGroups(try await f.dispatch("browser_find_close")).first { $0["id"] == .string("pr") }
    #expect(group2?["error"] == .null && group2?["refreshing"] == .bool(false))
}

@Test func aRefreshKeepsListedTabsAddsNewDropsGone() async throws {
    let reader = PullRequestsReader([pr(1), pr(2)])
    let f = try await prFixture(reader)
    try await f.dispatch("browser_pull_requests_refresh", [:], named: false)
    let first = prTabs(await f.snapshot())
    // Tab of #1 has loaded its page.
    await f.panes.updateBrowser(paneId: f.pane) { s in
        if let i = s.tabs.firstIndex(where: { $0.pullRequest == pr(1).url }) {
            s.tabs[i].loaded = true
            s.tabs[i].title = "Fix 1 by someone · Pull Request #1 · initech/app"
        }
    }
    reader.answer([pr(3), pr(1, "Renamed")])
    try await f.dispatch("browser_pull_requests_refresh", [:], named: false)
    let after = prTabs(await f.snapshot())
    #expect(after.map(\.pullRequest) == [pr(3).url, pr(1).url], "the list's order")
    #expect(after[1].id == first[0].id, "a listed tab stays")
    #expect(after[1].title == "Fix 1 by someone · Pull Request #1 · initech/app", "with its page")
    #expect(!after.contains { $0.id == first[1].id }, "a gone one goes")
    #expect(after[0].loaded == false && after[0].title == "Fix 3 · initech/app#3")
}

/// A pane whose only content was the pull-request group (restored with `pr` alone) closes when a
/// refresh says `absent` — by the rule restore and reconcile use — rather than staying empty.
@Test func aPaneLeftEmptyByARefreshCloses() async throws {
    let reader = PullRequestsReader([pr(1), pr(2)])
    let f = try await prFixture(reader)
    try await f.dispatch("browser_pull_requests_refresh", [:], named: false)
    await f.panes.updateBrowser(paneId: f.pane) { s in
        s.tabs.removeAll { $0.pullRequest == nil }
        s.active = nil
    }
    reader.answer(absent: "No pull-request group: initech has no GitHub account.")
    try await f.dispatch("browser_pull_requests_refresh", [:], named: false)
    #expect(await !f.layout.snapshot().panes.contains { $0.id == f.pane }, "the empty pane closes")
    #expect(await !f.panes.holdsContents(paneId: f.pane))
}

@Test func theActivePullRequestTabStaysAsALooseTab() async throws {
    let reader = PullRequestsReader([pr(1), pr(2)])
    let f = try await prFixture(reader)
    try await f.dispatch("browser_pull_requests_refresh", [:], named: false)
    let tab = try #require(prTabs(await f.snapshot()).last)
    try await f.dispatch("browser_select_tab", ["tab": .string(tab.id)])
    reader.answer([pr(1)])
    try await f.dispatch("browser_pull_requests_refresh", [:], named: false)
    let s = await f.snapshot()
    let kept = try #require(s.tabs.first { $0.id == tab.id })
    #expect(s.active == tab.id, "Rule 6: the operator stays where they were")
    #expect(kept.group == nil && kept.pullRequest == nil, "a plain loose tab now")
    #expect(prTabs(s).map(\.pullRequest) == [pr(1).url])
    #expect(try #require(await f.layout.browserTabs(id: f.pane)).tabs.contains { $0.id == tab.id }, "and saved as one")
}

@Test func aFailedRefreshKeepsTheListAndShowsTheErrorWhole() async throws {
    let reader = PullRequestsReader([pr(1)])
    let f = try await prFixture(reader)
    try await f.dispatch("browser_pull_requests_refresh", [:], named: false)
    let why = "github.com refused the pull-request search (HTTP 401): Bad credentials"
    reader.fail(StandardActionError.serverError(action: "ctx_github_pull_requests", message: why))
    let reply = try await f.dispatch("browser_pull_requests_refresh", [:], named: false)
    guard case .object(let o) = reply else { Issue.record("no reply"); return }
    #expect(o["error"] == .string(why) && o["count"] == .integer(1))
    #expect(prTabs(await f.snapshot()).map(\.pullRequest) == [pr(1).url], "the last list is kept")
    let group = try #require(replyGroups(try await f.dispatch("browser_find_close")).first { $0["id"] == .string("pr") })
    #expect(group["error"] == .string(why) && group["refreshing"] == .bool(false))
    // The next good read clears it.
    reader.answer([pr(1)])
    try await f.dispatch("browser_pull_requests_refresh", [:], named: false)
    #expect(await f.panes.browserPullRequests(org: "initech")?.error == nil)
}

@Test func aRefreshWhileOneRunsFetchesOnce() async throws {
    let reader = PullRequestsReader([pr(1)], gated: true)
    let f = try await prFixture(reader)
    let first = Task { try await f.dispatch("browser_pull_requests_refresh", [:], named: false) }
    for _ in 0..<5_000 where reader.reads == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
    let second = try await f.dispatch("browser_pull_requests_refresh", [:], named: false)
    guard case .object(let o) = second else { Issue.record("no reply"); return }
    #expect(o["refreshing"] == .bool(true), "returned at once")
    let group = replyGroups(try await f.dispatch("browser_find_close")).first { $0["id"] == .string("pr") }
    #expect(group == nil, "no list yet, so no group")
    let other = await f.layout.open(kind: "browser", title: "Browser").id
    try await f.dispatch("browser_new_tab", ["url": .string("https://example.org/"), "pane": .string(other)])
    #expect(await f.panes.browserSnapshot(paneId: other).group("pr") == nil, "a pane opened meanwhile neither")
    reader.release()
    _ = try await first.value
    #expect(reader.reads == 1)
    #expect(prTabs(await f.snapshot()).count == 1)
    #expect(prTabs(await f.panes.browserSnapshot(paneId: other)).count == 1, "the answer fills both")
}

@Test func absentMeansNoGroupAndNoError() async throws {
    let reader = PullRequestsReader([pr(1)])
    let f = try await prFixture(reader)
    try await f.dispatch("browser_pull_requests_refresh", [:], named: false)
    #expect(await f.snapshot().group("pr") != nil)
    let why = "No pull-request group: initech has no GitHub account."
    reader.answer(absent: why)
    let reply = try await f.dispatch("browser_pull_requests_refresh", [:], named: false)
    #expect(reply == .object(["org": .string("initech"), "count": .integer(0), "absent": .string(why), "error": .null,
                              "refreshing": .bool(false)]))
    let s = await f.snapshot()
    #expect(s.group("pr") == nil && prTabs(s).isEmpty)
    #expect(s.tabs.map(\.url) == ["https://example.com/a"])
}

@Test func aNewPaneGetsTheCachedList() async throws {
    let reader = PullRequestsReader([pr(1), pr(2)])
    let f = try await prFixture(reader)
    try await f.dispatch("browser_pull_requests_refresh", [:], named: false)
    let other = await f.layout.open(kind: "browser", title: "Browser").id
    try await f.dispatch("browser_new_tab", ["url": .string("https://example.org/"), "pane": .string(other)])
    let o = await f.panes.browserSnapshot(paneId: other)
    #expect(prTabs(o).map(\.pullRequest) == [pr(1).url, pr(2).url])
    #expect(o.group("pr")?.collapsed == true)
    #expect(o.activeTab?.url == "https://example.org/")
    #expect(reader.reads == 1, "from the list kept, not a read")
}

@Test func pullRequestTabsAreNeverGrouped() async throws {
    let reader = PullRequestsReader([pr(1), pr(2)])
    let f = try await prFixture(reader)
    try await f.dispatch("browser_pull_requests_refresh", [:], named: false)
    // Both pages finish loading on github.com: the site rule leaves them in the pull-request group.
    for tab in prTabs(await f.snapshot()) {
        for loading in [true, false] {
            await f.panes.browserPageDidReport(paneId: f.pane, tab: tab.id, BrowserPageReport(
                url: tab.url, title: "PR", isLoading: loading, progress: loading ? 0.5 : 1, canGoBack: false,
                canGoForward: false, failure: nil))
        }
    }
    let s = await f.snapshot()
    #expect(prTabs(s).count == 2 && s.groups.map(\.id) == ["pr"])
    // A tab opened from one waits for the site rule rather than joining the pull-request group.
    let opener = try #require(prTabs(s).first?.id)
    try await f.dispatch("browser_new_tab", ["url": .string("https://github.com/initech/app/pull/1/files"),
                                             "opener": .string(opener)])
    let after = await f.snapshot()
    #expect(prTabs(after).count == 2)
}

@Test func aPaneWhoseOnlyTabsWerePullRequestsIsRestoredWithItsGroup() async throws {
    let reader = PullRequestsReader([pr(1)])
    let f = try await prFixture(reader)
    try await f.dispatch("browser_pull_requests_refresh", [:], named: false)
    try await f.dispatch("browser_group", ["action": .string("expand"), "group": .string("pr")])
    try await f.dispatch("browser_tab_column", ["hidden": .bool(true)])
    let loose = try #require(await f.snapshot().tabs.first { $0.group == nil }?.id)
    try await f.dispatch("browser_close_tab", ["tab": .string(loose)])
    let saved = try #require(await f.layout.browserTabs(id: f.pane))
    #expect(saved.tabs.isEmpty && saved.groups.map(\.id) == ["pr"])
    // A relaunch: nothing in the store, no list read yet.
    await f.panes.drop(paneId: f.pane)
    await f.panes.browserSetPullRequests(org: "initech", BrowserPullRequests())
    let pane = try #require(await f.layout.snapshot().panes.first { $0.id == f.pane })
    #expect(BrowserPaneKind.restoreStep(for: pane) != nil)
    try await f.dispatch("browser_restore", ["pane": .string(f.pane)], named: false)
    let s = await f.snapshot()
    #expect(s.group("pr")?.collapsed == false && s.tabColumnHidden, "its group and column came back")
    #expect(await f.layout.snapshot().panes.contains { $0.id == f.pane }, "an empty pr group keeps the pane")
}

@Test func aListReadAcrossAnOrganisationSwitchIsDropped() async throws {
    let reader = PullRequestsReader([pr(1)])
    let f = try await prFixture(reader)
    try await f.dispatch("browser_pull_requests_refresh", [:], named: false)
    reader.hold()
    reader.answer([pr(7)])
    let registry = f.registry
    let running = Task {
        try await registry.dispatch(name: "browser_pull_requests_refresh", params: .object([:]), origin: .agent,
                                    caller: .test("staging"), confirmation: nil)
    }
    for _ in 0..<5_000 where reader.reads < 2 { try await Task.sleep(nanoseconds: 1_000_000) }
    let globex = LayoutScope(organization: "globex", project: "web", environment: "e")
    await f.layout.switchScope(to: globex)
    await f.panes.switchScope(to: globex)
    reader.release()
    _ = try await running.value
    #expect(await f.panes.browserPullRequests(org: "globex") == nil, "the answer is filed under no organisation")
    let acme = try #require(await f.panes.browserPullRequests(org: "initech"))
    #expect(acme.items.map(\.number) == [1] && !acme.refreshing)
    #expect(await !f.panes.holdsContents(paneId: f.pane), "globex's canvas is untouched")
    let initech = LayoutScope(organization: "initech", project: "web", environment: "e")
    await f.layout.switchScope(to: initech)
    await f.panes.switchScope(to: initech)
    #expect(prTabs(await f.snapshot()).map(\.pullRequest) == [pr(1).url], "nor initech's panes")
}

// MARK: 3d-i walk: browser_copy_url

@Test func copyURLWritesTheActiveTabsAddressAndAnswersIt() async throws {
    let copies = BrowserCopies()
    let f = try await browserFixture(copyText: { copies.add($0) })
    try await f.dispatch("browser_new_tab", ["url": .string("https://a.test/one?x=1")])
    try await f.dispatch("browser_new_tab", ["url": .string("https://b.test/two")])
    let before = await f.snapshot()

    let reply = try await f.dispatch("browser_copy_url")
    guard case .object(let o) = reply else { Issue.record("no object: \(reply)"); return }
    #expect(o["url"] == .string("https://b.test/two"), "the active tab's address")
    #expect(o["copied"] == .bool(true))
    #expect(copies.all == ["https://b.test/two"])
    #expect(await f.snapshot() == before, "nothing in the pane changed: the page and the tabs stay")

    try await f.dispatch("browser_copy_url", ["tab": .string("t1")])
    #expect(copies.all.last == "https://a.test/one?x=1", "a named tab")
    #expect(await f.snapshot().active == before.active, "and it does not select it")
}

@Test func copyURLRefusesATabWithNoAddressAndAMissingTab() async throws {
    let copies = BrowserCopies()
    let f = try await browserFixture(copyText: { copies.add($0) })
    try await f.dispatch("browser_new_tab")
    #expect(await refusal { try await f.dispatch("browser_copy_url") } == "browser_copy_url: tab t1 has no address yet")
    #expect(await refusal { try await f.dispatch("browser_copy_url", ["tab": .string("t9")]) }
            == "browser_copy_url: the browser pane has no tab t9")
    #expect(copies.all.isEmpty, "nothing was written")
}

@Test func copyURLWithNoPasteboardSaysSo() async throws {
    let f = try await withTabs(["https://a.test/"])
    let reply = try await f.dispatch("browser_copy_url")
    guard case .object(let o) = reply else { Issue.record("no object"); return }
    #expect(o["url"] == .string("https://a.test/"))
    #expect(o["copied"] == .bool(false), "a headless dispatch writes nothing and says so")
}

@Test func copyURLIsAnAgentReachableControl() async throws {
    let f = try await withTabs(["https://a.test/"])
    let action = try #require(await f.registry.all().first { $0.name == "browser_copy_url" })
    #expect(action.kind == .control)
    #expect(action.audience == .agentReachable)
}

@Test func theCopyTipAndTheAddressRule() {
    #expect(BrowserCopyURL.tip == "Copied")
    #expect(BrowserCopyURL.tipDuration == 1.5)
    #expect(BrowserCopyURL.copyable("  https://a.test/ ") == "https://a.test/")
    #expect(BrowserCopyURL.copyable("   ") == nil)
}
