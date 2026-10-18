import Foundation
import Testing
@testable import WakilKit

/// Answers every db tool at once, except `query`/`read_table` when `stall` is on: those sleep
/// 30 s and throw `CancellationError` when cancelled, as a real call does.
/// Internal, not private: `WindowModelTests.restoreCancelsReadsInFlightFirst` uses it too.
/// `cancelled` counts the stalled calls that were cancelled — a canceller that actually ran.
actor StallingDB: ToolCaller {
    var stall = true
    private(set) var calls = 0
    private(set) var cancelled = 0
    /// Stalled calls that reached their sleep. `runningSince` is set before the call arrives,
    /// so a test that lifts the stall on it alone can let the call through unstalled.
    private(set) var stalled = 0
    func setStall(_ on: Bool) { stall = on }
    func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        calls += 1
        if stall, name == "query" || name == "read_table" {
            stalled += 1
            do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch {
                cancelled += 1
                throw error
            }
        }
        return .object(["structuredContent": .object([
            "columns": .array([.string("id")]),
            "rows": .array([.array([.integer(2)])]),
            "millis": .number(1),
        ])])
    }
}

private func fixture(
    _ db: StallingDB, truncated: Bool = false
) async throws -> (ActionRegistry, PaneStore, String, LayoutStore) {
    let dir = testScratchRoot.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let registry = ActionRegistry(journalDirectory: dir.appendingPathComponent("journal"), sessionId: "s1")
    let panes = PaneStore()
    let layout = LayoutStore()
    await registerStandardActions(
        into: registry, context: nil, panes: panes, db: db, resumes: ResumeBroker(), layout: layout)
    let pane = await layout.open(kind: "db", title: "db").id
    await panes.setRows(
        paneId: pane, columns: ["id"], columnTypes: ["int"], columnTypesInferred: false,
        rows: [[.integer(1)]], millis: 4, truncated: truncated, pageable: true, offset: 0,
        sort: [], listsTables: false, editable: nil)
    await layout.setFetch(PaneFetch(query: .sql(database: nil, raw: "SELECT 1")), id: pane)
    return (registry, panes, pane, layout)
}

private func run(_ registry: ActionRegistry, _ name: String, _ params: [String: JSONValue]) async throws -> JSONValue {
    try await registry.dispatch(
        name: name, params: .object(params), origin: .agent, caller: .test("staging"), confirmation: nil)
}

struct DBCancelTests {
    @Test(.timeLimit(.minutes(1))) func aCancelledQueryKeepsTheRowsAndSaysSo() async throws {
        let (registry, panes, pane, _) = try await fixture(StallingDB())
        let read = Task { try await run(registry, "db_run_query", ["pane": .string(pane), "query": .string("SELECT 2")]) }
        #expect(await dbEventually { await dbSnapshot(panes, pane).runningSince != nil })
        _ = try await run(registry, "db_cancel", ["pane": .string(pane)])
        let result = try await read.value
        guard case .object(let fields) = result else { Issue.record("not an object"); return }
        #expect(fields["cancelled"] == .bool(true))
        let snap = await dbSnapshot(panes, pane)
        #expect(snap.rows == [[.integer(1)]])
        #expect(snap.cancelledAfterMs != nil)
        #expect(snap.runningSince == nil)
    }

    @Test(.timeLimit(.minutes(1))) func aSecondReadWhileOneRunsIsRefused() async throws {
        let (registry, panes, pane, _) = try await fixture(StallingDB())
        let read = Task { try await run(registry, "db_refetch", ["pane": .string(pane)]) }
        #expect(await dbEventually { await dbSnapshot(panes, pane).runningSince != nil })
        await #expect(throws: StandardActionError.readInFlight(action: "db_page", pane: pane)) {
            _ = try await run(registry, "db_page", ["pane": .string(pane), "to": .string("next")])
        }
        _ = try await run(registry, "db_cancel", ["pane": .string(pane)])
        _ = try await read.value
    }

    @Test func cancelWithNothingInFlightIsRefused() async throws {
        let (registry, _, pane, _) = try await fixture(StallingDB())
        await #expect(throws: StandardActionError.nothingInFlight(action: "db_cancel", pane: pane)) {
            _ = try await run(registry, "db_cancel", ["pane": .string(pane)])
        }
    }

    @Test func aReadThatLandsWritesItsRowsAndEndsTheFlight() async throws {
        let db = StallingDB()
        await db.setStall(false)
        let (registry, panes, pane, _) = try await fixture(db)
        _ = try await run(registry, "db_refetch", ["pane": .string(pane)])
        let snap = await dbSnapshot(panes, pane)
        #expect(snap.rows == [[.integer(2)]])
        #expect(snap.runningSince == nil)
    }

    @Test(.timeLimit(.minutes(1))) func aQueryNamingNoPaneIsNotAFlight() async throws {
        let db = StallingDB()
        await db.setStall(false)
        let (registry, _, _, _) = try await fixture(db)
        // Opens its own pane when it lands; nothing to show `running` on before then (spec, "What it does not do").
        _ = try await run(registry, "db_run_query", ["query": .string("SELECT 2")])
    }

    @Test func dbCancelIsAgentReachableControl() async throws {
        let (registry, _, _, _) = try await fixture(StallingDB())
        let action = try #require(await registry.all().first { $0.name == "db_cancel" })
        #expect(action.kind == .control)
        #expect(action.audience == .agentReachable)
    }

    @Test(.timeLimit(.minutes(1))) func aCancelledPageMoveKeepsTheFetch() async throws {
        let (registry, panes, pane, layout) = try await fixture(StallingDB())
        let read = Task { try await run(registry, "db_page", ["pane": .string(pane), "to": .string("next")]) }
        #expect(await dbEventually { await dbSnapshot(panes, pane).runningSince != nil })
        _ = try await run(registry, "db_cancel", ["pane": .string(pane)])
        let result = try await read.value
        guard case .object(let fields) = result else { Issue.record("not an object"); return }
        #expect(fields["cancelled"] == .bool(true))
        #expect(await layout.fetch(id: pane)?.offset == 0)
    }

    @Test(.timeLimit(.minutes(1))) func aCancelledSortKeepsTheFetchAndSaysNotRequeried() async throws {
        let (registry, panes, pane, layout) = try await fixture(StallingDB(), truncated: true)
        let read = Task { try await run(registry, "pane_sort", ["pane": .string(pane), "column": .string("id")]) }
        #expect(await dbEventually { await dbSnapshot(panes, pane).runningSince != nil })
        _ = try await run(registry, "db_cancel", ["pane": .string(pane)])
        let result = try await read.value
        guard case .object(let fields) = result else { Issue.record("not an object"); return }
        #expect(fields["cancelled"] == .bool(true))
        #expect(fields["requeried"] == nil)
        #expect(await layout.fetch(id: pane)?.sort == [])
    }

    // Final review, Minor 4: `pane_close` drops the pane; its read must stop on the server too.
    @Test(.timeLimit(.minutes(1))) func droppingAPaneCancelsItsReadInFlight() async throws {
        let db = StallingDB()
        let (registry, panes, pane, _) = try await fixture(db)
        let read = Task { try await run(registry, "db_refetch", ["pane": .string(pane)]) }
        #expect(await dbEventually { await dbSnapshot(panes, pane).runningSince != nil })
        await panes.drop(paneId: pane)
        #expect(await dbEventually { await db.cancelled == 1 })
        _ = try? await read.value
    }

    // Final review, Minor 5: a local re-sort recorded under a read in flight would be reverted
    // when the read lands. Refused before anything changes (Rule 5).
    @Test(.timeLimit(.minutes(1))) func aSortWhileAReadRunsIsRefusedAndChangesNothing() async throws {
        let (registry, panes, pane, layout) = try await fixture(StallingDB())
        let read = Task { try await run(registry, "db_refetch", ["pane": .string(pane)]) }
        #expect(await dbEventually { await dbSnapshot(panes, pane).runningSince != nil })
        await #expect(throws: StandardActionError.readInFlight(action: "pane_sort", pane: pane)) {
            _ = try await run(registry, "pane_sort", ["pane": .string(pane), "column": .string("id")])
        }
        #expect(await layout.fetch(id: pane)?.sort == [])
        #expect(await dbSnapshot(panes, pane).sort == [])
        _ = try await run(registry, "db_cancel", ["pane": .string(pane)])
        _ = try await read.value
    }

    @Test(.timeLimit(.minutes(1))) func cancellingTheCallerEndsTheFlightWithoutACancelledMark() async throws {
        let (registry, panes, pane, _) = try await fixture(StallingDB())
        let read = Task { try await run(registry, "db_refetch", ["pane": .string(pane)]) }
        #expect(await dbEventually { await dbSnapshot(panes, pane).runningSince != nil })
        read.cancel()
        _ = try? await read.value
        #expect(await dbEventually { await dbSnapshot(panes, pane).runningSince == nil })
        #expect(await dbSnapshot(panes, pane).cancelledAfterMs == nil)
    }
}
