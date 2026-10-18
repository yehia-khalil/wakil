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

/// A window over its own registry, with the layout actions and the editor's actions on the
/// window's status over a `FakeGit` (as `WindowModelEditorTests` builds it), roots read from the
/// window itself — the wiring's arrangement, without the binaries.
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
        harnessFactory: { _, _, _ in nil }, resumes: ResumeBroker(),
        rootPath: "/tmp", providerId: "",
        lookupFactory: { _ in GitWindowLookup() },
        rootWatcher: watcher, editorRootWatcher: nil, fileLists: nil,
        gitStatus: status, paletteClients: PaletteClients(), placeClients: nil,
        agentSocketFactory: { _, _ in NoAgentSocket() })
    box.model = model
    await registerEditorActions(into: registry, panes: panes, layout: layout, files: nil, fileLists: nil,
                                gitStatus: status, roots: { await box.model?.gitRootPaths ?? [] })
    return (model, watcher, git, context)
}

@MainActor
private func openEditorPanes(_ model: WindowModel) async -> [String] {
    model.layoutSnapshot.panes.filter { $0.kind == "editor" }.map(\.id)
}

/// The window's git watcher and status (3a-i's, the window's since 3b-iii): it runs while an editor
/// pane is open, and reads once per root per wake for the window.
@Suite @MainActor struct WindowModelGitTests {
    @Test func theWatcherStartsWithAnEditorPaneAndAProjectAndStopsWithTheLastPane() async throws {
        let (model, watcher, _, _) = await gitWindow()
        await model.refreshContext()
        #expect(await watcher.events.isEmpty, "no editor pane yet, so nothing is watched")

        await model.openPane(kind: "editor")
        await model.openPane(kind: "editor")
        #expect(await watcher.events == ["watch /p/api,/p/portal 0.3 seconds"],
                "one watch for every root, however many editor panes are open")

        let ids = await openEditorPanes(model)
        try #require(ids.count == 2)
        await model.closePane(id: ids[0])
        #expect(await watcher.events.count == 1, "an editor pane is still open")
        await model.closePane(id: ids[1])
        #expect(await watcher.events.last == "stop")
    }

    /// A project's arrangement is its own, so a switch carries the editor pane only as far as
    /// the incoming project's canvas has one: none in `q` stops the watcher, one opened there
    /// watches `q`'s root, and coming back to `p` — whose canvas kept its editor pane — watches
    /// `p`'s again.
    @Test func aProjectSwitchRestartsTheWatcherOnTheNewRoots() async {
        let (model, watcher, git, context) = await gitWindow()
        await model.refreshContext()
        await model.openPane(kind: "editor")
        await context.switchTo(project: "q", roots: ["/q/web"])
        // `setProject` ends in this same read, and so does the agent's `ctx_set_project`.
        await model.refreshContext()
        #expect(await watcher.events == ["watch /p/api,/p/portal 0.3 seconds", "stop"])

        await model.openPane(kind: "editor")
        #expect(await watcher.events.last == "watch /q/web 0.3 seconds")

        await context.switchTo(project: "p", roots: ["/p/api", "/p/portal"])
        let beforeReturn = await git.calls.count
        await model.refreshContext()
        let events = await watcher.events
        #expect(events.last == "watch /p/api,/p/portal 0.3 seconds", "\(events)")
        // Fix round 1, I1: `p`'s canvas comes back as it was left, editor pane and all, and no
        // restore runs for an arrangement still in memory — so the watch that starts again
        // must read what changed while the operator was in `q`, not wait for the next event.
        let calls = await git.calls.dropFirst(beforeReturn)
        #expect(calls.contains { $0.hasPrefix("git_status /p/api") }, "\(calls)")
        #expect(calls.contains { $0.hasPrefix("git_status /p/portal") }, "\(calls)")
    }

    /// A second editor pane opened while one is open leaves the watched roots unchanged, so the
    /// watch does not restart and nothing is read: the window's status already holds every root.
    @Test func aSecondEditorPaneReadsNothingOfItsOwn() async throws {
        let (model, _, git, _) = await gitWindow()
        await model.refreshContext()
        await model.openPane(kind: "editor")
        let before = await git.statusCount
        await model.openPane(kind: "editor")
        try #require(await openEditorPanes(model).count == 2)
        #expect(model.gitRoots.map(\.root) == ["/p/api", "/p/portal"])
        #expect(await git.statusCount == before, "the window's status is read once, not per pane")
    }

    /// R4's catch-up (background agents 3 of 4, fix round 1), on 3b-iii's one status: a canvas
    /// come back to from memory on the same roots needs no read of its own. Here the environment
    /// left had an editor pane on the same roots, so the watch never stopped, and a change made
    /// while the operator was there already reached the window's status the returned pane reads.
    @Test func returningToACanvasInMemoryShowsWhatChangedWhileAway() async throws {
        let (model, watcher, git, context) = await gitWindow()
        await model.refreshContext()
        await model.openPane(kind: "editor")
        let staging = try #require(await openEditorPanes(model).first)
        await context.switchTo(environment: "dev")
        await model.refreshContext()
        await model.openPane(kind: "editor")
        let watches = await watcher.events.filter { $0.hasPrefix("watch") }.count
        await git.set(status: "/p/api", files: [("a.php", "changed", "M")])
        await watcher.fire("/p/api")

        await context.switchTo(environment: "staging")
        await model.refreshContext()

        #expect(await openEditorPanes(model) == [staging])
        #expect(await watcher.events.filter { $0.hasPrefix("watch") }.count == watches,
                "the same roots: the watch did not restart")
        #expect(model.gitRoots.first { $0.root == "/p/api" }?.files.map(\.path) == ["a.php"])
    }

    @Test func anOrgSwitchStopsTheWatcher() async {
        let (model, watcher, _, _) = await gitWindow()
        await model.refreshContext()
        await model.openPane(kind: "editor")
        await model.invalidateForOrgChange()
        #expect(await watcher.events.last == "stop")
    }

    @Test func aWakeReadsThatRootOnceForTheWindow() async {
        let (model, watcher, git, _) = await gitWindow()
        await model.refreshContext()
        await model.openPane(kind: "editor")
        await model.openPane(kind: "editor")
        let before = await git.calls.count

        await watcher.fire("/p/api")

        let calls = await git.calls.dropFirst(before)
        // 3b-iii: one read of the root for the window, however many panes show it.
        #expect(calls.filter { $0.hasPrefix("git_status /p/api") }.count == 1, "\(calls)")
        #expect(!calls.contains { $0.hasPrefix("git_status /p/portal") }, "\(calls)")
    }

    /// Opened from the Landing or by an agent naming no title, an editor pane is titled `Editor`.
    @Test func anEditorPaneIsTitledEditor() async throws {
        let (model, _, _, _) = await gitWindow()
        await model.refreshContext()
        await model.openPane(kind: "editor")
        let pane = try #require(model.layoutSnapshot.panes.first { $0.kind == "editor" })
        #expect(pane.title == "Editor")
        #expect(Pane.defaultTitle(kind: "db") == "db", "every other kind keeps its wire word")
    }

    @Test func noProjectRootMeansNoGitRoots() async {
        let (model, watcher, _, _) = await gitWindow(roots: [])
        await model.refreshContext()
        await model.openPane(kind: "editor")
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
        await model.openPane(kind: "editor")
        await model.openPane(kind: "editor")
        let before = await git.statusCount
        await watcher.fire("/p/api")
        #expect(await git.statusCount == before + 1)
        #expect(model.gitRoots.first?.files.map(\.path) == ["a.txt"], "the window shows the one read")
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

    // Fix round 1, item 2: a newly opened editor pane's window lists every root loading while the
    // first read is parked — not "No project roots to read".
    @Test func aNewEditorPaneListsEveryRootLoadingWhileTheFirstReadIsParked() async throws {
        let (model, _, git, _) = await gitWindow()
        await model.refreshContext()
        await git.setSlowStatus(true)
        let opening = Task { await model.openPane(kind: "editor") }
        while await git.statusCount < 2 { await Task.yield() }
        #expect(await apiEventually {
            model.gitRoots.map(\.root) == ["/p/api", "/p/portal"] && model.gitRoots.allSatisfy { $0.loading }
        }, "the window showed no roots loading while the read was parked")
        for call in 0..<8 { await git.releaseStatus(call) }
        _ = await opening.value
        #expect(model.gitRoots.allSatisfy { !$0.loading })
    }

    // And on a wake: the root carries the loading mark while it is read.
    @Test func aWakeMarksTheRootLoadingWhileItReads() async throws {
        let (model, watcher, git, _) = await gitWindow()
        await model.refreshContext()
        await model.openPane(kind: "editor")
        await git.setSlowStatus(true)
        let before = await git.statusCount
        let wake = Task { await watcher.fire("/p/api") }
        while await git.statusCount < before + 1 { await Task.yield() }
        #expect(await apiEventually {
            model.gitRoots.first { $0.root == "/p/api" }?.loading == true
        }, "the window showed no loading mark on the wake")
        for call in 0..<(before + 8) { await git.releaseStatus(call) }
        await wake.value
        #expect(model.gitRoots.allSatisfy { !$0.loading })
    }
}
