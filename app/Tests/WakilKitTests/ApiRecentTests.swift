import Foundation
import Testing
@testable import WakilKit

/// The pane's past tense — `recent` (#195), Phase 4.
///
/// **Three tenses, one rule.** The draft is the future, the response is
/// the present, and the strip is the past. A relaunch and an environment
/// switch both clear only the PRESENT — which is what makes the switch's
/// three outcomes one rule rather than three coincidences.
///
/// **Rows, never bodies.** The near neighbour is the terminal pane's block
/// history, ruled ephemeral and capped long ago — not the db grid, which
/// persists and pages.

private func okResponse(_ n: Int, environment: String = "staging") -> ApiResponseSnapshot {
    .ok(ApiResponseOK(
        status: 200, url: "https://billing.example.com/bookings/\(n)",
        environment: environment, headers: [:], body: "{\"id\":\(n)}",
        durationMs: 10 + n, byteCount: 8, truncated: false))
}

private func aDraft(method: String = "GET", path: String = "/bookings/1") -> ApiDraft {
    var draft = ApiDraft.empty
    draft.entry = "billing"
    draft.method = method
    draft.path = [.literal(path)]
    return draft
}

@Test("The strip caps at 200, folds behind a count, and carries no body")
func recentIsRowsNeverBodies() async throws {
    let panes = PaneStore()
    await panes.openApi(
        paneId: "api1", entry: "billing", environment: "staging", origin: nil, credentialed: true)

    for n in 1...205 {
        await panes.recordApiSend(
            paneId: "api1", draft: aDraft(path: "/bookings/\(n)"), response: okResponse(n))
    }

    let snapshot = await panes.apiSnapshot(paneId: "api1")
    #expect(snapshot.recent.count == 200)
    // A short history and a trimmed one must never look alike.
    #expect(snapshot.recentTruncated == true)

    // **Rows, never bodies.** A strip that held bodies would be a log of
    // every payload the pane has ever received, in memory, for a surface
    // that cannot search them.
    let first = try #require(snapshot.recent.first)
    #expect(first.status == 200)
    #expect(first.method == "GET")
    #expect(first.environment == "staging")
    #expect(first.path.contains("/bookings/"))
}

@Test("The newest send is first, and the oldest is what falls off the end")
func recentIsNewestFirst() async throws {
    let panes = PaneStore()
    await panes.openApi(
        paneId: "api1", entry: "billing", environment: "staging", origin: nil, credentialed: true)
    for n in 1...3 {
        await panes.recordApiSend(
            paneId: "api1", draft: aDraft(path: "/bookings/\(n)"), response: okResponse(n))
    }

    let recent = await panes.apiSnapshot(paneId: "api1").recent
    #expect(recent.map(\.path) == ["/bookings/3", "/bookings/2", "/bookings/1"])
}

@Test("A row joins recent only when the send had an outcome — a refusal never does")
func aRefusalIsNotPastTense() async throws {
    let panes = PaneStore()
    await panes.openApi(
        paneId: "api1", entry: "billing", environment: "staging", origin: nil, credentialed: true)

    await panes.recordApiSend(
        paneId: "api1", draft: aDraft(),
        response: .refusal(ApiSendRefusal(failures: [
            ApiSendFailure(region: .path, message: "unfilled")
        ])))

    // Nothing was sent, so there is no past tense to record. A refusal in
    // the strip would be a history of things that never happened.
    #expect(await panes.apiSnapshot(paneId: "api1").recent.isEmpty)
}

@Test("A transport failure and a fate-unknown DO join recent — something left, or may have")
func whatLeftIsRecordedEvenWhenItFailed() async throws {
    let panes = PaneStore()
    await panes.openApi(
        paneId: "api1", entry: "billing", environment: "staging", origin: nil, credentialed: true)

    await panes.recordApiSend(
        paneId: "api1", draft: aDraft(method: "POST"),
        response: .transport(ApiTransportFailure(
            stage: "connect", waitedMs: 30, reason: "refused", environment: "staging")))
    await panes.recordApiSend(
        paneId: "api1", draft: aDraft(method: "PUT"),
        response: .unknown(ApiFateUnknown(reason: "no client", environment: "staging")))

    let recent = await panes.apiSnapshot(paneId: "api1").recent
    #expect(recent.count == 2)
    // A failure has no status, and the row says so rather than inventing
    // a zero — the same rule the response state carries.
    #expect(recent.allSatisfy { $0.status == nil })
    #expect(Set(recent.map(\.method)) == ["POST", "PUT"])
}

@Test("W15: each environment keeps its own Recent, and a row is filed where it ran")
func eachEnvironmentKeepsItsOwnRecent() async throws {
    let panes = PaneStore()
    await panes.openApi(
        paneId: "api1", entry: "billing", environment: "staging", origin: nil, credentialed: true)
    await panes.recordApiSend(
        paneId: "api1", draft: aDraft(), response: okResponse(1, environment: "staging"))
    await panes.clearApiResponses(to: "production")
    await panes.recordApiSend(
        paneId: "api1", draft: aDraft(), response: okResponse(2, environment: "production"))
    #expect(await panes.apiSnapshot(paneId: "api1").recent.map(\.environment) == ["production"])
    await panes.clearApiResponses(to: "staging")
    #expect(await panes.apiSnapshot(paneId: "api1").recent.map(\.environment) == ["staging"])
}

@Test("An environment switch clears the present and leaves the past where it ran")
func aSwitchLeavesThePastAlone() async throws {
    let panes = PaneStore()
    await panes.openApi(
        paneId: "api1", entry: "billing", environment: "staging", origin: nil, credentialed: true)
    let draft = aDraft()
    await panes.setApiDraft(paneId: "api1", draft: draft)
    let sent = okResponse(1)
    await panes.setApiResponse(paneId: "api1", response: sent)
    await panes.recordApiSend(paneId: "api1", draft: draft, response: sent)

    await panes.clearApiResponses(to: "production")
    let away = await panes.apiSnapshot(paneId: "api1")
    #expect(away.response.state == "cleared")
    #expect(away.request.method == "GET")
    #expect(away.recent.isEmpty)
    await panes.clearApiResponses(to: "staging")
    #expect(await panes.apiSnapshot(paneId: "api1").recent.count == 1)
}

@Test("W15: every api pane of one project and environment shares one Recent")
func recentIsSharedAcrossPanes() async throws {
    let panes = PaneStore()
    for id in ["api1", "api2"] {
        await panes.openApi(
            paneId: id, entry: "billing", environment: "staging", origin: nil, credentialed: true)
    }
    await panes.recordApiSend(paneId: "api1", draft: aDraft(path: "/bookings/41"), response: okResponse(41))
    #expect(await panes.apiSnapshot(paneId: "api2").recent.map(\.path) == ["/bookings/41"])
}

@Test("W15: another project has its own Recent")
func anotherProjectHasItsOwn() async throws {
    let panes = PaneStore()
    await panes.switchScope(to: LayoutScope(organization: "initech", project: "a"))
    await panes.openApi(
        paneId: "api1", entry: "billing", environment: "staging", origin: nil, credentialed: true)
    await panes.recordApiSend(paneId: "api1", draft: aDraft(), response: okResponse(1))
    await panes.switchScope(to: LayoutScope(organization: "initech", project: "b"))
    await panes.openApi(
        paneId: "api1", entry: "billing", environment: "staging", origin: nil, credentialed: true)
    #expect(await panes.apiSnapshot(paneId: "api1").recent.isEmpty)
}

@Test("W15: Reopen loads into the pane it is pressed in, and the cap is shared")
func reopenLoadsIntoThePanePressed() async throws {
    let panes = PaneStore()
    for id in ["api1", "api2"] {
        await panes.openApi(
            paneId: id, entry: "billing", environment: "staging", origin: nil, credentialed: true)
    }
    await panes.recordApiSend(paneId: "api1", draft: aDraft(path: "/bookings/7"), response: okResponse(7))
    let row = try #require(await panes.apiSnapshot(paneId: "api2").recent.first)
    #expect(await panes.reopenApiRow(paneId: "api2", rowId: row.id) != nil)
    #expect(await panes.apiDraft(paneId: "api2").path == [.literal("/bookings/7")])
    #expect(await panes.apiDraft(paneId: "api1").path == [])
    for n in 1...PaneStore.recentCap {
        await panes.recordApiSend(paneId: n.isMultiple(of: 2) ? "api1" : "api2",
                                  draft: aDraft(path: "/b/\(n)"), response: okResponse(n))
    }
    let shared = await panes.apiSnapshot(paneId: "api1")
    #expect(shared.recent.count == PaneStore.recentCap)
    #expect(shared.recentTruncated)
}

@Test("A recorded send keeps the path as it was shown")
func aRowKeepsItsShownPath() async throws {
    let panes = PaneStore()
    await panes.openApi(
        paneId: "api1", entry: "billing", environment: "staging", origin: nil, credentialed: true)
    await panes.recordApiSend(paneId: "api1", draft: aDraft(), response: okResponse(1),
                              shownPath: "/bookings/<id:1>")
    #expect(await panes.apiSnapshot(paneId: "api1").recent.first?.shownPath == "/bookings/<id:1>")
}

// MARK: - Task 11: api_reopen

@Test("Reopen takes a row id, so trimming the cap never reopens the wrong row")
func reopenIsKeyedNotPositional() async throws {
    let panes = PaneStore()
    await panes.openApi(
        paneId: "api1", entry: "billing", environment: "staging", origin: nil, credentialed: true)
    for n in 1...205 {
        await panes.recordApiSend(
            paneId: "api1", draft: aDraft(path: "/bookings/\(n)"), response: okResponse(n))
    }

    let recent = await panes.apiSnapshot(paneId: "api1").recent
    // The newest row, whose POSITION is 0 today and will not be after the
    // next send — which is the whole reason reopen is keyed.
    let target = try #require(recent.first)
    #expect(target.path == "/bookings/205")

    let reopened: ApiDraft = try #require(
        await panes.reopenApiRow(paneId: "api1", rowId: target.id))
    #expect(reopened.path == [ApiPart.literal("/bookings/205")])
    #expect(await panes.apiDraft(paneId: "api1").path == [.literal("/bookings/205")])
}

@Test("A row id that was trimmed off the end is refused, not silently reopened as another row")
func reopenRefusesATrimmedRow() async throws {
    let panes = PaneStore()
    await panes.openApi(
        paneId: "api1", entry: "billing", environment: "staging", origin: nil, credentialed: true)
    await panes.recordApiSend(
        paneId: "api1", draft: aDraft(path: "/bookings/1"), response: okResponse(1))
    let first = try #require(await panes.apiSnapshot(paneId: "api1").recent.first)

    // Push it off the end of the cap.
    for n in 2...(PaneStore.recentCap + 2) {
        await panes.recordApiSend(
            paneId: "api1", draft: aDraft(path: "/bookings/\(n)"), response: okResponse(n))
    }

    // An index would have reopened whatever moved into that slot. An id
    // cannot, so it says no.
    #expect(await panes.reopenApiRow(paneId: "api1", rowId: first.id) == nil)
}

@Test("Reopen always lands, even while the operator's cursor is in a field")
func reopenIsAWholeDraftGestureAndAlwaysLands() async throws {
    let panes = PaneStore()
    await panes.openApi(
        paneId: "api1", entry: "billing", environment: "staging", origin: nil, credentialed: true)
    await panes.recordApiSend(
        paneId: "api1", draft: aDraft(path: "/bookings/7"), response: okResponse(7))
    let row = try #require(await panes.apiSnapshot(paneId: "api1").recent.first)

    // The operator's cursor is in the path field.
    await panes.setApiFocus(paneId: "api1", fields: [.path], generation: 1)

    // **Deliberately NOT refused, and this is the one place in the pane
    // where that is true.** Decision 27 stops one author overwriting the
    // other's field; reopening is the operator's OWN whole-draft
    // gesture, so refusing it would mean refusing them their own click on
    // the grounds that they had been typing.
    let reopened = await panes.reopenApiRow(paneId: "api1", rowId: row.id)
    #expect(reopened != nil)
    #expect(await panes.apiDraft(paneId: "api1").path == [.literal("/bookings/7")])
    // **And the mark stays** (Decision 27 by focus, Amendment 9a):
    // reopening moves no cursor, and the field the cursor is in is still
    // under the operator's hand.
    #expect(await panes.apiFocus(paneId: "api1") == [.path])
}

// MARK: - Task 12: Copy as cURL

@Test("Copy as cURL works on a recent row, and names the credential it is missing")
func curlIsPastTenseOnly() async throws {
    let panes = PaneStore()
    await panes.openApi(
        paneId: "api1", entry: "billing", environment: "staging", origin: nil, credentialed: true)
    var draft = aDraft(method: "POST", path: "/bookings/41/confirm")
    draft.headers = [ApiHeaderRow(name: "x-trace", value: [.literal("abc")])]
    draft.contentType = "application/json"
    draft.body = [.literal("{\"ok\":true}")]
    let sent: ApiResponseSnapshot = .ok(ApiResponseOK(
        status: 200, url: "https://billing.example.com/bookings/41/confirm",
        environment: "staging", headers: [:], body: "{}", durationMs: 9, byteCount: 2,
        truncated: false))
    await panes.recordApiSend(paneId: "api1", draft: draft, response: sent)
    let row = try #require(await panes.apiSnapshot(paneId: "api1").recent.first)

    let line = apiRenderCurl(row: row, url: "https://billing.example.com/bookings/41/confirm")

    #expect(line.contains("curl"))
    #expect(line.contains("-X POST"))
    #expect(line.contains("https://billing.example.com/bookings/41/confirm"))
    #expect(line.contains("x-trace"))

    // **It names the credential it is missing rather than omitting it.**
    // A line that silently left the header out would be a second,
    // false read-back: it would 401 and the operator would debug the
    // endpoint rather than the copy.
    #expect(line.contains("credential not included"))
    // **And it names no scheme and no ref.** Neither is the operator's to
    // see here — #118's redaction rule — and a guessed `Bearer` would be
    // a scheme Wakil never confirmed.
    #expect(!line.contains("Bearer"))
    #expect(!line.contains("authRef"))
    #expect(!line.lowercased().contains("authorization:"))
}

@Test("A row that was never credentialed says nothing about a credential")
func curlOnlyMentionsACredentialThereWasOne() async throws {
    let panes = PaneStore()
    await panes.openApi(
        paneId: "api1", entry: "open", environment: "staging", origin: nil, credentialed: false)
    await panes.recordApiSend(
        paneId: "api1", draft: aDraft(), response: okResponse(1))
    let row = try #require(await panes.apiSnapshot(paneId: "api1").recent.first)

    let line = apiRenderCurl(row: row, url: "https://open.example.com/bookings/1", credentialed: false)
    // Nothing was supplied, so there is nothing missing — saying otherwise
    // would send the operator looking for a credential that never existed.
    #expect(!line.contains("credential not included"))
}

@Test("The rendered line is emitted, never parsed back — a body with quotes survives")
func curlEmitsAndNeverParses() async throws {
    let panes = PaneStore()
    await panes.openApi(
        paneId: "api1", entry: "billing", environment: "staging", origin: nil, credentialed: true)
    var draft = aDraft(method: "POST")
    draft.body = [.literal("{\"note\":\"he said \\\"hi\\\"\"}")]
    await panes.recordApiSend(paneId: "api1", draft: draft, response: okResponse(1))
    let row = try #require(await panes.apiSnapshot(paneId: "api1").recent.first)

    let line = apiRenderCurl(row: row, url: "https://billing.example.com/x")
    // The pasteboard is a fifth emit position with its own rule, not an
    // exception to the no-delimiter ruling: this is quoted for a shell
    // and Wakil never reads its own line back — a pasted cURL command is read by Go's parse_curl (Amendment 11), not by this emitter.
    #expect(line.contains("--data"))
    #expect(line.contains("'"))
}

@Test("W15: a row rendered from another pane keeps the credential its own send had")
func curlReadsTheRowsCredentialNotTheRenderingPanes() async throws {
    let dir = testScratchRoot.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let registry = ActionRegistry(journalDirectory: dir, sessionId: "t")
    let panes = PaneStore()
    await registerApiActions(
        into: registry, panes: panes, layout: LayoutStore(), http: StallingHTTP(),
        activeContext: { ("initech", "proj", "staging", "/tmp") })
    var ids: [String] = []
    for _ in 0..<2 {
        let opened = try await registry.dispatch(
            name: "api_open", params: .object([:]), origin: .agent, caller: .test("staging"),
            confirmation: nil)
        guard case .object(let f) = opened, case .string(let pane)? = f["pane"] else {
            Issue.record("api_open answered no pane"); return
        }
        ids.append(pane)
    }
    // Two entries in one scope: the first is credentialed, the second is not.
    await panes.openApi(
        paneId: ids[0], entry: "billing", environment: "staging", origin: nil, credentialed: true)
    await panes.openApi(
        paneId: ids[1], entry: "open", environment: "staging", origin: nil, credentialed: false)
    await panes.recordApiSend(paneId: ids[0], draft: aDraft(), response: okResponse(1))
    var openDraft = aDraft(path: "/public")
    openDraft.entry = "open"
    await panes.recordApiSend(paneId: ids[1], draft: openDraft, response: okResponse(2))

    func curl(from pane: String, row: String) async throws -> String {
        let reply = try await registry.dispatch(
            name: "api_render_curl", params: .object(["pane": .string(pane), "row": .string(row)]),
            origin: .agent, caller: .test("staging"), confirmation: nil)
        guard case .object(let f) = reply, case .string(let line)? = f["curl"] else { return "" }
        return line
    }
    let recent = await panes.apiSnapshot(paneId: ids[0]).recent
    let credentialedRow = try #require(recent.first { $0.entry == "billing" })
    let openRow = try #require(recent.first { $0.entry == "open" })
    #expect(credentialedRow.credentialed)
    #expect(!openRow.credentialed)
    // Rendered from the uncredentialed pane, the credentialed send still warns…
    #expect(try await curl(from: ids[1], row: credentialedRow.id).contains("credential not included"))
    // …and rendered from the credentialed pane, the open send does not.
    #expect(!(try await curl(from: ids[0], row: openRow.id).contains("credential not included")))
}
