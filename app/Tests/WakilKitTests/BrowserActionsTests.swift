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
                    removeData: BrowserDataRemover? = nil) async throws -> BrowserFixture {
    let dir = testScratchRoot.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let registry = ActionRegistry(journalDirectory: dir, sessionId: "t")
    let layout = LayoutStore()
    let pane = open ? await layout.open(kind: "browser", title: "Browser").id : ""
    let panes = PaneStore(kinds: PaneKinds.standard)
    let settings = BrowserSettingsBox(SettingsBrowser(searchEngine: "google", startPage: startPage))
    await registerBrowserActions(into: registry, panes: panes, layout: layout, settings: { settings.current },
                                 orgFiles: { orgFiles }, removeData: removeData)
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
