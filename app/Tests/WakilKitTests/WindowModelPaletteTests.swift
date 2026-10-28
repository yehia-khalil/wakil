import Foundation
import Testing
@testable import WakilKit

// MARK: - Fakes

/// A `wakil-db` whose databases and tables a test can change between opens, and whose
/// listings can be held at a gate — so a background refresh can be made to land late.
private actor PaletteDB: ToolCaller {
    private var databases: [String]
    private var tables: [String: [String]]
    private var gated = false
    /// `holdNext()`: park only the next listing, so a read that follows it is not held too.
    private var gateOnce = false
    private var parked: [CheckedContinuation<Void, Never>] = []
    private(set) var calls: [String] = []

    init(databases: [String], tables: [String: [String]]) {
        self.databases = databases
        self.tables = tables
    }

    func set(tables: [String: [String]]) { self.tables = tables }
    func hold() { gated = true }
    func holdNext() { gated = true; gateOnce = true }
    func release() {
        gated = false
        parked.forEach { $0.resume() }
        parked = []
    }
    func count(_ name: String) -> Int { calls.filter { $0.hasPrefix(name) }.count }

    func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        calls.append("\(name) \(optionalString(arguments, "database") ?? optionalString(arguments, "name") ?? "")")
        if gated, name == "list_databases" {
            if gateOnce { gated = false; gateOnce = false }
            await withCheckedContinuation { parked.append($0) }
        }
        switch name {
        case "list_databases":
            return .object(["structuredContent": .object([
                "databases": .array(databases.map { .object(["name": .string($0), "driver": .string("postgres")]) }),
            ])])
        case "list_tables":
            let names = tables[optionalString(arguments, "database") ?? ""] ?? []
            return .object(["structuredContent": .object([
                "containers": .array(names.map { .object(["name": .string($0), "kind": .string("table")]) }),
            ])])
        case "read_table":
            return .object(["structuredContent": .object([
                "columns": .array([.string("id")]), "rows": .array([.array([.integer(1)])]),
            ])])
        default:
            return .object([:])
        }
    }
}

/// A `wakil-http` whose `list_apis` answers `entries`.
private func paletteHTTP(_ entries: [String]) -> RecordingToolCaller {
    RecordingToolCaller { name, _ in
        guard name == "list_apis" else { return .object([:]) }
        return .object(["structuredContent": .object(["apis": .array(entries.map {
            .object(["name": .string($0), "baseUrl": .string("https://\($0).example")])
        })])])
    }
}

/// A harness whose `send` never returns, so `turnInFlight` is genuinely true — the same
/// shape `ProviderSwitchTests` uses for its own turn-in-flight refusal.
private final class HangingHarness: AgentHarness, @unchecked Sendable {
    private let stream: AsyncStream<HarnessEvent>
    private let continuation: AsyncStream<HarnessEvent>.Continuation
    init() { (stream, continuation) = AsyncStream<HarnessEvent>.makeStream() }
    func start(sessionId: String, resumingFrom parentSessionId: String?, workingDirectory: String) async throws {}
    func send(_ text: String) async throws {
        await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
    }
    func events() -> AsyncStream<HarnessEvent> { stream }
    func interrupt() async {}
    func stop() async { continuation.finish() }
}

private struct PaletteLookup: ProviderCredentialsLookup {
    func credentials(forProvider id: String) async throws -> ProviderCredentials {
        ProviderCredentials(claudePath: "/usr/bin/true", configDir: "/dev/null", oauthToken: "test-only")
    }
}

/// Parks the first caller until `release()`; later callers pass.
private actor SourceGateBox {
    private var first = true
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var parked = false
    func waitIfFirst() async {
        guard first else { return }
        first = false
        parked = true
        await withCheckedContinuation { waiter = $0 }
    }
    func release() {
        waiter?.resume()
        waiter = nil
    }
}

/// Collects `onLate` deliveries across tasks.
private actor LateBox {
    private(set) var deliveries: [[PaletteEntry]] = []
    func add(_ rows: [PaletteEntry]) { deliveries.append(rows) }
}

/// One window over a real registry: layout actions, the window's status over a `FakeGit` (with the
/// editor's actions on it when `editorGit`), roots from a `GitRootsContext`, and whatever else
/// `register` adds — the wiring's arrangement without the binaries.
private struct PaletteWindow {
    let model: WindowModel
    let registry: ActionRegistry
    let panes: PaneStore
    let layout: LayoutStore
    let git: FakeGit
    let context: GitRootsContext

    func journal() async throws -> [JournalEntry] { try await registry.journalEntries() }
}

@MainActor
private func paletteWindow(
    environment: String = "staging",
    db: (any ToolCaller)? = nil,
    http: (any ToolCaller)? = nil,
    files: (any ToolCaller)? = nil,
    harness: AgentHarness? = nil,
    editorGit: Bool = false,
    register: @Sendable (ActionRegistry, PaneStore, LayoutStore) async -> Void = { _, _, _ in }
) async -> PaletteWindow {
    let registry = ActionRegistry(
        journalDirectory: testScratchRoot.appendingPathComponent("palette-window-\(UUID().uuidString)"),
        sessionId: "palette-window")
    let panes = PaneStore()
    let layout = LayoutStore()
    let context = GitRootsContext(roots: ["/p/api", "/p/portal"])
    let git = FakeGit()
    await git.set(status: "/p/api", files: [("a.txt", "changed", "M")])
    await git.set(status: "/p/portal", files: [])
    await registerLayoutActions(into: registry, layout: layout, panes: panes)
    await register(registry, panes, layout)
    // The window's one status, read by the window and the actions alike (3b-iii) — the production
    // arrangement.
    let box = RootsBox()
    let status = GitStatus(git: git, roots: { await box.model?.gitRootPaths ?? [] })
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout,
        context: ContextStore(client: context),
        harnessFactory: { _, _, _ in harness }, resumes: ResumeBroker(),
        rootPath: "/tmp", providerId: "main",
        lookupFactory: { _ in PaletteLookup() },
        rootWatcher: RecordingRootWatcher(),
        gitStatus: status,
        paletteClients: PaletteClients(database: db, http: http, git: git, files: files),
        environment: environment)
    box.model = model
    if editorGit {
        await registerEditorActions(into: registry, panes: panes, layout: layout, files: files, fileLists: nil,
                                    gitStatus: status, roots: { await box.model?.gitRootPaths ?? [] })
    }
    return PaletteWindow(model: model, registry: registry, panes: panes, layout: layout, git: git,
                         context: context)
}

/// A stand-in `ctx_set_environment` with the shipped action's gate shape: `.control`, its
/// target named by `name`.
private func registerEnvironmentSwitch(into registry: ActionRegistry) async {
    await registry.register(Action(
        name: "ctx_set_environment", description: "", kind: .control, audience: .agentReachable,
        schema: .object([:]), handler: { _ in .object([:]) }, targetEnvironmentParam: "name"))
}

// MARK: - Tests

@Suite @MainActor struct WindowModelPaletteTests {
    /// Spec 37: ⌘P → "New Editor pane" → an editor pane opens and is focused.
    @Test func newEditorPaneEntryOpensAndFocusesAnEditorPane() async throws {
        let w = await paletteWindow()
        await w.model.refreshContext()
        let entries = await w.model.paletteRootEntries(mode: .open) { _ in }
        let row = try #require(entries.first { $0.id == "newpane:editor" })

        #expect(await w.model.performPalette(.run(row.action)) == nil)

        let editors = w.model.layoutSnapshot.panes.filter { $0.kind == "editor" }
        #expect(editors.count == 1)
        #expect(w.model.layoutSnapshot.focusedId == editors.first?.id)
        #expect(try await w.journal().contains { $0.action == "pane_open" && $0.origin == .ui })
    }

    /// The `palette-command-step` e2e on the Conversations branch: a launch onto a Landing gives
    /// the composer the keyboard (ruling 7), so ⌘K opens over the composer's field. The pane the
    /// run opens is focused by its own `pane_open`, and the run raised no focus request, so the
    /// palette's close read "nothing moved" and handed the keyboard back to the composer. The
    /// pane acted on asks for the keyboard even when opening it already focused it (rule 6).
    @Test func aPaneThePaletteOpensAsksForTheKeyboardOnALanding() async throws {
        let w = await paletteWindow()
        let composer = ComposerModel(window: w.model, speech: SpeechRegistry(engines: []))
        await w.model.refreshContext()
        #expect(composer.focusToken == 1, "the launch onto the Landing gave the composer the keyboard")
        let entries = await w.model.paletteRootEntries(mode: .open) { _ in }
        let row = try #require(entries.first { $0.id == "newpane:editor" })
        let requests = w.model.keyboardFocusRequests

        #expect(await w.model.performPalette(.run(row.action)) == nil)

        let editor = try #require(w.model.layoutSnapshot.panes.first { $0.kind == "editor" })
        #expect(w.model.layoutSnapshot.focusedId == editor.id)
        #expect(w.model.keyboardFocusRequests != requests, "the palette's close must read the run as moving the keyboard")
        #expect(composer.focusToken == 1, "nothing hands the composer the keyboard")
        #expect(try await w.journal().filter { $0.action == "pane_focus" }.isEmpty, "asked without a dispatch")
    }

    /// An editor in focus puts the project's files first in Resources; with another pane focused the
    /// changed files keep the lead.
    @Test func fileRowsComeFirstInResourcesWhenAnEditorIsFocused() async throws {
        let fakeFiles = FakeFiles()
        await fakeFiles.setListing("/p/api", ["a.go"])
        let w = await paletteWindow(files: fakeFiles) { registry, panes, layout in
            await registerEditorActions(into: registry, panes: panes, layout: layout, files: fakeFiles, fileLists: nil,
                                        gitStatus: nil, roots: { ["/p/api", "/p/portal"] })
        }
        await w.model.refreshContext()
        func resourceKinds() async -> [String] {
            await w.model.paletteRootEntries(mode: .open) { _ in }.filter { $0.group == .resources }.map(\.kindLabel)
        }
        let editor = await w.layout.open(kind: "editor", title: "Editor")
        await w.model.refreshPanes()
        _ = await w.model.focusPane(id: editor.id)
        #expect(w.model.layoutSnapshot.focusedId == editor.id)
        #expect(await resourceKinds().first == "file")

        let terminal = await w.layout.open(kind: "terminal", title: "Terminal")
        await w.model.refreshPanes()
        _ = await w.model.focusPane(id: terminal.id)
        #expect(w.model.layoutSnapshot.focusedId == terminal.id)
        #expect(await resourceKinds().first == "git")
    }

    /// A file row opens in an editor pane (a new one when none exists) and focuses it.
    @Test func aFileRowOpensInANewEditorPaneAndFocusesIt() async throws {
        let fakeFiles = FakeFiles()
        await fakeFiles.put("/p/api/a.go", "package a")
        await fakeFiles.setListing("/p/api", ["a.go"])
        let w = await paletteWindow(files: fakeFiles) { registry, panes, layout in
            await registerEditorActions(into: registry, panes: panes, layout: layout, files: fakeFiles, fileLists: nil,
                                        gitStatus: nil, roots: { ["/p/api", "/p/portal"] })
        }
        await w.model.refreshContext()
        let rows = await w.model.paletteRootEntries(mode: .open) { _ in }
        let row = try #require(rows.first { $0.id == "editorfile:/p/api/a.go" })

        #expect(await w.model.performPalette(.run(row.action)) == nil)

        let editors = w.model.layoutSnapshot.panes.filter { $0.kind == "editor" }
        #expect(editors.count == 1)
        #expect(w.model.layoutSnapshot.focusedId == editors.first?.id)
    }

    /// ⌘P and ⌘K reach the window as tokens: two presses of the same key are two events, and
    /// each carries its mode.
    @Test func paletteKeysAreTokensCarryingTheirMode() async throws {
        let w = await paletteWindow()
        #expect(w.model.paletteKeyPress == nil)
        w.model.paletteKey(.open)
        let first = try #require(w.model.paletteKeyPress)
        w.model.paletteKey(.open)
        let second = try #require(w.model.paletteKeyPress)
        #expect(first.mode == .open && second.mode == .open)
        #expect(first != second)
        w.model.paletteKey(.commands)
        #expect(w.model.paletteKeyPress?.mode == .commands)
    }

    /// The plane's showing flag — what takes the keyboard from the panes under it — is set by
    /// opening and cleared by every close.
    @Test func showingFollowsOpenAndClose() async throws {
        let w = await paletteWindow()
        #expect(!w.model.paletteShowing)
        w.model.paletteOpened()
        #expect(w.model.paletteShowing)
        w.model.paletteClosed()
        #expect(!w.model.paletteShowing)
    }

    /// Spec 46, rule 6: a close that hands the keyboard back to the focused pane raises a
    /// window-local count the panes watch — and nothing else: the agent's focus-request count
    /// (`keyboardFocusRequests`, which a close compares to see whether a run moved focus) is
    /// untouched, and nothing is dispatched or journalled.
    @Test func returningTheKeyboardRaisesOnlyTheLocalCount() async throws {
        let w = await paletteWindow()
        let requests = w.model.keyboardFocusRequests
        let before = w.model.keyboardReturns
        w.model.returnKeyboardToFocusedPane()
        #expect(w.model.keyboardReturns == before + 1)
        #expect(w.model.keyboardFocusRequests == requests)
    }

    /// Where the keyboard goes on a close (rule 6). A SwiftUI-focused pane (the terminal, the
    /// git pane) holds the keyboard with the window's hosting view as AppKit's first responder,
    /// so handing that view back focuses nothing: the pane is asked instead.
    @Test func paletteFocusReturnByWhatHeldTheKeyboard() {
        #expect(PaletteFocusReturn.decide(restoringFocus: true, runMovedFocus: false, heldBy: .swiftUIFocus) == .focusedPane)
        #expect(PaletteFocusReturn.decide(restoringFocus: true, runMovedFocus: false, heldBy: .appKitView) == .responder)
        #expect(PaletteFocusReturn.decide(restoringFocus: true, runMovedFocus: false, heldBy: .nothing) == .leave)
        // A run that focused a pane already put the keyboard where it belongs.
        #expect(PaletteFocusReturn.decide(restoringFocus: true, runMovedFocus: true, heldBy: .swiftUIFocus) == .leave)
        #expect(PaletteFocusReturn.decide(restoringFocus: true, runMovedFocus: true, heldBy: .appKitView) == .leave)
        // A plane that takes over focuses its own field.
        #expect(PaletteFocusReturn.decide(restoringFocus: false, runMovedFocus: false, heldBy: .swiftUIFocus) == .leave)
        #expect(PaletteFocusReturn.decide(restoringFocus: false, runMovedFocus: false, heldBy: .appKitView) == .leave)
    }

    /// Spec 38: Switch environment… → `qa` dispatches `ctx_set_environment {name: qa}`, origin ui.
    @Test func switchEnvironmentDispatchesWithOriginUI() async throws {
        let w = await paletteWindow(register: { registry, _, _ in await registerEnvironmentSwitch(into: registry) })
        _ = await w.model.paletteRootEntries(mode: .commands) { _ in }

        #expect(await w.model.performPalette(.runCommand(commandId: "global.env", value: "qa")) == nil)

        let switches = try await w.journal().filter { $0.action == "ctx_set_environment" }
        #expect(switches.count == 1)
        #expect(switches.first?.origin == .ui)
        #expect(switches.first?.params == .object(["name": .string("qa")]))
        #expect(switches.first?.outcome == "ok")
    }

    /// Spec 38's second half, against the gate as it is (Decision D10, `writeGate`): a switch
    /// into production prices `.control` actions **for the agent only**; the operator's own
    /// switch — the context line's chooser — has never raised a plane. The palette must leave
    /// that unchanged in both directions: the operator's switch runs as the chooser's does, and
    /// the agent's identical call still parks for confirmation.
    @Test func switchingIntoProductionMeetsTheGateUnchanged() async throws {
        let w = await paletteWindow(register: { registry, _, _ in await registerEnvironmentSwitch(into: registry) })
        _ = await w.model.paletteRootEntries(mode: .commands) { _ in }

        #expect(await w.model.performPalette(.runCommand(commandId: "global.env", value: "production")) == nil)
        #expect(w.model.pending == nil)
        let ran = try await w.journal().filter { $0.action == "ctx_set_environment" }
        #expect(ran.map(\.outcome) == ["ok"])
        #expect(ran.first?.origin == .ui)

        await #expect(throws: ActionError.self) {
            try await w.registry.dispatch(
                name: "ctx_set_environment", params: .object(["name": .string("production")]),
                origin: .agent, caller: .test("staging"), confirmation: nil)
        }
    }

    /// Spec 39: `catalog api` → the API entry row → `api_open {entry: catalog}`, and the pane it
    /// opens is focused.
    @Test func catalogApiOpensTheApiPane() async throws {
        let http = paletteHTTP(["catalog", "billing"])
        let w = await paletteWindow(http: http, register: { registry, panes, layout in
            await registerApiActions(into: registry, panes: panes, layout: layout, http: http)
        })
        await w.model.refreshContext()
        let entries = await w.model.paletteRootEntries(mode: .open) { _ in }
        let row = try #require(PaletteSearch.rank(entries, query: "catalog api").first)
        #expect(row.id == "api:catalog")

        #expect(await w.model.performPalette(.run(row.action)) == nil)

        let opened = try await w.journal().filter { $0.action == "api_open" }
        #expect(opened.first?.params == .object(["entry": .string("catalog")]))
        let api = try #require(w.model.layoutSnapshot.panes.first { $0.kind == "api" })
        #expect(w.model.layoutSnapshot.focusedId == api.id)
    }

    /// Spec 40: a table row → `db_read_table {database, table}`, drawn in a focused pane.
    @Test func tableRowReadsTheTable() async throws {
        let db = PaletteDB(databases: ["core"], tables: ["core": ["bookings"]])
        let w = await paletteWindow(db: db, register: { registry, panes, layout in
            await registerStandardActions(
                into: registry, context: nil, panes: panes, db: db, resumes: ResumeBroker(), layout: layout)
        })
        await w.model.refreshContext()
        let entries = await w.model.paletteRootEntries(mode: .open) { _ in }
        let row = try #require(entries.first { $0.id == "table:core/bookings" })

        #expect(await w.model.performPalette(.run(row.action)) == nil)

        let read = try await w.journal().filter { $0.action == "db_read_table" }
        #expect(read.first?.params == .object(["database": .string("core"), "table": .string("bookings")]))
        #expect(read.first?.origin == .ui)
        let pane = try #require(w.model.layoutSnapshot.panes.first { $0.kind == "db" })
        #expect(w.model.layoutSnapshot.focusedId == pane.id)
        #expect(await db.count("read_table") == 1)
    }

    /// Spec 41: the palette registers nothing. **Update these two sets when a branch adds an
    /// action on purpose** — they were captured from the shipped registry (`WakilWiring.build`)
    /// before the palette was wired, and a palette-only action appearing here is the failure.
    @Test func agentToolListUnchanged() async throws {
        let dir = testScratchRoot.appendingPathComponent(UUID().uuidString)
        let bin = dir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let wiring = await WakilWiring.build(
            journalDirectory: dir, sessionId: "palette-tools", executableDirectory: bin,
            environment: ["HOME": dir.path, "WAKIL_BIN_DIR": bin.path])
        await wiring.shutdown()
        let all = await wiring.registry.all()

        #expect(Set(all.map(\.name)) == registeredBeforeThePalette)
        #expect(Set(agentAllowedTools(actions: all)) == agentToolsBeforeThePalette)
    }

    /// Rule 8: a failed run answers its whole error.
    @Test func failedDispatchReturnsTheWholeError() async throws {
        let whole = "db_refetch: connection refused: dial tcp 10.0.0.4:5432: i/o timeout (after 3 retries)"
        struct Refused: Error, CustomStringConvertible { let description: String }
        let w = await paletteWindow(register: { registry, _, _ in
            await registry.register(Action(
                name: "db_refetch", description: "", kind: .read, schema: .object([:]),
                handler: { _ in throw Refused(description: whole) }))
        })
        _ = await w.model.paletteRootEntries(mode: .commands) { _ in }

        let error = await w.model.performPalette(.run(.dispatch(action: "db_refetch", params: .object(["pane": .string("p1")]))))

        #expect(error == whole)
    }

    /// Review Focus 3: entries built for one project never run in another.
    @Test func staleContextIsRefused() async throws {
        let w = await paletteWindow()
        await w.model.refreshContext()
        _ = await w.model.paletteRootEntries(mode: .open) { _ in }
        await w.context.switchTo(project: "q", roots: ["/q/web"])
        await w.model.refreshContext()
        let before = try await w.journal().count

        let error = await w.model.performPalette(.run(.dispatch(action: "pane_open", params: .object(["kind": .string("editor")]))))

        #expect(error == "the palette was opened for acme/p in staging; reopen it")
        #expect(try await w.journal().count == before)
        #expect(w.model.layoutSnapshot.panes.isEmpty)
    }

    /// P5: a provider switch runs `setProvider`, so its refusals still answer — here, a turn
    /// in flight — and nothing is dispatched behind them.
    @Test func providerSwitchStillGoesThroughSetProvider() async throws {
        let w = await paletteWindow(harness: HangingHarness())
        Task { await w.model.send("this turn never finishes") }
        #expect(await apiEventually { w.model.turnInFlight })
        _ = await w.model.paletteRootEntries(mode: .commands) { _ in }

        let fromCommand = await w.model.performPalette(.runCommand(commandId: "global.provider", value: "work"))
        let fromRow = await w.model.performPalette(.run(.setProvider("work")))

        #expect(fromCommand == "set provider work: a turn is in flight — wait for it to finish")
        #expect(fromRow == fromCommand)
        #expect(try await w.journal().allSatisfy { $0.action != "ctx_set_provider" })
    }

    // MARK: Fix round 1

    /// A drill step read in p keeps its rows after a switch to q and a fresh root list; its row
    /// must still be refused, because the step — not the root — is what the row came from.
    @Test func aDrilledRowFromAnotherProjectIsRefused() async throws {
        let db = PaletteDB(databases: ["core"], tables: ["core": ["bookings"]])
        let w = await paletteWindow(db: db, register: { registry, panes, layout in
            await registerStandardActions(
                into: registry, context: nil, panes: panes, db: db, resumes: ResumeBroker(), layout: layout)
        })
        await w.model.refreshContext()
        _ = await w.model.paletteRootEntries(mode: .open) { _ in }
        let rows = await w.model.paletteChoices(for: "drill:tables:core")
        let row = try #require(rows.first)
        await w.context.switchTo(project: "q", roots: ["/q/web"])
        await w.model.refreshContext()
        _ = await w.model.paletteRootEntries(mode: .open) { _ in }
        let before = try await w.journal().count

        let error = await w.model.performPalette(.run(row.action, step: "drill:tables:core"))

        #expect(error == "the palette was opened for acme/p in staging; reopen it")
        #expect(try await w.journal().count == before)
    }

    /// The same for a choice step: an environment list read in p never switches q.
    @Test func aChoiceFromAnotherProjectIsRefused() async throws {
        let w = await paletteWindow(register: { registry, _, _ in await registerEnvironmentSwitch(into: registry) })
        await w.model.refreshContext()
        _ = await w.model.paletteRootEntries(mode: .commands) { _ in }
        _ = await w.model.paletteChoices(for: "global.env")
        await w.context.switchTo(project: "q", roots: ["/q/web"])
        await w.model.refreshContext()
        _ = await w.model.paletteRootEntries(mode: .commands) { _ in }
        let before = try await w.journal().count

        let error = await w.model.performPalette(.runCommand(commandId: "global.env", value: "qa"))

        #expect(error == "the palette was opened for acme/p in staging; reopen it")
        #expect(try await w.journal().count == before)
    }

    /// Spec §7, rule 6: the pane acted on is focused even when nothing opens.
    @Test func theActedOnPaneIsFocused() async throws {
        let w = await paletteWindow(editorGit: true)
        await w.model.refreshContext()
        await w.model.openPane(kind: "editor")
        let editor = try #require(w.model.layoutSnapshot.focusedId)
        await w.model.openPane(kind: "db")
        #expect(w.model.layoutSnapshot.focusedId != editor)
        let entries = await w.model.paletteRootEntries(mode: .open) { _ in }
        let row = try #require(entries.first { $0.id == "file:changed:/p/api/a.txt" })

        #expect(await w.model.performPalette(.run(row.action)) == nil)

        #expect(try await w.journal().contains { $0.action == "editor_changes_select" && $0.outcome == "ok" })
        #expect(w.model.layoutSnapshot.focusedId == editor)
    }

    /// Opening the palette reads; it never writes the window's status — not even when a read
    /// fails.
    @Test func openingThePaletteLeavesTheStatusAlone() async throws {
        struct Refused: Error, CustomStringConvertible { let description: String }
        let w = await paletteWindow(register: { registry, _, _ in
            await registry.register(Action(
                name: "db_refetch", description: "", kind: .read, schema: .object([:]),
                handler: { _ in throw Refused(description: "db_refetch: the operator's own error") }))
            await registry.register(Action(
                name: "ctx_list_environments", description: "", kind: .read, schema: .object([:]),
                handler: { _ in throw Refused(description: "ctx_list_environments: down") }))
        })
        _ = await w.model.performPalette(.run(.dispatch(action: "db_refetch", params: .object([:]))))
        let status = w.model.status
        #expect(status == "db_refetch: the operator's own error")

        _ = await w.model.paletteRootEntries(mode: .commands) { _ in }
        _ = await w.model.paletteRootEntries(mode: .open) { _ in }
        _ = await w.model.paletteChoices(for: "global.env")

        #expect(w.model.status == status)
    }

    /// Two opens racing: the older one finishing last must not leave its context behind.
    @Test func anOlderOpenFinishingLastDoesNotWin() async throws {
        let gate = SourceGateBox()
        let w = await paletteWindow(register: { registry, _, _ in
            await registry.register(Action(
                name: "ctx_list_environments", description: "", kind: .read, schema: .object([:]),
                handler: { _ in
                    await gate.waitIfFirst()
                    return .object(["structuredContent": .object(["environments": .object([:])])])
                }))
        })
        await w.model.refreshContext()
        let older = Task { await w.model.paletteRootEntries(mode: .commands) { _ in } }
        #expect(await apiEventually { await gate.parked })
        await w.context.switchTo(project: "q", roots: ["/q/web"])
        await w.model.refreshContext()
        _ = await w.model.paletteRootEntries(mode: .commands) { _ in }
        await gate.release()
        _ = await older.value

        #expect(await w.model.performPalette(.run(.dispatch(action: "pane_open", params: .object(["kind": .string("editor")])))) == nil)
    }

    /// A run cancelled from elsewhere answers nothing — not an older error still in `status`.
    @Test func aCancelledRunDoesNotAnswerAnOlderError() async throws {
        struct Refused: Error, CustomStringConvertible { let description: String }
        let w = await paletteWindow(register: { registry, _, _ in
            await registry.register(Action(
                name: "db_refetch", description: "", kind: .read, schema: .object([:]),
                handler: { _ in throw Refused(description: "db_refetch: older") }))
            await registry.register(Action(
                name: "db_page", description: "", kind: .read, schema: .object([:]),
                handler: { _ in throw CancellationError() }))
        })
        #expect(await w.model.performPalette(.run(.dispatch(action: "db_refetch", params: .object([:])))) == "db_refetch: older")

        #expect(await w.model.performPalette(.run(.dispatch(action: "db_page", params: .object([:])))) == nil)
    }

    /// A Send request dies with its pane, and with the canvas it was asked on.
    @Test func sendRequestsAreClearedOnCloseAndScopeChange() async throws {
        let w = await paletteWindow()
        await w.model.refreshContext()
        await w.model.openPane(kind: "api")
        let api = try #require(w.model.layoutSnapshot.focusedId)
        _ = await w.model.paletteRootEntries(mode: .commands) { _ in }
        _ = await w.model.performPalette(.run(.dispatch(action: "window.apiSend", params: .object(["pane": .string(api)]))))
        #expect(w.model.apiSendRequest(pane: api) != nil)
        await w.model.closePane(id: api)
        #expect(w.model.apiSendRequest(pane: api) == nil, "closed with its pane")

        await w.model.openPane(kind: "api")
        let again = try #require(w.model.layoutSnapshot.focusedId)
        _ = await w.model.paletteRootEntries(mode: .commands) { _ in }
        _ = await w.model.performPalette(.run(.dispatch(action: "window.apiSend", params: .object(["pane": .string(again)]))))
        await w.context.switchTo(project: "q", roots: ["/q/web"])
        await w.model.refreshContext()
        #expect(w.model.apiSendRequests.isEmpty, "cleared with the canvas")
    }

    // MARK: P5 / P6 / P7

    /// P5: Send runs the api pane's own Send — the window asks the pane, which flushes its held
    /// fields and picks the action — and is never dispatched bare.
    @Test func sendAsksTheApiPaneToPressItsOwnSend() async throws {
        let w = await paletteWindow()
        _ = await w.model.paletteRootEntries(mode: .commands) { _ in }
        let before = try await w.journal().count

        #expect(w.model.apiSendRequest(pane: "api-1") == nil)
        #expect(await w.model.performPalette(.run(.dispatch(action: "window.apiSend", params: .object(["pane": .string("api-1")])))) == nil)
        let first = try #require(w.model.apiSendRequest(pane: "api-1"))
        _ = await w.model.performPalette(.run(.dispatch(action: "window.apiSend", params: .object(["pane": .string("api-1")]))))

        #expect(w.model.apiSendRequest(pane: "api-1") != first, "each press is an event of its own")
        #expect(try await w.journal().count == before, "nothing reached the registry")
    }

    /// P6: Close pane runs what the pane's own close control runs.
    @Test func closePaneClosesTheFocusedPane() async throws {
        let w = await paletteWindow()
        await w.model.refreshContext()
        await w.model.openPane(kind: "db")
        let pane = try #require(w.model.layoutSnapshot.focusedId)
        _ = await w.model.paletteRootEntries(mode: .commands) { _ in }
        let close = try #require(CommandCatalog.entries(for: await w.model.paletteContext()).first { $0.id == "db.close" })

        #expect(await w.model.performPalette(.run(close.action)) == nil)

        #expect(w.model.layoutSnapshot.panes.allSatisfy { $0.id != pane })
        #expect(try await w.journal().last?.action == "pane_close")
    }

    /// P7 (c), 3b-iii: a changed file chosen with no editor pane open opens one, with the file's
    /// diff tab, and focuses it.
    @Test func aChangedFileWithNoEditorPaneOpensOneWithItsDiffTab() async throws {
        let w = await paletteWindow(editorGit: true)
        await w.model.refreshContext()
        let entries = await w.model.paletteRootEntries(mode: .open) { _ in }
        let row = try #require(entries.first { $0.id == "file:changed:/p/api/a.txt" })
        #expect(row.action == .dispatch(action: "editor_changes_select", params: .object([
            "root": .string("/p/api"), "path": .string("a.txt"), "group": .string("changed"),
        ])))

        #expect(await w.model.performPalette(.run(row.action)) == nil)

        let pane = try #require(w.model.layoutSnapshot.panes.first { $0.kind == "editor" })
        #expect(w.model.layoutSnapshot.focusedId == pane.id)
        let tabs = await w.panes.editorSnapshot(paneId: pane.id).tabs
        #expect(tabs.map(\.subject) == [.diff(root: "/p/api", path: "a.txt", group: .changed)])
        #expect(try await w.journal().contains { $0.action == "editor_changes_select" && $0.outcome == "ok" })
    }

    /// P7 (b): the table cache never answers across projects.
    @Test func theTableCacheIsPerProject() async throws {
        let db = PaletteDB(databases: ["core"], tables: ["core": ["bookings"]])
        let w = await paletteWindow(db: db)
        await w.model.refreshContext()
        _ = await w.model.paletteRootEntries(mode: .open) { _ in }
        #expect(await db.count("list_databases") == 1)

        await w.context.switchTo(project: "q", roots: ["/q/web"])
        await w.model.refreshContext()
        await db.set(tables: ["core": ["invoices"]])
        let entries = await w.model.paletteRootEntries(mode: .open) { _ in }

        #expect(entries.contains { $0.id == "table:core/invoices" })
        #expect(!entries.contains { $0.id == "table:core/bookings" }, "p's tables answered in q")
    }

    /// P7 (d): a ⌘P answered from the cache asks again in the background and delivers the fresh
    /// rows through `onLate`.
    @Test func aCachedOpenRefreshesInTheBackground() async throws {
        let db = PaletteDB(databases: ["core"], tables: ["core": ["bookings"]])
        let w = await paletteWindow(db: db)
        await w.model.refreshContext()
        _ = await w.model.paletteRootEntries(mode: .open) { _ in }
        await db.set(tables: ["core": ["bookings", "invoices"]])

        let late = LateBox()
        let cached = await w.model.paletteRootEntries(mode: .open) { rows in Task { await late.add(rows) } }

        #expect(!cached.contains { $0.id == "table:core/invoices" }, "the open answers from the cache")
        #expect(await apiEventually {
            await late.deliveries.last?.contains { $0.id == "table:core/invoices" } ?? false
        })
        let fresh = try #require(await late.deliveries.last)
        #expect(fresh.contains { $0.id == "newpane:editor" }, "the refresh replaces the tables, not the list")
    }

    /// P7 (a): a late result from a palette that has since closed is dropped.
    @Test func aLateResultAfterCloseIsDropped() async throws {
        let db = PaletteDB(databases: ["core"], tables: ["core": ["bookings"]])
        let w = await paletteWindow(db: db)
        await w.model.refreshContext()
        _ = await w.model.paletteRootEntries(mode: .open) { _ in }
        await db.set(tables: ["core": ["bookings", "invoices"]])
        await db.hold()

        let late = LateBox()
        _ = await w.model.paletteRootEntries(mode: .open) { rows in Task { await late.add(rows) } }
        #expect(await apiEventually { await db.count("list_databases") == 2 }, "the background refresh started")
        w.model.paletteClosed()
        await db.release()

        #expect(await apiEventually { await db.count("list_tables") == 2 }, "the refresh finished")
        try await Task.sleep(for: .milliseconds(100))
        #expect(await late.deliveries.isEmpty)
    }

    /// P7 (a): a newer open supersedes an older one's late rows the same way.
    @Test func aLateResultFromAnOlderOpenIsDropped() async throws {
        let db = PaletteDB(databases: ["core"], tables: ["core": ["bookings"]])
        let w = await paletteWindow(db: db)
        await w.model.refreshContext()
        _ = await w.model.paletteRootEntries(mode: .open) { _ in }
        await db.hold()

        let older = LateBox()
        _ = await w.model.paletteRootEntries(mode: .open) { rows in Task { await older.add(rows) } }
        #expect(await apiEventually { await db.count("list_databases") == 2 })
        _ = await w.model.paletteRootEntries(mode: .commands) { _ in }
        await db.release()

        #expect(await apiEventually { await db.count("list_tables") >= 2 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(await older.deliveries.isEmpty)
    }

    /// Invariant 4: an org switch leaves nothing the palette read in the outgoing organisation —
    /// no step stamps, no built-for context or identity, no last list, no fresh tables, no table
    /// cache — and a row still on screen is refused rather than run. (A pending Send belongs to
    /// the canvas, and goes with the swap off it: `activateLayout`.)
    @Test func anOrgSwitchEmptiesThePalettesCache() async throws {
        let db = PaletteDB(databases: ["core"], tables: ["core": ["bookings"]])
        let w = await paletteWindow(db: db)
        await w.model.refreshContext()
        _ = await w.model.paletteRootEntries(mode: .open) { _ in }
        let late = LateBox()
        _ = await w.model.paletteRootEntries(mode: .open) { rows in Task { await late.add(rows) } }
        #expect(await apiEventually { await !late.deliveries.isEmpty }, "the background refresh landed")
        _ = await w.model.paletteChoices(for: "drill:tables:core")
        _ = await w.model.performPalette(.run(.dispatch(action: "window.apiSend", params: .object(["pane": .string("api-1")]))))

        let seeded = w.model.paletteCacheForTesting
        #expect(seeded.builtFor != nil && seeded.builtIn != nil && !seeded.stepStamps.isEmpty)
        #expect(!seeded.builds.isEmpty)
        #expect(seeded.latest != nil && seeded.freshTables != nil && !seeded.tableCacheKeys.isEmpty)
        #expect(!w.model.apiSendRequests.isEmpty)

        await w.model.invalidateForOrgChange()
        w.model.setOrganizationForTesting("beta")
        let before = try await w.journal().count

        let left = w.model.paletteCacheForTesting
        #expect(left.builtFor == nil)
        #expect(left.builtIn == .organisationLeft, "names no organisation, and matches none")
        #expect(!left.building && left.builds.isEmpty)
        #expect(left.stepStamps.isEmpty)
        #expect(left.latest == nil && left.freshTables == nil)
        #expect(left.tableCacheKeys.isEmpty)
        let error = await w.model.performPalette(
            .run(.dispatch(action: "pane_open", params: .object(["kind": .string("editor")])), step: "drill:tables:core"))
        #expect(error == "the organisation changed under the palette; reopen it")
        #expect(try await w.journal().count == before)
    }

    /// P7 (e): a project choice lists the current organisation's projects, through the same
    /// reader ⌘P's Projects group uses.
    @Test func projectChoicesAreTheCurrentOrganisations() async throws {
        let w = await paletteWindow(register: { registry, _, _ in
            await registry.register(Action(
                name: "ctx_list_projects", description: "", kind: .read, schema: .object([:]),
                handler: { _ in .object(["structuredContent": .object(["projects": .object([
                    "p": .object(["path": .string("/p")]), "q": .object(["path": .string("/q")]),
                ])])]) }))
        })
        await w.model.refreshContext()

        let choices = await w.model.paletteChoices(for: "global.project")

        #expect(choices.map(\.id) == ["p", "q"])
    }

    /// A database row's drill step lists that database's tables.
    @Test func aDatabaseDrillListsItsTables() async throws {
        let db = PaletteDB(databases: ["core", "audit"], tables: ["core": ["bookings"], "audit": ["events"]])
        let w = await paletteWindow(db: db)
        await w.model.refreshContext()
        _ = await w.model.paletteRootEntries(mode: .open) { _ in }

        let tables = await w.model.paletteChoices(for: "drill:tables:audit")

        #expect(tables.map(\.id) == ["table:audit/events"])
    }

    // MARK: Final fix wave

    /// Item 1: a refresh in a new environment does not re-stamp the rows still on screen. The old
    /// list was read in `staging`; while `qa`'s list loads, Return on its table row must be refused,
    /// not run as `db_read_table` in `qa` — and it stays refused once `qa`'s list has landed, since
    /// the rows on screen are the generation the controller names.
    @Test func anOldRowIsRefusedWhileTheNewEnvironmentsListLoads() async throws {
        let db = PaletteDB(databases: ["core"], tables: ["core": ["bookings"]])
        let w = await paletteWindow(db: db, register: { registry, panes, layout in
            await registerStandardActions(
                into: registry, context: nil, panes: panes, db: db, resumes: ResumeBroker(), layout: layout)
        })
        await w.model.refreshContext()
        let shown = await w.model.paletteRoot(mode: .open) { _ in }
        let row = try #require(shown.rows.first { $0.id == "table:core/bookings" })
        await w.context.switchTo(environment: "qa")
        await w.model.refreshContext()
        #expect(w.model.environment == "qa")
        let listed = await db.count("list_databases")
        await db.holdNext()
        let refresh = Task { await w.model.paletteRoot(mode: .open) { _ in } }
        #expect(await apiEventually { await db.count("list_databases") == listed + 1 }, "qa's list is loading")
        // What ran, not how many entries: under a loaded full suite a background refresh's own
        // dispatch can land in the journal mid-test, which a count would blame on the old row.
        let ranInQA = { try await w.journal().contains { $0.action == "db_read_table" && $0.environment == "qa" } }

        let loading = await w.model.performPalette(.run(row.action), shown: shown.generation)

        #expect(loading == "the palette was opened for acme/p in staging; reopen it")
        #expect(try await !ranInQA(), "nothing ran in qa")

        await db.release()
        let fresh = await refresh.value
        let landed = await w.model.performPalette(.run(row.action), shown: shown.generation)
        #expect(landed == "the palette was opened for acme/p in staging; reopen it", "still the staging rows")
        #expect(try await !ranInQA())
        let qaRow = try #require(fresh.rows.first { $0.id == "table:core/bookings" })
        #expect(await w.model.performPalette(.run(qaRow.action), shown: fresh.generation) == nil, "qa's own row runs")
    }

    /// Item 2 (spec rule 9, rule 2): a typed cURL is this window's recent across a close — run, or
    /// abandoned by Esc or by closing — and an organisation switch leaves none behind.
    @Test func aTypedCurlIsARecentAcrossClosesAndGoneAfterAnOrgSwitch() async throws {
        let w = await paletteWindow()
        let api = PaletteContext(focusedPane: FocusedPane(id: "api-1", kind: "api"))
        func openCurlStep() throws -> PaletteModel {
            var p = w.model.makePalette(mode: .commands)
            p.rootEntries = CommandCatalog.entries(for: api)
            let i = try #require(p.results.firstIndex { $0.id == "api.curl" })
            p.move(i)
            #expect(p.confirm() == nil, "a text step pushes without asking for choices")
            #expect(p.steps.last?.commandId == "api.curl")
            return p
        }
        let epoch = w.model.paletteEpoch

        var ran = try openCurlStep()
        #expect(ran.results.isEmpty, "nothing typed yet")
        ran.type("curl https://ran.example")
        #expect(ran.confirm() == .runCommand(commandId: "api.curl", value: "curl https://ran.example"))
        w.model.keepPaletteRecents(ran.recents, openedAt: epoch)

        var popped = try openCurlStep()
        #expect(popped.results.map(\.title) == ["curl https://ran.example"])
        popped.type("curl https://popped.example")
        #expect(popped.escape() == nil)
        w.model.keepPaletteRecents(popped.recents, openedAt: epoch)

        var closed = try openCurlStep()
        closed.type("curl https://closed.example")
        closed.closing()
        w.model.keepPaletteRecents(closed.recents, openedAt: epoch)

        let reopened = try openCurlStep()
        #expect(reopened.results.map(\.title)
            == ["curl https://closed.example", "curl https://popped.example", "curl https://ran.example"])

        await w.model.invalidateForOrgChange()
        #expect(w.model.paletteRecents.isEmpty)
        #expect(try openCurlStep().results.isEmpty, "no recent crosses an organisation")
        w.model.keepPaletteRecents(reopened.recents, openedAt: epoch)
        #expect(w.model.paletteRecents.isEmpty, "a palette opened in the old org writes nothing back")
    }

    /// Item 5 (rule 8): an environment listing that fails keeps *Switch environment…* in ⌘K, and
    /// its step shows the failure whole as one row that never runs.
    @Test func aFailedEnvironmentListingIsShownNotHidden() async throws {
        struct Refused: Error, CustomStringConvertible { let description: String }
        let w = await paletteWindow(register: { registry, _, _ in
            await registry.register(Action(
                name: "ctx_list_environments", description: "", kind: .read, schema: .object([:]),
                handler: { _ in throw Refused(description: "config.json: permission denied (open /home/x/.wakil)") }))
        })
        await w.model.refreshContext()

        let root = await w.model.paletteRootEntries(mode: .commands) { _ in }
        #expect(root.contains { $0.id == "global.env" }, "the command stays")

        let choices = await w.model.paletteChoices(for: "global.env")
        #expect(choices.count == 1)
        let error = try #require(choices.first)
        #expect(error.isError)
        #expect(error.subtitle.contains("config.json: permission denied (open /home/x/.wakil)"))
    }

    /// Rule 6: a run that outlives its palette does not move the keyboard. The operator closed it
    /// and went to the Database pane while the new editor pane's status was still being read; the
    /// select still lands, but focus stays where the operator put it.
    @Test func aRunFinishingAfterTheCloseLeavesFocusAlone() async throws {
        let w = await paletteWindow(editorGit: true)
        await w.model.refreshContext()
        await w.model.openPane(kind: "db")
        let db = try #require(w.model.layoutSnapshot.focusedId)
        _ = await w.model.paletteRootEntries(mode: .open) { _ in }
        await w.git.setSlowStatus(true)
        w.model.paletteOpened()
        let run = Task {
            await w.model.performPalette(.run(.dispatch(action: "editor_changes_select", params: .object([
                "root": .string("/p/api"), "path": .string("a.txt"), "group": .string("changed"),
            ]))))
        }
        #expect(await apiEventually { w.model.layoutSnapshot.panes.contains { $0.kind == "editor" } })
        w.model.paletteClosed()
        #expect(await w.model.focusPane(id: db))
        for call in 0..<16 { await w.git.releaseStatus(call) }
        _ = await run.value

        #expect(w.model.layoutSnapshot.focusedId == db)
    }

    /// Conversations 2 of 3, Task 3: with nothing live, ⌘P draws no Running group — not an empty
    /// header, not a loading row.
    @Test func nothingLiveDrawsNoRunningGroup() async throws {
        let w = await paletteWindow()
        await w.model.refreshContext()
        let entries = await w.model.paletteRootEntries(mode: .open) { _ in }
        #expect(!entries.isEmpty)
        #expect(!entries.contains { $0.group == .running }, "\(entries.map(\.id))")
    }

    /// Defence in depth: a step with no stamp after the window left an organisation is refused,
    /// even once a root list has been built in the new one.
    @Test func anUnstampedStepAfterAnOrgSwitchIsRefused() async throws {
        let db = PaletteDB(databases: ["core"], tables: ["core": ["bookings"]])
        let w = await paletteWindow(db: db)
        await w.model.refreshContext()
        _ = await w.model.paletteRootEntries(mode: .open) { _ in }
        let rows = await w.model.paletteChoices(for: "drill:tables:core")
        let row = try #require(rows.first)

        await w.model.invalidateForOrgChange()
        w.model.setOrganizationForTesting("beta")
        _ = await w.model.paletteRootEntries(mode: .commands) { _ in }
        let before = try await w.journal().count

        let error = await w.model.performPalette(.run(row.action, step: "drill:tables:core"))

        #expect(error == "the organisation changed under the palette; reopen it")
        #expect(try await w.journal().count == before)
    }
}

/// Every action the shipped registry held before the palette was wired.
private let registeredBeforeThePalette: Set<String> = [
    "editor_refresh",
    "editor_tree", "editor_tree_expand", "editor_tree_collapse", "editor_tree_reveal", "editor_move_tab",
    // 3b-iii: the Changes view's four, all agent-reachable.
    "editor_changes_select", "editor_changes_step", "editor_changes_collapse", "editor_changes_expand",
    // 3a-ii review I2: a group collapses as a root does.
    "editor_changes_group_collapse", "editor_changes_group_expand",
    // 3a-ii: the seven git writes, agent-reachable mutations.
    "editor_changes_stage", "editor_changes_unstage", "editor_changes_discard", "editor_changes_commit", "editor_changes_branch_create", "editor_changes_branch_delete", "editor_changes_branch_rename", "editor_changes_branches", "editor_changes_stash", "editor_changes_stash_apply", "editor_changes_stash_drop", "editor_changes_stash_drop_all", "editor_changes_stash_pop", "editor_changes_stashes", "editor_changes_switch", "editor_open_stash_diff", "editor_timeline", "editor_blame", "editor_open_commit_diff", "editor_changes_amend", "editor_changes_undo_commit", "editor_changes_stage_hunk",
    // 3a-ii-b: range staging, agent-reachable mutations.
    "editor_changes_stage_ranges", "editor_changes_unstage_ranges",
    // 3a-ii-b: the ✨ draft, a control action (it fills Wakil's own box).
    "editor_changes_draft_message",
    // 3a-iii-a: the remote operations, agent-reachable mutations priced allow.
    "editor_changes_fetch", "editor_changes_pull", "editor_changes_push", "editor_changes_sync", "editor_changes_publish",
    // 3a-v-b: merge, rebase and resolving, agent-reachable mutations (abort, skip, take and undo apply gated for the agent).
    "editor_changes_merge", "editor_changes_rebase", "editor_changes_continue", "editor_changes_skip", "editor_changes_abort",
    "editor_changes_take", "editor_changes_keep_file", "editor_changes_stash_undo_apply",
    "editor_clone",
    "editor_peek", "editor_peek_step", "editor_peek_close",
    "editor_find", "editor_search", "files_search",
    // 3b-iv: file operations in the tree, all agent-reachable mutations.
    "editor_create", "editor_rename", "editor_trash",
    "editor_open", "editor_open_file", "editor_new_scratch", "editor_focus_tab", "editor_close", "editor_goto", "editor_select", "editor_set_language", "editor_replace_range", "editor_save", "editor_reload", "editor_restore", "editor_replace", "editor_replace_undo",
    // 3a-v-b: the conflict blocks in a conflicted file's tab.
    "editor_conflict_accept", "editor_conflict_next", "editor_conflict_previous", "editor_conflict_compare",
    // 3c-i: the browser's actions; browser_restore is the window's own (operator-only).
    "browser_back", "browser_bookmark", "browser_clear_data", "browser_close_tab", "browser_download_cancel", "browser_downloads_clear", "browser_find", "browser_find_close", "browser_find_step", "browser_focus_address", "browser_forward", "browser_move_tab", "browser_navigate", "browser_new_tab", "browser_open", "browser_password_delete", "browser_password_fill", "browser_password_never", "browser_password_save", "browser_password_suggest", "browser_print", "browser_reload", "browser_reopen_tab", "browser_restore", "browser_select_tab", "browser_stop", "browser_zoom",
    // 3c-ii: the agent's reach into the page; the five acts are mutations, revoke_site the operator's.
    "browser_read_page", "browser_click", "browser_type", "browser_select", "browser_press", "browser_scroll",
    "browser_revoke_site",
    "api_bind", "api_cancel", "api_fill_from_curl", "api_open", "api_render_curl", "api_reopen",
    "api_remove_entry", "api_request", "api_send", "api_set_entry", "api_set_request", "api_unbind", "api_undo_fill", "api_update_entry",
    // Provider capacity, on purpose: the operator-only record path and the agent's read.
    "capacity_record", "ctx_capacity",
    "ctx_add_provider", "ctx_adopt_provider", "ctx_config_tree", "ctx_create_org", "ctx_list_accounts",
    "ctx_create_environment", "ctx_create_project", "ctx_remove_environment", "ctx_remove_project",
    "ctx_rename_environment", "ctx_rename_project",
    // 3b-v (Decision 38): the editor settings read, and the two operator-only writes.
    "ctx_editor_settings", "ctx_set_editor_settings", "ctx_set_project_editor_settings",
    // 3c-i: the browser settings read, and the operator-only write.
    "ctx_browser_settings", "ctx_set_browser_settings",
    // 3b-viii (Decision 42): the operator-only write for a local model endpoint.
    "ctx_set_local_provider",
    "ctx_list_environments", "ctx_list_machine_providers", "ctx_list_orgs", "ctx_list_projects",
    "ctx_list_providers", "ctx_provider_login", "ctx_set_environment", "ctx_set_project",
    "ctx_set_provider", "ctx_unlink_provider", "ctx_update_org",
    // 3a-iii-a: the git account tools, operator-only.
    "ctx_git_account_add", "ctx_git_account_remove", "ctx_git_host_suggestions",
    "ctx_git_ssh_keys", "ctx_git_key_generate", "ctx_git_token_set", "ctx_git_key_passphrase_set", "ctx_git_account_test",
    "ctx_git_device_start", "ctx_git_device_poll", "ctx_git_gh_logins", "ctx_git_gh_import",
    "ctx_set_project_agent_instructions",
    "db_cancel", "db_classify_statement", "db_describe_table", "db_list_databases", "db_list_tables", "db_page",
    "db_read_table", "db_refetch", "db_remove_database", "db_update_database", "db_render_update", "db_run_mutation",
    "db_run_query", "db_set_connection", "db_set_dsn",
    "pane_close", "pane_focus", "pane_maximize", "pane_move", "pane_open", "pane_resize", "pane_restore",
    "pane_scroll_clear", "pane_scroll_to_row", "pane_select_cell", "pane_select_rows",
    "pane_set_column_width", "pane_set_density", "pane_snap", "pane_sort",
    "session_close", "session_get", "session_list", "session_new", "session_read", "session_record_parent", "session_resume",
    "session_set_provider", "session_switch", "settings_open", "term_open", "term_propose", "term_run", "term_scroll",
]

/// The agent's `--allowedTools`, captured at the same moment.
private let agentToolsBeforeThePalette: Set<String> = [
    "mcp__wakil__editor_refresh",
    // 3b-v (Decision 38): the read only; both writes are operator-only and absent.
    "mcp__wakil__ctx_editor_settings",
    "mcp__wakil__ctx_browser_settings",
    "mcp__wakil__editor_tree", "mcp__wakil__editor_tree_expand", "mcp__wakil__editor_tree_collapse",
    "mcp__wakil__editor_move_tab", "mcp__wakil__editor_tree_reveal",
    "mcp__wakil__editor_changes_select", "mcp__wakil__editor_changes_step",
    // 3a-iv: the branch and stash lists; their writes are mutations, reached through the gate.
    "mcp__wakil__editor_changes_branches", "mcp__wakil__editor_changes_stashes", "mcp__wakil__editor_open_stash_diff",
    "mcp__wakil__editor_timeline", "mcp__wakil__editor_blame", "mcp__wakil__editor_open_commit_diff",
    "mcp__wakil__editor_changes_collapse", "mcp__wakil__editor_changes_expand",
    "mcp__wakil__editor_changes_group_collapse", "mcp__wakil__editor_changes_group_expand",
    // 3a-ii-b: the ✨ draft, .control, so published.
    "mcp__wakil__editor_changes_draft_message",
    "mcp__wakil__editor_peek", "mcp__wakil__editor_peek_step", "mcp__wakil__editor_peek_close",
    "mcp__wakil__editor_find", "mcp__wakil__editor_search", "mcp__wakil__files_search",
    "mcp__wakil__editor_open", "mcp__wakil__editor_open_file", "mcp__wakil__editor_new_scratch", "mcp__wakil__editor_focus_tab", "mcp__wakil__editor_close", "mcp__wakil__editor_goto", "mcp__wakil__editor_select", "mcp__wakil__editor_set_language", "mcp__wakil__editor_replace_range", "mcp__wakil__editor_reload", "mcp__wakil__editor_restore",
    "mcp__wakil__editor_conflict_accept", "mcp__wakil__editor_conflict_next", "mcp__wakil__editor_conflict_previous", "mcp__wakil__editor_conflict_compare",
    "mcp__wakil-git", "mcp__wakil-pm", "mcp__wakil-recall",
    // 3c-i: every browser action but browser_restore.
    "mcp__wakil__browser_back", "mcp__wakil__browser_bookmark", "mcp__wakil__browser_close_tab", "mcp__wakil__browser_download_cancel", "mcp__wakil__browser_downloads_clear", "mcp__wakil__browser_find", "mcp__wakil__browser_find_close", "mcp__wakil__browser_find_step", "mcp__wakil__browser_focus_address", "mcp__wakil__browser_forward", "mcp__wakil__browser_move_tab", "mcp__wakil__browser_navigate", "mcp__wakil__browser_new_tab", "mcp__wakil__browser_open", "mcp__wakil__browser_reload", "mcp__wakil__browser_reopen_tab", "mcp__wakil__browser_select_tab", "mcp__wakil__browser_stop", "mcp__wakil__browser_zoom",
    // 3c-ii: the read only; the acts are mutations, reached through the gate.
    "mcp__wakil__browser_read_page",
    "mcp__wakil__api_bind", "mcp__wakil__api_cancel", "mcp__wakil__api_fill_from_curl",
    "mcp__wakil__api_open", "mcp__wakil__api_render_curl", "mcp__wakil__api_reopen",
    "mcp__wakil__api_request", "mcp__wakil__api_set_request", "mcp__wakil__api_unbind",
    "mcp__wakil__api_undo_fill",
    "mcp__wakil__ctx_capacity",  // provider capacity; capacity_record is operator-only
    "mcp__wakil__ctx_config_tree", "mcp__wakil__ctx_list_environments",
    "mcp__wakil__ctx_list_projects", "mcp__wakil__ctx_list_providers", "mcp__wakil__db_cancel", "mcp__wakil__db_classify_statement", "mcp__wakil__db_describe_table",
    "mcp__wakil__db_list_databases", "mcp__wakil__db_list_tables", "mcp__wakil__db_page",
    "mcp__wakil__db_read_table", "mcp__wakil__db_refetch", "mcp__wakil__db_render_update",
    "mcp__wakil__db_run_query",
    "mcp__wakil__pane_close", "mcp__wakil__pane_focus", "mcp__wakil__pane_maximize",
    "mcp__wakil__pane_move", "mcp__wakil__pane_open", "mcp__wakil__pane_resize",
    "mcp__wakil__pane_restore", "mcp__wakil__pane_scroll_clear", "mcp__wakil__pane_scroll_to_row",
    "mcp__wakil__pane_select_cell", "mcp__wakil__pane_select_rows", "mcp__wakil__pane_set_column_width",
    "mcp__wakil__pane_set_density", "mcp__wakil__pane_snap", "mcp__wakil__pane_sort",
    "mcp__wakil__read_layout", "mcp__wakil__read_pane", "mcp__wakil__session_get",
    "mcp__wakil__session_list", "mcp__wakil__session_read", "mcp__wakil__session_record_parent",
    "mcp__wakil__session_resume", "mcp__wakil__term_open", "mcp__wakil__term_propose",
    "mcp__wakil__term_scroll",
]
