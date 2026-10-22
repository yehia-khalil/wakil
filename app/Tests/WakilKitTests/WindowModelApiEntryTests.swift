import Foundation
import Testing
@testable import WakilKit

/// A wakil-ctx and wakil-http in one: the active place is project `p` (file `/p/project.json`) in
/// `dev`; writes are recorded; `list_apis` answers whatever the last write left.
private actor ApiEntryContext: ToolCaller {
    var calls: [(name: String, arguments: JSONValue)] = []
    var refuse: String?
    var entries: [String] = ["orders-api"]

    func refuse(with text: String?) { refuse = text }
    func count(_ name: String) -> Int { calls.filter { $0.name == name }.count }
    func lastArguments(_ name: String) -> [String: JSONValue] {
        if case .object(let o)? = calls.last(where: { $0.name == name })?.arguments { return o }
        return [:]
    }

    private func ok(_ o: [String: JSONValue]) -> JSONValue { .object(["structuredContent": .object(o)]) }

    func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        calls.append((name, arguments))
        switch name {
        case "get_context":
            return ok([
                "Org": .string("test-org"), "Environment": .string("dev"),
                "ProjectKey": .string("p"), "Project": .object(["name": .string("p")]),
                "RootPaths": .array([]), "ActiveProvider": .string("p1"),
            ])
        case "config_tree":
            return ok(["org": .object(["id": .string("test-org")]), "projects": .array([.object([
                "name": .string("p"), "path": .string("/p/project.json"),
            ])])])
        case "list_apis":
            return ok(["apis": .array(entries.map {
                .object(["name": .string($0), "baseUrl": .string("https://x.example"),
                         "authenticated": .bool(false)])
            })])
        default: break
        }
        if let refuse {
            return .object(["isError": .bool(true), "content": .array([
                .object(["type": .string("text"), "text": .string(refuse)])])])
        }
        if name == "update_api_entry", case .object(let o) = arguments,
           case .string(let new)? = o["newName"] {
            entries = entries.map { $0 == "orders-api" ? new : $0 }
        }
        return ok([:])
    }
}

@MainActor
private func apiWindow() async -> (WindowModel, ApiEntryContext) {
    let ctx = ApiEntryContext()
    let window = WindowModel.forTesting(
        scratchRoot: testScratchRoot, context: ContextStore(client: ctx), apiHTTP: ctx)
    await registerStandardActions(
        into: window.registryForTesting, context: ctx, panes: window.panesForTesting,
        db: nil, resumes: ResumeBroker())
    await window.refreshContext()
    await window.refreshSettings()
    _ = await window.layoutForTesting.open(kind: "api", title: apiPaneTitle(entry: "orders-api"))
    await window.panesForTesting.openApi(
        paneId: "api-1", entry: "orders-api", environment: "dev",
        origin: "https://x.example", credentialed: false, entries: ["orders-api"])
    return (window, ctx)
}

@Suite @MainActor struct WindowModelApiEntryTests {
    @Test func renamingAnEntryInTheActivePlaceRepointsTheOpenPaneAndReresolves() async throws {
        let (window, ctx) = await apiWindow()
        let before = await ctx.count("list_apis")

        let error = await window.updateApiEntry(
            projectPath: "/p/project.json", environment: "dev", name: "orders-api", newName: "orders")

        #expect(error == nil)
        #expect(await window.panesForTesting.apiDraft(paneId: "api-1").entry == "orders")
        #expect(await ctx.count("list_apis") > before)
        #expect(await window.panesForTesting.apiSnapshot(paneId: "api-1").entries == ["orders"])
        // W8: the pane's title follows its entry.
        let titles = await window.layoutForTesting.snapshot().panes.map(\.title)
        #expect(titles == [apiPaneTitle(entry: "orders")])
        // Only what was set is sent.
        let sent = await ctx.lastArguments("update_api_entry")
        #expect(sent["newName"] == .string("orders"))
        #expect(sent["baseUrl"] == nil && sent["authHeader"] == nil && sent["clearToken"] == nil)
    }

    @Test func aRenameInAnotherEnvironmentRepointsNothing() async throws {
        let (window, ctx) = await apiWindow()
        let before = await ctx.count("list_apis")

        let error = await window.updateApiEntry(
            projectPath: "/p/project.json", environment: "stage", name: "orders-api", newName: "orders")

        #expect(error == nil)
        #expect(await window.panesForTesting.apiDraft(paneId: "api-1").entry == "orders-api")
        #expect(await ctx.count("list_apis") == before)
    }

    @Test func aRefusedWriteAnswersTheToolsTextAndRepointsNothing() async throws {
        let (window, ctx) = await apiWindow()
        await ctx.refuse(with: "an entry named orders already exists")
        let before = await ctx.count("list_apis")

        let error = await window.updateApiEntry(
            projectPath: "/p/project.json", environment: "dev", name: "orders-api", newName: "orders")

        #expect(error?.contains("an entry named orders already exists") == true)
        #expect(await window.panesForTesting.apiDraft(paneId: "api-1").entry == "orders-api")
        #expect(await ctx.count("list_apis") == before)
    }

    @Test func aSetOrRemoveInTheActivePlaceReresolvesWithoutRepointing() async throws {
        let (window, ctx) = await apiWindow()
        var before = await ctx.count("list_apis")
        #expect(await window.setApiEntry(
            projectPath: "/p/project.json", environment: "dev", name: "billing",
            baseUrl: "https://b.example", authHeader: nil, token: "t") == nil)
        #expect(await ctx.count("list_apis") > before)
        #expect(await ctx.lastArguments("set_api_entry")["token"] == .string("t"))
        #expect(await ctx.lastArguments("set_api_entry")["authHeader"] == nil)

        before = await ctx.count("list_apis")
        #expect(await window.removeApiEntry(
            projectPath: "/p/project.json", environment: "dev", name: "billing") == nil)
        #expect(await ctx.count("list_apis") > before)
        #expect(await window.panesForTesting.apiDraft(paneId: "api-1").entry == "orders-api")
    }

    @Test func aUiDatabaseUpdateRefreshesTheDatabaseList() async throws {
        let (window, _) = await apiWindow()
        func listings() async throws -> Int {
            try await window.registryForTesting.journalEntries().filter { $0.action == "db_list_databases" }.count
        }
        try await Task.sleep(for: .milliseconds(300))
        let before = try await listings()
        _ = await window.updateDatabase(
            projectPath: "/p/project.json", environment: "dev", name: "core", newName: "main")
        var seen = false
        for _ in 0..<100 where !seen {
            seen = try await listings() > before
            if !seen { try await Task.sleep(for: .milliseconds(50)) }
        }
        #expect(seen)
    }

    @Test func updateDatabaseSendsOnlyWhatIsSet() async throws {
        let (window, ctx) = await apiWindow()
        let error = await window.updateDatabase(
            projectPath: "/p/project.json", environment: "dev", name: "core", revokeWrite: true)
        #expect(error == nil)
        let sent = await ctx.lastArguments("update_database")
        #expect(sent["revokeWrite"] == .bool(true))
        #expect(sent["newName"] == nil)
    }
}

@Test func settingsTreeDecodesAnApiEntrysAuthHeader() throws {
    let data = Data(#"{"name":"orders","baseUrl":"https://o.example","authRef":"k","authHeader":"X-Key"}"#.utf8)
    #expect(try JSONDecoder().decode(SettingsAPI.self, from: data).authHeader == "X-Key")
    let bare = Data(#"{"name":"orders","baseUrl":"https://o.example"}"#.utf8)
    #expect(try JSONDecoder().decode(SettingsAPI.self, from: bare).authHeader == "")
}
