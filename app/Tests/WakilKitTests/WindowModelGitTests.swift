import Foundation
import Testing
@testable import WakilKit

/// A `wakil-ctx` that answers `get_context` with a project and roots the test can move.
actor GitRootsContext: ToolCaller {
    private var project: String
    private var roots: [String]
    private var environment = "staging"

    init(project: String = "p", roots: [String]) {
        self.project = project
        self.roots = roots
    }

    func switchTo(project: String, roots: [String]) {
        self.project = project
        self.roots = roots
    }

    func switchTo(environment: String) { self.environment = environment }

    func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        guard name == "get_context" else { return .object(["structuredContent": .object([:])]) }
        return .object(["structuredContent": .object([
            "Org": .string("acme"), "Environment": .string(environment),
            "Project": .object(["name": .string(project)]),
            "RootPaths": .array(roots.map { .string($0) }),
        ])])
    }
}

/// A `RootWatcher` that records what the window asked of it and keeps the last `changed`, so
/// a test can play an FSEvents wake by hand.
actor RecordingRootWatcher: RootWatcher {
    private(set) var events: [String] = []
    private var changed: (@Sendable (String, [String]?) async -> Void)?

    func watch(roots: [String], window: Duration, changed: @escaping @Sendable (String) async -> Void) async {
        await watch(roots: roots, window: window) { root, _ in await changed(root) }
    }

    func watch(roots: [String], window: Duration, changedPaths: @escaping @Sendable (String, [String]?) async -> Void) async {
        events.append("watch \(roots.joined(separator: ",")) \(window)")
        self.changed = changedPaths
    }

    func stop() async {
        events.append("stop")
        changed = nil
    }

    /// A burst under `root`; `paths` the ones that woke it, nil when the watcher cannot say.
    func fire(_ root: String, paths: [String]? = nil) async { await changed?(root, paths) }
}

private struct GitWindowLookup: ProviderCredentialsLookup {
    func credentials(forProvider id: String) async throws -> ProviderCredentials {
        ProviderCredentials(claudePath: "/usr/bin/true", configDir: "/dev/null", oauthToken: "test-only")
    }
}

@MainActor final class RootsBox { weak var model: WindowModel? }

/// A window over its own registry, with the layout and git actions registered against a
/// `FakeGit`, roots read from the window itself — the wiring's arrangement, without the
/// binaries.
@MainActor
private func gitWindow(
    roots: [String] = ["/p/api", "/p/portal"]
) async -> (WindowModel, RecordingRootWatcher, FakeGit, GitRootsContext) {
    let registry = ActionRegistry(
        journalDirectory: testScratchRoot.appendingPathComponent("git-window-\(UUID().uuidString)"),
        sessionId: "git-window")
    let panes = PaneStore()
    let layout = LayoutStore()
    let context = GitRootsContext(roots: roots)
    let watcher = RecordingRootWatcher()
    let git = FakeGit()
    for root in ["/p/api", "/p/portal", "/q/web"] {
        await git.set(status: root, files: [("a.txt", "changed", "M")])
    }
    await registerLayoutActions(into: registry, layout: layout, panes: panes)
    let box = RootsBox()
    let status = GitStatus(git: git, roots: { await box.model?.gitRootPaths ?? [] })
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout,
        context: ContextStore(client: context),
        harnessFactory: { _, _ in nil }, resumes: ResumeBroker(),
        rootPath: "/tmp", providerId: "",
        lookupFactory: { _ in GitWindowLookup() },
        rootWatcher: watcher, editorRootWatcher: nil, fileLists: nil,
        gitStatus: status, paletteClients: PaletteClients())
    box.model = model
    await registerGitActions(into: registry, panes: panes, layout: layout, status: status)
    return (model, watcher, git, context)
}

@MainActor
private func openGitPanes(_ model: WindowModel) async -> [String] {
    model.layoutSnapshot.panes.filter { $0.kind == "git" }.map(\.id)
}

@Suite @MainActor struct WindowModelGitTests {
    @Test func theWatcherStartsWithAGitPaneAndAProjectAndStopsWithTheLastPane() async throws {
        let (model, watcher, _, _) = await gitWindow()
        await model.refreshContext()
        #expect(await watcher.events.isEmpty, "no git pane yet, so nothing is watched")

        await model.openPane(kind: "git")
        await model.openPane(kind: "git")
        #expect(await watcher.events == ["watch /p/api,/p/portal 0.3 seconds"],
                "one watch for every root, however many git panes are open")

        let ids = await openGitPanes(model)
        try #require(ids.count == 2)
        await model.closePane(id: ids[0])
        #expect(await watcher.events.count == 1, "a git pane is still open")
        await model.closePane(id: ids[1])
        #expect(await watcher.events.last == "stop")
    }

    /// A project's arrangement is its own, so a switch carries the git pane only as far as
    /// the incoming project's canvas has one: none in `q` stops the watcher, one opened there
    /// watches `q`'s root, and coming back to `p` — whose canvas kept its git pane — watches
    /// `p`'s again.
    @Test func aProjectSwitchRestartsTheWatcherOnTheNewRoots() async {
        let (model, watcher, git, context) = await gitWindow()
        await model.refreshContext()
        await model.openPane(kind: "git")
        await context.switchTo(project: "q", roots: ["/q/web"])
        // `setProject` ends in this same read, and so does the agent's `ctx_set_project`.
        await model.refreshContext()
        #expect(await watcher.events == ["watch /p/api,/p/portal 0.3 seconds", "stop"])

        await model.openPane(kind: "git")
        #expect(await watcher.events.last == "watch /q/web 0.3 seconds")

        await context.switchTo(project: "p", roots: ["/p/api", "/p/portal"])
        let beforeReturn = await git.calls.count
        await model.refreshContext()
        let events = await watcher.events
        #expect(events.last == "watch /p/api,/p/portal 0.3 seconds", "\(events)")
        // Fix round 1, I1: `p`'s canvas comes back as it was left, git pane and all, and no
        // restore runs for an arrangement still in memory — so the watch that starts again
        // must read what changed while the operator was in `q`, not wait for the next event.
        let calls = await git.calls.dropFirst(beforeReturn)
        #expect(calls.contains { $0.hasPrefix("git_status /p/api") }, "\(calls)")
        #expect(calls.contains { $0.hasPrefix("git_status /p/portal") }, "\(calls)")
    }

    /// Final review, item 6: a second git pane opened while one is open leaves the watched
    /// roots unchanged, so the watch does not restart — and it must still read, not show
    /// "No project roots to read" until the next file event.
    /// 3b-iii: a second pane reads nothing of its own; it adopts the window's status, so it shows
    /// every root without wakil-git seeing another read.
    @Test func aSecondGitPaneAdoptsTheWindowsStatusWhenItOpens() async throws {
        let (model, _, git, _) = await gitWindow()
        await model.refreshContext()
        await model.openPane(kind: "git")
        let before = await git.statusCount
        await model.openPane(kind: "git")
        let second = try #require(await openGitPanes(model).last)
        try #require(await openGitPanes(model).count == 2)
        #expect(await apiEventually { model.git(second)?.roots.map(\.root) == ["/p/api", "/p/portal"] },
                "the second pane never showed the status")
        #expect(await git.statusCount == before, "the window's status is read once, not per pane")
    }

    @Test func anOrgSwitchStopsTheWatcher() async {
        let (model, watcher, _, _) = await gitWindow()
        await model.refreshContext()
        await model.openPane(kind: "git")
        await model.invalidateForOrgChange()
        #expect(await watcher.events.last == "stop")
    }

    @Test func aWakeRefreshesThatRootInEveryOpenGitPane() async {
        let (model, watcher, git, _) = await gitWindow()
        await model.refreshContext()
        await model.openPane(kind: "git")
        await model.openPane(kind: "git")
        let before = await git.calls.count

        await watcher.fire("/p/api")

        let calls = await git.calls.dropFirst(before)
        // 3b-iii: one read of the root for the window, however many panes show it.
        #expect(calls.filter { $0.hasPrefix("git_status /p/api") }.count == 1, "\(calls)")
        #expect(!calls.contains { $0.hasPrefix("git_status /p/portal") }, "\(calls)")
    }

    /// R6: a git pane brought back by a restore re-reads its status. It has no fetch, so a
    /// restore that only re-ran fetches would leave it showing nothing.
    @Test func aRestoredGitPaneReReadsEveryRoot() async {
        let (model, _, git, _) = await gitWindow()
        await model.refreshContext()
        await model.openPane(kind: "git")
        let before = await git.calls.count

        await model.restorePaneContents()

        let calls = await git.calls.dropFirst(before)
        #expect(calls.contains { $0.hasPrefix("git_status /p/api") }, "\(calls)")
        #expect(calls.contains { $0.hasPrefix("git_status /p/portal") }, "\(calls)")
    }

    /// Task 10: the pane draws what the window holds for it, read after every dispatch and
    /// every refresh — the same snapshot `read_pane` answers with.
    @Test func theWindowHoldsEachGitPanesSnapshot() async throws {
        let (model, watcher, _, _) = await gitWindow()
        await model.refreshContext()
        await model.openPane(kind: "git")
        let id = try #require(await openGitPanes(model).first)
        await watcher.fire("/p/api")
        let snapshot = try #require(model.git(id))
        #expect(snapshot.roots.map(\.name) == ["api", "portal"])
        #expect(snapshot.roots.first?.files.map(\.path) == ["a.txt"])

        await model.dispatchFromSurface("git_select", .object([
            "pane": .string(id), "root": .string("/p/api"), "path": .string("a.txt"),
            "group": .string("changed"),
        ]))
        #expect(model.git(id)?.folded == true)
        #expect(model.git(id)?.selection?.path == "a.txt")
    }

    /// Opened from the Landing or by an agent naming no title, a git pane is titled `Git`.
    @Test func aGitPaneIsTitledGit() async throws {
        let (model, _, _, _) = await gitWindow()
        await model.refreshContext()
        await model.openPane(kind: "git")
        let pane = try #require(model.layoutSnapshot.panes.first { $0.kind == "git" })
        #expect(pane.title == "Git")
        #expect(Pane.defaultTitle(kind: "db") == "db", "every other kind keeps its wire word")
    }

    @Test func noProjectRootMeansNoGitRoots() async {
        let (model, watcher, _, _) = await gitWindow(roots: [])
        await model.refreshContext()
        await model.openPane(kind: "git")
        #expect(model.gitRootPaths.isEmpty)
        #expect(model.rootPath == NSHomeDirectory())
        #expect(await watcher.events.isEmpty, "no root, so nothing to watch")
    }

    @Test func anEditorPaneAloneStartsTheWatcherAndTheStatusIsReadFirst() async throws {
        let (model, watcher, git, _) = await gitWindow()
        await model.refreshContext()
        await model.openPane(kind: "editor")
        #expect(await watcher.events == ["watch /p/api,/p/portal 0.3 seconds"])
        #expect(model.gitRoots.map(\.root) == ["/p/api", "/p/portal"])
        #expect(await git.statusCount == 2, "one read per root, before any wake")
    }

    @Test func oneReadPerRootPerWakeWhateverTheNumberOfPanes() async throws {
        let (model, watcher, git, _) = await gitWindow()
        await model.refreshContext()
        await model.openPane(kind: "git")
        await model.openPane(kind: "git")
        await model.openPane(kind: "editor")
        let before = await git.statusCount
        await watcher.fire("/p/api")
        #expect(await git.statusCount == before + 1)
        for pane in await openGitPanes(model) {
            #expect(model.git(pane)?.roots.first?.files.map(\.path) == ["a.txt"], "every git pane shows the one read")
        }
    }

    @Test func nothingIsReadWithNoPaneThatShowsGit() async throws {
        let (model, watcher, git, _) = await gitWindow()
        await model.refreshContext()
        await model.openPane(kind: "api")
        #expect(await watcher.events.isEmpty)
        #expect(await git.statusCount == 0)
    }

    @Test func anOrgSwitchEmptiesTheMirror() async throws {
        let (model, _, _, _) = await gitWindow()
        await model.refreshContext()
        await model.openPane(kind: "editor")
        await model.invalidateForOrgChange()
        #expect(model.gitRoots.isEmpty)
    }
}
