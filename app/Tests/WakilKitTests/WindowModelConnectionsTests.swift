import Foundation
import Testing
@testable import WakilKit

/// What `wakil-ctx` was asked, by tool, in order.
private actor ConnectionClient: ToolCaller {
    var calls: [(tool: String, arguments: JSONValue)] = []
    func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        calls.append((name, arguments))
        let fields: JSONValue = name == "connection_add" ? .object(["name": .string("github")]) : .object([:])
        return .object(["content": .array([]), "structuredContent": fields])
    }
    func tools() -> [String] { calls.map(\.tool) }
}

private func standardRegistry(_ client: ConnectionClient) async -> ActionRegistry {
    let registry = ActionRegistry(
        journalDirectory: testScratchRoot.appendingPathComponent(UUID().uuidString), sessionId: "s1")
    await registerStandardActions(into: registry, context: client, panes: PaneStore(), db: nil, resumes: ResumeBroker())
    return registry
}

private let connectionActions = [
    "ctx_connection_catalog", "ctx_connection_add", "ctx_connection_update", "ctx_connection_remove",
    "ctx_connection_secrets_set", "ctx_connection_allow_set", "ctx_connection_signin_start",
    "ctx_connection_signin_wait", "ctx_connection_signout", "ctx_jira_token_set",
]

/// Every connection action is the operator's: registered `.operatorOnly`, on the list the agent's
/// permission layer refuses, and refused there by name; the operator's dispatch reaches wakil-ctx.
@Test func addConnectionDispatchesOperatorOnly() async throws {
    let client = ConnectionClient()
    let registry = await standardRegistry(client)
    let registered = await registry.all()
    for name in connectionActions {
        #expect(registered.first { $0.name == name }?.audience == .operatorOnly, "\(name)")
        #expect(operatorOnlyActions.contains(name), "\(name)")
        let decision = permissionDecision(toolName: "mcp__\(wakilShimServerName)__\(name)", knownActions: [name])
        guard case .deny(let why) = decision else {
            Issue.record("an agent reached \(name): \(decision)")
            continue
        }
        #expect(why.contains("only the operator"), "\(name): \(why)")
    }

    _ = try await registry.dispatch(
        name: "ctx_connection_add", params: .object(["id": .string("initech"), "kind": .string("github")]),
        origin: .ui, caller: .test("staging"), confirmation: nil)
    #expect(await client.tools() == ["connection_add"])
    #expect(await client.calls.first?.arguments == .object(["id": .string("initech"), "kind": .string("github")]))
}

/// The secret params are journalled by name with their value redacted.
@Test func secretsAreRedactedInTheJournal() async throws {
    let registry = await standardRegistry(ConnectionClient())
    _ = try await registry.dispatch(
        name: "ctx_connection_secrets_set",
        params: .object(["id": .string("initech"), "name": .string("wiki"),
                         "values": .object(["env:WIKI_TOKEN": .string("w-secret-1")])]),
        origin: .ui, caller: .test("staging"), confirmation: nil)
    _ = try await registry.dispatch(
        name: "ctx_jira_token_set",
        params: .object(["id": .string("initech"), "email": .string("ops@initech.test"), "token": .string("j-secret-2")]),
        origin: .ui, caller: .test("staging"), confirmation: nil)
    let entries = try await registry.journalEntries()
    #expect(entries.count == 2)
    guard entries.count == 2, case .object(let secrets) = entries[0].params, case .object(let jira) = entries[1].params else {
        Issue.record("entries \(entries)"); return
    }
    #expect(secrets["values"] == .string("[redacted]"))
    #expect(secrets["name"] == .string("wiki"))
    #expect(jira["token"] == .string("[redacted]"))
    #expect(jira["email"] == .string("ops@initech.test"))
    let raw = String(decoding: try JSONEncoder().encode(entries.map(\.params)), as: UTF8.self)
    #expect(!raw.contains("w-secret-1") && !raw.contains("j-secret-2"))
}

@Suite @MainActor struct WindowModelConnectionsTests {
    /// Records each stubbed action's params; `ctx_config_tree` answers `connections`.
    private actor Asked {
        var calls: [(String, JSONValue)] = []
        func add(_ name: String, _ params: JSONValue) { calls.append((name, params)) }
        func names() -> [String] { calls.map(\.0) }
        func params(_ name: String) -> [JSONValue] { calls.filter { $0.0 == name }.map(\.1) }
    }

    private func window(
        connections: [JSONValue], asked: Asked,
        waitForever: Bool = false
    ) async -> WindowModel {
        let model = WindowModel.forTesting(scratchRoot: testScratchRoot, organization: "initech")
        let tree: JSONValue = .object(["structuredContent": .object([
            "org": .object(["id": .string("initech"), "connections": .array(connections)]),
            "providers": .array([]), "projects": .array([]),
        ])])
        await model.registryForTesting.register(Action(
            name: "ctx_config_tree", description: "", kind: .read, schema: .object([:]), handler: { _ in tree }))
        for name in connectionActions {
            await model.registryForTesting.register(Action(
                name: name, description: "stub", kind: .control, audience: .operatorOnly, schema: .object([:]),
                handler: { params in
                    await asked.add(name, params)
                    if name == "ctx_connection_signin_start" {
                        return .object(["structuredContent": .object(["url": .string("https://auth.initech.test/authorize")])])
                    }
                    if name == "ctx_connection_signin_wait" {
                        if waitForever { try await Task.sleep(for: .seconds(3600)) }
                        return .object(["structuredContent": .object(["account": .string("ops@initech.test")])])
                    }
                    return .object(["structuredContent": .object([:])])
                }))
        }
        await model.refreshSettings()
        return model
    }

    private static func connection(_ name: String, signIn: String = "none", signedIn: Bool = false,
                                   allow: [String: Bool] = [:], hints: [String: String] = [:]) -> JSONValue {
        .object([
            "name": .string(name), "kind": .string("custom"), "transport": .string("stdio"), "command": .string("x"),
            "signIn": .string(signIn), "signedIn": .bool(signedIn),
            "allow": .object(allow.mapValues { .bool($0) }), "hints": .object(hints.mapValues { .string($0) }),
        ])
    }

    @Test func allowReadOnlyToolsSkipsLockedAndAllowed() async {
        let asked = Asked()
        let model = await window(connections: [Self.connection("wiki", allow: ["read_page": true], hints: [
            "read_page": "readOnly", "list_pages": "readOnly", "search": "readOnly",
            "edit_page": "writes", "drop_page": "destructive", "plain": "",
        ])], asked: asked)
        #expect(await model.allowReadOnlyTools(org: "initech", name: "wiki") == nil)
        let tools = await asked.params("ctx_connection_allow_set").compactMap { p -> String? in
            guard case .object(let o) = p, case .string(let t)? = o["tool"], o["allow"] == .bool(true),
                  o["id"] == .string("initech"), o["name"] == .string("wiki") else { return nil }
            return t
        }
        #expect(tools == ["list_pages", "search"])
    }

    @Test func checkConnectionMapsErrorWhole() async {
        let asked = Asked()
        let model = await window(connections: [
            Self.connection("wiki"),
            Self.connection("tracker", signIn: "token", signedIn: true),
            Self.connection("docs", signIn: "browser", signedIn: false),
        ], asked: asked)
        let whole = "wiki: exec: \"wiki-mcp\": executable file not found in $PATH\nsecond line of the server's own words"

        model.connectionLister = { _, _ in .error(whole) }
        #expect(await model.checkConnection(org: "initech", name: "wiki") == .failing(whole))

        model.connectionLister = { _, _ in .error("calling \"initialize\": 401 Unauthorized") }
        #expect(await model.checkConnection(org: "initech", name: "tracker") == .needsSignIn)

        model.connectionLister = { _, _ in .error("dial tcp: connection refused") }
        #expect(await model.checkConnection(org: "initech", name: "docs") == .needsSignIn)

        let seen = SeenArgs()
        model.connectionLister = { org, name in
            await seen.set(org, name)
            return .tools([ConnectionTool(name: "read_page", hint: "readOnly"), ConnectionTool(name: "edit_page", hint: "")])
        }
        guard case .connected(let tools, _) = await model.checkConnection(org: "initech", name: "wiki") else {
            Issue.record("not connected"); return
        }
        #expect(tools.map(\.name) == ["read_page", "edit_page"])
        #expect(await seen.value == "initech/wiki")
        #expect(await asked.params("ctx_connection_update") == [.object([
            "id": .string("initech"), "name": .string("wiki"),
            "hints": .object(["read_page": .string("readOnly"), "edit_page": .string("")]),
        ])])
    }

    @Test func signInCanBeCancelled() async throws {
        let asked = Asked()
        let model = await window(connections: [Self.connection("docs", signIn: "browser")], asked: asked, waitForever: true)
        var opened: [URL] = []
        model.openURL = { opened.append($0) }
        let task = Task { await model.signIn(org: "initech", name: "docs") }
        for _ in 0..<200 where await !asked.names().contains("ctx_connection_signin_wait") {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(opened == [URL(string: "https://auth.initech.test/authorize")!])
        task.cancel()
        #expect(await task.value == nil)
        #expect(model.connectionAccounts.isEmpty)
    }

    @Test func aFinishedSignInKeepsTheAccount() async {
        let asked = Asked()
        let model = await window(connections: [Self.connection("docs", signIn: "browser")], asked: asked)
        #expect(await model.signIn(org: "initech", name: "docs") == nil)
        #expect(model.connectionAccounts["initech/docs"] == "ops@initech.test")
    }
}

private actor SeenArgs {
    var value = ""
    func set(_ org: String, _ name: String) { value = "\(org)/\(name)" }
}

@Test func theListingLineParses() {
    #expect(parseConnectionListing(Data(#"{"tools":[{"name":"a","hint":"readOnly"},{"name":"b","hint":""}]}"#.utf8), exitCode: 0)
        == .tools([ConnectionTool(name: "a", hint: "readOnly"), ConnectionTool(name: "b", hint: "")]))
    #expect(parseConnectionListing(Data(#"{"tools":[]}"#.utf8), exitCode: 0) == .tools([]))
    #expect(parseConnectionListing(Data(#"{"error":"401 Unauthorized"}"#.utf8), exitCode: 1) == .error("401 Unauthorized"))
    #expect(parseConnectionListing(Data(), exitCode: 2) == .error("wakil-connect exited 2 and said nothing"))
}

@Test func theRowsAndTheStatusLineSayWhatTheServerSaid() {
    let c = SettingsConnection(name: "wiki", allow: ["edit_page": true, "search": false],
                               hints: ["search": "readOnly", "edit_page": "writes", "drop_page": "destructive", "plain": ""],
                               secretKeys: ["env:WIKI_TOKEN", "header:X-Api-Key", "access"])
    let rows = connectionToolRows(c)
    #expect(rows.map(\.name) == ["drop_page", "edit_page", "plain", "search"])
    #expect(rows.map(\.says) == ["destructive", "writes", "—", "read-only"])
    #expect(rows.map(\.allowed) == [false, true, false, false])
    #expect(rows.map(\.locked) == [true, false, false, false])
    #expect(connectionSecretEntries(c).map(\.key) == ["env:WIKI_TOKEN", "header:X-Api-Key"])

    let at = Date(timeIntervalSince1970: 1000)
    let nine = (1...9).map { ConnectionTool(name: "t\($0)", hint: "") }
    #expect(connectionStatusLine(.connected(tools: nine, checkedAt: at), now: at.addingTimeInterval(130))
        == "Connected · 9 tools · checked 2 min ago")
    #expect(connectionStatusLine(.failing("the whole\nerror")) == "the whole\nerror")
    #expect(connectionDot(SettingsConnection(name: "x", signIn: "token"), status: nil) == .needsSignIn)
    #expect(connectionDot(SettingsConnection(name: "x"), status: nil) == .unchecked)
    #expect(connectionDot(SettingsConnection(name: "x"), status: .failing("e")) == .failing)
    #expect(jiraDot(SettingsOrg(id: "initech", jiraBase: "https://initech.atlassian.net", jiraTokenStored: true)) == .connected)
    #expect(jiraDot(SettingsOrg(id: "initech", jiraBase: "https://initech.atlassian.net")) == .needsSignIn)
}
