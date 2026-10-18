import Foundation
import Testing
@testable import WakilKit

/// Amendment 11, Task 4: `api_fill_from_curl` and `api_undo_fill` through the registry.

/// A `wakil-http` for the paste: `parse_curl` and `locate_api_url` answer canned replies,
/// `list_apis` answers `billing` and `catalog`, and every call is recorded.
actor CurlHTTP: ToolCaller {
    private(set) var calls: [(name: String, arguments: JSONValue)] = []
    var parseReply: JSONValue
    var locateReply: JSONValue

    init(parse: JSONValue = curlParsed(), locate: JSONValue = curlLocated()) {
        parseReply = .object(["structuredContent": parse])
        locateReply = .object(["structuredContent": locate])
    }

    func answerParse(_ reply: JSONValue) { parseReply = reply }
    func answerLocate(_ structured: JSONValue) { locateReply = .object(["structuredContent": structured]) }
    func names() -> [String] { calls.map(\.name) }

    func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        calls.append((name, arguments))
        switch name {
        case "list_apis":
            return .object(["structuredContent": .object(["apis": .array([
                .object(["name": .string("billing"), "baseUrl": .string("https://billing.example.com"),
                         "authenticated": .bool(true)]),
                .object(["name": .string("catalog"), "baseUrl": .string("https://api.example.com"),
                         "authenticated": .bool(false)]),
            ])])])
        case "parse_curl": return parseReply
        case "locate_api_url": return locateReply
        default: return .null
        }
    }
}

/// `parse_curl`'s answer for a POST to billing, with a credential dropped.
func curlParsed(body: String = "{\"a\":1}") -> JSONValue {
    .object([
        "method": .string("POST"),
        "url": .string("https://billing.example.com/v1/charges?paid=true"),
        "headers": .array([
            .object(["name": .string("X-Trace"), "value": .string("7")]),
            .object(["name": .string("Content-Type"), "value": .string("application/json")]),
        ]),
        "body": .string(body),
        "hasBody": .bool(true),
        "dropped": .array([.object(["name": .string("Authorization")])]),
    ])
}

/// `locate_api_url`'s answer: billing, in the active environment.
func curlLocated() -> JSONValue {
    .object([
        "found": .bool(true), "active": .bool(true), "environment": .string("staging"),
        "entry": .string("billing"), "path": .string("/v1/charges?paid=true"),
        "host": .string("billing.example.com"),
        "entries": .array([.string("billing"), .string("catalog")]),
    ])
}

/// What a fill of `curlParsed()` writes.
private func filledDraft() -> ApiDraft {
    var draft = ApiDraft.empty
    draft.entry = "billing"
    draft.method = "POST"
    draft.path = [.literal("/v1/charges")]
    draft.query = [ApiQueryRow(name: "paid", value: [.literal("true")])]
    draft.headers = [ApiHeaderRow(name: "X-Trace", value: [.literal("7")])]
    draft.contentType = "application/json"
    draft.body = [.literal("{\"a\":1}")]
    return draft
}

private struct CurlRig {
    let registry: ActionRegistry
    let panes: PaneStore
    let layout: LayoutStore
    let http: CurlHTTP
    let pane: String
    let journal: URL

    @discardableResult
    func fill(_ text: String = "curl -X POST https://billing.example.com/v1/charges",
              origin: ActionOrigin = .ui) async throws -> [String: JSONValue] {
        let reply = try await registry.dispatch(
            name: "api_fill_from_curl",
            params: .object(["pane": .string(pane), "text": .string(text)]),
            origin: origin, caller: .test("staging"), confirmation: nil)
        guard case .object(let fields) = reply else { return [:] }
        return fields
    }

    @discardableResult
    func undo(origin: ActionOrigin = .ui) async throws -> JSONValue {
        try await registry.dispatch(
            name: "api_undo_fill", params: .object(["pane": .string(pane)]),
            origin: origin, caller: .test("staging"), confirmation: nil)
    }
}

/// A pane opened on `entry`, with the registry wired to a `CurlHTTP`.
private func curlRig(entry: String = "billing", http: CurlHTTP = CurlHTTP()) async throws -> CurlRig {
    let dir = testScratchRoot.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let registry = ActionRegistry(journalDirectory: dir, sessionId: "t")
    let panes = PaneStore()
    let layout = LayoutStore()
    await registerApiActions(
        into: registry, panes: panes, layout: layout, http: http,
        activeContext: { ("initech", "proj", "staging", "/tmp") })
    let opened = try await registry.dispatch(
        name: "api_open", params: .object(["entry": .string(entry)]), origin: .ui,
        caller: .test("staging"), confirmation: nil)
    guard case .object(let f) = opened, case .string(let pane)? = f["pane"] else {
        throw CurlRigFailed()
    }
    return CurlRig(registry: registry, panes: panes, layout: layout, http: http, pane: pane, journal: dir)
}

private struct CurlRigFailed: Error {}

private func sentOK() -> ApiResponseSnapshot {
    .ok(ApiResponseOK(
        status: 200, url: "https://billing.example.com/v1/charges", environment: "staging",
        headers: [:], body: "{}", durationMs: 5, byteCount: 2, truncated: false))
}

@Test("A fill writes the whole draft and answers the line's parts")
func aFillWritesTheWholeDraft() async throws {
    let rig = try await curlRig()
    let reply = try await rig.fill()
    #expect(await rig.panes.apiDraft(paneId: rig.pane) == filledDraft())
    #expect(reply["entry"] == .string("billing"))
    #expect(reply["switched"] == .bool(false))
    #expect(reply["dropped"] == .array([.string("Authorization")]))
    #expect(reply["line"] == .string("Filled from cURL · billing · dropped: Authorization"))
    // parse_curl read the text; locate_api_url placed the URL parse_curl found.
    let calls = await rig.http.calls
    #expect(calls.first { $0.name == "parse_curl" }?.arguments
        == .object(["text": .string("curl -X POST https://billing.example.com/v1/charges")]))
    #expect(calls.first { $0.name == "locate_api_url" }?.arguments
        == .object(["url": .string("https://billing.example.com/v1/charges?paid=true")]))
}

@Test("A fill to another entry switches the pane and retitles it")
func aFillToAnotherEntrySwitches() async throws {
    let rig = try await curlRig(entry: "catalog")
    let reply = try await rig.fill()
    let snapshot = await rig.panes.apiSnapshot(paneId: rig.pane)
    #expect(snapshot.entry == "billing")
    #expect(snapshot.request.origin == "https://billing.example.com")
    #expect(snapshot.credentialed)
    #expect(reply["switched"] == .bool(true))
    let title = await rig.layout.snapshot().panes.first { $0.id == rig.pane }?.title
    #expect(title == "billing")
}

@Test("A refused fill leaves the draft untouched and throws the refusal")
func aRefusedFillLeavesTheDraft() async throws {
    let rig = try await curlRig()
    await rig.http.answerLocate(.object([
        "found": .bool(false), "active": .bool(false), "environment": .string("staging"),
        "host": .string("api.other.com"),
        "entries": .array([.string("billing"), .string("catalog")]),
    ]))
    let before = await rig.panes.apiDraft(paneId: rig.pane)
    do {
        try await rig.fill()
        Issue.record("the fill landed")
    } catch {
        #expect(String(describing: error).contains("no entry in staging has that host"))
    }
    #expect(await rig.panes.apiDraft(paneId: rig.pane) == before)
    // C1: a refusal sets no pane state — it reaches the operator through the outcome.
    let snapshot = await rig.panes.apiSnapshot(paneId: rig.pane)
    #expect(snapshot.fillLine == nil)
    #expect(!snapshot.fillUndoable)
}

@Test("Undo puts back the draft the fill replaced, and forgets it")
func undoPutsBackTheDraft() async throws {
    let rig = try await curlRig(entry: "catalog")
    var original = await rig.panes.apiDraft(paneId: rig.pane)
    original.method = "DELETE"
    original.path = [.literal("/items/9")]
    await rig.panes.setApiDraft(paneId: rig.pane, draft: original)
    try await rig.fill()
    let reply = try await rig.undo()
    #expect(await rig.panes.apiDraft(paneId: rig.pane) == original)
    #expect(reply == .object(["pane": .string(rig.pane), "entry": .string("catalog")]))
    // The entry came back, and with it the origin, the credential and the title.
    let snapshot = await rig.panes.apiSnapshot(paneId: rig.pane)
    #expect(snapshot.request.origin == "https://api.example.com")
    #expect(!snapshot.credentialed)
    #expect(await rig.layout.snapshot().panes.first { $0.id == rig.pane }?.title == "catalog")
    do {
        try await rig.undo()
        Issue.record("a second undo landed")
    } catch {
        #expect(String(describing: error).contains("nothing to undo"))
    }
}

@Test("Undo brings back a binding the fill replaced")
func undoRestoresABindingTheFillReplaced() async throws {
    let rig = try await curlRig()
    var original = await rig.panes.apiDraft(paneId: rig.pane)
    original.path = [.literal("/bookings/"), .bound(liveBinding(name: "id", generation: 7))]
    original.body = [.literal("{\"note\":"), .bound(liveBinding(name: "note")), .literal("}")]
    await rig.panes.setApiDraft(paneId: rig.pane, draft: original)
    try await rig.fill()
    #expect(await rig.panes.apiDraft(paneId: rig.pane) != original)
    try await rig.undo()
    let restored = await rig.panes.apiDraft(paneId: rig.pane)
    #expect(restored == original)
    #expect(restored.path[1] == .bound(liveBinding(name: "id", generation: 7)))
}

@Test("Any other write forgets the kept draft")
func anyOtherWriteForgetsTheKeptDraft() async throws {
    let rig = try await curlRig()
    try await rig.fill()
    _ = try await rig.registry.dispatch(
        name: "api_set_request",
        params: .object(["pane": .string(rig.pane), "method": .string("PUT")]),
        origin: .ui, caller: .test("staging"), confirmation: nil)
    await #expect(throws: (any Error).self) { try await rig.undo() }

    // Forgotten at the PRESS: Undo after Send must not put back a draft from before a request
    // that has already left.
    try await rig.fill()
    _ = try #require(await rig.panes.beginApiSend(paneId: rig.pane, method: "POST", at: Date()))
    do {
        try await rig.undo()
        Issue.record("undo after a Send landed")
    } catch {
        #expect(String(describing: error).contains("nothing to undo"))
    }
}

@Test("An agent fill while the operator is in a field is Decision 27's refusal")
func anAgentFillUnderTheOperatorsHandIsRefused() async throws {
    let rig = try await curlRig()
    await rig.panes.setApiFocus(paneId: rig.pane, fields: [.path], generation: 1)
    let before = await rig.panes.apiDraft(paneId: rig.pane)
    do {
        try await rig.fill(origin: .agent)
        Issue.record("the agent's fill landed under the operator's hand")
    } catch {
        #expect(String(describing: error).contains("the operator is editing Path"))
    }
    #expect(await rig.panes.apiDraft(paneId: rig.pane) == before)
    #expect(await rig.panes.apiKeptDraft(paneId: rig.pane) == nil)
    // Refused before parse_curl was asked: nothing about the text left the app.
    #expect(!(await rig.http.names().contains("parse_curl")))
    // The operator's own paste lands.
    try await rig.fill(origin: .ui)
    #expect(await rig.panes.apiDraft(paneId: rig.pane) == filledDraft())
}

@Test("The pasted text is journalled as redacted")
func thePastedTextIsJournalledRedacted() async throws {
    let rig = try await curlRig()
    try await rig.fill("curl -u admin:s3cr3t https://billing.example.com/v1/charges")
    let files = try FileManager.default.contentsOfDirectory(at: rig.journal, includingPropertiesForKeys: nil)
    let text = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
    #expect(text.contains("api_fill_from_curl"))
    #expect(!text.contains("s3cr3t"))
    #expect(text.contains("[redacted]"))
}

@Test("parse_curl's refusal is the fill's refusal")
func parseCurlsRefusalIsTheFills() async throws {
    let rig = try await curlRig()
    await rig.http.answerParse(.object([
        "isError": .bool(true),
        "content": .array([.object(["type": .string("text"), "text": .string("not a cURL command")])]),
    ]))
    do {
        try await rig.fill("curl")
        Issue.record("the fill landed")
    } catch {
        #expect(String(describing: error).contains("not a cURL command"))
    }
    #expect(!(await rig.http.names().contains("locate_api_url")))
}

// MARK: - C1: the fill's line and Undo are pane state

@Test("After a fill the snapshot carries the line and Undo; an agent's fill shows the same")
func aFillsLineIsPaneState() async throws {
    let rig = try await curlRig()
    try await rig.fill(origin: .agent)
    let snapshot = await rig.panes.apiSnapshot(paneId: rig.pane)
    #expect(snapshot.fillLine == "Filled from cURL · billing · dropped: Authorization")
    #expect(snapshot.fillUndoable)
    #expect(await rig.panes.apiFillLine(paneId: rig.pane) == snapshot.fillLine)
}

@Test("api_set_request, a Send and an undo each clear the line and Undo")
func theLineClearsWithTheKeptDraft() async throws {
    func cleared(_ rig: CurlRig) async -> Bool {
        let s = await rig.panes.apiSnapshot(paneId: rig.pane)
        return s.fillLine == nil && !s.fillUndoable
    }
    let rig = try await curlRig()
    try await rig.fill()
    #expect(!(await cleared(rig)))
    _ = try await rig.registry.dispatch(
        name: "api_set_request",
        params: .object(["pane": .string(rig.pane), "method": .string("PUT")]),
        origin: .ui, caller: .test("staging"), confirmation: nil)
    #expect(await cleared(rig))

    try await rig.fill()
    let token = try #require(await rig.panes.beginApiSend(paneId: rig.pane, method: "POST", at: Date()))
    #expect(await cleared(rig))
    await rig.panes.finishApiSend(
        paneId: rig.pane, token: token, outcome: ApiRequestOutcome(draft: filledDraft(), response: sentOK()))

    try await rig.fill()
    try await rig.undo()
    #expect(await cleared(rig))
}

@Test("read_pane's shape is unchanged by a fill")
func readPaneHasNoNewKeyAfterAFill() async throws {
    let rig = try await curlRig()
    try await rig.fill()
    let filled = await rig.panes.readPane(paneId: rig.pane, kind: "api")
    // The same draft, written plainly, on a pane that was never filled.
    let plain = PaneStore()
    let opened = await rig.panes.apiSnapshot(paneId: rig.pane)
    await plain.openApi(
        paneId: rig.pane, entry: "billing", environment: "staging",
        origin: opened.request.origin, credentialed: opened.credentialed, entries: opened.entries)
    await plain.setApiDraft(paneId: rig.pane, draft: filledDraft())
    let written = await plain.readPane(paneId: rig.pane, kind: "api")
    #expect(filled == written)
}

@Test("A fill made while a Send is in flight keeps its Undo when the reply lands")
func aFillDuringASendSurvivesTheReply() async throws {
    let rig = try await curlRig(entry: "catalog")
    let sent = await rig.panes.apiDraft(paneId: rig.pane)
    let token = try #require(await rig.panes.beginApiSend(paneId: rig.pane, method: "GET", at: Date()))
    try await rig.fill()
    await rig.panes.finishApiSend(
        paneId: rig.pane, token: token, outcome: ApiRequestOutcome(draft: sent, response: sentOK()))
    let snapshot = await rig.panes.apiSnapshot(paneId: rig.pane)
    #expect(snapshot.fillLine == "Filled from cURL · billing · dropped: Authorization")
    #expect(snapshot.fillUndoable)
    try await rig.undo()
    #expect(await rig.panes.apiDraft(paneId: rig.pane) == sent)
}

@Test("A Send refused before it leaves keeps the fill's Undo")
func aRefusedSendKeepsTheUndo() async throws {
    let rig = try await curlRig()
    try await rig.fill()
    // A second send is refused at beginApiSend, so it never leaves and forgets nothing.
    let token = try #require(await rig.panes.beginApiSend(paneId: rig.pane, method: "POST", at: Date()))
    try await rig.fill()
    #expect(await rig.panes.beginApiSend(paneId: rig.pane, method: "POST", at: Date()) == nil)
    #expect(await rig.panes.apiSnapshot(paneId: rig.pane).fillUndoable)
    await rig.panes.finishApiSend(
        paneId: rig.pane, token: token, outcome: ApiRequestOutcome(draft: filledDraft(), response: sentOK()))
    #expect(await rig.panes.apiSnapshot(paneId: rig.pane).fillUndoable)
}
