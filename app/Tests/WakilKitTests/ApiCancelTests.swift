import Foundation
import Testing
@testable import WakilKit

/// W14: a send in flight, refused a second time, and cancelled from either channel.

private func cancelFixture(
    _ http: StallingHTTP
) async throws -> (registry: ActionRegistry, panes: PaneStore, pane: String) {
    let dir = testScratchRoot.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let registry = ActionRegistry(journalDirectory: dir, sessionId: "t")
    let panes = PaneStore()
    await registerApiActions(
        into: registry, panes: panes, layout: LayoutStore(), http: http,
        activeContext: { ("initech", "proj", "staging", "/tmp") })
    let opened = try await registry.dispatch(
        name: "api_open", params: .object([:]), origin: .agent, caller: .test("staging"),
        confirmation: nil)
    guard case .object(let f) = opened, case .string(let pane)? = f["pane"] else {
        throw CancelFixtureFailed()
    }
    return (registry, panes, pane)
}
private struct CancelFixtureFailed: Error {}

private func dispatch(
    _ registry: ActionRegistry, _ name: String, _ params: [String: JSONValue]
) async throws -> JSONValue {
    try await registry.dispatch(
        name: name, params: .object(params), origin: .agent, caller: .test("staging"),
        confirmation: nil)
}

@Test("A cancelled read reads 'cancelled after', and Recent records it as cancelled", .timeLimit(.minutes(1)))
func aCancelledReadIsCancelled() async throws {
    let (registry, panes, pane) = try await cancelFixture(StallingHTTP())
    let send = Task { try await dispatch(registry, "api_request", ["pane": .string(pane)]) }
    try #require(await apiEventually { await panes.apiSnapshot(paneId: pane).sending != nil })
    _ = try await dispatch(registry, "api_cancel", ["pane": .string(pane)])
    _ = try await send.value
    let snapshot = await panes.apiSnapshot(paneId: pane)
    #expect(snapshot.response.state == "cancelled")
    #expect(snapshot.sending == nil)
    #expect(snapshot.recent.first?.cancelled == true)
    // F10: a read is plainly cancelled — it changed nothing, so there is no fate to doubt.
    let row = try #require(snapshot.recent.first)
    #expect(apiRecentRowLabel(row).contains(" · cancelled · "))
    #expect(!apiRecentRowLabel(row).contains("may have landed"))
}

@Test("A cancelled mutation is fate-unknown: the server may already have it", .timeLimit(.minutes(1)))
func aCancelledMutationIsFateUnknown() async throws {
    let (registry, panes, pane) = try await cancelFixture(StallingHTTP())
    _ = try await dispatch(registry, "api_set_request", [
        "pane": .string(pane), "method": .string("POST"),
        "body": .array([.object(["literal": .string("{}")])]),
    ])
    let send = Task {
        try await dispatch(registry, "api_send", ["pane": .string(pane), "statement": .string("s")])
    }
    try #require(await apiEventually { await panes.apiSnapshot(paneId: pane).sending != nil })
    _ = try await dispatch(registry, "api_cancel", ["pane": .string(pane)])
    _ = try await send.value
    guard case .unknown(let record) = await panes.apiSnapshot(paneId: pane).response else {
        Issue.record("not fate-unknown"); return
    }
    #expect(record.reason.hasPrefix("cancelled after "))
    #expect(record.reason.hasSuffix(" — the server may already have it"))
    // F10: Recent records it as fate unknown too, not as a plain cancel.
    let row = try #require(await panes.apiSnapshot(paneId: pane).recent.first)
    #expect(row.cancelled)
    #expect(apiRecentRowLabel(row).contains(" · cancelled — may have landed"))
}

@Test("A second send on a pane in flight is refused, from either channel", .timeLimit(.minutes(1)))
func aSecondSendIsRefused() async throws {
    let (registry, panes, pane) = try await cancelFixture(StallingHTTP())
    let send = Task { try await dispatch(registry, "api_request", ["pane": .string(pane)]) }
    try #require(await apiEventually { await panes.apiSnapshot(paneId: pane).sending != nil })
    let thrown = await #expect(throws: ApiActionError.self) {
        _ = try await dispatch(registry, "api_request", ["pane": .string(pane)])
    }
    #expect(String(describing: thrown!).contains("a send is already in flight on this pane"))
    _ = try await dispatch(registry, "api_cancel", ["pane": .string(pane)])
    _ = try await send.value
}

@Test("api_cancel with nothing in flight is refused")
func cancelWithNothingInFlightIsRefused() async throws {
    let (registry, _, pane) = try await cancelFixture(StallingHTTP())
    let thrown = await #expect(throws: ApiActionError.self) {
        _ = try await dispatch(registry, "api_cancel", ["pane": .string(pane)])
    }
    #expect(String(describing: thrown!).contains("nothing is in flight"))
}

@Test("Review Focus 3: a reply that beats the cancel is kept, not overwritten as cancelled", .timeLimit(.minutes(1)))
func aReplyThatBeatsTheCancelIsKept() async throws {
    let http = StallingHTTP(honoursCancel: false)
    let (registry, panes, pane) = try await cancelFixture(http)
    // Whatever happens below, nothing stays parked past the test.
    defer { Task { await http.release() } }
    let send = Task { try await dispatch(registry, "api_request", ["pane": .string(pane)]) }
    try #require(await apiEventually { await http.parkedCount() == 1 })
    _ = try await dispatch(registry, "api_cancel", ["pane": .string(pane)])
    await http.release()
    _ = try await send.value
    let snapshot = await panes.apiSnapshot(paneId: pane)
    #expect(snapshot.response.status == 200)
    #expect(snapshot.recent.first?.cancelled == false)
}

@Test("Review Focus 4: a send that outlives its environment lands in Recent only")
func aSendThatOutlivesItsEnvironmentLandsInRecentOnly() async throws {
    let panes = PaneStore()
    await panes.openApi(
        paneId: "api-1", entry: "slow", environment: "staging", origin: "https://s", credentialed: false)
    let reply = ApiResponseSnapshot.ok(ApiResponseOK(
        status: 200, url: "https://s/x", environment: "staging", headers: [:], body: "",
        durationMs: 5, byteCount: 0, truncated: false))
    // F2: the pane holds staging's earlier reply, so the switch to production clears it rather
    // than leaving `.none` alone — "staging's reply lands after the pane was cleared".
    await panes.setApiResponse(paneId: "api-1", response: reply)
    let token = try #require(await panes.beginApiSend(paneId: "api-1", method: "GET", at: Date()))
    await panes.clearApiResponses(to: "production")
    await panes.finishApiSend(
        paneId: "api-1", token: token, outcome: ApiRequestOutcome(draft: .empty, response: reply))
    let snapshot = await panes.apiSnapshot(paneId: "api-1")
    #expect(snapshot.response == .cleared(environment: "production"))
    #expect(snapshot.sending == nil)
    // W15: production's Recent is production's. The send is filed under staging, where it went.
    #expect(snapshot.recent.isEmpty)
    await panes.clearApiResponses(to: "staging")
    #expect(await panes.apiSnapshot(paneId: "api-1").recent.first?.environment == "staging")
}

@Test("read_pane says whether a send is in flight")
func readPanePublishesSending() async {
    let panes = PaneStore()
    await panes.openApi(paneId: "api-1", entry: "e", environment: "s", origin: nil, credentialed: false)
    guard case .object(let idle) = await panes.readPane(paneId: "api-1", kind: "api")
    else { Issue.record("not an object"); return }
    #expect(idle["sending"] == .bool(false))
    _ = await panes.beginApiSend(paneId: "api-1", method: "GET", at: Date())
    guard case .object(let busy) = await panes.readPane(paneId: "api-1", kind: "api")
    else { Issue.record("not an object"); return }
    #expect(busy["sending"] == .bool(true))
}

@Test("Send becomes Cancel, counting, while a send is in flight")
func sendBecomesCancel() {
    let since = Date(timeIntervalSince1970: 0)
    let control = apiSendControl(
        method: "GET", sending: ApiSending(since: since, method: "GET"),
        now: since.addingTimeInterval(1.23))
    #expect(control.action == "api_cancel")
    #expect(control.label == "Cancel · 1.2 s")
    #expect(apiCancelledLine(waitedMs: 4200) == "cancelled after 4.2 s")
}

@Test("Recent's label: a cancelled read is 'cancelled', a cancelled mutation may have landed")
func recentLabelsACancelledSendByItsMethod() {
    func row(_ method: String) -> ApiRecentRow {
        ApiRecentRow(
            method: method, entry: "e", environment: "staging", path: "/x", status: nil,
            durationMs: 4200, draft: .empty, cancelled: true)
    }
    #expect(apiRecentRowLabel(row("GET")) == "GET /x · cancelled · 4200 ms")
    #expect(apiRecentRowLabel(row("DELETE")) == "DELETE /x · cancelled — may have landed · 4200 ms")
}

private struct CancelWindowLookup: ProviderCredentialsLookup {
    func credentials(forProvider id: String) async throws -> ProviderCredentials {
        ProviderCredentials(
            claudePath: "/usr/bin/true", configDir: "/dev/null", oauthToken: "test-only")
    }
}

/// F1 (preflight): the window re-reads panes when a dispatch FINISHES, and a send's flight is the
/// whole of its dispatch. So the start and the end of a flight are signalled on their own, and
/// the window re-reads on each — or Send could never read Cancel. Driven from the agent's
/// channel, which no window path refreshes for.
@Test("The window sees a send in flight before it completes, and sees it end", .timeLimit(.minutes(1)))
@MainActor
func theWindowSeesASendInFlight() async throws {
    let dir = testScratchRoot.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let registry = ActionRegistry(journalDirectory: dir, sessionId: "t")
    let panes = PaneStore()
    let layout = LayoutStore()
    await registerApiActions(
        into: registry, panes: panes, layout: layout, http: StallingHTTP(),
        activeContext: { ("initech", "proj", "staging", "/tmp") })
    let opened = try await dispatch(registry, "api_open", [:])
    guard case .object(let f) = opened, case .string(let pane)? = f["pane"] else {
        throw CancelFixtureFailed()
    }
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: NSTemporaryDirectory(), providerId: "main", lookup: CancelWindowLookup())
    // Final review 8: a thrown `#require` below must not leak the window's pumps.
    defer { await model.shutdown() }
    // The window subscribes from a `Task` its `init` starts; a flight begun before it listens
    // would be announced to nobody.
    try #require(await apiEventually { await panes.apiFlightSubscriberCount > 0 })

    let send = Task { try await dispatch(registry, "api_request", ["pane": .string(pane)]) }
    try #require(await apiEventually { await panes.apiSnapshot(paneId: pane).sending != nil })
    // The dispatch is still parked: only a flight signal can have refreshed the window.
    try #require(await apiEventually { model.api(pane)?.sending != nil })

    _ = try await dispatch(registry, "api_cancel", ["pane": .string(pane)])
    _ = try await send.value
    try #require(await apiEventually { model.api(pane)?.sending == nil })
    #expect(model.api(pane)?.response.state == "cancelled")
}

/// Final review 5: Cancel pressed just as the reply lands reaches a pane with nothing in flight.
/// The operator's press is answered by the reply already on screen, so the refusal is not put on
/// the status line. An agent's `api_cancel` is still refused in words
/// (`cancelWithNothingInFlightIsRefused`).
@Test("Cancel from the window with nothing in flight is silent", .timeLimit(.minutes(1)))
@MainActor
func cancelFromTheWindowWithNothingInFlightIsSilent() async throws {
    let (registry, panes, pane) = try await cancelFixture(StallingHTTP())
    let model = WindowModel(
        registry: registry, panes: panes, layout: LayoutStore(), context: nil,
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: NSTemporaryDirectory(), providerId: "main", lookup: CancelWindowLookup())
    defer { await model.shutdown() }
    let landed = await model.enqueueFromSurface(pane: pane, building: { _ in
        [("api_cancel", .object(["pane": .string(pane)]))]
    }).value
    #expect(!landed)
    #expect(model.status == "")
    // Any other refusal from the window still reaches the status line.
    _ = await model.enqueueFromSurface(pane: pane, building: { _ in
        [("api_set_request", .object(["pane": .string(pane), "method": .string("")]))]
    }).value
    #expect(model.status.contains("api_set_request"))
}

@Test("Only the window's nothing-in-flight refusal of api_cancel is silent")
func onlyTheNothingInFlightRefusalIsSilent() {
    #expect(apiSurfaceRefusalIsSilent(ApiActionError.nothingInFlight(action: "api_cancel")))
    #expect(!apiSurfaceRefusalIsSilent(ApiActionError.sendInFlight(action: "api_request")))
    #expect(!apiSurfaceRefusalIsSilent(CancelFixtureFailed()))
}

/// Fix round 1: pane ids are per scope, so a reply finds its pane by the flight's token. A send
/// left from project A's `api-1` lands there, and project B's own `api-1` — in flight itself —
/// is untouched, its flight and its canceller still its own.
@Test("A reply lands on the pane it left from, not on another scope's pane with its id")
func aReplyLandsInTheScopeItLeftFrom() async throws {
    let a = LayoutScope(organization: "o", project: "a", environment: "dev")
    let b = LayoutScope(organization: "o", project: "b", environment: "dev")
    let panes = PaneStore()
    await panes.switchScope(to: a)
    await panes.openApi(paneId: "api-1", entry: "e", environment: "staging", origin: nil, credentialed: false)
    let sentFromA = try #require(await panes.beginApiSend(paneId: "api-1", method: "GET", at: Date()))

    await panes.switchScope(to: b)
    await panes.openApi(paneId: "api-1", entry: "e", environment: "staging", origin: nil, credentialed: false)
    let sentFromB = try #require(await panes.beginApiSend(paneId: "api-1", method: "GET", at: Date()))
    let cancelledB = Cancelled()
    await panes.armApiSend(paneId: "api-1", token: sentFromB) { cancelledB.mark() }
    // A's canceller, armed late, belongs to A's flight and does not replace B's.
    let cancelledA = Cancelled()
    await panes.armApiSend(paneId: "api-1", token: sentFromA) { cancelledA.mark() }

    let reply = ApiResponseSnapshot.ok(ApiResponseOK(
        status: 201, url: "https://a/x", environment: "staging", headers: [:], body: "",
        durationMs: 5, byteCount: 0, truncated: false))
    await panes.finishApiSend(
        paneId: "api-1", token: sentFromA, outcome: ApiRequestOutcome(draft: .empty, response: reply))

    // B, the active scope: still in flight, no reply, no row, and its own canceller.
    let inB = await panes.apiSnapshot(paneId: "api-1")
    #expect(inB.sending != nil)
    #expect(inB.response == .none)
    #expect(inB.recent.isEmpty)
    #expect(await panes.cancelApiSend(paneId: "api-1"))
    #expect(cancelledB.count == 1)
    #expect(cancelledA.count == 0)

    // A: the reply and its row, and the flight over.
    await panes.switchScope(to: a)
    let inA = await panes.apiSnapshot(paneId: "api-1")
    #expect(inA.sending == nil)
    #expect(inA.response.status == 201)
    #expect(inA.recent.count == 1)
}

/// Counts calls to a canceller, from any thread.
private final class Cancelled: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    func mark() { lock.lock(); calls += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
}

/// Final review minor 9: who sent is read from who is calling, as a db read's maker is
/// (`DBFlightMakerTests`). An org switch stops the operator's sends in the org it leaves —
/// they went out on the window's `wakil-http`, which it re-points — and leaves an agent's,
/// which run on the client pinned to its own place.
@Test("An org switch's cancel stops the operator's send and leaves an agent's", .timeLimit(.minutes(1)))
func anOrgSwitchCancelsOnlyTheOperatorsSend() async throws {
    for (caller, byOperator) in [
        (DispatchCaller.test("staging"), true),
        (DispatchCaller.test("staging", session: "agent-session"), false),
    ] {
        let (registry, panes, pane) = try await cancelFixture(StallingHTTP())
        let send = Task {
            try await registry.dispatch(
                name: "api_request", params: .object(["pane": .string(pane)]), origin: .agent,
                caller: caller, confirmation: nil)
        }
        try #require(await apiEventually { await panes.apiSnapshot(paneId: pane).sending != nil })

        await panes.cancelOperatorApiSends(inOrganization: LayoutScope.initial.organization)

        if byOperator {
            #expect(await apiEventually { await panes.apiSnapshot(paneId: pane).sending == nil },
                    "the operator's send is stopped")
        } else {
            #expect(await panes.apiSnapshot(paneId: pane).sending != nil, "the agent's send runs on")
            send.cancel()
        }
        _ = try? await send.value
    }
}
