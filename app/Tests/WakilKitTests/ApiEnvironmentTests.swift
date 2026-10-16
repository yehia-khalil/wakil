import Foundation
import Testing
@testable import WakilKit

/// 9b W12 and W1: a switch that changes nothing raises nothing, and every api pane re-resolves
/// its entry when the environment does change.

private func listing(_ entries: [(String, String)]) -> [ApiEntryListing] {
    entries.map { ApiEntryListing(name: $0.0, baseURL: $0.1, credentialed: false) }
}

private func listApisReply(_ entries: [(String, String)]) -> JSONValue {
    .object(["structuredContent": .object(["apis": .array(entries.map {
        .object(["name": .string($0.0), "baseUrl": .string($0.1), "authenticated": .bool(false)])
    })])])
}

@Test("W12: the environment already active is a no-op, trimmed")
func aSwitchToTheActiveEnvironmentIsANoOp() {
    #expect(environmentSwitchIsNoOp(from: "production", to: " production "))
    #expect(!environmentSwitchIsNoOp(from: "staging", to: "production"))
    #expect(writeGate(
        environment: "production", kind: .control, origin: .agent,
        targetEnvironment: "production", production: .undeclared) == .allow)
    #expect(writeGate(
        environment: "staging", kind: .control, origin: .agent,
        targetEnvironment: "production", production: .undeclared) == .gate)
}

@Test("W1: an entry the new environment declares takes its origin; one it does not keeps its name")
func reresolution() {
    let qa = listing([("catalog", "https://catalog-qa.example")])
    #expect(apiReresolution(entry: "catalog", listing: qa).origin == "https://catalog-qa.example")
    let missing = apiReresolution(entry: "billing", listing: qa)
    #expect(missing.entry == "billing")
    #expect(missing.origin == nil)
}

@Test("Review Focus 5: a single-entry environment never leaves a pane unpointed")
func aSingleEntryEnvironmentNeverLeavesAPaneUnpointed() async throws {
    let one = listing([("catalog", "https://c.example")])
    #expect(apiReresolution(entry: "", listing: one).entry == "catalog")
    #expect(!apiPaneIsUnpointed(entry: "", entries: ["catalog"]))
    #expect(apiPaneIsUnpointed(entry: "", entries: ["catalog", "billing"]))

    let dir = testScratchRoot.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let registry = ActionRegistry(journalDirectory: dir, sessionId: "t")
    let panes = PaneStore()
    await registerApiActions(
        into: registry, panes: panes, layout: LayoutStore(),
        http: RecordingToolCaller(always: listApisReply([("catalog", "https://c.example")])),
        activeContext: { ("initech", "proj", "staging", "/tmp") })
    let opened = try await registry.dispatch(
        name: "api_open", params: .object([:]), origin: .agent, environment: "staging",
        confirmation: nil)
    guard case .object(let f) = opened else { Issue.record("no result"); return }
    #expect(f["entry"] == .string("catalog"))
}

@Test("W1: api_open naming no entry in an environment of several opens unpointed, with the whole list")
func anOmittedEntryOpensUnpointed() async throws {
    let dir = testScratchRoot.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let registry = ActionRegistry(journalDirectory: dir, sessionId: "t")
    let panes = PaneStore()
    let http = RecordingToolCaller(always: listApisReply([
        ("billing", "https://b.example"), ("catalog", "https://c.example"),
    ]))
    await registerApiActions(
        into: registry, panes: panes, layout: LayoutStore(), http: http,
        activeContext: { ("initech", "proj", "staging", "/tmp") })
    let opened = try await registry.dispatch(
        name: "api_open", params: .object([:]), origin: .agent, environment: "staging",
        confirmation: nil)
    guard case .object(let f) = opened, case .string(let pane)? = f["pane"] else {
        Issue.record("no pane"); return
    }
    #expect(f["entry"] == .string(""))
    #expect(f["origin"] == .null)
    #expect(f["entries"] == .array([.string("billing"), .string("catalog")]))
    // One list_apis, not two (the handler used to call it once to pick and once to list).
    #expect(await http.calls.filter { $0.name == "list_apis" }.count == 1)

    // Send from it is refused, as a refusal the pane draws, and nothing reaches wakil-http.
    _ = try await registry.dispatch(
        name: "api_request", params: .object(["pane": .string(pane)]), origin: .agent,
        environment: "staging", confirmation: nil)
    let snapshot = await panes.apiSnapshot(paneId: pane)
    guard case .refusal(let refusal) = snapshot.response else { Issue.record("not refused"); return }
    #expect(refusal.failures.map(\.message) == [apiPickAnEntryFirst])
    #expect(refusal.failures.first?.region == nil)
    #expect(await http.calls.allSatisfy { $0.name == "list_apis" })
}

@Test("W1: api_send from an unpointed pane is refused too, before anything reaches wakil-http")
func anUnpointedMutationIsRefused() async throws {
    let dir = testScratchRoot.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let registry = ActionRegistry(journalDirectory: dir, sessionId: "t")
    let panes = PaneStore()
    let http = RecordingToolCaller(always: listApisReply([
        ("billing", "https://b.example"), ("catalog", "https://c.example"),
    ]))
    await registerApiActions(
        into: registry, panes: panes, layout: LayoutStore(), http: http,
        activeContext: { ("initech", "proj", "staging", "/tmp") })
    let opened = try await registry.dispatch(
        name: "api_open", params: .object([:]), origin: .agent, environment: "staging",
        confirmation: nil)
    guard case .object(let f) = opened, case .string(let pane)? = f["pane"] else {
        Issue.record("no pane"); return
    }
    _ = try await registry.dispatch(
        name: "api_set_request", params: .object(["pane": .string(pane), "method": .string("POST")]),
        origin: .agent, environment: "staging", confirmation: nil)
    let sent = try await registry.dispatch(
        name: "api_send", params: .object(["pane": .string(pane), "statement": .string("POST /x")]),
        origin: .agent, environment: "staging", confirmation: nil)
    guard case .object(let r) = sent else { Issue.record("no result"); return }
    #expect(r["state"] == .string("refusal"))
    guard case .refusal(let refusal) = await panes.apiSnapshot(paneId: pane).response else {
        Issue.record("not refused"); return
    }
    #expect(refusal.failures.map(\.message) == [apiPickAnEntryFirst])
    #expect(await http.calls.allSatisfy { $0.name == "list_apis" })
}

@Test("W1: the resolver re-resolves every api pane with one list_apis")
func theResolverReResolvesEveryPane() async {
    let panes = PaneStore()
    await panes.openApi(paneId: "api-1", entry: "catalog", environment: "staging",
                        origin: "https://c.example", credentialed: false, entries: ["catalog", "billing"])
    await panes.openApi(paneId: "api-2", entry: "billing", environment: "staging",
                        origin: "https://b.example", credentialed: true, entries: ["catalog", "billing"])
    await panes.clearApiResponses(to: "qa")
    let http = RecordingToolCaller(always: listApisReply([("catalog", "https://catalog-qa.example")]))
    await ApiPaneResolver(panes: panes, http: http).reresolve(environment: "qa")

    let one = await panes.apiSnapshot(paneId: "api-1")
    #expect(one.request.origin == "https://catalog-qa.example")
    #expect(one.entries == ["catalog"])
    let two = await panes.apiSnapshot(paneId: "api-2")
    #expect(two.entry == "billing")
    #expect(two.request.origin == nil)
    #expect(apiOriginLine(two) == .caution("qa declares no entry named billing — pick one"))
    #expect(await http.calls.count == 1)
}

@Test("W1, the operator's walk: staging → production → staging keeps an entry both declare pointed")
func theRoundTripKeepsTheOrigin() async {
    let panes = PaneStore()
    await panes.openApi(paneId: "api-1", entry: "catalog", environment: "staging",
                        origin: "https://catalog-staging.example", credentialed: true,
                        entries: ["catalog"])
    let staging = ApiPaneResolver(
        panes: panes, http: RecordingToolCaller(always: listApisReply([("catalog", "https://catalog-staging.example")])))
    let production = ApiPaneResolver(
        panes: panes, http: RecordingToolCaller(always: listApisReply([("catalog", "https://catalog.example")])))

    await panes.clearApiResponses(to: "production")
    await production.reresolve(environment: "production")
    #expect(await panes.apiSnapshot(paneId: "api-1").request.origin == "https://catalog.example")
    await panes.clearApiResponses(to: "staging")
    await staging.reresolve(environment: "staging")
    let back = await panes.apiSnapshot(paneId: "api-1")
    #expect(back.request.origin == "https://catalog-staging.example")
    #expect(back.environment == "staging")
    #expect(apiOriginLine(back) == .origin("https://catalog-staging.example"))
}

@Test("The URL line says what is missing")
func theOriginLine() {
    func snap(entry: String, origin: String?, entries: [String]) -> ApiSnapshot {
        ApiSnapshot(
            entry: entry, environment: "staging", credentialed: false,
            request: ApiRequestSnapshot(method: "GET", origin: origin, path: [], query: [],
                                        headers: ApiRequestSnapshot.empty.headers, body: []),
            response: .none, entries: entries, recent: [], recentTruncated: false)
    }
    #expect(apiOriginLine(snap(entry: "c", origin: "https://c", entries: ["c"])) == .origin("https://c"))
    #expect(apiOriginLine(snap(entry: "", origin: nil, entries: ["a", "b", "c"]))
        == .caution("pick an entry — staging declares 3"))
    #expect(apiOriginLine(snap(entry: "c", origin: nil, entries: ["c"]))
        == .caution("no origin — this entry does not resolve"))
    // Fix round 1, item 6: the missing-entry branch.
    #expect(apiOriginLine(snap(entry: "billing", origin: nil, entries: ["catalog"]))
        == .caution("staging declares no entry named billing — pick one"))
}

// MARK: - The Send control's press (W14; preflight F9)

@Test("F9: Send's press sends at rest, and cancels in flight with the pane named")
func theSendPress() {
    let since = Date(timeIntervalSince1970: 0)
    let flight = ApiSending(since: since, method: "POST")
    #expect(apiSendPress(pane: "api-1", sending: nil) == .send)
    #expect(apiSendPress(pane: "api-1", sending: flight)
        == .dispatch(name: "api_cancel", params: .object(["pane": .string("api-1")])))
}

@Test("F9: ⌘Return in flight does nothing — it never cancels")
func commandReturnNeverCancels() {
    let flight = ApiSending(since: Date(), method: "GET")
    #expect(apiSendPress(pane: "api-1", sending: nil, fromKeyboard: true) == .send)
    #expect(apiSendPress(pane: "api-1", sending: flight, fromKeyboard: true) == .nothing)
}

// MARK: - Fix round 1

/// A `wakil-http` whose first `list_apis` waits for `release()` (latching, like `StallingHTTP`)
/// and then answers `first`; every later call answers `later` at once.
private actor StalledListing: ToolCaller {
    private let first: JSONValue
    private let later: JSONValue
    private var calls = 0
    private var parked: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var isParked = false

    init(first: JSONValue, later: JSONValue) { self.first = first; self.later = later }

    func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        calls += 1
        guard calls == 1 else { return later }
        if !released {
            await withCheckedContinuation { parked = $0; isParked = true }
        }
        return first
    }

    func release() {
        released = true
        parked?.resume()
        parked = nil
    }
}

private struct ListingFailed: Error {}

@Test("Fix 1: a stale re-resolve that answers after a later switch writes nothing", .timeLimit(.minutes(1)))
func aStaleReResolveLosesToALaterSwitch() async throws {
    let panes = PaneStore()
    await panes.openApi(paneId: "api-1", entry: "catalog", environment: "staging",
                        origin: "https://catalog-staging.example", credentialed: false, entries: ["catalog"])
    let http = StalledListing(
        first: listApisReply([("catalog", "https://catalog.example")]),
        later: listApisReply([("catalog", "https://catalog-staging.example")]))
    let resolver = ApiPaneResolver(panes: panes, http: http)
    defer { Task { await http.release() } }

    // Switch A, to production: its list_apis stalls.
    await panes.clearApiResponses(to: "production")
    let stale = Task { await resolver.reresolve(environment: "production") }
    try #require(await apiEventually { await http.isParked })
    // Switch B, back to staging, finishes first.
    await panes.clearApiResponses(to: "staging")
    await resolver.reresolve(environment: "staging")
    // Now A's answer arrives.
    await http.release()
    await stale.value

    let pane = await panes.apiSnapshot(paneId: "api-1")
    #expect(pane.environment == "staging")
    #expect(pane.request.origin == "https://catalog-staging.example")
}

@Test("Fix 3: a failed list_apis leaves every pane as it was; an empty answer declares none")
func aFailedListingLeavesPanesUntouched() async {
    let panes = PaneStore()
    await panes.openApi(paneId: "api-1", entry: "catalog", environment: "staging",
                        origin: "https://c.example", credentialed: true, entries: ["catalog", "billing"])
    let threw = RecordingToolCaller { _, _ in throw ListingFailed() }
    await ApiPaneResolver(panes: panes, http: threw).reresolve(environment: "staging")
    var pane = await panes.apiSnapshot(paneId: "api-1")
    #expect(pane.request.origin == "https://c.example")
    #expect(pane.credentialed)
    #expect(pane.entries == ["catalog", "billing"])

    let isError = RecordingToolCaller(always: .object([
        "isError": .bool(true), "content": .array([]),
    ]))
    await ApiPaneResolver(panes: panes, http: isError).reresolve(environment: "staging")
    pane = await panes.apiSnapshot(paneId: "api-1")
    #expect(pane.request.origin == "https://c.example")

    let none = RecordingToolCaller(always: listApisReply([]))
    await ApiPaneResolver(panes: panes, http: none).reresolve(environment: "staging")
    pane = await panes.apiSnapshot(paneId: "api-1")
    #expect(pane.request.origin == nil)
    #expect(pane.entries == [])
}

@Test("Fix 4: api_open on a pointed pane, naming no entry, keeps that pane's entry")
func reopeningAPointedPaneKeepsItsEntry() async throws {
    let dir = testScratchRoot.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let registry = ActionRegistry(journalDirectory: dir, sessionId: "t")
    let panes = PaneStore()
    await registerApiActions(
        into: registry, panes: panes, layout: LayoutStore(),
        http: RecordingToolCaller(always: listApisReply([
            ("billing", "https://b.example"), ("catalog", "https://c.example"),
        ])),
        activeContext: { ("initech", "proj", "staging", "/tmp") })
    let opened = try await registry.dispatch(
        name: "api_open", params: .object(["entry": .string("billing")]), origin: .agent,
        environment: "staging", confirmation: nil)
    guard case .object(let f) = opened, case .string(let pane)? = f["pane"] else {
        Issue.record("no pane"); return
    }
    let again = try await registry.dispatch(
        name: "api_open", params: .object(["pane": .string(pane)]), origin: .agent,
        environment: "staging", confirmation: nil)
    guard case .object(let g) = again else { Issue.record("no result"); return }
    #expect(g["entry"] == .string("billing"))
    #expect(g["origin"] == .string("https://b.example"))
    #expect(await panes.apiSnapshot(paneId: pane).entry == "billing")
}

@Test("Fix 2: Send from an unpointed pane is refused before anything is dispatched")
func anUnpointedSendIsRefusedInThePlan() {
    let draft = ApiRequestSnapshot(
        method: "POST", origin: nil, path: [], query: [],
        headers: ApiRequestSnapshot.empty.headers, body: [])
    let plan = apiSendPlan(draft: draft, pane: "api-1", held: [:], unpointed: true)
    #expect(plan.calls.isEmpty)
    #expect(plan.refusal == apiPickAnEntryFirst)
    // The fields are still saved as typed: only the send is refused.
    let typed = apiSendPlan(
        draft: draft, pane: "api-1", held: [ApiFieldRow(.path): [.literal("/x")]], unpointed: true)
    #expect(typed.calls.map(\.0) == ["api_set_request"])
    #expect(typed.refusal == apiPickAnEntryFirst)
    // Pointed, it sends and refuses nothing.
    let pointed = apiSendPlan(draft: draft, pane: "api-1", held: [:])
    #expect(pointed.calls.map(\.0) == ["api_send"])
    #expect(pointed.refusal == nil)
}

@Test("W8: a re-resolve that points an unpointed pane retitles it")
func aReresolveRetitles() async {
    let panes = PaneStore()
    let layout = LayoutStore()
    let id = await layout.open(kind: "api", title: "api").id
    await panes.openApi(paneId: id, entry: "", environment: "staging", origin: nil,
                        credentialed: false, entries: ["a", "b"])
    let http = RecordingToolCaller(always: listApisReply([("catalog", "https://c.example")]))
    await ApiPaneResolver(panes: panes, http: http, layout: layout).reresolve(environment: "qa")
    #expect(await layout.snapshot().panes.first { $0.id == id }?.title == "catalog")
}

@Test("W8: a re-resolve that leaves a pane's entry as it was leaves its title alone")
func aReresolveThatChangesNothingKeepsTheTitle() async {
    let panes = PaneStore()
    let layout = LayoutStore()
    let id = await layout.open(kind: "api", title: "catalog · bookings").id
    await panes.openApi(paneId: id, entry: "catalog", environment: "staging",
                        origin: "https://c.example", credentialed: false, entries: ["catalog"])
    let http = RecordingToolCaller(always: listApisReply([("catalog", "https://c-qa.example")]))
    await ApiPaneResolver(panes: panes, http: http, layout: layout).reresolve(environment: "qa")
    #expect(await layout.snapshot().panes.first { $0.id == id }?.title == "catalog · bookings")
}

@Test("W8 (P22): a stale answer writes nothing, so it retitles nothing")
func aStaleReresolveRetitlesNothing() async {
    let panes = PaneStore()
    await panes.openApi(paneId: "api-1", entry: "", environment: "staging", origin: nil,
                        credentialed: false, entries: ["a", "b"])
    let generation = await panes.apiResolutionMark()
    await panes.clearApiResponses(to: "qa")
    let changed = await panes.reresolveApis(
        environment: "staging", listing: [ApiEntryListing(name: "catalog", baseURL: "https://c.example", credentialed: false)],
        generation: generation)
    #expect(changed == nil)
    let fresh = await panes.reresolveApis(
        environment: "qa", listing: [ApiEntryListing(name: "catalog", baseURL: "https://c.example", credentialed: false)])
    #expect(fresh == ["api-1": "catalog"])
}

@Test("W8 (final review I3): a pane restored unpointed in a multi-entry environment is retitled")
func aRestoredUnpointedPaneIsRetitled() async {
    let panes = PaneStore()
    let layout = LayoutStore()
    // The layout persisted the title it had; the draft was never persisted.
    let id = await layout.open(kind: "api", title: "catalog").id
    let http = RecordingToolCaller(always: listApisReply([
        ("catalog", "https://c.example"), ("billing", "https://b.example"), ("auth", "https://a.example"),
    ]))
    await ApiPaneResolver(panes: panes, http: http, layout: layout)
        .reresolve(environment: "staging", restored: [id])
    #expect(apiOriginLine(await panes.apiSnapshot(paneId: id)) == .caution("pick an entry — staging declares 3"))
    #expect(await layout.snapshot().panes.first { $0.id == id }?.title == "api")
}
