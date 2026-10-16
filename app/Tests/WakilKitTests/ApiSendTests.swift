import Foundation
import Testing
@testable import WakilKit

/// The gated send — `api_send` (#194), Phase 3, and Phase 2's exit clause:
/// *"production costs a typed confirmation that staging does not"*.
///
/// **The send is two actions because `ActionKind` is fixed per action.**
/// One `.mutate` send would read the production price for every method and
/// price a `GET` at `.gate` — the exact inversion Decision 25 exists to
/// prevent. So `api_request` carries GET and HEAD at `.read`, and this
/// carries the mutation methods at `.mutate`.

private func sendFixture() async throws -> (ActionRegistry, PaneStore, String) {
    let registry = ActionRegistry(
        journalDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("api-send-\(UUID().uuidString)"),
        sessionId: "t")
    let panes = PaneStore()
    let layout = LayoutStore()
    let http = SendStubHTTP(reply: .object([
        "structuredContent": .object([
            "apis": .array([
                .object([
                    "name": .string("billing"),
                    "baseUrl": .string("https://billing.example.com"),
                    "authenticated": .bool(true),
                ])
            ]),
        ]),
    ]))
    await registerApiActions(
        into: registry, panes: panes, layout: layout, http: http,
        activeContext: { ("initech", "proj", "staging", "/tmp") })
    let opened = try await registry.dispatch(
        name: "api_open", params: .object([:]), origin: .agent, environment: "staging",
        confirmation: nil)
    guard case .object(let fields) = opened, case .string(let paneId)? = fields["pane"] else {
        throw NoSendPane()
    }
    var draft = ApiDraft.empty
    draft.entry = "billing"
    draft.method = "POST"
    draft.path = [.literal("/bookings/41/confirm")]
    await panes.setApiDraft(paneId: paneId, draft: draft)
    return (registry, panes, paneId)
}

private struct NoSendPane: Error {}

private struct SendStubHTTP: ToolCaller, Sendable {
    let reply: JSONValue
    func callTool(
        name: String, arguments: JSONValue, timeout: TimeInterval
    ) async throws -> JSONValue { reply }
}

// MARK: - The exit clause

@Test("A mutation sends on one click outside production, and costs a typed confirmation in it")
func theExitClause() async throws {
    let (registry, panes, paneId) = try await sendFixture()
    let statement: JSONValue = .object([
        "pane": .string(paneId),
        "statement": .string("POST /bookings/41/confirm with no body"),
    ])

    // **The price is asserted through dispatch, not read off a
    // descriptor.** `ActionDescriptor` does not carry `price`, and the
    // effect is what matters: the default pair `(.block, .gate)` would
    // gate this staging send and block the production one outright, so
    // both halves below diverge only if `api_send` declares its own.
    _ = try await registry.dispatch(
        name: "api_send", params: statement,
        origin: .agent, environment: "staging", confirmation: nil)
    #expect(await panes.apiResponse(paneId: paneId).state != "none")

    // In production the same call, with no confirmation, does not run.
    await #expect(throws: (any Error).self) {
        _ = try await registry.dispatch(
            name: "api_send", params: statement,
            origin: .agent, environment: "production", confirmation: nil)
    }

    // And with one, it does — `.gate` rather than `.block`, which is the
    // difference between "costs a confirmation" and "cannot be done".
    _ = try await registry.dispatch(
        name: "api_send", params: statement,
        origin: .ui, environment: "production", confirmation: "confirm")

    // A GET never reaches the gate at all, in any environment — which is
    // why the send had to be split into two actions.
    let request = try #require(await registry.all().first { $0.name == "api_request" })
    #expect(request.kind == .read)
    let send = try #require(await registry.all().first { $0.name == "api_send" })
    #expect(send.kind == .mutate)
}

@Test("api_send refuses without a statement, because a gated mutate must have one to show")
func aGatedMutateNeedsItsStatement() async throws {
    let (registry, panes, paneId) = try await sendFixture()

    await #expect(throws: (any Error).self) {
        _ = try await registry.dispatch(
            name: "api_send", params: .object(["pane": .string(paneId)]),
            origin: .agent, environment: "staging", confirmation: nil)
    }
    #expect(await panes.apiResponse(paneId: paneId).state == "none")
}

@Test("api_send refuses a read method and names the action that owns it")
func apiSendRefusesAReadMethod() async throws {
    let (registry, panes, paneId) = try await sendFixture()
    var draft = await panes.apiDraft(paneId: paneId)
    draft.method = "GET"
    await panes.setApiDraft(paneId: paneId, draft: draft)

    await #expect(throws: (any Error).self) {
        _ = try await registry.dispatch(
            name: "api_send",
            params: .object([
                "pane": .string(paneId),
                "statement": .string("POST /bookings/41/confirm"),
            ]),
            origin: .agent, environment: "staging", confirmation: nil)
    }
}

@Test("Outside production a mutation sends without a confirmation")
func aStagingMutationSendsOnOneClick() async throws {
    let (registry, panes, paneId) = try await sendFixture()

    let result = try await registry.dispatch(
        name: "api_send",
        params: .object([
            "pane": .string(paneId),
            "statement": .string("POST /bookings/41/confirm with an empty body"),
        ]),
        origin: .agent, environment: "staging", confirmation: nil)

    guard case .object(let fields) = result else { Issue.record("no object"); return }
    // It went — the stub answers `list_apis`-shaped content with no
    // status, which is fate-unknown rather than a refusal. What matters
    // here is that the gate did not stop it.
    #expect(fields["state"] != .string("refusal"))
    #expect(await panes.apiResponse(paneId: paneId).state != "none")
}

// MARK: - The statement

@Test("The statement names the request Wakil puts on the wire, and the body's shape not its bytes")
func theStatementNamesTheShape() {
    var draft = ApiDraft.empty
    draft.entry = "billing"
    draft.method = "POST"
    draft.path = [.literal("/bookings/"), .slot("id"), .literal("/confirm")]
    draft.contentType = "application/merge-patch+json"
    draft.body = [.literal("{\"note\":\"a very long note that nobody wants in a plane\"}")]

    let statement = apiSendStatement(draft: draft, origin: "https://billing.example.com")

    #expect(statement.contains("POST"))
    #expect(statement.contains("billing.example.com"))
    // **The shape, never the bytes** — a large document must not make the
    // confirmation plane unreadable.
    #expect(!statement.contains("a very long note"))
    #expect(statement.contains("application/merge-patch+json"))
    // **It names the REQUEST, not the operation the server performs.**
    // Wakil cannot know what a POST does at the other end, and a
    // method-override header means the verb on the wire is not always the
    // operation — so the sentence promises only what Wakil is sending.
    #expect(statement.lowercased().contains("send"))
}

@Test("An empty body says so, rather than naming a content type nothing will carry")
func anEmptyBodyIsStatedAsEmpty() {
    var draft = ApiDraft.empty
    draft.entry = "billing"
    draft.method = "DELETE"
    draft.path = [.literal("/bookings/41")]

    let statement = apiSendStatement(draft: draft, origin: "https://billing.example.com")
    #expect(statement.contains("no body"))
    // Three wire states, not two: an empty body sends no body and no
    // content type.
    #expect(!statement.contains("content-type"))
}

@Test("W13: the plane names the URL that will leave and the body by its shape")
func theStatementNamesTheWholeRequest() {
    var draft = ApiDraft.empty
    draft.entry = "httpbin"
    draft.method = "POST"
    draft.path = [.literal("/test")]
    draft.query = [ApiQueryRow(name: "page", value: [.literal("2")])]
    draft.body = [.literal(#"{"test": 1, "customer_id": "#), .slot("id"), .literal("}")]
    #expect(apiSendStatement(draft: draft, origin: "https://httpbin.org")
        == "Send POST https://httpbin.org/test?page=2 with a JSON body {test, customer_id}")
}

@Test("W13: an array, text, nothing, a named content type", arguments: [
    ([ApiPart.literal("[1, 2, 3]")], "", "/x", "Send PUT https://h.example/x with a JSON array of 3"),
    ([.literal("[]")], "", "/x", "Send PUT https://h.example/x with a JSON array of 0"),
    ([.literal("not json at all")], "", "/x", "Send PUT https://h.example/x with 15 bytes of text"),
    ([], "", "/x", "Send PUT https://h.example/x with no body"),
    ([.literal(#"{"a":1}"#)], "application/merge-patch+json", "/x",
     "Send PUT https://h.example/x with a JSON body {a} as application/merge-patch+json"),
])
func theStatementShapes(body: [ApiPart], contentType: String, path: String, expected: String) {
    var draft = ApiDraft.empty
    draft.method = "PUT"
    draft.path = [.literal(path)]
    draft.contentType = contentType
    draft.body = body
    #expect(apiSendStatement(draft: draft, origin: "https://h.example") == expected)
}

@Test("A hole in the path is drawn by its name")
func aHoleInThePathIsDrawnByName() {
    var draft = ApiDraft.empty
    draft.method = "DELETE"
    draft.path = [.literal("/c/"), .slot("id")]
    #expect(apiSendStatement(draft: draft, origin: "https://h.example")
        == "Send DELETE https://h.example/c/<id> with no body")
}

@Test("A content type reaches the statement through apiSendParams")
func theSendParamsCarryTheContentType() {
    let snapshot = ApiRequestSnapshot(
        method: "POST", origin: "https://h.example", path: [.literal("/x")], query: [],
        headers: apiWakilHeaderRows(entry: "", contentType: "text/plain", credentialed: false),
        body: [.literal("hi")])
    let params = apiSendParams(draft: snapshot, pane: "api-1", origin: "https://h.example")
    guard case .object(let fields) = params else { Issue.record("not an object"); return }
    #expect(fields["statement"]
        == .string("Send POST https://h.example/x with 2 bytes of text as text/plain"))
}

// MARK: - Task 9: the line that names what left

private func journalLines(_ directory: URL, session: String = "t") throws -> [JournalEntry] {
    // `<sessionId>.jsonl`, which is what `ActionRegistry` actually writes.
    let file = directory.appendingPathComponent("\(session).jsonl")
    guard let data = try? Data(contentsOf: file) else { return [] }
    // **A plain decoder, matching the plain encoder `ActionRegistry`
    // uses.** Forcing `.iso8601` here made every line fail to decode and
    // the helper return an empty array — a test that reads nothing and
    // reports nothing wrong.
    let decoder = JSONDecoder()
    return String(decoding: data, as: UTF8.self)
        .split(separator: "\n")
        .compactMap { try? decoder.decode(JournalEntry.self, from: Data($0.utf8)) }
}

@Test("The journal records the URL that left, and only when one did")
func theJournalRecordsWhatLeft() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("api-send-journal-\(UUID().uuidString)")
    let registry = ActionRegistry(journalDirectory: directory, sessionId: "t")
    let panes = PaneStore()
    let layout = LayoutStore()
    let http = SendStubHTTP(reply: .object([
        "structuredContent": .object([
            // `api_open` reads this to resolve the entry; the send reads
            // the same stub and finds a status, which is what makes the
            // second half of this test an `ok`.
            "apis": .array([
                .object([
                    "name": .string("billing"),
                    "baseUrl": .string("https://billing.example.com"),
                    "authenticated": .bool(true),
                ])
            ]),
            "status": .number(200),
            "url": .string("https://billing.example.com/bookings/41/confirm"),
            "body": .string("{}"),
        ]),
    ]))
    await registerApiActions(
        into: registry, panes: panes, layout: layout, http: http,
        activeContext: { ("initech", "proj", "staging", "/tmp") })
    let opened = try await registry.dispatch(
        name: "api_open", params: .object([:]), origin: .agent, environment: "staging",
        confirmation: nil)
    guard case .object(let openFields) = opened,
        case .string(let paneId)? = openFields["pane"]
    else { throw NoSendPane() }

    // A draft that cannot resolve: nothing leaves.
    var refusing = ApiDraft.empty
    refusing.entry = "billing"
    refusing.method = "POST"
    refusing.path = [.literal("/bookings/"), .slot("id")]
    await panes.setApiDraft(paneId: paneId, draft: refusing)
    _ = try await registry.dispatch(
        name: "api_send",
        params: .object([
            "pane": .string(paneId), "statement": .string("POST /bookings/<id>"),
        ]),
        origin: .agent, environment: "staging", confirmation: nil)

    // Only the dispatch line — no URL was ever composed, and a line
    // claiming one would record a request that never existed.
    #expect(try journalLines(directory).filter { $0.outcome == "sent" }.isEmpty)

    // A draft that resolves: the URL that left is recorded.
    var sending = ApiDraft.empty
    sending.entry = "billing"
    sending.method = "POST"
    sending.path = [.literal("/bookings/41/confirm")]
    await panes.setApiDraft(paneId: paneId, draft: sending)
    _ = try await registry.dispatch(
        name: "api_send",
        params: .object([
            "pane": .string(paneId), "statement": .string("POST /bookings/41/confirm"),
        ]),
        origin: .agent, environment: "staging", confirmation: nil)

    let all = try journalLines(directory)
    let sent = all.filter { $0.outcome == "sent" }
    #expect(sent.count == 1)
    guard case .object(let params)? = sent.first?.params else {
        Issue.record("the sent line carried no params"); return
    }
    #expect(params["url"] == .string("https://billing.example.com/bookings/41/confirm"))
    // **It is a SECOND line, not a widened first one.** The dispatch line
    // records what was asked — a pane and a sentence — and this records
    // what was sent; collapsing them would lose the distinction that makes
    // the pair readable, exactly as "gated" then "ok" is two lines.
    #expect(params["statement"] == .string("POST /bookings/41/confirm"))
    #expect(all.count > sent.count)
}
