import Foundation
import Testing
@testable import WakilKit

private func storeWithRows() async -> PaneStore {
    let panes = PaneStore()
    await panes.setRows(
        paneId: "db-1", columns: ["id"], columnTypes: ["int"], columnTypesInferred: false,
        rows: [[.integer(1)]], millis: 4, truncated: false, pageable: true, offset: 0,
        sort: [], listsTables: false, editable: nil)
    return panes
}

struct DBFlightTests {
    @Test func aSecondReadOnARunningPaneIsRefused() async {
        let panes = await storeWithRows()
        let first = await panes.beginDBRead(paneId: "db-1", at: Date())
        #expect(first != nil)
        #expect(await panes.beginDBRead(paneId: "db-1", at: Date()) == nil)
    }

    @Test func runningShowsInTheSnapshotAndReadPane() async {
        let panes = await storeWithRows()
        let since = Date(timeIntervalSince1970: 1000)
        _ = await panes.beginDBRead(paneId: "db-1", at: since)
        let snap = await dbSnapshot(panes, "db-1")
        #expect(snap.runningSince == since)
        guard case .object(let read) = await panes.readPane(paneId: "db-1", kind: "db") else {
            Issue.record("read_pane is not an object"); return
        }
        #expect(read["running"] == .bool(true))
        #expect(read["cancelledAfterMs"] == .null)
    }

    @Test func cancelEndsTheFlightAtOnceAndKeepsTheRows() async {
        let panes = await storeWithRows()
        let since = Date(timeIntervalSince1970: 1000)
        _ = await panes.beginDBRead(paneId: "db-1", at: since)
        #expect(await panes.cancelDBRead(paneId: "db-1", at: since.addingTimeInterval(3.2)))
        let snap = await dbSnapshot(panes, "db-1")
        #expect(snap.runningSince == nil)
        #expect(snap.cancelledAfterMs == 3200)
        #expect(snap.rows == [[.integer(1)]])
        guard case .object(let read) = await panes.readPane(paneId: "db-1", kind: "db") else {
            Issue.record("read_pane is not an object"); return
        }
        #expect(read["running"] == .bool(false))
        #expect(read["cancelledAfterMs"] == .number(3200))
        // The pane is free again straight away — an environment switch relies on it.
        #expect(await panes.beginDBRead(paneId: "db-1", at: Date()) != nil)
    }

    @Test func cancelRunsTheArmedCanceller() async {
        let panes = await storeWithRows()
        let token = try! #require(await panes.beginDBRead(paneId: "db-1", at: Date()))
        let fired = Fired()
        await panes.armDBRead(paneId: "db-1", token: token) { Task { await fired.set() } }
        _ = await panes.cancelDBRead(paneId: "db-1")
        #expect(await dbEventually { await fired.value })
    }

    @Test func aCancelBeforeTheCancellerIsArmedIsHonouredWhenItArrives() async {
        let panes = await storeWithRows()
        let token = try! #require(await panes.beginDBRead(paneId: "db-1", at: Date()))
        _ = await panes.cancelDBRead(paneId: "db-1")
        let fired = Fired()
        await panes.armDBRead(paneId: "db-1", token: token) { Task { await fired.set() } }
        #expect(await dbEventually { await fired.value })
    }

    @Test func aLateReplyAfterCancelIsDropped() async {
        let panes = await storeWithRows()
        let token = try! #require(await panes.beginDBRead(paneId: "db-1", at: Date()))
        _ = await panes.cancelDBRead(paneId: "db-1")
        #expect(await panes.finishDBRead(paneId: "db-1", token: token) == false)
    }

    @Test func finishingTheCurrentFlightClearsItAndTheCancelledLine() async {
        let panes = await storeWithRows()
        _ = try! #require(await panes.beginDBRead(paneId: "db-1", at: Date()))
        _ = await panes.cancelDBRead(paneId: "db-1")
        let token = try! #require(await panes.beginDBRead(paneId: "db-1", at: Date()))
        #expect(await panes.finishDBRead(paneId: "db-1", token: token))
        let snap = await dbSnapshot(panes, "db-1")
        #expect(snap.runningSince == nil)
        #expect(snap.cancelledAfterMs == nil)
    }

    @Test func cancelWithNothingInFlightReportsFalse() async {
        let panes = await storeWithRows()
        #expect(await panes.cancelDBRead(paneId: "db-1") == false)
    }

    @Test func cancelAllEndsEveryFlight() async {
        let panes = await storeWithRows()
        _ = await panes.beginDBRead(paneId: "db-1", at: Date())
        await panes.cancelAllDBReads()
        #expect(await dbSnapshot(panes, "db-1").runningSince == nil)
    }

    @Test func cancelAllEndsFlightsInEveryScope() async {
        let panes = await storeWithRows()
        let a = LayoutScope(organization: "acme", project: "a")
        let b = LayoutScope(organization: "acme", project: "b")
        let fired = FiredCount()
        await panes.switchScope(to: a)
        let tokenA = try! #require(await panes.beginDBRead(paneId: "db-1", at: Date()))
        await panes.armDBRead(paneId: "db-1", token: tokenA) { Task { await fired.bump() } }
        await panes.switchScope(to: b)
        let tokenB = try! #require(await panes.beginDBRead(paneId: "db-1", at: Date()))
        await panes.armDBRead(paneId: "db-1", token: tokenB) { Task { await fired.bump() } }
        await panes.cancelAllDBReads()
        #expect(await dbSnapshot(panes, "db-1").runningSince == nil)
        await panes.switchScope(to: a)
        #expect(await dbSnapshot(panes, "db-1").runningSince == nil)
        #expect(await dbEventually { await fired.count == 2 })
    }

    @Test func aReplyForAProjectSwitchedAwayIsDropped() async {
        let panes = PaneStore()
        let a = LayoutScope(organization: "acme", project: "a")
        let b = LayoutScope(organization: "acme", project: "b")
        func rows(_ n: Int64) async {
            await panes.setRows(
                paneId: "db-1", columns: ["id"], columnTypes: ["int"], columnTypesInferred: false,
                rows: [[.integer(n)]], millis: 4, truncated: false, pageable: true, offset: 0,
                sort: [], listsTables: false, editable: nil)
        }
        await panes.switchScope(to: a)
        await rows(1)
        let token = try! #require(await panes.beginDBRead(paneId: "db-1", at: Date()))
        await panes.switchScope(to: b)
        await rows(2)
        #expect(await panes.finishDBRead(paneId: "db-1", token: token) == false)
        #expect(await dbSnapshot(panes, "db-1").rows == [[.integer(2)]])
        await panes.switchScope(to: a)
        let back = await dbSnapshot(panes, "db-1")
        #expect(back.runningSince == nil)
        #expect(back.rows == [[.integer(1)]])
    }
}

private actor FiredCount {
    var count = 0
    func bump() { count += 1 }
}

private actor Fired {
    var value = false
    func set() { value = true }
}

func dbEventually(_ seconds: Double = 2, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds * testWaitLoadMultiplier)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return await condition()
}

func dbSnapshot(_ panes: PaneStore, _ id: String) async -> DataSurfaceSnapshot {
    (await panes.snapshot(paneId: id, kind: "db")).dataSurface ?? .empty
}

