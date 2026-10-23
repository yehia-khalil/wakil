import Testing
import Foundation
@testable import WakilKit

// 2e-iv: `db_set_connection`, the window method that drives it, and the settings tree's
// `connection`.

private actor ConnectionRecorder: ToolCaller {
    private(set) var calls: [(tool: String, arguments: JSONValue)] = []
    var failWith: String?
    func fail(with message: String?) { failWith = message }
    func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        calls.append((name, arguments))
        if name == "set_database_connection", let failWith {
            return .object(["isError": .bool(true), "content": .array([
                .object(["type": .string("text"), "text": .string(failWith)])])])
        }
        if name == "config_tree" {
            return .object(["structuredContent": .object([
                "org": .object(["id": .string("acme")]), "providers": .array([]), "projects": .array([]),
            ])])
        }
        return .object(["structuredContent": .object([:])])
    }
    func setCalls() -> [JSONValue] { calls.filter { $0.tool == "set_database_connection" }.map(\.arguments) }
}

@MainActor private func connectionModel() async throws -> (WindowModel, ConnectionRecorder) {
    let backend = ConnectionRecorder()
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let registry = ActionRegistry(journalDirectory: dir, sessionId: "conn")
    let panes = PaneStore(kinds: PaneKinds.standard)
    let layout = LayoutStore()
    await registerStandardActions(into: registry, context: backend, panes: panes, db: nil, resumes: ResumeBroker())
    await registerLayoutActions(into: registry, layout: layout)
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: ContextStore(client: backend),
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main",
        lookup: ConnectionCredentialsLookup(), environment: "staging")
    return (model, backend)
}

private struct ConnectionCredentialsLookup: ProviderCredentialsLookup {
    func credentials(forProvider id: String) async throws -> ProviderCredentials {
        ProviderCredentials(claudePath: "/usr/bin/true", configDir: "/dev/null", oauthToken: "test-only")
    }
}

@Test @MainActor func theWindowMethodSendsPartsAndNoKeyForAnEmptyPassword() async throws {
    let (model, backend) = try await connectionModel()
    let refusal = await model.setDatabaseConnection(
        projectPath: "/p.json", environment: "staging", name: "core", driver: "mysql",
        connection: SettingsDatabaseConnection(host: "db.internal", port: "3307", database: "orders", user: "reader"),
        password: "", grantWrite: false, writePassword: "")
    #expect(refusal == nil)
    let sent = try #require(await backend.setCalls().first)
    guard case .object(let args) = sent else { Issue.record("not an object: \(sent)"); return }
    #expect(args["host"] == .string("db.internal"))
    #expect(args["port"] == .string("3307"))
    #expect(args["database"] == .string("orders"))
    #expect(args["user"] == .string("reader"))
    #expect(args["password"] == nil, "an empty password means keep: no key is sent")
    #expect(args["writePassword"] == nil)
    #expect(args["grantWrite"] == nil)
    // Settings are re-read either way.
    #expect(await backend.calls.contains { $0.tool == "config_tree" })
}

@Test @MainActor func theWindowMethodSendsPasswordsWhenTyped() async throws {
    let (model, backend) = try await connectionModel()
    _ = await model.setDatabaseConnection(
        projectPath: "/p.json", environment: "staging", name: "core", driver: "mysql",
        connection: SettingsDatabaseConnection(host: "h", database: "d", user: "u", writeUser: "w"),
        password: "pw", grantWrite: true, writePassword: "wpw")
    guard case .object(let args)? = await backend.setCalls().first else { Issue.record("no call"); return }
    #expect(args["password"] == .string("pw"))
    #expect(args["writePassword"] == .string("wpw"))
    #expect(args["grantWrite"] == .bool(true))
    #expect(args["writeUser"] == .string("w"))
}

@Test @MainActor func aRefusalComesBackAsTheSentenceAndSettingsAreStillRefreshed() async throws {
    let (model, backend) = try await connectionModel()
    await backend.fail(with: "host is required")
    let refusal = await model.setDatabaseConnection(
        projectPath: "/p.json", environment: "staging", name: "core", driver: "mysql",
        connection: SettingsDatabaseConnection(), password: "", grantWrite: false, writePassword: "")
    #expect(refusal?.contains("host is required") == true, "got \(String(describing: refusal))")
    #expect(await backend.calls.contains { $0.tool == "config_tree" })
}

@Test func theSettingsTreeDecodesAConnectionAndItsAbsence() throws {
    func decode(_ database: JSONValue) -> SettingsDatabase? {
        let reply = JSONValue.object(["structuredContent": .object([
            "org": .object(["id": .string("acme")]), "providers": .array([]),
            "projects": .array([.object([
                "name": .string("orders"), "path": .string("/p.json"), "roots": .array([]),
                "environments": .array([.object([
                    "name": .string("staging"), "databases": .array([database]), "api": .array([]),
                ])]),
            ])]),
        ])])
        return decodeSettingsTree(fromResult: reply)?.projects.first?.environments.first?.databases.first
    }
    let with = decode(.object([
        "name": .string("core"), "driver": .string("mysql"), "ref": .string("db:x"),
        "writable": .bool(true),
        "connection": .object(["host": .string("db.internal"), "database": .string("orders"),
                               "user": .string("reader"), "writeUser": .string("writer")]),
    ]))
    #expect(with?.connection?.host == "db.internal")
    #expect(with?.connection?.port == "")
    #expect(with?.connection?.database == "orders")
    #expect(with?.connection?.user == "reader")
    #expect(with?.connection?.path == "")
    #expect(with?.connection?.writeUser == "writer")
    let legacy = decode(.object(["name": .string("old"), "driver": .string("mysql"), "ref": .string("db:y")]))
    #expect(legacy != nil)
    #expect(legacy?.connection == nil)
}
