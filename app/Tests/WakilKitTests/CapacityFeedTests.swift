import Testing
import Foundation
@testable import WakilKit

@MainActor
private final class Dispatches {
    var calls: [(String, JSONValue)] = []
    var listing: JSONValue = .object(["structuredContent": .object(["readings": .array([])])])
    func dispatch(_ name: String, _ params: JSONValue) async throws -> JSONValue {
        calls.append((name, params))
        return name == "ctx_capacity" ? listing : .object([:])
    }
}

private let fixedNow = ISO8601DateFormatter().date(from: "2026-10-10T16:18:00Z")!
private let windows = CapacityWindows(
    fiveHour: CapacityWindow(percentLeft: 28, resetsAt: ISO8601DateFormatter().date(from: "2026-10-10T17:20:00Z")!),
    sevenDay: nil)

@MainActor @Test func aStreamReadingIsRecordedThenReRead() async {
    let d = Dispatches()
    let feed = CapacityFeed(now: { fixedNow })
    feed.attach(dispatch: d.dispatch)
    await feed.receive(windows, provider: "main")
    #expect(d.calls.map(\.0) == ["capacity_record", "ctx_capacity"])
    #expect(d.calls[0].1 == capacityRecordParams(provider: "main", windows: windows, asOf: fixedNow))
}

@MainActor @Test func noProviderMeansNothingIsRecorded() async {
    let d = Dispatches()
    let feed = CapacityFeed(now: { fixedNow })
    feed.attach(dispatch: d.dispatch)
    await feed.receive(windows, provider: "")
    #expect(d.calls.isEmpty)
}

@MainActor @Test func refreshKeepsTheLastReadingsWhenTheReadFails() async {
    let d = Dispatches()
    d.listing = .object(["structuredContent": .object(["readings": .array([
        .object(["account": .string("main"), "kind": .string("claude-code"), "state": .string("notRead")])])])])
    let feed = CapacityFeed(now: { fixedNow })
    feed.attach(dispatch: d.dispatch)
    await feed.refresh()
    #expect(feed.readings.map(\.account) == ["main"])
    d.listing = .string("garbage")
    await feed.refresh()
    #expect(feed.readings.map(\.account) == ["main"])   // Rule 8: last readings stay
    #expect(feed.failure != nil)
}

@Test func providerRowsCarryTheCapacitySubtitleAndCaution() {
    let rows: [JSONValue] = [.object(["id": .string("work"), "kind": .string("claude-code")])]
    let low = CapacityReading(account: "work", kind: "claude-code", state: .read,
        fiveHour: CapacityWindow(percentLeft: 50, resetsAt: fixedNow.addingTimeInterval(3_600)),
        sevenDay: CapacityWindow(percentLeft: 12, resetsAt: fixedNow.addingTimeInterval(86_400 * 3)),
        asOf: fixedNow, error: nil)
    let items = WindowModel.providerItems(from: rows, running: "", capacity: [low], now: fixedNow)
    #expect(items.first?.subtitle == "account · claude-code · 5h 50% · week 12%")
    #expect(items.first?.caution == true)
}

@MainActor @Test func aRateLimitIsRecordedAgainstThePumpsProvider() async {
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot, organization: "alpha")
    let d = Dispatches()
    model.capacity.attach(dispatch: d.dispatch)
    // The pump started under "main"; the window has since switched (providerId is not "main").
    #expect(model.providerId != "main")
    await model.receiveForTesting(.rateLimit(windows), provider: "main")
    guard case .object(let params)? = d.calls.first(where: { $0.0 == "capacity_record" })?.1 else {
        Issue.record("nothing recorded: \(d.calls.map(\.0))"); return
    }
    #expect(params["provider"] == .string("main"))
}

@MainActor @Test func resetForgetsReadingsAndFailure() async {
    let d = Dispatches()
    d.listing = .object(["structuredContent": .object(["readings": .array([
        .object(["account": .string("main"), "kind": .string("claude-code"), "state": .string("notRead")])])])])
    let feed = CapacityFeed(now: { fixedNow })
    feed.attach(dispatch: d.dispatch)
    await feed.refresh()
    d.listing = .string("garbage")
    await feed.refresh()
    #expect(!feed.readings.isEmpty && feed.failure != nil)
    feed.reset()
    #expect(feed.readings.isEmpty)
    #expect(feed.failure == nil)
}

@MainActor @Test func refreshWithProbeAsksForRefresh() async {
    let d = Dispatches()
    let feed = CapacityFeed(now: { fixedNow })
    feed.attach(dispatch: d.dispatch)
    await feed.refresh(probe: true)
    await feed.refresh()
    #expect(d.calls.map(\.0) == ["ctx_capacity", "ctx_capacity"])
    #expect(d.calls[0].1 == .object(["refresh": .bool(true)]))
    #expect(d.calls[1].1 == .object([:]))
}

@MainActor private final class GatedDispatch {
    var continuation: CheckedContinuation<Void, Never>?
    func dispatch(_ name: String, _ params: JSONValue) async throws -> JSONValue {
        await withCheckedContinuation { continuation = $0 }
        return .object(["structuredContent": .object(["readings": .array([
            .object(["account": .string("old-org"), "kind": .string("claude"), "state": .string("noLimits")])])])])
    }
}

@MainActor @Test func aReplyThatLandsAfterResetIsDropped() async {
    let g = GatedDispatch()
    let feed = CapacityFeed(now: { fixedNow })
    feed.attach(dispatch: g.dispatch)
    let inFlight = Task { await feed.refresh() }
    while g.continuation == nil { await Task.yield() }
    feed.reset()
    g.continuation?.resume()
    await inFlight.value
    #expect(feed.readings.isEmpty)
    #expect(feed.failure == nil)
}
