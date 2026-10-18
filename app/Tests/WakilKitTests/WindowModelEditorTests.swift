import Foundation
import Testing
@testable import WakilKit

struct EditorWindowLookup: ProviderCredentialsLookup {
    func credentials(forProvider id: String) async throws -> ProviderCredentials {
        ProviderCredentials(claudePath: "/usr/bin/true", configDir: "/dev/null", oauthToken: "test-only")
    }
}

/// Everything `editorWindowParts` builds, with the window's git status over a `FakeGit` and a
/// `RecordingRootWatcher` for each of the git and editor watches (3b-iii).
struct EditorWindowParts {
    let model: WindowModel
    let editorWatcher: RecordingRootWatcher
    let gitWatcher: RecordingRootWatcher
    let files: FakeFiles
    let git: FakeGit
}

/// A window with an editor watcher, over `GitRootsContext`'s project and roots, its registry
/// holding the editor actions over one `EditorFileLists` on a `FakeFiles`, shared with the
/// window and the palette as the wiring shares it. Its git status is one `GitStatus` over a
/// `FakeGit`, passed to the window and to the editor actions alike.
@MainActor
func editorWindowFull(
    roots: [String], persistence: LayoutPersistence? = nil, context: GitRootsContext? = nil,
    withGit: Bool = true
) async -> EditorWindowParts {
    let registry = ActionRegistry(
        journalDirectory: testScratchRoot.appendingPathComponent("editor-window-\(UUID().uuidString)"),
        sessionId: "editor-window")
    let panes = PaneStore()
    let layout = LayoutStore()
    let watcher = RecordingRootWatcher()
    let gitWatcher = RecordingRootWatcher()
    let files = FakeFiles()
    let git = FakeGit()
    let fileLists = EditorFileLists(files: files)
    await registerLayoutActions(
        into: registry, layout: layout, panes: panes, unsavedEditorTabs: unsavedEditorTabsProbe(panes: panes))
    let box = RootsBox()
    let status: GitStatus? = withGit ? GitStatus(git: git, roots: { await box.model?.gitRootPaths ?? [] }) : nil
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, persistence: persistence,
        context: ContextStore(client: context ?? GitRootsContext(roots: roots)),
        harnessFactory: { _, _ in nil }, resumes: ResumeBroker(),
        rootPath: "/tmp", providerId: "",
        lookupFactory: { _ in EditorWindowLookup() },
        rootWatcher: withGit ? gitWatcher : nil, editorRootWatcher: watcher, fileLists: fileLists, gitStatus: status,
        paletteClients: PaletteClients(files: fileLists), placeClients: nil)
    box.model = model
    await registerEditorActions(
        into: registry, panes: panes, layout: layout, files: fileLists, fileLists: fileLists,
        gitStatus: status, roots: { [weak model] in await model?.gitRootPaths ?? [] })
    return EditorWindowParts(model: model, editorWatcher: watcher, gitWatcher: gitWatcher, files: files, git: git)
}

@MainActor
func editorWindowParts(
    roots: [String], persistence: LayoutPersistence? = nil, context: GitRootsContext? = nil
) async -> (WindowModel, RecordingRootWatcher, FakeFiles) {
    // No status and no git watcher: tests that do not need git run the window as before 3b-iii, so
    // no extra read or refresh lands inside a debounce window they time.
    let w = await editorWindowFull(roots: roots, persistence: persistence, context: context, withGit: false)
    return (w.model, w.editorWatcher, w.files)
}

@MainActor
func editorWindow(
    roots: [String] = ["/p/api", "/p/portal"]
) async -> (WindowModel, RecordingRootWatcher) {
    let (model, watcher, _) = await editorWindowParts(roots: roots)
    return (model, watcher)
}

@MainActor
func editorWindowWithFiles(
    roots: [String] = ["/p/api", "/p/portal"]
) async -> (WindowModel, FakeFiles) {
    let (model, _, files) = await editorWindowParts(roots: roots)
    return (model, files)
}

@Suite @MainActor struct WindowModelEditorTests {
    // 3b-iv: the tree's name field gets its refusal whole, thrown to it — not on the window's
    // status line — and a success lands as `dispatchFromSurface`'s does.
    @Test func aThrowingSurfaceCallHandsItsRefusalToTheCallerNotTheStatusLine() async throws {
        let (model, files) = await editorWindowWithFiles()
        await model.refreshContext()
        await model.openPane(kind: "editor")
        let pane = try #require(model.layoutSnapshot.panes.first { $0.kind == "editor" }?.id)
        await files.put("/p/api/a.go", "a")
        do {
            try await model.dispatchFromSurfaceThrowing("editor_create", .object([
                "pane": .string(pane), "path": .string("/p/api/a.go"), "kind": .string("file")]))
            Issue.record("created over a file")
        } catch {
            #expect(String(describing: error).contains("/p/api/a.go already exists"))
        }
        #expect(model.status == "", "the refusal is the caller's to show")
        let made = try await model.dispatchFromSurfaceThrowing("editor_create", .object([
            "pane": .string(pane), "path": .string("/p/api/n.go"), "kind": .string("file")]))
        guard case .object(let o) = made else { Issue.record("no reply object"); return }
        #expect(o["made"] == .string("/p/api/n.go"))
        #expect(model.editor(pane)?.tabs.map(\.path) == ["/p/api/n.go"], "the panes are re-read")
    }

    @Test func cmdShiftGTogglesTheChangesViewOnCmdBsTerms() async throws {
        let (model, _, _) = await editorWindowParts(roots: ["/p/api", "/p/portal"])
        await model.refreshContext()
        await model.openPane(kind: "editor")
        await model.toggleEditorColumn(.changes)
        let pane = try #require(model.layoutSnapshot.panes.first { $0.kind == "editor" }?.id)
        #expect(model.editor(pane)?.column?.view == .changes && model.editor(pane)?.column?.shown == true)
        await model.toggleEditorColumn(.files)
        #expect(model.editor(pane)?.column?.view == .files)
        await model.toggleEditorColumn(.changes)
        await model.toggleEditorColumn(.changes)
        #expect(model.editor(pane)?.column?.shown == false)
    }

    @Test(.timeLimit(.minutes(1)))
    func aGitWakeReachesEveryEditorPaneOnceAndTheFileWakeReadsNoGit() async throws {
        let w = await editorWindowFull(roots: ["/p/api", "/p/portal"])
        await w.model.refreshContext()
        await w.model.openPane(kind: "editor")
        await w.model.openPane(kind: "editor")
        let before = await w.git.statusCount
        await w.gitWatcher.fire("/p/api")
        #expect(await w.git.statusCount == before + 1)
        await w.editorWatcher.fire("/p/api", paths: ["/p/api/a.go"])
        #expect(await w.git.statusCount == before + 1, "the file watcher reads no git")
    }

    // The git wake's loop reaches EVERY editor pane: each pane's highlight follows its vanished row.
    @Test(.timeLimit(.minutes(1)))
    func aGitWakeMovesEveryEditorPanesHighlightOffAVanishedRow() async throws {
        let w = await editorWindowFull(roots: ["/p/api", "/p/portal"])
        await w.git.set(status: "/p/api", files: [("a.go", "changed", "M"), ("b.go", "changed", "M"), ("c.go", "changed", "M")])
        await w.model.refreshContext()
        await w.model.openPane(kind: "editor")
        await w.model.openPane(kind: "editor")
        let ids = w.model.layoutSnapshot.panes.filter { $0.kind == "editor" }.map(\.id)
        #expect(ids.count == 2)
        await w.gitWatcher.fire("/p/api")   // the status as it is now
        for id in ids {
            await w.model.dispatchFromSurface("editor_changes_select", .object([
                "pane": .string(id), "root": .string("/p/api"), "path": .string("b.go"), "group": .string("changed")]))
            #expect(w.model.editor(id)?.column?.changesHighlight?.path == "b.go")
        }
        await w.git.set(status: "/p/api", files: [("a.go", "changed", "M"), ("c.go", "changed", "M")])
        await w.gitWatcher.fire("/p/api")
        for id in ids {
            #expect(w.model.editor(id)?.column?.changesHighlight?.path == "c.go", "pane \(id)")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func cmdReturnOnADiffOpensItsFileAndElsewhereMaximizes() async throws {
        let w = await editorWindowFull(roots: ["/p/api", "/p/portal"])
        await w.git.set(status: "/p/api", files: [("a.go", "changed", "M")])
        await w.files.put("/p/api/a.go", "1\n2\n")
        await w.model.refreshContext()
        await w.model.openPane(kind: "editor")
        let pane = try #require(w.model.layoutSnapshot.panes.first { $0.kind == "editor" }?.id)
        await w.gitWatcher.fire("/p/api")
        await w.model.dispatchFromSurface("editor_changes_select", .object([
            "pane": .string(pane), "root": .string("/p/api"), "path": .string("a.go"), "group": .string("changed")]))
        #expect(w.model.editor(pane)?.tabs.first?.subject == .diff(root: "/p/api", path: "a.go", group: .changed))
        await w.model.commandReturn()
        let s = try #require(w.model.editor(pane))
        #expect(s.tabs.count == 2 && s.tabs[s.active!].path == "/p/api/a.go")
        #expect(w.model.layoutSnapshot.maximizedId == nil)
        await w.model.dispatchFromSurface("editor_new_scratch", .object(["pane": .string(pane)]))
        #expect(w.model.editor(pane)?.tabs[w.model.editor(pane)!.active!].isScratch == true)
        await w.model.commandReturn()
        #expect(w.model.layoutSnapshot.maximizedId == pane)
    }

    @Test func cmdBShowsTheFocusedEditorsFilesAndAgainHidesThem() async throws {
        let (model, _, _) = await editorWindowParts(roots: ["/p/api", "/p/portal"])
        await model.refreshContext()
        await model.openPane(kind: "editor")
        let pane = try #require(model.layoutSnapshot.panes.first { $0.kind == "editor" }?.id)
        await model.toggleEditorColumn(.files)
        #expect(model.editor(pane)?.column?.shown == true && model.editor(pane)?.column?.view == .files)
        await model.toggleEditorColumn(.search)
        #expect(model.editor(pane)?.column?.view == .search && model.editor(pane)?.column?.shown == true)
        await model.toggleEditorColumn(.search)
        #expect(model.editor(pane)?.column?.shown == false)
    }

    // Task 8 review I3: only the operator's ⌘B / ⌘⇧F asks for the keyboard in the column — showing it,
    // never hiding it — and an agent's editor_tree never does.
    @Test func onlyTheOperatorsToggleAsksForTheKeyboardInTheColumn() async throws {
        let (model, _, _) = await editorWindowParts(roots: ["/p/api", "/p/portal"])
        await model.refreshContext()
        await model.openPane(kind: "editor")
        let pane = try #require(model.layoutSnapshot.panes.first { $0.kind == "editor" }?.id)
        await model.dispatchFromSurface("editor_tree", .object(["pane": .string(pane), "view": .string("search")]))
        #expect(model.editor(pane)?.column?.shown == true)
        #expect(model.editorColumnFocusRequest == nil, "an action shows the column without taking the keyboard")
        await model.toggleEditorColumn(.files)
        #expect(model.editorColumnFocusRequest?.pane == pane && model.editorColumnFocusRequest?.view == .files)
        model.editorColumnFocusTaken()
        #expect(model.editorColumnFocusRequest == nil)
        await model.toggleEditorColumn(.files)                // hides it: nothing to focus
        #expect(model.editor(pane)?.column?.shown == false && model.editorColumnFocusRequest == nil)
    }

    // Review round 1, I1: with no editor focused, the toggle is computed from the pane editor_tree
    // acts on (the first editor), not from the column last left in some other pane.
    @Test(arguments: [EditorColumnView.files, .search])
    func cmdBWithNoEditorFocusedTogglesTheFirstEditorsOwnColumn(_ view: EditorColumnView) async throws {
        let (model, _, _) = await editorWindowParts(roots: ["/p/api", "/p/portal"])
        await model.refreshContext()
        await model.openPane(kind: "editor")
        let first = try #require(model.layoutSnapshot.focusedId)
        await model.toggleEditorColumn(view)
        await model.toggleEditorColumn(view)                  // the first editor's column: hidden
        #expect(model.editor(first)?.column?.shown == false)
        await model.openPane(kind: "editor")
        let second = try #require(model.layoutSnapshot.focusedId)
        #expect(second != first)
        if model.editor(second)?.column?.shown != true { await model.toggleEditorColumn(view) }
        #expect(model.editor(second)?.column?.shown == true && model.editor(second)?.column?.view == view)
        #expect(model.editorColumnDefault.shown, "the column last left shows")
        await model.openPane(kind: "db")                      // no editor focused
        #expect(model.layoutSnapshot.panes.first { $0.id == model.layoutSnapshot.focusedId }?.kind == "db")
        await model.toggleEditorColumn(view)
        #expect(model.editor(first)?.column?.shown == true && model.editor(first)?.column?.view == view)
        #expect(model.editor(second)?.column?.shown == true)
    }

    @Test func aWatcherWakeInvalidatesTheListBeforeTheTreeReReadsIt() async throws {
        let (model, watcher, files) = await editorWindowParts(roots: ["/p/api", "/p/portal"])
        await model.refreshContext()
        await files.setListing("/p/api", ["a.go"])
        await model.openPane(kind: "editor")             // the watcher starts, and the list is watched
        await model.toggleEditorColumn(.files)
        #expect(model.editorFiles.listings["/p/api"]?.files == ["a.go"])
        await files.setListing("/p/api", ["a.go", "b.go"])
        await watcher.fire("/p/api")
        #expect(model.editorFiles.listings["/p/api"]?.files == ["a.go", "b.go"])
    }

    // An agent session pinned to the place on screen shows the Files column: its roots' listings
    // are what the operator's tree draws, so they land in the window's lists. Left out, the column
    // drew each root as still listing, with no row the operator could open. An agent pinned to a
    // place the screen is not showing still lists into nothing the screen draws.
    @Test func theScreensOwnAgentListsIntoTheTreeTheOperatorSees() async throws {
        let (model, _, files) = await editorWindowParts(roots: ["/p/api", "/p/portal"])
        await model.refreshContext()
        await files.setListing("/p/api", ["a.go"])
        await model.openPane(kind: "editor")
        let pane = try #require(model.layoutSnapshot.focusedId)
        let lists = try #require(model.fileListsForTesting)

        let elsewhere = Place(organization: model.place.organization, project: "other", environment: "qa")
        _ = await ActionRegistry.$dispatchCaller.withValue(DispatchCaller(place: elsewhere, session: "s0")) {
            await lists.listing(root: "/p/api")
        }
        #expect(await lists.state().listings["/p/api"] == nil, "another place's read is not the screen's tree")

        _ = try await model.registryForTesting.dispatch(
            name: "editor_tree",
            params: .object(["pane": .string(pane), "shown": .bool(true), "view": .string("files")]),
            origin: .agent, caller: DispatchCaller(place: model.place, session: "s1"), confirmation: nil)

        #expect(try await drawn { model.editorFiles.listings["/p/api"]?.files == ["a.go"] },
                "the column draws the root as still listing")
    }

    // Final review I1: both projects have an editor pane, so the list stays watched across the
    // switch — but nothing watches p's roots while q is active. Back in p, ⌘P and the tree must
    // not serve the listing from before the switch.
    @Test func aProjectSwitchAndBackNeverServesAListingFromBeforeTheSwitch() async throws {
        let context = GitRootsContext(roots: ["/p/api", "/p/portal"])
        let (model, _, files) = await editorWindowParts(roots: ["/p/api", "/p/portal"], context: context)
        await model.refreshContext()
        await context.switchTo(project: "q", roots: ["/q/web"])
        await model.refreshContext()
        await model.openPane(kind: "editor")                 // q's canvas holds an editor too
        await context.switchTo(project: "p", roots: ["/p/api", "/p/portal"])
        await model.refreshContext()
        await files.setListing("/p/api", ["a.go"])
        await model.openPane(kind: "editor")
        await model.toggleEditorColumn(.files)
        #expect(model.editorFiles.listings["/p/api"]?.files == ["a.go"])
        await context.switchTo(project: "q", roots: ["/q/web"])
        await model.refreshContext()
        await files.setListing("/p/api", ["a.go", "b.go"])   // a checkout in a terminal, say
        await context.switchTo(project: "p", roots: ["/p/api", "/p/portal"])
        await model.refreshContext()
        let lists = try #require(model.fileListsForTesting)
        let palette = try await lists.callTool(
            name: "files_list", arguments: .object(["root": .string("/p/api")]), timeout: 5)
        guard case .object(let o) = palette, case .object(let content)? = o["structuredContent"] else {
            Issue.record("files_list answered \(palette)"); return
        }
        #expect(EditorRootListing(root: "/p/api", content: content).files == ["a.go", "b.go"], "⌘P's read")
        #expect(model.editorFiles.listings["/p/api"]?.files == ["a.go", "b.go"])
    }

    // Final review I4: the editor watcher hands each burst's paths to editor_refresh, so a log
    // written under the root leaves the results as they are, and a result's own file marks them.
    @Test func aWakeMarksSearchResultsChangedOnlyWhenAResultsFileChanged() async throws {
        let (model, watcher, files) = await editorWindowParts(roots: ["/p/api", "/p/portal"])
        await model.refreshContext()
        await model.openPane(kind: "editor")
        let pane = try #require(model.layoutSnapshot.focusedId)
        await files.setSearch([("/p/api", "app/User.php", 1, 1, "x")])
        await model.dispatchFromSurface("editor_search", .object(["pane": .string(pane), "query": .string("x")]))
        await watcher.fire("/p/api", paths: ["/p/api/storage/logs/laravel.log"])
        #expect(model.editor(pane)?.search.changedSince == false, "a log beside the results")
        await watcher.fire("/p/api", paths: ["/p/api/app/User.php"])
        #expect(model.editor(pane)?.search.changedSince == true, "a result's own file")
    }

    /// Waits (bounded) for `condition` on the window — what is drawn, not what the store holds.
    private func drawn(_ condition: @MainActor () -> Bool) async throws -> Bool {
        for _ in 0..<300 {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    // Final review C1: the window redraws an editor pane while a search is in flight, so the tick
    // and Cancel show for the whole search — not only once its dispatch has returned.
    @Test func aSearchInFlightIsDrawnBeforeItsDispatchReturns() async throws {
        let (model, files) = await editorWindowWithFiles()
        await model.refreshContext()
        await model.openPane(kind: "editor")
        let pane = try #require(model.layoutSnapshot.focusedId)
        await files.setSearch([("/p/api", "a.go", 1, 1, "x")])
        await files.setSlowSearch(true)
        let run = Task { await model.dispatchFromSurface("editor_search", .object(["pane": .string(pane), "query": .string("x")])) }
        while await files.calls.filter({ $0.hasPrefix("files_search") }).isEmpty { await Task.yield() }
        #expect(try await drawn { model.editor(pane)?.search.inFlight == true }, "no tick or Cancel while searching")
        #expect(try await drawn { model.editor(pane)?.column?.view == .search })
        await files.releaseSearch()
        await run.value
        #expect(model.editor(pane)?.search.inFlight == false)
        #expect(model.editor(pane)?.search.results.count == 1)
    }

    // Final review C1 (and T5 #8): ⌘B draws the column at once, with each root's "listing" tick,
    // while the roots list — not only once every root has listed.
    @Test func cmdBDrawsTheColumnWhileItsRootsAreStillListing() async throws {
        let (model, files) = await editorWindowWithFiles()
        await model.refreshContext()
        await model.openPane(kind: "editor")
        let pane = try #require(model.layoutSnapshot.focusedId)
        await files.setListing("/p/api", ["a.go"])
        await files.setSlowList(true)
        let toggle = Task { await model.toggleEditorColumn(.files) }
        while await !files.calls.contains("files_list /p/api") { await Task.yield() }
        #expect(try await drawn { model.editor(pane)?.column?.shown == true }, "the column waited for every root")
        #expect(model.editorFiles.listings["/p/api"] == nil, "the root still shows its listing tick")
        await files.releaseList()
        await toggle.value
        #expect(try await drawn { model.editorFiles.listings["/p/api"]?.files == ["a.go"] })
    }

    // Final review C1: a heavy folder that is loading shows open with its tick while it loads, so
    // a second click collapses it (Rule 4) instead of expanding it again.
    @Test func aHeavyFolderLoadingIsDrawnOpenWithItsTick() async throws {
        let (model, files) = await editorWindowWithFiles()
        await model.refreshContext()
        await files.setListing("/p/api", []); await files.setHeavy("/p/api", ["vendor"])
        await files.setDir("/p/api/vendor", [("laravel", true)])
        await model.openPane(kind: "editor")
        await model.toggleEditorColumn(.files)
        let pane = try #require(model.layoutSnapshot.focusedId)
        await files.setSlowDir(true)
        let expand = Task {
            await model.dispatchFromSurface("editor_tree_expand", .object(["pane": .string(pane), "path": .string("/p/api/vendor")]))
        }
        #expect(try await drawn { model.editor(pane)?.column?.open.contains("/p/api/vendor") == true }, "the chevron stayed closed")
        #expect(try await drawn { model.editorFiles.loading.contains("/p/api/vendor") }, "no load tick")
        await files.releaseDir()
        await expand.value
        #expect(try await drawn { model.editorFiles.dirs["/p/api/vendor"]?.map(\.name) == ["laravel"] })
    }

    @Test func anOrgSwitchEmptiesTheTreesAndTheirList() async throws {
        let (model, _, files) = await editorWindowParts(roots: ["/p/api", "/p/portal"])
        await model.refreshContext()
        await files.setListing("/p/api", ["a.go"])
        await model.openPane(kind: "editor")
        await model.toggleEditorColumn(.files)
        #expect(model.editorFiles.listings["/p/api"]?.files == ["a.go"])
        await model.invalidateForOrgChange()
        #expect(model.editorFiles == .empty)
        await model.refreshPanes()
        #expect(model.editorFiles == .empty, "the list itself was emptied, not only the mirror")
    }

    // Controller ruling 1: at relaunch the watcher starts before editor_restore runs, so the
    // restored panes share one listing per root rather than each listing every root.
    @Test func aRelaunchListsEachRootOnceHoweverManyEditorPanesItRestores() async throws {
        let persistence = LayoutPersistence(
            directory: testScratchRoot.appendingPathComponent("editor-relaunch-\(UUID().uuidString)"))
        do {
            let (model, _, _) = await editorWindowParts(roots: ["/p/api", "/p/portal"], persistence: persistence)
            await model.refreshContext()
            for _ in 0..<2 {
                await model.openPane(kind: "editor")
                await model.toggleEditorColumn(.search)
                await model.toggleEditorColumn(.files)
            }
            let editors = model.layoutSnapshot.panes.filter { $0.kind == "editor" }
            #expect(editors.count == 2)
            #expect(editors.allSatisfy { $0.editorColumn?.shown == true && $0.editorColumn?.view == .files })
        }
        let (model, _, files) = await editorWindowParts(roots: ["/p/api", "/p/portal"], persistence: persistence)
        await model.refreshContext()
        #expect(model.layoutSnapshot.panes.filter { $0.kind == "editor" }.count == 2)
        #expect(await files.calls.filter { $0 == "files_list /p/api" }.count == 1)
    }

    // Controller ruling 2: a wake does not wait for an open heavy folder's reload, and the tree
    // draws the reload once it lands.
    @Test func aWakeDoesNotWaitForAHeavyFolderReloadAndTheTreeDrawsItWhenItLands() async throws {
        let (model, watcher, files) = await editorWindowParts(roots: ["/p/api", "/p/portal"])
        await model.refreshContext()
        await files.setListing("/p/api", []); await files.setHeavy("/p/api", ["vendor"])
        await files.setDir("/p/api/vendor", [("laravel", true)])
        await model.openPane(kind: "editor")
        await model.toggleEditorColumn(.files)
        let pane = try #require(model.layoutSnapshot.focusedId)
        await model.dispatchFromSurface(
            "editor_tree_expand", .object(["pane": .string(pane), "path": .string("/p/api/vendor")]))
        #expect(model.editorFiles.dirs["/p/api/vendor"]?.map(\.name) == ["laravel"])
        await files.setDir("/p/api/vendor", [("laravel", true), ("composer.json", false)])
        await files.setSlowDir(true)
        let woke = WakeFlag()
        Task { await watcher.fire("/p/api"); await woke.set() }
        var spins = 0
        while await !woke.isSet, spins < 100_000 { spins += 1; await Task.yield() }
        #expect(await woke.isSet, "the wake returned with the folder's reload still parked")
        #expect(model.editorFiles.dirs["/p/api/vendor"]?.map(\.name) == ["laravel"])
        await files.releaseDir()
        spins = 0
        while model.editorFiles.dirs["/p/api/vendor"]?.count != 2, spins < 100_000 { spins += 1; await Task.yield() }
        #expect(model.editorFiles.dirs["/p/api/vendor"]?.map(\.name) == ["laravel", "composer.json"])
    }

    // 3b-ii final review (controller ruling): a pending ⌘B request for the keyboard never carries
    // into another organisation, whose panes reuse the same ids (Rule 6).
    @Test func anOrgSwitchClearsAPendingColumnFocusRequest() async throws {
        let (model, _) = await editorWindow()
        await model.refreshContext()
        await model.openPane(kind: "editor")
        await model.toggleEditorColumn(.files)
        try #require(model.editorColumnFocusRequest != nil)
        await model.invalidateForOrgChange()
        #expect(model.editorColumnFocusRequest == nil)
    }

    @Test func anOrgSwitchDropsTheEditorsSaveState() async throws {
        let (model, _) = await editorWindow()
        model.editorTabsDelay = .milliseconds(50)
        await model.refreshContext()
        await model.newScratch()
        let pane = try #require(model.layoutSnapshot.focusedId)
        await model.saveFocusedEditor()
        #expect(model.editorSaveAsRequest == pane)
        await model.editorViewDidReport(pane: pane, tab: 0, cursor: EditorPosition(line: 1, column: 1),
                                        selection: nil, visibleRange: nil, scrollTop: 0)
        await model.invalidateForOrgChange()
        #expect(model.editorSaveAsRequest == nil)
        try await Task.sleep(for: .milliseconds(150))
        #expect(model.editorTabsWriteCount == 0)
    }

    @Test func anOrgSwitchStopsTheEditorWatcher() async throws {
        let (model, watcher) = await editorWindow()
        await model.refreshContext()
        await model.openPane(kind: "editor")
        #expect(await watcher.events.last?.hasPrefix("watch") == true)
        await model.invalidateForOrgChange()
        #expect(await watcher.events.last == "stop")
    }

    @Test func theEditorWatcherStartsWithAnEditorPaneAndStopsWithTheLast() async throws {
        let (model, watcher) = await editorWindow()
        await model.refreshContext()
        #expect(await watcher.events.isEmpty)
        await model.openPane(kind: "editor")
        #expect(await watcher.events == ["watch /p/api,/p/portal 0.3 seconds"])
        let id = try #require(model.layoutSnapshot.panes.first { $0.kind == "editor" }?.id)
        await model.closePane(id: id)
        #expect(await watcher.events.last == "stop")
    }

    @Test func commandTOpensAScratchTabInTheFocusedEditorOrANewEditorPane() async throws {
        let (model, _) = await editorWindow()
        await model.refreshContext()
        await model.newScratch()
        let pane = try #require(model.layoutSnapshot.panes.first { $0.kind == "editor" })
        #expect(model.editor(pane.id)?.tabs.map(\.subject) == [.scratch(number: 1)])
        #expect(model.layoutSnapshot.focusedId == pane.id)
        await model.newScratch()
        #expect(model.layoutSnapshot.panes.filter { $0.kind == "editor" }.count == 1)
        #expect(model.editor(pane.id)?.tabs.count == 2)
    }

    @Test func commandSOnAScratchTabAsksForAPathInsteadOfSaving() async throws {
        let (model, _) = await editorWindow()
        await model.refreshContext()
        await model.newScratch()
        await model.saveFocusedEditor()
        #expect(model.editorSaveAsRequest == model.layoutSnapshot.focusedId)
        model.cancelSaveAs()
        #expect(model.editorSaveAsRequest == nil)
    }

    @Test func savingAScratchAsAPathMakesItThatFileAndClosesTheField() async throws {
        let (model, files) = await editorWindowWithFiles()
        await model.refreshContext()
        await model.newScratch()
        let pane = try #require(model.layoutSnapshot.focusedId)
        await model.editorBufferDidChange(pane: pane, tab: 0, text: "select 1", basis: 0)
        await model.saveFocusedEditor()
        #expect(await model.saveScratch(pane: pane, as: "/p/api/q.sql") == .saved)
        #expect(model.editorSaveAsRequest == nil)
        #expect(await files.text(of: "/p/api/q.sql") == "select 1")
        #expect(model.editor(pane)?.tabs.first?.path == "/p/api/q.sql")
    }

    @Test func savingAScratchOutsideTheRootsAnswersTheRefusalWholeAndKeepsTheField() async throws {
        let (model, _) = await editorWindowWithFiles()
        await model.refreshContext()
        await model.newScratch()
        let pane = try #require(model.layoutSnapshot.focusedId)
        await model.saveFocusedEditor()
        guard case .failed(let failure) = await model.saveScratch(pane: pane, as: "/etc/q.sql") else {
            Issue.record("a save outside the roots did not fail")
            return
        }
        #expect(failure.contains("outside the active project's roots"))
        #expect(model.editorSaveAsRequest == pane)
    }

    @Test func commandWClosesTheActiveTabThenThePane() async throws {
        let (model, _) = await editorWindow()
        await model.refreshContext()
        await model.newScratch()
        await model.closeFocusedTabOrPane()
        let pane = try #require(model.layoutSnapshot.panes.first { $0.kind == "editor" })
        #expect(model.editor(pane.id)?.tabs.isEmpty == true)
        await model.closeFocusedTabOrPane()
        #expect(!model.layoutSnapshot.panes.contains { $0.kind == "editor" })
    }

    @Test func cancellingASaveInFlightLeavesTheTabDirty() async throws {
        let (model, files) = await editorWindowWithFiles()
        await model.refreshContext()
        await files.put("/p/api/a.go", "a")
        await model.dispatchFromSurface("editor_open", .object(["path": .string("/p/api/a.go")]))
        await model.refreshLayout()
        let pane = try #require(model.layoutSnapshot.panes.first { $0.kind == "editor" }?.id)
        await model.focusPane(id: pane)
        await model.editorBufferDidChange(pane: pane, tab: 0, text: "b", basis: 0)
        await files.setSlowWrite(true)
        let save = Task { await model.saveFocusedEditor() }
        while true {
            await model.refreshPanes()
            if model.editor(pane)?.tabs.first?.saving == true { break }
            await Task.yield()
        }
        model.cancelSave(pane: pane)
        await files.releaseWrite()
        await save.value
        await model.refreshPanes()
        let t = try #require(model.editor(pane)?.tabs.first)
        #expect(t.dirty && !t.saving)
        #expect(await files.text(of: "/p/api/a.go") == "a")
    }

    @Test func commandWOnANonEditorPaneClosesThePaneAsBefore() async throws {
        let (model, _) = await editorWindow()
        await model.refreshContext()
        await model.openPane(kind: "api")
        await model.closeFocusedTabOrPane()
        #expect(model.layoutSnapshot.panes.isEmpty)
    }

    @Test func aBurstOfViewReportsUpdatesTheStoreEachTimeAndWritesTheSavedTabsOnceAfter() async throws {
        let (model, files) = await editorWindowWithFiles()
        model.editorTabsDelay = .milliseconds(50)
        await model.refreshContext()
        await files.put("/p/api/a.go", "one\ntwo\nthree")
        await model.dispatchFromSurface("editor_open", .object(["path": .string("/p/api/a.go")]))
        await model.refreshLayout()
        let pane = try #require(model.layoutSnapshot.panes.first { $0.kind == "editor" }?.id)
        await model.editorBufferDidChange(pane: pane, tab: 0, text: "one\ntwo\nthree!", basis: 0)
        #expect(model.editor(pane)?.tabs.first?.text == "one\ntwo\nthree!")
        let writesBefore = model.editorTabsWriteCount
        for line in 1...3 {
            await model.editorViewDidReport(pane: pane, tab: 0, cursor: EditorPosition(line: line, column: 2),
                                            selection: nil, visibleRange: 1...3, scrollTop: Double(line))
            #expect(model.editor(pane)?.tabs.first?.cursor == EditorPosition(line: line, column: 2))
        }
        // Not written yet: the report does not wait on the layout.
        #expect(model.layoutSnapshot.panes.first { $0.id == pane }?.editorTabs?.first?.cursor
                != EditorPosition(line: 3, column: 2))
        await model.settleEditorTabsWrite(pane: pane)
        #expect(model.editorTabsWriteCount == writesBefore + 1)
        #expect(model.layoutSnapshot.panes.first { $0.id == pane }?.editorTabs
                == [EditorSavedTab(path: "/p/api/a.go", cursor: EditorPosition(line: 3, column: 2), scrollTop: 3)])
    }

    @Test func aSecondCommandSDuringASaveKeepsTheFirstSavesCancel() async throws {
        let (model, files) = await editorWindowWithFiles()
        await model.refreshContext()
        await files.put("/p/api/a.go", "a")
        await model.dispatchFromSurface("editor_open", .object(["path": .string("/p/api/a.go")]))
        await model.refreshLayout()
        let pane = try #require(model.layoutSnapshot.panes.first { $0.kind == "editor" }?.id)
        await model.focusPane(id: pane)
        await model.editorBufferDidChange(pane: pane, tab: 0, text: "b", basis: 0)
        await files.setSlowWrite(true)
        let first = Task { await model.saveFocusedEditor() }
        while true {
            await model.refreshPanes()
            if model.editor(pane)?.tabs.first?.saving == true { break }
            await Task.yield()
        }
        await model.saveFocusedEditor()   // returns at once: one save per pane
        model.cancelSave(pane: pane)
        await files.releaseWrite()
        await first.value
        await model.refreshPanes()
        let t = try #require(model.editor(pane)?.tabs.first)
        #expect(t.dirty && !t.saving)
        #expect(await files.text(of: "/p/api/a.go") == "a")
        #expect(model.status.isEmpty)
    }

    @Test func theDiskTextIsReadWithoutChangingTheTab() async throws {
        let (model, files) = await editorWindowWithFiles()
        await model.refreshContext()
        await files.put("/p/api/a.go", "a")
        await model.dispatchFromSurface("editor_open", .object(["path": .string("/p/api/a.go")]))
        await model.refreshLayout()
        let pane = try #require(model.layoutSnapshot.panes.first { $0.kind == "editor" }?.id)
        let before = model.editor(pane)
        await files.put("/p/api/a.go", "disk")
        #expect(await model.editorDiskText(pane: pane, path: "/p/api/a.go") == "disk")
        #expect(await model.editorDiskText(pane: pane, path: "/etc/passwd") == nil)
        await model.refreshPanes()
        #expect(model.editor(pane) == before)
    }

    /// Opens a.go, sets the autosave mode and delay, and types "b". The delay is set BEFORE the
    /// edit, because the edit arms the timer with whatever delay is in force then.
    private func openTyped(_ model: WindowModel, _ files: FakeFiles, mode: EditorAutosaveMode,
                           delay: Duration = .milliseconds(30)) async throws -> String {
        model.editorAutosaveDelay = delay
        model.editorSettings = EditorSettings(
            app: SettingsEditor(fontSize: 12, wordWrap: false, autosave: mode), project: .defaults, appError: nil)
        await model.refreshContext()
        await files.put("/p/api/a.go", "a")
        await model.dispatchFromSurface("editor_open", .object(["path": .string("/p/api/a.go")]))
        await model.refreshLayout()
        let pane = try #require(model.layoutSnapshot.panes.first { $0.kind == "editor" }?.id)
        _ = await model.focusPane(id: pane)
        await model.editorBufferDidChange(pane: pane, tab: 0, text: "b", basis: 0)
        return pane
    }

    /// Polls until the pane's first tab is saving; records an issue and answers false after 5 s.
    private func waitUntilSaving(_ model: WindowModel, _ pane: String) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            await model.refreshPanes()
            if model.editor(pane)?.tabs.first?.saving == true { return true }
            await Task.yield()
        }
        Issue.record("the tab never reached saving")
        return false
    }

    @Test func afterAPauseTheEditIsWrittenToDisk() async throws {
        let (model, files) = await editorWindowWithFiles()
        let pane = try await openTyped(model, files, mode: .pause)
        await model.settleEditorAutosave()
        #expect(await files.text(of: "/p/api/a.go") == "b")
        #expect(model.editor(pane)?.tabs.first?.dirty == false)
    }

    @Test func withAutosaveOffNothingIsWritten() async throws {
        let (model, files) = await editorWindowWithFiles()
        _ = try await openTyped(model, files, mode: .off)
        try await Task.sleep(for: .milliseconds(120))
        await model.settleEditorAutosave()
        #expect(await files.text(of: "/p/api/a.go") == "a")
        #expect(model.editorAutosaveCount == 0)
    }

    @Test func typingAgainRestartsThePause() async throws {
        let (model, files) = await editorWindowWithFiles()
        let pane = try await openTyped(model, files, mode: .pause, delay: .seconds(1))
        try await Task.sleep(for: .milliseconds(400))
        await model.editorBufferDidChange(pane: pane, tab: 0, text: "bc", basis: 0)
        try await Task.sleep(for: .milliseconds(400))
        // 800 ms after the first edit, 400 after the second: not yet.
        #expect(await files.text(of: "/p/api/a.go") == "a")
        await model.settleEditorAutosave()
        #expect(await files.text(of: "/p/api/a.go") == "bc")
        #expect(model.editorAutosaveCount == 1)
    }

    // Review Focus 3.
    @Test func aTabClosedBeforeThePauseEndsIsNotWritten() async throws {
        let (model, files) = await editorWindowWithFiles()
        let pane = try await openTyped(model, files, mode: .pause, delay: .seconds(1))
        await model.dispatchFromSurface("editor_close", .object(["pane": .string(pane), "discard": .bool(true)]))
        await model.settleEditorAutosave()
        #expect(await files.text(of: "/p/api/a.go") == "a")
        #expect(model.status.isEmpty)
    }

    // Review Focus 4.
    @Test func autosaveDoesNotFireWhileASaveIsInFlight() async throws {
        let (model, files) = await editorWindowWithFiles()
        let pane = try await openTyped(model, files, mode: .pause, delay: .seconds(1))
        await files.setSlowWrite(true)
        let save = Task { await model.saveFocusedEditor() }
        guard await waitUntilSaving(model, pane) else { await files.releaseWrite(); await save.value; return }
        // The timer fires during the save and waits for it rather than dispatching a second one.
        try await Task.sleep(for: .milliseconds(1300))
        #expect(model.editorAutosaveCount == 0)
        await files.releaseWrite()
        await save.value
        await model.settleEditorAutosave()
        // ⌘S wrote the edit, so the waiting timer found nothing left to save.
        #expect(model.editorAutosaveCount == 0)
        #expect(await files.text(of: "/p/api/a.go") == "b")
    }

    @Test func aTabChangedOnDiskIsNotAutosaved() async throws {
        let (model, files) = await editorWindowWithFiles()
        let pane = try await openTyped(model, files, mode: .pause, delay: .seconds(1))
        // Another writer changes the file; the refresh marks the dirty tab changed on disk (3b-i).
        await files.put("/p/api/a.go", "z")
        await model.dispatchFromSurface("editor_refresh", .object(["pane": .string(pane), "root": .string("/p/api")]))
        await model.refreshPanes()
        #expect(model.editor(pane)?.tabs.first?.diskState == .changedOnDisk)
        await model.settleEditorAutosave()
        #expect(await files.text(of: "/p/api/a.go") == "z")
    }

    @Test func whenFocusLeavesThePaneItsDirtyTabsSave() async throws {
        let (model, files) = await editorWindowWithFiles()
        _ = try await openTyped(model, files, mode: .focus)
        _ = await model.openPane(kind: "api")      // focus moves to the new pane
        await model.settleEditorAutosave()
        #expect(await files.text(of: "/p/api/a.go") == "b")
    }

    @Test func resigningActiveSavesInFocusModeOnly() async throws {
        let (model, files) = await editorWindowWithFiles()
        _ = try await openTyped(model, files, mode: .focus)
        await model.editorAppDidResignActive()
        #expect(await files.text(of: "/p/api/a.go") == "b")

        let (other, otherFiles) = await editorWindowWithFiles()
        _ = try await openTyped(other, otherFiles, mode: .pause, delay: .seconds(60))
        await other.editorAppDidResignActive()
        #expect(await otherFiles.text(of: "/p/api/a.go") == "a")
    }

    @Test func cancellingAnAutosaveInFlightLeavesTheTabDirty() async throws {
        let (model, files) = await editorWindowWithFiles()
        await files.setSlowWrite(true)
        let pane = try await openTyped(model, files, mode: .pause)
        guard await waitUntilSaving(model, pane) else { await files.releaseWrite(); await model.settleEditorAutosave(); return }
        model.cancelSave(pane: pane)
        await files.releaseWrite()
        await model.settleEditorAutosave()
        await model.refreshPanes()
        let t = try #require(model.editor(pane)?.tabs.first)
        #expect(t.dirty && !t.saving)
        #expect(await files.text(of: "/p/api/a.go") == "a")
    }

    // Final review I-1: every dirty tab in the pane focus leaves is written, not just the first.
    @Test func focusLeavingAPaneSavesEveryDirtyTab() async throws {
        let (model, files) = await editorWindowWithFiles()
        let pane = try await openTyped(model, files, mode: .focus)
        await files.put("/p/api/b.go", "a")
        await model.dispatchFromSurface("editor_open", .object(["pane": .string(pane), "path": .string("/p/api/b.go")]))
        await model.refreshPanes()
        let b = try #require(model.editor(pane)?.tabs.firstIndex { $0.path == "/p/api/b.go" })
        await model.editorBufferDidChange(pane: pane, tab: b, text: "b", basis: 0)
        await model.settleEditorAutosave()   // the tab switch to b.go saved a.go: dirty it again
        await model.editorBufferDidChange(pane: pane, tab: 0, text: "bb", basis: 0)
        #expect(model.editor(pane)?.tabs.filter(\.dirty).count == 2)
        _ = await model.openPane(kind: "api")      // focus moves to the new pane
        await model.settleEditorAutosave()
        #expect(await files.text(of: "/p/api/a.go") == "bb")
        #expect(await files.text(of: "/p/api/b.go") == "b")
    }

    // Final review I-2 (Rule 1): the operator's Don't Save must mean what it says.
    @Test func aPauseTimerDoesNotSaveBehindTheUnsavedPrompt() async throws {
        let (model, files) = await editorWindowWithFiles()
        let pane = try await openTyped(model, files, mode: .pause, delay: .seconds(1))
        await model.closeFocusedTabOrPane()   // ⌘W on the dirty tab: the prompt is up
        #expect(model.unsavedPrompt != nil)
        try await Task.sleep(for: .milliseconds(1300))
        await model.settleEditorAutosave()
        #expect(await files.text(of: "/p/api/a.go") == "a")
        await model.resolveUnsaved(.dontSave)
        await model.settleEditorAutosave()
        #expect(await files.text(of: "/p/api/a.go") == "a")
        #expect(model.editor(pane)?.tabs.isEmpty == true)
    }

    // Final review I-3 (Rule 8): an autosave that succeeds leaves an unread failure on the line.
    @Test func anAutosaveKeepsAnEarlierStatusLine() async throws {
        let (model, files) = await editorWindowWithFiles()
        _ = try await openTyped(model, files, mode: .pause, delay: .seconds(1))
        await model.dispatchFromSurface("no_such_action", .object([:]))   // a failure, unread
        let failure = model.status
        #expect(!failure.isEmpty)
        await model.settleEditorAutosave()
        #expect(await files.text(of: "/p/api/a.go") == "b")
        #expect(model.status == failure)
    }

    // Final review I-1: typing during a slow ⌘S leaves the tail saved, not dropped.
    @Test func aTimerThatFindsASaveInFlightSavesAfterIt() async throws {
        let (model, files) = await editorWindowWithFiles()
        let pane = try await openTyped(model, files, mode: .pause, delay: .seconds(1))
        await files.setSlowWrite(true)
        let save = Task { await model.saveFocusedEditor() }
        guard await waitUntilSaving(model, pane) else { await files.releaseWrite(); await save.value; return }
        await model.editorBufferDidChange(pane: pane, tab: 0, text: "bc", basis: 0)
        try await Task.sleep(for: .milliseconds(1300))   // the timer fires while ⌘S is still writing
        await files.releaseWrite()
        await save.value
        await model.settleEditorAutosave()
        #expect(await files.text(of: "/p/api/a.go") == "bc")
        #expect(model.editorAutosaveCount == 1)
    }

    // Final review M-3: the mode is read when the timer fires, not only when it is armed.
    @Test func turningAutosaveOffBeforeThePauseEndsSavesNothing() async throws {
        let (model, files) = await editorWindowWithFiles()
        _ = try await openTyped(model, files, mode: .pause, delay: .seconds(1))
        model.editorSettings = EditorSettings(
            app: SettingsEditor(fontSize: 12, wordWrap: false, autosave: .off), project: .defaults, appError: nil)
        try await Task.sleep(for: .milliseconds(1300))
        await model.settleEditorAutosave()
        #expect(await files.text(of: "/p/api/a.go") == "a")
        #expect(model.editorAutosaveCount == 0)
    }

    /// A stub for the project write, so a save lands without a wakil-ctx.
    private func stubProjectWrite(_ model: WindowModel, refuse: Bool = false) async {
        await model.registryForTesting.register(Action(
            name: "ctx_set_project_editor_settings", description: "stub", kind: .control, audience: .operatorOnly,
            schema: .object([:]),
            handler: { _ in
                if refuse { throw StandardActionError.missingParam(action: "ctx_set_project_editor_settings", param: "heavyFolders") }
                return .object([:])
            }))
    }

    // 3b-v part 2: the heavy folders decide what each root lists, so a save re-lists every root.
    @Test func savingTheHeavyFoldersRelistsEveryRoot() async throws {
        let (model, _, files) = await editorWindowParts(roots: ["/p/api", "/p/portal"])
        await model.refreshContext()
        await files.setListing("/p/api", ["a.go"])
        await model.openPane(kind: "editor")
        await model.toggleEditorColumn(.files)
        await stubProjectWrite(model)
        let before = await files.calls.filter { $0 == "files_list /p/api" }.count
        let refusal = await model.saveProjectEditorSettings(
            projectPath: "/p.json", ["heavyFolders": .array([.string("storage")])])
        #expect(refusal == nil)
        var spins = 0
        while await files.calls.filter({ $0 == "files_list /p/api" }).count <= before, spins < 2_000 {
            await Task.yield()
            spins += 1
        }
        #expect(await files.calls.filter { $0 == "files_list /p/api" }.count > before)
    }

    @Test func savingTheTabSizeRelistsNothing() async throws {
        let (model, _, files) = await editorWindowParts(roots: ["/p/api"])
        await model.refreshContext()
        await files.setListing("/p/api", ["a.go"])
        await model.openPane(kind: "editor")
        await model.toggleEditorColumn(.files)
        await stubProjectWrite(model)
        let before = await files.calls.filter { $0 == "files_list /p/api" }.count
        _ = await model.saveProjectEditorSettings(projectPath: "/p.json", ["tabSize": .integer(2)])
        for _ in 0..<50 { await Task.yield() }
        #expect(await files.calls.filter { $0 == "files_list /p/api" }.count == before)
    }

    // Review Focus 5.
    @Test func aRefusedHeavyFolderWriteRelistsNothing() async throws {
        let (model, _, files) = await editorWindowParts(roots: ["/p/api"])
        await model.refreshContext()
        await files.setListing("/p/api", ["a.go"])
        await model.openPane(kind: "editor")
        await model.toggleEditorColumn(.files)
        await stubProjectWrite(model, refuse: true)
        let before = await files.calls.filter { $0 == "files_list /p/api" }.count
        let refusal = await model.saveProjectEditorSettings(
            projectPath: "/p.json", ["heavyFolders": .array([.string("dist"), .string("dist")])])
        #expect(refusal != nil)
        for _ in 0..<50 { await Task.yield() }
        #expect(await files.calls.filter { $0 == "files_list /p/api" }.count == before)
    }

    @Test func revealShowsFilesOpensTheFoldersAndAsksThePaneToSelectTheRow() async throws {
        let (model, files) = await editorWindowWithFiles()
        await model.refreshContext()
        await files.put("/p/api/app/a.go", "x")
        await model.dispatchFromSurface("editor_open", .object(["path": .string("/p/api/app/a.go")]))
        await model.refreshLayout()
        let pane = try #require(model.layoutSnapshot.panes.first { $0.kind == "editor" }?.id)
        await model.revealActiveFileInTree(pane: pane)
        #expect(model.editor(pane)?.column?.shown == true && model.editor(pane)?.column?.view == .files)
        #expect(model.editor(pane)?.column?.open == ["/p/api", "/p/api/app"])
        #expect(model.editorTreeRevealRequest?.pane == pane && model.editorTreeRevealRequest?.path == "/p/api/app/a.go")
        #expect(model.editorColumnFocusRequest == nil, "the keyboard stays where it was (Rule 6)")
        model.editorTreeRevealTaken()
        #expect(model.editorTreeRevealRequest == nil)
    }

    @Test func revealWithAScratchInFrontDoesNothing() async throws {
        let (model, _) = await editorWindow()
        await model.refreshContext()
        await model.newScratch()
        let pane = try #require(model.layoutSnapshot.focusedId)
        await model.revealActiveFileInTree(pane: pane)
        #expect(model.editorTreeRevealRequest == nil && model.editor(pane)?.column == nil)
    }

    @Test func anOrgSwitchClearsAPendingRevealRequest() async throws {
        let (model, files) = await editorWindowWithFiles()
        await model.refreshContext()
        await files.put("/p/api/a.go", "x")
        await model.dispatchFromSurface("editor_open", .object(["path": .string("/p/api/a.go")]))
        await model.refreshLayout()
        await model.revealActiveFileInTree()
        try #require(model.editorTreeRevealRequest != nil)
        await model.invalidateForOrgChange()
        #expect(model.editorTreeRevealRequest == nil)
    }

    @Test func aMiddleClickClosesACleanTabAndAsksAboutADirtyOne() async throws {
        let (model, _) = await editorWindow()
        await model.refreshContext()
        await model.newScratch()
        await model.newScratch()
        let pane = try #require(model.layoutSnapshot.focusedId)
        await model.editorBufferDidChange(pane: pane, tab: 1, text: "typed", basis: 0)
        await model.closeEditorTab(pane: pane, subject: .scratch(number: 1))
        #expect(model.editor(pane)?.tabs.map(\.subject) == [.scratch(number: 2)])
        await model.closeEditorTab(pane: pane, subject: .scratch(number: 2))
        #expect(model.unsavedPrompt?.intent == .closeTab(pane: pane, subject: .scratch(number: 2)))
        #expect(model.editor(pane)?.tabs.count == 1)
    }

    @Test func theRevealCommandIsOfferedOnlyWithAFileTabInFront() async throws {
        let (model, files) = await editorWindowWithFiles()
        await model.refreshContext()
        await model.newScratch()
        #expect(!(await model.paletteContext().editorActiveIsFile))
        await files.put("/p/api/a.go", "x")
        await model.dispatchFromSurface("editor_open", .object(["path": .string("/p/api/a.go")]))
        await model.refreshPanes()
        #expect(await model.paletteContext().editorActiveIsFile)
    }
}

private actor WakeFlag {
    private(set) var isSet = false
    func set() { isSet = true }
}
