import Testing
import Foundation
@testable import WakilKit

/// `WindowModel` is everything the Task 11 window does that is not drawing:
/// the dispatches its controls make, the pane snapshot its table reads, the
/// harness events its thought thread lists, and the org/project/environment
/// labels Invariant 8 requires on screen. It lives in `WakilKit` rather than
/// in `WakilApp` for exactly one reason — a test target cannot import an
/// executable target, so anything left in `WakilApp` is covered by the
/// operator runbook alone. The SwiftUI view in
/// `app/Sources/WakilApp/WakilWindow.swift` is deliberately thin for the
/// same reason.
///
/// SAFETY. Nothing here runs the `claude` CLI: the harness is a stub
/// conforming to `AgentHarness`, and every registry these tests use is
/// built in-process. Journals and saved layouts land in scratch
/// directories, never `~/.wakil`. The two layout-persistence tests at the
/// foot of this file are the only ones that spawn a Go binary — they need a
/// real `bin/wakil-ctx` because the org and project the layout is filed
/// under come from `refreshContext()`, and they point it at a scratch
/// `HOME` built by `makeFixture` rather than at the operator's own.

private func windowScratchDirectory() throws -> URL {
    let dir = testScratchRoot.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Polls `condition` on the main actor until it holds or the budget runs
/// out, returning whether it held. The event pump `WindowModel.send` starts
/// is a separate `Task`, so a test that checked immediately after `send`
/// returned would be asserting on a race rather than on the model.
///
/// `condition` is `async` because Task 10's resume tests hand this a
/// closure that itself `await`s (`await model.thoughts.contains { ... }`)
/// — those tests are `@MainActor`, like every other test here that touches
/// `model`, so the `await` inside is redundant rather than required (it
/// warns "no async operations occur" rather than failing to compile), kept
/// because it matches the brief's own text. A plain synchronous closure,
/// which is what every earlier test here still passes, satisfies this
/// type with no change at its call site.
@MainActor
private func waitUntil(_ condition: @MainActor () async -> Bool) async -> Bool {
    for _ in 0..<400 {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return await condition()
}

/// Records what it was asked to do, so a test can assert the model reached
/// the harness at all.
private actor HarnessLog {
    private(set) var entries: [String] = []
    func add(_ entry: String) { entries.append(entry) }
}

/// The `lookup` the large majority of this file's `WindowModel(...)` call
/// sites pass: it always succeeds, with credentials nothing here reads —
/// `send`/`resume` pass them straight through to `harnessFactory`, and every
/// factory in this file (`{ _ in harness }`, `{ _ in nil }`, `{ _ in
/// harnesses.next() }`) ignores the `ProviderSelection` it is handed
/// entirely. These tests exist to cover dispatch, event pumping and resume
/// mechanics, not credential plumbing — `ProviderCredentialsLookupTests.swift`
/// covers `ProviderCredentialsLookup` itself, and a future provider-switch
/// suite is what should exercise a lookup that actually refuses.
///
/// Deliberately `private` to this test file, and deliberately NOT a default
/// argument on `WindowModel`'s initialisers: a defaulted `lookup` sitting on
/// a `public` production initialiser would let a future real call site omit
/// it and compile clean into fake credentials — precisely the quiet path
/// 2b-vi exists to remove. So every call site below passes this explicitly.
private struct AlwaysSucceedsCredentialsLookup: ProviderCredentialsLookup {
    func credentials(forProvider id: String) async throws -> ProviderCredentials {
        ProviderCredentials(claudePath: "/usr/bin/true", configDir: "/dev/null", oauthToken: "test-only")
    }
}

/// An `AgentHarness` that spawns nothing. `events()` returns a stream the
/// test feeds by hand, which is what makes "the thought thread renders what
/// the harness emits" assertable without a real session.
///
/// `@unchecked Sendable`: `holdNextSend`/`sendGate` below are plain mutable
/// state, touched only from `@MainActor` test code and from `send` itself
/// (which every caller in this file also calls from the main actor) — never
/// from two places at once, so there is nothing for the checker to actually
/// catch, but nothing here proves that to it either.
private final class StubHarness: AgentHarness, @unchecked Sendable {
    let log = HarnessLog()
    private let stream: AsyncStream<HarnessEvent>
    let continuation: AsyncStream<HarnessEvent>.Continuation

    /// When true, the *next* `send` suspends after logging itself and
    /// before returning, until `releaseSend()` is called. Off by default,
    /// so every existing test's `send` behaves exactly as it always has.
    ///
    /// Built for Finding 5 of the final review (2026-09-09): the bug it
    /// reproduces needs a `.result` event to be fully processed by
    /// `WindowModel`'s event pump *while `harness.send` is still
    /// suspended* — a real race in production, between the child
    /// process's stdin write and its own stdout. A test cannot depend on
    /// scheduler timing to land that race reliably, so this makes the
    /// ordering exact instead: the test holds `send` open with this gate,
    /// yields the event, waits for proof the pump consumed it, and only
    /// then releases the gate.
    var holdNextSend = false { didSet { if holdNextSend { sendGate.arm() } } }
    private let sendGate = HoldGate()

    /// If set, the *next* `send` throws this instead of succeeding — after
    /// logging itself, so the log still shows the attempt was made. Off by
    /// default. Used to check that a failed `send` clears `turnInFlight`
    /// rather than leaving it set (Finding 5's second half).
    var nextSendError: Error?

    /// If set, the *next* `start` throws this instead of succeeding —
    /// after logging itself, so the attempt is still visible in the log.
    /// Off by default. Built for Finding 2 of the 2b-v acceptance review
    /// (2026-09-10): `resume` must leave the existing session untouched
    /// when the harness the factory hands it fails to start, and that
    /// needs a harness whose `start` can be made to fail on demand.
    var nextStartError: Error?

    /// When true, `stop` suspends after logging itself and before calling
    /// `continuation.finish()`, until `releaseStop()` is called. Off by
    /// default. Built for Finding 1 of the 2b-v acceptance review
    /// (2026-09-10), the same way `holdNextSend` was built for Finding 5
    /// of the prior one: the bug it reproduces needs an event to be
    /// yielded onto THIS harness's stream — buffered, not yet drained —
    /// while `resume` is suspended inside `harness?.stop()`, which is
    /// exactly the gap between `eventPumpGeneration` being bumped and this
    /// harness's continuation actually finishing. A test cannot depend on
    /// scheduler timing to land that gap reliably (nothing here retries or
    /// polls for "did the race happen"), so this holds `stop` open at
    /// exactly that gap instead: the test waits for `"stop"` to appear in
    /// the log — proof `resume` has bumped the generation and is now
    /// inside this call — yields the stale event, and only then releases
    /// the gate to let `finish()` run.
    var holdNextStop = false { didSet { if holdNextStop { stopGate.arm() } } }
    private let stopGate = HoldGate()

    /// When true, the *next* `start` suspends after logging itself, until
    /// `releaseStart()` is called. The same shape as `holdNextSend`, built
    /// for #284: a turn's slow, silent stretch is `resolveCredentials` and
    /// the process spawn inside `harness.start`, and what the window shows
    /// DURING it is only assertable if a test can hold it open there.
    var holdNextStart = false { didSet { if holdNextStart { startGate.arm() } } }
    private let startGate = HoldGate()

    init() {
        (stream, continuation) = AsyncStream<HarnessEvent>.makeStream()
    }

    func start(sessionId: String, resumingFrom parentSessionId: String?, workingDirectory: String) async throws {
        await log.add("start:\(sessionId):\(parentSessionId ?? "-"):\(workingDirectory)")
        if let nextStartError {
            self.nextStartError = nil
            throw nextStartError
        }
        guard holdNextStart else { return }
        holdNextStart = false
        await startGate.wait()
    }
    func send(_ text: String) async throws {
        await log.add("send:\(text)")
        if let nextSendError {
            self.nextSendError = nil
            throw nextSendError
        }
        guard holdNextSend else { return }
        holdNextSend = false
        await sendGate.wait()
    }
    func events() -> AsyncStream<HarnessEvent> { stream }
    func interrupt() async { await log.add("interrupt") }
    func stop() async {
        await log.add("stop")
        if holdNextStop {
            holdNextStop = false
            await stopGate.wait()
        }
        continuation.finish()
    }

    /// Lets a `send` gated by `holdNextSend` return — whether it is parked
    /// already or still on its way to the gate (`HoldGate` latches the
    /// release). A no-op if no hold was asked for.
    func releaseSend() {
        sendGate.release()
    }

    /// Lets a `stop` gated by `holdNextStop` proceed to `finish()`. Same
    /// no-op-if-nothing-held shape as `releaseSend`, for the same reason.
    func releaseStop() {
        stopGate.release()
    }

    /// Lets a `start` gated by `holdNextStart` return. Same
    /// no-op-if-nothing-held shape as `releaseSend`, for the same reason.
    func releaseStart() {
        startGate.release()
    }
}

private func makeRegistry() throws -> (ActionRegistry, PaneStore, LayoutStore) {
    let dir = try windowScratchDirectory()
    return (
        ActionRegistry(journalDirectory: dir, sessionId: "window-test"),
        PaneStore(kinds: PaneKinds.standard),
        LayoutStore()
    )
}

// MARK: - Pane projection

@Test func paneTableRendersEveryCellOfASnapshot() {
    let grid = DataSurfaceSnapshot(
        columns: ["id", "name", "active"], columnTypes: [], columnTypesInferred: false,
        rows: [
            [.number(1), .string("widgets"), .bool(true)],
            [.number(2), .null, .bool(false)],
        ],
        rowCount: 2, millis: 0, truncated: false, pageable: false, offset: 0,
        selection: .empty, sort: [], scrollTarget: nil, listsTables: false, editable: nil)

    let table = PaneTable(dataSurface: grid)

    #expect(table.columns.map(\.name) == ["id", "name", "active"])
    #expect(table.rows.map { $0.cells.map(\.text) } == [["1", "widgets", "true"], ["2", "", "false"]])
}

/// `PaneStore.snapshot` answers for a pane nothing has written to with the
/// same shape a cleared pane gets, so the table must render it as empty
/// rather than as a failure.
@Test func paneTableOfAnUntouchedPaneIsEmpty() async {
    let panes = PaneStore(kinds: PaneKinds.standard)
    let snapshot = await panes.snapshot(paneId: "db", kind: "db")
    guard let grid = snapshot.dataSurface else {
        Issue.record("expected a grid snapshot")
        return
    }
    let table = PaneTable(dataSurface: grid)
    #expect(table.columns.isEmpty)
    #expect(table.rows.isEmpty)
    #expect(table.truncated == false)
}

/// Row ids must be distinct even when two rows carry identical cells, or
/// SwiftUI's `Table` collapses them into one visible row.
@Test func paneTableGivesIdenticalRowsDistinctIdentities() {
    let duplicate: [JSONValue] = [.string("same")]
    let grid = DataSurfaceSnapshot(
        columns: ["c"], columnTypes: [], columnTypesInferred: false,
        rows: [duplicate, duplicate], rowCount: 2, millis: 0, truncated: false,
        pageable: false, offset: 0, selection: .empty, sort: [], scrollTarget: nil,
        listsTables: false, editable: nil)
    let table = PaneTable(dataSurface: grid)
    #expect(table.rows.count == 2)
    #expect(table.rows[0].id != table.rows[1].id)
}

// MARK: - Pane projection widened (Task 9, 2c-i): types, selection, sort

@Test func paneTableCarriesTypesSelectionAndSort() {
    let grid = DataSurfaceSnapshot(
        columns: ["id", "name"], columnTypes: ["INTEGER", "TEXT"], columnTypesInferred: false,
        rows: [[.number(1), .null]], rowCount: 1, millis: 9, truncated: true,
        pageable: false, offset: 0,
        selection: PaneSelection(anchorRow: 0, anchorColumn: "name", rows: [0]),
        sort: [PaneSort(column: "id", direction: .descending)], scrollTarget: nil,
        listsTables: false, editable: nil)
    let table = PaneTable(dataSurface: grid)
    #expect(table.columns.map(\.name) == ["id", "name"])
    #expect(table.columns.map(\.type) == ["INTEGER", "TEXT"])
    #expect(table.millis == 9)
    #expect(table.truncated)
    #expect(table.selection.anchorRow == 0)
    #expect(table.sort.first?.direction == .descending)
    // The NULL survives the projection as a NULL rather than as "".
    #expect(table.rows[0].cells[1].isNull)
}

/// D5: `sort` is a precedence list, and a second entry is a second term
/// rather than being discarded — this is what lets the projection carry
/// what a second header click means.
@Test func paneTableCarriesEveryTermInThePrecedenceListGiven() {
    let grid = DataSurfaceSnapshot(
        columns: [], columnTypes: [], columnTypesInferred: false, rows: [], rowCount: 0,
        millis: 0, truncated: false, pageable: false, offset: 0, selection: .empty,
        sort: [
            PaneSort(column: "kind", direction: .ascending),
            PaneSort(column: "id", direction: .descending),
        ], scrollTarget: nil, listsTables: false, editable: nil)
    let table = PaneTable(dataSurface: grid)
    #expect(table.sort.map(\.column) == ["kind", "id"])
    #expect(table.sort.map(\.direction) == [.ascending, .descending])
}

// MARK: - Paging state: `pageable` and `offset` (Task 13)

@Test func aPaneTableCarriesWhereItIsAndWhetherItCanMove() {
    let grid = DataSurfaceSnapshot(
        columns: ["id"], columnTypes: ["INTEGER"], columnTypesInferred: false,
        rows: [[.number(1)]], rowCount: 1, millis: 4, truncated: true, pageable: true,
        offset: 500, selection: .empty, sort: [], scrollTarget: nil, listsTables: false,
        editable: nil)
    let table = PaneTable(dataSurface: grid)
    #expect(table.pageable)
    #expect(table.offset == 500)
}

@Test func theFooterNamesWhichRowsAreOnScreenOnlyWhenPaging() {
    // Page one of a complete result says nothing about a range: "rows
    // 1-6" beside "6 rows" is noise. A later page, or a truncated first
    // one, is where the range is the answer to a real question.
    func table(rows: Int, offset: Int, truncated: Bool, pageable: Bool) -> PaneTable {
        PaneTable(
            columns: [PaneColumn(name: "id", type: "INTEGER")],
            columnTypesInferred: false,
            rows: (0..<rows).map { PaneRow(id: $0, cells: [PaneCell(.number(Double($0)))]) },
            millis: 1, truncated: truncated, selection: .empty, sort: [],
            scrollTarget: nil, pageable: pageable, offset: offset, failure: nil,
            listsTables: false)
    }
    #expect(table(rows: 6, offset: 0, truncated: false, pageable: true)
            .rowRangeDescription == nil)
    #expect(table(rows: 500, offset: 500, truncated: true, pageable: true)
            .rowRangeDescription == "rows 501–1,000 · more remain")
    #expect(table(rows: 6, offset: 1000, truncated: false, pageable: true)
            .rowRangeDescription == "rows 1,001–1,006 · end")
    #expect(table(rows: 500, offset: 0, truncated: true, pageable: true)
            .rowRangeDescription == "rows 1–500 · more remain")
    // An unpageable result never offers a range, because there is no
    // second page for the range to be relative to.
    #expect(table(rows: 3, offset: 0, truncated: false, pageable: false)
            .rowRangeDescription == nil)
}

/// Reuses `makeRegistry()`/`WindowModel(...)` — the route every other test
/// in this file already has to a model's `PaneStore` — rather than adding a
/// parallel harness under the brief's `testWindowModel`/`panesForTesting`
/// names, which do not exist in this file.
@Test @MainActor func aModelHoldsATablePerPane() async throws {
    let (registry, panes, layout) = try makeRegistry()
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup())

    // `refreshPanes` iterates the LAYOUT (Decision 24), so the pane must be
    // open there too. `open`'s first `"db"` pane is always `"db-1"`.
    _ = await layout.open(kind: "db", title: "Results")
    await panes.setRows(
        paneId: "db-1", columns: ["id"], columnTypes: ["INTEGER"], columnTypesInferred: false,
        rows: [[.number(1)]], millis: 0, truncated: false,
        pageable: true, offset: 0, sort: [], listsTables: false, editable: nil)
    await model.refreshPanes()
    #expect(model.table("db-1").rows.count == 1)
    // An unknown pane is empty rather than absent, so a SwiftUI body can
    // ask for one unconditionally.
    #expect(model.table("never-written").rows.isEmpty)
}

/// `editable(paneId:)` — added alongside `commitCellEdit` (2c-ii-b Task 12)
/// as the accessor `Canvas.paneView` needs to read a pane's `PaneEditable`
/// per pane id, the same way `table(_:)` already does for `PaneTable`.
///
/// **Per pane id, not window-scoped** — `DBPane`'s `refusal` doc comment
/// records the walked failure a single shared value causes: one pane's
/// state painted under every other open pane. Two panes here get two
/// different `PaneEditable` values from the one call this test makes on
/// each, which is what "per pane id" actually has to mean at the type this
/// value is read at.
@Test @MainActor func aModelHoldsAnEditablePerPane() async throws {
    let (registry, panes, layout) = try makeRegistry()
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup())

    // `refreshPanes` iterates the LAYOUT (Decision 24), so both panes must
    // be open there too. `open`'s first two `"db"` panes are `"db-1"` and
    // `"db-2"`, in order.
    _ = await layout.open(kind: "db", title: "One")
    _ = await layout.open(kind: "db", title: "Two")
    await panes.setRows(
        paneId: "db-1", columns: ["id", "name"], columnTypes: ["INTEGER", "TEXT"],
        columnTypesInferred: false, rows: [[.number(1), .string("a")]], millis: 0,
        truncated: false, pageable: true, offset: 0, sort: [], listsTables: false,
        editable: PaneEditable(
            table: "widgets", keyColumns: ["id"], columns: ["name"], rowKeys: ["id = 1"]))
    await panes.setRows(
        paneId: "db-2", columns: ["id"], columnTypes: ["INTEGER"], columnTypesInferred: false,
        rows: [[.number(2)]], millis: 0, truncated: false, pageable: true, offset: 0, sort: [],
        listsTables: false, editable: nil)

    // Unpopulated before the same refresh `tables` itself waits on — there
    // is no separate pump for this cache to lag behind or race ahead of.
    #expect(model.editable(paneId: "db-1") == nil)

    await model.refreshPanes()

    #expect(model.editable(paneId: "db-1") == PaneEditable(
        table: "widgets", keyColumns: ["id"], columns: ["name"], rowKeys: ["id = 1"]))
    // `db-2`'s own subject cannot be written back to a single table, so its
    // entry is `nil` — never `db-1`'s value, painted under a pane that
    // never earned it.
    #expect(model.editable(paneId: "db-2") == nil)
    // An unknown pane id, the same as `table(_:)`'s own "empty rather than
    // absent" rule one type down: nothing was ever written for it, so
    // there is nothing to hand back.
    #expect(model.editable(paneId: "never-written") == nil)
}

// MARK: - The observation pump (final review Finding 3)

/// An agent's dispatch never touches `WindowModel`, so nothing on screen
/// re-read `PaneStore` after it: `tables` refreshed at launch, from
/// `runQuery`, and from `dispatchFromSurface`, and an MCP `pane_select_cell`
/// changed the store while the window went on drawing the old selection
/// until the operator happened to click. 2c-i's exit criterion is that a
/// selection is "set identically by clicking and by the agent" — a
/// selection only the agent can see does not meet it.
///
/// Dispatched straight through the registry with `origin: .agent`, which is
/// exactly what `MCPServer` does for a `tools/call`, so this is the agent's
/// path and not a model method wearing its name.
@Test @MainActor func anAgentsDispatchReachesTheScreenWithoutTheOperatorClicking() async throws {
    let (registry, panes, layout) = try makeRegistry()
    await registerPaneContentActions(into: registry, panes: panes, layout: layout)
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup())

    // `refreshPanes` iterates the LAYOUT (Decision 24), so the pane must be
    // open there too. `open`'s first `"db"` pane is always `"db-1"`.
    _ = await layout.open(kind: "db", title: "Results")
    await panes.setRows(
        paneId: "db-1", columns: ["id"], columnTypes: ["INTEGER"], columnTypesInferred: false,
        rows: [[.number(1)], [.number(2)], [.number(3)]], millis: 0, truncated: false,
        pageable: true, offset: 0, sort: [], listsTables: false, editable: nil)
    await model.refreshPanes()
    #expect(model.table("db-1").selection.anchorRow == nil)

    _ = try await registry.dispatch(
        name: "pane_select_cell",
        params: .object(["pane": .string("db-1"), "row": .number(2), "column": .string("id")]),
        origin: .agent, caller: .test("staging"), confirmation: nil)

    #expect(await waitUntil { model.table("db-1").selection.anchorRow == 2 })
    #expect(model.table("db-1").selection.rows == [2])
}

/// The canvas half of the same gap: geometry an agent changed was equally
/// invisible, because `layoutSnapshot` was only re-read by the window's own
/// dispatch paths.
@Test @MainActor func anAgentsLayoutDispatchReachesTheCanvasToo() async throws {
    let (registry, panes, layout) = try makeRegistry()
    await registerLayoutActions(into: registry, layout: layout)
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup())
    await model.openPane(kind: "db")
    let id = try #require(model.layoutSnapshot.panes.first).id

    _ = try await registry.dispatch(
        name: "pane_move",
        params: .object(["id": .string(id), "x": .number(321), "y": .number(654)]),
        origin: .agent, caller: .test("staging"), confirmation: nil)

    #expect(await waitUntil {
        model.layoutSnapshot.panes.first { $0.id == id }?.frame.x == 321
    })
}

/// The pump waits rather than polls: with nothing dispatched it does no
/// work at all, so a model left alone does not spin re-reading two actors
/// every frame. Asserted as "the cached values are untouched after many
/// scheduling turns", which is the observable half of not polling.
@Test @MainActor func theObservationPumpDoesNothingUntilSomethingIsDispatched() async throws {
    let (registry, panes, layout) = try makeRegistry()
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup())
    // Written behind the model's back and never refreshed: if anything were
    // polling, `tables` would pick this up on its own.
    await panes.setRows(
        paneId: "db-1", columns: ["id"], columnTypes: [], columnTypesInferred: false,
        rows: [[.number(1)]], millis: 0, truncated: false,
        pageable: true, offset: 0, sort: [], listsTables: false, editable: nil)
    for _ in 0..<200 { await Task.yield() }
    #expect(model.table("db-1").rows.isEmpty)
}

// MARK: - The header-edge width drag (final review Finding 5)

/// `pane_set_column_width` shipped registered, reachable from ⌘K and from
/// an agent, and with **no pointer path at all**: the header cells carried a
/// tap-to-sort gesture and nothing else, so the plan's claim that width is
/// reachable from the pointer was not true of the surface, and
/// `dispatchFromSurface`'s `pane_set_column_width` branch was dead code.
/// `widthHandle` in `DataSurface` is that path; this is the arithmetic it
/// runs, shared between the live preview and the commit so the width the
/// operator watches and the width that is dispatched cannot differ.
@Test func aHeaderDragCommitsTheWidthThePointerEndedAt() {
    #expect(paneColumnWidthAfterDrag(startWidth: 120, translation: 40) == 160)
    #expect(paneColumnWidthAfterDrag(startWidth: 120, translation: -30) == 90)
    #expect(paneColumnWidthAfterDrag(startWidth: 120, translation: 0) == 120)
}

/// **The same floor the layout arithmetic uses**, so an operator cannot
/// drag a column narrower than `paneColumnLayout` would ever draw it — a
/// width below the floor would be stored, persisted, and then silently
/// ignored on every redraw.
@Test func aHeaderDragCannotTakeAColumnBelowTheLayoutMinimum() {
    #expect(paneColumnWidthAfterDrag(startWidth: 120, translation: -500)
        == paneColumnMinimumWidth)
    // And the floor is one number, not two: the same constant
    // `paneColumnLayout` floors its free columns at.
    #expect(paneColumnLayout(
        columns: ["a", "b", "c"], overrides: [:], availableWidth: 10,
        horizontalSpacing: 16) == [paneColumnMinimumWidth, paneColumnMinimumWidth,
                                   paneColumnMinimumWidth])
}

// MARK: - The footer's row count (walk defect D4)

/// `1 rows` is what the CTE check drew. Nothing was wrong with it except
/// that it is not English, which is exactly the class of thing only a walk
/// reports.
@Test func oneRowIsSingularAndEverythingElseIsNot() {
    #expect(paneRowCountLabel(1) == "1 row")
    #expect(paneRowCountLabel(0) == "0 rows")
    #expect(paneRowCountLabel(2) == "2 rows")
    #expect(paneRowCountLabel(500) == "500 rows")
}

// MARK: - Row hover and selection backgrounds

/// A row at rest — neither hovered nor selected — draws nothing.
/// `design-language.md` §8's "row separation by whitespace, not rules"
/// holds only if the default really is zero, not merely a very faint one.
@Test func aRowAtRestHasNoBackground() {
    #expect(paneRowBackgroundOpacity(selected: false, hovered: false) == 0)
}

/// Hover has to read weaker than selection, or "you are here" and "this is
/// chosen" collapse into the same look — the distinction the operator
/// asked for when a hover treatment was added at all.
@Test func hoverAloneIsWeakerThanSelectionAlone() {
    let hover = paneRowBackgroundOpacity(selected: false, hovered: true)
    let selected = paneRowBackgroundOpacity(selected: true, hovered: false)
    #expect(hover > 0)
    #expect(hover < selected)
}

/// A row that is both selected and hovered has to be legible as both,
/// which means visibly stronger than selection alone — otherwise hovering
/// a selected row would look identical to leaving it, and the hover
/// treatment would silently stop working for exactly the rows an operator
/// is most likely to be pointing at.
@Test func selectedAndHoveredIsStrongerThanSelectionAlone() {
    let both = paneRowBackgroundOpacity(selected: true, hovered: true)
    let selected = paneRowBackgroundOpacity(selected: true, hovered: false)
    #expect(both > selected)
}

// MARK: - The editable-cell hover outline

/// The outline is the same size at both densities — that is the whole
/// point of insetting by a computed amount rather than a fixed one. An
/// affordance that grows with the row would read as a slab in airy mode,
/// which is the treatment that was rejected.
@Test func theEditHoverOutlineIsTheSameHeightInAiryAsItsTarget() {
    let inset = paneEditHoverInset(rowHeight: PaneDensity.airy.rowHeight)
    #expect(PaneDensity.airy.rowHeight - 2 * inset == editHoverOutlineHeight)
}

/// A dense row is shorter than the target, so the inset floors instead of
/// going negative. A negative inset would draw the outline past its own
/// row's edges and over its neighbours — the row above would look editable
/// when the pointer is nowhere near it.
@Test func theEditHoverOutlineNeverEscapesADenseRow() {
    let inset = paneEditHoverInset(rowHeight: PaneDensity.dense.rowHeight)
    #expect(inset > 0)
    #expect(PaneDensity.dense.rowHeight - 2 * inset > 0)
}

/// Airy rows inset more than dense ones. Stated separately from the two
/// above because it is the property that has to survive any future change
/// to either row height: the taller row is always the one that needs more
/// taken off it.
@Test func airyRowsInsetMoreThanDenseOnes() {
    #expect(paneEditHoverInset(rowHeight: PaneDensity.airy.rowHeight)
        > paneEditHoverInset(rowHeight: PaneDensity.dense.rowHeight))
}

/// The pointer path's payload, end to end: exactly what `widthHandle`
/// dispatches, through the one method it dispatches with. This is the
/// confirmation that `dispatchFromSurface`'s special case is now live code
/// rather than a branch nothing reaches — the width has to arrive in
/// `layoutSnapshot`, which is what the surface redraws from.
@Test @MainActor func aHeaderDragsCommittedWidthReachesTheCanvasThroughTheRegistry() async throws {
    let (registry, panes, layout) = try makeRegistry()
    await registerPaneContentActions(into: registry, panes: panes, layout: layout)
    await registerLayoutActions(into: registry, layout: layout)
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup())
    await model.openPane(kind: "db")
    let id = try #require(model.layoutSnapshot.panes.first).id

    // A drag that tried to take the column to 20pt: the floor is applied
    // where the gesture commits, so 20 never reaches the action.
    let width = paneColumnWidthAfterDrag(startWidth: 120, translation: -100)
    await model.dispatchFromSurface("pane_set_column_width", .object([
        "pane": .string(id), "column": .string("name"), "width": .number(width)]))

    let pane = try #require(model.layoutSnapshot.panes.first { $0.id == id })
    #expect(pane.columnWidths["name"] == paneColumnMinimumWidth)
    // Journalled from the pointer, like every other interaction on the
    // surface — Invariant 2 has no exception for a drag.
    let entry = try #require(
        try await registry.journalEntries().first { $0.action == "pane_set_column_width" })
    #expect(entry.origin == .ui)
}

// MARK: - Header alignment (final review Finding 4)

/// §2.1 forbids a pinned `Section` header, so the header and the rows live
/// in different scroll contexts and their horizontal offset is shared by
/// hand. The first version of that latched an origin from the first
/// `.global` measurement and subtracted it — and `.global` moves when the
/// pane moves, because `Canvas` positions a pane with `.offset(x:)`. So
/// dragging a pane 200pt right drew its header 200pt off its columns and,
/// because the subtrahend was latched, left it there: values under the
/// wrong column name.
@Test func movingThePaneDoesNotMoveTheHeaderOffItsColumns() {
    // At rest: the rows' leading edge is the surface's leading edge, and
    // the header sits square on its columns.
    #expect(paneHeaderOffset(contentLeadingEdge: 400, surfaceLeadingEdge: 400) == 0)
    // The pane is dragged 200pt right. Both edges move together, because
    // an `.offset` on the pane moves everything inside it, so the header
    // must not move relative to its columns at all.
    #expect(paneHeaderOffset(contentLeadingEdge: 600, surfaceLeadingEdge: 600) == 0)
    // And back left, past the window origin.
    #expect(paneHeaderOffset(contentLeadingEdge: -150, surfaceLeadingEdge: -150) == 0)
}

@Test func theHeaderTracksHorizontalScrollingAndOnlyThat() {
    // Scrolled 120pt right: the content's leading edge has gone left of
    // the surface's, and the header follows it exactly.
    #expect(paneHeaderOffset(contentLeadingEdge: 280, surfaceLeadingEdge: 400) == -120)
    // The same scroll, with the pane also dragged 200pt right. The scroll
    // is the whole of the answer; the drag contributes nothing.
    #expect(paneHeaderOffset(contentLeadingEdge: 480, surfaceLeadingEdge: 600) == -120)
}

/// The rows are leading-aligned inside their scroll view, so their leading
/// edge cannot be right of the surface's. A positive difference is a
/// measurement taken mid-layout, and acting on one would push the header
/// right of its columns — the same failure in a smaller place.
@Test func aHeaderOffsetIsNeverPositive() {
    #expect(paneHeaderOffset(contentLeadingEdge: 420, surfaceLeadingEdge: 400) == 0)
}

/// Before anything has been measured the header draws where an unscrolled
/// surface wants it, rather than at some sentinel.
@Test func anUnmeasuredSurfaceDrawsItsHeaderSquare() {
    #expect(paneHeaderOffset(contentLeadingEdge: nil, surfaceLeadingEdge: 400) == 0)
}

// MARK: - Client-side sort (Task 12)

/// **Both readers, not one.** As first written this asserted only
/// `model.table(...)` — the view's half — and passed while
/// `PaneStore.snapshot`, and so `read_pane`, still reported rows in
/// insertion order (final review Finding 1). It now pins the two against
/// each other, which is the property that matters: one ordering, produced
/// once at the store, so "row 0" names the same row to the operator's
/// luminous edge and to the agent.
@Test @MainActor func refreshPanesAppliesTheRecordedSortIntent() async throws {
    let (registry, panes, layout) = try makeRegistry()
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup())

    // `refreshPanes` now iterates the LAYOUT (Decision 24), so the pane must
    // actually be open there too — not just hold contents in `PaneStore` —
    // or it answers `kind: nil` and never lands in `model.table(_:)`.
    // `open`'s first `"db"` pane is always `"db-1"`.
    _ = await layout.open(kind: "db", title: "Results")
    await panes.setRows(
        paneId: "db-1", columns: ["name"], columnTypes: ["TEXT"], columnTypesInferred: false,
        rows: [[.string("c")], [.string("a")], [.string("b")]], millis: 0, truncated: false,
        pageable: true, offset: 0, sort: [], listsTables: false, editable: nil)
    // `setSort` is gone (2c-ii): `reorder` is the store's own writer now.
    await panes.reorder(paneId: "db-1", sort: [PaneSort(column: "name", direction: .ascending)])
    await model.refreshPanes()
    #expect(model.table("db-1").rows.map { $0.cells[0].text } == ["a", "b", "c"])
    // The agent's half: the very object `read_pane` returns verbatim.
    guard case .object(let snapshot) = await panes.readPane(paneId: "db-1", kind: "db") else {
        Issue.record("snapshot was not an object")
        return
    }
    #expect(snapshot["rows"] == .array([
        .array([.string("a")]), .array([.string("b")]), .array([.string("c")]),
    ]))
    // And the ids the view draws are positions in that same order.
    #expect(model.table("db-1").rows.map(\.id) == [0, 1, 2])
}

// MARK: - Pane row width and accessibility (Task 10 fix round)

/// The width `WakilWindow` caps each column at, given the whole pane's
/// available width divided evenly with `horizontalSpacing` between
/// columns. This is the arithmetic behind Finding 1 of Task 10's fix
/// round: a `Grid` cell with no width constraint grows to fit its content,
/// so one long value would otherwise stretch its column — and the row
/// after it — past whatever is showing it, with nothing to scroll to
/// reach the rest.
@Test func paneColumnWidthDividesAvailableWidthEvenlyMinusSpacing() {
    // 400pt across 4 columns with 16pt between each of the 3 gaps: (400 -
    // 48) / 4 = 88.
    #expect(paneColumnWidth(availableWidth: 400, columnCount: 4, horizontalSpacing: 16) == 88)
    // One column takes the spacing-free whole width.
    #expect(paneColumnWidth(availableWidth: 400, columnCount: 1, horizontalSpacing: 16) == 400)
}

/// However many columns a schema has, no column is ever asked to draw at
/// less than the floor — a wide schema trades "the row fits the available
/// width" for "every column is still legible", never the other way round.
@Test func paneColumnWidthNeverGoesBelowItsFloor() {
    #expect(paneColumnWidth(availableWidth: 100, columnCount: 20, horizontalSpacing: 16) == 60)
    #expect(paneColumnWidth(availableWidth: 100, columnCount: 20, horizontalSpacing: 16, minimum: 40) == 40)
}

/// Total, the same way `paneTable` is: a width or column count that makes
/// no sense (an unmeasured `GeometryReader` reporting 0 before its first
/// real layout pass, or an empty pane) answers with the floor rather than
/// dividing by zero or returning something negative a `.frame(maxWidth:)`
/// would then reject.
@Test func paneColumnWidthIsTotalAgainstDegenerateInput() {
    #expect(paneColumnWidth(availableWidth: 0, columnCount: 4, horizontalSpacing: 16) == 60)
    #expect(paneColumnWidth(availableWidth: 400, columnCount: 0, horizontalSpacing: 16) == 60)
    #expect(paneColumnWidth(availableWidth: -10, columnCount: 4, horizontalSpacing: 16) == 60)
}

/// The fact that makes `WakilWindow`'s `ScrollView` scroll horizontally as
/// well as vertically necessary: enough columns, each floored at its
/// legibility minimum, add up to more than the pane actually has —
/// exactly the reviewer's own example (20 columns, 16pt spacing, 100pt
/// pane): 60 × 20 + 16 × 19 = 1504, which is nowhere near 100.
@Test func paneRowOverflowsAvailableWidthOnceTheFlooredTotalExceedsIt() {
    #expect(paneRowOverflowsAvailableWidth(availableWidth: 100, columnCount: 20, horizontalSpacing: 16))
}

/// The complementary fact: when there are few enough columns that
/// `paneColumnWidth` never has to floor any of them, dividing the
/// available width evenly consumes exactly that width and no more — the
/// row fits, and horizontal scrolling has nothing to do.
@Test func paneRowFitsAvailableWidthWhenNoColumnIsFloored() {
    #expect(!paneRowOverflowsAvailableWidth(availableWidth: 400, columnCount: 4, horizontalSpacing: 16))
}

/// The row-level VoiceOver label Finding 2 of Task 10's fix round adds:
/// every column paired with its value, in column order, which is what a
/// screen reader announces for one row now that `Grid` gives it nothing on
/// its own.
@Test func paneRowAccessibilityLabelPairsEveryColumnWithItsValue() {
    let row = PaneRow(id: 0, cells: [PaneCell(.string("1")), PaneCell(.string("widgets"))])
    #expect(paneRowAccessibilityLabel(columns: ["id", "name"], row: row) == "id: 1, name: widgets")
}

/// A cell shorter than `columns` — the same case the view draws as `""` —
/// reads as "empty" in the label rather than as a blank that would vanish
/// between two commas and read as a missing word instead of a value.
@Test func paneRowAccessibilityLabelNamesAMissingCellAsEmpty() {
    let row = PaneRow(id: 0, cells: [PaneCell(.string("1"))])
    #expect(paneRowAccessibilityLabel(columns: ["id", "name"], row: row) == "id: 1, name: empty")
}

// MARK: - Thought thread projection

@Test func thoughtRowCarriesAssistantTextVerbatim() {
    let row = thoughtRow(id: 0, for: .assistantText("hello"))!
    #expect(row.detail == "hello")
    #expect(row.isError == false)
}

@Test func thoughtRowNamesTheToolAndKeepsItsMCPPrefix() {
    let row = thoughtRow(id: 1, for: .toolUse(id: "t1", name: "mcp__wakil__db_run_query", input: .object([:])))!
    #expect(row.detail.contains("mcp__wakil__db_run_query"))
}

/// The whole reason `HarnessEvent.toolResult` carries `isError` (spec §3.1's
/// 2026-09-07 amendment) is that the thought thread must show a refused or
/// failed tool call as such. Probe §6's permission refusal arrives exactly
/// this way.
@Test func thoughtRowMarksAFailedToolResultAsAnError() {
    let refused = thoughtRow(
        id: 2,
        for: .toolResult(id: "t1", content: .string("Permission for this tool use was denied."), isError: true))!
    let succeeded = thoughtRow(id: 3, for: .toolResult(id: "t2", content: .string("ok"), isError: false))!

    #expect(refused.isError)
    #expect(refused.detail.contains("Permission"))
    #expect(succeeded.isError == false)
}

@Test func thoughtRowMarksAFailedTurnAsAnError() {
    #expect(thoughtRow(id: 4, for: .result(isError: true, text: "boom"))!.isError)
    #expect(thoughtRow(id: 5, for: .result(isError: false, text: "done"))!.isError == false)
}

/// Probe §2 found `.unknown` to be the path most events take — 10 of
/// `basic-turn.jsonl`'s 13 lines are `stream_event`, `rate_limit_event` or
/// `session_state_changed`. 2a drew them, because §7 asked for a plain list
/// of harness events. §9's thread holds perhaps six lines before the live
/// step is pushed off the end, so drawing them buries the four lines that
/// describe work under eleven that do not, and defeats the only claim §9
/// makes. Spec §7.1.
@Test func anUnknownFrameProducesNoRowAtAll() {
    #expect(thoughtRow(id: 6, for: .unknown(type: "rate_limit_event")) == nil)
    #expect(thoughtRow(id: 7, for: .unknown(type: "system")) == nil)
}

@Test func everyEventThatDescribesWorkStillProducesARow() {
    #expect(thoughtRow(id: 0, for: .assistantText("hello")) != nil)
    #expect(thoughtRow(id: 1, for: .toolUse(id: "t", name: "n", input: .object([:]))) != nil)
    #expect(thoughtRow(id: 2, for: .toolResult(id: "t", content: .string("ok"), isError: false)) != nil)
    #expect(thoughtRow(id: 3, for: .result(isError: false, text: "done")) != nil)
    #expect(thoughtRow(id: 4, for: .systemInit(sessionId: "s")) != nil)
}

/// Row ids must stay unique once some events produce no row. `append`
/// numbers from a counter of its own rather than from `thoughts.count`,
/// which would repeat an id after any drop — and `ThoughtRow` is
/// `Identifiable`, so a repeated id makes SwiftUI draw one row twice and
/// omit another.
///
/// Drives the real path — `send` against a `StubHarness`, then events
/// through its stream — rather than a test-only append hook on
/// `WindowModel`: `StubHarness` and `waitUntil` already exist for exactly
/// this (see `sendingStartsTheSessionAndListsTheEventsItProduces` above).
@Test @MainActor func droppedEventsDoNotCollapseRowIds() async throws {
    let (registry, panes, layout) = try makeRegistry()
    let harness = StubHarness()
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in harness }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup())

    await model.send("what is in this table?")
    harness.continuation.yield(.assistantText("one"))
    harness.continuation.yield(.unknown(type: "rate_limit_event"))
    harness.continuation.yield(.assistantText("two"))

    // 2d-ii: the sent turn is a `you` row first, then the two kept events.
    #expect(await waitUntil { model.thoughts.map(\.detail) == ["what is in this table?", "one", "two"] },
            "\(model.thoughts)")
    #expect(Set(model.thoughts.map(\.id)).count == model.thoughts.count)
}

/// Finding 1 of the final review (2026-09-09): `.unknown` events are still
/// dropped from `thoughts` — the assertion above already covers that — but
/// `append` now offers a debug route for exactly the case that drop makes
/// invisible: a session stalled mid-turn with nothing on screen to show
/// for it. Gated on `WAKIL_DEBUG_EVENTS` in the process environment in
/// production; this test flips `debugEventsEnabledOverride` instead of the
/// real environment variable, which two tests running in parallel — Swift
/// Testing's default — could race on. `debugEventSink` stands in for the
/// real stderr write — the seam exists so this test can assert on what
/// left the model without capturing the process's actual file descriptor 2.
@Test @MainActor func unknownEventsAreDroppedButReachTheDebugSinkWhenEnabled() async throws {
    let (registry, panes, layout) = try makeRegistry()
    let harness = StubHarness()
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in harness }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup())

    var captured: [String] = []
    model.debugEventSink = { captured.append($0) }
    model.debugEventsEnabledOverride = true

    await model.send("what is in this table?")
    harness.continuation.yield(.unknown(type: "rate_limit_event"))
    harness.continuation.yield(.assistantText("kept"))

    #expect(await waitUntil { model.thoughts.count == 2 }, "\(model.thoughts)")
    // Dropped from the thread: the operator's own `you` row, then only the
    // kept event...
    #expect(model.thoughts.map(\.detail) == ["what is in this table?", "kept"])
    // ...but not from the debug sink: both events reached it, including
    // the one the thread never shows.
    #expect(await waitUntil { captured.count == 2 }, "\(captured)")
    #expect(captured.contains { $0.contains("unknown") && $0.contains("rate_limit_event") })
    #expect(captured.contains { $0.contains("assistantText") })
}

/// The debug route is opt-in. With the override forced `false` — standing
/// in for an unset `WAKIL_DEBUG_EVENTS` — the sink must never fire: an
/// operator who has not asked for the dump is in the position the old spec
/// risk wrongly claimed everyone already was in.
@Test @MainActor func theDebugSinkIsSilentWhenDisabled() async throws {
    let (registry, panes, layout) = try makeRegistry()
    let harness = StubHarness()
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in harness }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup())

    var captured: [String] = []
    model.debugEventSink = { captured.append($0) }
    model.debugEventsEnabledOverride = false

    await model.send("what is in this table?")
    harness.continuation.yield(.unknown(type: "rate_limit_event"))
    harness.continuation.yield(.assistantText("kept"))

    // 2d-ii: the `you` row, then "kept" — waiting for both, so the
    // assertion cannot pass before the events have been handled.
    #expect(await waitUntil { model.thoughts.map(\.detail) == ["what is in this table?", "kept"] },
            "\(model.thoughts)")
    #expect(captured.isEmpty, "\(captured)")
}

// MARK: - Dispatch wiring

/// Invariant 2: a UI control changes state only by dispatching, and the
/// journal must be able to say afterwards that the UI is what asked. This
/// is the first `origin: .ui` dispatch in production code.
@Test @MainActor func everyWindowControlDispatchesWithTheUIOrigin() async throws {
    let (registry, panes, layout) = try makeRegistry()
    let seen = HarnessLog()
    for name in ["ctx_set_project", "ctx_set_environment", "db_run_query"] {
        await registry.register(Action(
            name: name, description: "", kind: .read, schema: .object([:]),
            handler: { _ in await seen.add(name); return .object([:]) }))
    }
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup())

    await model.setProject("widgets")
    await model.setEnvironment("staging")
    await model.runQuery("select 1", database: nil, pane: nil)

    let entries = try await registry.journalEntries()
    #expect(entries.map(\.action) == ["ctx_set_project", "ctx_set_environment", "db_run_query"])
    #expect(entries.allSatisfy { $0.origin == .ui })
    #expect(entries.allSatisfy { $0.outcome == "ok" }, "\(entries)")
    #expect(await seen.entries.count == 3)
}

/// The model reads the pane back through `PaneStore` after dispatching,
/// rather than building rows from the action's return value. That is
/// Invariant 2 in the small: the table shows registry-owned state, not a
/// reconstruction the UI made for itself.
@Test @MainActor func runningAQueryRefreshesTheTableFromThePaneStore() async throws {
    let (registry, panes, layout) = try makeRegistry()
    await registry.register(Action(
        name: "db_run_query", description: "", kind: .read, schema: .object([:]),
        handler: { _ in
            await panes.setRows(
                paneId: "db", columns: ["n"], columnTypes: [], columnTypesInferred: false,
                rows: [[.number(7)]], millis: 0, truncated: false,
                pageable: true, offset: 0, sort: [], listsTables: false, editable: nil)
            return .object(["ignored": .bool(true)])
        }))
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup())

    // `refreshPanes` iterates the LAYOUT (Decision 24), so the default
    // `"db"` pane `runQuery` targets must actually exist there too.
    await layout.load(
        LayoutSnapshot(panes: [
            Pane(id: "db", kind: "db", title: "db", frame: PaneFrame(x: 0, y: 0, width: 100, height: 100))
        ]), for: .initial)

    await model.runQuery("select 7", database: nil, pane: nil)

    #expect(model.table("db").columns.map(\.name) == ["n"])
    #expect(model.table("db").rows.map { $0.cells.map(\.text) } == [["7"]])
}

// MARK: - dispatchFromSurface (Task 11)

/// What a click inside a `DataSurface` goes through for an ordinary
/// content action. `pane_select_cell` writes to `PaneStore`, so this is
/// the "everything but `pane_set_column_width`" half of
/// `dispatchFromSurface`: it dispatches, then refreshes — landing in
/// `PaneStore` AND showing up in `model.table(_:)` from that one call, not
/// merely dispatched into a store nobody re-read.
@Test @MainActor func dispatchFromSurfaceRoutesASelectionThroughPaneStoreAndRefreshesTheTable() async throws {
    let (registry, panes, layout) = try makeRegistry()
    await registerPaneContentActions(into: registry, panes: panes, layout: layout)
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup())

    // `refreshPanes` iterates the LAYOUT (Decision 24), so the pane must be
    // open there too, not just hold contents in `PaneStore`. `open`'s
    // first `"db"` pane is always `"db-1"`.
    _ = await layout.open(kind: "db", title: "Results")
    await panes.setRows(
        paneId: "db-1", columns: ["id"], columnTypes: ["INTEGER"], columnTypesInferred: false,
        rows: [[.number(1)]], millis: 0, truncated: false,
        pageable: true, offset: 0, sort: [], listsTables: false, editable: nil)

    await model.dispatchFromSurface(
        "pane_select_cell",
        .object(["pane": .string("db-1"), "row": .number(0), "column": .string("id")]))

    // Landed in PaneStore.
    let stored = await panes.readPane(paneId: "db-1", kind: "db")
    guard case .object(let obj) = stored, case .object(let selection)? = obj["selection"] else {
        Issue.record("expected a selection object, got \(stored)")
        return
    }
    #expect(selection["anchorRow"] == .number(0))

    // And reflected back — the refresh dispatchFromSurface performs after
    // dispatching, not just a write nothing re-read.
    #expect(model.table("db-1").selection.anchorRow == 0)

    let entries = try await registry.journalEntries()
    let entry = try #require(entries.first { $0.action == "pane_select_cell" })
    #expect(entry.origin == .ui)
}

/// The one name `dispatchFromSurface` routes differently: a column width
/// lives on `Pane`, in `LayoutStore`, not in `PaneStore`, so it must reach
/// `model.layoutSnapshot` through `dispatchLayout` rather than through
/// `dispatch` + `refreshPanes` — the ordinary path above would dispatch
/// the action but never read the layout back, and nothing would persist
/// it either.
///
/// **Load-bearing**: commenting out the `if name ==
/// "pane_set_column_width"` special case in `dispatchFromSurface` (so it
/// falls through to `dispatch` + `refreshPanes` like every other name)
/// makes this test fail — `model.layoutSnapshot` is never re-read, so the
/// width dispatched into `LayoutStore` is invisible to it. Confirmed by
/// hand while writing this test, then the routing was restored.
@Test @MainActor func dispatchFromSurfaceRoutesColumnWidthThroughLayoutNotPaneStore() async throws {
    let (registry, panes, layout) = try makeRegistry()
    await registerPaneContentActions(into: registry, panes: panes, layout: layout)
    await registerLayoutActions(into: registry, layout: layout)
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup())

    await model.openPane(kind: "db")
    let id = try #require(model.layoutSnapshot.panes.first).id

    await model.dispatchFromSurface(
        "pane_set_column_width",
        .object(["pane": .string(id), "column": .string("name"), "width": .number(120)]))

    let pane = try #require(model.layoutSnapshot.panes.first { $0.id == id })
    #expect(pane.columnWidths["name"] == 120)

    let entries = try await registry.journalEntries()
    let entry = try #require(entries.first { $0.action == "pane_set_column_width" })
    #expect(entry.origin == .ui)
}

/// The truncation flag has to reach the window too, not only `read_pane`.
/// The *Run query* control sends no `limit`, so `wakilcore.clampReadLimit`
/// caps every query it runs at 500 rows; a human counting the rows on
/// screen is wrong about a large table in exactly the way an agent reading
/// `rowCount` is, so the same flag answers both.
@Test @MainActor func aTruncatedPaneIsMarkedTruncatedOnTheWindow() async throws {
    let (registry, panes, layout) = try makeRegistry()
    await registry.register(Action(
        name: "db_run_query", description: "", kind: .read, schema: .object([:]),
        handler: { _ in
            await panes.setRows(
                paneId: "db", columns: ["n"], columnTypes: [], columnTypesInferred: false,
                rows: [[.number(7)]], millis: 0, truncated: true,
                pageable: true, offset: 0, sort: [], listsTables: false, editable: nil)
            return .object(["ignored": .bool(true)])
        }))
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup())
    // `refreshPanes` iterates the LAYOUT (Decision 24), so the default
    // `"db"` pane `runQuery` targets must actually exist there too.
    await layout.load(
        LayoutSnapshot(panes: [
            Pane(id: "db", kind: "db", title: "db", frame: PaneFrame(x: 0, y: 0, width: 100, height: 100))
        ]), for: .initial)

    #expect(model.table("db").truncated == false)
    await model.runQuery("select * from customers", database: nil, pane: nil)
    #expect(model.table("db").truncated)
}

/// A refused or broken dispatch has to end up on screen as text, not as a
/// thrown error: there is nowhere above a SwiftUI button for one to go.
@Test @MainActor func aFailedDispatchBecomesVisibleStatusText() async throws {
    let (registry, panes, layout) = try makeRegistry()
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup())

    await model.runQuery("select 1", database: nil, pane: nil)   // nothing registered

    #expect(model.status.contains("db_run_query"), "\(model.status)")
    let entries = try await registry.journalEntries()
    #expect(entries.map(\.outcome) == ["unknown"])
    #expect(entries.map(\.origin) == [.ui])
}

/// An error a caller cannot self-describe: `description` names nothing
/// about which action threw it, unlike `StandardActionError`'s own.
private struct SilentTestError: Error, CustomStringConvertible {
    var description: String { "boom" }
}

/// `StandardActionError.description` already begins with the action for
/// every case (`"\(action): \(message)"`, `StandardActions.swift`) — so
/// `dispatch`'s `catch` must not prepend the action name again on top of
/// it. Before the fix this produced
/// `"test_action: test_action: missing required param \"x\""`.
@Test @MainActor func aStandardActionErrorNamesItsActionExactlyOnceInStatus() async throws {
    let (registry, panes, layout) = try makeRegistry()
    await registry.register(Action(
        name: "test_action", description: "", kind: .read, schema: .object([:]),
        handler: { _ in
            throw StandardActionError.missingParam(action: "test_action", param: "x")
        }))
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup())

    await model.dispatchFromSurface("test_action", .object([:]))

    #expect(model.status == "test_action: missing required param \"x\"", "\(model.status)")
}

/// The other half of the same fix: an error that does NOT name its own
/// action must still get `name`'s prefix — otherwise the fix above could
/// over-correct into "never prefix anything".
@Test @MainActor func anErrorThatDoesNotNameItsActionStillGetsThePrefix() async throws {
    let (registry, panes, layout) = try makeRegistry()
    await registry.register(Action(
        name: "test_action", description: "", kind: .read, schema: .object([:]),
        handler: { _ in throw SilentTestError() }))
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup())

    await model.dispatchFromSurface("test_action", .object([:]))

    #expect(model.status == "test_action: boom", "\(model.status)")
}

// MARK: - dispatchFromSurfaceInOrder (2c-iv Task 5)

/// Send commits a pending body first (Amendment 8c): the two calls must land in order, and the
/// second must not start until the first has returned — so the send reads the written body.
@Test @MainActor func dispatchFromSurfaceInOrderAwaitsEach() async throws {
    let (registry, panes, layout) = try makeRegistry()
    let log = OrderLog()
    await registry.register(Action(
        name: "test_first", description: "", kind: .read, schema: .object([:]),
        handler: { _ in
            await log.append("first started")
            try await Task.sleep(nanoseconds: 50_000_000)
            await log.append("first returned")
            return .object([:])
        }))
    await registry.register(Action(
        name: "test_second", description: "", kind: .read, schema: .object([:]),
        handler: { _ in
            await log.append("second started")
            return .object([:])
        }))
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup())

    await model.dispatchFromSurfaceInOrder([
        ("test_first", .object([:])), ("test_second", .object([:])),
    ])

    #expect(await log.entries == ["first started", "first returned", "second started"])
}

/// A refused first call stops the sequence: a send after a refused body write would send a
/// body other than the one its statement names.
@Test @MainActor func dispatchFromSurfaceInOrderStopsAtARefusal() async throws {
    let (registry, panes, layout) = try makeRegistry()
    let log = OrderLog()
    await registry.register(Action(
        name: "test_first", description: "", kind: .read, schema: .object([:]),
        handler: { _ in throw SilentTestError() }))
    await registry.register(Action(
        name: "test_second", description: "", kind: .read, schema: .object([:]),
        handler: { _ in
            await log.append("second started")
            return .object([:])
        }))
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup())

    await model.dispatchFromSurfaceInOrder([
        ("test_first", .object([:])), ("test_second", .object([:])),
    ])

    #expect(await log.entries.isEmpty)
    #expect(model.status == "test_first: boom", "\(model.status)")
}

private actor OrderLog {
    var entries: [String] = []
    func append(_ entry: String) { entries.append(entry) }
}

// MARK: - the surface chain (2c-iv Amendment 9a)

private actor TestGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var open = false
    func wait() async {
        if open { return }
        await withCheckedContinuation { continuation in waiters.append(continuation) }
    }
    func release() { open = true; waiters.forEach { $0.resume() }; waiters = [] }
}

/// Two calls the pane made separately land in the order it made them: a debounced write and the
/// gesture after it are two enqueues, and the gesture must not overtake the write.
@Test @MainActor func surfaceCallsLandInTheOrderThePaneMadeThem() async throws {
    let (registry, panes, layout) = try makeRegistry()
    let log = OrderLog()
    await registry.register(Action(
        name: "test_first", description: "", kind: .read, schema: .object([:]),
        handler: { _ in
            await log.append("first started")
            try await Task.sleep(nanoseconds: 50_000_000)
            await log.append("first returned")
            return .object([:])
        }))
    await registry.register(Action(
        name: "test_second", description: "", kind: .read, schema: .object([:]),
        handler: { _ in await log.append("second started"); return .object([:]) }))
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup())

    model.enqueueFromSurface(pane: "api-1", building: { _ in [("test_first", .object([:]))] })
    model.enqueueFromSurface(pane: "api-1", building: { _ in [("test_second", .object([:]))] })
    await model.surfaceChainSettled()

    #expect(await log.entries == ["first started", "first returned", "second started"])
}

/// A send is started and not awaited, so a write typed during it, or a Cancel, is not stuck
/// behind it. **Time-limited** (preflight F15): if the detach regresses, the chain waits on the
/// gate forever, and this must fail rather than hang the suite.
@Test(.timeLimit(.minutes(1))) @MainActor func aSendDoesNotHoldTheSurfaceChain() async throws {
    let (registry, panes, layout) = try makeRegistry()
    let log = OrderLog()
    let gate = TestGate()
    await registry.register(Action(
        name: "api_request", description: "", kind: .read, schema: .object([:]),
        handler: { _ in await gate.wait(); return .object([:]) }))
    await registry.register(Action(
        name: "test_after", description: "", kind: .read, schema: .object([:]),
        handler: { _ in await log.append("after"); return .object([:]) }))
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup())

    model.enqueueFromSurface(pane: "api-1", building: { _ in [("api_request", .object([:]))] })
    model.enqueueFromSurface(pane: "api-1", building: { _ in [("test_after", .object([:]))] })
    // The gate opens after ten seconds whatever happens, and says so in the log, so a regressed
    // detach ends in a failed expectation below rather than in the time limit alone.
    let watchdog = Task {
        try await Task.sleep(nanoseconds: 10_000_000_000)
        await log.append("gate opened")
        await gate.release()
    }
    await model.surfaceChainSettled()
    #expect(await log.entries == ["after"])
    watchdog.cancel()
    await gate.release()
}

/// Review Focus 1: the focus mark is released only after the flush queued before it has landed.
/// So an agent's write cannot land between the flush leaving and landing, which would let the
/// flush erase it.
@Test @MainActor func aFocusReleaseWaitsForTheWriteBeforeIt() async throws {
    let (registry, panes, layout) = try makeRegistry()
    let log = OrderLog()
    await registry.register(Action(
        name: "test_flush", description: "", kind: .read, schema: .object([:]),
        handler: { _ in
            try await Task.sleep(nanoseconds: 50_000_000)
            await log.append("focus while flushing: \(await panes.apiFocus(paneId: "api-1").count)")
            return .object([:])
        }))
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup())

    await model.noteApiFocus(pane: "api-1", fields: apiFocusMarks(.path), generation: 1)
    model.enqueueFromSurface(pane: "api-1", building: { _ in [("test_flush", .object([:]))] })
    model.enqueueFocusRelease(pane: "api-1", generation: 2)
    await model.surfaceChainSettled()

    #expect(await log.entries == ["focus while flushing: 2"])
    #expect(await panes.apiFocus(paneId: "api-1").isEmpty)
}

/// Preflight F6: moving from A to B can deliver B's focus-in before A's focus-out. A's flush is
/// queued and B is marked off the chain (`noteApiFocus`, which the pane starts in an unstructured
/// `Task` — just after focus-in, not synchronously with it), **and A stays marked until its flush
/// has landed**: B's own setting rides the chain behind the flush, and only it releases A.
@Test @MainActor func movingToAnotherFieldKeepsTheLeftFieldMarkedUntilItsWriteLands() async throws {
    let (registry, panes, layout) = try makeRegistry()
    let log = OrderLog()
    await registry.register(Action(
        name: "test_flush", description: "", kind: .read, schema: .object([:]),
        handler: { _ in
            try await Task.sleep(nanoseconds: 50_000_000)
            let focus = await panes.apiFocus(paneId: "api-1").sorted().map(\.label)
            await log.append("while flushing: \(focus)")
            return .object([:])
        }))
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup())

    // The cursor arrives in the path (A).
    await model.noteApiFocus(pane: "api-1", fields: apiFocusMarks(.path), generation: 1)
    model.enqueueApiFocus(pane: "api-1", fields: apiFocusMarks(.path), generation: 1)
    await model.surfaceChainSettled()
    // B's focus-in arrives first: A's flush is queued, then B is noted off the chain (awaited
    // here; the pane's `Task` lands it just after focus-in) and set again on the chain.
    model.enqueueFromSurface(pane: "api-1", building: { _ in [("test_flush", .object([:]))] })
    await model.noteApiFocus(pane: "api-1", fields: [.body], generation: 2)
    model.enqueueApiFocus(pane: "api-1", fields: [.body], generation: 2)
    #expect(await panes.apiFocus(paneId: "api-1") == [.path, apiQueryRegionMark, .body])
    await model.surfaceChainSettled()

    #expect(await log.entries == [#"while flushing: ["Path", "Query", "Body"]"#])
    #expect(await panes.apiFocus(paneId: "api-1") == [.body])
}

/// A drop lands after every call the pane queued before it (9a): `bindFromSurface` waits for the
/// chain, so the flush the pane queues for a drop is on the draft before `api_bind` reads it.
@Test @MainActor func aDropWaitsForTheCallsQueuedBeforeIt() async throws {
    let (registry, panes, layout) = try makeRegistry()
    let log = OrderLog()
    await registry.register(Action(
        name: "test_flush", description: "", kind: .read, schema: .object([:]),
        handler: { _ in
            try await Task.sleep(nanoseconds: 50_000_000)
            await log.append("flush returned")
            return .object([:])
        }))
    await registry.register(Action(
        name: "api_bind", description: "", kind: .read, schema: .object([:]),
        handler: { _ in await log.append("bind started"); return .object([:]) }))
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup())

    model.enqueueFromSurface(pane: "api-1", building: { _ in [("test_flush", .object([:]))] })
    _ = await model.bindFromSurface(pane: "api-1", source: "db-1", row: 0)

    #expect(await log.entries == ["flush returned", "bind started"])
}

/// Fix round 1: generations are issued by the window, never counted in the view. A pane view
/// SwiftUI rebuilds starts a fresh `ApiFocusTracker`, while the store keeps its high-water mark
/// for the pane's life, and the fresh view's first focus must still mark and its release still
/// release.
@Test @MainActor func aRebuiltPaneViewsFocusStillMarksAfterTheStoreHasSeenLaterGenerations()
    async throws
{
    let (registry, panes, layout) = try makeRegistry()
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup())
    let request = ApiRequestSnapshot(
        method: "GET", origin: nil, path: [], query: [], headers: [], body: [])
    func feed(_ change: ApiFocusTracker.Change) {
        switch change {
        case .arrived(let fields, _): model.focusFromSurface(pane: "api-1", fields: fields)
        case .released: model.releaseFocusFromSurface(pane: "api-1")
        case .ignored: break
        }
    }

    // The first view: five focus changes, so the store has seen generation 5 or later.
    var first = ApiFocusTracker()
    for _ in 0..<5 {
        feed(first.took(ApiFieldRow(.path), identifier: "api.path", request: request))
        feed(first.lost(identifier: "api.path"))
    }
    await model.surfaceChainSettled()
    #expect(await panes.apiFocus(paneId: "api-1").isEmpty)

    // SwiftUI rebuilds the pane: a fresh tracker, starting from nothing.
    var rebuilt = ApiFocusTracker()
    feed(rebuilt.took(ApiFieldRow(.body), identifier: "api.body", request: request))
    await model.surfaceChainSettled()
    #expect(await panes.apiFocus(paneId: "api-1") == [.body], "the fresh view's focus marks")
    feed(rebuilt.lost(identifier: "api.body"))
    await model.surfaceChainSettled()
    #expect(await panes.apiFocus(paneId: "api-1").isEmpty, "and its release releases")
}

/// Fix round 1: a view SwiftUI tore down never delivered its focus-out. The pane clears its
/// focus when it appears, so a mark the old view held cannot stick, and the agent is not
/// refused for a cursor that is no longer anywhere.
@Test @MainActor func aPaneAppearingClearsAMarkItsTornDownViewLeftBehind() async throws {
    let (registry, panes, layout) = try makeRegistry()
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup())

    model.focusFromSurface(pane: "api-1", fields: apiFocusMarks(.path))
    await model.surfaceChainSettled()
    #expect(await panes.apiFocus(paneId: "api-1") == [.path, apiQueryRegionMark])

    // The view is torn down with the cursor in the path; a new one appears.
    model.releaseFocusFromSurface(pane: "api-1")
    await model.surfaceChainSettled()
    #expect(await panes.apiFocus(paneId: "api-1").isEmpty)
}

/// Fix round 1: the window's generations only ever rise, across windows too.
@Test @MainActor func focusGenerationsOnlyRise() throws {
    let (registry, panes, layout) = try makeRegistry()
    func window() -> WindowModel {
        WindowModel(
            registry: registry, panes: panes, layout: layout, context: nil,
            harnessFactory: { _ in nil }, resumes: ResumeBroker(),
            rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup())
    }
    let one = window()
    let two = window()
    let a = one.nextFocusGeneration()
    let b = two.nextFocusGeneration()
    let c = one.nextFocusGeneration()
    #expect(a < b && b < c)
}

/// Fix round 1: a send is detached, so it cannot stop the calls after it; a batch with a send
/// anywhere but last is refused whole, before anything runs.
@Test @MainActor func aBatchWithASendBeforeItsLastCallIsRefusedWhole() async throws {
    let (registry, panes, layout) = try makeRegistry()
    let log = OrderLog()
    await registry.register(Action(
        name: "api_request", description: "", kind: .read, schema: .object([:]),
        handler: { _ in await log.append("send"); return .object([:]) }))
    await registry.register(Action(
        name: "test_write", description: "", kind: .read, schema: .object([:]),
        handler: { _ in await log.append("write"); return .object([:]) }))
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup())

    await model.dispatchFromSurfaceInOrder([
        ("test_write", .object([:])), ("api_request", .object([:])), ("test_write", .object([:])),
    ])
    #expect(await log.entries.isEmpty)
    #expect(model.status.contains("a send must be the last call of its batch"), "\(model.status)")

    // Last is fine: the write lands, then the send starts.
    await model.dispatchFromSurfaceInOrder([
        ("test_write", .object([:])), ("api_request", .object([:])),
    ])
    #expect(await waitUntil { await log.entries == ["write", "send"] })
}

@Test func onlyTheTwoSendsDetachFromTheChain() {
    #expect(apiSurfaceCallDetaches("api_request"))
    #expect(apiSurfaceCallDetaches("api_send"))
    #expect(!apiSurfaceCallDetaches("api_set_request"))
    #expect(!apiSurfaceCallDetaches("api_cancel"))
}

// MARK: - Harness wiring

@Test @MainActor func sendingStartsTheSessionAndListsTheEventsItProduces() async throws {
    let (registry, panes, layout) = try makeRegistry()
    let harness = StubHarness()
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in harness }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup())

    await model.send("what is in this table?")
    harness.continuation.yield(.systemInit(sessionId: "abc"))
    harness.continuation.yield(.assistantText("two rows"))

    // The leading `you` row (the operator's own turn), then the two events'
    // rows: the session init and the assistant's text.
    #expect(await waitUntil { model.thoughts.count == 3 }, "\(model.thoughts)")
    #expect(model.thoughts.first?.label == "you")
    #expect(model.thoughts.first?.detail == "what is in this table?")
    #expect(model.thoughts.map(\.detail).contains("two rows"))
    // The logged `start:` entry carries the freshly-minted session id and
    // the working directory, neither of which this test can predict, so it
    // checks the prefix rather than the whole entry.
    var entries = await harness.log.entries
    #expect(entries.count == 2)
    #expect(entries[0].hasPrefix("start:"))
    #expect(entries[1] == "send:what is in this table?")

    // A second turn reuses the session rather than starting another one:
    // spec §3.3 assigns one session id per session, not per message.
    await model.send("and now?")
    entries = await harness.log.entries
    #expect(entries.count == 3)
    #expect(entries[0].hasPrefix("start:"))
    #expect(entries[1] == "send:what is in this table?")
    #expect(entries[2] == "send:and now?")
}

/// Standing check 2 in the runbook needs the failure to be legible when the
/// provider environment is not set, rather than a text field that silently
/// does nothing.
@Test @MainActor func sendingWithNoHarnessSaysSoInsteadOfDoingNothing() async throws {
    let (registry, panes, layout) = try makeRegistry()
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup())

    await model.send("hello")

    #expect(!model.status.isEmpty)
}

// MARK: - Resume (2b-v, Task 10)

/// Hands out a fresh `StubHarness` per call and keeps every one it issued,
/// so a test can assert on the harness *before* a resume and the one
/// *after* it independently.
private final class HarnessBox: @unchecked Sendable {
    private(set) var issued: [StubHarness] = []
    /// Consumed by the next `next()` call, then cleared — same
    /// one-shot shape as `StubHarness.nextSendError` and
    /// `.nextStartError`. Lets a test make the *next issued* harness
    /// fail to start without a reference to it (the factory closure
    /// runs inside `resume`, with no test code between construction and
    /// `start`).
    var nextStartError: Error?
    func next() -> AgentHarness? {
        let h = StubHarness()
        if let nextStartError {
            h.nextStartError = nextStartError
            self.nextStartError = nil
        }
        issued.append(h)
        return h
    }
}

/// Registers a `read_session` action returning a fixed thread, so
/// `WindowModel`'s resume path can be tested without `wakil-ctx`.
private func registerFakeReadSession(
    into registry: ActionRegistry, cwd: String,
    entries: [(kind: String, text: String, tool: String, isError: Bool)],
    provider: String = "main", parent: String = ""
) async {
    await registry.register(Action(
        name: "session_read", description: "test double", kind: .read,
        schema: .object(["type": .string("object")]),
        handler: { _ in
            .object(["structuredContent": .object([
                "cwd": .string(cwd),
                "provider": .string(provider),
                "parent": .string(parent),
                "truncated": .bool(false),
                "entries": .array(entries.map { e in
                    .object([
                        "kind": .string(e.kind), "text": .string(e.text),
                        "toolName": .string(e.tool), "isError": .bool(e.isError),
                    ])
                }),
            ])])
        }
    ))
}

@Test @MainActor func resumingReplacesTheHarnessAndRestartsTheEventPump() async throws {
    let (registry, panes, layout) = try makeRegistry()
    // `resume` reads the parent's transcript before it will swap anything
    // (it needs the provider and the cwd) — this test cares about the
    // swap, not the transcript's contents, so the fixture reads back empty.
    await registerFakeReadSession(into: registry, cwd: "/Users/x/proj", entries: [])
    let harnesses = HarnessBox()          // hands out a fresh StubHarness per call
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in harnesses.next() }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup(), environment: "staging")

    await model.send("first")
    let first = harnesses.issued[0]
    #expect(await first.log.entries.contains { $0.hasPrefix("start:") })

    await model.resume(sessionId: "parent-1")

    // The old one was stopped, a new one started as a fork.
    #expect(await first.log.entries.contains("stop"))
    let second = harnesses.issued[1]
    let started = await second.log.entries.first { $0.hasPrefix("start:") }!
    #expect(started.contains(":parent-1:"))

    // And the new stream is being drained: an event on the SECOND harness
    // reaches `thoughts`, which only happens if the pump was replaced.
    second.continuation.yield(.assistantText("from the fork"))
    #expect(await waitUntil { await model.thoughts.contains { $0.detail == "from the fork" } })
}

@Test @MainActor func aResumedSessionRunsInTheDirectoryTheTranscriptRecords() async throws {
    // read_session returns cwd; the launch must use it rather than the
    // project's first root.
    let (registry, panes, layout) = try makeRegistry()
    await registerFakeReadSession(into: registry, cwd: "/Users/x/other-root", entries: [])
    let harnesses = HarnessBox()
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in harnesses.next() }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup(), environment: "staging")

    await model.resume(sessionId: "parent-1")
    let started = await harnesses.issued[0].log.entries.first { $0.hasPrefix("start:") }!
    #expect(started.hasSuffix(":/Users/x/other-root"))
}

@Test @MainActor func aFreshSessionRunsInTheProjectsFirstRoot() async throws {
    let (registry, panes, layout) = try makeRegistry()
    let harnesses = HarnessBox()
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in harnesses.next() }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup(), environment: "staging")
    await model.send("hello")
    let started = await harnesses.issued[0].log.entries.first { $0.hasPrefix("start:") }!
    #expect(started.hasSuffix(":/Users/x/proj"))
    #expect(started.contains(":-:"))     // resumingFrom nil
}

/// The live session's own transcript is filed under the project root the
/// instant it starts, so it is offered by ⌘P exactly like any past
/// session — nothing about it looks special to the palette. Picking it
/// would fork from a file this same window's own process is still
/// appending to, so `resume` must refuse rather than dispatch anything: no
/// `session_read` call (deliberately not registered here — a call would
/// fail the test with an unrelated "no such action" error if the guard
/// let it through) and no second harness minted.
@Test @MainActor func resumingTheSessionAlreadyRunningInThisWindowIsRefused() async throws {
    let (registry, panes, layout) = try makeRegistry()
    let harnesses = HarnessBox()
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in harnesses.next() }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup(), environment: "staging")

    await model.send("first")
    let started = await harnesses.issued[0].log.entries.first { $0.hasPrefix("start:") }!
    // "start:<sessionId>:<parent>:<workingDirectory>" — the id is the
    // second colon-delimited field.
    let ownSessionId = String(started.split(separator: ":")[1])

    await model.resume(sessionId: ownSessionId)

    let statusAfterResume = await model.status
    #expect(statusAfterResume.contains(ownSessionId), "\(statusAfterResume)")
    #expect(harnesses.issued.count == 1, "a second harness was minted despite the guard")
}

@Test @MainActor func theRebuiltThreadCarriesASeamNamingTheParent() async throws {
    let (registry, panes, layout) = try makeRegistry()
    await registerFakeReadSession(into: registry, cwd: "/Users/x/proj", entries: [
        ("user", "run the query", "", false),
        ("assistant", "on it", "", false),
    ])
    let harnesses = HarnessBox()
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in harnesses.next() }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup(), environment: "staging")

    await model.resume(sessionId: "parent-1")
    let details = await model.thoughts.map(\.detail)
    #expect(details.contains("run the query"))
    #expect(details.contains { $0.contains("parent-1") })
    // The seam is last, so the six-row window shows it (design-language §9).
    #expect(await model.thoughts.last!.detail.contains("parent-1"))
}

/// Guards FIX 7's removal of `nextThoughtId = 0` from `rebuiltThread`: with
/// no prior `send`, a freshly constructed model's counter already sits at
/// 0, so calling `resume` first — the shape this test had before — would
/// pass identically whether or not `rebuiltThread` reset the counter, and
/// could not have caught a regression back to resetting it. A live thought
/// minted BEFORE the resume gives the rebuild something it must not reuse:
/// without the fix, `rebuiltThread` would zero the counter and could very
/// plausibly hand a rebuilt row the same id as a row from the era before
/// resume — a stale reference (a UI selection, say) would then silently
/// point at an unrelated row instead of the one it was about, since
/// `ThoughtRow.id` is all a caller has to tell rows apart once `thoughts`
/// has been replaced.
@Test @MainActor func rebuiltRowIdsDoNotCollideWithLiveOnes() async throws {
    let (registry, panes, layout) = try makeRegistry()
    await registerFakeReadSession(into: registry, cwd: "/Users/x/proj", entries: [
        ("assistant", "one", "", false), ("assistant", "two", "", false),
    ])
    let harnesses = HarnessBox()
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in harnesses.next() }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup(), environment: "staging")

    await model.send("first")
    harnesses.issued[0].continuation.yield(.assistantText("before resume"))
    #expect(await waitUntil { await model.thoughts.contains { $0.detail == "before resume" } })
    let idsBeforeResume = await model.thoughts.map(\.id)

    await model.resume(sessionId: "parent-1")
    harnesses.issued[1].continuation.yield(.assistantText("live"))
    #expect(await waitUntil { await model.thoughts.contains { $0.detail == "live" } })
    let idsAfterResume = await model.thoughts.map(\.id)

    #expect(Set(idsAfterResume).count == idsAfterResume.count)
    // The point of the fix: nothing minted after the resume — rebuilt rows
    // or the live event that follows them — reuses an id from before it.
    #expect(Set(idsBeforeResume).isDisjoint(with: Set(idsAfterResume)),
            "before: \(idsBeforeResume), after: \(idsAfterResume)")
}

@Test @MainActor func resumingAcrossProvidersIsRefusedAndNamesBoth() async throws {
    let (registry, panes, layout) = try makeRegistry()
    await registerFakeReadSession(into: registry, cwd: "/Users/x/proj", entries: [], provider: "work")
    let harnesses = HarnessBox()
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in harnesses.next() }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup(), environment: "staging")

    await model.resume(sessionId: "parent-1")
    #expect(await model.status.contains("work"))
    #expect(await model.status.contains("main"))
    #expect(harnesses.issued.isEmpty)     // nothing was launched
}

/// No active provider chosen yet is legitimate, so `providerId` can
/// legitimately be `""`. Before this fix the refusal interpolated it
/// verbatim — "…and this window is running " with nothing after it —
/// which reads as a bug, not a diagnosis. It must now say the provider is
/// unset instead of trailing off.
@Test @MainActor func resumingWithAnUnsetProviderNamesItAsUnsetRatherThanBlank() async throws {
    let (registry, panes, layout) = try makeRegistry()
    await registerFakeReadSession(into: registry, cwd: "/Users/x/proj", entries: [], provider: "work")
    let harnesses = HarnessBox()
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in harnesses.next() }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "", lookup: AlwaysSucceedsCredentialsLookup(), environment: "staging")

    await model.resume(sessionId: "parent-1")
    let status = await model.status
    #expect(status.contains("work"), "\(status)")
    #expect(status.contains("unset"), "\(status)")
    #expect(!status.hasSuffix("is "), "\(status)")
    #expect(harnesses.issued.isEmpty)
}

// MARK: - Task 10: the bottom-edge account indicator's label

/// Task 10's indicator draws `model.providerLabel`, not `model.providerId`
/// directly — the whole point of the extra property is that the view never
/// has to decide what an empty id means. This is the one thing about the
/// indicator this task's brief calls out as testable at all ("an empty
/// provider id produces the honest 'no provider' rendering rather than an
/// empty string"): everything else about the indicator is judged by eye,
/// per the runbook, not by a test.
@Test @MainActor func providerLabelForAnUnsetProviderIsTheHonestWordNotAnEmptyString() async throws {
    let (registry, panes, layout) = try makeRegistry()
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "", lookup: AlwaysSucceedsCredentialsLookup(),
        environment: "staging")

    #expect(await model.providerLabel == "unset")
    #expect(await !model.providerLabel.isEmpty)
}

/// The ordinary case: a provider id that is actually set passes through
/// unchanged, verbatim — never uppercased, abbreviated, or otherwise
/// reshaped into something that would stop matching what `--dispatch
/// session_set_provider` or the org's own config dir call it.
@Test @MainActor func providerLabelForASetProviderIsThatProviderIdVerbatim() async throws {
    let (registry, panes, layout) = try makeRegistry()
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "work", lookup: AlwaysSucceedsCredentialsLookup(),
        environment: "staging")

    #expect(await model.providerLabel == "work")
}

@Test @MainActor func aParkedResumeRequestIsActedOn() async throws {
    let (registry, panes, layout) = try makeRegistry()
    await registerFakeReadSession(into: registry, cwd: "/Users/x/proj", entries: [])
    let broker = ResumeBroker()
    let harnesses = HarnessBox()
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in harnesses.next() }, resumes: broker,
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup(), environment: "staging")
    _ = model

    await broker.request(ResumeRequest(sessionId: "parent-1"))
    // Waits for the logged `start:` entry itself, not merely for a harness
    // to have been issued: `harnessFactory()` runs synchronously inside
    // `resume`, before the `await next.start(...)` that actually writes
    // the log line, so a wait that stopped at "issued" would still race
    // the log write under load — observed as an intermittent crash on this
    // machine when the whole suite runs in parallel, never in isolation.
    #expect(await waitUntil {
        guard let first = harnesses.issued.first else { return false }
        return await first.log.entries.contains { $0.hasPrefix("start:") }
    })
    let started = await harnesses.issued[0].log.entries.first { $0.hasPrefix("start:") }!
    #expect(started.contains(":parent-1:"))
}

/// Finding 1 of the 2b-v acceptance review (2026-09-10): an event already
/// sitting in the OLD harness's stream when `resume` swaps it out must
/// never reach the rebuilt `thoughts` — the `tool_result` for the very
/// `session_resume` call that triggered this swap is exactly such an
/// event in production. `Task.cancel()` alone does not prevent it: an
/// `AsyncStream` keeps delivering values already buffered before
/// `finish()`, regardless of whether the consuming `Task` has been
/// cancelled, so the old pump's `for await` loop would otherwise still
/// call `append` after the seam.
///
/// `holdNextStop` pins the exact gap this needs: the test waits for
/// `"stop"` to appear in the first harness's log — proof `resume` has
/// already bumped `eventPumpGeneration` and is now suspended inside
/// `harness?.stop()` — yields the stale event into a stream `stop` has
/// not yet finished, and only then releases `stop` to let it finish. That
/// makes the race deterministic instead of hoping a natural scheduling
/// window lands it.
@Test @MainActor func staleEventsFromTheSupersededHarnessNeverReachTheRebuiltThread() async throws {
    let (registry, panes, layout) = try makeRegistry()
    await registerFakeReadSession(into: registry, cwd: "/Users/x/proj", entries: [
        ("assistant", "rebuilt line", "", false),
    ])
    let harnesses = HarnessBox()
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in harnesses.next() }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup(), environment: "staging")

    await model.send("first")
    let first = harnesses.issued[0]
    first.holdNextStop = true

    let resumeTask = Task { await model.resume(sessionId: "parent-1") }
    #expect(await waitUntil { await first.log.entries.contains("stop") })
    // `resume` is now parked inside `first.stop()`, past the generation
    // bump and past `thoughts = rebuiltThread(...)`'s eventual assignment
    // — this event is buffered on a stream that has not finished yet, so
    // it WILL be delivered to the old pump once `stop` is released, not
    // silently dropped the way a post-`finish()` yield would be.
    first.continuation.yield(.assistantText("stale from the old session"))
    first.releaseStop()
    await resumeTask.value

    // Give the (now-superseded) old pump every chance to misbehave before
    // asserting it did not: the new pump's own event proves the swap is
    // fully settled, so if the stale event were going to land, it has had
    // at least this long to do it.
    let second = harnesses.issued[1]
    second.continuation.yield(.assistantText("from the fork"))
    #expect(await waitUntil { await model.thoughts.contains { $0.detail == "from the fork" } })

    let details = await model.thoughts.map(\.detail)
    #expect(!details.contains("stale from the old session"), "\(details)")
    #expect(details.contains("rebuilt line"))
}

/// Task 9's analogue to the test just above, for `setProvider` rather
/// than `resume`: `eventPumpGeneration += 1` must run BEFORE `await
/// harness?.stop()` there too, and for the identical reason —
/// `ClaudeCodeCLIHarness.stop()` waits for stdout to finish becoming
/// buffered events, not for this window to have drained them, and
/// `Task.cancel()` does not stop an `AsyncStream` from delivering values
/// already sitting in its buffer.
///
/// **Deliberately does NOT copy `staleEventsFromTheSupersededHarnessNever
/// ReachTheRebuiltThread`'s exact shape, even though it looks like the
/// obvious template.** That test yields the stale event and releases
/// `stop`'s gate in the same breath, then asserts only after both
/// `Task`s have run to completion — which makes it a race between the
/// old pump's task and `resume`'s own continuation resuming, decided by
/// however the scheduler happens to order two simultaneously-ready tasks.
/// Measured directly (a local, reverted-before-commit edit moving
/// `resume`'s own bump below its `stop()` call): that race did not
/// reliably resolve either way on this machine, and the existing test
/// kept passing even with `resume`'s ordering inverted — so copying its
/// shape here would have produced a test that LOOKS like it pins the
/// property without actually doing so.
///
/// This version pins it deterministically instead, by never releasing
/// the gate before checking: the stale event is yielded and given many
/// scheduling turns (`Task.yield()`, not a fixed sleep — this is checking
/// an absence, which a `waitUntil` cannot do) to reach the OLD pump
/// WHILE `setProvider` is still parked inside `harness?.stop()`'s gate,
/// unreleased. At that moment, in the correct ordering, the bump already
/// ran before `stop()` was ever called — so the pump sees the mismatch
/// and drops the event no matter when it gets scheduled to look. In the
/// bug this guards against (bump moved below `stop()`), the bump cannot
/// have run yet — `setProvider`'s own `Task` is still suspended on the
/// gate, which only `releaseStop()` (called AFTER this check) lets it
/// past — so the pump would see the UNCHANGED generation and append the
/// event right here, before the gate is ever released. Confirmed against
/// both orderings — see this task's fix-round report.
@Test @MainActor func staleEventsFromTheSupersededHarnessNeverReachTheClearedThreadAfterASwitch() async throws {
    let (registry, panes, layout) = try makeRegistry()
    let harnesses = HarnessBox()
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in harnesses.next() }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup(), environment: "staging")

    await model.send("first")
    let first = harnesses.issued[0]
    // A `.result` event, not just `.assistantText`: `setProvider` refuses
    // outright while `turnInFlight` is still true, so the turn must
    // actually end before this test can ever reach the swap at all.
    first.continuation.yield(.result(isError: false, text: nil))
    #expect(await waitUntil { await !model.turnInFlight })
    first.holdNextStop = true

    let switchTask = Task { await model.setProvider("work") }
    #expect(await waitUntil { await first.log.entries.contains("stop") })
    // `setProvider` is now parked inside `first.stop()`'s gate — it has
    // not returned from that call, so in the bug this guards against it
    // cannot yet have executed anything textually after it either.
    first.continuation.yield(.assistantText("stale from the old session"))
    for _ in 0..<200 { await Task.yield() }

    // Checked BEFORE the gate is ever released: this is the deterministic
    // half. The correct ordering already changed the generation before
    // `stop()` was called at all, so this must already read empty; the
    // bug this guards against cannot have changed it yet, because nothing
    // has let `setProvider`'s `Task` past the gate to reach that line.
    let detailsWhileGated = await model.thoughts.map(\.detail)
    #expect(!detailsWhileGated.contains("stale from the old session"), "\(detailsWhileGated)")

    first.releaseStop()
    await switchTask.value

    // The new pump's own event proves the swap is fully settled.
    let second = harnesses.issued[1]
    second.continuation.yield(.assistantText("from the switch"))
    #expect(await waitUntil { await model.thoughts.contains { $0.detail == "from the switch" } })

    let details = await model.thoughts.map(\.detail)
    #expect(!details.contains("stale from the old session"), "\(details)")
    #expect(details.contains { $0.contains("main") && $0.contains("work") }, "\(details)")
}

/// Finding 2 of the 2b-v acceptance review (2026-09-10): the brief's own
/// pseudocode stopped the existing harness and overwrote `thoughts`
/// *before* attempting to start the new one, so a `next.start` failure
/// destroyed the working session — process stopped, thread replaced,
/// nothing left to recover. `resume` now starts the replacement first and
/// only touches the existing session once that succeeds; this pins the
/// failure path left behind.
///
/// `sessionId` is private, so "the same session" is checked the way an
/// outside caller actually would: a further `send` reaches the ORIGINAL
/// harness rather than minting a third one (the factory is only ever
/// called when both `harness` and `sessionId` are `nil` — see `send`) —
/// which is only true if the failed resume left both exactly as they
/// were.
@Test @MainActor func aResumeThatFailsToStartLeavesTheExistingSessionUntouched() async throws {
    let (registry, panes, layout) = try makeRegistry()
    await registerFakeReadSession(into: registry, cwd: "/Users/x/proj", entries: [])
    let harnesses = HarnessBox()
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in harnesses.next() }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup(), environment: "staging")

    await model.send("first")
    let first = harnesses.issued[0]
    first.continuation.yield(.assistantText("still here"))
    #expect(await waitUntil { await model.thoughts.contains { $0.detail == "still here" } })
    let idsBefore = await model.thoughts.map(\.id)
    let detailsBefore = await model.thoughts.map(\.detail)

    struct Boom: Error {}
    harnesses.nextStartError = Boom()

    await model.resume(sessionId: "parent-1")

    // The failed resume changed nothing about the session already running.
    #expect(await model.thoughts.map(\.id) == idsBefore)
    #expect(await model.thoughts.map(\.detail) == detailsBefore)
    let statusAfterFailedResume = await model.status
    #expect(statusAfterFailedResume.contains("resume"), "\(statusAfterFailedResume)")

    // And it is still the session in use: sending again reaches the
    // FIRST harness — no third harness was minted, because `send` only
    // calls the factory when both `harness` and `sessionId` are `nil`.
    await model.send("second")
    #expect(harnesses.issued.count == 2, "\(harnesses.issued.count)")
    #expect(await first.log.entries.contains("send:second"))
}

// MARK: - The agent's MCP configuration

private func decodeConfig(_ json: String) throws -> [String: JSONValue] {
    let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    guard case .object(let root) = value, case .object(let servers)? = root["mcpServers"] else {
        Issue.record("not an mcpServers object: \(json)")
        return [:]
    }
    return servers
}

@Test func agentMCPConfigNamesTheShimAndTheAnswerBinaries() throws {
    let json = agentMCPConfigJSON(
        shimExecutable: URL(fileURLWithPath: "/Apps/Wakil.app/Contents/MacOS/Wakil"),
        socketPath: "/tmp/wakil-1.sock",
        binaries: [
            "wakil-pm": URL(fileURLWithPath: "/Apps/Wakil.app/Contents/Resources/wakil-pm"),
            "wakil-recall": URL(fileURLWithPath: "/Apps/Wakil.app/Contents/Resources/wakil-recall"),
            "wakil-git": URL(fileURLWithPath: "/Apps/Wakil.app/Contents/Resources/wakil-git"),
        ],
        place: Place(organization: "personal", project: "", environment: ""),
        provider: "primary")

    let servers = try decodeConfig(json)
    #expect(Set(servers.keys) == ["wakil", "wakil-pm", "wakil-recall", "wakil-git"])
    // 3a-i: wakil-git resolves the project's roots under the org, as wakil-pm resolves its
    // issues, so it is launched with the same environment.
    guard case .object(let git)? = servers["wakil-git"], case .object(let gitEnv)? = git["env"] else {
        Issue.record("no wakil-git env: \(json)")
        return
    }
    #expect(gitEnv["WAKIL_ORG"] == .string("personal"))
    #expect(gitEnv["WAKIL_PROVIDER"] == .string("primary"))

    guard case .object(let shim)? = servers["wakil"] else {
        Issue.record("no wakil server: \(json)")
        return
    }
    #expect(shim["command"] == .string("/Apps/Wakil.app/Contents/MacOS/Wakil"))
    #expect(shim["args"] == .array([.string("--mcp-shim"), .string("--socket"), .string("/tmp/wakil-1.sock")]))

    guard case .object(let pm)? = servers["wakil-pm"], case .object(let env)? = pm["env"] else {
        Issue.record("no wakil-pm env: \(json)")
        return
    }
    #expect(env["WAKIL_ORG"] == .string("personal"))
    #expect(env["WAKIL_PROVIDER"] == .string("primary"))
}

@Test func agentConfigPinsEveryServerToThePlace() throws {
    let servers = try decodeConfig(agentMCPConfigJSON(
        shimExecutable: URL(fileURLWithPath: "/Apps/Wakil.app/Contents/MacOS/Wakil"),
        socketPath: "/tmp/wakil-1.sock",
        binaries: Dictionary(uniqueKeysWithValues: agentFacingServers.map {
            ($0, URL(fileURLWithPath: "/bin/\($0)"))
        }),
        place: Place(organization: "initech", project: "api", environment: "staging"),
        provider: "primary"))

    #expect(servers.count == agentFacingServers.count + 1)
    for (name, server) in servers {
        guard case .object(let entry) = server, case .object(let env)? = entry["env"] else {
            Issue.record("no env for \(name)")
            continue
        }
        #expect(env["WAKIL_ORG"] == .string("initech"), "\(name)")
        #expect(env["WAKIL_PROJECT"] == .string("api"), "\(name)")
        #expect(env["WAKIL_ENVIRONMENT"] == .string("staging"), "\(name)")
    }
}

@Test func agentConfigOmitsEmptyPlaceMembers() throws {
    let servers = try decodeConfig(agentMCPConfigJSON(
        shimExecutable: URL(fileURLWithPath: "/Apps/Wakil.app/Contents/MacOS/Wakil"),
        socketPath: "/tmp/wakil-1.sock",
        binaries: [:],
        place: Place(organization: "initech", project: "api", environment: ""),
        provider: nil))
    guard case .object(let shim)? = servers["wakil"], case .object(let env)? = shim["env"] else {
        Issue.record("no shim env")
        return
    }
    #expect(env["WAKIL_ORG"] == .string("initech"))
    #expect(env["WAKIL_PROJECT"] == .string("api"))
    #expect(env["WAKIL_ENVIRONMENT"] == nil)
}

/// The registry key, not project.json's name, is what a pin carries: the Go side looks
/// `WAKIL_PROJECT` up by key, and the two can differ. The window still draws the name.
@MainActor
@Test func aPlaceCarriesTheRegistryKeyWhileTheWindowDrawsTheName() async throws {
    let client = RecordingToolCaller { name, _ in
        guard name == "get_context" else { return .object([:]) }
        return .object(["structuredContent": .object([
            "Org": .string("initech"),
            "Project": .object(["name": .string("API Service")]),
            "ProjectKey": .string("api"),
            "Environment": .string("staging"),
        ])])
    }
    let model = WindowModel.forTesting(
        scratchRoot: testScratchRoot, organization: "initech", context: ContextStore(client: client))
    await model.refreshContext()

    #expect(model.project == "API Service")
    #expect(model.place == Place(organization: "initech", project: "api", environment: "staging"))
    #expect(model.activeShellContext.project == "api")

    let servers = try decodeConfig(agentMCPConfigJSON(
        shimExecutable: URL(fileURLWithPath: "/Apps/Wakil.app/Contents/MacOS/Wakil"),
        socketPath: "/tmp/wakil-1.sock", binaries: [:], place: model.place, provider: nil))
    guard case .object(let shim)? = servers["wakil"], case .object(let env)? = shim["env"] else {
        Issue.record("no shim env")
        return
    }
    #expect(env["WAKIL_PROJECT"] == .string("api"))

    let shell = model.activeShellContext
    let terminal = terminalChildEnvironment(
        org: shell.org, project: shell.project, environment: shell.environment, base: [:])
    #expect(terminal["WAKIL_PROJECT"] == "api")
}

/// Plan 3: the layout scope is the place, so it is filed under the registry key and the
/// environment — never the display name, which project.json can change under it.
@MainActor
@Test func theScopeIsKeyedByRegistryKeyNotDisplayName() async throws {
    let client = RecordingToolCaller { name, _ in
        guard name == "get_context" else { return .object([:]) }
        return .object(["structuredContent": .object([
            "Org": .string("initech"),
            "Project": .object(["name": .string("API Service")]),
            "ProjectKey": .string("api"),
            "Environment": .string("staging"),
        ])])
    }
    let (registry, panes, layout) = try makeRegistry()
    await registerLayoutActions(into: registry, layout: layout)
    let directory = try windowScratchDirectory()
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout,
        persistence: LayoutPersistence(directory: directory), context: ContextStore(client: client),
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup())
    await model.refreshContext()

    await model.openPane(kind: "db")

    let org = directory.appendingPathComponent("initech")
    #expect(FileManager.default.fileExists(atPath: org.appendingPathComponent("api@staging.json").path))
    let written = try FileManager.default.contentsOfDirectory(atPath: org.path)
    #expect(!written.contains { $0.hasPrefix("API Service") }, "\(written)")
}

/// Spec §2.1: `wakil-ctx`, `wakil-db` and `wakil-http` are "removed from the
/// agent's configuration entirely" — the registry is their only caller, so
/// that the pane is state rather than a reconstruction. With
/// `--strict-mcp-config` this file is the whole server list, so absence here
/// is the enforcement.
@Test func agentMCPConfigNeverExposesThePaneAffectingBinaries() throws {
    let servers = try decodeConfig(agentMCPConfigJSON(
        shimExecutable: URL(fileURLWithPath: "/Apps/Wakil.app/Contents/MacOS/Wakil"),
        socketPath: "/tmp/wakil-1.sock",
        binaries: [
            "wakil-pm": URL(fileURLWithPath: "/bin/wakil-pm"),
            "wakil-ctx": URL(fileURLWithPath: "/bin/wakil-ctx"),
            "wakil-db": URL(fileURLWithPath: "/bin/wakil-db"),
            "wakil-http": URL(fileURLWithPath: "/bin/wakil-http"),
        ],
        place: nil,
        provider: nil))

    #expect(servers["wakil-ctx"] == nil)
    #expect(servers["wakil-db"] == nil)
    #expect(servers["wakil-http"] == nil)
    #expect(servers["wakil-pm"] != nil)
}

// MARK: - The agent's permission allow list

/// **The drift alarm.** `agentAllowedTools` derives from whatever
/// `ActionRegistry.all()` returns, so it cannot fall behind the registry on
/// its own — but this test pins the action set this suite registers against
/// the names spelled out here, so adding, renaming or removing an action
/// fails this test and forces whoever did it to look at the launch's
/// permission surface. A silently stale allow list is a session in which the
/// agent is denied a read or control the registry had already decided was
/// safe (probe §6), and nothing about that failure looks like a permission
/// problem from inside the app.
///
/// It is an equality, not a `contains`: an entry that grants more than the
/// registry does is as much a drift as one that grants less.
///
/// `ctx_set_project` and `ctx_set_environment` are `.control` as of 2b-i
/// Task 9 and were in this list once `agentAllowedTools` admitted `.control`
/// alongside `.read`. They are absent now: both are operator-only, because an
/// agent's place is fixed when its session starts. `read_layout` joins
/// `read_pane` as a second hand-written entry.
@Test func theAllowListIsExactlyTheRegistrysReadAndControlActionsPlusBothReadTools() async {
    // Registering writes nothing: only `dispatch` touches the journal, and
    // nothing here dispatches. The directory is named so a stray write would
    // be obvious rather than landing in the real `~/.wakil`.
    let registry = ActionRegistry(
        journalDirectory: testScratchRoot
            .appendingPathComponent("wakil-allowlist-test-journal"),
        sessionId: "allow-list")
    await registerStandardActions(into: registry, context: nil, panes: PaneStore(), db: nil, resumes: ResumeBroker())

    // ctx_set_provider added by Phase 2b-vi Task 9, and deliberately
    // ABSENT from this list — fix round 1 of the acceptance review caught
    // that it must be, alongside session_set_provider (excluded below by
    // name — see `operatorOnlyActions`'s own doc comment). It is `.control`
    // and would otherwise pass the kind filter, but it writes `active.json`'s Provider
    // field, which `WindowSession.swift` reads
    // (`activeContext?.activeProvider`) to choose which account the NEXT
    // window opens under. An agent that could call it freely still could
    // not swap its OWN running session — that needs `session_set_provider`,
    // which it cannot reach either — but it could choose which account
    // Wakil runs under after the next relaunch: a deferred form of exactly
    // what excluding `session_set_provider` exists to forbid. So it is in
    // `operatorOnlyActions` alongside it, and both are absent here.
    #expect(agentAllowedTools(actions: await registry.all()) == [
        // ctx_list_environments, added 2026-09-20 beside the context line:
        // `.read`, and not in `operatorOnlyActions`. It answers the active
        // project's environment names and whether each is read-only — no
        // host, no DSN, no credential, since the DSN lives in the Keychain
        // and never travels with this listing. The agent cannot switch
        // environment (`ctx_set_environment` is operator-only); the listing
        // tells it which environments exist so it can name the one the work
        // needs to the operator.
        // ctx_config_tree, added by Phase 2e (#198): `.read`, and NOT in
        // `operatorOnlyActions`, so it passes the filter. Decision 30's
        // new asymmetry stated as one line of a list — the agent may read
        // the settings pane's configuration and may drive nothing on it,
        // which is why `settings_open` is `.control` and still absent
        // below. It reports a database's Keychain entry NAME and never a
        // credential's value, which is what puts it beside
        // `ctx_list_providers` rather than beside the org-plane four.
        // Names: `.control` and agent-reachable, for the agent's own conversation.
        "mcp__wakil__conversation_rename",
        "mcp__wakil__ctx_browser_settings",
        "mcp__wakil__ctx_config_tree",
        // ctx_editor_settings, added by 3b-v (Decision 38): `.read` and
        // agent-reachable. Its two writes, `ctx_set_editor_settings` and
        // `ctx_set_project_editor_settings`, are `.control` and
        // operator-only, so they are absent here like `ctx_update_org`.
        "mcp__wakil__ctx_editor_settings",
        // ctx_github_pull_requests, added by 3d-i: `.read`, agent-reachable, active org only.
        "mcp__wakil__ctx_github_pull_requests",
        // ctx_keyboard: `.read`, agent-reachable; ctx_set_key and ctx_set_keys are operator-only.
        "mcp__wakil__ctx_keyboard",
        "mcp__wakil__ctx_list_environments",
        "mcp__wakil__ctx_list_projects",
        // ctx_list_providers, added by Phase 2b-vi Task 12, is `.read`
        // and reads only id/kind/label (never a credential — see
        // `ProviderSummary`'s own doc comment) — no more sensitive than
        // `ctx_list_projects` beside it, and not in `operatorOnlyActions`,
        // which exists for the two actions that actually MOVE an
        // account rather than merely list what is registered.
        "mcp__wakil__ctx_list_providers",
        // db_describe_table, db_list_tables and db_read_table added by
        // Phase 2c-ii Task 10 — the schema browser, each `.read` because
        // it reaches a real database, so all three pass this filter
        // exactly like db_run_query beside them.
        // db_classify_statement, db_page and db_refetch added by Phase
        // 2c-ii Task 11 — the one re-fetch path and the two actions that
        // drive it, plus the classification action the query line needs.
        // All three are `.read`, exactly like the rest of this group.
        // db_cancel, added by the db-pane copy/cancel/detail plan: `.control`, so the
        // registry's own rule allow-lists it, like api_cancel.
        "mcp__wakil__db_cancel",
        "mcp__wakil__db_classify_statement",
        "mcp__wakil__db_describe_table",
        "mcp__wakil__db_list_databases",
        "mcp__wakil__db_list_tables",
        "mcp__wakil__db_page",
        "mcp__wakil__db_read_table",
        "mcp__wakil__db_refetch",
        // db_render_update, added by Task 10 of the record-editing phase,
        // is `.read` too — its own registration comment (beside
        // `db_run_mutation` in `StandardActions.swift`) argues at length
        // for why, given that the connection it opens under the hood is
        // the writable one.
        "mcp__wakil__db_render_update",
        "mcp__wakil__db_run_query",
        // pane_sort moved here from `PaneContentActions.swift` by Phase
        // 2c-ii Task 12 and changed kind from `.control` to `.read`:
        // sorting an incomplete result now reaches a database through
        // `refetchPane`, so it passes this filter exactly like the other
        // database actions above rather than through the `.control` half
        // the filter also allows.
        "mcp__wakil__pane_sort",
        "mcp__wakil__session_get",
        "mcp__wakil__session_list",
        "mcp__wakil__session_read",
        "mcp__wakil__session_record_parent",
        "mcp__wakil__session_resume",
        "mcp__wakil__read_pane",
        "mcp__wakil__read_layout",
        "mcp__wakil-pm",
        "mcp__wakil-recall",
        "mcp__wakil-git",
    ])
}

/// A `.mutate` action is never allowed at the CLI layer, so the first one
/// 2b registers falls through to the CLI's own permission handling rather
/// than being pre-approved by an allow list nobody thought to revisit. That
/// is the seam `--permission-prompt-tool` plugs into; until it exists, an
/// unlisted tool is denied outright in a `-p` session (probe §6), which is
/// the safe direction to fail in.
///
/// That seam exists as of 2026-09-10 (`MCP/PermissionPrompt.swift`): an
/// unlisted `.mutate` action now reaches the bridge, is allowed through by
/// it, and is refused or parked by `dispatch` plus `writeGate` instead — the
/// assertions below are unchanged because what they guard, the allow list
/// itself, is unchanged.
@Test func aMutatingActionIsNeverOnTheAllowList() {
    let mutating = ActionDescriptor(
        name: "http_post", description: "", kind: .mutate,
        schema: .object(["type": .string("object")]))
    let reading = ActionDescriptor(
        name: "http_get", description: "", kind: .read,
        schema: .object(["type": .string("object")]))

    let allowed = agentAllowedTools(actions: [mutating, reading])
    #expect(allowed.contains("mcp__wakil__http_get"))
    #expect(!allowed.contains("mcp__wakil__http_post"))
}

/// The prefix has to be the *same* server name the `--mcp-config` JSON keys
/// the shim under, or every entry names a server that does not exist and
/// grants nothing. Probe §4 recorded the CLI's namespacing as
/// `mcp__<server>__<tool>`; this asserts the two halves of that agree,
/// rather than trusting two string literals to stay equal.
@Test func everyAllowListEntryNamesAServerTheMCPConfigActuallyDefines() throws {
    let servers = try decodeConfig(agentMCPConfigJSON(
        shimExecutable: URL(fileURLWithPath: "/Apps/Wakil.app/Contents/MacOS/Wakil"),
        socketPath: "/tmp/wakil-1.sock",
        binaries: [
            "wakil-pm": URL(fileURLWithPath: "/bin/wakil-pm"),
            "wakil-recall": URL(fileURLWithPath: "/bin/wakil-recall"),
            "wakil-git": URL(fileURLWithPath: "/bin/wakil-git"),
        ],
        place: nil, provider: nil))

    let descriptor = ActionDescriptor(
        name: "db_run_query", description: "", kind: .read,
        schema: .object(["type": .string("object")]))
    for entry in agentAllowedTools(actions: [descriptor]) {
        #expect(entry.hasPrefix("mcp__"), "\(entry) is not in the CLI's namespaced form")
        let rest = String(entry.dropFirst("mcp__".count))
        let server = rest.components(separatedBy: "__").first ?? rest
        #expect(servers[server] != nil, "\(entry) names server \(server), which the --mcp-config does not define")
    }
}

@Test func theAllowListAdmitsControlActionsAndBothReadTools() async {
    let directory = testScratchRoot
        .appendingPathComponent("allow-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let registry = ActionRegistry(journalDirectory: directory, sessionId: "s")
    await registerStandardActions(into: registry, context: nil, panes: PaneStore(), db: nil, resumes: ResumeBroker())
    await registerLayoutActions(into: registry, layout: LayoutStore())
    // Without this the `.mutate` assertion below cannot see `api_send`,
    // and a pin that cannot see the thing it pins is not a pin.
    await registerApiActions(into: registry, panes: PaneStore())

    let allowed = agentAllowedTools(actions: await registry.all())

    // Layout is reachable — that is the whole point of making it .control.
    #expect(allowed.contains("mcp__wakil__pane_move"))
    #expect(allowed.contains("mcp__wakil__pane_snap"))
    // Context switching is operator-only: an agent's place is fixed at session start.
    #expect(!allowed.contains("mcp__wakil__ctx_set_environment"))
    #expect(!allowed.contains("mcp__wakil__ctx_set_project"))
    #expect(allowed.contains("mcp__wakil__read_pane"))
    #expect(allowed.contains("mcp__wakil__read_layout"))
    // **Two `.mutate` actions as of 2c-iv**, and both must be absent from
    // the agent's allow list — the whole point of `agentAllowedTools`
    // filtering on kind. `api_send` is the second: it reaches the
    // permission prompt and then Wakil's own gate, never the allow list,
    // and being `.mutate` is what puts it there structurally rather than
    // by anyone remembering to leave it out.
    let mutating = await registry.all().filter { $0.kind == .mutate }.map(\.name).sorted()
    #expect(mutating == ["api_send", "db_run_mutation"])
    for name in mutating { #expect(!allowed.contains("mcp__wakil__\(name)")) }
}

// MARK: - Layout wiring

/// Builds a model whose registry has both the standard and the layout
/// actions in it — what the window actually gets from `WakilWiring.build`.
@MainActor
private func makeLayoutModel() async throws -> (WindowModel, ActionRegistry, LayoutStore) {
    let (registry, panes, layout) = try makeRegistry()
    await registerStandardActions(into: registry, context: nil, panes: panes, db: nil, resumes: ResumeBroker())
    await registerLayoutActions(into: registry, layout: layout)
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup())
    return (model, registry, layout)
}

@Test @MainActor func openingAPaneThroughTheModelGoesThroughTheRegistry() async throws {
    let (model, registry, _) = try await makeLayoutModel()

    await model.openPane(kind: "db")

    #expect(model.layoutSnapshot.panes.count == 1)
    let entries = try await registry.journalEntries()
    #expect(entries.map(\.action) == ["pane_open"])
    // Every UI control dispatches; none writes layout state directly.
    #expect(entries.map(\.origin) == [.ui])
}

@Test @MainActor func endingADragCommitsExactlyOneAction() async throws {
    let (model, registry, _) = try await makeLayoutModel()
    await model.openPane(kind: "db")
    let id = try #require(model.layoutSnapshot.panes.first).id

    // A drag is a gesture: previewing dispatches nothing, however many
    // frames it runs for. This is spec §4.1 as an assertion.
    for step in 0..<40 {
        await model.previewDrag(id: id, x: Double(step) * 5, y: 700)
    }
    let duringDrag = try await registry.journalEntries().count

    await model.commitDrag(id: id, x: 195, y: 700)

    let after = try await registry.journalEntries()
    #expect(after.count == duringDrag + 1)
    #expect(after.last?.action == "pane_move")
}

@Test @MainActor func aPreviewNearAnotherPaneSurfacesASnapCandidate() async throws {
    let (model, _, _) = try await makeLayoutModel()
    await model.openPane(kind: "db")
    let anchor = try #require(model.layoutSnapshot.panes.first)
    await model.commitDrag(id: anchor.id, x: 400, y: 100)

    await model.openPane(kind: "db")
    let dragged = try #require(model.layoutSnapshot.panes.last)

    // Land the dragged pane's right edge 4pt short of the anchor's left
    // edge, which is now at x = 400.
    await model.previewDrag(id: dragged.id, x: 400 - dragged.frame.width - 4, y: 100)
    #expect(model.dragCandidate != nil)
    #expect(model.dragCandidate?.toPaneId == anchor.id)

    await model.endDrag(id: dragged.id)
    #expect(model.dragCandidate == nil)
}

@Test @MainActor func commitingADragThatWasPreviewingASnapDispatchesPaneSnap() async throws {
    let (model, registry, layout) = try await makeLayoutModel()
    await model.openPane(kind: "db")
    let anchor = try #require(model.layoutSnapshot.panes.first)
    await model.commitDrag(id: anchor.id, x: 400, y: 100)
    await model.openPane(kind: "db")
    let dragged = try #require(model.layoutSnapshot.panes.last)

    let x = 400 - dragged.frame.width - 4
    await model.previewDrag(id: dragged.id, x: x, y: 100)
    await model.commitDrag(id: dragged.id, x: x, y: 100)

    // The snap is what the user was aiming at, so that is what is
    // journalled and what coordinates the edge — not the position they
    // happened to release on.
    let entries = try await registry.journalEntries()
    #expect(entries.last?.action == "pane_snap")
    #expect(await layout.snapshot().graph.neighbours(of: dragged.id, along: .right) == [anchor.id])
}

@Test @MainActor func runningAPaletteActionDispatchesIt() async throws {
    let (model, registry, _) = try await makeLayoutModel()

    _ = await model.performPalette(.run(.dispatch(action: "pane_restore", params: .object([:]))))

    let entries = try await registry.journalEntries()
    #expect(entries.last?.action == "pane_restore")
    #expect(entries.last?.origin == .ui)
}

@Test @MainActor func paletteOpenPanesAreEveryOpenPane() async throws {
    let (model, _, _) = try await makeLayoutModel()
    await model.openPane(kind: "db")
    await model.openPane(kind: "db")

    let rows = await model.paletteRootEntries(mode: .open) { _ in }
    let panes = rows.filter { $0.group == .openPanes }
    #expect(panes.map(\.id) == model.layoutSnapshot.panes.map { "pane:\($0.id)" })
}

// MARK: - Layout persistence

private func windowRepoRoot() -> URL {
    URL(fileURLWithPath: #filePath)          // app/Tests/WakilKitTests/WindowModelTests.swift
        .deletingLastPathComponent()          // WakilKitTests
        .deletingLastPathComponent()          // Tests
        .deletingLastPathComponent()          // app
        .deletingLastPathComponent()          // repo root
}

/// Before `refreshContext()` has answered, the org and the project are both
/// `""`. Writing a layout under an empty org would file it somewhere no
/// later session looks, so the save is skipped entirely — the commit still
/// happens, it is just not persisted yet.
@Test @MainActor func aLayoutCommitWritesNothingUntilTheOrgAndProjectAreKnown() async throws {
    let (registry, panes, layout) = try makeRegistry()
    await registerLayoutActions(into: registry, layout: layout)
    let directory = try windowScratchDirectory()
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout,
        persistence: LayoutPersistence(directory: directory), context: nil,
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup())

    await model.openPane(kind: "db")

    #expect(model.layoutSnapshot.panes.count == 1)
    let written = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(written.isEmpty, "\(written)")
}

/// Spec §4.3: the layout is written on commit. Every dispatch that changes
/// the arrangement persists the snapshot the model just re-read, so what is
/// on disk is the registry-owned state and not a copy the view assembled.
@Test @MainActor func aLayoutCommitIsWrittenUnderTheActiveOrgAndProject() async throws {
    let bin = windowRepoRoot().appendingPathComponent("bin/wakil-ctx")
    try #require(FileManager.default.isExecutableFile(atPath: bin.path), "run `make build` first")
    let home = try makeFixture(org: "acme", projectOrg: "acme", environments: ["dev"])
    let client = try await startedClient(bin: bin, home: home, org: "acme")

    let (registry, panes, layout) = try makeRegistry()
    await registerStandardActions(into: registry, context: client, panes: panes, db: nil, resumes: ResumeBroker())
    await registerLayoutActions(into: registry, layout: layout)
    let directory = try windowScratchDirectory()
    let persistence = LayoutPersistence(directory: directory)
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, persistence: persistence,
        context: ContextStore(client: client),
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup())

    await model.setProject("widgets")
    await model.openPane(kind: "db")
    let id = try #require(model.layoutSnapshot.panes.first).id
    await model.commitDrag(id: id, x: 240, y: 180)

    await client.stop()

    let (saved, note) = persistence.load(for: LayoutScope(organization: "acme", project: "widgets", environment: ""))
    #expect(note == nil)
    #expect(saved == model.layoutSnapshot)
    #expect(saved?.panes.first?.frame.x == 240)
}

/// RE-REVIEW, FIX 1: a window resize writes nothing, however many times it
/// fires.
///
/// `setCanvasSize` is the window reporting a fact about itself — its own
/// doc comment says so, which is why it is not a dispatched action — and
/// `.task(id: geometry.size)` fires it on EVERY size change while an edge
/// is being dragged. With a pane maximized, `LayoutStore.setVoid` moves
/// that pane's frame to follow the canvas, so the snapshot genuinely
/// differs on every tick: once the write moved into `refreshLayout()`
/// (Critical 1), dragging a window edge performed dozens of atomic-rename
/// saves a second. Nothing about that is an arrangement the operator
/// asked to commit.
@Test @MainActor func resizingTheWindowWithAPaneMaximizedWritesNothing() async throws {
    let bin = windowRepoRoot().appendingPathComponent("bin/wakil-ctx")
    try #require(FileManager.default.isExecutableFile(atPath: bin.path), "run `make build` first")
    let home = try makeFixture(org: "acme", projectOrg: "acme", environments: ["dev"])
    let client = try await startedClient(bin: bin, home: home, org: "acme")

    let (registry, panes, layout) = try makeRegistry()
    await registerStandardActions(
        into: registry, context: client, panes: panes, db: nil, resumes: ResumeBroker())
    await registerLayoutActions(into: registry, layout: layout, panes: panes)
    let directory = try windowScratchDirectory()
    let persistence = LayoutPersistence(directory: directory)
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, persistence: persistence,
        context: ContextStore(client: client),
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup())

    await model.setProject("widgets")
    await model.openPane(kind: "db")
    let id = try #require(model.layoutSnapshot.panes.first).id
    await model.toggleMaximize(id: id)
    #expect(model.layoutSnapshot.maximizedId == id)

    // Everything up to here is a real commit and is correctly on disk.
    // Clear it, so that anything written from here on is unmistakably a
    // write the resize caused.
    //
    // **Deleted until it STAYS deleted.** `observationPump` refreshes once
    // per dispatch that ran, on its own schedule, so the open and the
    // maximize can each land a (correct) second write of the same snapshot
    // after the inline one — the harmless double-write the re-review
    // parked. Draining it here is what makes the assertion below about the
    // resize and nothing else.
    let file = directory.appendingPathComponent("acme/widgets@_.json")
    #expect(FileManager.default.fileExists(atPath: file.path))
    let drainedBy = Date().addingTimeInterval(5)
    while Date() < drainedBy {
        try? FileManager.default.removeItem(at: file)
        try? await Task.sleep(nanoseconds: 150_000_000)
        if !FileManager.default.fileExists(atPath: file.path) { break }
    }
    try #require(!FileManager.default.fileExists(atPath: file.path), "the pump never went quiet")

    // One drag of a window edge, as `.task(id: geometry.size)` delivers it.
    for width in stride(from: 1200.0, to: 1210.0, by: 1.0) {
        await model.setCanvasSize(width: width, height: 800)
    }

    // The snapshot really did change every tick — this is what makes the
    // write tempting, and what makes a test that asserts "nothing was
    // written" meaningful rather than vacuous.
    #expect(model.layoutSnapshot.panes.first?.frame.width == 1209)
    await client.stop()
    #expect(!FileManager.default.fileExists(atPath: file.path),
            "a window resize must not write the layout file")
}

/// Spec §4.3: the layout is read at project switch — and a file that cannot
/// be read degrades visibly, in the same `status` channel a refused dispatch
/// uses, rather than silently.
///
/// The last third of this test is the *implicit* switch: a second model,
/// with its own empty `LayoutStore`, restores the active project's canvas
/// from nothing but `refreshContext()` — which is what the window calls at
/// launch, and so is what makes an arrangement survive a restart rather
/// than only a switch away and back.
@Test @MainActor func switchingProjectRestoresItsSavedLayoutAndReportsAnUnreadableOne() async throws {
    let bin = windowRepoRoot().appendingPathComponent("bin/wakil-ctx")
    try #require(FileManager.default.isExecutableFile(atPath: bin.path), "run `make build` first")
    let home = try makeTwoProjectFixture(
        org: "acme", projects: [("widgets", ["dev"]), ("gadgets", ["dev"])])
    let client = try await startedClient(bin: bin, home: home, org: "acme")

    let directory = try windowScratchDirectory()
    let persistence = LayoutPersistence(directory: directory)
    // What an earlier session left behind for one project…
    let earlier = LayoutSnapshot(
        panes: [Pane(
            id: "db-9", kind: "db", title: "db",
            frame: PaneFrame(x: 11, y: 22, width: 300, height: 200))],
        focusedId: "db-9")
    try persistence.save(earlier, for: LayoutScope(organization: "acme", project: "widgets", environment: ""))
    // …and a file for the other that is not a layout at all.
    try "not json".write(
        to: directory.appendingPathComponent("acme/gadgets.json"), atomically: true, encoding: .utf8)

    let (registry, panes, layout) = try makeRegistry()
    await registerStandardActions(into: registry, context: client, panes: panes, db: nil, resumes: ResumeBroker())
    await registerLayoutActions(into: registry, layout: layout)
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, persistence: persistence,
        context: ContextStore(client: client),
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup())

    await model.setProject("gadgets")
    #expect(model.layoutSnapshot.panes.isEmpty)
    #expect(model.status.contains("gadgets"), "\(model.status)")

    await model.setProject("widgets")
    #expect(model.layoutSnapshot == earlier)

    let (secondRegistry, secondPanes, secondLayout) = try makeRegistry()
    await registerStandardActions(into: secondRegistry, context: client, panes: secondPanes, db: nil, resumes: ResumeBroker())
    let relaunched = WindowModel(
        registry: secondRegistry, panes: secondPanes, layout: secondLayout,
        persistence: persistence, context: ContextStore(client: client),
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup())

    await relaunched.refreshContext()

    await client.stop()

    #expect(relaunched.project == "widgets")
    #expect(relaunched.layoutSnapshot == earlier)
}

/// The end-to-end form of final review Finding 6, through a real
/// `wakil-ctx`: two projects, each with a pane called `db-1`, and the
/// second must not draw the first's rows.
///
/// Pane ids are unique within one process, but not across sessions —
/// `LayoutStore.load` raises its counter only from the snapshot being
/// loaded, so two saved projects can each hold a `db-1`, which is exactly
/// what the two saved layouts below are. Before this fix `PaneStore` was
/// keyed by pane id alone and never cleared, so switching to `gadgets` left
/// `widgets`' result set on screen and in `read_pane` under `gadgets`'
/// `db-1`: a different project's, and possibly a different environment's,
/// database.
@Test @MainActor func switchingProjectDoesNotCarryOnesRowsIntoTheOthersPane() async throws {
    let bin = windowRepoRoot().appendingPathComponent("bin/wakil-ctx")
    try #require(FileManager.default.isExecutableFile(atPath: bin.path), "run `make build` first")
    let home = try makeTwoProjectFixture(
        org: "acme", projects: [("widgets", ["dev"]), ("gadgets", ["dev"])])
    let client = try await startedClient(bin: bin, home: home, org: "acme")

    let directory = try windowScratchDirectory()
    let persistence = LayoutPersistence(directory: directory)
    // Both projects were left holding a pane with the same id — the shape
    // that makes the leak reachable at all.
    for project in ["widgets", "gadgets"] {
        try persistence.save(
            LayoutSnapshot(
                panes: [Pane(
                    id: "db-1", kind: "db", title: "db",
                    frame: PaneFrame(x: 10, y: 10, width: 300, height: 200))],
                focusedId: "db-1"),
            for: LayoutScope(organization: "acme", project: project, environment: ""))
    }

    let (registry, panes, layout) = try makeRegistry()
    await registerStandardActions(
        into: registry, context: client, panes: panes, db: nil, resumes: ResumeBroker())
    await registerLayoutActions(into: registry, layout: layout, panes: panes)
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, persistence: persistence,
        context: ContextStore(client: client),
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup())

    await model.setProject("widgets")
    await panes.setRows(
        paneId: "db-1", columns: ["secret"], columnTypes: ["TEXT"], columnTypesInferred: false,
        rows: [[.string("widgets' rows")]], millis: 1, truncated: false,
        pageable: true, offset: 0, sort: [], listsTables: false, editable: nil)
    await model.refreshPanes()
    #expect(model.table("db-1").rows.count == 1)

    await model.setProject("gadgets")

    // The screen.
    #expect(model.table("db-1").rows.isEmpty)
    #expect(model.table("db-1").columns.isEmpty)
    // And the agent's half of the same answer.
    guard case .object(let snapshot) = await panes.readPane(paneId: "db-1", kind: "db") else {
        Issue.record("snapshot was not an object")
        await client.stop()
        return
    }
    #expect(snapshot["rowCount"] == .number(0))
    #expect(snapshot["rows"] == .array([]))

    // Back again: §13 says a pane is never torn down on a switch and its
    // state stays warm, so `widgets` finds its rows where it left them.
    await model.setProject("widgets")
    #expect(model.table("db-1").rows.count == 1)

    await client.stop()
}

// MARK: - ⌘P sources

/// `ctx_list_projects` answers with `structuredContent.projects` as a JSON
/// **object keyed by project name** (`wakilcore.ProjectListing.Projects` is
/// a `map[string]ProjectEntry`), and the entries themselves carry only
/// `path` and `provider` — no `name`. A parser that reads it as an array of
/// records, or looks for a `name` field inside each entry, produces an empty
/// ⌘P against a real org with real projects. This test drives the real
/// binary precisely because that mismatch is invisible to a hand-built
/// fixture that agrees with the parser.
@Test @MainActor func paletteListsEveryProjectInTheActiveOrg() async throws {
    let bin = windowRepoRoot().appendingPathComponent("bin/wakil-ctx")
    try #require(FileManager.default.isExecutableFile(atPath: bin.path), "run `make build` first")
    let home = try makeTwoProjectFixture(
        org: "acme", projects: [("widgets", ["dev"]), ("gadgets", ["dev"])])
    let client = try await startedClient(bin: bin, home: home, org: "acme")

    let (registry, panes, layout) = try makeRegistry()
    await registerStandardActions(into: registry, context: client, panes: panes, db: nil, resumes: ResumeBroker())
    await registerLayoutActions(into: registry, layout: layout)
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout,
        context: ContextStore(client: client),
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup())

    let rows = await model.paletteRootEntries(mode: .open) { _ in }

    await client.stop()

    let projects = rows.filter { $0.group == .projects && !$0.isError }
    // Sorted, because a JSON object has no order and a palette whose rows
    // moved between openings would be unusable.
    #expect(projects.map(\.id) == ["project:gadgets", "project:widgets"])
    #expect(projects.map(\.title) == ["gadgets", "widgets"])
    // The subtitle is the entry's provider or, failing that, its path —
    // both of which live on the value, unlike the name.
    #expect(projects.allSatisfy { !$0.subtitle.isEmpty }, "\(projects)")
    #expect(!rows.contains { $0.group == .projects && $0.isError }, "\(rows)")
}

/// Writes a minimal provider record directly under a scratch `HOME`,
/// mirroring `StandardActionsTests.swift`'s identically-named,
/// identically-built helper — duplicated rather than shared because both
/// are small file-private conveniences and Swift gives no way to import
/// one test file's `private` from another.
private func writeProviderFixture(home: URL, org: String, id: String, label: String? = nil) throws {
    let dir = home.appendingPathComponent(".wakil/orgs/\(org)/providers")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let body = label.map { #"{"kind":"local","label":"\#($0)"}"# } ?? #"{"kind":"local"}"#
    try body.write(to: dir.appendingPathComponent("\(id).json"), atomically: true, encoding: .utf8)
}

/// Task 12's fix for the sub-phase's headline defect: acceptance found
/// `session_set_provider` had no palette route to it at all, because
/// nothing in ⌘P ever listed a provider to select. This drives the real
/// `ctx_list_providers` tool (Task 12, Go side) the way
/// `paletteListsEveryProjectInTheActiveOrg` above drives
/// `ctx_list_projects`, and additionally proves the one thing that test
/// has no analogue for: the row naming the account THIS window is
/// already running (`providerId: "main"` below) is marked distinguishably
/// from the other, so an operator opening ⌘P mid-session can tell which
/// account they are on without leaving the palette.
@Test @MainActor func paletteListsEveryProviderInTheActiveOrgAndMarksTheRunningOne() async throws {
    let bin = windowRepoRoot().appendingPathComponent("bin/wakil-ctx")
    try #require(FileManager.default.isExecutableFile(atPath: bin.path), "run `make build` first")
    let home = try makeFixture(org: "acme", projectOrg: "acme", environments: ["dev"])
    try writeProviderFixture(home: home, org: "acme", id: "main")
    try writeProviderFixture(home: home, org: "acme", id: "work", label: "Work account")
    let client = try await startedClient(bin: bin, home: home, org: "acme")

    let (registry, panes, layout) = try makeRegistry()
    await registerStandardActions(into: registry, context: client, panes: panes, db: nil, resumes: ResumeBroker())
    await registerLayoutActions(into: registry, layout: layout)
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout,
        context: ContextStore(client: client),
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup())

    let rows = await model.paletteRootEntries(mode: .open) { _ in }

    await client.stop()

    let providers = rows.filter { $0.group == .providers && !$0.isError }
    // Sorted by id — ListProvidersFor's own contract (Go side).
    #expect(providers.map(\.id) == ["provider:main", "provider:work"])
    let running = try #require(providers.first { $0.id == "provider:main" })
    #expect(running.subtitle.contains("running"), "\(running)")
    let other = try #require(providers.first { $0.id == "provider:work" })
    #expect(!other.subtitle.contains("running"), "\(other)")
    // Every provider row names its kind, running or not. Pinned because
    // the operator's 2026-09-11 walk found that without it a provider row
    // is indistinguishable from a session row: a session's subtitle is the
    // provider id it ran under, and a provider's title is that same id, so
    // searching "main" returned four sessions subtitled `main` beside one
    // provider titled `main`. "account" is the word the bottom-edge
    // indicator uses, and the window uses one word for one thing.
    #expect(running.subtitle.hasPrefix("account"), "\(running)")
    #expect(other.subtitle.hasPrefix("account"), "\(other)")
    // The label, when set, is the title — "work" has one, "main" does not
    // and falls back to its id.
    #expect(other.title == "Work account")
    #expect(running.title == "main")
    #expect(!rows.contains { $0.group == .providers && $0.isError }, "\(rows)")
}

/// An empty ⌘P must be distinguishable from a ⌘P that could not be filled.
/// With no context client all three sources fail, the palette still opens
/// with whatever it does have, and each source that could not answer is
/// one error row naming it (rule 8: never hidden, never the status line) — `ctx_list_providers` (Task 12) joins `ctx_list_projects`
/// and `session_list` here for the identical reason.
/// The Landing's half of the same rule: its Continue column reads sessions, and whatever the
/// sessions, projects or providers could not answer is said on the status line it draws.
@Test @MainActor func theLandingSaysWhichReadsCouldNotAnswer() async throws {
    let (model, _, _) = try await makeLayoutModel()

    #expect(await model.landingSessions().isEmpty)

    #expect(model.status.contains("ctx_list_projects"), "\(model.status)")
    #expect(model.status.contains("session_list"), "\(model.status)")
    #expect(model.status.contains("ctx_list_providers"), "\(model.status)")
}

@Test @MainActor func aPaletteSourceThatCannotAnswerSaysSoRatherThanLookingEmpty() async throws {
    let (model, _, _) = try await makeLayoutModel()

    let rows = await model.paletteRootEntries(mode: .open) { _ in }

    let errors = rows.filter(\.isError).map(\.subtitle).joined(separator: "\n")
    #expect(!rows.contains { [.projects, .sessions, .providers].contains($0.group) && !$0.isError })
    #expect(errors.contains("ctx_list_projects"), "\(errors)")
    #expect(errors.contains("session_list"), "\(errors)")
    #expect(errors.contains("ctx_list_providers"), "\(errors)")
}

/// A bare object literal (`["id": .string("s1"), ...]`) as a row in a
/// `[JSONValue]` fixture, matching the shape `session_list` actually
/// returns, rather than every test spelling out `.object([...])` by hand.
/// `JSONValue` lives in the same package as this test target, so the
/// conformance needs no `@retroactive`.
extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}

// MARK: - `sessionItems(from:)` — title precedence and chain collapsing

/// `title` is the CLI's own summary of the conversation (Task 2's
/// `ai-title` record) and beats everything else once it exists.
@Test func thePaletteShowsATitleWhenTheSessionHasOne() async throws {
    let items = WindowModel.sessionItems(from: [
        ["id": .string("s1"), "provider": .string("main"), "title": .string("booking bug"),
         "firstPrompt": .string("why does the booking")],
    ])
    #expect(items.first?.title == "booking bug")
    #expect(items.first?.payload == "s1")
}

/// Without a `title`, the operator's own first prompt (up to 200 runes,
/// Task 5) is the next-best label; without either, the id is the last
/// resort so the row still has something to pick it by.
@Test func thePaletteFallsBackToTheFirstPromptThenTheId() async throws {
    let withPrompt = WindowModel.sessionItems(from: [
        ["id": .string("s1"), "provider": .string("main"), "firstPrompt": .string("why does the booking")],
    ])
    #expect(withPrompt.first?.title == "why does the booking")
    let bare = WindowModel.sessionItems(from: [["id": .string("s2"), "provider": .string("main")]])
    #expect(bare.first?.title == "s2")
}

/// A stored name titles a past conversation by its lineage root: operator, then ai, then the CLI's title.
@Test func aStoredNameTitlesAPastConversationByItsRoot() async throws {
    let row: JSONValue = ["id": .string("s9"), "provider": .string("main"), "lineageRoot": .string("r1"),
                          "title": .string("CLI title"), "firstPrompt": .string("hello")]
    func title(_ names: [String: StoredConversationName]) -> String? {
        PaletteItems.sessionItems(from: [row], names: names).first?.title
    }
    #expect(title(["r1": StoredConversationName(ai: "Model")]) == "Model")
    #expect(title(["r1": StoredConversationName(operator: "Mine", ai: "Model")]) == "Mine")
    #expect(title(["other": StoredConversationName(ai: "Model")]) == "CLI title")
}

@Test func aRowWithNoStoredNameKeepsTodaysTitle() async throws {
    let rows: [JSONValue] = [["id": .string("s1"), "provider": .string("main"), "firstPrompt": .string("why")]]
    #expect(PaletteItems.sessionItems(from: rows, names: ["s1": StoredConversationName(ai: "X")]).first?.title == "why")
    #expect(PaletteItems.sessionItems(from: rows).first?.title == "why")
}

/// 2d-i: a session's first prompt is what was sent, which may carry the
/// identifier note under the typed text. Landing and ⌘P title the row by
/// the typed text alone.
@Test func aSessionTitleFromTheFirstPromptLeavesTheNoteOut() async throws {
    let typed = "what's in transaction read only"
    let sent = typed + "\n\n" + TurnNote.header + "\n- \"transaction read only\" → transaction_read_only (column · staging · core db)"
    let items = WindowModel.sessionItems(from: [
        ["id": .string("s1"), "provider": .string("main"), "firstPrompt": .string(sent)],
    ])
    #expect(items.first?.title == typed)
}

/// What `session_list` sends is cut to 200 runes plus "…" (Go's
/// `truncateRunes`). A typed turn of 112–199 runes is cut inside the
/// note's header, which then has no full header to split on — the title
/// still has to be the typed text alone (parked in #347, reachable in ⌘P
/// once #350 sent firstPrompt).
@Test func aSessionTitleLeavesOutANoteTheFirstPromptCutShort() async throws {
    func cut(_ s: String) -> String { s.count <= 200 ? s : String(s.prefix(200)) + "…" }
    let note = "\n\n" + TurnNote.header + "\n- \"customer id\" → customer_id (column · staging · events db)"
    for length in [110, 111, 112, 150, 198, 199] {
        let typed = String(repeating: "w", count: length)
        let items = WindowModel.sessionItems(from: [
            ["id": .string("s1"), "provider": .string("main"), "firstPrompt": .string(cut(typed + note))],
        ])
        #expect(items.first?.title == typed, "typed \(length) runes")
    }
}

/// A turn longer than the cut keeps its own "…": nothing of the note
/// reached the first prompt, and the typed text really was cut.
@Test func aSessionTitleCutInsideTheTypedTextKeepsItsEllipsis() async throws {
    let typed = String(repeating: "w", count: 250)
    let sent = typed + "\n\n" + TurnNote.header + "\n- \"x\" → x (column · staging · db)"
    let firstPrompt = String(sent.prefix(200)) + "…"
    let items = WindowModel.sessionItems(from: [
        ["id": .string("s1"), "provider": .string("main"), "firstPrompt": .string(firstPrompt)],
    ])
    #expect(items.first?.title == firstPrompt)
}

// A chain of forks is one conversation. Newest-first ordering means the
// child arrives before its parent, so the child is what the operator
// picks and the parent is folded into it.
@Test func aChainOfForksCollapsesToItsNewestMember() async throws {
    let items = WindowModel.sessionItems(from: [
        ["id": .string("child"), "provider": .string("main"), "title": .string("booking bug"),
         "parent": .string("parent")],
        ["id": .string("parent"), "provider": .string("main"), "title": .string("booking bug")],
    ])
    #expect(items.count == 1)
    #expect(items.first?.payload == "child")
    #expect(items.first?.subtitle.contains("resumed") == true)
}

@Test func unrelatedSessionsAreNotCollapsed() async throws {
    let items = WindowModel.sessionItems(from: [
        ["id": .string("a"), "provider": .string("main")],
        ["id": .string("b"), "provider": .string("main")],
    ])
    #expect(items.count == 2)
}

/// Three deep: A forked to B, B forked to C, all three present, newest
/// first. The rule drops a row whose id appears as *some* row's `parent` —
/// not just its immediate child's — so both B (named by C) and A (named by
/// B) are dropped, and only C, the newest, survives. A rule that only
/// looked at immediate parent/child pairs would stop at dropping B and
/// leave A behind as a second, misleading entry for the same conversation;
/// collecting every row's `parent` into one set before dropping anything
/// avoids that.
@Test func aThreeDeepChainCollapsesToTheSingleNewestEntry() async throws {
    let items = WindowModel.sessionItems(from: [
        ["id": .string("c"), "provider": .string("main"), "title": .string("booking bug"),
         "parent": .string("b")],
        ["id": .string("b"), "provider": .string("main"), "title": .string("booking bug"),
         "parent": .string("a")],
        ["id": .string("a"), "provider": .string("main"), "title": .string("booking bug")],
    ])
    #expect(items.count == 1)
    #expect(items.first?.payload == "c")
    #expect(items.first?.subtitle.contains("resumed") == true)
}

/// A parent whose child is not in *this* listing — the child may belong to
/// another project, or its transcript may not be readable — is a session
/// in its own right and must not disappear just because some other row,
/// unrelated to it, happens to be a chain.
@Test func aParentWithNoChildInTheListingIsKept() async throws {
    let items = WindowModel.sessionItems(from: [
        ["id": .string("child"), "provider": .string("main"), "parent": .string("elsewhere")],
        ["id": .string("orphan-parent"), "provider": .string("main")],
    ])
    #expect(items.map(\.payload).sorted() == ["child", "orphan-parent"])
}

/// A node that points INTO a cycle, not one that is part of one. The
/// drop-set guard (`parents`) only protects nodes that are themselves
/// somebody's `parent` — every member of a self-cycle qualifies, so `A`
/// (parent of itself) is dropped before reaching the walk below. `B`,
/// whose only edge is `parent: "a"`, is nobody's `parent` and survives
/// that filter, so it reaches the chain walk with `a -> a -> a -> ...`
/// ahead of it. Without a visited set this call never returns — a hang,
/// not a wrong answer — so the pass/fail signal here is this test timing
/// out (or the whole suite hanging) rather than a failed `#expect`.
@Test func aNodePointingIntoASelfCycleDoesNotHangTheWalk() async throws {
    let items = WindowModel.sessionItems(from: [
        ["id": .string("a"), "provider": .string("main"), "parent": .string("a")],
        ["id": .string("b"), "provider": .string("main"), "parent": .string("a")],
    ])
    // `a` is in the drop set (it is its own parent); `b` is not.
    #expect(items.map(\.payload) == ["b"])
}

// MARK: - `providerItems(from:running:)` — Task 12: marking the running provider

/// The whole point of `providerPaletteItems()` existing: the row naming
/// whichever provider `running` names must read differently from every
/// other row, so an operator scanning ⌘P can tell which account this
/// window is already on without leaving the palette. `payload` carries
/// the id, never the label — ⌘P's provider row (`.setProvider`) hands
/// `payload` straight to `setProvider(_:)`, which resolves credentials by
/// id, so a payload that were the label instead would send it a string
/// no lookup can ever find.
@Test func theRunningProviderIsMarkedDistinctlyInItsPaletteRow() async throws {
    let items = WindowModel.providerItems(from: [
        ["id": .string("main"), "kind": .string("claude-code")],
        ["id": .string("work"), "kind": .string("claude-code"), "label": .string("Work account")],
    ], running: "main")

    let main = try #require(items.first { $0.payload == "main" })
    #expect(main.subtitle.contains("running"), "\(main)")
    #expect(main.title == "main")

    let work = try #require(items.first { $0.payload == "work" })
    #expect(!work.subtitle.contains("running"), "\(work)")
    #expect(work.title == "Work account")
}

/// A provider with no `label` still has to be pickable — the identical
/// "still shows something" contract `sessionItems(from:)` gives a session
/// with neither `title` nor `firstPrompt`. Falling back to the id, rather
/// than to an empty string, is what keeps this row from reading as blank.
@Test func aProviderWithNoLabelFallsBackToItsId() async throws {
    let items = WindowModel.providerItems(
        from: [["id": .string("main"), "kind": .string("claude-code")]], running: "")
    #expect(items.first?.title == "main")
    #expect(items.first?.payload == "main")
    // `running` names nothing this listing carries, so nothing is marked.
    #expect(items.first?.subtitle.contains("running") == false)
}

// MARK: - `orgListings(from:)` and `machineProviderListings(from:)` — Task 14

/// `jiraBase` is omitted on the wire when an org has none (`ctx_list_orgs`'s
/// own doc comment); the plane's "no Jira site" text depends on this
/// parsing to `nil` rather than to an empty string, which is a distinct,
/// wrong answer for a `NULL`-shaped question.
@Test func orgListingsOmitJiraBaseWhenTheWireDoes() async throws {
    let items = WindowModel.orgListings(from: [
        ["id": .string("umbrella"), "jiraBase": .string("https://umbrella.atlassian.net"),
         "accounts": .integer(2)],
        ["id": .string("personal"), "accounts": .integer(1)],
    ])
    let umbrella = try #require(items.first { $0.name == "umbrella" })
    #expect(umbrella.jiraBase == "https://umbrella.atlassian.net")
    #expect(umbrella.accounts == 2)
    let personal = try #require(items.first { $0.name == "personal" })
    #expect(personal.jiraBase == nil)
    #expect(personal.accounts == 1)
}

/// A row with no `id` names no organisation at all and is dropped, the
/// same "cannot be resumed" rule `sessionItems(from:)` applies to a
/// session with no `id`.
@Test func orgListingsDropsARowWithNoId() async throws {
    let items = WindowModel.orgListings(from: [["accounts": .integer(3)]])
    #expect(items.isEmpty)
}

/// `displayName` follows the identical omit-rather-than-blank precedent
/// `jiraBase` already sets (spec §8.1.1: `OrgSummary.DisplayName` is
/// `omitempty` on the Go side) — an org with no display name parses to
/// `nil`, not `""`, so the plane's "fall back to the id" rule has
/// something unambiguous to test against.
@Test func orgListingsParseDisplayNameAndOmitItWhenTheWireDoes() async throws {
    let items = WindowModel.orgListings(from: [
        ["id": .string("initech"), "displayName": .string("Initech Labs"), "accounts": .integer(1)],
        ["id": .string("acceptance-b"), "accounts": .integer(0)],
    ])
    let labs = try #require(items.first { $0.name == "initech" })
    #expect(labs.displayName == "Initech Labs")
    let unnamed = try #require(items.first { $0.name == "acceptance-b" })
    #expect(unnamed.displayName == nil)
}

/// `org` and `homeOrg` are equal on a native registration and differ on a
/// `--share` binding — the one fact the Adopting state's warning exists to
/// surface (T14-R3). Both shapes have to parse correctly or the warning
/// either never fires or fires on every row.
@Test func machineProviderListingsCarryHomeOrgSeparatelyFromOrg() async throws {
    let items = WindowModel.machineProviderListings(from: [
        ["org": .string("acceptance"), "id": .string("main"), "kind": .string("claude-code"),
         "homeOrg": .string("acceptance"), "configDir": .string("/Users/x/.claude-acceptance")],
        ["org": .string("second"), "id": .string("main"), "kind": .string("claude-code"),
         "homeOrg": .string("acceptance"), "configDir": .string("/Users/x/.claude-acceptance"),
         "label": .string("Main")],
    ])
    let native = try #require(items.first { $0.org == "acceptance" })
    #expect(native.homeOrg == "acceptance")
    let shared = try #require(items.first { $0.org == "second" })
    #expect(shared.homeOrg == "acceptance")
    #expect(shared.org != shared.homeOrg)
    #expect(shared.label == "Main")
}

/// A row missing any of `org`/`id`/`kind` names no complete registration
/// and is dropped rather than parsed with a guessed field.
@Test func machineProviderListingsDropsARowMissingARequiredField() async throws {
    let items = WindowModel.machineProviderListings(from: [
        ["org": .string("acceptance"), "id": .string("main")],
    ])
    #expect(items.isEmpty)
}

// MARK: - `adoptionCandidates(from:excluding:)` — Task 14, fix round 1 (Important 1)

private func machineRow(
    org: String, id: String, configDir: String? = nil, homeOrg: String? = nil
) -> WindowModel.MachineProviderListing {
    WindowModel.MachineProviderListing(
        org: org, providerId: id, kind: "claude-code", label: nil, configDir: configDir,
        homeOrg: homeOrg)
}

/// The exact collision the finding named: two UNRELATED physical accounts
/// (different `configDir`s) that happen to share a provider id under two
/// different orgs. De-duplicating on the bare id drops one of them
/// silently; de-duplicating on `configDir` keeps both, because they are
/// two different credential boundaries regardless of the id they share.
@Test func twoUnrelatedAccountsSharingAnIdAreNotCollapsed() async throws {
    let rows = [
        machineRow(org: "personal", id: "main", configDir: "/Users/x/.claude-personal"),
        machineRow(org: "work", id: "main", configDir: "/Users/x/.claude-work"),
    ]
    let candidates = WindowModel.adoptionCandidates(from: rows, excluding: "initech")
    #expect(candidates.count == 2, "\(candidates)")
    #expect(Set(candidates.map(\.configDir)) == ["/Users/x/.claude-personal", "/Users/x/.claude-work"])
}

/// The SAME physical account (one `configDir`) visible under two different
/// orgs — its native home and one earlier `--share` — is one candidate,
/// not two: offering it twice would not be a second real choice.
@Test func theSamePhysicalAccountUnderTwoOtherOrgsIsOneCandidate() async throws {
    let rows = [
        machineRow(org: "personal", id: "main", configDir: "/shared", homeOrg: "personal"),
        machineRow(org: "work", id: "main", configDir: "/shared", homeOrg: "personal"),
    ]
    let candidates = WindowModel.adoptionCandidates(from: rows, excluding: "initech")
    #expect(candidates.count == 1, "\(candidates)")
}

/// An account already registered under the target org — natively, or by an
/// earlier adopt — must not re-offer itself as a candidate for that same
/// org, even though its OWN row in the listing names a different org.
@Test func anAccountAlreadyInTheTargetOrgIsExcludedFromItsOwnCandidates() async throws {
    let rows = [
        machineRow(org: "acceptance", id: "main", configDir: "/a", homeOrg: "acceptance"),
        machineRow(org: "second", id: "main", configDir: "/a", homeOrg: "acceptance"),
    ]
    let candidates = WindowModel.adoptionCandidates(from: rows, excluding: "acceptance")
    #expect(candidates.isEmpty, "\(candidates)")
}

/// With no `configDir` at all (a `--kind codex` account, which Wakil does
/// not manage a directory for), the fallback identity is
/// `(homeOrg ?? org, providerId)` — two rows naming the SAME home and id
/// collapse to one candidate.
@Test func accountsWithNoConfigDirFallBackToHomeOrgAndId() async throws {
    let rows = [
        machineRow(org: "personal", id: "codex1", homeOrg: "home1"),
        machineRow(org: "work", id: "codex1", homeOrg: "home1"),
    ]
    let candidates = WindowModel.adoptionCandidates(from: rows, excluding: "initech")
    #expect(candidates.count == 1, "\(candidates)")
}

/// Still with no `configDir`, but no `homeOrg` naming a shared common
/// home either: the fallback identity then differs per row (`org` itself
/// stands in for `homeOrg`), so two otherwise-identical-looking rows under
/// different orgs are treated as different accounts rather than silently
/// merged on a guess this function cannot actually verify.
@Test func accountsWithNoConfigDirAndNoHomeOrgAreNotMergedAcrossOrgs() async throws {
    let rows = [
        machineRow(org: "personal", id: "codex1"),
        machineRow(org: "work", id: "codex1"),
    ]
    let candidates = WindowModel.adoptionCandidates(from: rows, excluding: "initech")
    #expect(candidates.count == 2, "\(candidates)")
}

// MARK: - Layout persistence, continued

/// `LayoutStore` promises that "coming back to a project finds it as it was
/// left", and `layout.load` replaces an arrangement wholesale. So the saved
/// layout is read **once per project per session**, not once per stretch of
/// being the active one: a pane the agent opened — which goes straight to
/// `LayoutStore` and is not persisted by this model — must survive a trip
/// to another project and back, rather than being overwritten by whatever
/// was last written to disk.
@Test @MainActor func returningToAProjectKeepsWhatWasOpenedThereSinceTheLoad() async throws {
    let bin = windowRepoRoot().appendingPathComponent("bin/wakil-ctx")
    try #require(FileManager.default.isExecutableFile(atPath: bin.path), "run `make build` first")
    let home = try makeTwoProjectFixture(
        org: "acme", projects: [("widgets", ["dev"]), ("gadgets", ["dev"])])
    let client = try await startedClient(bin: bin, home: home, org: "acme")

    let directory = try windowScratchDirectory()
    let persistence = LayoutPersistence(directory: directory)
    let earlier = LayoutSnapshot(
        panes: [Pane(
            id: "db-9", kind: "db", title: "db",
            frame: PaneFrame(x: 11, y: 22, width: 300, height: 200))],
        focusedId: "db-9")
    try persistence.save(earlier, for: LayoutScope(organization: "acme", project: "widgets", environment: ""))

    let (registry, panes, layout) = try makeRegistry()
    await registerStandardActions(into: registry, context: client, panes: panes, db: nil, resumes: ResumeBroker())
    await registerLayoutActions(into: registry, layout: layout)
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, persistence: persistence,
        context: ContextStore(client: client),
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup())

    await model.setProject("widgets")
    #expect(model.layoutSnapshot.panes.map(\.id) == ["db-9"])

    // The agent opens a pane. It reaches `LayoutStore` through the registry
    // like everything else, and nothing persists it — this model only saves
    // after its own dispatches.
    _ = try await registry.dispatch(
        name: "pane_open", params: .object(["kind": .string("db")]),
        origin: .agent, caller: .test("dev"), confirmation: nil)
    await model.refreshLayout()
    #expect(model.layoutSnapshot.panes.count == 2)

    await model.setProject("gadgets")
    await model.setProject("widgets")

    await client.stop()

    #expect(model.layoutSnapshot.panes.count == 2, "\(model.layoutSnapshot.panes.map(\.id))")
    #expect(model.layoutSnapshot.panes.map(\.id).contains("db-9"))
}

/// Two layout commits can overlap — a drag release landing while a palette
/// command is in flight. Each write is an atomic rename, so unordered
/// writers can leave the *older* snapshot on disk. The writes are chained,
/// which makes the order they land in the order their snapshots were read
/// in, so what is on disk when the dust settles is what is on screen.
///
/// **This guards the end state; it is not a reproducer.** Removing the
/// chain still passes it on this machine — eight small writes started in
/// order happen to finish in order — so it fails only if something makes
/// the ordering *reliably* wrong. The argument for the chain is that
/// nothing guarantees the ordering without it, not that this test can
/// catch every way it might go missing.
@Test @MainActor func concurrentCommitsLeaveTheLatestArrangementOnDisk() async throws {
    let bin = windowRepoRoot().appendingPathComponent("bin/wakil-ctx")
    try #require(FileManager.default.isExecutableFile(atPath: bin.path), "run `make build` first")
    let home = try makeFixture(org: "acme", projectOrg: "acme", environments: ["dev"])
    let client = try await startedClient(bin: bin, home: home, org: "acme")

    let (registry, panes, layout) = try makeRegistry()
    await registerStandardActions(into: registry, context: client, panes: panes, db: nil, resumes: ResumeBroker())
    await registerLayoutActions(into: registry, layout: layout)
    let directory = try windowScratchDirectory()
    let persistence = LayoutPersistence(directory: directory)
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, persistence: persistence,
        context: ContextStore(client: client),
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup())

    await model.setProject("widgets")
    await model.openPane(kind: "db")
    let id = try #require(model.layoutSnapshot.panes.first).id

    // Eight commits started before any of them is awaited. Each `Task`
    // inherits this test's main-actor isolation, so they interleave at
    // every suspension point the way two of the window's own controls do.
    var commits: [Task<Void, Never>] = []
    for step in 1...8 {
        commits.append(Task { await model.commitDrag(id: id, x: Double(step) * 10, y: Double(step) * 5) })
    }
    for commit in commits { await commit.value }

    await client.stop()

    let saved = try #require(persistence.load(for: LayoutScope(organization: "acme", project: "widgets", environment: "")).snapshot)
    #expect(saved == model.layoutSnapshot)
}

/// The write gate compares arrangements, not snapshots, because `busy` is
/// runtime state that moves under it. Here one pane is left busy — as it
/// would be by a dispatch still in flight — while a second dispatch that
/// arranges nothing completes. Without the normalisation that second
/// dispatch sees a difference, calls it a change, and rewrites the file for
/// an arrangement that did not move; worse, what it writes carries the
/// transient flag.
@Test @MainActor func aDispatchThatArrangesNothingWritesNothingEvenWithAPaneBusy() async throws {
    let bin = windowRepoRoot().appendingPathComponent("bin/wakil-ctx")
    try #require(FileManager.default.isExecutableFile(atPath: bin.path), "run `make build` first")
    let home = try makeFixture(org: "acme", projectOrg: "acme", environments: ["dev"])
    let client = try await startedClient(bin: bin, home: home, org: "acme")

    let (registry, panes, layout) = try makeRegistry()
    await registerStandardActions(into: registry, context: client, panes: panes, db: nil, resumes: ResumeBroker())
    await registerLayoutActions(into: registry, layout: layout)
    let directory = try windowScratchDirectory()
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout,
        persistence: LayoutPersistence(directory: directory),
        context: ContextStore(client: client),
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup())

    await model.setProject("widgets")
    await model.openPane(kind: "db")
    await model.openPane(kind: "db")
    let first = try #require(model.layoutSnapshot.panes.first).id
    let second = try #require(model.layoutSnapshot.panes.last).id

    let file = directory.appendingPathComponent("acme").appendingPathComponent("widgets@_.json")
    try #require(FileManager.default.fileExists(atPath: file.path))
    try FileManager.default.removeItem(at: file)

    // `first` is busy, the way a dispatch still in flight leaves it.
    await layout.setBusy(true, id: first)
    // Focusing the already-focused pane arranges nothing at all.
    await model.focusPane(id: second)

    await client.stop()

    #expect(!FileManager.default.fileExists(atPath: file.path))
}

// MARK: - Core state

/// A turn is in flight from a successful `send` until the `.result` event
/// that ends it. Nothing else sets it — spec §4.1.
///
/// Drives the real path — `send` against a `StubHarness`, then a `.result`
/// event through its stream — rather than a test-only setter on
/// `WindowModel`: `StubHarness` and `waitUntil` already exist for exactly
/// this (see `sendingStartsTheSessionAndListsTheEventsItProduces` above),
/// so no hook needs to be added to production code just to flip a boolean.
@Test @MainActor func aTurnInFlightMakesTheCoreThink() async throws {
    let (registry, panes, layout) = try makeRegistry()
    let harness = StubHarness()
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in harness }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup())

    #expect(model.coreState == .idle)
    await model.send("what is in this table?")
    #expect(model.coreState == .thinking)

    harness.continuation.yield(.result(isError: false, text: "done"))
    #expect(await waitUntil { model.coreState == .idle })
}

/// A turn that ended in error still ended. Leaving the Core thinking after
/// a failed turn would be a sphere that never stops.
@Test @MainActor func aFailedTurnAlsoEndsTheThinking() async throws {
    let (registry, panes, layout) = try makeRegistry()
    let harness = StubHarness()
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in harness }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup())

    await model.send("what is in this table?")
    #expect(model.coreState == .thinking)

    harness.continuation.yield(.result(isError: true, text: "boom"))
    #expect(await waitUntil { model.coreState == .idle })
}

/// A `send` with no harness never started a turn, so nothing may be in
/// flight — otherwise the Core thinks forever on a machine with no provider
/// configured, which is the documented degraded launch.
@Test @MainActor func aSendWithNoHarnessLeavesTheCoreIdle() async throws {
    let (registry, panes, layout) = try makeRegistry()
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup())

    await model.send("hello")
    #expect(model.coreState == .idle)
    #expect(!model.status.isEmpty)
}

/// Finding 5 of the final review (2026-09-09): `turnInFlight` used to be
/// set *after* `try await harness.send(text)` returned. `send` suspends on
/// the main actor — in production, while the child's stdin write
/// completes — and the event pump appends on that same actor, so a turn
/// fast enough to land its `.result` inside that suspension had `append`
/// clear the flag first and the line after `harness.send` returns re-set
/// it to `true` with nothing left to ever clear it again: the Core "thinks"
/// forever.
///
/// This reproduces the ordering exactly rather than hoping a scheduler
/// interleaves the same way twice: `StubHarness.holdNextSend` keeps `send`
/// suspended after it has logged the attempt, `.result` is yielded into the
/// stream, and the test waits for `model.thoughts` to prove the event pump
/// actually ran `append` for it — which is the one observable, code-path-
/// independent signal that `turnInFlight` was cleared *during* the
/// suspension — before releasing `send` to return. Against the old
/// ordering this fails (`coreState` is `.thinking` after `send` completes,
/// forever); against the fix it passes.
@Test @MainActor func aResultLandingDuringSendsSuspensionDoesNotStickTurnInFlightBackOn() async throws {
    let (registry, panes, layout) = try makeRegistry()
    let harness = StubHarness()
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in harness }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup())

    harness.holdNextSend = true
    let sendTask = Task { await model.send("what is in this table?") }

    // Wait until `send` has logged the attempt — the point at which it is
    // either about to enter the gate or already inside it.
    var loggedSend = false
    for _ in 0..<400 {
        if await harness.log.entries.contains("send:what is in this table?") {
            loggedSend = true
            break
        }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    #expect(loggedSend)

    harness.continuation.yield(.result(isError: false, text: "done"))

    // Wait until the event pump has actually run `append` for it — proof
    // the flag was cleared during `send`'s suspension, not after.
    #expect(await waitUntil { model.thoughts.contains { $0.label == "turn" } })

    harness.releaseSend()
    await sendTask.value

    #expect(model.coreState == .idle, "turnInFlight was re-set to true after send returned")
}

/// **A turn that has not started yet still has to say so. #284.**
///
/// The window's only sign that a turn is happening is the Core's glow, and
/// `turnInFlight` is not raised until after the credential lookup and the
/// process spawn — the two slow things in a first turn. Until this, an
/// operator who clicked Send during those saw nothing at all: no glow, no
/// text. That is the report this issue carries — *"clicking send sometimes
/// spawned no agent process and produced no status text"* — and the missing
/// text is what made the missing process impossible to read, because every
/// failing path in `send` sets `status`, so an empty one said only that the
/// turn had reached none of them.
///
/// The gate holds `start` open at exactly the stretch in question rather than
/// hoping a scheduler lands there twice the same way.
@Test @MainActor func theWindowSaysItIsStartingTheAgentWhileTheAgentIsStarting() async throws {
    let (registry, panes, layout) = try makeRegistry()
    let harness = StubHarness()
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in harness }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup())
    #expect(model.status.isEmpty)

    harness.holdNextStart = true
    let sendTask = Task { await model.send("what is in this table?") }

    var startedStarting = false
    for _ in 0..<400 {
        if await harness.log.entries.contains(where: { $0.hasPrefix("start:") }) {
            startedStarting = true
            break
        }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    #expect(startedStarting)

    // The window is mid-spawn. This is the moment that used to be silent.
    #expect(!model.status.isEmpty, "a turn being started must not look like a click that was ignored")
    #expect(model.status.contains("starting"))

    harness.releaseStart()
    await sendTask.value

    // And it is gone once the turn is away — nothing clears it but the paths
    // that write their own answer over it.
    #expect(model.status.isEmpty, "the status must not outlive the start it described")
}

/// The same status must not survive a start that failed — the error replaces
/// it, so an operator is never told a turn is starting that already stopped.
///
/// **A guard, not a proof.** It passes with the status line removed too,
/// because then there is nothing to survive. What it pins is the arrangement
/// the status line rests on: nothing clears it, and every path out of `send`
/// writes its own answer over it. Delete one of those writes and this is what
/// notices.
@Test @MainActor func aFailedStartReplacesTheStartingStatusWithTheReason() async throws {
    let (registry, panes, layout) = try makeRegistry()
    let harness = StubHarness()
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in harness }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup())
    harness.nextStartError = NSError(
        domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "the child would not launch"])

    await model.send("what is in this table?")

    #expect(!model.status.contains("starting"), "status = \(model.status)")
    #expect(model.status.contains("the child would not launch"), "status = \(model.status)")
}

/// The other half of Finding 5: a `send` that throws — including one that
/// throws after already having set `turnInFlight = true` — must not leave
/// the flag stuck. A failed send did not start a turn.
@Test @MainActor func aFailedSendClearsTurnInFlightRatherThanLeavingItSet() async throws {
    let (registry, panes, layout) = try makeRegistry()
    let harness = StubHarness()
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in harness }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup())

    struct Boom: Error {}
    harness.nextSendError = Boom()

    await model.send("what is in this table?")

    #expect(model.coreState == .idle)
    #expect(model.status.contains("agent:"), "\(model.status)")
}

// MARK: - Clicking a pane on the canvas

/// The canvas is the third way to focus a pane, alongside the rail and ⌘K.
/// It was the one that was never wired: `LayoutStore.focus`'s own doc
/// comment calls itself "the one call a click on an unfocused pane
/// dispatches", but until this test `Canvas.paneView` carried only a
/// `DragGesture` and a resize handle, so a click that did not move the
/// pointer dispatched nothing at all and focus stayed wherever `open` or
/// `maximize` last put it.
@Test @MainActor func clickingAnUnfocusedPaneFocusesIt() async throws {
    let (model, registry, _) = try await makeLayoutModel()
    await model.openPane(kind: "db")
    let first = try #require(model.layoutSnapshot.panes.first)
    await model.openPane(kind: "db")

    // `open` focuses what it opened, so the second pane holds focus and
    // the first is the unfocused one a click has to be able to reach.
    #expect(model.layoutSnapshot.focusedId != first.id)
    let before = try await registry.journalEntries().count

    await model.paneClicked(id: first.id)

    #expect(model.layoutSnapshot.focusedId == first.id)
    let after = try await registry.journalEntries()
    #expect(after.count == before + 1)
    #expect(after.last?.action == "pane_focus")
    #expect(after.last?.origin == .ui)
}

/// Clicking the pane that already has focus must dispatch nothing.
///
/// Not a micro-optimisation: every dispatch journals, and a click is the
/// most repeated gesture there is — the pane you are working in is the one
/// you click most. Without this guard the journal fills with `pane_focus`
/// entries recording that focus did not change.
///
/// **The guard belongs here and not in `focusPane`.** `LayoutStore.focus`
/// also *recovers* a pane that has drifted outside the void, and the rail
/// is the only handle such a pane has left — so a rail click on the
/// already-focused pane is meaningful work and must still dispatch. A
/// canvas click cannot be that case, because a pane you can click is a
/// pane already on screen.
@Test @MainActor func clickingTheAlreadyFocusedPaneDispatchesNothing() async throws {
    let (model, registry, _) = try await makeLayoutModel()
    await model.openPane(kind: "db")
    let only = try #require(model.layoutSnapshot.panes.first)
    #expect(model.layoutSnapshot.focusedId == only.id)
    let before = try await registry.journalEntries().count

    await model.paneClicked(id: only.id)
    await model.paneClicked(id: only.id)
    await model.paneClicked(id: only.id)

    #expect(model.layoutSnapshot.focusedId == only.id)
    #expect(try await registry.journalEntries().count == before)
}

/// The rail keeps dispatching unconditionally — the recovery path above,
/// as an assertion rather than a comment.
@Test @MainActor func focusingTheAlreadyFocusedPaneFromTheRailStillDispatches() async throws {
    let (model, registry, _) = try await makeLayoutModel()
    await model.openPane(kind: "db")
    let only = try #require(model.layoutSnapshot.panes.first)
    let before = try await registry.journalEntries().count

    await model.focusPane(id: only.id)

    let after = try await registry.journalEntries()
    #expect(after.count == before + 1)
    #expect(after.last?.action == "pane_focus")
}

/// A focus request on the pane that already holds focus must still be
/// *observable*, because first responder is not `focusedId` and the two drift
/// apart on the commonest gesture there is.
///
/// #284, Defect 1. `TerminalPane` took first responder back through
/// `.onChange(of: isFocusedPane)`, and `onChange` only fires on a change:
/// typing to the agent moves first responder to the composer without touching
/// `focusedId`, so the rail click that is supposed to bring the operator back
/// dispatched `pane_focus` with the value the pane already had, nothing
/// changed, and the keyboard stayed in the composer. A proposal could then
/// never be accepted — the `⏎` the whole design turns on went to the wrong
/// view. A counter is what makes the *request* visible rather than only its
/// effect on state.
@Test @MainActor func focusingTheAlreadyFocusedPaneRaisesAKeyboardFocusRequest() async throws {
    let (model, _, _) = try await makeLayoutModel()
    await model.openPane(kind: "db")
    let only = try #require(model.layoutSnapshot.panes.first)
    #expect(model.layoutSnapshot.focusedId == only.id)
    let before = model.keyboardFocusRequests

    await model.focusPane(id: only.id)
    await model.focusPane(id: only.id)

    // The state did not move, which is the whole point: without the counter
    // there is nothing here for a view to react to.
    #expect(model.layoutSnapshot.focusedId == only.id)
    #expect(model.keyboardFocusRequests == before + 2)
}

/// A canvas click on the already-focused pane dispatches nothing and must
/// still raise a request.
///
/// The first fix asserted the opposite, on the reasoning that "the click
/// itself is what moves first responder". It does not: the canvas gesture is
/// a `DragGesture`/`TapGesture` and neither touches `TerminalPane`'s
/// `@FocusState`. Clicking the pane you are already in is exactly what an
/// operator does after typing to the agent, so it is the same defect by a
/// different gesture — #284's acceptance says *a rail click (or any operator
/// focus request)*, and a canvas click is one.
///
/// What must NOT happen is a dispatch: every dispatch journals, and a click is
/// the most repeated gesture there is.
@Test @MainActor func clickingTheAlreadyFocusedPaneRaisesAKeyboardFocusRequestWithoutDispatching()
    async throws
{
    let (model, registry, _) = try await makeLayoutModel()
    await model.openPane(kind: "db")
    let only = try #require(model.layoutSnapshot.panes.first)
    let before = model.keyboardFocusRequests
    let journalledBefore = try await registry.journalEntries().count

    await model.paneClicked(id: only.id)

    #expect(model.keyboardFocusRequests == before + 1)
    #expect(model.layoutSnapshot.focusedId == only.id, "nothing about the arrangement moved")
    #expect(try await registry.journalEntries().count == journalledBefore,
            "a click that changes no focus must not journal")
}

/// **The agent's `pane_focus` raises it too, and that is Invariant 2.**
///
/// The first fix raised the counter in `WindowModel.focusPane`, which the rail
/// and `⌘K` reach and the agent does not — so the same action had two
/// different effects depending on who asked for it: an operator got the
/// keyboard back and the agent's caller did not. The count now lives in
/// `LayoutStore.focus(id:)`, the registry action behind both channels.
@Test @MainActor func theAgentsPaneFocusRaisesAKeyboardFocusRequestToo() async throws {
    let (model, registry, _) = try await makeLayoutModel()
    await model.openPane(kind: "db")
    let only = try #require(model.layoutSnapshot.panes.first)
    let before = model.keyboardFocusRequests

    // Straight through the registry with `origin: .agent`, exactly as the
    // agent's MCP call arrives — never through `focusPane`, which is the
    // operator's path.
    _ = try await registry.dispatch(
        name: "pane_focus", params: .object(["id": .string(only.id)]),
        origin: .agent, caller: .test("staging"), confirmation: nil)
    await model.refreshLayout()

    #expect(model.keyboardFocusRequests == before + 1)
}

/// An organisation switch must leave the counter exactly where it is.
///
/// #284, Defect 1, and the classification `InvalidationContractTests` makes a
/// new `WindowModel` property choose. It is an event count and not either
/// org's state, so it is `orgIndependent` — and **resetting it would be
/// actively wrong rather than merely untidy**. Nothing reads its value; a view
/// reacts to it differing from the last one it saw. A reset to zero is a
/// change, so it is a focus request as far as every pane is concerned, and the
/// switch would end by pulling first responder into a pane nobody clicked.
@Test @MainActor func anOrganisationSwitchLeavesTheKeyboardFocusRequestsAlone() async throws {
    let (model, _, _) = try await makeLayoutModel()
    await model.openPane(kind: "db")
    let only = try #require(model.layoutSnapshot.panes.first)
    await model.focusPane(id: only.id)
    let before = model.keyboardFocusRequests
    try #require(before > 0, "the counter has to have moved, or this asserts nothing")

    await model.invalidateForOrgChange()

    #expect(model.keyboardFocusRequests == before)
}

// MARK: - The confirmation gate (Phase 2b-iii, Task 10)

/// Builds a bare model with no context client and no harness — everything
/// these tests need is the registry, the gate, and a broker of the model's
/// own — plus the registry, so the test can register its own stand-in
/// `db_run_mutation` action.
///
/// `environment` is set through `WindowModel.init`'s `environment:`
/// override directly rather than through `refreshContext()` — which could
/// now be driven with a `ContextStore` over a `RecordingToolCaller`
/// instead of a real `wakil-ctx` process, but that would only be exercising
/// `refreshContext()` itself. Every real call site leaves that parameter at
/// its default and learns the environment from `wakil-ctx`; these tests
/// only care what the write gate does with `"staging"` versus
/// `"production"`.
@MainActor
private func makeTestModel(environment: String) async throws -> (WindowModel, ActionRegistry) {
    let (registry, panes, layout) = try makeRegistry()
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout,
        context: nil, harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup(), environment: environment)
    return (model, registry)
}

/// Registers a `.mutate` action named `db_run_mutation` — the name
/// `WindowModel.runMutation` always dispatches — whose handler returns
/// `.object([:])`. Registered directly on the registry, the same way
/// `everyWindowControlDispatchesWithTheUIOrigin` above registers its own
/// stand-ins, so these tests drive the write gate without a `wakil-db`
/// binary.
private func registerTestMutation(into registry: ActionRegistry) async {
    await registry.register(Action(
        name: "db_run_mutation", description: "", kind: .mutate,
        schema: .object([:]),
        handler: { _ in .object([:]) }))
}

/// Registers a `db_refetch` action that answers unconditionally with
/// `.object([:])`. This section's fixture (`makeTestModel`) builds a
/// bare registry with no `LayoutStore` pane at all — there is nothing
/// real to refetch — so the stub exists only so `runMutation`'s now
/// -unconditional post-mutation refetch (D8b; `pane` is no longer
/// optional, since every real caller always has one) does not surface an
/// "unknown action" error into `model.status` and obscure what these
/// tests are actually about: the confirmation gate, not the refetch.
private func registerNoOpRefetch(into registry: ActionRegistry) async {
    await registry.register(Action(
        name: "db_refetch", description: "", kind: .read, schema: .object([:]),
        handler: { _ in .object([:]) }))
}

// The operator's own mutation goes through the same gate and the same
// broker as the agent's — one confirmation mechanism, not two.
@Test @MainActor func anOperatorMutationParksAndRunsOnceConfirmed() async throws {
    let (model, registry) = try await makeTestModel(environment: "staging")
    await registerTestMutation(into: registry)
    // This run completes, so the now-unconditional post-mutation refetch
    // (D8b) actually fires — stub it so it doesn't overwrite `status`.
    await registerNoOpRefetch(into: registry)

    async let run: Void = model.runMutation("DELETE FROM t WHERE id=1", database: "orders", pane: "db-1")
    while model.pending == nil { await Task.yield() }
    #expect(model.pending?.origin == .ui)
    #expect(model.pending?.affectsEveryRow == false)

    await model.confirmPending(typed: "confirm")
    await run
    #expect(model.pending == nil)
    #expect(model.status == "")
}

// Final review minor 4: an approval is for the place the proposal was asked in. One that
// arrives once the screen is elsewhere runs nowhere — not in the place now on screen, whose
// environment was never judged for it — and says why.
@Test @MainActor func anOperatorApprovalAfterTheScreenLeftTheProposalsPlaceRunsNothing() async throws {
    let (registry, panes, layout) = try makeRegistry()
    let broker = ConfirmationBroker()
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout,
        context: nil, harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup(),
        confirmations: broker, environment: "staging")
    model.setOrganizationForTesting("initech")
    let ran = MutationRuns()
    await registry.register(Action(
        name: "db_run_mutation", description: "", kind: .mutate, schema: .object([:]),
        handler: { _ in
            await ran.bump()
            return .object([:])
        }))
    await registerNoOpRefetch(into: registry)

    async let run: Void = model.runMutation("DELETE FROM t WHERE id=1", database: "orders", pane: "db-1")
    while model.pending == nil { await Task.yield() }
    let parked = try #require(model.pending)
    model.setOrganizationForTesting("umbrella")
    #expect(model.place != parked.place)

    await broker.approve(id: parked.id)
    await run

    #expect(await ran.count == 0, "nothing ran in umbrella")
    #expect(model.status.contains("nothing ran"), "\(model.status)")
}

private actor MutationRuns {
    private(set) var count = 0
    func bump() { count += 1 }
}

// The wrong word does not confirm, and does not dismiss the plane either —
// a typo must not cost the operator the proposal.
@Test @MainActor func typingTheWrongWordDoesNotConfirm() async throws {
    let (model, registry) = try await makeTestModel(environment: "staging")
    await registerTestMutation(into: registry)
    // This run completes too — see the identical note above.
    await registerNoOpRefetch(into: registry)

    async let run: Void = model.runMutation("DELETE FROM t", database: "orders", pane: "db-1")
    while model.pending == nil { await Task.yield() }
    #expect(model.pending?.affectsEveryRow == true)

    await model.confirmPending(typed: "yes")
    #expect(model.pending != nil)  // still parked

    await model.confirmPending(typed: "confirm")
    await run
    #expect(model.pending == nil)
}

@Test @MainActor func cancellingLeavesTheMutationUnrunAndSaysSo() async throws {
    let (model, registry) = try await makeTestModel(environment: "staging")
    await registerTestMutation(into: registry)

    async let run: Void = model.runMutation("DELETE FROM t WHERE id=1", database: "orders", pane: "db-1")
    while model.pending == nil { await Task.yield() }
    await model.cancelPending()
    await run

    #expect(model.pending == nil)
    #expect(model.status.contains("cancelled"))
}

// Production never parks: there is no word that would run it.
@Test @MainActor func aProductionMutationNeverReachesTheOperator() async throws {
    let (model, registry) = try await makeTestModel(environment: "production")
    await registerTestMutation(into: registry)

    await model.runMutation("DELETE FROM t WHERE id=1", database: "orders", pane: "db-1")
    #expect(model.pending == nil)
    #expect(model.status.contains("blocked"))
}

// Finding 1 of the Task 10 review: ⌘K once listed every registered action
// with no filter on kind, so `db_run_mutation` was selectable there like any
// read — and selecting it dispatched with `.object([:])`, no `statement` at
// all. The curated catalog no longer lists it; the guard is pinned through
// the palette's own run path all the same. That must not park a blank
// confirmation: a red plane asking the operator to confirm nothing, and
// the single-flight broker occupied for up to two minutes while every
// unrelated agent proposal in the meantime got `.busy`.
@Test @MainActor func selectingAMutationFromCommandKWithNoArgumentsDoesNotPark() async throws {
    let (model, registry) = try await makeTestModel(environment: "staging")
    await registerTestMutation(into: registry)

    _ = await model.performPalette(.run(.dispatch(action: "db_run_mutation", params: .object([:]))))

    #expect(model.pending == nil)
    #expect(model.status.contains("db_run_mutation"), "\(model.status)")
    #expect(model.status.contains("statement"), "\(model.status)")

    // The broker was never occupied by the blank attempt above — a real
    // proposal right afterwards still parks rather than seeing `.busy`.
    async let run: Void = model.runMutation("DELETE FROM t WHERE id=1", database: "orders", pane: "db-1")
    while model.pending == nil { await Task.yield() }
    #expect(model.pending?.statement == "DELETE FROM t WHERE id=1")
    await model.cancelPending()
    await run
}

// MARK: - D8b: a confirmed mutation refetches the pane it named

/// The walked failure: after `confirm` on
/// `update events set customer_id = 42 where id = 3`, the plane closed,
/// the line correctly snapped back to `events` — and the pane went on
/// showing `customer_id = 7` for `id = 3`, a value the database no longer
/// held. Rows may not outlive the state they describe, least of all
/// across the one action guaranteed to have changed it.
///
/// Uses the registry's own journal — the same call-recording mechanism
/// `switchingEnvironmentRefetchesEveryOpenPane` reads above — rather than a
/// harness call counter: a `db_refetch` journal entry naming the pane, that
/// did not exist before the run, is proof the pane was actually asked for
/// its subject again.
@Test @MainActor func aConfirmedMutationRefetchesItsPane() async throws {
    let (registry, panes, layout) = try makeRegistry()
    await registerTestMutation(into: registry)
    await registerFakeRefetch(into: registry, panes: panes, failingPane: "", failureMessage: "")
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main",
        lookup: AlwaysSucceedsCredentialsLookup(), environment: "staging")
    let before = try await registry.journalEntries().filter { $0.action == "db_refetch" }.count

    async let run: Void = model.runMutation(
        "UPDATE events SET kind = 'x' WHERE id = 1", database: "orders", pane: "db-1")
    while model.pending == nil { await Task.yield() }
    await model.confirmPending(typed: "confirm")
    await run

    let refetches = try await registry.journalEntries().filter { $0.action == "db_refetch" }
    #expect(refetches.count > before)
    #expect(refetches.last?.params == .object(["pane": .string("db-1")]))
}

/// A cancelled mutation must NOT refetch. Redrawing the pane for no reason
/// would teach the operator that cancelling does something.
///
/// This passes before the fix as well as after — `dispatch` already
/// returned `nil` for a cancel, so even the pre-fix `_ = await
/// dispatch(...)` never called anything that could refetch. It is kept
/// anyway, deliberately, as a lock against a *different* future mistake:
/// were the `guard` in `runMutation` ever loosened to "refetch whenever a
/// pane was named" rather than "refetch only when it ran", this is the
/// test that would catch it.
@Test @MainActor func aCancelledMutationLeavesThePaneAlone() async throws {
    let (registry, panes, layout) = try makeRegistry()
    await registerTestMutation(into: registry)
    await registerFakeRefetch(into: registry, panes: panes, failingPane: "", failureMessage: "")
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main",
        lookup: AlwaysSucceedsCredentialsLookup(), environment: "staging")
    let before = try await registry.journalEntries().filter { $0.action == "db_refetch" }.count

    async let run: Void = model.runMutation(
        "UPDATE events SET kind = 'x' WHERE id = 1", database: "orders", pane: "db-1")
    while model.pending == nil { await Task.yield() }
    await model.cancelPending()
    await run

    let after = try await registry.journalEntries().filter { $0.action == "db_refetch" }.count
    #expect(after == before)
}

// §8's first hover-revealed row action: drilling from a table list opens
// that table in a new pane. The SUBJECT decides whether a drill is
// offered, never the column names — see `PaneTable.drillTarget`'s own
// doc comment.
@Test func onlyATableListOffersADrill() {
    func table(columns: [String], rows: [[JSONValue]]) -> PaneTable {
        PaneTable(
            columns: columns.map { PaneColumn(name: $0, type: "TEXT") },
            columnTypesInferred: false,
            rows: rows.enumerated().map { PaneRow(id: $0.offset, cells: $0.element.map(PaneCell.init)) },
            millis: 1, truncated: false, selection: .empty, sort: [],
            scrollTarget: nil, pageable: false, offset: 0, failure: nil,
            listsTables: false)
    }
    let tables = table(columns: ["name", "kind"],
                       rows: [[.string("events"), .string("table")]])
    #expect(tables.drillTarget(row: 0, subject: .tables(database: nil)) == "events")
    // A query that happens to return a column called "name" is not a
    // table list, and offering to open row 3 of it as a table would open
    // a pane on a table that does not exist. The SUBJECT decides, never
    // the column names.
    #expect(table(columns: ["name"], rows: [[.string("Ada")]])
        .drillTarget(row: 0, subject: .sql(database: nil, raw: "SELECT name FROM people")) == nil)
    #expect(tables.drillTarget(row: 9, subject: .tables(database: nil)) == nil)
    // Spec §4, built in the final fix wave (Minor 10): a `.columns` pane
    // drills to the pane's OWN table, from any of its rows — the row names
    // a column, and the subject names the table, so the subject is what is
    // asked. A row that does not exist still drills nowhere.
    let columns = table(columns: ["name", "type", "key"],
                        rows: [[.string("id"), .string("INT"), .bool(false)],
                               [.string("kind"), .string("TEXT"), .bool(false)]])
    #expect(columns.drillTarget(row: 0, subject: .columns(database: nil, table: "events")) == "events")
    #expect(columns.drillTarget(row: 1, subject: .columns(database: nil, table: "events")) == "events")
    #expect(columns.drillTarget(row: 9, subject: .columns(database: nil, table: "events")) == nil)
    #expect(columns.drillTarget(row: 0, subject: .columns(database: nil, table: "")) == nil)
    // Fix round 1, Finding 3: a pane with no subject at all — never
    // fetched, or a fetch that failed before a subject was recorded —
    // must not offer a drill either. `subject: nil` is not "the subject
    // decided yes"; it is "there is no subject to ask".
    #expect(tables.drillTarget(row: 0, subject: nil) == nil)
    // A NULL first cell must not be offered as a table name — that would
    // dispatch `db_read_table` against a table that does not exist.
    #expect(table(columns: ["name", "kind"], rows: [[.null, .string("table")]])
        .drillTarget(row: 0, subject: .tables(database: nil)) == nil)
    // Same for an empty string: a table genuinely named "" is not a
    // sensible drill target, and the guard exists for exactly this shape
    // of driver response, not only for NULL.
    #expect(table(columns: ["name", "kind"], rows: [[.string(""), .string("table")]])
        .drillTarget(row: 0, subject: .tables(database: nil)) == nil)
}

/// FINAL REVIEW, Minor 13: relaunch re-runs `db` panes, not every pane
/// that happens to carry a fetch.
///
/// Spec §8 says "each `db` pane with a fetch". The loop asked only whether
/// a fetch was present, which is harmless while `Pane.kinds` is `["db"]`
/// and wrong the day 2c-iii adds a second kind — a terminal pane with a
/// subject of its own would be handed `db_refetch`.
@Test @MainActor func relaunchOnlyRefetchesDbPanes() async throws {
    let (registry, panes, layout) = try makeRegistry()
    await registerStandardActions(
        into: registry, context: nil, panes: panes, db: nil, resumes: ResumeBroker(),
        layout: layout)
    let restored = LayoutSnapshot(
        panes: [
            Pane(id: "db-1", kind: "db", title: "main",
                 frame: PaneFrame(x: 0, y: 0, width: 640, height: 420),
                 fetch: PaneFetch(query: .sql(database: nil, raw: "SELECT 1"))),
            // A kind this phase does not build, standing in for the one
            // 2c-iii will: it carries a fetch and must still be left alone.
            Pane(id: "term-1", kind: "terminal", title: "shell",
                 frame: PaneFrame(x: 0, y: 0, width: 640, height: 420),
                 fetch: PaneFetch(query: .sql(database: nil, raw: "SELECT 2"))),
        ],
        focusedId: "db-1")
    await layout.load(restored, for: .initial)
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main",
        lookup: AlwaysSucceedsCredentialsLookup())
    await model.refreshLayout()

    await model.restorePaneContents()

    // Every `db_refetch` that was dispatched at all names the db pane.
    // (With no database client each one fails, which is fine: what is
    // under test is WHICH panes were asked for, not what came back.)
    let refetches = try await registry.journalEntries().filter { $0.action == "db_refetch" }
    #expect(!refetches.isEmpty)
    for entry in refetches {
        #expect(entry.params == .object(["pane": .string("db-1")]))
    }
}

/// Review Focus 2: a restore re-runs every pane's subject. A read still in flight on a pane
/// must be cancelled first, or the restore's own `db_refetch` is refused (Interaction Rule 5)
/// and the pane keeps showing the environment just left.
@Test @MainActor func restoreCancelsReadsInFlightFirst() async throws {
    let (registry, panes, layout) = try makeRegistry()
    let db = StallingDB()
    await registerStandardActions(
        into: registry, context: nil, panes: panes, db: db, resumes: ResumeBroker(),
        layout: layout)
    await layout.load(LayoutSnapshot(
        panes: [Pane(id: "db-1", kind: "db", title: "main",
                     frame: PaneFrame(x: 0, y: 0, width: 640, height: 420),
                     fetch: PaneFetch(query: .sql(database: nil, raw: "SELECT 1")))],
        focusedId: "db-1"), for: .initial)
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main",
        lookup: AlwaysSucceedsCredentialsLookup())
    await model.refreshLayout()

    let first = Task {
        try await registry.dispatch(
            name: "db_refetch", params: .object(["pane": .string("db-1")]),
            origin: .agent, caller: .test("staging"), confirmation: nil)
    }
    #expect(await dbEventually { @Sendable in await dbSnapshot(panes, "db-1").runningSince != nil })
    #expect(await dbEventually { @Sendable in await db.stalled == 1 })
    await db.setStall(false)

    await model.restorePaneContents()

    #expect(!model.status.contains("already running"))
    #expect(await dbSnapshot(panes, "db-1").rows == [[.integer(2)]])
    _ = try? await first.value
}

/// A model over `StallingDB` with pane `db-1` showing `[[1]]` from `SELECT 1`, and a
/// `db_refetch` on it stalled in flight. The write paths' tests (final review, Important 1).
@MainActor private func modelWithAReadInFlight() async throws
    -> (WindowModel, ActionRegistry, PaneStore, StallingDB, Task<JSONValue, Error>)
{
    let (registry, panes, layout) = try makeRegistry()
    let db = StallingDB()
    await registerStandardActions(
        into: registry, context: nil, panes: panes, db: db, resumes: ResumeBroker(),
        layout: layout)
    await registerTestMutation(into: registry)
    await layout.load(LayoutSnapshot(
        panes: [Pane(id: "db-1", kind: "db", title: "main",
                     frame: PaneFrame(x: 0, y: 0, width: 640, height: 420),
                     fetch: PaneFetch(query: .sql(database: nil, raw: "SELECT 1")))],
        focusedId: "db-1"), for: .initial)
    await panes.setRows(
        paneId: "db-1", columns: ["id"], columnTypes: ["int"], columnTypesInferred: false,
        rows: [[.integer(1)]], millis: 1, truncated: false, pageable: true, offset: 0,
        sort: [], listsTables: false,
        editable: PaneEditable(table: "t", keyColumns: ["id"], columns: ["id"], rowKeys: ["id=1"]))
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main",
        lookup: AlwaysSucceedsCredentialsLookup(), environment: "staging")
    await model.refreshLayout()
    let read = Task {
        try await registry.dispatch(
            name: "db_refetch", params: .object(["pane": .string("db-1")]),
            origin: .agent, caller: .test("staging"), confirmation: nil)
    }
    #expect(await dbEventually { @Sendable in await dbSnapshot(panes, "db-1").runningSince != nil })
    #expect(await dbEventually { @Sendable in await db.stalled == 1 })
    await db.setStall(false)
    return (model, registry, panes, db, read)
}

// Final review, Important 1: the write supersedes a read in flight. Its refetch is not refused,
// and the older read cannot land pre-write rows over it.
@Test @MainActor func aMutationRefetchesThroughAReadInFlight() async throws {
    let (model, _, panes, _, read) = try await modelWithAReadInFlight()
    async let run: Void = model.runMutation("DELETE FROM t WHERE id=1", database: nil, pane: "db-1")
    while model.pending == nil { await Task.yield() }
    await model.confirmPending(typed: "confirm")
    await run
    #expect(!model.status.contains("already running"), "\(model.status)")
    #expect(await dbSnapshot(panes, "db-1").rows == [[.integer(2)]])
    #expect(await dbSnapshot(panes, "db-1").runningSince == nil)
    _ = try? await read.value
}

@Test @MainActor func aCellEditRefetchesThroughAReadInFlight() async throws {
    let (model, registry, panes, _, read) = try await modelWithAReadInFlight()
    await registry.register(Action(
        name: "db_render_update", description: "", kind: .read, schema: .object([:]),
        handler: { _ in .object(["structuredContent": .object([
            "statement": .string("UPDATE t SET id = 3 WHERE id = 1")])]) }))
    let pane = try #require(model.layoutSnapshot.panes.first { $0.id == "db-1" })
    async let outcome = model.commitCellEdit(
        pane: pane, rowKey: "id=1", column: "id", columnType: "int", value: "3")
    while model.pending == nil { await Task.yield() }
    await model.confirmPending(typed: "confirm")
    #expect(await outcome == .committed)
    #expect(!model.status.contains("already running"), "\(model.status)")
    #expect(await dbSnapshot(panes, "db-1").rows == [[.integer(2)]])
    #expect(await dbSnapshot(panes, "db-1").runningSince == nil)
    _ = try? await read.value
}

// Background agents 3 of 4 (the spec's "in-flight reads stay"): an org switch stops no read —
// the read may be the outgoing place's agent's, through its own pinned client. It lands in the
// scope it began in (`ScopeRouting`), or is cancelled from there.
@Test @MainActor func anOrgSwitchLeavesAReadInFlightRunning() async throws {
    let (model, _, panes, db, read) = try await modelWithAReadInFlight()
    await model.invalidateForOrgChange()
    #expect(await db.cancelled == 0)
    #expect(await dbSnapshot(panes, "db-1").runningSince != nil, "still that pane's read")
    _ = await panes.cancelDBRead(paneId: "db-1")
    _ = try? await read.value
}

// Background agents 3 of 4, fix round 1 (ruling: the spec's "in-flight reads stay" over Final
// review Minor 3): a project switch stops nothing. An agent's read in flight in its own place —
// `widgets`, homed there by the scope lookup — keeps running while the screen goes to
// `gadgets` and comes back, and is still that pane's read when it does.
@Test @MainActor func aProjectSwitchLeavesABackgroundReadInFlightRunning() async throws {
    let bin = windowRepoRoot().appendingPathComponent("bin/wakil-ctx")
    try #require(FileManager.default.isExecutableFile(atPath: bin.path), "run `make build` first")
    let home = try makeTwoProjectFixture(
        org: "acme", projects: [("widgets", ["dev"]), ("gadgets", ["dev"])])
    let client = try await startedClient(bin: bin, home: home, org: "acme")
    let directory = try windowScratchDirectory()
    let persistence = LayoutPersistence(directory: directory)
    // Only `widgets` is saved, so the switch to `gadgets` loads nothing from disk and reaches no
    // `restorePaneContents` (which cancels every read itself).
    try persistence.save(
        LayoutSnapshot(
            panes: [Pane(id: "db-1", kind: "db", title: "db",
                         frame: PaneFrame(x: 10, y: 10, width: 300, height: 200),
                         fetch: PaneFetch(query: .sql(database: nil, raw: "SELECT 1")))],
            focusedId: "db-1"),
        for: LayoutScope(organization: "acme", project: "widgets", environment: ""))
    let (registry, panes, layout) = try makeRegistry()
    let db = StallingDB()
    await db.setStall(false)
    await registerStandardActions(
        into: registry, context: client, panes: panes, db: db, resumes: ResumeBroker(),
        layout: layout)
    await registerLayoutActions(into: registry, layout: layout, panes: panes)
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, persistence: persistence,
        context: ContextStore(client: client),
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup())
    await model.setProject("widgets")
    let widgets = await panes.activeScope
    registry.setScopeLookup { caller in caller.session == nil ? nil : widgets }

    await db.setStall(true)
    let read = Task {
        try await registry.dispatch(
            name: "db_refetch", params: .object(["pane": .string("db-1")]),
            origin: .agent, caller: .test("dev", session: "agent-widgets"), confirmation: nil)
    }
    #expect(await dbEventually { @Sendable in await dbSnapshot(panes, "db-1").runningSince != nil })
    #expect(await dbEventually { @Sendable in await db.stalled == 1 })
    await model.setProject("gadgets")
    #expect(model.project == "gadgets", "\(model.status)")
    await model.setProject("widgets")
    #expect(model.project == "widgets", "\(model.status)")
    #expect(await db.cancelled == 0)
    #expect(await dbSnapshot(panes, "db-1").runningSince != nil)
    read.cancel()
    _ = try? await read.value
    await client.stop()
}

// Fix round 1, Finding 2: `offersDrill(subject:listsTables:)` is the pure
// predicate `DBPane` asks to decide whether to offer a drill AT ALL,
// pulled out of the view so a regression there is caught by a test
// rather than by a human clicking around — `WakilApp` has no test
// target and cannot have one.
//
// `listsTables: false` throughout: this test is pinning the SUBJECT half
// of the two-source decision (D2's `.tables`/`.columns` path never
// produces a `Rows`, so it never has a `listsTables` to be true). The
// `listsTables: true` half is `PaneFetchTests.swift`'s
// `aDeclaredListingOffersTheDrill`.
@Test func offersDrillOnlyForASchemaSubjectIncludingAnEmptyOne() {
    #expect(offersDrill(subject: .tables(database: nil), listsTables: false))
    #expect(offersDrill(subject: .tables(database: "staging"), listsTables: false))
    // Spec §4's second half, built in the final fix wave (Minor 10).
    #expect(offersDrill(subject: .columns(database: nil, table: "events"), listsTables: false))
    #expect(!offersDrill(subject: .sql(database: nil, raw: "SELECT name FROM people"),
                         listsTables: false))
    #expect(!offersDrill(subject: .table(database: nil, name: "events"), listsTables: false))
    #expect(!offersDrill(subject: nil, listsTables: false))
}

// MARK: - D12 wiring: a failed refetch marks the pane it failed for

/// Registers a `db_refetch` handler directly on the registry, the same way
/// `registerTestMutation` above stands in for `db_run_mutation` without a
/// `wakil-db` binary — `db_refetch`'s own routing by table name is already
/// covered by `StandardActionsTests.swift` against a `RecordingToolCaller`;
/// this fixture exists only to prove `WindowModel` records the per-pane
/// OUTCOME, not to re-prove that routing.
///
/// `failingPane` is the one pane id whose "subject" does not resolve — it
/// throws, exactly the shape a dropped table or an environment with no
/// such database reaches a handler as. Every other pane's subject DOES
/// resolve: its handler writes real rows to `panes` before returning, so
/// the pane that succeeds is not merely "never touched" (which would make
/// `failure == nil` trivially true whether or not the fix exists) — it is
/// touched, and still carries no failure.
private func registerFakeRefetch(
    into registry: ActionRegistry, panes: PaneStore, failingPane: String, failureMessage: String
) async {
    await registry.register(Action(
        name: "db_refetch", description: "", kind: .read, schema: .object([:]),
        handler: { params in
            guard case .object(let obj) = params, case .string(let paneId)? = obj["pane"] else {
                throw StandardActionError.missingParam(action: "db_refetch", param: "pane")
            }
            if paneId == failingPane {
                throw StandardActionError.serverError(action: "db_refetch", message: failureMessage)
            }
            await panes.setRows(
                paneId: paneId, columns: ["id"], columnTypes: ["INTEGER"],
                columnTypesInferred: false, rows: [[.number(1)]],
                millis: 1, truncated: false, pageable: false, offset: 0, sort: [], listsTables: false, editable: nil)
            return .object([:])
        }))
}

/// The walked failure: reopening on `production`, `db_refetch` returned an
/// error for two panes and both drew "no rows". Each pane must carry its
/// OWN failure — a message about pane B drawn under pane A is the same
/// class of lie in a smaller font, which is the fix Task 14 of 2c-ii
/// already had to make once for the query line's refusals.
///
/// The third `#expect` the brief sketches (a difference between db-1's and
/// db-2's messages) is deliberately not here: two panes failing the same
/// way legitimately produce the same message, so that would prove
/// nothing. What proves the failure is per-pane rather than global is a
/// pane whose refetch SUCCEEDED carrying no failure at all, in the same
/// run as the ones that didn't — see `registerFakeRefetch`'s own comment
/// for how the fixture keeps that pane from being merely untouched.
@Test @MainActor func aFailedRestoreMarksEachPaneSeparately() async throws {
    let (registry, panes, layout) = try makeRegistry()
    await registerFakeRefetch(
        into: registry, panes: panes, failingPane: "db-2",
        failureMessage: "no such collection: widgets")
    let restored = LayoutSnapshot(
        panes: [
            Pane(id: "db-1", kind: "db", title: "ok",
                 frame: PaneFrame(x: 0, y: 0, width: 640, height: 420),
                 fetch: PaneFetch(query: .sql(database: nil, raw: "SELECT 1"))),
            Pane(id: "db-2", kind: "db", title: "bad",
                 frame: PaneFrame(x: 0, y: 0, width: 640, height: 420),
                 fetch: PaneFetch(query: .sql(database: nil, raw: "SELECT 1"))),
        ],
        focusedId: "db-1")
    await layout.load(restored, for: .initial)
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main",
        lookup: AlwaysSucceedsCredentialsLookup(), environment: "production")
    await model.refreshLayout()

    await model.restorePaneContents()

    #expect(model.table("db-2").failure != nil)
    #expect(model.table("db-2").failure?.contains("no such collection: widgets") == true)
    // The pane whose subject actually resolved carries real rows AND no
    // failure, in the same run as the pane that has neither — the
    // contrast that proves per-pane recording rather than a window-wide
    // flag.
    #expect(model.table("db-1").rows.count == 1)
    #expect(model.table("db-1").failure == nil)
}

/// The walked failure: `show tables` typed into a pane on `events`
/// (sqlite) failed — correctly, sqlite has no `SHOW TABLES` — and the
/// only sign was a status line at the very bottom of the window. The
/// query line still read `show tables`, the grid still showed the old
/// `events` rows, and the footer still described them as sorted.
/// `runQuery` discarded `dispatch`'s result with `_ =`; this proves it
/// now records the failure against the pane that ran it, the same way
/// `pagePane` and `refetchPane` already do (D12).
///
/// Registers `db_run_query` directly, the same way `registerFakeRefetch`
/// stands in for `db_refetch` above: `db-1`'s query throws, `db-2`'s
/// resolves and writes real rows — so the pane that succeeds is touched
/// and still carries no failure, the contrast that proves the failure is
/// recorded per pane rather than globally.
@Test @MainActor func aFailedQueryMarksThePaneItFailedFor() async throws {
    let (registry, panes, layout) = try makeRegistry()
    await registry.register(Action(
        name: "db_run_query", description: "", kind: .read, schema: .object([:]),
        handler: { params in
            guard case .object(let obj) = params, case .string(let paneId)? = obj["pane"] else {
                throw StandardActionError.missingParam(action: "db_run_query", param: "pane")
            }
            if paneId == "db-1" {
                throw StandardActionError.serverError(
                    action: "db_run_query",
                    message: "SQL logic error: near \"show\": syntax error (1)")
            }
            await panes.setRows(
                paneId: paneId, columns: ["id"], columnTypes: ["INTEGER"],
                columnTypesInferred: false, rows: [[.number(1)]],
                millis: 1, truncated: false, pageable: false, offset: 0, sort: [], listsTables: false, editable: nil)
            return .object([:])
        }))
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup())

    await model.runQuery("show tables", database: nil, pane: "db-1")
    await model.runQuery("select 1", database: nil, pane: "db-2")

    let db1Failure = await panes.failure(paneId: "db-1")
    #expect(db1Failure?.contains("show") == true, "\(String(describing: db1Failure))")
    let db2Failure = await panes.failure(paneId: "db-2")
    #expect(db2Failure == nil)
}

// MARK: - D11, revised by Plan 3: each environment keeps its own canvas

/// **Replaces D11's refetch-in-place** (operator, 2026-10-16). D11 was walked as a banner
/// reading `production` over three panes of `staging` rows, and answered by refetching the
/// canvas on screen. Staging and production of one project are now two places, each with its
/// own canvas: the switch shows the incoming environment's canvas, and the one left keeps its
/// rows — coming back finds them as they were, with nothing re-run.
@Test @MainActor func twoEnvironmentsOfOneProjectKeepTwoCanvases() async throws {
    let backend = EnvironmentBackend(environment: "staging", project: "api")
    let (model, registry, panes, layout) = try await environmentWindow(backend)
    await registerFakeRefetch(into: registry, panes: panes, failingPane: "", failureMessage: "")
    let id = await layout.open(kind: "db", title: "orders").id
    await layout.setFetch(PaneFetch(query: .sql(database: nil, raw: "SELECT 1")), id: id)
    await panes.setRows(
        paneId: id, columns: ["env"], columnTypes: ["TEXT"], columnTypesInferred: false,
        rows: [[.string("staging row")]], millis: 1, truncated: false, pageable: false, offset: 0,
        sort: [], listsTables: false, editable: nil)
    await model.refreshLayout()
    let stagingRows = await panes.snapshot(paneId: id, kind: "db")

    await model.setEnvironment("production")

    #expect(model.environment == "production")
    #expect(model.layoutSnapshot.panes.isEmpty, "production showed staging's canvas")

    await model.setEnvironment("staging")

    #expect(model.layoutSnapshot.panes.map(\.id) == [id])
    #expect(await panes.snapshot(paneId: id, kind: "db") == stagingRows)
    #expect(try await registry.journalEntries().filter { $0.action == "db_refetch" }.isEmpty,
            "coming back re-ran staging's pane")
}

/// D11's relaunch argument still holds for the canvas the switch brings in: an environment's
/// arrangement read off disk holds subjects and no rows, so its panes re-run — in the incoming
/// environment, since that is the only one on screen.
@Test @MainActor func anEnvironmentsSavedCanvasIsRefetchedWhenTheSwitchBringsItIn() async throws {
    let backend = EnvironmentBackend(environment: "staging", project: "api")
    let persistence = LayoutPersistence(directory: try windowScratchDirectory())
    try persistence.save(
        LayoutSnapshot(
            panes: [Pane(id: "db-7", kind: "db", title: "orders",
                         frame: PaneFrame(x: 0, y: 0, width: 640, height: 420),
                         fetch: PaneFetch(query: .sql(database: nil, raw: "SELECT 1")))],
            focusedId: "db-7"),
        for: LayoutScope(organization: "acme", project: "api", environment: "production"))
    let (model, registry, panes, _) = try await environmentWindow(backend, persistence: persistence)
    await registerFakeRefetch(into: registry, panes: panes, failingPane: "", failureMessage: "")

    await model.setEnvironment("production")

    #expect(model.layoutSnapshot.panes.map(\.id) == ["db-7"])
    let refetched = try await registry.journalEntries().filter { $0.action == "db_refetch" }
    #expect(refetched.count == 1)
    #expect(refetched.first?.environment == "production")
}

/// A REFUSED switch must not refetch — the environment did not change, so
/// redrawing every pane would waste a load-bearing round trip for no
/// reason at all, and the `if` that became a `guard` in `setEnvironment`
/// is precisely what stops that.
@Test @MainActor func aRefusedEnvironmentSwitchDoesNotRefetch() async throws {
    let (registry, panes, layout) = try makeRegistry()
    // Always refuses — the stand-in for a `wakil-ctx` that does not
    // recognise the name, or any other reason `dispatch` returns `nil`.
    await registry.register(Action(
        name: "ctx_set_environment", description: "", kind: .control, schema: .object([:]),
        handler: { _ in throw StandardActionError.serverError(action: "ctx_set_environment", message: "no such environment") }))
    await registerFakeRefetch(
        into: registry, panes: panes, failingPane: "", failureMessage: "")
    let restored = LayoutSnapshot(
        panes: [
            Pane(id: "db-1", kind: "db", title: "main",
                 frame: PaneFrame(x: 0, y: 0, width: 640, height: 420),
                 fetch: PaneFetch(query: .sql(database: nil, raw: "SELECT 1"))),
        ],
        focusedId: "db-1")
    await layout.load(restored, for: .initial)
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main",
        lookup: AlwaysSucceedsCredentialsLookup(), environment: "staging")
    await model.refreshLayout()

    let before = try await registry.journalEntries().filter { $0.action == "db_refetch" }.count

    await model.setEnvironment("nowhere")

    let after = try await registry.journalEntries().filter { $0.action == "db_refetch" }.count
    #expect(after == before)
}

/// FINAL REVIEW, CRITICAL 2: an agent's `ctx_set_environment` never touches
/// `WindowModel` — it goes straight through `ActionRegistry.dispatch` the
/// way `MCPServerTests.swift` proves every `tools/call` does — and until
/// this, `observationPump` refreshed panes and layout on every dispatch but
/// never called `refreshContext()`. So the window kept the previous
/// environment's rows on screen, the banner kept naming the environment the
/// window last read, and — the dangerous half — `model.environment`, which
/// feeds `writeGate` for the agent's own next dispatch, stayed stale too.
///
/// Dispatched straight through the registry (`origin: .debug`, a
/// `--dispatch` script — `ctx_set_environment` is operator-only, so
/// `dispatch` refuses it from the agent), exactly
/// like `anAgentsDispatchReachesTheScreenWithoutTheOperatorClicking` above
/// does for `pane_select_cell` — never through `WindowModel.setEnvironment`,
/// which is the operator's own route and already covered by
/// `twoEnvironmentsOfOneProjectKeepTwoCanvases`. A real `wakil-ctx` is
/// required (unlike that test's stub) because part of what is under test is
/// whether `model.environment` — read only out of `refreshContext()` — is
/// caught up at all, and a stub `ctx_set_environment` control action would
/// prove nothing about that.
///
/// **Plan 3 changed what "reaches the panes" means.** It used to be a refetch of the canvas on
/// screen; staging and production of one project are now two places, so the agent's switch
/// brings in the incoming environment's own canvas and leaves the one it left as it was.
@Test @MainActor func anAgentsEnvironmentSwitchReachesTheWindowsPanesAndItsOwnEnvironment() async throws {
    let bin = windowRepoRoot().appendingPathComponent("bin/wakil-ctx")
    try #require(FileManager.default.isExecutableFile(atPath: bin.path), "run `make build` first")
    let home = try makeFixture(org: "acme", projectOrg: "acme", environments: ["dev", "staging"])
    let client = try await startedClient(bin: bin, home: home, org: "acme")

    let (registry, panes, layout) = try makeRegistry()
    await registerStandardActions(into: registry, context: client, panes: panes, db: nil, resumes: ResumeBroker())
    // Overrides `registerStandardActions`'s own `db_refetch` (which throws
    // without a real `wakil-db`) with the same fixture
    // `aFailedRestoreMarksEachPaneSeparately` uses above — this test is
    // about whether a refetch is ISSUED, not about `wakil-db`'s routing.
    await registerFakeRefetch(into: registry, panes: panes, failingPane: "", failureMessage: "")
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: ContextStore(client: client),
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main",
        lookup: AlwaysSucceedsCredentialsLookup(), environment: "dev")
    // The operator's own project switch, so `ctx_set_environment` below has
    // a project to run against — `setProject` is the operator's route and
    // is not what is under test here. It must come BEFORE the pane is
    // loaded: `activateLayout()` switches `LayoutStore` to the resolved
    // project, which would otherwise wipe a `db-1` loaded under project "".
    await model.setProject("widgets")
    let restored = LayoutSnapshot(
        panes: [
            Pane(id: "db-1", kind: "db", title: "main",
                 frame: PaneFrame(x: 0, y: 0, width: 640, height: 420),
                 fetch: PaneFetch(query: .sql(database: nil, raw: "SELECT 1"))),
        ],
        focusedId: "db-1")
    // Whatever environment `set_project` left active — this fixture declares two, so none is
    // picked — is the scope the pane is loaded into.
    await layout.load(restored, for: LayoutScope(
        organization: "acme", project: "widgets", environment: model.environment))
    await model.refreshLayout()
    #expect(model.layoutSnapshot.panes.map(\.id) == ["db-1"])

    // Not `model.setEnvironment` — straight through the registry, the way a
    // `--dispatch` script reaches it (`.debug`): `ctx_set_environment` is
    // operator-only, so `dispatch` refuses it from the agent. Neither side is
    // production, so this clears the write gate as `.allow` without a
    // confirmation.
    _ = try await registry.dispatch(
        name: "ctx_set_environment", params: .object(["name": .string("staging")]),
        origin: .debug, caller: DispatchCaller(place: model.place, session: nil), confirmation: nil)

    #expect(await waitUntil { model.environment == "staging" })
    // `environment` is written before the swap that follows it in the same `refreshContext`, so
    // the canvas is polled on its own rather than assumed from the environment.
    #expect(await waitUntil { model.layoutSnapshot.panes.isEmpty }, "staging showed the canvas left")
    #expect(try await registry.journalEntries().filter { $0.action == "db_refetch" }.isEmpty)

    await client.stop()
}

// MARK: - An agent's settings write reaches an open settings pane

/// A context server whose configuration tree holds one environment, and
/// gains a database when `set_database_dsn` is called — so a test can tell
/// a pane that re-read after the write from one that did not.
private actor SettingsBackend: ToolCaller {
    private var databases: [JSONValue] = []

    func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        switch name {
        case "set_database_dsn":
            databases.append(.object([
                "name": .string("ledger"), "driver": .string("mysql"),
                "ref": .string("db:orders:staging:ledger"), "writable": .bool(false),
            ]))
            return .object(["structuredContent": .object([:])])
        case "config_tree":
            return .object(["structuredContent": .object([
                "org": .object(["id": .string("acme"), "displayName": .string("Acme")]),
                "providers": .array([]),
                "projects": .array([.object([
                    "name": .string("orders"), "path": .string("/src/orders/project.json"),
                    "roots": .array([]),
                    "environments": .array([.object([
                        "name": .string("staging"), "databases": .array(databases),
                        "api": .array([]),
                    ])]),
                ])]),
            ])])
        default:
            return .object(["structuredContent": .object([:])])
        }
    }
}

/// **#300's Cover found this: the pane said "nothing here is cached" and
/// was right, and still drew a state that was no longer on disk.** Every
/// settings write the OPERATOR makes goes through a `WindowModel` wrapper
/// that calls `refreshSettings()` afterwards. The agent's never does — it
/// reaches `ActionRegistry.dispatch` straight from the socket — so the
/// write landed and the open pane kept its last read until Reload. Two
/// channels, one state on disk, two states on screen: Invariant 2, and
/// Invariant 3's "what is actually on screen" with it.
///
/// Dispatched straight through the registry, exactly as
/// `anAgentsEnvironmentSwitchReachesTheWindowsPanesAndItsOwnEnvironment`
/// above does, and never through `WindowModel.setDatabaseDSN`, which is
/// the operator's route. `origin: .debug` (a `--dispatch` script), not
/// `.agent`: `db_set_dsn` is operator-only, and `dispatch` refuses it from
/// the agent; the pump's redraw is what is under test, whoever asked.
@Test @MainActor func anAgentsSettingsWriteRedrawsAnOpenSettingsPane() async throws {
    let backend = SettingsBackend()
    let (registry, panes, layout) = try makeRegistry()
    await registerStandardActions(into: registry, context: backend, panes: panes, db: nil, resumes: ResumeBroker())
    await registerLayoutActions(into: registry, layout: layout)
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: ContextStore(client: backend),
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main",
        lookup: AlwaysSucceedsCredentialsLookup(), environment: "staging")

    await model.openSettings()
    #expect(model.settings?.projects.first?.environments.first?.databases.isEmpty == true)

    _ = try await registry.dispatch(
        name: "db_set_dsn",
        params: .object([
            "projectPath": .string("/src/orders/project.json"), "environment": .string("staging"),
            "name": .string("ledger"), "driver": .string("mysql"),
            "dsn": .string("mysql://u:p@h/ledger"),
        ]),
        origin: .debug, caller: DispatchCaller(place: model.place, session: nil), confirmation: nil)

    #expect(await waitUntil {
        model.settings?.projects.first?.environments.first?.databases.map(\.name) == ["ledger"]
    }, "the agent's write is on disk, and the open pane must say so without a Reload")
}

// MARK: - Unlinking the running account (#324)

/// A context server whose active provider is `main` until it is unlinked.
private actor UnlinkBackend: ToolCaller {
    private var active = "main"

    func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        switch name {
        case "get_context":
            return .object(["structuredContent": .object([
                "Org": .string("acme"), "Environment": .string("staging"),
                "RootPaths": .array([]), "ActiveProvider": .string(active),
            ])])
        case "unlink_provider":
            active = ""
            return .object(["structuredContent": .object([
                "removed": .bool(true), "credentialRemoved": .bool(true),
            ])])
        default:
            return .object(["structuredContent": .object([:])])
        }
    }
}

/// **#324, from the walk: unlinking the account a window runs as left the
/// bottom-edge ACCOUNT indicator naming it.** `unlinkAccount` refreshed the
/// settings pane and nothing else, and `providerId`, which the indicator
/// draws, is only ever re-read by `refreshContext()`.
@Test @MainActor func unlinkingTheRunningAccountStopsTheWindowNamingIt() async throws {
    let backend = UnlinkBackend()
    let (registry, panes, layout) = try makeRegistry()
    await registerStandardActions(into: registry, context: backend, panes: panes, db: nil, resumes: ResumeBroker())
    await registerLayoutActions(into: registry, layout: layout)
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: ContextStore(client: backend),
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main",
        lookup: AlwaysSucceedsCredentialsLookup(), environment: "staging")
    await model.refreshContext()
    #expect(model.providerId == "main")

    _ = await model.unlinkAccount(Account(org: "acme", accountId: "main", kind: "claude-code", mine: true))

    #expect(model.providerId != "main", "the window still names the account it just unlinked")
}

// MARK: - Confirmation description for a gated control action (D10)

/// Before this, a gated context switch died at the plane with "no
/// statement to confirm" — the refusal shown to the operator described a
/// mutation, for an action that is not one.
@Test func aGatedEnvironmentSwitchRaisesThePlane() async throws {
    #expect(confirmationDescription(
        action: "ctx_set_environment",
        params: .object(["name": .string("staging")]))
        == "switch the active environment to staging")
    #expect(confirmationDescription(action: "pane_move", params: .object([:])) == nil)
}

// MARK: - Turning an edited cell into a confirmed statement (Task 11)

/// The minimal `Pane` a `commitCellEdit` test needs: `title` and `frame`
/// are required by `Pane.init` but irrelevant to `commitCellEdit`, which
/// reads `pane.id` and `pane.fetch` (the latter for the database its rows
/// came from — final review finding, see
/// `aCellEditUsesTheSubjectDatabaseNotThePendingChoice` below). Leaving
/// `fetch` `nil` here is deliberate: every test using this helper wants no
/// `database` param sent at all, which is exactly what a pane with no
/// subject produces. Same shape `QueryTargetPaneTests.pane(_:)` uses.
private func editingTestPane(_ id: String) -> Pane {
    Pane(id: id, kind: "db", title: id, frame: PaneFrame(x: 0, y: 0, width: 640, height: 420))
}

/// A tiny recorder, because two of the tests below assert on WHICH actions
/// ran and in what order. `actor` rather than a class with a lock: these
/// handlers run off the main actor.
private actor Recorder {
    private var calls: [(name: String, params: JSONValue)] = []
    func record(_ name: String, _ params: JSONValue) { calls.append((name, params)) }
    func names() -> [String] { calls.map(\.name) }
    func params(for name: String) -> JSONValue? { calls.first { $0.name == name }?.params }
}

/// The full happy path: Go composes the `UPDATE`, `db_run_mutation` runs
/// it (through the same gate the query line uses), and the pane refetches.
/// **Both stubs are registered `.read` deliberately** — registering
/// `db_run_mutation` as `.mutate` would park it in the confirmation broker
/// and the test would hang waiting for a human. The gate itself is covered
/// by `MutationActionTests` and `WriteGateTests`; what is under test here
/// is the sequence.
@Test @MainActor func aCommittedCellEditRendersThenMutatesThenRefetches() async throws {
    let (registry, panes, layout) = try makeRegistry()
    let calls = Recorder()
    await registry.register(Action(
        name: "db_render_update", description: "stub", kind: .read,
        schema: .object(["type": .string("object")]),
        handler: { params in
            await calls.record("db_render_update", params)
            return .object(["structuredContent": .object([
                "statement": .string(#"UPDATE "events" SET "kind" = 'b' WHERE "id" = '1'"#),
            ])])
        }))
    await registry.register(Action(
        name: "db_run_mutation", description: "stub", kind: .read,
        schema: .object(["type": .string("object")]),
        handler: { params in
            await calls.record("db_run_mutation", params)
            return .object(["structuredContent": .object(["rowsAffected": .integer(1)])])
        }))
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main",
        lookup: AlwaysSucceedsCredentialsLookup())

    await panes.setRows(
        paneId: "db-1", columns: ["id", "kind"], columnTypes: ["INTEGER", "TEXT"],
        columnTypesInferred: false, rows: [[.integer(1), .string("a")]],
        millis: 0, truncated: false, pageable: true, offset: 0, sort: [], listsTables: false,
        editable: PaneEditable(
            table: "events", keyColumns: ["id"], columns: ["kind"],
            rowKeys: [#""id" = '1'"#]))
    let pane = editingTestPane("db-1")

    let outcome = await model.commitCellEdit(
        pane: pane, rowKey: #""id" = '1'"#, column: "kind", columnType: "TEXT", value: "b")

    #expect(outcome == .committed)
    // The statement Go composed is what reached the gated action —
    // nothing here rewrote it.
    #expect(await calls.names() == ["db_render_update", "db_run_mutation"])
    guard case .object(let mutateParams)? = await calls.params(for: "db_run_mutation") else {
        return #expect(Bool(false), "db_run_mutation should have been called")
    }
    #expect(mutateParams["statement"]
        == .string(#"UPDATE "events" SET "kind" = 'b' WHERE "id" = '1'"#))
}

/// A refusal carries the driver's own sentence and runs NOTHING — the
/// statement is never composed, so there is nothing to confirm.
@Test @MainActor func aRefusedCellEditRunsNothing() async throws {
    let (registry, panes, layout) = try makeRegistry()
    let calls = Recorder()
    await registry.register(Action(
        name: "db_render_update", description: "stub", kind: .read,
        schema: .object(["type": .string("object")]),
        handler: { _ in
            throw StandardActionError.serverError(
                action: "db_render_update",
                message: "\"abc\" is not a number, and n is a INTEGER column")
        }))
    await registry.register(Action(
        name: "db_run_mutation", description: "stub", kind: .read,
        schema: .object(["type": .string("object")]),
        handler: { params in
            await calls.record("db_run_mutation", params)
            return .null
        }))
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main",
        lookup: AlwaysSucceedsCredentialsLookup())
    await panes.setRows(
        paneId: "db-1", columns: ["id", "n"], columnTypes: ["INTEGER", "INTEGER"],
        columnTypesInferred: false, rows: [[.integer(1), .integer(7)]],
        millis: 0, truncated: false, pageable: true, offset: 0, sort: [], listsTables: false,
        editable: PaneEditable(
            table: "t", keyColumns: ["id"], columns: ["n"], rowKeys: [#""id" = '1'"#]))

    let outcome = await model.commitCellEdit(
        pane: editingTestPane("db-1"), rowKey: #""id" = '1'"#, column: "n",
        columnType: "INTEGER", value: "abc")

    guard case .refused(let reason) = outcome else {
        return #expect(Bool(false), "expected a refusal, got \(outcome)")
    }
    #expect(reason.contains("not a number"))
    #expect(await calls.names().isEmpty)
}

/// A pane the driver never called editable refuses before any round trip.
@Test @MainActor func aCellEditOnAReadOnlyPaneRefusesWithoutDispatching() async throws {
    let (registry, panes, layout) = try makeRegistry()
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main",
        lookup: AlwaysSucceedsCredentialsLookup())
    await panes.setRows(
        paneId: "db-1", columns: ["id"], columnTypes: ["INTEGER"], columnTypesInferred: false,
        rows: [[.integer(1)]], millis: 0, truncated: false, pageable: true,
        offset: 0, sort: [], listsTables: false, editable: nil)
    let outcome = await model.commitCellEdit(
        pane: editingTestPane("db-1"), rowKey: "x", column: "id",
        columnType: nil, value: "2")
    guard case .refused = outcome else {
        return #expect(Bool(false), "expected a refusal")
    }
}

// MARK: - Fix Round 1 (acceptance review, 2026-09-13)

/// A `rowKey` that is no longer among the pane's own `PaneEditable.rowKeys`
/// refuses before `db_render_update` is ever asked — the review's finding:
/// re-pointing the pane between the double-click and Enter can pair a
/// FRESH `table` with a STALE `rowKey`, and `db_render_update`'s own
/// description says explicitly that it does not cross-check the two.
/// Simulated here by setting rows up under table `events` and then
/// overwriting the SAME pane id's editable description with table
/// `audit` — the pane the operator was looking at is gone, replaced by
/// one that knows nothing about `"id" = '1'`.
@Test @MainActor func aRowKeyThatDoesNotMatchTheCurrentEditableDescriptionIsRefused() async throws {
    let (registry, panes, layout) = try makeRegistry()
    let calls = Recorder()
    await registry.register(Action(
        name: "db_render_update", description: "stub", kind: .read,
        schema: .object(["type": .string("object")]),
        handler: { params in
            await calls.record("db_render_update", params)
            return .object(["structuredContent": .object([
                "statement": .string(#"UPDATE "audit" SET "kind" = 'b' WHERE "id" = '1'"#),
            ])])
        }))
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main",
        lookup: AlwaysSucceedsCredentialsLookup())

    // The row the operator double-clicked, under `events`.
    await panes.setRows(
        paneId: "db-1", columns: ["id", "kind"], columnTypes: ["INTEGER", "TEXT"],
        columnTypesInferred: false, rows: [[.integer(1), .string("a")]],
        millis: 0, truncated: false, pageable: true, offset: 0, sort: [], listsTables: false,
        editable: PaneEditable(
            table: "events", keyColumns: ["id"], columns: ["kind"],
            rowKeys: [#""id" = '1'"#]))
    let capturedRowKey = #""id" = '1'"#

    // An agent re-points the SAME pane at a different table before Enter
    // is pressed. `PaneEditable.rowKeys` for `audit` says nothing about
    // `"id" = '1'` — it is a fresh table's own row keys, not a superset
    // that happens to include the old one.
    await panes.setRows(
        paneId: "db-1", columns: ["id", "kind"], columnTypes: ["INTEGER", "TEXT"],
        columnTypesInferred: false, rows: [[.integer(9), .string("z")]],
        millis: 0, truncated: false, pageable: true, offset: 0, sort: [], listsTables: false,
        editable: PaneEditable(
            table: "audit", keyColumns: ["id"], columns: ["kind"],
            rowKeys: [#""id" = '9'"#]))

    let outcome = await model.commitCellEdit(
        pane: editingTestPane("db-1"), rowKey: capturedRowKey, column: "kind",
        columnType: "TEXT", value: "b")

    guard case .refused = outcome else {
        return #expect(Bool(false), "expected a refusal, got \(outcome)")
    }
    // The point of the fix: `db_render_update` is never asked to compose
    // anything against the mismatched pair.
    #expect(await calls.names().isEmpty)
}

// MARK: - A cell edit uses the pane's subject database, not the query
// line's pending choice (final review, 2026-09-14)

/// The finding: `chooseDatabase` records the operator's intent for the
/// pane's NEXT Return — it runs nothing, and the pane goes on showing
/// whatever it showed before. `table`, `rowKey` and every value on screen
/// still came from the pane's own subject. Before this fix,
/// `commitCellEdit` sent `databaseForQueryLine(pane:)` — the pending
/// choice — as `database` to both round trips, so a cell double-clicked
/// under `alpha` could compose and RUN an `UPDATE` against `beta` while
/// `table` and `rowKey` named a row that only exists in `alpha`.
///
/// Set up here: a pane whose subject (`pane.fetch`) names database
/// `alpha`, and a query-line choice — via `chooseDatabase`, the real
/// operator-facing path, not a hand-built `QueryLineDatabaseChoice` — that
/// names `beta` for the pane's next Return. `commitCellEdit` must ignore
/// the choice entirely: both `db_render_update` and `db_run_mutation` must
/// receive `alpha`.
@Test @MainActor func aCellEditUsesTheSubjectDatabaseNotThePendingChoice() async throws {
    let (registry, panes, layout) = try makeRegistry()
    let calls = Recorder()
    await registry.register(Action(
        name: "db_render_update", description: "stub", kind: .read,
        schema: .object(["type": .string("object")]),
        handler: { params in
            await calls.record("db_render_update", params)
            return .object(["structuredContent": .object([
                "statement": .string(#"UPDATE "events" SET "kind" = 'b' WHERE "id" = '1'"#),
            ])])
        }))
    await registry.register(Action(
        name: "db_run_mutation", description: "stub", kind: .read,
        schema: .object(["type": .string("object")]),
        handler: { params in
            await calls.record("db_run_mutation", params)
            return .object(["structuredContent": .object(["rowsAffected": .integer(1)])])
        }))
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main",
        lookup: AlwaysSucceedsCredentialsLookup())

    // The pane's subject: rows read from `events` in database `alpha`.
    let pane = Pane(
        id: "db-1", kind: "db", title: "db-1",
        frame: PaneFrame(x: 0, y: 0, width: 640, height: 420),
        fetch: PaneFetch(query: .table(database: "alpha", name: "events")))
    await panes.setRows(
        paneId: "db-1", columns: ["id", "kind"], columnTypes: ["INTEGER", "TEXT"],
        columnTypesInferred: false, rows: [[.integer(1), .string("a")]],
        millis: 0, truncated: false, pageable: true, offset: 0, sort: [], listsTables: false,
        editable: PaneEditable(
            table: "events", keyColumns: ["id"], columns: ["kind"],
            rowKeys: [#""id" = '1'"#]))

    // The operator picks `beta` from the chooser but never presses
    // Enter — the pane's subject (and the rows on screen) are still
    // `alpha`'s. This is the real path (`chooseDatabase`), not a
    // hand-built choice, so the test fails if that method's own
    // staleness rule ever changes out from under it.
    model.chooseDatabase("beta", pane: pane)
    #expect(model.databaseForQueryLine(pane: pane) == "beta")

    let outcome = await model.commitCellEdit(
        pane: pane, rowKey: #""id" = '1'"#, column: "kind", columnType: "TEXT", value: "b")

    #expect(outcome == .committed)
    guard case .object(let renderParams)? = await calls.params(for: "db_render_update") else {
        return #expect(Bool(false), "db_render_update should have been called")
    }
    guard case .object(let mutateParams)? = await calls.params(for: "db_run_mutation") else {
        return #expect(Bool(false), "db_run_mutation should have been called")
    }
    // The point of the fix: both round trips carry the SUBJECT's
    // database, `alpha` — never `beta`, the pending chooser pick.
    #expect(renderParams["database"] == .string("alpha"))
    #expect(mutateParams["database"] == .string("alpha"))
}

/// Registers a `.mutate` action named `db_run_mutation` — the name
/// `commitCellEdit` always dispatches for its second round trip — whose
/// handler returns `.object([:])`. The same shape
/// `registerTestMutation(into:)` below (Task 10's confirmation-gate
/// section) uses, duplicated in this section under its own name so this
/// section reads independently of that one's ordering in the file.
private func registerRealMutationAction(into registry: ActionRegistry) async {
    await registry.register(Action(
        name: "db_run_mutation", description: "", kind: .mutate, schema: .object([:]),
        handler: { _ in .object([:]) }))
}

/// Registers `db_render_update` as a `.read` action that always answers
/// with the same well-formed `UPDATE`, regardless of what it was asked —
/// these three tests are about the SECOND round trip and the confirmation
/// broker, not about `db_render_update`'s own behaviour.
private func registerRealRenderAction(into registry: ActionRegistry) async {
    await registry.register(Action(
        name: "db_render_update", description: "", kind: .read, schema: .object([:]),
        handler: { _ in
            .object(["structuredContent": .object([
                "statement": .string(#"UPDATE "events" SET "kind" = 'b' WHERE "id" = '1'"#),
            ])])
        }))
}

/// Builds a model wired for these three tests: a real `.mutate`
/// `db_run_mutation`, a real `.read` `db_render_update`, and one editable
/// row under `events` at `"id" = '1'`.
@MainActor
private func makeCommitCellEditGateFixture(
    environment: String
) async throws -> (model: WindowModel, pane: Pane, rowKey: String) {
    let (registry, panes, layout) = try makeRegistry()
    await registerRealRenderAction(into: registry)
    await registerRealMutationAction(into: registry)
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main",
        lookup: AlwaysSucceedsCredentialsLookup(), environment: environment)
    await panes.setRows(
        paneId: "db-1", columns: ["id", "kind"], columnTypes: ["INTEGER", "TEXT"],
        columnTypesInferred: false, rows: [[.integer(1), .string("a")]],
        millis: 0, truncated: false, pageable: true, offset: 0, sort: [], listsTables: false,
        editable: PaneEditable(
            table: "events", keyColumns: ["id"], columns: ["kind"],
            rowKeys: [#""id" = '1'"#]))
    return (model, editingTestPane("db-1"), #""id" = '1'"#)
}

/// The reviewer's disproof of the brief's own instruction: registering the
/// real `.mutate` `db_run_mutation` does not hang. It parks, the same
/// `async let` + `confirmPending` pattern
/// `anOperatorMutationParksAndRunsOnceConfirmed` (Task 10 section) uses
/// drives it to `.approved`, and `commitCellEdit` returns `.committed` —
/// closing the seam every earlier test in this file left open, where
/// `db_run_mutation` was always a `.read` stand-in and never actually
/// reached the confirmation broker.
@Test @MainActor func aCellEditThroughTheRealMutateGateConfirmsAndCommits() async throws {
    let (model, pane, rowKey) = try await makeCommitCellEditGateFixture(environment: "staging")

    async let outcome = model.commitCellEdit(
        pane: pane, rowKey: rowKey, column: "kind", columnType: "TEXT", value: "b")
    while model.pending == nil { await Task.yield() }
    await model.confirmPending(typed: "confirm")

    #expect(await outcome == .committed)
}

/// The operator's own cancel, through the real gate: `.cancelled`, with no
/// reason attached (the enum's own `.cancelled` carries none) — because
/// there is nothing to say beyond "the operator decided not to."
@Test @MainActor func aCellEditCancelledAtTheRealGateReportsCancelledNotRefused() async throws {
    let (model, pane, rowKey) = try await makeCommitCellEditGateFixture(environment: "staging")

    async let outcome = model.commitCellEdit(
        pane: pane, rowKey: rowKey, column: "kind", columnType: "TEXT", value: "b")
    while model.pending == nil { await Task.yield() }
    await model.cancelPending()

    #expect(await outcome == .cancelled)
}

/// Fix Round 1's second Important: in `production`, `writeGate` never
/// parks — `aProductionMutationNeverReachesTheOperator` (Task 10 section)
/// already pins that there is no word that would run it — so
/// `commitCellEdit` never awaits a confirmation here at all. Before the
/// fix this still surfaced as `.cancelled`, with the gate's own
/// `blockedInProduction` sentence dropped on the floor; now it is
/// `.refused`, carrying that sentence, same as any other refusal.
@Test @MainActor func aCellEditBlockedInProductionIsARefusalNotACancel() async throws {
    let (model, pane, rowKey) = try await makeCommitCellEditGateFixture(environment: "production")

    let outcome = await model.commitCellEdit(
        pane: pane, rowKey: rowKey, column: "kind", columnType: "TEXT", value: "b")

    guard case .refused(let reason) = outcome else {
        return #expect(Bool(false), "expected a refusal, got \(outcome)")
    }
    // The gate's sentence, not its case name. This used to assert
    // `contains("blockedInProduction")` — the Swift case, which is what a
    // cell-edit refusal drew in red inside the pane until `ActionError`
    // learned a `description`. The assertion was pinning the leak.
    #expect(reason.contains("blocked in production"))
    #expect(!reason.contains("blockedInProduction"), "the case name is not for the operator")
    // Confirms there is no `db_refetch` action at all in this fixture and
    // still nothing throws: a refusal at the mutate step must not attempt
    // one.
}

// MARK: - Task 6: harnessFactory receives the live org, not the launch one

/// Records what `harnessFactory` was handed. `@unchecked Sendable` because
/// `harnessFactory`'s stored shape is a plain (non-`async`) `@Sendable`
/// closure — matching `WindowSession.start`'s production closure, which
/// only ever does synchronous work — so this is written and read on
/// whichever isolation domain calls the closure/reads the result, never
/// concurrently: `startHarnessForTesting()` runs it synchronously inline,
/// and the `#expect` below only reads `last` after that call has
/// returned.
private final class OrgRecorder: @unchecked Sendable {
    private(set) var last: Place?
    func record(_ place: Place) { last = place }
}

/// Pins the whole point of threading the org through `harnessFactory` as a
/// parameter (2b-viii Task 6): a window that switches org must build its
/// NEXT harness for the org it is running under NOW, not the one it
/// launched with — otherwise the config JSON `harnessFactory` builds would
/// carry the launch org's `WAKIL_ORG` to every MCP server for the rest of
/// the window's life.
@Test func harnessFactoryReceivesTheLiveOrgNotTheLaunchOne() async {
    let seen = OrgRecorder()
    let model = await WindowModel.forTesting(
        scratchRoot: testScratchRoot,
        organization: "alpha",
        harnessFactory: { place, _ in seen.record(place); return nil })
    await model.setOrganizationForTesting("beta")
    _ = await model.startHarnessForTesting()
    #expect(seen.last?.organization == "beta")
}

/// The harness is pinned to the place on screen when it starts, so an agent keeps working
/// there after the operator moves on.
@Test func harnessIsBuiltForThePlaceOnScreenAtSend() async {
    let seen = OrgRecorder()
    let model = await WindowModel.forTesting(
        scratchRoot: testScratchRoot,
        organization: "initech",
        harnessFactory: { place, _ in seen.record(place); return nil })
    await model.seedForTesting(
        providerId: "test-provider", rootPath: "/tmp/wakil-window-model-for-testing", thoughts: 0,
        project: "api", environment: "staging")
    await model.send("hello")
    #expect(seen.last == Place(organization: "initech", project: "api", environment: "staging"))
}

/// What the socket judges an agent's call against is the session's own place, so the operator
/// switching project on screen does not move a running agent. The caller is the one the
/// agent's own socket was started with (Task 4).
@Test @MainActor func theAgentCallerKeepsTheSessionsPlaceAcrossAProjectSwitch() async throws {
    let harnesses = HarnessBox()
    let sessions = Sessions()
    let model = WindowModel.forTesting(
        scratchRoot: testScratchRoot,
        organization: "initech",
        harnessFactory: { _, _ in harnesses.next() },
        agentSocketFactory: sessions.socketFactory)
    model.seedForTesting(
        providerId: "test-provider", rootPath: "/tmp/wakil-window-model-for-testing", thoughts: 0,
        project: "api", environment: "staging")
    await model.send("hello")
    // The operator moves the screen to another project.
    model.seedForTesting(
        providerId: "test-provider", rootPath: "/tmp/wakil-window-model-for-testing", thoughts: 0,
        project: "billing", environment: "staging")

    #expect(model.place.project == "billing")
    let socket = try #require(sessions.issuedSockets.first)
    #expect(await socket.caller().place
        == Place(organization: "initech", project: "api", environment: "staging"))
}

@Test @MainActor func aResumedSessionTakesThePlaceOnScreenAtResume() async throws {
    let (registry, panes, layout) = try makeRegistry()
    await registerFakeReadSession(into: registry, cwd: "/Users/x/proj", entries: [])
    let harnesses = HarnessBox()
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in harnesses.next() }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup(), environment: "staging")
    model.seedForTesting(
        providerId: "main", rootPath: "/Users/x/proj", thoughts: 0,
        project: "billing", environment: "staging")
    #expect(model.agentPlaces.isEmpty)

    await model.resume(sessionId: "parent-1")

    #expect(model.agentPlaces == [model.place])
    #expect(model.agentPlaces.first?.project == "billing")
}

/// Background agents 3 of 4: an org switch ends no place's agent, so the place stays one the
/// pool keeps clients for.
@Test @MainActor func anOrgSwitchKeepsTheAgentPlace() async throws {
    let harnesses = HarnessBox()
    let model = WindowModel.forTesting(
        scratchRoot: testScratchRoot,
        organization: "initech",
        harnessFactory: { _, _ in harnesses.next() })
    model.seedForTesting(
        providerId: "test-provider", rootPath: "/tmp/wakil-window-model-for-testing", thoughts: 0,
        project: "api", environment: "staging")
    await model.send("hello")
    let agentPlace = try #require(model.agentPlaces.first)

    await model.setOrganization("acme")

    #expect(model.agentPlaces == [agentPlace], "initech's agent still runs")
    #expect(model.agents[agentPlace]?.harness != nil)
}

/// A pool client that knows the place it was started for, and a log of the places stopped.
private final class PlaceProbe: ToolCaller, @unchecked Sendable {
    let place: Place
    init(_ place: Place) { self.place = place }
    func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        .object([:])
    }
}

private actor StoppedPlaces {
    private(set) var places: [Place] = []
    func record(_ place: Place) { places.append(place) }
}

private func recordingPool(_ stopped: StoppedPlaces) -> PlaceClients {
    PlaceClients(
        start: { _, place in PlaceProbe(place) },
        stop: { client in if let probe = client as? PlaceProbe { await stopped.record(probe.place) } })
}

/// The window, not a test, tells the pool which places are still in use: an org switch ends
/// no session, so the clients pinned to its place are kept — the agent left in the outgoing
/// org keeps calling through them.
@Test @MainActor func anOrgSwitchKeepsTheAgentPlacesPinnedClients() async throws {
    let stopped = StoppedPlaces()
    let pool = recordingPool(stopped)
    let harnesses = HarnessBox()
    let model = WindowModel.forTesting(
        scratchRoot: testScratchRoot, organization: "initech",
        harnessFactory: { _, _ in harnesses.next() }, placeClients: pool)
    model.seedForTesting(
        providerId: "test-provider", rootPath: "/tmp/wakil-window-model-for-testing", thoughts: 0,
        project: "api", environment: "staging")
    await model.send("hello")
    let agentPlace = try #require(model.agentPlaces.first)
    _ = try await pool.client(.database, for: agentPlace)

    await model.setOrganization("acme")
    await model.settlePlaceRetainForTesting()

    #expect(await !stopped.places.contains(agentPlace))
}

/// A resume in another place starts that place's own agent (background agents 3 of 4); the
/// first place's agent lives on, so its pinned clients are kept.
@Test @MainActor func aResumeInAnotherPlaceKeepsTheFirstPlacesPinnedClients() async throws {
    let (registry, panes, layout) = try makeRegistry()
    await registerFakeReadSession(into: registry, cwd: "/Users/x/proj", entries: [])
    let stopped = StoppedPlaces()
    let pool = recordingPool(stopped)
    let harnesses = HarnessBox()
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _, _, _ in harnesses.next() }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main",
        lookupFactory: { _ in AlwaysSucceedsCredentialsLookup() },
        placeClients: pool, environment: "staging")
    model.seedForTesting(
        providerId: "main", rootPath: "/Users/x/proj", thoughts: 0,
        project: "billing", environment: "staging")
    await model.send("hello")
    let old = try #require(model.agentPlaces.first)
    _ = try await pool.client(.database, for: old)

    model.seedForTesting(
        providerId: "main", rootPath: "/Users/x/proj", thoughts: 0,
        project: "api", environment: "staging")
    await model.resume(sessionId: "parent-1")
    #expect(model.agentPlaces == [old, model.place])

    await model.settlePlaceRetainForTesting()
    #expect(await !stopped.places.contains(old), "the first place's agent still runs")
}

// MARK: - `slugForOrgIdentifier(from:)` — the Creating form's derived id (spec §8.1.1 / §9)

/// The spec's own example, verbatim: "Initech Labs" proposes `initech-labs`.
/// Covers spaces → dash and lowercasing in the one case a reviewer will
/// check first.
@Test func slugSpacesBecomeDashesAndCaseIsLowered() async throws {
    #expect(WindowModel.slugForOrgIdentifier(from: "Initech Labs") == "initech-labs")
    #expect(WindowModel.slugForOrgIdentifier(from: "Umbrella") == "umbrella")
}

/// Leading and trailing junk — whitespace, and punctuation the token
/// pattern forbids as a first character — is dropped rather than
/// producing a leading or trailing dash.
@Test func slugTrimsLeadingAndTrailingJunk() async throws {
    #expect(WindowModel.slugForOrgIdentifier(from: "  Umbrella  ") == "umbrella")
    #expect(WindowModel.slugForOrgIdentifier(from: "!!!Acme!!!") == "acme")
}

/// A run of separators — repeated spaces, dashes, or a mix — collapses to
/// exactly one dash, never one dash per character in the run.
@Test func slugCollapsesRunsOfSeparatorsToOneDash() async throws {
    #expect(WindowModel.slugForOrgIdentifier(from: "A---B") == "a-b")
    #expect(WindowModel.slugForOrgIdentifier(from: "Acme    Corp") == "acme-corp")
    #expect(WindowModel.slugForOrgIdentifier(from: "Acme -_. Corp") == "acme-corp")
}

/// A deliberate design choice, recorded so a future reader does not take
/// it for an oversight: `.`/`-`/`_` are themselves legal in an org id, but
/// this function normalises them into the same single dash as any other
/// separator run, rather than preserving whichever one the operator typed.
/// One rule for every separator is simpler than a rule that treats the
/// three legal ones specially — and the identifier field stays editable,
/// so an operator who wants a literal dot back can still type it.
@Test func slugNormalisesLegalSeparatorCharactersToo() async throws {
    #expect(WindowModel.slugForOrgIdentifier(from: "acme.corp_2") == "acme-corp-2")
}

/// Non-ASCII input must not crash and must still produce a usable token —
/// the non-ASCII character is simply dropped (never turned into a stray
/// dash of its own), so accented or non-Latin characters interleaved with
/// ASCII ones read naturally rather than leaving double dashes behind.
@Test func slugDropsNonASCIICharactersWithoutCrashing() async throws {
    #expect(WindowModel.slugForOrgIdentifier(from: "Café Org") == "caf-org")
    // "ö" is dropped outright (no transliteration to "o", no stray dash),
    // so the two ASCII neighbours it sat between end up adjacent.
    #expect(WindowModel.slugForOrgIdentifier(from: "Björk") == "bjrk")
}

/// A digit-led name is legal input for `orgFileTokenPattern` (a digit may
/// start the token) and must survive as one.
@Test func slugMayStartWithADigit() async throws {
    #expect(WindowModel.slugForOrgIdentifier(from: "3M Company") == "3m-company")
}

/// A name that slugs to nothing — all punctuation, all whitespace, or
/// entirely non-ASCII — returns `nil` rather than a generated placeholder
/// like "org" or "new": the caller leaves the identifier field EMPTY, so
/// the operator is never shown a proposal they did not type.
@Test func slugReturnsNilWhenNothingSurvives() async throws {
    #expect(WindowModel.slugForOrgIdentifier(from: "   ") == nil)
    #expect(WindowModel.slugForOrgIdentifier(from: "!!!") == nil)
    #expect(WindowModel.slugForOrgIdentifier(from: "日本語") == nil)
    #expect(WindowModel.slugForOrgIdentifier(from: "") == nil)
}

/// Every non-nil slug this function can produce must itself satisfy
/// `orgFileTokenPattern` (`internal/wakilcore/paths.go`) — the whole point
/// of deriving one at all. Checked directly against the pattern rather
/// than only against hand-picked expected strings, so a future change to
/// the algorithm cannot silently start producing a token Go would refuse.
@Test func everyNonNilSlugMatchesTheGoOrgTokenPattern() async throws {
    let pattern = try Regex("^[A-Za-z0-9][A-Za-z0-9._-]*$")
    let names = [
        "Initech Labs", "  Umbrella  ", "A---B", "Café Org", "Björk", "3M Company",
        "acme.corp_2", "Acme -_. Corp", "x", "  --3 ",
    ]
    for name in names {
        guard let slug = WindowModel.slugForOrgIdentifier(from: name) else { continue }
        #expect(slug.wholeMatch(of: pattern) != nil, "slug \(slug) (from \(name)) failed the org token pattern")
    }
}

/// `pane_close`'s handler used to end at the dictionary removal below —
/// which releases rows and cannot release a file descriptor. This drives
/// the close through the REAL path (`closePane` dispatches `pane_close`
/// via the registry `WindowModel.forTesting` wires up), and asserts the
/// child was REAPED, by pid, not merely dereferenced from a dictionary
/// that would answer "gone" either way (Task 14).
@Test @MainActor func closingAPaneKillsItsShell() async throws {
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot, organization: "alpha")
    let pane = await model.openTerminalForTesting(path: NSTemporaryDirectory())
    let pid = await model.terminals.pidForTesting(paneId: pane)

    await model.closePane(id: pane)

    #expect(kill(pid!, 0) == -1)
    await model.shutdown()
}

// MARK: - A conversation's panes come back when you resume it (#147)

/// The whole of #147's first criterion, driven the way it actually
/// happens: work in a conversation, quit, relaunch, and land back in that
/// conversation rather than on whatever the project looked like most
/// recently.
///
/// "Relaunch" is a second `WindowModel` over its own empty stores, sharing
/// only the directory on disk — the same device
/// `switchingProjectRestoresItsSavedLayoutAndReportsAnUnreadableOne` uses
/// for a project, because a restart is exactly what a second model with
/// nothing in memory is.
///
/// The second half is what makes it a #147 test rather than a #146 one: a
/// **different** conversation in the same project has been worked in since,
/// so "the project's most recent arrangement" and "this conversation's
/// arrangement" are two different things, and only one of them is right.
@Test @MainActor func relaunchingIntoAConversationRestoresItsPanesAndNotTheProjectsLatest() async throws {
    let bin = windowRepoRoot().appendingPathComponent("bin/wakil-ctx")
    try #require(FileManager.default.isExecutableFile(atPath: bin.path), "run `make build` first")
    let home = try makeFixture(org: "acme", projectOrg: "acme", environments: ["dev"])
    let client = try await startedClient(bin: bin, home: home, org: "acme")
    let directory = try windowScratchDirectory()
    let persistence = LayoutPersistence(directory: directory)

    // What two different conversations left behind, and a project seed that
    // is neither of them — the state a week of work produces.
    let databaseWork = LayoutSnapshot(
        panes: [Pane(id: "db-1", kind: "db", title: "the database conversation",
                     frame: PaneFrame(x: 10, y: 20, width: 300, height: 200))],
        focusedId: "db-1")
    let ticketWork = LayoutSnapshot(
        panes: [Pane(id: "db-2", kind: "db", title: "the ticket conversation",
                     frame: PaneFrame(x: 30, y: 40, width: 300, height: 200))],
        focusedId: "db-2")
    try persistence.save(
        databaseWork,
        for: LayoutScope(organization: "acme", project: "widgets", environment: "", lineageRoot: "root-database"))
    // Saved second, so the project's seed now holds the ticket conversation's
    // panes — "the project's most recent arrangement", and the wrong answer.
    try persistence.save(
        ticketWork,
        for: LayoutScope(organization: "acme", project: "widgets", environment: "", lineageRoot: "root-tickets"))
    #expect(persistence.load(for: LayoutScope(organization: "acme", project: "widgets", environment: "")).snapshot == ticketWork)

    let model = try await windowModelForConversation(
        client: client, persistence: persistence, project: "widgets", conversation: "root-database")

    // `waitUntil`, not a bare `#expect`, for the reason this file's own
    // helper exists: the observation pump is a separate `Task` that calls
    // `refreshContext()` — and so `activateLayout()` — off the back of the
    // dispatches `resume` makes. Asserting the instant `resume` returns
    // reads whichever of the two got there first. Measured flaking at
    // roughly one full run in twelve, and 0/15 scoped, before this.
    // Convergence is the honest property: the canvas ends up showing the
    // conversation's arrangement, whatever order the two activations ran
    // in.
    #expect(
        await waitUntil { model.layoutSnapshot == databaseWork },
        "the conversation's panes, not the project's latest: \(model.layoutSnapshot.panes.map(\.title))")
}

/// A brand-new conversation in a project that has been worked in opens on
/// the project's arrangement — the seed. Every file on disk before #147 is
/// project-keyed, so this is also what makes the change cost the operator
/// nothing.
@Test @MainActor func aBrandNewConversationOpensOnTheProjectsArrangement() async throws {
    let bin = windowRepoRoot().appendingPathComponent("bin/wakil-ctx")
    try #require(FileManager.default.isExecutableFile(atPath: bin.path), "run `make build` first")
    let home = try makeFixture(org: "acme", projectOrg: "acme", environments: ["dev"])
    let client = try await startedClient(bin: bin, home: home, org: "acme")
    let directory = try windowScratchDirectory()
    let persistence = LayoutPersistence(directory: directory)

    // A file exactly as every pre-#147 release wrote it: project-keyed,
    // with no conversation anywhere in it.
    let seed = LayoutSnapshot(
        panes: [Pane(id: "db-7", kind: "db", title: "what was already there",
                     frame: PaneFrame(x: 1, y: 2, width: 300, height: 200))],
        focusedId: "db-7")
    try persistence.save(seed, for: LayoutScope(organization: "acme", project: "widgets", environment: ""))

    let model = try await windowModelForConversation(
        client: client, persistence: persistence, project: "widgets", conversation: nil)
    // Opening a pane is what mints the conversation, so this is the
    // Landing's first act of work — the case #147 calls out, because a
    // session with no turn has no transcript to be looked up in.
    await model.openPane(kind: "db")

    #expect(model.lineageRoot != nil, "opening a pane must put the window in a conversation")
    #expect(
        await waitUntil {
            model.layoutSnapshot.panes.map(\.title).contains("what was already there")
                && model.layoutSnapshot.panes.count == 2
        },
        "the seed a new conversation opens on: \(model.layoutSnapshot.panes.map(\.title))")
}

/// **Overturned at the walk, 2026-09-20 (#160).** Until then this asserted
/// that a conversation opened on ONE arrangement whichever project was
/// active — #142's user story 12. The operator switched to a project with
/// no sessions at all and the canvas did not move; the ruling is on #142,
/// dated. A conversation now keeps one arrangement **per project**, and a
/// project it has never been arranged in opens on that project's seed —
/// which is what this now pins.
@Test @MainActor func aConversationOpensOnTheSeedOfAProjectItHasNotBeenArrangedIn() async throws {
    let bin = windowRepoRoot().appendingPathComponent("bin/wakil-ctx")
    try #require(FileManager.default.isExecutableFile(atPath: bin.path), "run `make build` first")
    let home = try makeTwoProjectFixture(
        org: "acme", projects: [("widgets", ["dev"]), ("gadgets", ["dev"])])
    let client = try await startedClient(bin: bin, home: home, org: "acme")
    let directory = try windowScratchDirectory()
    let persistence = LayoutPersistence(directory: directory)

    // What this conversation arranged in `widgets`, which it must NOT be
    // shown while `gadgets` is active.
    try persistence.save(
        LayoutSnapshot(
            panes: [Pane(id: "db-1", kind: "db", title: "the widgets workspace",
                         frame: PaneFrame(x: 10, y: 20, width: 300, height: 200))],
            focusedId: "db-1"),
        for: LayoutScope(organization: "acme", project: "widgets", environment: "", lineageRoot: "root-a"))
    // And what `gadgets` itself looks like — the seed a conversation with
    // no arrangement in this project opens on.
    let gadgetsSeed = LayoutSnapshot(
        panes: [Pane(id: "db-9", kind: "db", title: "the gadgets seed",
                     frame: PaneFrame(x: 1, y: 2, width: 300, height: 200))],
        focusedId: "db-9")
    try persistence.save(gadgetsSeed, for: LayoutScope(organization: "acme", project: "gadgets", environment: ""))

    // The same conversation, with the OTHER project active.
    let model = try await windowModelForConversation(
        client: client, persistence: persistence, project: "gadgets", conversation: "root-a")

    #expect(
        await waitUntil { model.layoutSnapshot == gadgetsSeed },
        "\(model.layoutSnapshot.panes.map(\.title))")
    // And the widgets arrangement is untouched, rather than having been
    // adopted as this project's or written over.
    #expect(
        persistence.load(
            for: LayoutScope(organization: "acme", project: "widgets", environment: "", lineageRoot: "root-a")
        ).snapshot?.panes.map(\.title) == ["the widgets workspace"])
}

/// An unreadable arrangement opens an empty canvas **and** says so, exactly
/// as a project's did before #147 — it must not quietly become the seed.
@Test @MainActor func anUnreadableConversationLayoutDegradesVisibly() async throws {
    let bin = windowRepoRoot().appendingPathComponent("bin/wakil-ctx")
    try #require(FileManager.default.isExecutableFile(atPath: bin.path), "run `make build` first")
    let home = try makeFixture(org: "acme", projectOrg: "acme", environments: ["dev"])
    let client = try await startedClient(bin: bin, home: home, org: "acme")
    let directory = try windowScratchDirectory()
    let persistence = LayoutPersistence(directory: directory)

    try persistence.save(
        LayoutSnapshot(panes: [Pane(id: "db-5", kind: "db", title: "the seed",
                                    frame: PaneFrame(x: 0, y: 0, width: 10, height: 10))]),
        for: LayoutScope(organization: "acme", project: "widgets", environment: ""))
    // `<org>/conversations/<root>/<project>@<env>.json` since #160 and Plan 3 —
    // the project and environment are in the path because they are in the key.
    // This fixture leaves no environment active, which flattens to `_`.
    let conversations = directory.appendingPathComponent("acme/conversations/root-a")
    try FileManager.default.createDirectory(at: conversations, withIntermediateDirectories: true)
    try "not json".write(
        to: conversations.appendingPathComponent("widgets@_.json"), atomically: true, encoding: .utf8)

    let model = try await windowModelForConversation(
        client: client, persistence: persistence, project: "widgets", conversation: "root-a")

    #expect(
        await waitUntil { model.layoutSnapshot.panes.isEmpty && model.status.contains("root-a") },
        "a corrupt arrangement opens an empty canvas and says so: \(model.status)")
}

/// `session_get` as `wakilcore` answers it, cut down to the one field
/// `WindowModel.lineageRootOfSession` reads.
///
/// **The answer is a function of the id asked about**, because the two
/// things a test needs from this store are different shapes: #147's tests
/// want one conversation however many sessions are named (`{ _ in root }`
/// — a chain of six forks IS one conversation, which is the property
/// under test), and #148's want two, so that a switch has somewhere to
/// switch to.
///
/// Registered after `registerStandardActions`, which overrides its real
/// `session_get` — the same device `registerFakeRefetch` uses, and for the
/// same reason: a live `wakil-ctx` would need a real transcript store with
/// a real fork chain in it to answer, and what is under test is what the
/// window does with the answer.
private func registerFakeGetSession(
    into registry: ActionRegistry, lineageRoot: @escaping @Sendable (String) -> String?
) async {
    await registry.register(Action(
        name: "session_get", description: "test double", kind: .read,
        schema: .object(["type": .string("object")]),
        handler: { params in
            var id = ""
            if case .object(let object) = params, case .string(let value)? = object["id"] {
                id = value
            }
            var fields: [String: JSONValue] = ["provider": .string("main")]
            // Absent, not empty, when there is none — which is what an
            // older `wakil-ctx` on this machine would actually produce,
            // `bin/` being per-worktree and routinely stale.
            if let root = lineageRoot(id) { fields["lineageRoot"] = .string(root) }
            return .object(["structuredContent": .object(fields)])
        }
    ))
}

/// A window standing in one conversation, built the way a relaunch builds
/// one: fresh stores, nothing in memory, only the directory on disk shared.
///
/// **It gets there through `resume`**, which is how an operator gets there
/// too — the Landing lists conversations and picking one forks it. Nothing
/// here reaches past the public surface to plant a lineage root, so these
/// tests fail if `resume` stops inheriting one.
///
/// `conversation` is the lineage root the resumed session belongs to, or
/// `nil` for a window that has not begun work — the Landing.
@MainActor
private func windowModelForConversation(
    client: MCPClient, persistence: LayoutPersistence, project: String, conversation: String?
) async throws -> WindowModel {
    // The project first, the conversation second — the order a relaunch
    // has: the window resolves its context, draws the Landing, and the
    // operator picks a conversation off it. `lineageRoot` ignores the id
    // it is asked about, because one conversation is what this fixture
    // stands a window in.
    let window = try await windowOnTheLanding(
        client: client, persistence: persistence, project: project,
        lineageRoot: { _ in conversation })
    guard conversation != nil else { return window.model }
    await window.model.resume(sessionId: "parent-1")
    return window.model
}

/// A conversation started fresh is its own root — the same answer
/// `wakilcore.LineageRootIn` gives for an id with no recorded parent — and
/// it exists from the first act of work, not from the first turn.
@Test @MainActor func aFreshConversationIsItsOwnRoot() async throws {
    let (registry, panes, layout) = try makeRegistry()
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main",
        lookup: AlwaysSucceedsCredentialsLookup(), environment: "staging")

    #expect(model.lineageRoot == nil, "the Landing is not yet a conversation")

    model.markSessionStarted()
    #expect(model.lineageRoot == model.assignedSessionId)
    #expect(model.lineageRoot != nil)
}

/// **The whole point of the root.** A resume mints a new session id, so
/// `assignedSessionId` moves; the conversation does not. Keyed on the
/// session id, continuing a conversation would abandon the workspace that
/// belongs to it.
@Test @MainActor func aResumeInheritsTheParentsLineageRootRatherThanTakingTheChildsId() async throws {
    let (registry, panes, layout) = try makeRegistry()
    await registerFakeReadSession(into: registry, cwd: "/Users/x/proj", entries: [])
    await registerFakeGetSession(into: registry, lineageRoot: { _ in "the-oldest-ancestor" })
    let harnesses = HarnessBox()
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in harnesses.next() }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main",
        lookup: AlwaysSucceedsCredentialsLookup(), environment: "staging")

    await model.resume(sessionId: "parent-1")

    #expect(model.lineageRoot == "the-oldest-ancestor")
    #expect(model.assignedSessionId != "the-oldest-ancestor", "the id forked; the conversation did not")
    #expect(model.assignedSessionId == model.sessionId)
}

/// "A chain of six forks is still one workspace and not six" (#142's user
/// story 7). Every resume asks `wakilcore` for the root, and `wakilcore`
/// resolves it against the whole org's map, so the answer does not drift
/// however long the chain gets.
@Test @MainActor func aChainOfResumesKeepsOneConversation() async throws {
    let (registry, panes, layout) = try makeRegistry()
    await registerFakeReadSession(into: registry, cwd: "/Users/x/proj", entries: [])
    await registerFakeGetSession(into: registry, lineageRoot: { _ in "the-oldest-ancestor" })
    let harnesses = HarnessBox()
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in harnesses.next() }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main",
        lookup: AlwaysSucceedsCredentialsLookup(), environment: "staging")

    var ids: Set<String> = []
    for fork in 1...6 {
        await model.resume(sessionId: "parent-\(fork)")
        ids.insert(try #require(model.assignedSessionId))
        #expect(model.lineageRoot == "the-oldest-ancestor", "fork \(fork) left the conversation")
    }
    #expect(ids.count == 6, "six forks really were six different sessions")
}

/// A lineage that cannot be read falls back to the project's arrangement,
/// **not** to the parent's own id.
///
/// The parent's id is the plausible-looking wrong answer: mid-chain it
/// names a different file from the one this conversation's panes are
/// actually in, so the operator would get an empty canvas *and* a second
/// workspace filed beside the real one, with nothing to say so. `nil` is
/// the project's seed — what a brand-new conversation gets, which is a
/// state the operator already understands.
@Test @MainActor func aResumeWhoseLineageCannotBeReadFallsBackToTheProjectRatherThanGuessing() async throws {
    let (registry, panes, layout) = try makeRegistry()
    await registerFakeReadSession(into: registry, cwd: "/Users/x/proj", entries: [])
    await registerFakeGetSession(into: registry, lineageRoot: { _ in nil })
    let harnesses = HarnessBox()
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in harnesses.next() }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main",
        lookup: AlwaysSucceedsCredentialsLookup(), environment: "staging")

    await model.resume(sessionId: "parent-1")

    #expect(model.lineageRoot == nil)
    #expect(model.lineageRoot != "parent-1", "the parent's own id is the wrong answer mid-chain")
}

/// A resume that is refused never reaches the swap, so it must not move the
/// conversation either — the arrangement on screen belongs to the session
/// still running.
@Test @MainActor func aRefusedResumeLeavesTheConversationWhereItWas() async throws {
    let (registry, panes, layout) = try makeRegistry()
    // A transcript belonging to another provider: `resume` refuses.
    await registerFakeReadSession(
        into: registry, cwd: "/Users/x/proj", entries: [], provider: "someone-else")
    await registerFakeGetSession(into: registry, lineageRoot: { _ in "the-oldest-ancestor" })
    let harnesses = HarnessBox()
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in harnesses.next() }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main",
        lookup: AlwaysSucceedsCredentialsLookup(), environment: "staging")

    await model.send("start a conversation of our own")
    let ours = try #require(model.lineageRoot)

    await model.resume(sessionId: "parent-1")

    #expect(model.status.contains("someone-else"), "\(model.status)")
    #expect(model.lineageRoot == ours, "a refused resume must not rekey the canvas")
}

/// A provider switch starts a new conversation — a different account, a
/// different transcript store — so the canvas must be re-keyed to it.
///
/// **Found by review, not by this test.** Without the `activateLayout()`
/// that ends `setProvider`, the window sat in a new conversation while
/// `layoutScope` still named the old one, and `persistLayout` writes under
/// `layoutScope`: the new conversation's panes went straight over the
/// previous conversation's file. That is the loss #142 exists to stop,
/// reintroduced one path over.
@Test @MainActor func switchingProviderRekeysTheCanvasToTheNewConversation() async throws {
    let bin = windowRepoRoot().appendingPathComponent("bin/wakil-ctx")
    try #require(FileManager.default.isExecutableFile(atPath: bin.path), "run `make build` first")
    let home = try makeFixture(org: "acme", projectOrg: "acme", environments: ["dev"])
    try writeProviderFixture(home: home, org: "acme", id: "second")
    let client = try await startedClient(bin: bin, home: home, org: "acme")
    let directory = try windowScratchDirectory()
    let persistence = LayoutPersistence(directory: directory)

    let model = try await windowModelForConversation(
        client: client, persistence: persistence, project: "widgets", conversation: "root-first")
    try #require(model.lineageRoot == "root-first")
    await model.openPane(kind: "db")
    let before = model.layoutSnapshot.panes.count
    try #require(before > 0)

    await model.setProvider("second")

    // A different conversation, and the canvas knows it.
    #expect(model.lineageRoot != "root-first", "\(model.status)")
    let root = try #require(model.lineageRoot)
    await model.openPane(kind: "db")

    // The first conversation's file still holds what it held, rather than
    // having been overwritten by the second conversation's panes.
    let first = persistence.load(
        for: LayoutScope(organization: "acme", project: "widgets", environment: "", lineageRoot: "root-first"))
    #expect(first.snapshot?.panes.count == before)
    // And the new conversation has a file of its own. It opens on the
    // project's seed — which the first conversation's own saves kept up to
    // date — and the pane just opened is added to it, so it holds one more
    // than the seed rather than starting empty.
    let second = persistence.load(
        for: LayoutScope(organization: "acme", project: "widgets", environment: "", lineageRoot: root))
    #expect(second.snapshot?.panes.count == before + 1)
}

// MARK: - Switching conversations swaps the canvas (#148)

/// A window standing on the Landing of one project, plus the handles a
/// switching test needs to reach past it: the registry, to re-register a
/// session double between switches; the harness box, to make the next
/// resume fail to start; and the two stores, to plant contents or an
/// uncommitted arrangement the way a dispatch in flight would.
@MainActor
private struct LandedWindow {
    let model: WindowModel
    let registry: ActionRegistry
    let harnesses: HarnessBox
    let panes: PaneStore
    let layout: LayoutStore
}

/// A window on the Landing of `project`, wired with the two session
/// doubles a conversation needs, and nothing planted past the public
/// surface: every conversation these tests visit is reached through
/// `resume`, which is how ⌘P reaches one.
///
/// `lineageRoot` answers `session_get` — see that double for why the
/// answer is a function of the id rather than a single value.
///
/// **One `ResumeBroker`, shared.** `session_resume` parks a request rather
/// than resuming — that is what lets the agent and `--dispatch` reach it —
/// and `resumePump` drains the broker the MODEL was given. Handing the
/// actions a broker of their own would park every ⌘P selection where
/// nobody is looking, and the switch would silently never happen.
@MainActor
private func windowOnTheLanding(
    client: MCPClient, persistence: LayoutPersistence, project: String,
    lineageRoot: @escaping @Sendable (String) -> String?
) async throws -> LandedWindow {
    let (registry, panes, layout) = try makeRegistry()
    let resumes = ResumeBroker()
    await registerStandardActions(
        into: registry, context: client, panes: panes, db: nil, resumes: resumes)
    await registerLayoutActions(into: registry, layout: layout)
    let harnesses = HarnessBox()
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, persistence: persistence,
        context: ContextStore(client: client),
        harnessFactory: { _ in harnesses.next() }, resumes: resumes,
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup())
    await model.setProject(project)
    // Registered only now, and told the provider the window actually
    // ended up with: `refreshContext` above re-reads `providerId` off the
    // live context, and `resume` refuses a session belonging to a
    // different provider than the window is running. A fixture that
    // hard-coded "main" here would be testing that refusal instead.
    await registerFakeReadSession(
        into: registry, cwd: "/Users/x/proj", entries: [], provider: model.providerId)
    await registerFakeGetSession(into: registry, lineageRoot: lineageRoot)
    return LandedWindow(
        model: model, registry: registry, harnesses: harnesses, panes: panes, layout: layout)
}

/// The two conversations every switching test below moves between, as
/// `session_get` answers for the sessions that belong to them.
private let twoConversations: @Sendable (String) -> String? = { id in
    ["parent-db": "root-database", "parent-tk": "root-tickets"][id]
}

/// One pane, named, at a distinct frame — enough to tell two conversations'
/// arrangements apart by eye in a failure message.
private func arrangement(id: String, title: String, x: Double) -> LayoutSnapshot {
    LayoutSnapshot(
        panes: [Pane(id: id, kind: "db", title: title,
                     frame: PaneFrame(x: x, y: 0, width: 300, height: 200))],
        focusedId: id)
}

/// #148's first criterion, and the whole of what the operator asked for:
/// move between two conversations in the same project and watch the panes
/// swap, the way they already do when you switch project.
@Test @MainActor func switchingConversationSwapsTheCanvas() async throws {
    let bin = windowRepoRoot().appendingPathComponent("bin/wakil-ctx")
    try #require(FileManager.default.isExecutableFile(atPath: bin.path), "run `make build` first")
    let home = try makeFixture(org: "acme", projectOrg: "acme", environments: ["dev"])
    let client = try await startedClient(bin: bin, home: home, org: "acme")
    let persistence = LayoutPersistence(directory: try windowScratchDirectory())

    let databaseWork = arrangement(id: "db-1", title: "the database conversation", x: 10)
    let ticketWork = arrangement(id: "db-2", title: "the ticket conversation", x: 30)
    try persistence.save(
        databaseWork,
        for: LayoutScope(organization: "acme", project: "widgets", environment: "", lineageRoot: "root-database"))
    try persistence.save(
        ticketWork,
        for: LayoutScope(organization: "acme", project: "widgets", environment: "", lineageRoot: "root-tickets"))

    let window = try await windowOnTheLanding(
        client: client, persistence: persistence, project: "widgets",
        lineageRoot: twoConversations)
    let model = window.model

    await model.resume(sessionId: "parent-db")
    #expect(
        await waitUntil { model.layoutSnapshot == databaseWork },
        "first conversation: \(model.layoutSnapshot.panes.map(\.title))")

    await model.resume(sessionId: "parent-tk")
    #expect(
        await waitUntil { model.layoutSnapshot == ticketWork },
        "the switch must swap the canvas: \(model.layoutSnapshot.panes.map(\.title))")
}

/// "Switching back finds the first conversation's arrangement as it was
/// left, **including panes opened after the switch away**" — the property
/// keeping the outgoing arrangement in memory buys, and the one a
/// tear-down-and-reload would quietly break.
@Test @MainActor func switchingBackFindsTheConversationAsItWasLeft() async throws {
    let bin = windowRepoRoot().appendingPathComponent("bin/wakil-ctx")
    try #require(FileManager.default.isExecutableFile(atPath: bin.path), "run `make build` first")
    let home = try makeFixture(org: "acme", projectOrg: "acme", environments: ["dev"])
    let client = try await startedClient(bin: bin, home: home, org: "acme")
    let persistence = LayoutPersistence(directory: try windowScratchDirectory())

    try persistence.save(
        arrangement(id: "db-1", title: "the database conversation", x: 10),
        for: LayoutScope(organization: "acme", project: "widgets", environment: "", lineageRoot: "root-database"))
    try persistence.save(
        arrangement(id: "db-2", title: "the ticket conversation", x: 30),
        for: LayoutScope(organization: "acme", project: "widgets", environment: "", lineageRoot: "root-tickets"))

    let window = try await windowOnTheLanding(
        client: client, persistence: persistence, project: "widgets",
        lineageRoot: twoConversations)
    let model = window.model

    await model.resume(sessionId: "parent-db")
    try #require(await waitUntil { model.layoutSnapshot.panes.count == 1 })
    // Opened after the conversation was restored, and before the switch
    // away: this is the pane a reload from disk would be at risk of losing.
    await model.openPane(kind: "db")
    try #require(await waitUntil { model.layoutSnapshot.panes.count == 2 })

    await model.resume(sessionId: "parent-tk")
    try #require(
        await waitUntil {
            model.layoutSnapshot.panes.map(\.title) == ["the ticket conversation"]
        },
        "\(model.layoutSnapshot.panes.map(\.title))")

    await model.resume(sessionId: "parent-db")
    #expect(
        await waitUntil {
            model.layoutSnapshot.panes.count == 2
                && model.layoutSnapshot.panes.contains { $0.title == "the database conversation" }
        },
        "as it was left, extra pane and all: \(model.layoutSnapshot.panes.map(\.title))")
}

/// "Switching back does not cost a disk read for an arrangement already in
/// memory."
///
/// Asserted the only way an operator could observe it: the file is changed
/// underneath the window while the conversation is away, and the canvas
/// that comes back is the one memory held. A re-read would draw the
/// planted file instead.
///
/// **What it measures is a read that CHANGES the canvas**, not the
/// absence of a syscall. A read whose result was discarded would pass
/// here. That is the right line to draw: the criterion exists because
/// re-reading destroys what was opened since (`activateLayout`'s own
/// reasoning on `loadedLayoutScopes`), and a read nothing acts on
/// destroys nothing. Counting reads would need a seam in
/// `LayoutPersistence` that exists for no other reason.
@Test @MainActor func switchingBackDoesNotRereadAnArrangementAlreadyInMemory() async throws {
    let bin = windowRepoRoot().appendingPathComponent("bin/wakil-ctx")
    try #require(FileManager.default.isExecutableFile(atPath: bin.path), "run `make build` first")
    let home = try makeFixture(org: "acme", projectOrg: "acme", environments: ["dev"])
    let client = try await startedClient(bin: bin, home: home, org: "acme")
    let persistence = LayoutPersistence(directory: try windowScratchDirectory())

    let inMemory = LayoutScope(
        organization: "acme", project: "widgets", environment: "", lineageRoot: "root-database")
    try persistence.save(arrangement(id: "db-1", title: "from memory", x: 10), for: inMemory)
    try persistence.save(
        arrangement(id: "db-2", title: "the ticket conversation", x: 30),
        for: LayoutScope(organization: "acme", project: "widgets", environment: "", lineageRoot: "root-tickets"))

    let window = try await windowOnTheLanding(
        client: client, persistence: persistence, project: "widgets",
        lineageRoot: twoConversations)
    let model = window.model

    await model.resume(sessionId: "parent-db")
    try #require(await waitUntil { model.layoutSnapshot.panes.map(\.title) == ["from memory"] })

    await model.resume(sessionId: "parent-tk")
    try #require(
        await waitUntil { model.layoutSnapshot.panes.map(\.title) == ["the ticket conversation"] })

    // Planted while the conversation is away, and only ever visible if the
    // window goes back to disk for something it already holds.
    try persistence.save(arrangement(id: "db-9", title: "from disk", x: 99), for: inMemory)

    await model.resume(sessionId: "parent-db")
    try #require(await waitUntil { model.layoutSnapshot.panes.count == 1 })
    #expect(
        model.layoutSnapshot.panes.map(\.title) == ["from memory"],
        "a scope already read once must not be read again: \(model.layoutSnapshot.panes.map(\.title))")
}

/// "The outgoing arrangement is saved before the incoming one is
/// restored, so switching away and back never loses it."
///
/// **The change it leaves behind is an UNCOMMITTED one**, made against
/// `LayoutStore` directly rather than through a dispatch. Asserting on a
/// pane opened the ordinary way proves nothing: the dispatch that opened
/// it already committed it, so the file holds it whether or not a switch
/// flushes anything. What the flush exists for is the change that had not
/// been committed when the switch arrived — a dispatch still in flight,
/// or one whose commit had not been scheduled yet — and the only way to
/// stand a window in that state is to put the change where a dispatch
/// would have put it and not run the commit.
///
/// **The switch is the Landing's**, not a conversation's, and that is
/// what makes this measurable rather than a race. Every conversation
/// switch is reached through a dispatch (`session_resume`), and the
/// observation pump commits off the back of each one: measured 10 runs
/// out of 10, the pump got to the uncommitted change before the swap did,
/// so a conversation-switch version of this test passes with the flush
/// deleted. `openPane` from the Landing is the one entrance that reaches
/// `activateLayout` with no dispatch in front of it — `enterConversation`
/// mints the conversation and activates BEFORE dispatching `pane_open` —
/// so here the flush is the only thing that can carry the change across.
///
/// What the operator sees: a pane arranged on the Landing is still there
/// in the conversation that pane starts. Without the flush it is dropped,
/// and dropped silently — the store had it, no file ever did.
@Test @MainActor func theOutgoingArrangementIsSavedBeforeTheIncomingOneIsRestored() async throws {
    let bin = windowRepoRoot().appendingPathComponent("bin/wakil-ctx")
    try #require(FileManager.default.isExecutableFile(atPath: bin.path), "run `make build` first")
    let home = try makeFixture(org: "acme", projectOrg: "acme", environments: ["dev"])
    let client = try await startedClient(bin: bin, home: home, org: "acme")
    let persistence = LayoutPersistence(directory: try windowScratchDirectory())

    let seed = LayoutScope(organization: "acme", project: "widgets", environment: "")
    try persistence.save(arrangement(id: "db-1", title: "the project seed", x: 10), for: seed)

    let window = try await windowOnTheLanding(
        client: client, persistence: persistence, project: "widgets",
        lineageRoot: twoConversations)
    let model = window.model
    try #require(await waitUntil { model.layoutSnapshot.panes.map(\.title) == ["the project seed"] })

    // Arranged, and not committed: exactly where a dispatch that has not
    // reached its `refreshLayout` yet leaves the window.
    _ = await window.layout.open(kind: "db", title: "arranged and not yet committed")
    try #require(model.layoutSnapshot.panes.count == 1, "the model must not have seen it yet")

    // Opening a pane mints the conversation, which moves the scope — the
    // switch under test, with nothing dispatched before it.
    await model.openPane(kind: "db")
    try #require(model.lineageRoot != nil)

    #expect(
        await waitUntil {
            model.layoutSnapshot.panes.map(\.title).contains("arranged and not yet committed")
        },
        "the arrangement being left must reach disk first: \(model.layoutSnapshot.panes.map(\.title))")
    #expect(
        persistence.load(for: seed).snapshot?.panes.map(\.title)
            .contains("arranged and not yet committed") == true,
        "and it belongs to the scope it was made in")
}

/// "A refused or failed session switch leaves the canvas exactly as it
/// was." `aRefusedResumeLeavesTheConversationWhereItWas` pins the
/// conversation; this pins the panes, which is what the operator sees.
@Test @MainActor func aRefusedSessionSwitchLeavesTheCanvasExactlyAsItWas() async throws {
    let bin = windowRepoRoot().appendingPathComponent("bin/wakil-ctx")
    try #require(FileManager.default.isExecutableFile(atPath: bin.path), "run `make build` first")
    let home = try makeFixture(org: "acme", projectOrg: "acme", environments: ["dev"])
    let client = try await startedClient(bin: bin, home: home, org: "acme")
    let persistence = LayoutPersistence(directory: try windowScratchDirectory())

    try persistence.save(
        arrangement(id: "db-1", title: "the database conversation", x: 10),
        for: LayoutScope(organization: "acme", project: "widgets", environment: "", lineageRoot: "root-database"))

    let window = try await windowOnTheLanding(
        client: client, persistence: persistence, project: "widgets",
        lineageRoot: { ["parent-db": "root-database", "parent-other": "root-other"][$0] })
    let model = window.model

    await model.resume(sessionId: "parent-db")
    try #require(await waitUntil { model.layoutSnapshot.panes.count == 1 })
    let before = model.layoutSnapshot

    // A transcript belonging to another provider: `resume` refuses before
    // it touches anything.
    await registerFakeReadSession(
        into: window.registry, cwd: "/Users/x/proj", entries: [], provider: "someone-else")
    await model.resume(sessionId: "parent-other")

    #expect(model.status.contains("someone-else"), "\(model.status)")
    #expect(model.lineageRoot == "root-database", "a refused switch must not rekey the canvas")
    #expect(
        await waitUntil { model.layoutSnapshot == before },
        "the canvas must not move: \(model.layoutSnapshot.panes.map(\.title))")
}

/// The other half of the same criterion: a switch that is not refused but
/// FAILS — the forked agent will not start.
///
/// A different branch from the refusal above, and the one worth its own
/// test: it is reached after the lineage of the conversation being
/// switched to has already been read, which is the last point at which a
/// half-applied switch could leave the canvas keyed to a conversation the
/// window is not in.
@Test @MainActor func aFailedSessionSwitchLeavesTheCanvasExactlyAsItWas() async throws {
    let bin = windowRepoRoot().appendingPathComponent("bin/wakil-ctx")
    try #require(FileManager.default.isExecutableFile(atPath: bin.path), "run `make build` first")
    let home = try makeFixture(org: "acme", projectOrg: "acme", environments: ["dev"])
    let client = try await startedClient(bin: bin, home: home, org: "acme")
    let persistence = LayoutPersistence(directory: try windowScratchDirectory())

    let staying = LayoutScope(organization: "acme", project: "widgets", environment: "", lineageRoot: "root-database")
    try persistence.save(arrangement(id: "db-1", title: "the database conversation", x: 10), for: staying)
    try persistence.save(
        arrangement(id: "db-2", title: "the ticket conversation", x: 30),
        for: LayoutScope(organization: "acme", project: "widgets", environment: "", lineageRoot: "root-tickets"))

    let window = try await windowOnTheLanding(
        client: client, persistence: persistence, project: "widgets",
        lineageRoot: twoConversations)
    let model = window.model

    await model.resume(sessionId: "parent-db")
    try #require(await waitUntil { model.layoutSnapshot.panes.count == 1 })
    await model.openPane(kind: "db")
    try #require(await waitUntil { model.layoutSnapshot.panes.count == 2 })
    let before = model.layoutSnapshot

    struct WillNotStart: Error {}
    window.harnesses.nextStartError = WillNotStart()
    await model.resume(sessionId: "parent-tk")

    #expect(model.lineageRoot == "root-database", "a failed switch must not rekey the canvas")
    #expect(
        await waitUntil { model.layoutSnapshot == before },
        "the canvas must not move: \(model.layoutSnapshot.panes.map(\.title))")
    // And nothing of this conversation's was filed under the one it did
    // not reach.
    #expect(persistence.load(for: staying).snapshot?.panes.count == 2)
}

/// The switch as the operator makes it: a row in ⌘P.
///
/// The tests above call `resume` directly, which is the orchestrator's
/// entrance; this one pins the road to it. ⌘P does not resume — it
/// dispatches `session_resume`, which PARKS a request that `resumePump`
/// drains, so "the palette reaches the canvas" is a claim about three
/// components and not one. Before #148 the park reached the session and
/// stopped there: the thread changed and the canvas did not move.
@Test @MainActor func aConversationChosenInThePaletteSwapsTheCanvas() async throws {
    let bin = windowRepoRoot().appendingPathComponent("bin/wakil-ctx")
    try #require(FileManager.default.isExecutableFile(atPath: bin.path), "run `make build` first")
    let home = try makeFixture(org: "acme", projectOrg: "acme", environments: ["dev"])
    let client = try await startedClient(bin: bin, home: home, org: "acme")
    let persistence = LayoutPersistence(directory: try windowScratchDirectory())

    let databaseWork = arrangement(id: "db-1", title: "the database conversation", x: 10)
    let ticketWork = arrangement(id: "db-2", title: "the ticket conversation", x: 30)
    try persistence.save(
        databaseWork,
        for: LayoutScope(organization: "acme", project: "widgets", environment: "", lineageRoot: "root-database"))
    try persistence.save(
        ticketWork,
        for: LayoutScope(organization: "acme", project: "widgets", environment: "", lineageRoot: "root-tickets"))

    let window = try await windowOnTheLanding(
        client: client, persistence: persistence, project: "widgets",
        lineageRoot: twoConversations)
    let model = window.model

    _ = await model.performPalette(.run(.resumeSession("parent-db")))
    #expect(
        await waitUntil { model.layoutSnapshot == databaseWork },
        "first conversation: \(model.layoutSnapshot.panes.map(\.title))")

    _ = await model.performPalette(.run(.resumeSession("parent-tk")))
    #expect(
        await waitUntil { model.layoutSnapshot == ticketWork },
        "⌘P must swap the canvas: \(model.layoutSnapshot.panes.map(\.title))")
}

/// "Pane contents follow the arrangement across the switch, so one
/// conversation's panes never show another's rows."
///
/// Both conversations hold a pane called `db-1` — the case that makes this
/// a real hazard rather than a theoretical one: pane ids are unique within
/// a process but not across saved arrangements, so without `PaneStore`
/// following the scope the second conversation's `db-1` draws the first
/// one's rows.
@Test @MainActor func paneContentsFollowTheArrangementAcrossAConversationSwitch() async throws {
    let bin = windowRepoRoot().appendingPathComponent("bin/wakil-ctx")
    try #require(FileManager.default.isExecutableFile(atPath: bin.path), "run `make build` first")
    let home = try makeFixture(org: "acme", projectOrg: "acme", environments: ["dev"])
    let client = try await startedClient(bin: bin, home: home, org: "acme")
    let persistence = LayoutPersistence(directory: try windowScratchDirectory())

    try persistence.save(
        arrangement(id: "db-1", title: "the database conversation", x: 10),
        for: LayoutScope(organization: "acme", project: "widgets", environment: "", lineageRoot: "root-database"))
    try persistence.save(
        arrangement(id: "db-1", title: "the ticket conversation", x: 30),
        for: LayoutScope(organization: "acme", project: "widgets", environment: "", lineageRoot: "root-tickets"))

    let window = try await windowOnTheLanding(
        client: client, persistence: persistence, project: "widgets",
        lineageRoot: twoConversations)
    let model = window.model
    let panes = window.panes

    await model.resume(sessionId: "parent-db")
    try #require(await waitUntil { model.layoutSnapshot.panes.map(\.id) == ["db-1"] })
    await setOneRow(panes, "the database conversation's rows")
    await model.refreshPanes()
    try #require(model.tables["db-1"]?.rows.count == 1)

    await model.resume(sessionId: "parent-tk")
    try #require(
        await waitUntil { model.layoutSnapshot.panes.map(\.title) == ["the ticket conversation"] })
    // Given rows of its own, so the assertion below is about WHICH rows
    // `db-1` is drawing rather than about whether it is drawing any. A
    // bare "the table is empty" would hold just as well if the switch had
    // restored nothing at all.
    await setOneRow(panes, "the ticket conversation's rows")
    await model.refreshPanes()
    #expect(
        model.tables["db-1"]?.rows.count == 1
            && !oneCell(model).contains("database"),
        "the other conversation's db-1 must not draw these rows: \(oneCell(model))")

    // And back: the first conversation's rows are still its own, which is
    // the half that a `PaneStore` simply cleared on every switch would
    // also pass the assertion above.
    await model.resume(sessionId: "parent-db")
    try #require(
        await waitUntil {
            model.layoutSnapshot.panes.map(\.title) == ["the database conversation"]
        })
    await model.refreshPanes()
    #expect(
        oneCell(model).contains("database"),
        "returning must find the rows it left: \(oneCell(model))")
}

/// One row in `db-1`, the pane both conversations in the test above hold.
private func setOneRow(_ panes: PaneStore, _ text: String) async {
    await panes.setRows(
        paneId: "db-1", columns: ["row"], columnTypes: ["text"], columnTypesInferred: false,
        rows: [[.string(text)]], millis: 1, truncated: false,
        pageable: false, offset: 0, sort: [], listsTables: false, editable: nil)
}

/// What `db-1` is drawing, as one string — so a failure says which
/// conversation's rows are on screen rather than how many.
@MainActor
private func oneCell(_ model: WindowModel) -> String {
    String(describing: model.tables["db-1"]?.rows.map(\.cells))
}

/// "Switching to a conversation with no arrangement opens the project's
/// seed, matching what a relaunch into it would give."
@Test @MainActor func switchingToAConversationWithNoArrangementOpensTheProjectsSeed() async throws {
    let bin = windowRepoRoot().appendingPathComponent("bin/wakil-ctx")
    try #require(FileManager.default.isExecutableFile(atPath: bin.path), "run `make build` first")
    let home = try makeFixture(org: "acme", projectOrg: "acme", environments: ["dev"])
    let client = try await startedClient(bin: bin, home: home, org: "acme")
    let persistence = LayoutPersistence(directory: try windowScratchDirectory())

    try persistence.save(
        arrangement(id: "db-1", title: "the database conversation", x: 10),
        for: LayoutScope(organization: "acme", project: "widgets", environment: "", lineageRoot: "root-database"))
    // The seed a pre-#147 release left behind: project-keyed, no
    // conversation in it, and what a conversation with none of its own
    // opens on.
    try persistence.save(
        arrangement(id: "db-5", title: "the project seed", x: 50),
        for: LayoutScope(organization: "acme", project: "widgets", environment: ""))

    let window = try await windowOnTheLanding(
        client: client, persistence: persistence, project: "widgets",
        lineageRoot: { ["parent-db": "root-database", "parent-new": "root-never-arranged"][$0] })
    let model = window.model

    await model.resume(sessionId: "parent-db")
    try #require(
        await waitUntil { model.layoutSnapshot.panes.map(\.title) == ["the database conversation"] })

    await model.resume(sessionId: "parent-new")

    #expect(
        await waitUntil { model.layoutSnapshot.panes.map(\.title) == ["the project seed"] },
        "\(model.layoutSnapshot.panes.map(\.title))")
    // **And the files are still there**, which is the destructive half of
    // the same defect and the one an operator would not notice until the
    // next launch. Before the fix the switch committed an empty canvas
    // under the incoming conversation — and a conversation's save also
    // refreshes the project's seed, so BOTH of these came back `[]` and
    // every later conversation opened on nothing.
    #expect(
        persistence.load(for: LayoutScope(organization: "acme", project: "widgets", environment: ""))
            .snapshot?.panes.map(\.title) == ["the project seed"],
        "the seed must survive a switch onto it")
    #expect(
        persistence.load(
            for: LayoutScope(organization: "acme", project: "widgets", environment: "", lineageRoot: "root-database")
        ).snapshot?.panes.map(\.title) == ["the database conversation"],
        "and so must the conversation switched away from")
}

/// "Switching to a conversation that had no panes open gives an empty
/// canvas, rather than inheriting whatever was on screen." Nothing open is
/// a state a conversation can be in, and it is not the same state as never
/// having been arranged.
@Test @MainActor func switchingToAConversationThatHadNoPanesOpenGivesAnEmptyCanvas() async throws {
    let bin = windowRepoRoot().appendingPathComponent("bin/wakil-ctx")
    try #require(FileManager.default.isExecutableFile(atPath: bin.path), "run `make build` first")
    let home = try makeFixture(org: "acme", projectOrg: "acme", environments: ["dev"])
    let client = try await startedClient(bin: bin, home: home, org: "acme")
    let persistence = LayoutPersistence(directory: try windowScratchDirectory())

    // Written in this order so the project's seed — which `save` refreshes
    // for every conversation write — ends up holding the arrangement, not
    // the empty canvas. Without that the seed would be empty too and the
    // test would pass for the wrong reason.
    try persistence.save(
        LayoutSnapshot(panes: []),
        for: LayoutScope(organization: "acme", project: "widgets", environment: "", lineageRoot: "root-empty"))
    try persistence.save(
        arrangement(id: "db-1", title: "the database conversation", x: 10),
        for: LayoutScope(organization: "acme", project: "widgets", environment: "", lineageRoot: "root-database"))

    let window = try await windowOnTheLanding(
        client: client, persistence: persistence, project: "widgets",
        lineageRoot: { ["parent-db": "root-database", "parent-empty": "root-empty"][$0] })
    let model = window.model

    await model.resume(sessionId: "parent-db")
    try #require(
        await waitUntil { model.layoutSnapshot.panes.map(\.title) == ["the database conversation"] })

    await model.resume(sessionId: "parent-empty")

    #expect(
        await waitUntil { model.layoutSnapshot.panes.isEmpty },
        "nothing was open is a state: \(model.layoutSnapshot.panes.map(\.title))")
}

/// An organisation switch forgets no arrangement — the conversation-keyed ones included
/// (background agents 3 of 4). Each scope carries its organisation, so none is drawn under
/// another org's name, and the conversation and its canvas are still there to come back to.
///
/// **Driven through `invalidateForOrgChange()`, the one named contract**, and read back from
/// the window's own stores, with the conversation it was filed under.
@Test @MainActor func anOrganisationSwitchKeepsConversationArrangementsToo() async throws {
    let bin = windowRepoRoot().appendingPathComponent("bin/wakil-ctx")
    try #require(FileManager.default.isExecutableFile(atPath: bin.path), "run `make build` first")
    let home = try makeFixture(org: "acme", projectOrg: "acme", environments: ["dev"])
    let client = try await startedClient(bin: bin, home: home, org: "acme")
    let persistence = LayoutPersistence(directory: try windowScratchDirectory())

    try persistence.save(
        arrangement(id: "db-1", title: "the database conversation", x: 10),
        for: LayoutScope(organization: "acme", project: "widgets", environment: "", lineageRoot: "root-database"))

    let window = try await windowOnTheLanding(
        client: client, persistence: persistence, project: "widgets",
        lineageRoot: twoConversations)
    let model = window.model

    await model.resume(sessionId: "parent-db")
    try #require(await waitUntil { model.layoutSnapshot.panes.count == 1 })
    await setOneRow(window.panes, "the database conversation's rows")
    try #require(await window.panes.paneIds() == ["db-1"])
    let place = model.place
    let root = try #require(model.lineageRoot)

    await model.invalidateForOrgChange()

    #expect(await window.layout.snapshot().panes.map(\.title) == ["the database conversation"])
    #expect(await window.panes.paneIds() == ["db-1"], "and its rows")
    #expect(model.agents[place]?.lineageRoot == root, "and the conversation it was filed under")
    await client.stop()
}

// MARK: - Switching project inside a conversation swaps the canvas (#160)

/// The defect the operator found at the window on 2026-09-20, walking
/// `conversation-layouts-acceptance.md` step 10: switching to a project
/// with **no sessions at all** left the previous project's panes on
/// screen, because the project was not part of the scope's identity.
///
/// A window is in a conversation from its first turn or first pane
/// onward, so this was the ordinary case rather than an edge.
@Test @MainActor func switchingProjectInsideAConversationSwapsTheCanvas() async throws {
    let bin = windowRepoRoot().appendingPathComponent("bin/wakil-ctx")
    try #require(FileManager.default.isExecutableFile(atPath: bin.path), "run `make build` first")
    let home = try makeTwoProjectFixture(
        org: "acme", projects: [("widgets", ["dev"]), ("gadgets", ["dev"])])
    let client = try await startedClient(bin: bin, home: home, org: "acme")
    let persistence = LayoutPersistence(directory: try windowScratchDirectory())

    let inWidgets = arrangement(id: "db-1", title: "the widgets workspace", x: 10)
    let inGadgets = arrangement(id: "db-2", title: "the gadgets workspace", x: 30)
    try persistence.save(
        inWidgets,
        for: LayoutScope(organization: "acme", project: "widgets", environment: "", lineageRoot: "root-a"))
    try persistence.save(
        inGadgets,
        for: LayoutScope(organization: "acme", project: "gadgets", environment: "", lineageRoot: "root-a"))

    let model = try await windowModelForConversation(
        client: client, persistence: persistence, project: "widgets", conversation: "root-a")
    try #require(await waitUntil { model.layoutSnapshot == inWidgets })

    await model.setProject("gadgets")

    #expect(
        await waitUntil { model.layoutSnapshot == inGadgets },
        "the canvas must follow the project: \(model.layoutSnapshot.panes.map(\.title))")

    // And back, finding it as it was left — the same property a
    // conversation switch has.
    await model.setProject("widgets")
    #expect(
        await waitUntil { model.layoutSnapshot == inWidgets },
        "\(model.layoutSnapshot.panes.map(\.title))")
}

/// "Switching to a project with no arrangement at all gives an empty
/// canvas" — the operator's own case: `wakil-acceptance-2` had no
/// sessions and no arrangement, and showed the other project's panes.
@Test @MainActor func switchingToAProjectWithNoArrangementAtAllEmptiesTheCanvas() async throws {
    let bin = windowRepoRoot().appendingPathComponent("bin/wakil-ctx")
    try #require(FileManager.default.isExecutableFile(atPath: bin.path), "run `make build` first")
    let home = try makeTwoProjectFixture(
        org: "acme", projects: [("widgets", ["dev"]), ("gadgets", ["dev"])])
    let client = try await startedClient(bin: bin, home: home, org: "acme")
    let persistence = LayoutPersistence(directory: try windowScratchDirectory())

    try persistence.save(
        arrangement(id: "db-1", title: "the widgets workspace", x: 10),
        for: LayoutScope(organization: "acme", project: "widgets", environment: "", lineageRoot: "root-a"))

    let model = try await windowModelForConversation(
        client: client, persistence: persistence, project: "widgets", conversation: "root-a")
    try #require(await waitUntil { model.layoutSnapshot.panes.count == 1 })

    await model.setProject("gadgets")

    #expect(
        await waitUntil { model.layoutSnapshot.panes.isEmpty },
        "empty, not inherited: \(model.layoutSnapshot.panes.map(\.title))")
}

/// "A conversation's arrangement is never written into a different
/// project's seed."
///
/// Measured at the window before the fix: standing in `wakil-acceptance-2`
/// while working in `wakil-acceptance`'s conversation created
/// `personal/wakil-acceptance-2.json` holding the OTHER project's panes —
/// which is what every new conversation in that project would then open
/// on. It was empty at the time, so nothing was lost; with a seed of its
/// own it would have been.
@Test @MainActor func aConversationsPanesAreNeverWrittenIntoAnotherProjectsSeed() async throws {
    let bin = windowRepoRoot().appendingPathComponent("bin/wakil-ctx")
    try #require(FileManager.default.isExecutableFile(atPath: bin.path), "run `make build` first")
    let home = try makeTwoProjectFixture(
        org: "acme", projects: [("widgets", ["dev"]), ("gadgets", ["dev"])])
    let client = try await startedClient(bin: bin, home: home, org: "acme")
    let persistence = LayoutPersistence(directory: try windowScratchDirectory())

    let gadgetsSeed = arrangement(id: "db-9", title: "the gadgets seed", x: 90)
    try persistence.save(gadgetsSeed, for: LayoutScope(organization: "acme", project: "gadgets", environment: ""))

    let model = try await windowModelForConversation(
        client: client, persistence: persistence, project: "widgets", conversation: "root-a")
    await model.openPane(kind: "db")
    try #require(await waitUntil { model.layoutSnapshot.panes.count == 1 })

    #expect(
        persistence.load(for: LayoutScope(organization: "acme", project: "gadgets", environment: ""))
            .snapshot == gadgetsSeed,
        "the other project's seed must be untouched")
}


// MARK: - #264: a pane the agent opens is never drawn

/// #264: a pane the agent opens is on the canvas, focused and live — and the
/// window keeps drawing the Landing over it.
///
/// `WakilWindow` draws the Landing while `!model.sessionStarted`, which is
/// right: the axis is the session, not `panes.isEmpty`, so closing the last
/// pane returns to the room rather than here. `sessionStarted` is set by
/// `markSessionStarted()`, reached from `enterConversation()` and `resume()` —
/// every in-window entrance into work.
///
/// **An action dispatched over the MCP socket goes through none of them.** It
/// reaches `ActionRegistry.dispatch` and the handler directly, writes
/// `LayoutStore`, and returns. Measured against the shipped bundle on
/// 2026-09-23: `read_layout` answered with `terminal-1` focused and
/// `read_pane` with a live zsh, while the tree held the Landing's rows and no
/// rail at all. Clicking **Open terminal** then drew *both* panes at once.
///
/// It is Invariant 2 with the two paths landing in different places — both
/// reach the same `LayoutStore` and only one reaches the same window state —
/// and the visible consequence is that the agent can open a pane with a real
/// shell on a real pty that nothing on screen mentions.
///
/// Dispatched with `origin: .agent` straight through the registry, exactly as
/// `anAgentsDispatchReachesTheScreenWithoutTheOperatorClicking` does; never
/// `model.openPane`, which is the operator's route and already marks it.
@Test @MainActor func aPaneTheAgentOpensTakesTheWindowOutOfTheLanding() async throws {
    let (registry, panes, layout) = try makeRegistry()
    await registerLayoutActions(into: registry, layout: layout)
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup())

    #expect(!model.sessionStarted, "a fresh window is on the Landing")
    // The window hears the agent's dispatch through a pump it subscribes from a `Task`, so wait
    // until it is listening: under suite load the dispatch could otherwise be published first,
    // and the wake-up is never repeated (found in 2c-iv Task 3, when new MainActor tests shifted
    // the scheduling).
    #expect(await waitUntil { await registry.dispatchSubscriberCount > 0 })

    _ = try await registry.dispatch(
        name: "pane_open", params: .object(["kind": .string("db")]),
        origin: .agent, caller: .test("staging"), confirmation: nil)

    #expect(await waitUntil { !model.layoutSnapshot.panes.isEmpty },
            "the pane never reached the canvas at all")
    #expect(await waitUntil { model.sessionStarted },
            "the pane is on the canvas and the window still draws the Landing over it")
}

/// **And the pane it starts showing does not vanish.**
///
/// The obvious fix — call `markSessionStarted()` from the pump — is wrong, and
/// this is the test that says so. That mints `assignedSessionId` and
/// `lineageRoot`, and `lineageRoot` is part of `LayoutScope`: minting one
/// moves the scope out from under panes already filed under the old one, and
/// the next `activateLayout` hands back an empty arrangement for a scope
/// nothing has restored. `openPane` avoids it by entering the conversation
/// BEFORE it dispatches — its own doc comment says the pane "would simply
/// vanish" otherwise — and the agent's dispatch offers no such moment.
///
/// So the window stops drawing the Landing and files nothing differently. The
/// pane is under no conversation, which is what it already was; see #264 for
/// the half that is not fixed here.
@Test @MainActor func showingTheAgentsPaneDoesNotReFileTheArrangementUnderIt() async throws {
    let (registry, panes, layout) = try makeRegistry()
    await registerLayoutActions(into: registry, layout: layout)
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup())
    // As above: the window must be listening before the agent dispatches.
    #expect(await waitUntil { await registry.dispatchSubscriberCount > 0 })

    _ = try await registry.dispatch(
        name: "pane_open", params: .object(["kind": .string("db")]),
        origin: .agent, caller: .test("staging"), confirmation: nil)
    #expect(await waitUntil { model.sessionStarted })

    #expect(model.lineageRoot == nil,
            "showing the pane minted a conversation, which moves the scope it is filed under")
    #expect(!model.layoutSnapshot.panes.isEmpty,
            "the pane vanished from the canvas it had already been written to")
}

/// **And a dispatch that arranges nothing does not start one.** The Landing
/// means no work has begun in this window, and a dispatch that leaves the
/// canvas empty has begun none. Without this the flag would be set by the
/// agent merely reaching for a tool, and the window would leave the Landing
/// for a room with nothing in it.
@Test @MainActor func anAgentDispatchThatOpensNoPaneLeavesTheWindowOnTheLanding() async throws {
    let (registry, panes, layout) = try makeRegistry()
    await registerLayoutActions(into: registry, layout: layout)
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup())

    // A dispatch that runs, publishes, wakes the pump, and leaves the canvas
    // empty: closing a pane that is not there.
    _ = try? await registry.dispatch(
        name: "pane_close", params: .object(["pane": .string("db-404")]),
        origin: .agent, caller: .test("staging"), confirmation: nil)

    // Given the same room the assertions above are given, so this reads as
    // "it did not happen" rather than "it had not happened yet".
    _ = await waitUntil { model.sessionStarted }
    #expect(!model.sessionStarted,
            "an agent that arranged nothing took the window out of the Landing")
    #expect(model.assignedSessionId == nil, "and minted a conversation for it")
}

// MARK: - The grip's gutter

/// The columns are laid out between the grip's gutter and the hover actions' gutter, never
/// under either (spec Amendment 5; the ⓘ, 2c-ii-c walk): both gutters plus the width the
/// columns divide is the row, exactly.
@Test func theColumnsAreLaidOutBetweenTheGutters() {
    #expect(paneGripGutter == 14)
    #expect(paneRowActionGutter == 36)
    #expect(paneColumnsWidth(rowWidth: 600) + paneGripGutter + paneRowActionGutter == 600)
    let widths = paneColumnLayout(
        columns: ["id", "booking_id", "status"], overrides: [:],
        availableWidth: paneColumnsWidth(rowWidth: 600), horizontalSpacing: 16)
    #expect(widths.reduce(0, +) + 16 * 2 + paneGripGutter + paneRowActionGutter == 600)
}

/// A pane too narrow for the gutter and a column still lays one out, floored as
/// `paneContentWidth` floors.
@Test func aNarrowRowStillLaysOutAColumn() {
    #expect(paneColumnsWidth(rowWidth: 10) == paneColumnMinimumWidth)
}

/// Dim at rest, brighter under the pointer, and never zero: a grip drawn only on hover is
/// missing from the accessibility tree for every other row.
@Test func theGripIsDimAtRestAndRisesUnderThePointer() {
    #expect(paneGripOpacity(hovered: false) == 0.30)
    #expect(paneGripOpacity(hovered: true) == 0.55)
}

/// Task 4: the pane keeps a box queued while the dispatch carrying its write is on the chain, and
/// clears it when THAT dispatch completes, whatever its outcome. So an enqueue answers the task
/// that ends when its own calls have run, landed or refused, and not before.
@Test @MainActor func anEnqueueAnswersTheTaskThatEndsWhenItsCallsHaveRun() async throws {
    let (registry, panes, layout) = try makeRegistry()
    let log = OrderLog()
    await registry.register(Action(
        name: "test_slow", description: "", kind: .read, schema: .object([:]),
        handler: { _ in
            try await Task.sleep(nanoseconds: 50_000_000)
            await log.append("slow returned")
            return .object([:])
        }))
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup())

    // A batch that builds no calls has nothing to refuse.
    #expect(await model.enqueueFromSurface(pane: "api-1", building: { _ in [] }).value == true)
    let landed = model.enqueueFromSurface(pane: "api-1", building: { _ in
        [("test_slow", .object([:]))]
    })
    #expect(await landed.value == true)
    #expect(await log.entries == ["slow returned"])
    // A refused call (no such action) still completes its task, answering that it did not land.
    let refused = model.enqueueFromSurface(pane: "api-1", building: { _ in
        [("test_no_such_action", .object([:]))]
    })
    #expect(await refused.value == false)
}

// MARK: - A cancelled read is silent (2c-iv Task 6, fix round 1)

private struct SilentCancelLookup: ProviderCredentialsLookup {
    func credentials(forProvider id: String) async throws -> ProviderCredentials {
        ProviderCredentials(claudePath: "/usr/bin/true", configDir: "/dev/null", oauthToken: "test-only")
    }
}

/// A window whose `ctx_list_projects`, `session_list` and `ctx_list_providers` wait until their
/// caller is cancelled, then throw `CancellationError` — what an MCP-backed action does now that
/// `MCPClient` honours cancellation (W14).
@MainActor
private func stallingReadsWindow() async throws -> WindowModel {
    let dir = testScratchRoot.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let registry = ActionRegistry(journalDirectory: dir, sessionId: "t")
    for name in ["ctx_list_projects", "session_list", "ctx_list_providers"] {
        await registry.register(Action(
            name: name, description: "stalls", kind: .read, audience: .agentReachable,
            schema: .object(["type": .string("object")]),
            handler: { _ in
                try await Task.sleep(nanoseconds: 30_000_000_000)
                return .object([:])
            }))
    }
    return WindowModel(
        registry: registry, panes: PaneStore(), layout: LayoutStore(), context: nil,
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: NSTemporaryDirectory(), providerId: "main", lookup: SilentCancelLookup())
}

/// The audit's finding: SwiftUI cancels a `.task(id:)` when its id changes — `ContextLine` and
/// `Landing` on every project switch, `OrgPlane` on every phase, a palette sheet dismissed while
/// it loads. Their reads now throw `CancellationError` mid-call, and the window must not report
/// a routine cancel as a failure on the status line.
@Test(.timeLimit(.minutes(1)))
@MainActor
func aCancelledReadSaysNothingOnTheStatusLine() async throws {
    let model = try await stallingReadsWindow()
    let listing = Task { @MainActor in await model.listProjects() }
    try await Task.sleep(nanoseconds: 100_000_000)
    listing.cancel()
    #expect(await listing.value.isEmpty)
    #expect(model.status == "")

    let palette = Task { @MainActor in await model.landingSessions() }
    try await Task.sleep(nanoseconds: 100_000_000)
    palette.cancel()
    _ = await palette.value
    #expect(model.status == "")
    await model.shutdown()
}

// MARK: - Environments and the api pane (9b W12, W1)

/// A `wakil-ctx` and a `wakil-http` in one: the active environment moves on `set_environment`,
/// and `list_apis` answers that environment's entries. `catalog` is declared by both.
private actor EnvironmentBackend: ToolCaller {
    private(set) var environment: String
    private(set) var listings = 0
    private let apis: [String: [(String, String)]]

    /// `nil` answers no project, so the window files no arrangement; a name gives it one.
    private let project: String?

    /// `twoInStaging`: staging also declares `billing`, so a pane rebuilt from an empty draft
    /// stays unpointed — the walked "no entry · pick an entry — staging declares 2".
    init(environment: String, project: String? = nil, twoInStaging: Bool = false) {
        self.environment = environment
        self.project = project
        var staging = [("catalog", "https://catalog-staging.example")]
        if twoInStaging { staging.append(("billing", "https://billing-staging.example")) }
        apis = [
            "staging": staging,
            "qa": [("catalog", "https://catalog-qa.example")],
            "production": [("catalog", "https://catalog.example")],
        ]
    }

    func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        switch name {
        case "get_context":
            var fields: [String: JSONValue] = [
                "Org": .string("acme"), "Environment": .string(environment), "RootPaths": .array([]),
            ]
            if let project { fields["Project"] = .object(["name": .string(project)]) }
            return .object(["structuredContent": .object(fields)])
        case "set_environment":
            if case .object(let a) = arguments, case .string(let n)? = a["name"] { environment = n }
            return .object(["structuredContent": .object([:])])
        case "list_apis":
            listings += 1
            return .object(["structuredContent": .object(["apis": .array((apis[environment] ?? []).map {
                .object(["name": .string($0.0), "baseUrl": .string($0.1), "authenticated": .bool(true)])
            })])])
        default:
            return .object(["structuredContent": .object([:])])
        }
    }
}

@MainActor
private func environmentWindow(
    _ backend: EnvironmentBackend, persistence: LayoutPersistence? = nil,
    harnessFactory: @escaping @Sendable (Place, ProviderSelection) -> AgentHarness? = { _, _ in nil }
) async throws -> (WindowModel, ActionRegistry, PaneStore, LayoutStore) {
    let (registry, panes, layout) = try makeRegistry()
    await registerStandardActions(into: registry, context: backend, panes: panes, db: nil, resumes: ResumeBroker())
    let resolver = await registerApiActions(
        into: registry, panes: panes, layout: layout, http: backend,
        activeContext: { ("acme", "", await backend.environment, "/tmp") })
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, persistence: persistence,
        context: ContextStore(client: backend),
        harnessFactory: { place, selection, _ in harnessFactory(place, selection) },
        resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main",
        lookupFactory: { _ in AlwaysSucceedsCredentialsLookup() },
        apiResolver: resolver, environment: await backend.environment)
    await model.refreshContext()
    await panes.openApi(
        paneId: "api-1", entry: "catalog", environment: "staging",
        origin: "https://catalog-staging.example", credentialed: true, entries: ["catalog"])
    return (model, registry, panes, layout)
}

/// **The operator's walk** (W1): staging → production → staging left "no origin" on an entry
/// both environments declare, because a switch cleared the origin and nothing re-resolved it.
/// **Plan 3:** the pane no longer travels. Production shows its own canvas, and staging's pane
/// is found on return exactly as it was left — entry, origin and reply — because nothing touched
/// it while the operator was elsewhere. A reply never crosses environments.
@Test @MainActor func aRoundTripThroughEnvironmentsFindsTheApiPaneAsItWasLeft() async throws {
    let backend = EnvironmentBackend(environment: "staging", project: "api")
    let (model, _, panes, _) = try await environmentWindow(backend)
    let reply = ApiResponseSnapshot.refusal(ApiSendRefusal(failures: [
        ApiSendFailure(region: nil, message: "staging's reply"),
    ]))
    await panes.setApiResponse(paneId: "api-1", response: reply)

    await model.setEnvironment("production")
    #expect(model.environment == "production")
    #expect(await panes.apiSnapshot(paneId: "api-1").response != reply, "staging's reply crossed")

    await model.setEnvironment("staging")
    let back = await panes.apiSnapshot(paneId: "api-1")
    #expect(back.request.origin == "https://catalog-staging.example")
    #expect(back.credentialed && back.environment == "staging")
    #expect(back.response == reply)
}

/// W8: a re-resolve that points a pane at an entry retitles it, **and the window draws the new
/// title** — the switch re-reads the arrangement after the resolver wrote it. **Plan 3:** what a
/// switch re-resolves is the incoming environment's own canvas read off disk, not the pane left
/// behind; one saved unpointed, in an environment declaring one entry, is pointed and retitled.
@Test @MainActor func aSwitchBringingInAnUnpointedPaneRetitlesItOnScreen() async throws {
    let backend = EnvironmentBackend(environment: "staging", project: "api")
    let persistence = LayoutPersistence(directory: try windowScratchDirectory())
    try persistence.save(
        LayoutSnapshot(
            panes: [Pane(id: "api-5", kind: "api", title: "api",
                         frame: PaneFrame(x: 0, y: 0, width: 640, height: 420))],
            focusedId: "api-5"),
        for: LayoutScope(organization: "acme", project: "api", environment: "qa"))
    let (model, _, _, _) = try await environmentWindow(backend, persistence: persistence)

    await model.setEnvironment("qa")
    #expect(await waitUntil {
        model.layoutSnapshot.panes.first { $0.id == "api-5" }?.title == "catalog"
    })
}

/// W8 at launch: a pane restored from the layout is resolved from an empty draft, and the one
/// entry the environment declares points it — the window draws that title without waiting for
/// some later dispatch to re-read the arrangement.
@Test @MainActor func aRestoredPaneResolvedAtLaunchIsRetitledOnScreen() async throws {
    let backend = EnvironmentBackend(environment: "staging")
    let (model, _, _, layout) = try await environmentWindow(backend)
    // `api-1` is the fixture's own pane, already pointed; the second is restored with no draft.
    _ = await layout.open(kind: "api", title: "catalog")
    let id = await layout.open(kind: "api", title: "api").id
    await model.refreshLayout()

    await model.restorePaneContents()
    #expect(model.layoutSnapshot.panes.first { $0.id == id }?.title == "catalog")
}

/// W12: the operator choosing the environment already active dispatches nothing, so nothing
/// is cleared and nothing is re-read.
@Test @MainActor func choosingTheActiveEnvironmentChangesNothing() async throws {
    let backend = EnvironmentBackend(environment: "staging")
    let (model, registry, panes, _) = try await environmentWindow(backend)
    let refusal = ApiResponseSnapshot.refusal(ApiSendRefusal(failures: [
        ApiSendFailure(region: nil, message: "kept"),
    ]))
    await panes.setApiResponse(paneId: "api-1", response: refusal)
    let listings = await backend.listings

    await model.setEnvironment(" staging ")

    #expect(try await registry.journalEntries().filter { $0.action == "ctx_set_environment" }.isEmpty)
    #expect(await panes.apiSnapshot(paneId: "api-1").response == refusal)
    #expect(await backend.listings == listings)
}

/// The agent's switch does what the operator's does (W1). **Plan 3:** that is now showing the
/// incoming environment's canvas — staging's api pane is not re-resolved against qa, and is found
/// pointed at staging when the operator returns.
@Test @MainActor func anAgentsEnvironmentSwitchLeavesTheApiPaneInItsOwnEnvironment() async throws {
    let backend = EnvironmentBackend(environment: "staging", project: "api")
    let (model, registry, panes, _) = try await environmentWindow(backend)

    // `.debug`, the socket's other caller: `ctx_set_environment` is operator-only, and `dispatch` refuses it from the agent.
    _ = try await registry.dispatch(
        name: "ctx_set_environment", params: .object(["name": .string("qa")]),
        origin: .debug, caller: DispatchCaller(place: model.place, session: nil), confirmation: nil)

    #expect(await waitUntil { model.environment == "qa" })
    #expect(await panes.apiSnapshot(paneId: "api-1").request.origin != "https://catalog-qa.example")
    await model.setEnvironment("staging")
    let back = await panes.apiSnapshot(paneId: "api-1")
    #expect(back.environment == "staging")
    #expect(back.request.origin == "https://catalog-staging.example")
}

/// W1 at launch: an api pane restored from the layout holds nothing in the store — its draft is
/// not persisted — and is resolved against the environment it opens in, like any other.
@Test @MainActor func anApiPaneRestoredAtLaunchIsResolved() async throws {
    let backend = EnvironmentBackend(environment: "staging")
    let (model, _, panes, layout) = try await environmentWindow(backend)
    await layout.load(LayoutSnapshot(
        panes: [Pane(id: "api-9", kind: "api", title: "catalog",
                     frame: PaneFrame(x: 0, y: 0, width: 640, height: 420))],
        // The screen's canvas: an organisation with no project shows its own (final review).
        focusedId: "api-9"), for: LayoutScope(organization: model.organization, project: "", environment: ""))
    await model.refreshLayout()

    await model.restorePaneContents()

    let restored = await panes.apiSnapshot(paneId: "api-9")
    #expect(restored.entry == "catalog")
    #expect(restored.request.origin == "https://catalog-staging.example")
    #expect(restored.entries == ["catalog"])
    #expect(restored.environment == "staging")
}

// MARK: - Fix round 1 (Task 7)

/// Fix 6: a switch to an environment that does not declare the pane's entry keeps the name,
/// offers the new environment's entries, and says so on the URL line. **Plan 3:** a pane no longer
/// crosses into an environment, so it can no longer land in one that lacks its entry; the URL
/// line's wording for that state stays covered at the store (`ApiEnvironmentTests`, W1). What the
/// operator sees now: the pane stays pointed in its own environment, and qa does not show it.
@Test @MainActor func aPaneOnAnEntryAnotherEnvironmentLacksStaysPointedInItsOwn() async throws {
    let backend = EnvironmentBackend(environment: "staging", project: "api")
    let (model, _, panes, _) = try await environmentWindow(backend)
    await panes.openApi(
        paneId: "api-2", entry: "billing", environment: "staging",
        origin: "https://billing-staging.example", credentialed: true, entries: ["catalog", "billing"])

    await model.setEnvironment("qa")
    #expect(await panes.apiSnapshot(paneId: "api-2").entry != "billing", "staging's pane crossed into qa")

    await model.setEnvironment("staging")
    let pane = await panes.apiSnapshot(paneId: "api-2")
    #expect(pane.entry == "billing" && pane.environment == "staging")
    #expect(apiOriginLine(pane) == .origin("https://billing-staging.example"))
}

/// Fix 5: the operator's own switch is handled once. `observationPump` sees the window's own
/// dispatch too, and used to clear every api reply a second time, late — wiping a reply that
/// arrived under the new environment. **Plan 3:** neither the switch nor the pump clears a reply
/// any more — each environment keeps its own canvas — so the check is that staging's reply
/// survives every round trip and its pump wake-up, and that nothing is re-resolved in place.
@Test @MainActor func theOperatorsSwitchIsHandledOnce() async throws {
    let backend = EnvironmentBackend(environment: "staging", project: "api")
    let (model, _, panes, _) = try await environmentWindow(backend)
    let reply = ApiResponseSnapshot.refusal(ApiSendRefusal(failures: [
        ApiSendFailure(region: nil, message: "arrived in staging"),
    ]))
    await panes.setApiResponse(paneId: "api-1", response: reply)
    let listings = await backend.listings
    for target in ["production", "staging", "qa", "staging", "production", "qa", "staging"] {
        await model.setEnvironment(target)
        // Let the pump drain its wake-up for this dispatch.
        try await Task.sleep(nanoseconds: 60_000_000)
        #expect(model.environment == target, "switch to \(target)")
        if target == "staging" {
            #expect(await panes.apiSnapshot(paneId: "api-1").response == reply, "switch to \(target)")
        }
    }
    #expect(await backend.listings == listings, "a switch re-resolved a pane in place")
}

// MARK: - Send's plan is built at its turn (Task 9 fix round 4)

/// What a pane holds that the chain's builder reads when its turn comes: the held fields and
/// the gestures' holds on them, as `ApiPane`'s `@State` does.
@MainActor private final class PaneHeld {
    var held: ApiHeld
    var takenOver: [ApiFieldRow: ApiHeldTakeover]
    init(held: ApiHeld, takenOver: [ApiFieldRow: ApiHeldTakeover]) {
        self.held = held
        self.takenOver = takenOver
    }
}

/// Each `api_send` as it executed: the statement it was handed, and the statement the STORED
/// draft at that moment reads as — what actually leaves.
private actor SendLog {
    var sends: [(statement: String?, stored: String?, path: [ApiPart])] = []
    func append(_ statement: String?, _ stored: String?, _ path: [ApiPart]) {
        sends.append((statement, stored, path))
    }
}

private func statement(_ params: JSONValue) -> String? {
    guard case .object(let fields) = params, case .string(let text)? = fields["statement"] else {
        return nil
    }
    return text
}

/// An api pane over the real `api_open` and `api_set_request`, with `api_send` replaced by a
/// recorder that reads the stored draft when it executes. A POST, so Send is `api_send`.
@MainActor private func sendWindow() async throws -> (WindowModel, ActionRegistry, String, SendLog) {
    let (registry, panes, layout) = try makeRegistry()
    await registerApiActions(
        into: registry, panes: panes, layout: layout, http: nil,
        activeContext: { ("initech", "proj", "staging", "/tmp") })
    let opened = try await registry.dispatch(
        name: "api_open", params: .object([:]), origin: .agent, caller: .test("staging"),
        confirmation: nil)
    guard case .object(let fields) = opened, case .string(let pane)? = fields["pane"] else {
        throw SilentTestError()
    }
    _ = try await registry.dispatch(
        name: "api_set_request",
        params: .object(["pane": .string(pane), "method": .string("POST")]),
        origin: .agent, caller: .test("staging"), confirmation: nil)
    let log = SendLog()
    await registry.register(Action(
        name: "api_send", description: "", kind: .read, schema: .object([:]),
        handler: { params in
            let stored = await panes.apiSnapshot(paneId: pane).request
            await log.append(
                statement(params),
                statement(apiSendParams(draft: stored, pane: pane, origin: stored.origin)),
                stored.path)
            return .object([:])
        }))
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup())
    await model.refreshPanes()
    return (model, registry, pane, log)
}

/// The operator typed `/orders/7` into the path, pressed a gesture that rewrites the path
/// (here `/orders/<id>`), and pressed Send before it landed. **The statement Send dispatches
/// names the post-gesture request**: the request that leaves.
@Test(.timeLimit(.minutes(1))) @MainActor func sendsPlanIsBuiltAfterTheGestureAheadOfItLands() async throws {
    let (model, _, pane, log) = try await sendWindow()
    let path = ApiFieldRow(.path)
    let carried = ApiHeldTakeover(held: [.literal("/orders/7")], token: 1)
    let held = PaneHeld(held: [path: [.literal("/orders/7")]], takenOver: [path: carried])

    // The gesture: its write carries the field, taken over.
    model.enqueueFromSurface(pane: pane, building: { _ in
        [("api_set_request", .object([
            "pane": .string(pane),
            "path": .array([.object(["literal": .string("/orders/")]), .object(["slot": .string("id")])]),
        ]))]
    }, settled: { landed in
        let settled = apiGestureSettled(
            takenOver: held.takenOver, held: held.held, carried: [path: carried], landed: landed)
        held.takenOver = settled.takenOver
        held.held = settled.held
    })
    // Send, pressed while the gesture is still queued.
    model.enqueueFromSurface(pane: pane, building: { now in
        apiSendPlan(draft: now.request, pane: pane, held: held.held, takenOver: held.takenOver).calls
    })
    await model.surfaceChainSettled()
    try #require(await apiEventually { await log.sends.count == 1 })

    let sent = try #require(await log.sends.first)
    #expect(sent.statement == sent.stored, "\(sent.statement ?? "nil") vs \(sent.stored ?? "nil")")
    #expect(sent.statement?.contains("/orders/<id>") == true, "\(sent.statement ?? "nil")")
    #expect(held.held.isEmpty)
}

/// The same, with the gesture refused: it wrote nothing, the field still owes its write, and
/// Send's flush makes it. **The statement names what the draft holds when the send leaves.**
@Test(.timeLimit(.minutes(1))) @MainActor func sendsPlanAfterARefusedGestureNamesWhatTheDraftHolds() async throws {
    let (model, registry, pane, log) = try await sendWindow()
    await registry.register(Action(
        name: "test_refused", description: "", kind: .read, schema: .object([:]),
        handler: { _ in throw SilentTestError() }))
    let path = ApiFieldRow(.path)
    let carried = ApiHeldTakeover(held: [.literal("/orders/7")], token: 1)
    let held = PaneHeld(held: [path: [.literal("/orders/7")]], takenOver: [path: carried])

    model.enqueueFromSurface(pane: pane, building: { _ in
        [("test_refused", .object([:]))]
    }, settled: { landed in
        let settled = apiGestureSettled(
            takenOver: held.takenOver, held: held.held, carried: [path: carried], landed: landed)
        held.takenOver = settled.takenOver
        held.held = settled.held
    })
    model.enqueueFromSurface(pane: pane, building: { now in
        apiSendPlan(draft: now.request, pane: pane, held: held.held, takenOver: held.takenOver).calls
    })
    await model.surfaceChainSettled()
    try #require(await apiEventually { await log.sends.count == 1 })

    let sent = try #require(await log.sends.first)
    #expect(sent.statement == sent.stored, "\(sent.statement ?? "nil") vs \(sent.stored ?? "nil")")
    #expect(sent.path == [.literal("/orders/7")])
    #expect(held.takenOver.isEmpty)
    #expect(held.held == [path: [.literal("/orders/7")]])
}

/// The lazy door answers whether its batch landed, and builds nothing until its turn.
@Test @MainActor func aBatchBuiltAtItsTurnSaysWhetherItLanded() async throws {
    let (registry, panes, layout) = try makeRegistry()
    let log = OrderLog()
    await registry.register(Action(
        name: "test_refused", description: "", kind: .read, schema: .object([:]),
        handler: { _ in throw SilentTestError() }))
    await registry.register(Action(
        name: "test_landed", description: "", kind: .read, schema: .object([:]),
        handler: { _ in
            try await Task.sleep(nanoseconds: 30_000_000)
            await log.append("landed")
            return .object([:])
        }))
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup())

    let refused = model.enqueueFromSurface(pane: "api-1", building: { _ in
        [("test_landed", .object([:])), ("test_refused", .object([:]))]
    })
    var builtAfter: [String]?
    let landed = model.enqueueFromSurface(pane: "api-1", building: { _ in
        builtAfter = []
        return [("test_landed", .object([:]))]
    })
    #expect(builtAfter == nil)
    #expect(await refused.value == false)
    #expect(await landed.value == true)
    #expect(builtAfter == [])
    #expect(await log.entries == ["landed", "landed"])
}

// MARK: - The re-walk's data loss (2026-10-04, finding #4)

/// The draft the operator built before asking the agent anything.
private let walkedDraft: JSONValue = .object([
    "pane": .string("api-1"),
    "path": .array([.object(["literal": .string("/events")])]),
    "query": .array([.object(["name": .string("page"), "value": .array([.object(["literal": .string("2")])])])]),
    "headers": .array([.object(["name": .string("X-Auth-Id"), "value": .array([.object(["literal": .string("7")])])])]),
])

/// A window launched onto a project seed holding one api pane, `api-1` — a launch's canvas.
@MainActor
private func seededApiWindow(
    _ backend: EnvironmentBackend,
    harnessFactory: @escaping @Sendable (Place, ProviderSelection) -> AgentHarness? = { _, _ in nil }
) async throws -> (WindowModel, ActionRegistry, PaneStore, LayoutStore) {
    let persistence = LayoutPersistence(directory: try windowScratchDirectory())
    // The project seed a previous session left: the api pane's frame and title, never its draft.
    try persistence.save(
        LayoutSnapshot(
            panes: [Pane(id: "api-1", kind: "api", title: "catalog",
                         frame: PaneFrame(x: 0, y: 0, width: 640, height: 420))],
            focusedId: "api-1"),
        for: LayoutScope(organization: "acme", project: "widgets", environment: await backend.environment))
    return try await environmentWindow(
        backend, persistence: persistence, harnessFactory: harnessFactory)
}

/// W12 from the agent's side: the agent switching to the environment already active changes
/// nothing on screen — no clear, no re-resolve, no rebuild. The draft and the entry stay.
@Test @MainActor func anAgentsSwitchToTheActiveEnvironmentKeepsTheApiPane() async throws {
    let backend = EnvironmentBackend(environment: "staging", project: "widgets")
    let (model, registry, panes, _) = try await seededApiWindow(backend)
    #expect(await waitUntil { await registry.dispatchSubscriberCount > 0 })
    _ = try await registry.dispatch(
        name: "api_set_request", params: walkedDraft, origin: .ui, caller: .test("staging"),
        confirmation: nil)
    let before = await panes.apiSnapshot(paneId: "api-1")
    let listings = await backend.listings

    // `.debug`, the socket's other caller: `ctx_set_environment` is operator-only, and `dispatch` refuses it from the agent.
    _ = try await registry.dispatch(
        name: "ctx_set_environment", params: .object(["name": .string("staging")]),
        origin: .debug, caller: DispatchCaller(place: model.place, session: nil), confirmation: nil)
    // The pump runs after the dispatch: give it the room every agent-path test here gives it.
    _ = await waitUntil { await backend.listings != listings }

    let after = await panes.apiSnapshot(paneId: "api-1")
    #expect(after.entry == "catalog")
    #expect(after.request == before.request)
    #expect(await backend.listings == listings, "a no-op switch re-resolved the panes")
}

/// **The re-walk's data loss, root cause.** The canvas a launch restores is filed under no
/// conversation (`lineageRoot == nil`) — the window leaves the Landing for it without minting one
/// (#264). The operator's FIRST turn ("switch to staging") minted the conversation in
/// `enterConversation`, which moved the scope; `activateLayout` then re-read the project seed
/// off disk into the new scope, and `restorePaneContents` rebuilt every api pane from an empty
/// draft, because drafts are not persisted. The draft and the entry were gone before the agent
/// dispatched anything. A conversation minted over a canvas already on screen adopts it.
@Test @MainActor func aFirstTurnOverARestoredCanvasKeepsTheApiPanesDraft() async throws {
    let backend = EnvironmentBackend(environment: "staging", project: "widgets", twoInStaging: true)
    let (model, registry, panes, _) = try await seededApiWindow(backend)
    #expect(model.lineageRoot == nil, "a launch files its canvas under no conversation")
    _ = try await registry.dispatch(
        name: "api_set_request", params: walkedDraft, origin: .ui, caller: .test("staging"),
        confirmation: nil)
    let before = await panes.apiSnapshot(paneId: "api-1")
    #expect(before.entry == "catalog")

    await model.send("switch to staging")

    #expect(model.lineageRoot != nil, "the first turn puts the window in a conversation")
    let after = await panes.apiSnapshot(paneId: "api-1")
    #expect(after.entry == "catalog")
    #expect(after.request == before.request, "the first turn wiped the draft")
    #expect(model.layoutSnapshot.panes.map(\.id) == ["api-1"])
}

/// Review I3: the same loss through an account switch. `setProvider` moves a window that is in no
/// conversation into a fresh one, so it too adopts the canvas rather than re-reading the seed.
@Test @MainActor func anAccountSwitchOverARestoredCanvasKeepsTheApiPanesDraft() async throws {
    let backend = EnvironmentBackend(environment: "staging", project: "widgets", twoInStaging: true)
    let (model, registry, panes, _) = try await seededApiWindow(
        backend, harnessFactory: { _, _ in StubHarness() })
    #expect(model.lineageRoot == nil)
    _ = try await registry.dispatch(
        name: "api_set_request", params: walkedDraft, origin: .ui, caller: .test("staging"),
        confirmation: nil)
    let before = await panes.apiSnapshot(paneId: "api-1")

    await model.setProvider("work")

    #expect(model.lineageRoot != nil, "the switch puts the window in a fresh conversation")
    let after = await panes.apiSnapshot(paneId: "api-1")
    #expect(after.entry == "catalog", "the account switch unpointed the pane")
    #expect(after.request == before.request, "the account switch wiped the draft")
}

// MARK: - Capacity is recorded against the pump's provider

@MainActor
private final class CapacityRecorder {
    var providers: [String] = []
    func dispatch(_ name: String, _ params: JSONValue) async throws -> JSONValue {
        if name == "capacity_record", case .object(let p) = params, case .string(let id)? = p["provider"] {
            providers.append(id)
        }
        return .object([:])
    }
}

/// Review Focus 4: a live pump started under "main" keeps recording against
/// "main" after `providerId` changes without the pump being replaced
/// (`refreshContext` rewrites it from `get_context`). Reading `providerId`
/// at event time would record against "work" and fail here.
@Test @MainActor func aLivePumpRecordsCapacityAgainstTheProviderItStartedUnder() async throws {
    let (registry, panes, layout) = try makeRegistry()
    let harnesses = HarnessBox()
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in harnesses.next() }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup(), environment: "staging")
    let recorder = CapacityRecorder()
    model.capacity.attach(dispatch: recorder.dispatch)

    await model.send("first")                      // starts the pump under "main"
    model.seedForTesting(providerId: "work", rootPath: "/Users/x/proj", thoughts: 0)
    #expect(model.providerId == "work")

    let windows = CapacityWindows(
        fiveHour: CapacityWindow(percentLeft: 28, resetsAt: Date(timeIntervalSince1970: 1_800_000_000)),
        sevenDay: nil)
    harnesses.issued[0].continuation.yield(.rateLimit(windows))
    #expect(await waitUntil { !recorder.providers.isEmpty })
    #expect(recorder.providers == ["main"])
}

/// Final review finding 1: capacity is read when the context is, so launch and an org
/// switch fill the hairlines without waiting for a turn or Settings.
@Test @MainActor func refreshContextReadsCapacity() async throws {
    let bin = windowRepoRoot().appendingPathComponent("bin/wakil-ctx")
    try #require(FileManager.default.isExecutableFile(atPath: bin.path), "run `make build` first")
    let home = try makeTwoProjectFixture(org: "acme", projects: [("widgets", ["dev"])])
    let client = try await startedClient(bin: bin, home: home, org: "acme")
    let dir = try windowScratchDirectory()
    let registry = ActionRegistry(journalDirectory: dir, sessionId: "capacity-launch")
    let model = WindowModel(
        registry: registry, panes: PaneStore(), layout: LayoutStore(),
        persistence: LayoutPersistence(directory: dir),
        context: ContextStore(client: client),
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup())
    let listing: JSONValue = .object(["structuredContent": .object(["readings": .array([
        .object(["account": .string("main"), "kind": .string("claude-code"), "state": .string("notRead")])])])])
    model.capacity.attach { _, _ in listing }
    _ = try await client.callTool(name: "set_project", arguments: .object(["name": .string("widgets")]), timeout: 10)
    #expect(model.capacity.readings.isEmpty)
    await model.refreshContext()
    await client.stop()
    #expect(!model.capacity.readings.isEmpty, "\(model.status) \(model.capacity.failure ?? "")")
}

// MARK: - Capacity is probed at launch, on a switch and when a turn ends

@MainActor
private final class CapacityProbeRecorder {
    var refreshFlags: [Bool] = []
    func dispatch(_ name: String, _ params: JSONValue) async throws -> JSONValue {
        if name == "ctx_capacity" {
            if case .object(let p) = params, case .bool(true)? = p["refresh"] {
                refreshFlags.append(true)
            } else {
                refreshFlags.append(false)
            }
        }
        return .object([:])
    }
}

@Test @MainActor func turnEndRefreshesWithProbe() async throws {
    let (registry, panes, layout) = try makeRegistry()
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup(), environment: "staging")
    let recorder = CapacityProbeRecorder()
    model.capacity.attach(dispatch: recorder.dispatch)
    await model.receiveForTesting(.result(isError: false, text: "ok"))
    #expect(recorder.refreshFlags.contains(true), "a turn's end must ask for a probe: \(recorder.refreshFlags)")
}

@MainActor private func probeModel(_ id: String, recorder: CapacityProbeRecorder) async throws -> (WindowModel, MCPClient) {
    let bin = windowRepoRoot().appendingPathComponent("bin/wakil-ctx")
    try #require(FileManager.default.isExecutableFile(atPath: bin.path), "run `make build` first")
    let home = try makeTwoProjectFixture(org: "acme", projects: [("widgets", ["dev"]), ("gadgets", ["dev"])])
    let client = try await startedClient(bin: bin, home: home, org: "acme")
    let dir = try windowScratchDirectory()
    let model = WindowModel(
        registry: ActionRegistry(journalDirectory: dir, sessionId: id), panes: PaneStore(), layout: LayoutStore(),
        persistence: LayoutPersistence(directory: dir),
        context: ContextStore(client: client),
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup())
    model.capacity.attach(dispatch: recorder.dispatch)
    _ = try await client.callTool(name: "set_project", arguments: .object(["name": .string("widgets")]), timeout: 10)
    return (model, client)
}

@Test @MainActor func refreshContextForLaunchRefreshesWithProbe() async throws {
    let recorder = CapacityProbeRecorder()
    let (model, client) = try await probeModel("capacity-probe-launch", recorder: recorder)
    await model.refreshContext(probe: true)
    await model.settleCapacityForTesting()
    await client.stop()
    #expect(recorder.refreshFlags.contains(true), "\(model.status) \(recorder.refreshFlags)")
}

@Test @MainActor func orgSwitchRefreshesWithProbe() async throws {
    let recorder = CapacityProbeRecorder()
    let (model, client) = try await probeModel("capacity-probe-org", recorder: recorder)
    await model.setOrganization("acme")
    await model.settleCapacityForTesting()
    await client.stop()
    #expect(recorder.refreshFlags.contains(true), "\(model.status) \(recorder.refreshFlags)")
}

@Test @MainActor func projectSwitchReadsCapacityWithoutProbe() async throws {
    let recorder = CapacityProbeRecorder()
    let (model, client) = try await probeModel("capacity-probe-project", recorder: recorder)
    // What the observation pump does after an agent-issued ctx_set_project.
    _ = try await client.callTool(name: "set_project", arguments: .object(["name": .string("gadgets")]), timeout: 10)
    await model.refreshContext()
    await model.settleCapacityForTesting()
    await client.stop()
    #expect(!recorder.refreshFlags.isEmpty, "a context refresh still reads the stored numbers: \(model.status)")
    #expect(!recorder.refreshFlags.contains(true), "a context refresh without probe must not probe: \(recorder.refreshFlags)")
}

@Test @MainActor func setProviderRefreshesWithProbe() async throws {
    let (registry, panes, layout) = try makeRegistry()
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in StubHarness() }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup(), environment: "staging")
    let recorder = CapacityProbeRecorder()
    model.capacity.attach(dispatch: recorder.dispatch)
    await model.setProvider("work")
    await model.settleCapacityForTesting()
    #expect(model.providerId == "work", Comment(rawValue: model.status))
    #expect(recorder.refreshFlags.contains(true), "a provider switch must ask for a probe: \(recorder.refreshFlags)")
}
