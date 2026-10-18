import Foundation
import Testing
@testable import WakilKit

// Background agents, 3 of 4, Task 2: a dispatch's writes land in its caller's own scope. The
// window installs the real lookup in Task 3; here each test installs its own.

private let screenA = LayoutScope(organization: "acme", project: "a", environment: "staging")
private let homeB = LayoutScope(organization: "acme", project: "b", environment: "staging")

/// A registry with the layout actions and `db_run_query` over one layout and pane store, and a
/// scope lookup that sends every agent session to `homeB` and everything else to the screen.
private func routedRegistry() async throws -> (registry: ActionRegistry, layout: LayoutStore, panes: PaneStore) {
    let dir = testScratchRoot.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let rows = JSONValue.object([
        "content": .array([.object(["type": .string("text"), "text": .string("stub")])]),
        "structuredContent": .object([
            "columns": .array([.string("id")]),
            "rows": .array([.array([.number(7)])]),
            "millis": .number(0),
        ]),
    ])
    let panes = PaneStore()
    let layout = LayoutStore()
    let registry = ActionRegistry(journalDirectory: dir.appendingPathComponent("journal"), sessionId: "s1")
    await registerStandardActions(
        into: registry, context: nil, panes: panes, db: RecordingToolCaller(always: rows),
        resumes: ResumeBroker(), layout: layout)
    await registerLayoutActions(into: registry, layout: layout, panes: panes)
    registry.setScopeLookup { caller in caller.session == nil ? nil : homeB }
    await layout.switchScope(to: screenA)
    await panes.switchScope(to: screenA)
    return (registry, layout, panes)
}

private func paneId(_ result: JSONValue) -> String? {
    guard case .object(let fields) = result, case .string(let id)? = fields["id"] ?? fields["pane"] else { return nil }
    return id
}

/// `scope`'s arrangement, read as a caller homed there reads it.
private func snapshot(_ layout: LayoutStore, in scope: LayoutScope) async -> LayoutSnapshot {
    await ScopeRouting.$home.withValue(scope) { await layout.snapshot() }
}

private func rows(_ panes: PaneStore, _ id: String, in scope: LayoutScope) async -> [[JSONValue]] {
    await ScopeRouting.$home.withValue(scope) { await dbSnapshot(panes, id).rows }
}

/// A database whose reply waits until the test lets it through.
private actor GatedDB: ToolCaller {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var open = false
    private(set) var arrived = 0
    func release() {
        open = true
        waiting.forEach { $0.resume() }
        waiting = []
    }
    func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        arrived += 1
        if !open { await withCheckedContinuation { waiting.append($0) } }
        return .object(["structuredContent": .object([
            "columns": .array([.string("id")]),
            "rows": .array([.array([.integer(2)])]),
            "millis": .number(1),
        ])])
    }
}

struct ScopeRoutingTests {
    @Test func aBackgroundAgentsPaneLandsInItsOwnCanvas() async throws {
        let (registry, layout, panes) = try await routedRegistry()
        let agent = DispatchCaller.test("staging", session: "agent-b")
        let before = await layout.reading()

        let opened = try await registry.dispatch(
            name: "pane_open", params: .object(["kind": .string("db")]),
            origin: .agent, caller: agent, confirmation: nil)
        let id = try #require(paneId(opened))
        _ = try await registry.dispatch(
            name: "db_run_query", params: .object(["query": .string("select 7"), "pane": .string(id)]),
            origin: .agent, caller: agent, confirmation: nil)
        _ = try await registry.dispatch(
            name: "pane_focus", params: .object(["id": .string(id)]),
            origin: .agent, caller: agent, confirmation: nil)

        #expect(await snapshot(layout, in: homeB).panes.map(\.id) == [id])
        #expect(await rows(panes, id, in: homeB) == [[.integer(7)]])
        // The screen is untouched, and nothing asked it for the keyboard (Rule 6).
        let after = await layout.reading()
        #expect(after.snapshot == before.snapshot)
        #expect(after.snapshot.panes.isEmpty)
        #expect(after.focusRequests == before.focusRequests)
        #expect(await dbSnapshot(panes, id).rows.isEmpty)
    }

    @Test func anOperatorDispatchStillTargetsTheScreen() async throws {
        let (registry, layout, panes) = try await routedRegistry()
        let operatorCaller = DispatchCaller.test("staging", session: nil)
        let before = await layout.reading().focusRequests

        let opened = try await registry.dispatch(
            name: "pane_open", params: .object(["kind": .string("db")]),
            origin: .ui, caller: operatorCaller, confirmation: nil)
        let id = try #require(paneId(opened))
        _ = try await registry.dispatch(
            name: "db_run_query", params: .object(["query": .string("select 7"), "pane": .string(id)]),
            origin: .ui, caller: operatorCaller, confirmation: nil)
        _ = try await registry.dispatch(
            name: "pane_focus", params: .object(["id": .string(id)]),
            origin: .ui, caller: operatorCaller, confirmation: nil)

        #expect(await layout.snapshot().panes.map(\.id) == [id])
        #expect(await dbSnapshot(panes, id).rows == [[.integer(7)]])
        #expect(await layout.reading().focusRequests == before + 1)
        #expect(await snapshot(layout, in: homeB).panes.isEmpty)
    }

    @Test func aBackgroundShellsOutputStaysInItsOwnScope() async throws {
        let panes = PaneStore()
        await panes.switchScope(to: homeB)
        try await withTerminalStore(panes: panes) { store in
            _ = try await ScopeRouting.$home.withValue(homeB) {
                try await store.open(
                    paneId: "terminal-1", path: NSTemporaryDirectory(), shell: "/bin/bash",
                    environment: ["HOME": emptyHome()])
            }
            // The operator moves on; the shell keeps running.
            await panes.switchScope(to: screenA)
            // Typed into the shell where it lives: a shell is keyed by its scope and pane id.
            await ScopeRouting.$home.withValue(homeB) {
                await store.write(paneId: "terminal-1", bytes: Array("echo routed\n".utf8))
            }

            let landed = await dbEventually(8 * testWaitLoadMultiplier) {
                await ScopeRouting.$home.withValue(homeB) {
                    await panes.terminalBlocks(paneId: "terminal-1").contains { $0.command == "echo routed" }
                }
            }
            #expect(landed)
            #expect(await panes.terminalBlocks(paneId: "terminal-1").isEmpty)
        }
    }

    /// Fix round 1, Important 2: a screen switch invalidates only the scope it leaves. An agent's
    /// `list_apis` in flight in its own place still lands there.
    @Test func anApiReresolveInFlightInItsOwnPlaceSurvivesAScreenSwitch() async throws {
        let panes = PaneStore()
        let screenC = LayoutScope(organization: "acme", project: "c", environment: "staging")
        let listing = [ApiEntryListing(name: "catalog", baseURL: "https://c.example", credentialed: false)]
        await ScopeRouting.$home.withValue(homeB) {
            await panes.openApi(paneId: "api-1", entry: "", environment: "staging", origin: nil,
                                credentialed: false, entries: [])
        }
        await panes.switchScope(to: screenA)
        let inB = await ScopeRouting.$home.withValue(homeB) { await panes.apiResolutionMark() }
        let onA = await panes.apiResolutionMark()

        await panes.switchScope(to: screenC)
        await panes.clearApiResponses(to: "production")   // the screen's environment, C's alone

        let landed = await ScopeRouting.$home.withValue(homeB) {
            await panes.reresolveApis(environment: "staging", listing: listing, generation: inB)
        }
        #expect(landed == ["api-1": "catalog"])
        #expect(await ScopeRouting.$home.withValue(homeB) { await panes.apiSnapshot(paneId: "api-1").entry } == "catalog")
        // The screen's own read, begun on A, still cannot land on C.
        #expect(await panes.reresolveApis(environment: "staging", listing: listing, generation: onA) == nil)
    }

    /// Fix round 2, Important 1: an operator's read that outlives a swap lands in its own pane.
    /// Begun on B, its reply arrives while A is on screen; back on B the pane shows it, not the
    /// rows from before and not a running indicator.
    @Test func anOperatorsReadThatLandsWhileAwayShowsOnReturn() async throws {
        let dir = testScratchRoot.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = GatedDB()
        let panes = PaneStore()
        let layout = LayoutStore()
        let registry = ActionRegistry(journalDirectory: dir.appendingPathComponent("journal"), sessionId: "s1")
        await registerStandardActions(
            into: registry, context: nil, panes: panes, db: db, resumes: ResumeBroker(), layout: layout)
        await layout.switchScope(to: homeB)
        await panes.switchScope(to: homeB)
        let id = await layout.open(kind: "db", title: "db").id
        await layout.setFetch(PaneFetch(query: .sql(database: nil, raw: "SELECT 1")), id: id)
        await panes.setRows(
            paneId: id, columns: ["id"], columnTypes: ["int"], columnTypesInferred: false,
            rows: [[.integer(1)]], millis: 1, truncated: false, pageable: true, offset: 0,
            sort: [], listsTables: false, editable: nil)

        let read = Task {
            try await registry.dispatch(
                name: "db_refetch", params: .object(["pane": .string(id)]),
                origin: .ui, caller: DispatchCaller.test("staging", session: nil), confirmation: nil)
        }
        #expect(await dbEventually { await db.arrived == 1 })
        await layout.switchScope(to: screenA)
        await panes.switchScope(to: screenA)
        await db.release()
        let result = try await read.value
        #expect(!dbResultWasCancelled(result))

        await layout.switchScope(to: homeB)
        await panes.switchScope(to: homeB)
        #expect(await dbSnapshot(panes, id).rows == [[.integer(2)]])
        #expect(await dbSnapshot(panes, id).runningSince == nil)
        #expect(await ScopeRouting.$home.withValue(screenA) { await dbSnapshot(panes, id).rows }.isEmpty)
    }

    /// Fix round 2, ruling: a plain screen switch bumps no generation. An agent's listing in
    /// flight in B, the place on screen, survives the operator switching B → A and lands in B.
    @Test func anAgentsApiListingSurvivesTheOperatorLeavingItsPlace() async throws {
        let panes = PaneStore()
        let listing = [ApiEntryListing(name: "catalog", baseURL: "https://c.example", credentialed: false)]
        await panes.switchScope(to: homeB)
        await panes.openApi(paneId: "api-1", entry: "", environment: "staging", origin: nil,
                            credentialed: false, entries: [])
        let mark = await ScopeRouting.$home.withValue(homeB) { await panes.apiResolutionMark() }

        await panes.switchScope(to: screenA)

        let landed = await ScopeRouting.$home.withValue(homeB) {
            await panes.reresolveApis(environment: "staging", listing: listing, generation: mark)
        }
        #expect(landed == ["api-1": "catalog"])
        #expect(await panes.apiSnapshot(paneId: "api-1").entry == "")
    }

    /// Task 3, ruling 1: every dispatch is homed where it began, not only the db reads. An
    /// operator's `editor_open` whose read arrives after the screen moved lands in the pane it
    /// was asked of — even with a pane of the same id on the canvas now on screen (ids repeat
    /// across scopes loaded from disk). (An editor pane since 3b-iii folded the Git pane in.)
    @Test func anOperatorsWriteAfterAnAwaitLandsInTheScopeItBeganIn() async throws {
        let (registry, layout, panes) = try await routedRegistry()
        let files = FakeFiles()
        await files.put("/p/api/a.php", "from a")
        await files.setSlowRead(true)
        await registerEditorActions(
            into: registry, panes: panes, layout: layout, files: files, fileLists: nil,
            gitStatus: nil, roots: { ["/p/api"] })
        let id = await layout.open(kind: "editor", title: "Editor").id
        await layout.load(
            LayoutSnapshot(panes: [Pane(id: id, kind: "editor", title: "Editor",
                                        frame: PaneFrame(x: 0, y: 0, width: 10, height: 10))]),
            for: homeB)

        let open = Task {
            try await registry.dispatch(
                name: "editor_open", params: .object(["pane": .string(id), "path": .string("/p/api/a.php")]),
                origin: .ui, caller: DispatchCaller.test("staging"), confirmation: nil)
        }
        #expect(await dbEventually { await files.calls.contains("files_read /p/api/a.php") })
        await layout.switchScope(to: homeB)
        await panes.switchScope(to: homeB)
        await files.releaseRead()
        _ = try await open.value

        let inA = await ScopeRouting.$home.withValue(screenA) { await panes.editorSnapshot(paneId: id) }
        #expect(inA.tabs.map(\.text) == ["from a"])
        #expect(await panes.editorSnapshot(paneId: id).tabs.isEmpty, "B's pane of the same id is untouched")
    }

    /// Task 3, ruling 3: a shell is keyed by its scope and pane id. Two loaded scopes can each
    /// hold `terminal-1`, so one scope's `term_open` must not close the other's shell.
    @Test func aShellSurvivesTheSamePaneIdOpeningInAnotherScope() async throws {
        let panes = PaneStore()
        await panes.switchScope(to: screenA)
        try await withTerminalStore(panes: panes) { store in
            _ = try await ScopeRouting.$home.withValue(homeB) {
                try await store.open(
                    paneId: "terminal-1", path: NSTemporaryDirectory(), shell: "/bin/bash",
                    environment: ["HOME": emptyHome()])
            }
            let shellB = await ScopeRouting.$home.withValue(homeB) { await store.pidForTesting(paneId: "terminal-1") }
            _ = try await store.open(
                paneId: "terminal-1", path: NSTemporaryDirectory(), shell: "/bin/bash",
                environment: ["HOME": emptyHome()])

            #expect(await ScopeRouting.$home.withValue(homeB) { await store.isRunning(paneId: "terminal-1") })
            #expect(await ScopeRouting.$home.withValue(homeB) { await store.pidForTesting(paneId: "terminal-1") } == shellB)
            #expect(await store.isRunning(paneId: "terminal-1"))
            #expect(await store.pidForTesting(paneId: "terminal-1") != shellB)
        }
    }
}

private func emptyHome() -> String {
    let dir = testScratchRoot.appendingPathComponent("wakil-scratch-home-\(UUID().uuidString)").path
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}
