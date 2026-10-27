import Foundation
import Testing
@testable import WakilKit

/// A window over the layout, editor and browser actions (`editorWindowFull`'s shape, plus the
/// browser's), its start page blank. `journal` is its registry's journal file.
@MainActor
private func browserWindow(
    orgFiles: BrowserOrgFiles? = nil, removeData: BrowserDataRemover? = nil,
    context: (any ToolCaller)? = nil, quickModel: (any QuickModel)? = nil,
    pullRequests: @escaping BrowserPullRequestsRead = { nil }
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
        context: ContextStore(client: context ?? GitRootsContext(roots: ["/p/api"])),
        harnessFactory: { _, _, _ in nil }, resumes: ResumeBroker(),
        rootPath: "/tmp", providerId: "",
        lookupFactory: { _ in EditorWindowLookup() },
        rootWatcher: nil, editorRootWatcher: RecordingRootWatcher(), fileLists: fileLists, gitStatus: nil,
        paletteClients: PaletteClients(files: fileLists), placeClients: nil,
        agentSocketFactory: { _, _ in NoAgentSocket() },
        quickModelFactory: quickModel.map { model in { @Sendable _, _ in model } })
    await registerEditorActions(
        into: registry, panes: panes, layout: layout, files: fileLists, fileLists: fileLists,
        gitStatus: nil, roots: { [weak model] in await model?.gitRootPaths ?? [] })
    await registerBrowserActions(into: registry, panes: panes, layout: layout, settings: { .defaults },
                                 orgFiles: { orgFiles }, removeData: removeData, pullRequests: pullRequests)
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

    // MARK: 3d-i Task 12: New Group… opens the field of the group the call made

    @Test func aSurfaceCallAnswersTheGroupItMadeAndNothingWhenRefused() async throws {
        let (model, pane, _, _) = try await focusedBrowser()
        let tab = try #require(model.browser(pane)?.tabs.first?.id)
        let made = await model.dispatchFromSurfaceAnswer("browser_group", .object([
            "pane": .string(pane), "action": .string("create"), "tabs": .array([.string(tab)])]))
        guard case .object(let o)? = made, case .string(let group)? = o["group"] else {
            Issue.record("no group in \(String(describing: made))")
            return
        }
        #expect(model.browser(pane)?.group(group) != nil, "the group answered is the one drawn")
        let refused = await model.dispatchFromSurfaceAnswer("browser_group", .object([
            "pane": .string(pane), "action": .string("create"), "tabs": .array([.string("no-such-tab")])]))
        #expect(refused == nil, "a refusal answers nothing: no name field opens")
        #expect(!model.status.isEmpty, "and is on the status line, as for any control")
    }

    // MARK: 3d-i Task 9: ⌘W twice on a pinned tab, the tab column

    /// A fixed, steppable clock for `browserNow`.
    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 5_000)
    }

    /// The pane's second tab, `t2`, added; returns the clock the model reads.
    private func twoTabs(_ model: WindowModel, _ pane: String, _ panes: PaneStore, pinned: Bool) async throws -> Clock {
        await model.dispatchFromSurface("browser_new_tab", .object(["pane": .string(pane),
                                                                    "url": .string("https://b.test/")]))
        await model.refreshPanes()
        let clock = Clock()
        model.browserNow = { [clock] in clock.now }
        if pinned {
            let id = try #require(model.browser(pane)?.active)
            await panes.updateBrowser(paneId: pane, create: true) { s in
                for i in s.tabs.indices where s.tabs[i].id == id { s.tabs[i].pin = "pin1" }
            }
            await model.refreshPanes()
        }
        return clock
    }

    @Test func anUnpinnedTabClosesOnTheFirstPress() async throws {
        let (model, pane, _, _, panes) = try await focusedBrowserAndPanes()
        _ = try await twoTabs(model, pane, panes, pinned: false)
        #expect(model.browser(pane)?.tabs.count == 2)
        #expect(await model.browserKey(.closeTab))
        #expect(model.browser(pane)?.tabs.count == 1)
        #expect(model.browserCloseArm == nil)
    }

    @Test func aPinnedTabTakesTwoPresses() async throws {
        let (model, pane, _, _, panes) = try await focusedBrowserAndPanes()
        let clock = try await twoTabs(model, pane, panes, pinned: true)
        let tab = try #require(model.browser(pane)?.active)
        #expect(await model.browserKey(.closeTab))
        #expect(model.browser(pane)?.tabs.count == 2, "the first press only arms")
        #expect(model.browserCloseArm?.tab == tab)
        clock.now = clock.now.addingTimeInterval(1)
        #expect(await model.browserKey(.closeTab))
        #expect(model.browser(pane)?.tabs.count == 1, "the second press within 2 s closes")
        #expect(model.browserCloseArm == nil)
    }

    @Test func aPressAfterTwoSecondsOnAPinnedTabArmsAgain() async throws {
        let (model, pane, _, _, panes) = try await focusedBrowserAndPanes()
        let clock = try await twoTabs(model, pane, panes, pinned: true)
        _ = await model.browserKey(.closeTab)
        clock.now = clock.now.addingTimeInterval(3)
        _ = await model.browserKey(.closeTab)
        #expect(model.browser(pane)?.tabs.count == 2)
        #expect(model.browserCloseArm != nil)
    }

    @Test func aTabOfAPinnedGroupCountsAsPinned() async throws {
        let (model, pane, _, _, panes) = try await focusedBrowserAndPanes()
        let clock = try await twoTabs(model, pane, panes, pinned: false)
        _ = clock
        let id = try #require(model.browser(pane)?.active)
        await panes.updateBrowser(paneId: pane, create: true) { s in
            s.groups.append(BrowserGroup(id: "g1", name: "G", colour: .blue, kind: .own, pin: "pin2"))
            for i in s.tabs.indices where s.tabs[i].id == id { s.tabs[i].group = "g1" }
        }
        await model.refreshPanes()
        #expect(await model.browserKey(.closeTab))
        #expect(model.browser(pane)?.tabs.count == 2, "a tab of a pinned group arms, not closes")
        #expect(model.browserCloseArm?.tab == id)
    }

    @Test func theAgentClosesAPinnedTabInOneCall() async throws {
        let (model, pane, _, _, panes) = try await focusedBrowserAndPanes()
        _ = try await twoTabs(model, pane, panes, pinned: true)
        await model.dispatchFromSurface("browser_close_tab", .object(["pane": .string(pane)]))
        await model.refreshPanes()
        #expect(model.browser(pane)?.tabs.count == 1)
    }

    @Test func tabColumnTogglesAndIsSaved() async throws {
        let (model, pane, layout, _, _) = try await focusedBrowserAndPanes()
        await model.dispatchFromSurface("browser_tab_column", .object(["pane": .string(pane)]))
        await model.refreshPanes()
        #expect(model.browser(pane)?.tabColumnHidden == true)
        #expect(await layout.snapshot().panes.first { $0.id == pane }?.browserColumnHidden == true)
        await model.dispatchFromSurface("browser_tab_column", .object(["pane": .string(pane), "hidden": .bool(true)]))
        await model.refreshPanes()
        #expect(model.browser(pane)?.tabColumnHidden == true, "hidden true sets, it does not toggle")
        await model.dispatchFromSurface("browser_tab_column", .object(["pane": .string(pane), "hidden": .bool(false)]))
        await model.refreshPanes()
        #expect(model.browser(pane)?.tabColumnHidden == false)
    }

    @Test func toggleTabColumnPassesTheKeyInHorizontalMode() async throws {
        let (model, pane, _, _, panes) = try await focusedBrowserAndPanes()
        #expect(await !model.browserKey(.toggleTabColumn))
        #expect(model.browser(pane)?.tabColumnHidden == false)
        model.browserSettings = SettingsBrowser(searchEngine: "google", startPage: "", tabs: "vertical")
        #expect(await model.browserKey(.toggleTabColumn))
        #expect(model.browser(pane)?.tabColumnHidden == true)
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

    @Test func aLoadOfAnotherPageCountsOnceNotTwice() async throws {
        let (model, pane, _, _) = try await homedBrowser()
        try await report(model, pane, loading: true)
        try await report(model, pane, title: "Example", loading: false)
        try await report(model, pane, url: "https://example.com/b", title: "B", loading: true)
        try await report(model, pane, url: "https://example.com/b", title: "B", loading: false)
        let rows = try await visits(model)
        #expect(rows.map(\.url).sorted() == ["https://example.com/", "https://example.com/b"])
        #expect(rows.allSatisfy { $0.count == 1 })
    }

    @Test func anAddressChangeWithoutALoadIsAVisit() async throws {
        let (model, pane, _, _) = try await homedBrowser()
        try await report(model, pane, loading: true)
        try await report(model, pane, title: "Example", loading: false)
        try await report(model, pane, url: "https://example.com/spa", title: "Spa Page", loading: false)
        let rows = try await visits(model)
        let spa = rows.filter { $0.url == "https://example.com/spa" }
        #expect(spa.count == 1 && spa[0].count == 1 && spa[0].title == "Spa Page")
    }

    @Test func aFragmentOnlyChangeIsNotAVisit() async throws {
        let (model, pane, _, _) = try await homedBrowser()
        try await report(model, pane, loading: true)
        try await report(model, pane, title: "Example", loading: false)
        try await report(model, pane, url: "https://example.com/#section", title: "Example", loading: false)
        let rows = try await visits(model)
        #expect(rows.map(\.url) == ["https://example.com/"] && rows[0].count == 1)
    }

    @Test func aTabWithNoAddressIsNeverSuggested() async throws {
        let (model, pane, _, panes) = try await homedBrowser()
        await panes.updateBrowser(paneId: pane) { s in s.tabs.append(BrowserTab(id: "t9", url: "", title: "")) }
        try await report(model, pane, url: "https://a.test/", loading: false)   // re-reads the pane
        #expect(model.browser(pane)?.tabs.contains { $0.url.isEmpty } == true, "a blank tab is open")
        let rows = await model.browserSuggestions(typed: "new", pane: pane)
        #expect(rows.isEmpty, "\(rows)")
    }

    @Test func theEditedTabIsExcludedByPaneAndTabNotByTabAlone() async throws {
        let (model, paneA, _, _) = try await homedBrowser()
        await model.dispatchFromSurface("pane_open", .object(["kind": .string("browser")]))
        await model.refreshLayout()
        let browsers = model.layoutSnapshot.panes.filter { $0.kind == "browser" }.map(\.id)
        let paneB = try #require(browsers.first { $0 != paneA })
        await model.dispatchFromSurface("browser_open", .object(["pane": .string(paneB), "url": .string("https://b.test/")]))
        await model.refreshLayout()
        let a = try #require(model.browser(paneA)?.active)
        let b = try #require(model.browser(paneB)?.active)
        #expect(a == b, "both panes number their first tab alike")
        let rows = await model.browserSuggestions(typed: "b.test", pane: paneA)
        #expect(rows.map(\.kind) == [.tab] && rows[0].url == "https://b.test/")
        #expect(await model.browserSuggestions(typed: "a.test", pane: paneA).isEmpty)
    }

    @Test func aFailedLoadIsNotRecorded() async throws {
        let (model, pane, _, _) = try await homedBrowser()
        try await report(model, pane, loading: true)
        try await report(model, pane, loading: false, failure: "The server can't be found")
        #expect(try await visits(model).isEmpty)
    }

    @Test func theTabAndBookmarkRowsUseTheLabelTheBareURLAndNewestFirst() async throws {
        let (model, pane, _, panes) = try await homedBrowser()
        let scope = try #require(model.browserScope)
        let tab = try #require(model.browser(pane)?.tabs.first)
        await panes.browserSetBookmarks(org: scope.organization, [
            BrowserBookmark(url: "https://www.example.com/old", title: "Old", added: Date(timeIntervalSince1970: 10)),
            BrowserBookmark(url: "https://example.com/new", title: "New", added: Date(timeIntervalSince1970: 20)),
        ])
        #expect(tab.label == "a.test", "a tab with no title is labelled by its host")
        #expect(model.paletteBrowserTabs() == [PaletteBrowserTab(
            pane: pane, tab: tab.id, title: tab.label, subtitle: "a.test")])
        #expect(await model.paletteBookmarks() == [
            PaletteBookmark(url: "https://example.com/new", title: "New", subtitle: "example.com/new"),
            PaletteBookmark(url: "https://www.example.com/old", title: "Old", subtitle: "example.com/old"),
        ])
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

    // MARK: 3c-iii Task 9: the ★ menu's list and a chosen tab row

    @Test func theStarMenuReadsTheDrawnOrganisationsBookmarks() async throws {
        let (model, _, home, panes) = try await homedBrowser()
        let files = try BrowserOrgFiles(home: home, org: model.organization)
        try files.setBookmark(url: "https://marked.test/", title: "Marked", on: true, now: Date())
        await model.refreshBrowserSites()
        #expect(model.browserBookmarksOnScreen.map(\.url) == ["https://marked.test/"])
        await panes.browserSetBookmarks(org: model.organization, [])
        await model.refreshPanes()
        #expect(model.browserBookmarksOnScreen.isEmpty, "re-read after every dispatch")
        let drawn = try #require(model.browserScope)
        await panes.browserSetBookmarks(org: "umbrella", [BrowserBookmark(url: "https://u.test/", title: "", added: Date())])
        model.setDrawnScopeForTesting(LayoutScope(
            organization: "umbrella", project: drawn.project, environment: drawn.environment,
            lineageRoot: drawn.lineageRoot))
        await model.refreshPanes()
        #expect(model.browserBookmarksOnScreen.map(\.url) == ["https://u.test/"], "the drawn place's organisation")
    }

    @Test func aTabRowOfThisPaneSelectsItAndKeepsTheFocus() async throws {
        let (model, pane, _, _) = try await focusedBrowser()
        await model.dispatchFromSurface("browser_new_tab", .object(["pane": .string(pane)]))
        let first = try #require(model.browser(pane)?.tabs.first)
        await model.browserChooseTab(first.id, url: first.url, from: pane)
        #expect(model.browser(pane)?.active == first.id)
        #expect(model.layoutSnapshot.focusedId == pane)
    }

    @Test func aTabRowOfAnotherPaneSelectsItThereAndFocusesThatPane() async throws {
        let (model, pane, _, _) = try await focusedBrowser()
        await model.dispatchFromSurface("pane_open", .object(["kind": .string("browser")]))
        await model.refreshLayout()
        let other = try #require(model.layoutSnapshot.panes.first { $0.kind == "browser" && $0.id != pane }?.id)
        await model.dispatchFromSurface("browser_open", .object(["url": .string("https://b.test/"), "pane": .string(other)]))
        await model.focusPane(id: pane)
        await model.refreshLayout()
        #expect(model.layoutSnapshot.focusedId == pane)
        let tab = try #require(model.browser(other)?.tabs.first { $0.url == "https://b.test/" })
        await model.browserChooseTab(tab.id, url: tab.url, from: pane)
        await model.refreshLayout()
        #expect(model.browser(other)?.active == tab.id)
        #expect(model.layoutSnapshot.focusedId == other)
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
                                         active: tab, groups: [], columnHidden: false)
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

// MARK: - 3d-i Task 10: groups named by the quick model, pins of the place shown

/// `get_context` for organisation `acme` and a project that can be switched, and a `config_tree` with
/// one local quick provider serving `respond` (`WindowModelCommitDraftTests`' shape).
private actor NamingContext: ToolCaller {
    private var project = "alpha"
    private var org = "acme"
    func switchTo(project: String) { self.project = project }
    func switchTo(org: String) { self.org = org }
    func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        switch name {
        case "get_context":
            return .object(["structuredContent": .object([
                "Org": .string(org), "Environment": .string("staging"),
                "Project": .object(["name": .string(project)]), "RootPaths": .array([]),
            ])])
        case "config_tree":
            return .object(["structuredContent": .object([
                "org": .object(["id": .string("acme"), "quickProvider": .string("qwen")]),
                "providers": .array([.object(["id": .string("qwen"), "kind": .string("local"),
                                              "baseURL": .string("http://127.0.0.1:8012"),
                                              "serves": .array([.string("respond")])])]),
                "projects": .array([]),
            ])])
        default:
            return .object(["structuredContent": .object([:])])
        }
    }
}

/// Answers `respond` with `reply`, held until `release()` when `gated`; counts and keeps every input.
private actor NamingModel: QuickModel {
    nonisolated let serves: Set<QuickOperation> = [.respond]
    let reply: String
    private var open: Bool
    private(set) var inputs: [String] = []
    init(reply: String, gated: Bool = false) {
        self.reply = reply
        open = !gated
    }
    func infill(_ r: InfillRequest) async throws -> String { "" }
    func respond(_ r: RespondRequest) async throws -> String {
        inputs.append(r.input)
        for _ in 0..<10_000 where !open { try await Task.sleep(nanoseconds: 1_000_000) }
        return reply
    }
    func release() { open = true }
    /// Waits (up to 5 s) for the first request.
    func waitUntilAsked() async {
        for _ in 0..<5_000 where inputs.isEmpty { try? await Task.sleep(nanoseconds: 1_000_000) }
    }
    func shutdown() async {}
}

@Suite @MainActor struct WindowModelBrowserNamingTests {
    /// A window in project `alpha` of `acme` with quick tasks built on `model`, and one browser pane of
    /// two loose tabs on `docs.example.com`, neither loaded yet.
    private func twoTabsOneSite(_ model: NamingModel, context: NamingContext = NamingContext())
        async throws -> (WindowModel, String, LayoutStore, PaneStore)
    {
        let (window, _, layout, _, panes) = await browserWindow(context: context, quickModel: model)
        window.browserTabsDelay = .milliseconds(1)
        await window.refreshContext()
        await window.rebuildQuickTasks()
        await window.dispatchFromSurface("browser_open", .object(["url": .string("https://docs.example.com/std")]))
        await window.refreshLayout()
        let pane = try #require(window.layoutSnapshot.panes.first { $0.kind == "browser" }?.id)
        await window.dispatchFromSurface("browser_new_tab", .object(["pane": .string(pane),
                                                                     "url": .string("https://docs.example.com/book")]))
        await window.refreshPanes()
        return (window, pane, layout, panes)
    }

    /// Tab `tab` of `pane` finishing a load of `url` titled `title`: loading, then done.
    private func load(_ window: WindowModel, _ pane: String, _ tab: String, _ url: String, _ title: String) async throws {
        let scope = try #require(window.browserScope)
        for loading in [true, false] {
            await window.browserPageDidReport(scope: scope, pane: pane, tab: tab, BrowserPageReport(
                url: url, title: title, isLoading: loading, progress: loading ? 0.5 : 1, canGoBack: false,
                canGoForward: false, failure: nil))
        }
    }

    /// Both tabs loaded with titles: the site rule forms their group, which is then due a name.
    private func formGroup(_ window: WindowModel, _ pane: String) async throws -> String {
        try await load(window, pane, "t1", "https://docs.example.com/std", "Rust std library")
        try await load(window, pane, "t2", "https://docs.example.com/book", "The Rust Book")
        return try #require(window.browser(pane)?.groups.first?.id)
    }

    @Test func aReportThatRegroupsTabsIsSaved() async throws {
        let (window, pane, layout, _) = try await twoTabsOneSite(NamingModel(reply: #"{"name":"x"}"#))
        window.browserSettings.nameGroups = false
        let scope = try #require(window.browserScope)
        for tab in ["t1", "t2"] {   // titles and addresses first, so only the grouping changes below
            await window.browserPageDidReport(scope: scope, pane: pane, tab: tab, BrowserPageReport(
                url: "https://docs.example.com/\(tab)", title: tab, isLoading: true, progress: 0.5,
                canGoBack: false, canGoForward: false, failure: nil))
        }
        await window.settleBrowserTabsWrite(pane: pane)
        #expect(await layout.browserTabs(id: pane)?.groups.isEmpty == true)
        await window.browserPageDidReport(scope: scope, pane: pane, tab: "t1", BrowserPageReport(
            url: "https://docs.example.com/t1", title: "t1", isLoading: false, progress: 1,
            canGoBack: false, canGoForward: false, failure: nil))
        #expect(window.browser(pane)?.groups.count == 1, "the site rule formed the group")
        await window.settleBrowserTabsWrite(pane: pane)
        #expect(await layout.browserTabs(id: pane)?.groups.count == 1, "and the layout saved it")
    }

    @Test func aFormedGroupIsNamedByTheQuickTask() async throws {
        let model = NamingModel(reply: #"{"name":"Rust docs"}"#)
        let (window, pane, layout, _) = try await twoTabsOneSite(model)
        let group = try await formGroup(window, pane)
        await window.settleBrowserNaming()
        let named = try #require(window.browser(pane)?.groups.first { $0.id == group })
        #expect(named.name == "Rust docs")
        #expect(named.named)
        let input = try #require(await model.inputs.first)
        #expect(input.contains("Rust std library") && input.contains("The Rust Book"))
        #expect(!input.contains("example.com") && !input.contains("https"), "titles only, never addresses")
        await window.settleBrowserTabsWrite(pane: pane)
        #expect(await layout.browserTabs(id: pane)?.groups.first?.name == "Rust docs", "and saved")
    }

    @Test func namingIsAskedOncePerGroup() async throws {
        let model = NamingModel(reply: "no name here")   // stays unnamed, so still due
        let (window, pane, _, _) = try await twoTabsOneSite(model)
        _ = try await formGroup(window, pane)
        await window.settleBrowserNaming()
        try await load(window, pane, "t1", "https://docs.example.com/std", "Rust std library, again")
        try await load(window, pane, "t2", "https://docs.example.com/book", "The Rust Book, again")
        await window.settleBrowserNaming()
        #expect(await model.inputs.count == 1)
    }

    @Test func namingOffKeepsTheSiteName() async throws {
        let model = NamingModel(reply: #"{"name":"Rust docs"}"#)
        let (window, pane, _, _) = try await twoTabsOneSite(model)
        window.browserSettings.nameGroups = false
        let group = try await formGroup(window, pane)
        await window.settleBrowserNaming()
        #expect(await model.inputs.isEmpty)
        let kept = try #require(window.browser(pane)?.groups.first { $0.id == group })
        #expect(kept.name == "Example" && !kept.named)
    }

    @Test func aReplyThatDoesNotParseReachesTheStatus() async throws {
        let (window, pane, _, _) = try await twoTabsOneSite(NamingModel(reply: "I think: Rust"))
        let group = try await formGroup(window, pane)
        await window.settleBrowserNaming()
        let errors = await window.quickTaskStatus().errors
        #expect(errors.values.contains("the model's reply was not a group name: I think: Rust"))
        #expect(window.browser(pane)?.groups.first { $0.id == group }?.named == false)
    }

    @Test func aLateNameNeverOverwritesTheOperatorsName() async throws {
        let model = NamingModel(reply: #"{"name":"Rust docs"}"#, gated: true)
        let (window, pane, _, _) = try await twoTabsOneSite(model)
        let group = try await formGroup(window, pane)
        await model.waitUntilAsked()
        await window.dispatchFromSurface("browser_group", .object([
            "pane": .string(pane), "action": .string("rename"), "group": .string(group), "name": .string("Mine")]))
        await model.release()
        await window.settleBrowserNaming()
        await window.refreshPanes()
        #expect(window.browser(pane)?.groups.first { $0.id == group }?.name == "Mine")
    }

    @Test func aNameForADissolvedGroupIsDropped() async throws {
        let model = NamingModel(reply: #"{"name":"Rust docs"}"#, gated: true)
        let (window, pane, _, _) = try await twoTabsOneSite(model)
        _ = try await formGroup(window, pane)
        await model.waitUntilAsked()
        await window.dispatchFromSurface("browser_close_tab", .object(["pane": .string(pane), "tab": .string("t2")]))
        await window.refreshPanes()
        #expect(window.browser(pane)?.groups.isEmpty == true, "an automatic group dissolves at one")
        await model.release()
        await window.settleBrowserNaming()
        await window.refreshPanes()
        #expect(window.browser(pane)?.groups.isEmpty == true)
        #expect(window.browser(pane)?.tabs.map(\.group) == [nil])
    }

    @Test func aNameAfterASwitchIsDropped() async throws {
        let model = NamingModel(reply: #"{"name":"Rust docs"}"#, gated: true)
        let context = NamingContext()
        let (window, pane, layout, _) = try await twoTabsOneSite(model, context: context)
        let group = try await formGroup(window, pane)
        await model.waitUntilAsked()
        // Project beta holds a pane of the same id with the same unnamed group, restored as a relaunch would.
        await window.settleBrowserTabsWrite(pane: pane)
        await window.refreshLayout()
        let alphaPane = try #require(window.layoutSnapshot.panes.first { $0.id == pane })
        await layout.load(LayoutSnapshot(panes: [alphaPane]), for: LayoutScope(
            organization: "acme", project: "beta", environment: "staging"))
        await context.switchTo(project: "beta")
        await window.refreshContext()
        #expect(window.browserScope?.project == "beta")
        await window.dispatchFromSurface("browser_restore", .object(["pane": .string(pane)]))
        await window.refreshPanes()
        #expect(window.browser(pane)?.groups.first { $0.id == group }?.named == false)
        await model.release()
        await window.settleBrowserNaming()
        await window.refreshPanes()
        let beta = try #require(window.browser(pane)?.groups.first { $0.id == group })
        #expect(beta.name == "Example" && !beta.named, "another place's reply never lands in this one's group")
        await context.switchTo(project: "alpha")
        await window.refreshContext()
        let kept = try #require(window.browser(pane)?.groups.first { $0.id == group })
        #expect(kept.name == "Example" && !kept.named, "the reply landed while another place was shown")
    }

    // MARK: Pins of the place shown

    /// A window with a home in project `alpha` of `acme`, its actions reading the same organisation's files.
    private func pinnedWindow(_ context: NamingContext) async throws -> (WindowModel, LayoutStore, BrowserOrgFiles) {
        let home = testScratchRoot.appendingPathComponent(UUID().uuidString)
        let files = try BrowserOrgFiles(home: home, org: "acme")
        let (window, _, layout, _, _) = await browserWindow(orgFiles: files, context: context)
        window.browserHome = home
        await window.refreshContext()
        return (window, layout, files)
    }

    private func pin(_ id: String, _ url: String) -> BrowserPin { BrowserPin(id: id, kind: .tab, url: url, title: id) }

    private func pinIds(_ window: WindowModel, _ pane: String) -> Set<String> {
        Set(window.browser(pane)?.tabs.compactMap(\.pin) ?? [])
    }

    private func show(_ window: WindowModel, _ context: NamingContext, _ project: String) async {
        await context.switchTo(project: project)
        await window.refreshContext()
    }

    @Test func pinsAreReadForThePlaceShownOnly() async throws {
        let context = NamingContext()
        let (window, layout, files) = try await pinnedWindow(context)
        try files.setPins([pin("pa1", "https://a.example.com/")], project: "alpha")
        try files.setPins([pin("pb1", "https://b.example.com/")], project: "beta")
        await window.dispatchFromSurface("browser_open", .object(["url": .string("https://example.com/")]))
        await window.refreshLayout()
        let pane = try #require(window.layoutSnapshot.panes.first { $0.kind == "browser" }?.id)
        #expect(pinIds(window, pane) == ["pa1"])
        // Project beta holds a browser pane of the same id, restored as a relaunch restores it.
        let alphaPane = try #require(window.layoutSnapshot.panes.first { $0.id == pane })
        let beta = LayoutScope(organization: "acme", project: "beta", environment: "staging")
        await layout.load(LayoutSnapshot(panes: [alphaPane]), for: beta)
        await show(window, context, "beta")
        #expect(window.browserScope == beta)
        await window.dispatchFromSurface("browser_restore", .object(["pane": .string(pane)]))
        await window.refreshPanes()
        #expect(pinIds(window, pane) == ["pb1"])
        // Both projects pin more while away; each canvas shown takes its own file's only.
        try files.setPins([pin("pa1", "https://a.example.com/"), pin("pa2", "https://a2.example.com/")],
                          project: "alpha")
        try files.setPins([pin("pb1", "https://b.example.com/"), pin("pb2", "https://b2.example.com/")],
                          project: "beta")
        await show(window, context, "alpha")
        #expect(pinIds(window, pane) == ["pa1", "pa2"])
        await show(window, context, "beta")
        #expect(pinIds(window, pane) == ["pb1", "pb2"])
    }

    @Test func showingACanvasReconcilesItsPins() async throws {
        let context = NamingContext()
        let (window, layout, files) = try await pinnedWindow(context)
        try files.setPins([pin("pa1", "https://a.example.com/")], project: "alpha")
        await window.dispatchFromSurface("browser_open", .object(["url": .string("https://example.com/")]))
        await window.refreshLayout()
        let pane = try #require(window.layoutSnapshot.panes.first { $0.kind == "browser" }?.id)
        #expect(pinIds(window, pane) == ["pa1"])
        await show(window, context, "beta")
        try files.setPins([pin("pa2", "https://a2.example.com/")], project: "alpha")
        await show(window, context, "alpha")
        #expect(pinIds(window, pane) == ["pa2"], "the pin added came in, the one removed went")
        #expect(await layout.browserTabs(id: pane)?.tabs.compactMap(\.pin) == ["pa2"], "and the layout saved it")
        // An unreadable file removes nothing, and says why on the pane.
        await show(window, context, "beta")
        try Data("{".utf8).write(to: files.pinsURL(project: "alpha"))
        await show(window, context, "alpha")
        #expect(pinIds(window, pane) == ["pa2"])
        #expect(window.browser(pane)?.pinsError != nil)
    }

    @Test func aCanvasShownWithNoTabLeftClosesThePane() async throws {
        let context = NamingContext()
        let (window, _, files) = try await pinnedWindow(context)
        try files.setPins([pin("pa1", "https://a.example.com/")], project: "alpha")
        await window.dispatchFromSurface("browser_open", .object(["url": .string("https://example.com/")]))
        await window.refreshLayout()
        let pane = try #require(window.layoutSnapshot.panes.first { $0.kind == "browser" }?.id)
        let unpinned = try #require(window.browser(pane)?.tabs.first { $0.pin == nil }?.id)
        await window.dispatchFromSurface("browser_close_tab", .object(["pane": .string(pane), "tab": .string(unpinned)]))
        await window.refreshPanes()
        #expect(pinIds(window, pane) == ["pa1"] && window.browser(pane)?.tabs.count == 1)
        await show(window, context, "beta")
        try files.setPins([], project: "alpha")
        await show(window, context, "alpha")
        #expect(!window.layoutSnapshot.panes.contains { $0.id == pane }, "its last tab went, and the pane with it")
    }
}

// MARK: - 3d-i Task 11: the pull-request group's refresh

@Suite @MainActor struct WindowModelBrowserPullRequestsTests {
    /// A window on organisation `acme` reading pull requests from `reader`, its loop's interval
    /// `interval`, and no browser pane yet.
    private func window(_ reader: PullRequestsReader, interval: Duration = .seconds(300)) async -> WindowModel {
        let (window, _, _, _, _) = await browserWindow(context: NamingContext(), pullRequests: reader.read)
        window.browserPullRequestsInterval = interval
        window.browserTabsDelay = .milliseconds(1)
        await window.refreshContext()
        return window
    }

    private func openBrowser(_ window: WindowModel) async throws -> String {
        await window.dispatchFromSurface("browser_open", .object(["url": .string("https://example.com/")]))
        await window.refreshLayout()
        return try #require(window.layoutSnapshot.panes.first { $0.kind == "browser" }?.id)
    }

    /// Waits (up to 5 s) until `reader` has read `count` times.
    private func waitFor(_ reader: PullRequestsReader, reads count: Int) async {
        for _ in 0..<5_000 where reader.reads < count { try? await Task.sleep(nanoseconds: 1_000_000) }
    }

    @Test func theLoopRefreshesWhenTheFirstBrowserPaneOpensAndStopsWithTheLast() async throws {
        let reader = PullRequestsReader([pr(1)])
        let window = await window(reader, interval: .milliseconds(20))
        try await Task.sleep(nanoseconds: 60_000_000)
        #expect(reader.reads == 0, "no browser pane, no read")
        #expect(!window.browserPullRequestsLoopRuns)
        let pane = try await openBrowser(window)
        #expect(window.browserPullRequestsLoopRuns)
        await waitFor(reader, reads: 3)
        #expect(reader.reads >= 3, "a refresh at once, then one each interval")
        await waitFor(reader, reads: 4)
        await window.refreshPanes()
        #expect(window.browser(pane)?.tabs.contains { $0.pullRequest == pr(1).url } == true)
        await window.closePane(id: pane)
        await window.refreshLayout()
        #expect(!window.browserPullRequestsLoopRuns, "it ends with the last browser pane")
        let after = reader.reads
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(reader.reads <= after + 1, "at most the read already under way")
    }

    @Test func cmdRWithTheHeaderFocusedRefreshes() async throws {
        let reader = PullRequestsReader([pr(1)])
        let window = await window(reader)
        let pane = try await openBrowser(window)
        await window.focusPane(id: pane)
        await waitFor(reader, reads: 1)
        for _ in 0..<5_000 where window.browser(pane)?.group("pr") == nil {
            try await Task.sleep(nanoseconds: 1_000_000)
            await window.refreshPanes()
        }
        #expect(reader.reads == 1)
        // ⌘R with the keyboard on the page reloads it, and reads nothing.
        #expect(await window.browserKey(.reload))
        #expect(reader.reads == 1)
        window.browserHeaderFocus = BrowserHeaderFocus(pane: pane, group: "pr")
        let seq = window.browser(pane)?.activeTab?.command?.seq
        #expect(await window.browserKey(.reload))
        #expect(reader.reads == 2, "the header's ⌘R refreshes the list")
        #expect(window.browser(pane)?.activeTab?.command?.seq == seq, "and reloads no page")
    }

    @Test func anOrganisationChangeEndsTheLoopUntilTheSwitchIsOver() async throws {
        let reader = PullRequestsReader([pr(1)])
        let window = await window(reader, interval: .milliseconds(20))
        _ = try await openBrowser(window)
        await waitFor(reader, reads: 2)
        await window.invalidateForOrgChange()
        #expect(!window.browserPullRequestsLoopRuns)
        await window.refreshLayout()
        #expect(!window.browserPullRequestsLoopRuns, "held while the switch runs, though the canvas still shows the pane")
    }

    @Test func anOrganisationSwitchStopsTheLoop() async throws {
        let reader = PullRequestsReader([pr(1)])
        let context = NamingContext()
        let (window, _, _, _, panes) = await browserWindow(context: context, pullRequests: reader.read)
        window.browserPullRequestsInterval = .milliseconds(20)
        window.browserTabsDelay = .milliseconds(1)
        await window.refreshContext()
        let pane = try await openBrowser(window)
        await waitFor(reader, reads: 2)
        window.browserHeaderFocus = BrowserHeaderFocus(pane: pane, group: "pr")
        // A read under way when the switch begins: it answers the incoming organisation's list.
        reader.hold()
        let held = reader.reads
        await waitFor(reader, reads: held + 1)
        await context.switchTo(org: "globex")
        await window.setOrganization("globex")
        #expect(window.organization == "globex")
        #expect(!window.browserPullRequestsLoopRuns, "globex's canvas shows no browser pane")
        #expect(window.browserHeaderFocus == nil && window.browserPullRequestsAbsent == nil)
        reader.answer([pr(7)])
        reader.release()
        let after = reader.reads
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(reader.reads == after, "no read after the switch")
        #expect(await panes.browserPullRequests(org: "globex") == nil, "the late answer is filed under no one")
        #expect(await panes.browserPullRequests(org: "acme")?.items.map(\.number) == [1], "nor over acme's")
        // Back on acme, whose canvas shows the browser pane: once the switch is over, the loop runs again.
        await context.switchTo(org: "acme")
        await window.setOrganization("acme")
        #expect(window.layoutSnapshot.panes.contains { $0.id == pane })
        #expect(window.browserPullRequestsLoopRuns)
        await waitFor(reader, reads: after + 1)
        #expect(reader.reads > after)
    }

    /// Task 12: the strip's pull-request header reads the window's copy of the list — refreshing
    /// while a refresh runs (Rule 5), and a failure whole (Rule 8).
    @Test func theHeaderReadsTheRefreshAndItsFailureWhole() async throws {
        let reader = PullRequestsReader([pr(1)])
        let window = await window(reader)
        let pane = try await openBrowser(window)
        await waitFor(reader, reads: 1)
        for _ in 0..<5_000 where window.browser(pane)?.group("pr") == nil
            || window.browserPullRequestsOnScreen?.refreshing != false {
            try await Task.sleep(nanoseconds: 1_000_000)
            await window.refreshPanes()
        }
        #expect(window.browserPullRequestsOnScreen?.refreshing == false)
        let why = "github.com refused the pull-request search (HTTP 502): Bad gateway — try again in a minute."
        reader.fail(StandardActionError.serverError(action: "ctx_github_pull_requests", message: why))
        reader.hold()
        let refresh = Task { await window.refreshBrowserPullRequests() }
        await waitFor(reader, reads: 2)
        #expect(window.browserPullRequestsOnScreen?.refreshing == true, "the header shows the refresh while it runs")
        reader.release()
        await refresh.value
        #expect(window.browserPullRequestsOnScreen?.refreshing == false)
        #expect(window.browserPullRequestsOnScreen?.error == why, "the failure whole")
        await window.invalidateForOrgChange()
        #expect(window.browserPullRequestsOnScreen == nil, "another organisation's list is not drawn")
    }

    @Test func theFirstRefreshShowsItsRefreshBeforeAnyListWasRead() async throws {
        let reader = PullRequestsReader([pr(1)], gated: true)
        let window = await window(reader)
        #expect(window.browserPullRequestsOnScreen == nil, "nothing read yet")
        _ = try await openBrowser(window)
        await waitFor(reader, reads: 1)
        #expect(window.browserPullRequestsOnScreen?.refreshing == true, "the first refresh shows its refresh too")
        await window.refreshPanes()
        #expect(window.browserPullRequestsOnScreen?.refreshing == true, "a re-read while it runs keeps it")
        reader.release()
        for _ in 0..<5_000 where window.browserPullRequestsOnScreen?.refreshing != false {
            try await Task.sleep(nanoseconds: 1_000_000)
            await window.refreshPanes()
        }
        #expect(window.browserPullRequestsOnScreen?.refreshing == false)
        #expect(window.browserPullRequestsOnScreen?.items.count == 1)
    }

    @Test func settingsReadsWhyThereIsNoGroup() async throws {
        let reader = PullRequestsReader()
        let why = "No pull-request group: acme has no GitHub account."
        reader.answer(absent: why)
        let window = await window(reader)
        _ = try await openBrowser(window)
        for _ in 0..<5_000 where window.browserPullRequestsAbsent == nil { try await Task.sleep(nanoseconds: 1_000_000) }
        #expect(window.browserPullRequestsAbsent == why)
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
