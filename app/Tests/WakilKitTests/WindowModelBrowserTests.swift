import Foundation
import Testing
@testable import WakilKit

/// A window over the layout, editor and browser actions (`editorWindowFull`'s shape, plus the
/// browser's), its start page blank. `journal` is its registry's journal file.
@MainActor
private func browserWindow() async -> (WindowModel, FakeFiles, LayoutStore, journal: URL) {
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
    await registerBrowserActions(into: registry, panes: panes, layout: layout, settings: { .defaults })
    return (model, files, layout, journalDir.appendingPathComponent("browser-window.jsonl"))
}

@Suite @MainActor struct WindowModelBrowserTests {
    /// A focused browser pane holding one tab on `https://a.test/`.
    private func focusedBrowser() async throws -> (WindowModel, String, LayoutStore, URL) {
        let (model, _, layout, journal) = await browserWindow()
        await model.refreshContext()
        await model.dispatchFromSurface("browser_open", .object(["url": .string("https://a.test/")]))
        await model.refreshLayout()
        let pane = try #require(model.layoutSnapshot.panes.first { $0.kind == "browser" }?.id)
        await model.focusPane(id: pane)
        return (model, pane, layout, journal)
    }

    @Test func theWindowHandsOutTheActiveOrganisationsFilesOnly() async throws {
        let (model, _, _, _) = await browserWindow()
        let home = testScratchRoot.appendingPathComponent(UUID().uuidString)
        model.browserHome = home
        await model.refreshContext()
        // Before an organisation is active there is nothing to hand out.
        let files = try #require(model.browserOrgFiles)
        #expect(!model.organization.isEmpty)
        #expect(files.org == model.organization)
        #expect(files.directory.path == home.path + "/.wakil/orgs/\(model.organization)/browser")
        model.browserHome = nil
        #expect(model.browserOrgFiles == nil, "no home, no files")
    }

    @Test func noOrganisationYetMeansNoFiles() async {
        let (model, _, _, _) = await browserWindow()
        model.browserHome = testScratchRoot
        #expect(model.organization.isEmpty)
        #expect(model.browserOrgFiles == nil)
    }

    @Test func keysOutsideABrowserKeepTodaysMeaning() async throws {
        let (model, files, _, _) = await browserWindow()
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
        await model.browserPageDidReport(pane: pane, tab: tab, BrowserPageReport(
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
        await model.browserFindDidReport(pane: pane, current: 2, total: 5)
        #expect(model.browser(pane)?.find?.total == 5)
        await model.browserDownloadDidChange(pane: pane, BrowserDownload(
            id: "d1", filename: "f", received: 0, expected: 1, state: .running))
        #expect(model.browser(pane)?.downloads.count == 1)
        let opener = try #require(model.browser(pane)?.active)
        let id = await model.browserPageOpenedTab(pane: pane, opener: opener, url: "https://p.test/")
        #expect(id != nil && model.browser(pane)?.active == id)
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
