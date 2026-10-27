import Foundation
import Testing
@testable import WakilKit

/// A window over the layout, editor and browser actions (`editorWindowFull`'s shape, plus the
/// browser's), its start page blank. `journal` is its registry's journal file.
@MainActor
private func browserWindow(
    orgFiles: BrowserOrgFiles? = nil, removeData: BrowserDataRemover? = nil
) async -> (WindowModel, FakeFiles, LayoutStore, journal: URL, panes: PaneStore) {
    let journalDir = testScratchRoot.appendingPathComponent("browser-window-\(UUID().uuidString)")
    let registry = ActionRegistry(journalDirectory: journalDir, sessionId: "browser-window")
    let panes = PaneStore()
    let layout = LayoutStore()
    let files = FakeFiles()
    let fileLists = EditorFileLists(files: files)
    await registerLayoutActions(
        into: registry, layout: layout, panes: panes, unsavedEditorTabs: unsavedEditorTabsProbe(panes: panes))
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, persistence: nil,
        context: ContextStore(client: GitRootsContext(roots: ["/p/api"])),
        harnessFactory: { _, _, _ in nil }, resumes: ResumeBroker(),
        rootPath: "/tmp", providerId: "",
        lookupFactory: { _ in EditorWindowLookup() },
        rootWatcher: nil, editorRootWatcher: RecordingRootWatcher(), fileLists: fileLists, gitStatus: nil,
        paletteClients: PaletteClients(files: fileLists), placeClients: nil,
        agentSocketFactory: { _, _ in NoAgentSocket() }, quickModelFactory: nil)
    await registerEditorActions(
        into: registry, panes: panes, layout: layout, files: fileLists, fileLists: fileLists,
        gitStatus: nil, roots: { [weak model] in await model?.gitRootPaths ?? [] })
    await registerBrowserActions(into: registry, panes: panes, layout: layout, settings: { .defaults },
                                 orgFiles: { orgFiles }, removeData: removeData)
    return (model, files, layout, journalDir.appendingPathComponent("browser-window.jsonl"), panes)
}

@Suite @MainActor struct WindowModelBrowserTests {
    /// A focused browser pane holding one tab on `https://a.test/`.
    private func focusedBrowser() async throws -> (WindowModel, String, LayoutStore, URL) {
        let (model, pane, layout, journal, _) = try await focusedBrowserAndPanes()
        return (model, pane, layout, journal)
    }

    /// `focusedBrowser`, with the window's pane store, for a test that moves its screen.
    private func focusedBrowserAndPanes() async throws -> (WindowModel, String, LayoutStore, URL, PaneStore) {
        let (model, _, layout, journal, panes) = await browserWindow()
        await model.refreshContext()
        await model.dispatchFromSurface("browser_open", .object(["url": .string("https://a.test/")]))
        await model.refreshLayout()
        let pane = try #require(model.layoutSnapshot.panes.first { $0.kind == "browser" }?.id)
        await model.focusPane(id: pane)
        return (model, pane, layout, journal, panes)
    }

    // MARK: 3c-iii Task 5: visits recorded, suggestions answered

    /// A report for the active tab of `pane`.
    private func report(_ model: WindowModel, _ pane: String, url: String = "https://example.com/",
                        title: String = "", loading: Bool, failure: String? = nil) async throws {
        let scope = try #require(model.browserScope)
        let tab = try #require(model.browser(pane)?.active)
        await model.browserPageDidReport(scope: scope, pane: pane, tab: tab, BrowserPageReport(
            url: url, title: title, isLoading: loading, progress: loading ? 0.5 : 1, canGoBack: false,
            canGoForward: false, failure: failure))
    }

    /// A browser window with a temp home and an active organisation.
    private func homedBrowser() async throws -> (WindowModel, String, URL, PaneStore) {
        let (model, pane, _, _, panes) = try await focusedBrowserAndPanes()
        let home = testScratchRoot.appendingPathComponent(UUID().uuidString)
        model.browserHome = home
        return (model, pane, home, panes)
    }

    private func visits(_ model: WindowModel) async throws -> [BrowserHistoryEntry] {
        await model.settleBrowserHistory()
        let scope = try #require(model.browserScope)
        let files = try #require(model.browserOrgFiles(for: scope))
        return try files.history.matching(["example"], limit: 50)
    }

    @Test func aFinishedLoadIsRecordedOnce() async throws {
        let (model, pane, _, _) = try await homedBrowser()
        try await report(model, pane, loading: true)
        try await report(model, pane, title: "Example", loading: false)
        try await report(model, pane, title: "Example Domain", loading: false)
        let rows = try await visits(model)
        #expect(rows.count == 1 && rows[0].count == 1 && rows[0].title == "Example Domain")
        #expect(rows[0].url == "https://example.com/")
    }

    @Test func aFailedLoadIsNotRecorded() async throws {
        let (model, pane, _, _) = try await homedBrowser()
        try await report(model, pane, loading: true)
        try await report(model, pane, loading: false, failure: "The server can't be found")
        #expect(try await visits(model).isEmpty)
    }

    @Test func historyIsNotRecordedForAPlaceNoLongerOnScreen() async throws {
        let (model, pane, _, _) = try await homedBrowser()
        let scope = try #require(model.browserScope)
        let tab = try #require(model.browser(pane)?.active)
        let elsewhere = LayoutScope(organization: "globex", project: scope.project, environment: scope.environment,
                                    lineageRoot: scope.lineageRoot)
        for loading in [true, false] {
            await model.browserPageDidReport(scope: elsewhere, pane: pane, tab: tab, BrowserPageReport(
                url: "https://example.com/", title: "E", isLoading: loading, progress: 1, canGoBack: false,
                canGoForward: false, failure: nil))
        }
        #expect(try await visits(model).isEmpty)
        let globex = try #require(model.browserOrgFiles(for: elsewhere))
        #expect(try globex.history.matching(["example"], limit: 5).isEmpty)
    }

    @Test func aVisitLandsInThePlacesOrganisationNotTheActiveOne() async throws {
        let (model, pane, _, _) = try await homedBrowser()
        let drawn = try #require(model.browserScope)
        model.setOrganizationForTesting("globex")
        try await report(model, pane, loading: true)
        try await report(model, pane, title: "E", loading: false)
        await model.settleBrowserHistory()
        #expect(try model.browserOrgFiles(for: drawn)?.history.matching(["example"], limit: 5).count == 1)
        #expect(try model.browserOrgFiles?.history.matching(["example"], limit: 5).isEmpty == true)
    }

    @Test func suggestionsReadTheDrawnPlacesHistoryOnly() async throws {
        let (model, pane, _, _) = try await homedBrowser()
        try await report(model, pane, title: "Example", loading: true)
        try await report(model, pane, title: "Example", loading: false)
        await model.settleBrowserHistory()
        // Move the tab off the page so only history can answer.
        try await report(model, pane, url: "https://other.test/", title: "Other", loading: false)
        #expect(await model.browserSuggestions(typed: "example", pane: pane).map(\.kind) == [.history])
        let drawn = try #require(model.browserScope)
        model.setDrawnScopeForTesting(LayoutScope(
            organization: "umbrella", project: drawn.project, environment: drawn.environment,
            lineageRoot: drawn.lineageRoot))
        #expect(await model.browserSuggestions(typed: "example", pane: pane).isEmpty, "another place's files")
    }

    @Test func aPrefixMatchWithFewVisitsBeatsBusierRowsThatMerelyContainTheWord() async throws {
        let (model, pane, _, _) = try await homedBrowser()
        let scope = try #require(model.browserScope)
        let history = try #require(model.browserOrgFiles(for: scope)).history
        let now = Date()
        for i in 0..<12 {
            let url = "https://search.test/?q=github\(i)"
            for _ in 0..<5 { try history.record(url: url, title: "", at: now, newVisit: true) }
        }
        try history.record(url: "https://github.com/", title: "GitHub", at: now, newVisit: true)
        let rows = await model.browserSuggestions(typed: "github", pane: pane)
        #expect(rows.first?.url == "https://github.com/")
        #expect(BrowserSuggestions.completion("github", in: rows) == ".com")
    }

    @Test func aPlaceChangeDuringTheCallAnswersNothing() async throws {
        let (model, pane, _, _) = try await homedBrowser()
        try await report(model, pane, title: "Example", loading: true)
        try await report(model, pane, title: "Example", loading: false)
        await model.settleBrowserHistory()
        try await report(model, pane, url: "https://other.test/", title: "Other", loading: false)
        let drawn = try #require(model.browserScope)
        model.browserSuggestionsAfterReads = {
            model.setDrawnScopeForTesting(LayoutScope(
                organization: "umbrella", project: drawn.project, environment: drawn.environment,
                lineageRoot: drawn.lineageRoot))
        }
        #expect(await model.browserSuggestions(typed: "example", pane: pane).isEmpty)
    }

    @Test func suggestionsIncludeOpenTabsOfEveryBrowserPaneButNotTheOneBeingEdited() async throws {
        let (model, pane, _, _) = try await homedBrowser()
        await model.dispatchFromSurface("browser_open", .object(["url": .string("https://second.test/")]))
        await model.refreshLayout()
        let first = try #require(model.browser(pane)?.tabs.first?.id)
        await model.dispatchFromSurface("browser_select_tab", .object(["pane": .string(pane), "tab": .string(first)]))
        let kinds = await model.browserSuggestions(typed: "second", pane: pane)
        #expect(kinds.map(\.kind) == [.tab] && kinds[0].url == "https://second.test/")
        #expect(await model.browserSuggestions(typed: "a.test", pane: pane).isEmpty, "the tab being edited")
    }

    @Test func searchRowsComeLastAndAreTheEnginesOwn() async throws {
        let (model, pane, _, _) = try await homedBrowser()
        let rows = await model.browserSuggestions(typed: "swift", pane: pane, search: ["swift ui", "swift nio"])
        #expect(rows.map(\.kind) == [.search, .search] && rows.map(\.url) == ["swift ui", "swift nio"])
    }

    @Test func bookmarksAreLoadedWhenTheOrganisationIsActivated() async throws {
        let (model, pane, home, panes) = try await homedBrowser()
        let org = model.organization
        let files = try BrowserOrgFiles(home: home, org: org)
        try files.setBookmark(url: "https://marked.test/", title: "Marked", on: true, now: Date())
        await model.refreshBrowserSites()
        #expect(await panes.browserBookmarks(org: org).map(\.url) == ["https://marked.test/"])
        #expect(await model.browserSuggestions(typed: "marked", pane: pane).map(\.kind) == [.bookmark])
    }

    @Test func anUnreadableBookmarksFileLoadsAsNothingAndIsNotWritten() async throws {
        let (model, _, home, panes) = try await homedBrowser()
        let org = model.organization
        let files = try BrowserOrgFiles(home: home, org: org)
        try FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true)
        let file = files.directory.appendingPathComponent("bookmarks.json")
        try Data("{ not json".utf8).write(to: file)
        await model.refreshBrowserSites()
        #expect(await panes.browserBookmarks(org: org).isEmpty)
        #expect(try String(contentsOf: file, encoding: .utf8) == "{ not json")
    }

    /// A settings value with suggestions on or off, over a fetch that counts its calls.
    private func engineWindow(on: Bool, reply: String = #"["q",["a"]]"#) async throws
        -> (WindowModel, FetchLog) {
        let (model, _, _, _) = try await homedBrowser()
        model.browserSettings = SettingsBrowser(searchEngine: "google", startPage: "", searchSuggestions: on)
        let log = FetchLog()
        model.browserSuggestFetch = { url in log.add(url); return Data(reply.utf8) }
        return (model, log)
    }

    @Test func noEngineIsAskedWhileTheSettingIsOff() async throws {
        let (model, log) = try await engineWindow(on: false)
        #expect(await model.browserEngineSuggestions(typed: "swift").isEmpty)
        #expect(log.urls.isEmpty)
    }

    @Test func anAddressIsNeverSentToTheEngine() async throws {
        let (model, log) = try await engineWindow(on: true)
        #expect(await model.browserEngineSuggestions(typed: "localhost:3000").isEmpty)
        #expect(log.urls.isEmpty)
    }

    @Test func engineSuggestionsComeBackWhenOn() async throws {
        let (model, log) = try await engineWindow(on: true)
        #expect(await model.browserEngineSuggestions(typed: "swift ui") == ["a"])
        #expect(log.urls.count == 1 && log.urls[0].absoluteString.hasSuffix("q=swift%20ui"))
    }

    @Test func noEndpointOrAFailedFetchGivesNothing() async throws {
        let (model, log) = try await engineWindow(on: true)
        model.browserSettings = SettingsBrowser(searchEngine: "kagi", startPage: "", searchSuggestions: true)
        #expect(await model.browserEngineSuggestions(typed: "swift").isEmpty)
        #expect(log.urls.isEmpty)
        model.browserSettings = SettingsBrowser(searchEngine: "google", startPage: "", searchSuggestions: true)
        model.browserSuggestFetch = { _ in throw URLError(.timedOut) }
        #expect(await model.browserEngineSuggestions(typed: "swift").isEmpty)
    }

    @Test func theWindowHandsOutTheActiveOrganisationsFilesOnly() async throws {
        let (model, _, _, _, _) = await browserWindow()
        let home = testScratchRoot.appendingPathComponent(UUID().uuidString)
        model.browserHome = home
        await model.refreshContext()
        // Before an organisation is active there is nothing to hand out.
        let files = try #require(model.browserOrgFiles)
        #expect(!model.organization.isEmpty)
        #expect(files.org == model.organization)
        #expect(files.directory.path == home.path + "/.wakil/orgs/\(model.organization)/browser")
        let first = try files.identifier()
        model.setOrganizationForTesting("globex")
        let second = try #require(model.browserOrgFiles)
        #expect(second.directory.path == home.path + "/.wakil/orgs/globex/browser")
        #expect(second.directory != files.directory)
        #expect(try second.identifier() != first, "another organisation never gets this one's store id")
        model.browserHome = nil
        #expect(model.browserOrgFiles == nil, "no home, no files")
    }

    /// Task 10 (must-fix, destructive): Settings' Delete passes the organisation its question
    /// named; the action deletes nothing when another one is active by then.
    @Test func clearingBrowsingDataNamesTheOrganisationTheQuestionAsked() async throws {
        let files = try BrowserOrgFiles(home: testScratchRoot.appendingPathComponent(UUID().uuidString), org: "acme")
        let removed = LockedFlag()
        let (model, _, _, _, _) = await browserWindow(orgFiles: files, removeData: { @Sendable _, deleteFiles in
            try deleteFiles()
            removed.set()
        })
        let refused = try #require(await model.clearBrowserData(org: "globex"))
        #expect(refused.contains("The organisation changed; ask again."))
        #expect(!removed.value, "asked about globex, acme is active: nothing deleted")
        #expect(await model.clearBrowserData(org: "acme") == nil)
        #expect(removed.value)
    }

    @Test func noOrganisationYetMeansNoFiles() async {
        let (model, _, _, _, _) = await browserWindow()
        model.browserHome = testScratchRoot
        #expect(model.organization.isEmpty)
        #expect(model.browserOrgFiles == nil)
    }

    @Test func keysOutsideABrowserKeepTodaysMeaning() async throws {
        let (model, files, _, _, _) = await browserWindow()
        await model.refreshContext()
        await files.put("/p/api/a.go", "a")
        await model.dispatchFromSurface("editor_open", .object(["path": .string("/p/api/a.go")]))
        await model.refreshLayout()
        let editor = try #require(model.layoutSnapshot.panes.first { $0.kind == "editor" }?.id)
        await model.focusPane(id: editor)
        #expect(await !model.browserKey(.newTab))
        await model.newScratch()
        #expect(model.editor(editor)?.tabs.count == 2, "⌘T made a scratch tab")
        await model.closeFocusedTabOrPane()
        #expect(model.editor(editor)?.tabs.count == 1, "⌘W closed the editor's tab")
        #expect(!model.layoutSnapshot.panes.contains { $0.kind == "browser" })
    }

    @Test func cmdTInABrowserOpensATab() async throws {
        let (model, pane, _, _) = try await focusedBrowser()
        await model.newScratch()
        let s = try #require(model.browser(pane))
        #expect(s.tabs.count == 2 && s.active == s.tabs[1].id)
        #expect(s.activeTab?.command?.verb == .focusAddress, "a blank start page focuses the address")
        #expect(!model.layoutSnapshot.panes.contains { $0.kind == "editor" }, "no scratch tab was made")
        await model.closeFocusedTabOrPane()
        #expect(model.browser(pane)?.tabs.count == 1, "⌘W closed the browser's tab")
        await model.closeFocusedTabOrPane()
        #expect(!model.layoutSnapshot.panes.contains { $0.id == pane }, "its last tab closed the pane")
    }

    @Test func savedTabsFollowTheStore() async throws {
        let (model, pane, layout, _) = try await focusedBrowser()
        func saved() async -> [String]? { await layout.browserTabs(id: pane)?.tabs.map(\.url) }
        await model.dispatchFromSurface("browser_new_tab", .object(["pane": .string(pane), "url": .string("https://b.test/")]))
        #expect(await saved() == ["https://a.test/", "https://b.test/"])
        #expect(model.layoutSnapshot.panes.first { $0.id == pane }?.browserTabs?.count == 2, "the window's layout too")
        #expect(await model.browserKey(.tab(1)))
        #expect(await layout.browserTabs(id: pane)?.active == model.browser(pane)?.tabs[0].id)
        #expect(await model.browserKey(.closeTab))
        #expect(await saved() == ["https://b.test/"])
        // A report that moves the address is written on the debounce.
        model.browserTabsDelay = .milliseconds(1)
        let tab = try #require(model.browser(pane)?.active)
        let scope = try #require(model.browserScope)
        await model.browserPageDidReport(scope: scope, pane: pane, tab: tab, BrowserPageReport(
            url: "https://c.test/", title: "C", isLoading: false, progress: 1, canGoBack: true,
            canGoForward: false, failure: nil))
        #expect(model.browser(pane)?.activeTab?.url == "https://c.test/", "the cell is re-read")
        await model.settleBrowserTabsWrite(pane: pane)
        #expect(await saved() == ["https://c.test/"])
        #expect(model.browserTabsWriteCount == 1)
    }

    @Test func theSeamRefreshesTheCell() async throws {
        let (model, pane, _, _) = try await focusedBrowser()
        await model.dispatchFromSurface("browser_find", .object(["pane": .string(pane), "query": .string("x")]))
        let scope = try #require(model.browserScope)
        await model.browserFindDidReport(scope: scope, pane: pane, current: 2, total: 5)
        #expect(model.browser(pane)?.find?.total == 5)
        await model.browserDownloadDidChange(scope: scope, pane: pane, BrowserDownload(
            id: "d1", filename: "f", received: 0, expected: 1, state: .running))
        #expect(model.browser(pane)?.downloads.count == 1)
        let opener = try #require(model.browser(pane)?.active)
        let id = await model.browserPageOpenedTab(scope: scope, pane: pane, opener: opener, url: "https://p.test/")
        #expect(id != nil && model.browser(pane)?.active == id)
    }

    /// Pane and tab ids repeat from place to place, so a web view still running in another place
    /// names this place's `browser-1`/`t1`: what it says must change nothing here.
    @Test func aReportFromAnotherPlaceChangesNothingInThisOne() async throws {
        let (model, pane, layout, _) = try await focusedBrowser()
        model.browserTabsDelay = .milliseconds(1)
        let scope = try #require(model.browserScope)
        let tab = try #require(model.browser(pane)?.active)
        let before = try #require(model.browser(pane))
        let elsewhere = [
            LayoutScope(organization: "globex", project: scope.project, environment: scope.environment,
                        lineageRoot: scope.lineageRoot),
            LayoutScope(organization: scope.organization, project: scope.project + "-other",
                        environment: scope.environment, lineageRoot: scope.lineageRoot),
        ]
        for other in elsewhere {
            await model.browserPageDidReport(scope: other, pane: pane, tab: tab, BrowserPageReport(
                url: "https://mail.test/", title: "Inbox", isLoading: false, progress: 1, canGoBack: true,
                canGoForward: false, failure: nil))
            #expect(await model.browserPageOpenedTab(scope: other, pane: pane, opener: tab, url: "https://p.test/") == nil)
            #expect(await !model.browserPageClosed(scope: other, pane: pane, tab: tab))
            await model.browserFindDidReport(scope: other, pane: pane, current: 1, total: 9)
            await model.browserDownloadDidChange(scope: other, pane: pane, BrowserDownload(
                id: "d1", filename: "f", received: 0, expected: 1, state: .running))
        }
        await model.settleBrowserTabsWrite(pane: pane)
        #expect(model.browser(pane) == before, "the cell is as it was")
        #expect(await layout.browserTabs(id: pane)?.tabs.map(\.url) == ["https://a.test/"], "and the saved layout")
        // The same report from this place lands.
        await model.browserPageDidReport(scope: scope, pane: pane, tab: tab, BrowserPageReport(
            url: "https://c.test/", title: "C", isLoading: false, progress: 1, canGoBack: true,
            canGoForward: false, failure: nil))
        #expect(model.browser(pane)?.activeTab?.url == "https://c.test/")
        #expect(await model.browserPageClosed(scope: scope, pane: pane, tab: tab))
        #expect(!model.layoutSnapshot.panes.contains { $0.id == pane }, "its only tab closed, and the pane with it")
    }

    /// A place switch names the incoming place before the canvas is swapped: until the swap, the
    /// canvas drawn — and the scope a browser pane is keyed with — is still the outgoing place's,
    /// and the incoming place's seam calls are refused.
    @Test func theDrawnScopeIsTheCanvasNotTheContext() async throws {
        let (model, pane, _, _) = try await focusedBrowser()
        let drawn = try #require(model.browserScope)
        #expect(model.drawnScope == drawn)
        model.setOrganizationForTesting("globex")
        #expect(model.organization == "globex")
        #expect(model.browserScope == drawn, "the canvas on screen is still the outgoing place's")
        let incoming = LayoutScope(organization: "globex", project: drawn.project, environment: drawn.environment,
                                   lineageRoot: drawn.lineageRoot)
        let tab = try #require(model.browser(pane)?.active)
        await model.browserPageDidReport(scope: incoming, pane: pane, tab: tab, BrowserPageReport(
            url: "https://mail.test/", title: "Inbox", isLoading: false, progress: 1, canGoBack: false,
            canGoForward: false, failure: nil))
        #expect(model.browser(pane)?.activeTab?.url == "https://a.test/", "the incoming place's report is refused")
    }

    /// A web view is built on its place's organisation's store, whatever the context names: in the
    /// gap before a canvas swap they differ.
    @Test func aPlacesFilesAreItsOwnOrganisationsNotTheContexts() async throws {
        let (model, _, _, _) = try await focusedBrowser()
        model.browserHome = testScratchRoot.appendingPathComponent(UUID().uuidString)
        let drawn = try #require(model.browserScope)
        model.setOrganizationForTesting("globex")
        let files = try #require(model.browserOrgFiles(for: drawn))
        #expect(files.org == drawn.organization && files.org != "globex")
        #expect(model.browserOrgFiles?.org == "globex", "the context's are another organisation's")
        #expect(model.browserOrgFiles(for: LayoutScope(organization: "", project: "", environment: "")) == nil)
    }

    /// Mid-swap — the pane store's screen moved to the incoming canvas, the window not yet re-read —
    /// a report tagged with the canvas still drawn must not land in the incoming one's pane of the
    /// same id (`showCanvas` to a bare organisation moves the stores before `readLayoutSnapshot`).
    @Test func aReportDuringACanvasSwapChangesNothingInTheIncomingCanvas() async throws {
        let (model, pane, _, _, panes) = try await focusedBrowserAndPanes()
        let drawn = try #require(model.browserScope)
        let tab = try #require(model.browser(pane)?.active)
        let bare = LayoutScope(organization: "globex", project: "", environment: "")
        await panes.switchScope(to: bare)
        await panes.browserRestore(paneId: pane, tabs: [BrowserSavedTab(id: tab, url: "https://b.test/", title: "B")],
                                         active: tab)
        let incoming = await panes.browserSnapshot(paneId: pane)
        await model.browserPageDidReport(scope: drawn, pane: pane, tab: tab, BrowserPageReport(
            url: "https://mail.test/", title: "Inbox", isLoading: false, progress: 1, canGoBack: false,
            canGoForward: false, failure: nil))
        #expect(await panes.browserSnapshot(paneId: pane) == incoming, "the incoming canvas's pane is untouched")
    }

    @Test func browserKeysDispatchTheirActions() async throws {
        let (model, pane, _, journal) = try await focusedBrowser()
        #expect(await model.browserKey(.zoomIn))
        #expect(model.browser(pane)?.activeTab?.zoom == 1.1)
        #expect(await model.browserKey(.reload))
        #expect(model.browser(pane)?.activeTab?.command?.verb == .load("https://a.test/"), "never loaded: it loads")
        let seq = model.browser(pane)?.activeTab?.command?.seq ?? 0
        #expect(await model.browserKey(.focusAddress))
        #expect(model.browser(pane)?.activeTab?.command == BrowserCommand(seq: seq + 1, verb: .focusAddress))
        let lines = try String(contentsOf: journal, encoding: .utf8).split(separator: "\n")
        #expect(lines.contains { $0.contains("\"browser_focus_address\"") }, "⌘L went through the action")
        #expect(await model.browserKey(.find))
        #expect(model.browser(pane)?.find?.query == "")
        await model.dispatchFromSurface("browser_new_tab", .object(["pane": .string(pane), "url": .string("https://b.test/")]))
        #expect(await model.browserKey(.nextTab))
        #expect(model.browser(pane)?.active == model.browser(pane)?.tabs[0].id, "wraps to the first")
        #expect(await model.browserKey(.tab(9)))
        #expect(model.browser(pane)?.active == model.browser(pane)?.tabs[1].id)
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    func set() { lock.withLock { stored = true } }
    var value: Bool { lock.withLock { stored } }
}

// MARK: - 3c-ii Task 9: the window keeps the sites in step and forgets a closed conversation's list

private let reachOrg = "initech"
private let reachPlace = Place(organization: reachOrg, project: "shop", environment: "staging")

/// A `ctx_config_tree` answer: the project `shop` with `staging` and `qa`, and `ops`' production `live`.
private func reachTree() -> JSONValue {
    func env(_ name: String, _ url: String, production: Bool? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["name": .string(name), "api": .array([.object(["baseUrl": .string(url)])])]
        if let production { o["production"] = .bool(production) }
        return .object(o)
    }
    return .object(["structuredContent": .object([
        "org": .object(["id": .string(reachOrg)]),
        "projects": .array([
            .object(["name": .string("shop"), "environments": .array([
                env("staging", "https://staging.initech.dev"), env("qa", "https://qa.initech.dev")])]),
            .object(["name": .string("ops"), "environments": .array([
                env("live", "https://api.initech.com", production: true)])]),
        ]),
    ])])
}

/// Holds `ctx_config_tree` open until released, so a test can switch organisation mid-read.
private actor ReachGate {
    private var entered = false
    private var open = false
    func enter() async {
        entered = true
        while !open { try? await Task.sleep(nanoseconds: 1_000_000) }
    }
    func waitUntilEntered() async { while !entered { try? await Task.sleep(nanoseconds: 1_000_000) } }
    func release() { open = true }
}

private final class CallCount: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}

private struct ReachBackend: ToolCaller {
    func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        switch name {
        case "get_context":
            return .object(["structuredContent": .object([
                "Org": .string(reachOrg), "Project": .string("shop"), "Environment": .string("staging"),
                "RootPaths": .array([]), "ActiveProvider": .string("")])])
        default:
            return .object(["structuredContent": .object([:])])
        }
    }
}

/// A window with browser actions and a counted `ctx_config_tree`, running agents on `sessions`.
@MainActor
private func reachWindow(
    _ sessions: Sessions, trees: CallCount = CallCount(), context: (any ToolCaller)? = nil,
    gate: ReachGate? = nil, confirmations: ConfirmationBroker = ConfirmationBroker()
) async -> (WindowModel, PaneStore) {
    let dir = testScratchRoot.appendingPathComponent("browser-reach-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let registry = ActionRegistry(journalDirectory: dir, sessionId: "browser-reach")
    let panes = PaneStore()
    let layout = LayoutStore()
    await registerLayoutActions(into: registry, layout: layout, panes: panes)
    await registerBrowserActions(into: registry, panes: panes, layout: layout, settings: { .defaults })
    await registry.register(Action(
        name: "ctx_config_tree", description: "", kind: .read, audience: .agentReachable,
        schema: .object(["type": .string("object")]), handler: { _ in trees.bump(); await gate?.enter(); return reachTree() }))
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, persistence: nil,
        context: context.map { ContextStore(client: $0) },
        harnessFactory: { place, _, socketPath in sessions.harness(place, socketPath) },
        resumes: ResumeBroker(), rootPath: "/tmp", providerId: "test-provider",
        lookupFactory: { _ in AlwaysSucceedsCredentialsLookupForTesting() }, confirmations: confirmations,
        agentSocketFactory: sessions.socketFactory, environment: "staging")
    model.setOrganizationForTesting(reachOrg)
    model.seedForTesting(providerId: "test-provider", rootPath: "/tmp", thoughts: 0,
                         project: "shop", environment: "staging")
    return (model, panes)
}

@Suite @MainActor struct WindowModelBrowserReachTests {
    @Test func sitesFollowTheConfigTree() async {
        let (model, panes) = await reachWindow(Sessions())
        #expect(model.browserSites == .unread)
        await model.refreshBrowserSites()
        #expect(model.browserSites.read)
        #expect(model.browserSites.isProduction("api.initech.com"), "another project's live is production")
        #expect(!model.browserSites.isProduction("staging.initech.dev"))
        #expect(model.browserSites.tag("https://staging.initech.dev/x") == .environment("staging"))
        #expect(await panes.browserSites(org: reachOrg) == model.browserSites)
        #expect(model.settings != nil, "the tree it read is the settings too")
    }

    @Test func aSwitchRecomputesTheEnvironmentTag() async {
        let (model, _) = await reachWindow(Sessions())
        await model.refreshBrowserSites()
        #expect(model.browserSites.tag("https://staging.initech.dev/") == .environment("staging"))
        model.seedForTesting(providerId: "test-provider", rootPath: "/tmp", thoughts: 0,
                             project: "shop", environment: "qa")
        await model.refreshBrowserSites()
        #expect(model.browserSites.tag("https://staging.initech.dev/") == nil, "staging's tag is gone")
        #expect(model.browserSites.tag("https://qa.initech.dev/") == .environment("qa"))
    }

    @Test func launchAndSettingsRefreshReadTheSites() async {
        let trees = CallCount()
        let (model, _) = await reachWindow(Sessions(), trees: trees, context: ReachBackend())
        await model.refreshContext()
        #expect(model.browserSites.read, "launch reads the sites")
        let afterLaunch = trees.value
        await model.refreshSettings()
        #expect(trees.value == afterLaunch + 1, "a settings refresh reads the tree once, for both")
        #expect(model.browserSites.read)
    }

    @Test func closingAConversationForgetsOnlyItsSites() async throws {
        let sessions = Sessions()
        let (model, panes) = await reachWindow(sessions)
        #expect(await model.send("first"))
        let first = try #require(model.currentAgent)
        await model.newConversation()
        #expect(await model.send("second"))
        let second = try #require(model.currentAgent)
        #expect(first.id != second.id)
        await panes.browserAllow(site: "staging.initech.dev", conversation: first.id)
        await panes.browserAllow(site: "staging.initech.dev", conversation: second.id)

        await model.closeConversation(first.id)
        // A turn is in flight, so it asks; the answer closes it.
        await model.answerCloseQuestion(close: true)

        #expect(model.conversation(id: first.id) == nil)
        #expect(await panes.browserAllowed(conversation: first.id).isEmpty)
        #expect(await panes.browserAllowed(conversation: second.id) == ["staging.initech.dev"])
        await model.shutdown()
    }

    @Test func revokeTakesTheSiteOffTheScreensConversation() async throws {
        let (model, panes) = await reachWindow(Sessions())
        #expect(await model.send("go"))
        let agent = try #require(model.currentAgent)
        await panes.browserAllow(site: "staging.initech.dev", conversation: agent.id)
        await panes.browserAllow(site: "qa.initech.dev", conversation: agent.id)
        await model.refreshPanes()
        #expect(model.browserAllowedOnScreen == ["staging.initech.dev", "qa.initech.dev"])

        await model.revokeBrowserSite("staging.initech.dev")

        #expect(await panes.browserAllowed(conversation: agent.id) == ["qa.initech.dev"])
        #expect(model.browserAllowedOnScreen == ["qa.initech.dev"])
        await model.shutdown()
    }

    @Test func anOrgSwitchResetsTheSites() async {
        let (model, panes) = await reachWindow(Sessions())
        await model.refreshBrowserSites()
        #expect(model.browserSites.read)
        await model.setOrganization("globex")
        #expect(model.browserSites == .unread, "unread until the new org's tree is read")
        #expect(model.browserAllowedOnScreen.isEmpty)
        #expect(await panes.browserSites(org: "globex") == .unread)
    }

    @Test func aReadAfterASwitchFillsOnlyTheOrgNowOpen() async {
        let (model, panes) = await reachWindow(Sessions())
        await model.refreshBrowserSites()
        await model.setOrganization("globex")
        await model.refreshBrowserSites()
        #expect(await panes.browserSites(org: "globex").read, "read for the org now open")
        #expect(await panes.browserSites(org: reachOrg) == .unread, "the outgoing org's copy was cleared")
    }

    @Test func anOrgSwitchAndReturnNeverPricesFromTheOldList() async {
        let (model, panes) = await reachWindow(Sessions())
        await model.refreshBrowserSites()
        #expect(await panes.browserSites(org: reachOrg).read)
        await model.setOrganization("globex")
        await model.setOrganization(reachOrg)
        #expect(await panes.browserSites(org: reachOrg) == .unread, "A -> B -> A: unread until re-read")
        #expect(model.browserSites == .unread)
    }

    @Test func aSettingsReadInFlightDuringAnOrgSwitchInstallsNothingForTheNewOrg() async throws {
        let gate = ReachGate()
        let (model, panes) = await reachWindow(Sessions(), gate: gate)
        let read = Task { await model.refreshSettings() }
        await gate.waitUntilEntered()
        await model.setOrganization("globex")
        await gate.release()
        await read.value
        #expect(model.browserSites == .unread, "the outgoing org's tree is not the new org's sites")
        #expect(await panes.browserSites(org: "globex") == .unread)
        #expect(await panes.browserSites(org: reachOrg) == .unread)
    }

    @Test func aResumeClearsWhichToolUsesWereBrowserTools() async throws {
        let sessions = Sessions()
        let (model, _) = await reachWindow(sessions)
        await model.registryForTesting.register(Action(
            name: "session_read", description: "", kind: .read, audience: .agentReachable,
            schema: .object(["type": .string("object")]),
            handler: { _ in .object(["structuredContent": .object([
                "cwd": .string("/tmp"), "provider": .string("test-provider"), "entries": .array([])])]) }))
        await model.registryForTesting.register(Action(
            name: "session_record_parent", description: "", kind: .control, audience: .operatorOnly,
            schema: .object(["type": .string("object")]), handler: { _ in .object([:]) }))
        #expect(await model.send("go"))
        let agent = try #require(model.currentAgent)
        agent.toolNames["t1"] = "browser_read"
        agent.turnInFlight = false
        await model.resume(sessionId: "past-1", in: agent.place, conversation: agent.id)
        #expect(agent.toolNames.isEmpty, "\(model.status)")
        await model.shutdown()
    }

    @Test func aSpokenTurnsSiteQuestionWantsTyping() async throws {
        let (model, _) = await reachWindow(Sessions())
        func ask(_ conversation: String?) -> PendingMutation {
            PendingMutation(action: "browser_click", params: .object([:]), database: nil, statement: "",
                            affectsEveryRow: false, origin: .agent, place: reachPlace,
                            conversation: conversation, ask: .site("staging.initech.dev"))
        }
        #expect(await model.send("typed", via: .typed))
        let agent = try #require(model.currentAgent)
        #expect(agent.lastTurnSource == .typed)
        #expect(!model.siteQuestionWantsTyping(ask(agent.id)), "typed: a click answers")
        agent.turnInFlight = false
        #expect(await model.send("spoken", via: .voice))
        #expect(agent.lastTurnSource == .voice)
        #expect(model.siteQuestionWantsTyping(ask(agent.id)), "spoken: typed confirm")
        #expect(model.siteQuestionWantsTyping(ask(nil)), "unknown asks for typing")
        #expect(model.siteQuestionWantsTyping(ask("no-such-conversation")), "unknown asks for typing")
        await model.shutdown()
    }

    /// Ruling 13: a typed request's site question is answered by a click on Allow; a spoken one's only
    /// by typing confirm (Invariant 7), and a production act or any other change never by a click.
    @Test func onlyATypedRequestsSiteQuestionIsAllowedByAClick() async throws {
        let broker = ConfirmationBroker(timeout: .seconds(60))
        let (model, _) = await reachWindow(Sessions(), confirmations: broker)
        func park(_ ask: PendingAsk, _ conversation: String) async -> (PendingMutation, Task<ConfirmationDecision, Never>) {
            let proposal = PendingMutation(
                action: "browser_click", params: .object([:]), database: nil, statement: "click \"Confirm\"",
                affectsEveryRow: false, origin: .agent, place: reachPlace, conversation: conversation, ask: ask)
            let parked = Task { await broker.request(proposal) }
            for _ in 0..<2000 where model.pending?.id != proposal.id { await Task.yield() }
            return (proposal, parked)
        }

        // A click that did not answer leaves the proposal to the Cancel after it.
        func clickThenCancel(_ ask: PendingAsk, _ conversation: String) async -> ConfirmationDecision {
            let (proposal, parked) = await park(ask, conversation)
            #expect(model.pending?.id == proposal.id)
            await model.allowPendingSite()
            await model.cancelPending()
            return await parked.value
        }

        #expect(await model.send("typed", via: .typed))
        let agent = try #require(model.currentAgent)
        #expect(await clickThenCancel(.productionSite("api.initech.com"), agent.id) == .cancelled,
                "a production act is never answered by a click")
        #expect(await clickThenCancel(.change, agent.id) == .cancelled, "nor is any other change")
        #expect(await clickThenCancel(.site("staging.initech.dev"), agent.id) == .approved,
                "typed: Allow answers the site question")

        agent.turnInFlight = false
        #expect(await model.send("spoken", via: .voice))
        #expect(await clickThenCancel(.site("staging.initech.dev"), agent.id) == .cancelled,
                "spoken: a click does not answer it")
        let (_, spoken) = await park(.site("staging.initech.dev"), agent.id)
        await model.confirmPending(typed: "confirm")
        #expect(await spoken.value == .approved, "spoken: typed confirm does")
        await model.shutdown()
    }

    @Test func aFreshSessionForgetsWhichToolUsesWereBrowserTools() async throws {
        let sessions = Sessions()
        let (model, _) = await reachWindow(sessions)
        #expect(await model.send("go"))
        let agent = try #require(model.currentAgent)
        agent.toolNames["t1"] = "browser_read"
        agent.turnInFlight = false
        await model.setProvider("other")
        #expect(agent.toolNames.isEmpty, "the thread was cleared, so were its tool names")
        await model.shutdown()
    }
}

/// The URLs a stubbed engine fetch was asked for.
final class FetchLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URL] = []
    func add(_ url: URL) { lock.withLock { stored.append(url) } }
    var urls: [URL] { lock.withLock { stored } }
}
