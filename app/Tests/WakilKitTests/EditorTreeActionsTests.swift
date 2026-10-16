import Foundation
import Testing
@testable import WakilKit

private func treeFixture() async throws -> (EditorFixture, EditorFileLists) {
    var f = try await editorFixture()
    let lists = EditorFileLists(files: f.files)
    let registry = ActionRegistry(journalDirectory: testScratchRoot.appendingPathComponent(UUID().uuidString), sessionId: "t")
    await registerEditorActions(into: registry, panes: f.panes, layout: f.layout, files: lists, fileLists: lists,
                                roots: { ["/p/api", "/p/web"] })
    f = EditorFixture(registry: registry, panes: f.panes, layout: f.layout, files: f.files, pane: f.pane)
    await lists.setWatching(true)
    return (f, lists)
}

@Test func showingTheColumnSetsAndPersistsItAndLoadsEveryRoot() async throws {
    let (f, lists) = try await treeFixture()
    await f.files.setListing("/p/api", ["a.go"]); await f.files.setListing("/p/web", ["i.ts"])
    let reply = try await f.dispatch("editor_tree", ["shown": .bool(true)])
    #expect(await f.snapshot().column == EditorColumnState(shown: true, view: .files, width: 240, open: []))
    #expect(await f.layout.editorColumn(id: f.pane)?.shown == true)
    #expect(await lists.state().listings.keys.sorted() == ["/p/api", "/p/web"])
    #expect(optionalString(reply, "pane") == f.pane)
}

@Test func aNewPaneStartsFromTheLastColumnLeftWithoutItsOpenFolders() async throws {
    let (f, _) = try await treeFixture()
    try await f.dispatch("editor_tree", ["shown": .bool(true), "view": .string("search"), "width": .number(320)])
    let other = await f.layout.open(kind: "editor", title: "Editor").id
    try await f.dispatch("editor_tree", ["pane": .string(other), "view": .string("files")])
    #expect(await f.panes.editorSnapshot(paneId: other).column == EditorColumnState(shown: true, view: .files, width: 320, open: []))
}

@Test func expandOpensThePathAndEveryParentAndCollapseClosesOnlyIt() async throws {
    let (f, _) = try await treeFixture()
    await f.files.setListing("/p/api", ["app/Models/User.php"])
    try await f.dispatch("editor_tree_expand", ["path": .string("/p/api/app/Models")])
    #expect(await f.snapshot().column?.open == ["/p/api", "/p/api/app", "/p/api/app/Models"])
    try await f.dispatch("editor_tree_collapse", ["path": .string("/p/api/app")])
    #expect(await f.snapshot().column?.open == ["/p/api", "/p/api/app/Models"])
}

// Final review I2: tree actions in flight together each read the column, await, then write it —
// so without one writer at a time a later write drops an earlier one's open folder, and the pane
// store and the layout can end on different copies.
@Test func concurrentExpandsKeepEveryOpenFolderAndBothStoresAgree() async throws {
    let (f, _) = try await treeFixture()
    let folders = (0..<24).map { "/p/api/d\($0)" }
    await f.files.setListing("/p/api", folders.map { String($0.dropFirst("/p/api/".count)) + "/x.go" })
    try await f.dispatch("editor_tree_expand", ["path": .string("/p/api")])
    try await withThrowingTaskGroup(of: Void.self) { group in
        for folder in folders {
            group.addTask { try await f.dispatch("editor_tree_expand", ["path": .string(folder)]) }
        }
        group.addTask { try await f.dispatch("editor_tree", ["width": .number(300)]) }
        try await group.waitForAll()
    }
    let open = Set(await f.snapshot().column?.open ?? [])
    #expect(open == Set(["/p/api"] + folders), "lost: \(Set(["/p/api"] + folders).subtracting(open).sorted())")
    #expect(await f.snapshot().column?.width == 300)
    #expect(await f.layout.editorColumn(id: f.pane) == f.snapshot().column, "the layout keeps the pane's copy")
}

@Test func expandingAHeavyFolderLoadsItThroughFilesListDir() async throws {
    let (f, lists) = try await treeFixture()
    await f.files.setListing("/p/api", ["a.go"]); await f.files.setHeavy("/p/api", ["vendor"])
    await f.files.setDir("/p/api/vendor", [("laravel", true), ("autoload.php", false)])
    try await f.dispatch("editor_tree_expand", ["path": .string("/p/api/vendor")])
    #expect(await lists.state().dirs["/p/api/vendor"]?.map(\.name) == ["laravel", "autoload.php"])
    #expect(await f.files.calls.contains("files_list_dir /p/api"))
}

@Test func collapsingAFolderStillLoadingCancelsTheLoad() async throws {
    let (f, lists) = try await treeFixture()
    await f.files.setListing("/p/api", []); await f.files.setHeavy("/p/api", ["vendor"])
    await f.files.setSlowDir(true)
    let expand = Task { try await f.dispatch("editor_tree_expand", ["path": .string("/p/api/vendor")]) }
    while await !lists.state().loading.contains("/p/api/vendor") { await Task.yield() }
    try await f.dispatch("editor_tree_collapse", ["path": .string("/p/api/vendor")])
    await f.files.releaseDir()
    _ = try? await expand.value
    #expect(await lists.state().loading.isEmpty)
    #expect(await lists.state().dirs["/p/api/vendor"] == nil)
}

@Test func treeActionsRefuseAPathOutsideTheRoots() async throws {
    let (f, _) = try await treeFixture()
    do {
        try await f.dispatch("editor_tree_expand", ["path": .string("/etc")])
        Issue.record("expected a refusal")
    } catch {
        #expect(String(describing: error).contains("Invariant 6") && String(describing: error).contains("Decision 36"))
    }
}

@Test func aPreviewOpenReplacesTheCleanPreviewTab() async throws {
    let (f, _) = try await treeFixture()
    await f.files.put("/p/api/a.go", "a"); await f.files.put("/p/api/b.go", "b")
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go"), "preview": .bool(true)])
    try await f.dispatch("editor_open", ["path": .string("/p/api/b.go"), "preview": .bool(true)])
    let s = await f.snapshot()
    #expect(s.tabs.map(\.path) == ["/p/api/b.go"] && s.tabs[0].preview && s.active == 0)
}

// Review Focus 4.
@Test func aPreviewOpenNeverReplacesADirtyTab() async throws {
    let (f, _) = try await treeFixture()
    await f.files.put("/p/api/a.go", "a"); await f.files.put("/p/api/b.go", "b")
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go"), "preview": .bool(true)])
    await f.panes.editorBufferDidChange(paneId: f.pane, tab: 0, text: "a!", basis: 0)
    try await f.dispatch("editor_open", ["path": .string("/p/api/b.go"), "preview": .bool(true)])
    let s = await f.snapshot()
    #expect(s.tabs.map(\.path) == ["/p/api/a.go", "/p/api/b.go"])
    #expect(!s.tabs[0].preview && s.tabs[1].preview)
}

@Test func anAgentEditKeepsThePreviewTab() async throws {
    let (f, _) = try await treeFixture()
    await f.files.put("/p/api/a.go", "a")
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go"), "preview": .bool(true)])
    try await f.dispatch("editor_replace_range", ["range": range(1, 1, 1, 1), "text": .string("x")])
    #expect(await f.snapshot().tabs[0].preview == false)
}

@Test func openingAPreviewTabWithoutPreviewKeepsIt() async throws {
    let (f, _) = try await treeFixture()
    await f.files.put("/p/api/a.go", "a")
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go"), "preview": .bool(true)])
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
    #expect(await f.snapshot().tabs[0].preview == false)
}

@Test func aPreviewOpenOfAnAlreadyOpenFileSwitchesToIt() async throws {
    let (f, _) = try await treeFixture()
    await f.files.put("/p/api/a.go", "a"); await f.files.put("/p/api/b.go", "b")
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
    try await f.dispatch("editor_open", ["path": .string("/p/api/b.go"), "preview": .bool(true)])
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go"), "preview": .bool(true)])
    let s = await f.snapshot()
    #expect(s.tabs.count == 2 && s.active == 0 && !s.tabs[0].preview)
}

@Test func restoreBringsTheColumnBackWithMissingFoldersDropped() async throws {
    let (f, _) = try await treeFixture()
    await f.files.setListing("/p/api", ["app/a.php"])
    await f.layout.setEditorColumn(id: f.pane, to: EditorColumnState(shown: true, view: .files, width: 260,
                                                                    open: ["/p/api", "/p/api/app", "/p/api/gone"]))
    try await f.dispatch("editor_restore")
    #expect(await f.snapshot().column == EditorColumnState(shown: true, view: .files, width: 260, open: ["/p/api", "/p/api/app"]))
}

// Final review I2: an expand that lands while editor_restore awaits its listings is kept — restore
// prunes the column as it is then, not the copy it read before — and both stores agree.
@Test func anExpandDuringARestoreIsKeptAndBothStoresAgree() async throws {
    let (f, lists) = try await treeFixture()
    await f.files.setListing("/p/api", ["app/a.php", "lib/x.go"])
    await f.layout.setEditorColumn(id: f.pane, to: EditorColumnState(shown: true, view: .files, width: 260,
                                                                    open: ["/p/api", "/p/api/app"]))
    await f.files.setSlowList(true)
    let restore = Task { try await f.dispatch("editor_restore") }
    while await !f.files.calls.contains("files_list /p/api") { await Task.yield() }
    let expand = Task { try await f.dispatch("editor_tree_expand", ["path": .string("/p/api/lib")]) }
    while await f.snapshot().column?.open.contains("/p/api/lib") != true { await Task.yield() }
    await f.files.releaseList()
    _ = try await restore.value
    _ = try await expand.value
    _ = lists
    #expect(await f.snapshot().column?.open == ["/p/api", "/p/api/app", "/p/api/lib"])
    #expect(await f.layout.editorColumn(id: f.pane) == f.snapshot().column, "the layout keeps the pane's copy")
}

@Test func unwatchedListsAreReadFreshEveryTime() async throws {
    let f = try await editorFixture()
    let lists = EditorFileLists(files: f.files)
    await f.files.setListing("/p/api", ["a.go"])
    _ = await lists.listing(root: "/p/api")
    await f.files.setListing("/p/api", ["a.go", "b.go"])
    #expect(await lists.listing(root: "/p/api").files == ["a.go", "b.go"])
    await lists.setWatching(true)
    _ = await lists.listing(root: "/p/api")
    await f.files.setListing("/p/api", ["c.go"])
    #expect(await lists.listing(root: "/p/api").files == ["a.go", "b.go"])
    await lists.invalidate(root: "/p/api")
    #expect(await lists.listing(root: "/p/api").files == ["c.go"])
}

// Final review I1: a root that stops being watched while the list stays watched (a project
// switch) loses its kept list; watched again, a root that was listed is re-read.
@Test func aRootNoLongerWatchedIsNeverServedFromItsKeptList() async throws {
    let f = try await editorFixture()
    let lists = EditorFileLists(files: f.files)
    await lists.watch(roots: ["/p/api"])
    await f.files.setListing("/p/api", ["a.go"])
    _ = await lists.listing(root: "/p/api")
    await lists.watch(roots: ["/q/web"])                 // still watching, but not /p/api
    await f.files.setListing("/p/api", ["a.go", "b.go"])
    await lists.watch(roots: ["/p/api"]).value
    #expect(await lists.state().listings["/p/api"]?.files == ["a.go", "b.go"], "re-read on return")
    #expect(await lists.listing(root: "/p/api").files == ["a.go", "b.go"])
}

// A watcher wake while a files_list is in flight: the stale read lands after the invalidate and
// must not be kept, or the tree never catches up.
@Test func aReadInFlightAcrossAnInvalidateIsNeverKept() async throws {
    let f = try await editorFixture()
    let lists = EditorFileLists(files: f.files)
    await lists.setWatching(true)
    await f.files.setListing("/p/api", ["a.go"])
    await f.files.setSlowList(true)
    let stale = Task { await lists.listing(root: "/p/api") }
    while await !f.files.calls.contains("files_list /p/api") { await Task.yield() }
    await f.files.setListing("/p/api", ["a.go", "b.go"])
    await f.files.setSlowList(false)
    await lists.invalidate(root: "/p/api")          // re-reads: the root was being listed
    await f.files.releaseList()
    _ = await stale.value
    #expect(await lists.state().listings["/p/api"]?.files == ["a.go", "b.go"])
    #expect(await lists.listing(root: "/p/api").files == ["a.go", "b.go"])
}

// Controller ruling 1: a root whose listing failed keeps its saved open folders untouched; only a
// successful listing can say a folder is gone.
@Test func restoreKeepsTheOpenFoldersOfARootWhoseListingFailed() async throws {
    let (f, _) = try await treeFixture()
    await f.files.setListing("/p/api", ["app/a.php"])
    await f.files.setListError("/p/web", "wakil-files: /p/web is unreadable")
    await f.layout.setEditorColumn(id: f.pane, to: EditorColumnState(shown: true, view: .files, width: 260,
                                                                    open: ["/p/api/gone", "/p/web", "/p/web/src"]))
    try await f.dispatch("editor_restore")
    #expect(await f.snapshot().column?.open == ["/p/web", "/p/web/src"])
}

// Controller ruling 2: showing the column lists the roots itself, so the tree is not empty just
// because the window's watcher has not started yet.
@Test func showingTheColumnListsTheRootsBeforeTheWatcherStarts() async throws {
    var f = try await editorFixture()
    let lists = EditorFileLists(files: f.files)
    let registry = ActionRegistry(journalDirectory: testScratchRoot.appendingPathComponent(UUID().uuidString), sessionId: "t")
    await registerEditorActions(into: registry, panes: f.panes, layout: f.layout, files: lists, fileLists: lists,
                                roots: { ["/p/api", "/p/web"] })
    f = EditorFixture(registry: registry, panes: f.panes, layout: f.layout, files: f.files, pane: f.pane)
    await f.files.setListing("/p/api", ["a.go"]); await f.files.setListing("/p/web", ["i.ts"])
    try await f.dispatch("editor_tree", ["shown": .bool(true)])
    #expect(await lists.state().listings["/p/api"]?.files == ["a.go"])
    #expect(await lists.state().listings["/p/web"]?.files == ["i.ts"])
}

@Test func aPaneThatSavedOnlyAColumnStillRestores() async throws {
    let (f, _) = try await treeFixture()
    await f.layout.setEditorColumn(id: f.pane, to: EditorColumnState(shown: true, view: .files, width: 240, open: []))
    let pane = try #require(await f.layout.snapshot().panes.first { $0.id == f.pane })
    #expect(EditorPaneKind.restoreStep(for: pane)?.action == "editor_restore")
}

// Review round 1, Important 1: a folder load overtaken by a refresh of its root never lands — here
// the refresh finds the heavy folder gone, so nothing reloads it either.
@Test func aFolderLoadOvertakenByARootRefreshNeverLands() async throws {
    let (f, lists) = try await treeFixture()
    await f.files.setListing("/p/api", []); await f.files.setHeavy("/p/api", ["vendor"])
    await f.files.setDir("/p/api/vendor", [("laravel", true)])
    await f.files.setSlowDir(true)
    let expand = Task { try await f.dispatch("editor_tree_expand", ["path": .string("/p/api/vendor")]) }
    while await !lists.state().loading.contains("/p/api/vendor") { await Task.yield() }
    await f.files.setHeavy("/p/api", [])
    await lists.invalidate(root: "/p/api")
    await f.files.releaseDir()
    _ = try? await expand.value
    #expect(await lists.state().dirs["/p/api/vendor"] == nil)
    #expect(await lists.state().loading.isEmpty)
}

// Controller ruling (round 1): a watcher wake reloads the loaded heavy folders, keeping their
// entries on screen until the reload lands — an open `vendor` never empties on a file change.
@Test func aRootRefreshReloadsItsLoadedHeavyFoldersWithoutEmptyingThem() async throws {
    let (f, lists) = try await treeFixture()
    await f.files.setListing("/p/api", ["a.go"]); await f.files.setHeavy("/p/api", ["vendor"])
    await f.files.setDir("/p/api/vendor", [("laravel", true)])
    try await f.dispatch("editor_tree_expand", ["path": .string("/p/api/vendor")])
    await f.files.setDir("/p/api/vendor", [("laravel", true), ("composer.json", false)])
    await f.files.setSlowDir(true)
    let wake = Task { await lists.invalidate(root: "/p/api") }
    // Bounded: without a reload this never comes true, and the test must fail, not hang.
    var spins = 0
    while await !lists.state().loading.contains("/p/api/vendor"), spins < 100_000 { spins += 1; await Task.yield() }
    #expect(await lists.state().loading.contains("/p/api/vendor"), "the wake reloads the open heavy folder")
    #expect(await lists.state().dirs["/p/api/vendor"]?.map(\.name) == ["laravel"])
    await f.files.releaseDir()
    // The wake starts the reload and does not wait for it (Task 7, controller ruling 2); the task
    // it hands back finishes when the reload has landed.
    await wake.value.value
    #expect(await lists.state().dirs["/p/api/vendor"]?.map(\.name) == ["laravel", "composer.json"])
    #expect(await lists.state().loading.isEmpty)
}

// Controller ruling (round 1): expanding a deep path inside a heavy folder loads every heavy
// ancestor not yet loaded, so the subtree above it draws.
@Test func expandingADeepHeavyPathLoadsEachHeavyAncestor() async throws {
    let (f, lists) = try await treeFixture()
    await f.files.setListing("/p/api", ["a.go"]); await f.files.setHeavy("/p/api", ["vendor"])
    await f.files.setDir("/p/api/vendor", [("laravel", true)])
    await f.files.setDir("/p/api/vendor/laravel", [("framework", true)])
    await f.files.setDir("/p/api/vendor/laravel/framework", [("src", true)])
    try await f.dispatch("editor_tree_expand", ["path": .string("/p/api/vendor/laravel/framework")])
    let dirs = await lists.state().dirs
    #expect(dirs["/p/api/vendor"]?.map(\.name) == ["laravel"])
    #expect(dirs["/p/api/vendor/laravel"]?.map(\.name) == ["framework"])
    #expect(dirs["/p/api/vendor/laravel/framework"]?.map(\.name) == ["src"])
}

// Controller ruling 2 (Rule 8): a failed folder load keeps its error whole, for its row.
@Test func aFailedFolderLoadKeepsItsWholeError() async throws {
    let (f, lists) = try await treeFixture()
    await f.files.setListing("/p/api", []); await f.files.setHeavy("/p/api", ["vendor"])
    await f.files.setDirThrows("/p/api/vendor", "wakil-files: connection closed while listing vendor")
    try await f.dispatch("editor_tree_expand", ["path": .string("/p/api/vendor")])
    #expect(await lists.state().dirErrors["/p/api/vendor"] == "wakil-files: connection closed while listing vendor")
    #expect(await lists.state().loading.isEmpty)
}

// Controller ruling 2: turning watching off cancels the folder loads in flight; none lands later.
@Test func turningWatchingOffCancelsFolderLoadsInFlight() async throws {
    let (f, lists) = try await treeFixture()
    await f.files.setListing("/p/api", []); await f.files.setHeavy("/p/api", ["vendor"])
    await f.files.setDir("/p/api/vendor", [("laravel", true)])
    await f.files.setSlowDir(true)
    let expand = Task { try await f.dispatch("editor_tree_expand", ["path": .string("/p/api/vendor")]) }
    while await !lists.state().loading.contains("/p/api/vendor") { await Task.yield() }
    await lists.setWatching(false)
    await f.files.releaseDir()
    _ = try? await expand.value
    #expect(await lists.state().dirs["/p/api/vendor"] == nil)
    #expect(await lists.state().loading.isEmpty)
}

// Review round 1, minor 1: turning watching off when it is already off changes nothing, so a tree
// listed unwatched is not wiped by every sync that finds no watcher.
@Test func unwatchingAnUnwatchedListKeepsWhatItListed() async throws {
    let f = try await editorFixture()
    let lists = EditorFileLists(files: f.files)
    await f.files.setListing("/p/api", ["a.go"])
    _ = await lists.listing(root: "/p/api")
    await lists.setWatching(false)
    #expect(await lists.state().listings["/p/api"]?.files == ["a.go"])
}
