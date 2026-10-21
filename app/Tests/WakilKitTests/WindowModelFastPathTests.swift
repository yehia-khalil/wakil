import Foundation
import Testing
@testable import WakilKit

/// A quick model answering one canned reply after an optional delay, counting what it was asked.
private actor CannedQuickModel: QuickModel {
    nonisolated let serves: Set<QuickOperation> = [.infill, .respond]
    private let reply: String
    private let delay: Duration
    private(set) var respondCalls = 0

    init(reply: String, delay: Duration = .zero) { self.reply = reply; self.delay = delay }

    func infill(_ request: InfillRequest) async throws -> String { reply }
    func respond(_ request: RespondRequest) async throws -> String {
        respondCalls += 1
        if delay > .zero { try await Task.sleep(for: delay) }
        return reply
    }
    func shutdown() async {}
}

/// `wakil-ctx` as far as the fast path needs it: a tree with the switch on or off, and a context.
private struct FastPathBackend: ToolCaller {
    let fastPath: Bool
    var kind = "local"

    func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        switch name {
        case "config_tree":
            return .object(["structuredContent": .object([
                "org": .object(["id": .string("test-org"), "quickProvider": .string("qwen"),
                                "ghostText": .bool(false), "fastPath": .bool(fastPath)]),
                "providers": .array([.object([
                    "id": .string("qwen"), "kind": .string(kind), "baseURL": .string("http://127.0.0.1:8012"),
                    "serves": .array([.string("infill"), .string("respond")])])]),
                "projects": .array([]),
            ])])
        case "get_context":
            return .object(["structuredContent": .object([
                "Org": .string("test-org"), "Environment": .string("qa"),
                "RootPaths": .array([]), "ActiveProvider": .string(""),
            ])])
        default:
            return .object(["structuredContent": .object([:])])
        }
    }
}

/// A `wakil-http` that answers `list_apis` only after `delay`.
private struct SlowHTTP: ToolCaller {
    let delay: Duration
    func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        try await Task.sleep(for: delay)
        return .object(["structuredContent": .object(["apis": .array([])])])
    }
}

/// What the fake actions ran, with the origin and route the journal kept for each.
struct FastPathCalls {
    let registry: ActionRegistry
    func all() async -> [JournalEntry] {
        let fake: Set<String> = ["ctx_set_environment", "settings_open", "db_page"]
        return ((try? await registry.journalEntries()) ?? []).filter { fake.contains($0.action) }
    }
}

private func obj(_ props: [String: String], required: [String]) -> JSONValue {
    .object(["type": .string("object"),
             "properties": .object(props.mapValues { .object(["type": .string($0)]) }),
             "required": .array(required.map { .string($0) })])
}

private struct FastPathRefusal: Error, CustomStringConvertible { let description: String }

/// A window whose quick model is a local `CannedQuickModel`, with a recording `ctx_set_environment`,
/// `settings_open` and `db_page` and a `db_page` that refuses.
@MainActor
private func makeFastPathWindow(
    reply: String, fastPath: Bool = true, delay: Duration = .zero, kind: String = "local",
    paletteClients: PaletteClients = PaletteClients()
) async -> (WindowModel, FastPathCalls, CannedQuickModel) {
    let model = CannedQuickModel(reply: reply, delay: delay)
    let window = WindowModel.forTesting(
        scratchRoot: testScratchRoot, context: ContextStore(client: FastPathBackend(fastPath: fastPath, kind: kind)),
        quickModelFactory: { _, _ in model }, paletteClients: paletteClients)
    let registry = window.registryForTesting
    func fake(_ name: String, _ schema: JSONValue, _ handler: @escaping @Sendable (JSONValue) async throws -> JSONValue) async {
        await registry.register(Action(name: name, description: "", kind: .control, audience: .operatorOnly,
                                       schema: schema, handler: handler))
    }
    await fake("ctx_set_environment", obj(["name": "string"], required: ["name"])) { _ in .object([:]) }
    await fake("settings_open", obj([:], required: [])) { _ in .object([:]) }
    await fake("db_page", obj(["pane": "string", "to": "string"], required: ["pane", "to"])) { _ in
        throw FastPathRefusal(description: "db_page: pane editor-1 is not a table pane")
    }
    window.seedForTesting(providerId: "", rootPath: "/p", thoughts: 0, project: "shop", environment: "qa")
    window.setSettingsForTesting(SettingsTree(
        org: SettingsOrg(id: "test-org"),
        projects: [SettingsProject(name: "shop", environments: [SettingsEnvironment(name: "staging"), SettingsEnvironment(name: "qa")])]))
    await window.rebuildQuickTasks()
    return (window, FastPathCalls(registry: registry), model)
}

@Suite @MainActor struct WindowModelFastPathTests {
    @Test func aLineTheModelRoutesRunsAsTheOperatorAndSaysSo() async {
        let (window, calls, _) = await makeFastPathWindow(reply: #"{"action":"ctx_set_environment","params":{"name":"staging"}}"#)
        let outcome = await window.runFastPath("switch to staging")
        #expect(outcome == .ran(FastPathReceipt(line: "switch to staging", text: "Ran: switch environment to staging", refused: false)))
        let last = await calls.all().last
        #expect(last?.action == "ctx_set_environment")
        #expect(last?.origin == .ui)
        #expect(last?.via == "fastPath")
    }

    @Test func aHandlerThatRefusesShowsItsRefusalWhole() async {
        let (window, _, _) = await makeFastPathWindow(reply: #"{"action":"db_page","params":{"pane":"editor-1","to":"next"}}"#)
        window.seedForTesting(providerId: "", rootPath: "/p", thoughts: 0, layoutSnapshot: LayoutSnapshot(
            panes: [Pane(id: "editor-1", kind: "editor", title: "a.go", frame: PaneFrame(x: 0, y: 0, width: 400, height: 300))]), project: "shop", environment: "qa")
        guard case .refused(let r) = await window.runFastPath("next page") else { Issue.record("not refused"); return }
        #expect(r.line == "next page")
        #expect(r.refused)
        #expect(r.text.contains("not a table pane"))
    }

    @Test func fastPathOffOrNoQuickTasksGoesToTheAgent() async {
        let (window, calls, model) = await makeFastPathWindow(reply: #"{"action":"settings_open","params":{}}"#, fastPath: false)
        #expect(await window.runFastPath("open settings") == .toAgent)
        #expect(await calls.all().isEmpty)
        #expect(await model.respondCalls == 0)
    }

    @Test func anAnswerThatLandsAfterAnOrgSwitchIsDropped() async throws {
        let (window, calls, _) = await makeFastPathWindow(
            reply: #"{"action":"settings_open","params":{}}"#, delay: .milliseconds(100))
        let outcome = Task { await window.runFastPath("open settings") }
        try await Task.sleep(for: .milliseconds(30))
        window.quickTasksGeneration += 1      // what rebuildQuickTasks does on an org switch
        #expect(await outcome.value == .toAgent)
        #expect(await calls.all().isEmpty)
    }

    @Test func aPlaceSwitchDuringTheWaitDispatchesNothing() async throws {
        let (window, calls, _) = await makeFastPathWindow(
            reply: #"{"action":"settings_open","params":{}}"#, delay: .milliseconds(100))
        let outcome = Task { await window.runFastPath("open settings") }
        try await Task.sleep(for: .milliseconds(30))
        window.seedForTesting(providerId: "", rootPath: "/p", thoughts: 0, project: "other", environment: "qa")
        #expect(await outcome.value == .toAgent)
        #expect(await calls.all().isEmpty)
    }

    @Test func rebuildingWithTheFastPathOnWarmsThePrompt() async {
        let (window, _, model) = await makeFastPathWindow(reply: #"{"action":"agent","params":{}}"#)
        await window.rebuildQuickTasks()
        var warmed = false
        for _ in 0..<40 where !warmed {
            try? await Task.sleep(for: .milliseconds(10))
            warmed = await model.respondCalls >= 1
        }
        #expect(warmed)
    }

    @Test func rebuildingWithTheFastPathOffAsksNothing() async {
        let (_, _, model) = await makeFastPathWindow(reply: #"{"action":"agent","params":{}}"#, fastPath: false)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await model.respondCalls == 0)
    }

    @Test func receiptTextNamesTheActionInWords() {
        #expect(WindowModel.fastPathReceiptText(action: "editor_open", params: .object(["path": .string("/p/api/confirm.go")]))
                == "Ran: open confirm.go")
        #expect(WindowModel.fastPathReceiptText(action: "pane_restore", params: .object([:])) == "Ran: restore the layout")
        #expect(WindowModel.fastPathReceiptText(action: "editor_goto", params: .object(["line": .integer(40)])) == "Ran: go to line 40")
        #expect(WindowModel.fastPathReceiptText(action: "db_list_tables", params: .object(["database": .string("core")]))
                == "Ran: list the tables in core")
        #expect(WindowModel.fastPathReceiptText(action: "db_list_tables", params: .object([:])) == "Ran: list the tables")
    }

    @Test func theScopeHoldsTheTopTwentyFilesAndEveryPane() async throws {
        let (window, _, files) = await editorWindowParts(roots: ["/p"])
        await window.refreshContext()
        await files.setListing("/p", (1...30).map { "src/confirm\($0).go" } + ["api/confirm.go"])
        await files.put("/p/api/confirm.go", "package api")
        await window.dispatchFromSurface("editor_open", .object(["path": .string("/p/api/confirm.go")]))
        await window.refreshLayout()
        let scope = await window.fastPathScope(for: "open confirm.go")
        #expect(scope.files.count == 20)
        #expect(scope.files.first == "/p/api/confirm.go")
        // A leading verb matches no file, and must not empty the list.
        #expect(await window.fastPathScope(for: "open confirm.go").files.first == "/p/api/confirm.go")
        #expect(scope.panes.map(\.kind) == ["editor"])
        #expect(scope.roots == window.rootPaths)
    }

    @Test func theSchemasAreTheRegistrysForEachAllowedActionItHolds() async throws {
        let (window, _, _) = await editorWindowParts(roots: ["/p"])
        let schemas = await window.fastPathSchemas()
        #expect(schemas["editor_open"] != nil)
        #expect(schemas.keys.allSatisfy { FastPath.allowed[$0] != nil })
    }

    @Test func aLineJournalsOnlyItsOwnDispatchAndLeavesTheStatusAlone() async throws {
        let (window, calls, _) = await makeFastPathWindow(reply: #"{"action":"settings_open","params":{}}"#)
        window.setStatusForTesting("db_run: connection refused")
        let before = try await calls.registry.journalEntries().count
        #expect(await window.runFastPath("open settings") != .toAgent)
        let added = Array(try await calls.registry.journalEntries().dropFirst(before))
        #expect(added.map(\.action) == ["settings_open"])
        #expect(added.first?.via == "fastPath")
        #expect(window.status == "db_run: connection refused")
    }

    @Test func aLineForTheAgentJournalsNothing() async throws {
        let (window, calls, _) = await makeFastPathWindow(reply: #"{"action":"agent","params":{}}"#)
        window.setStatusForTesting("kept")
        let before = try await calls.registry.journalEntries().count
        #expect(await window.runFastPath("why is it slow?") == .toAgent)
        #expect(try await calls.registry.journalEntries().count == before)
        #expect(window.status == "kept")
    }

    @Test func theProjectsComeFromSettingsWithoutARoundTrip() async {
        let (window, _, _) = await makeFastPathWindow(reply: #"{"action":"agent","params":{}}"#)
        #expect(await window.fastPathScope(for: "go to shop").projects == ["shop"])
    }

    @Test func theDatabasesAreTheQueryLinesWithoutSettingsRead() async {
        let (window, _, _) = await makeFastPathWindow(reply: #"{"action":"agent","params":{}}"#)
        window.seedForTesting(providerId: "", rootPath: "/p", thoughts: 0, databases: ["core", "audit"], project: "shop", environment: "qa")
        window.setSettingsForTesting(nil)
        #expect(await window.fastPathScope(for: "tables in core").databases == ["core", "audit"])
    }

    @Test func aScopeNotReadyByTheDeadlineSendsTheLineToTheAgent() async {
        let (window, calls, model) = await makeFastPathWindow(
            reply: #"{"action":"settings_open","params":{}}"#,
            paletteClients: PaletteClients(http: SlowHTTP(delay: .seconds(30))))
        for _ in 0..<40 where await model.respondCalls == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        let warmed = await model.respondCalls      // the rebuild's warm-up, not a line
        let started = ContinuousClock.now
        #expect(await window.runFastPath("open settings") == .toAgent)
        #expect(ContinuousClock.now - started < .seconds(10), "the 300 ms deadline, loosely: not the 30 s read")
        #expect(await calls.all().isEmpty)
        #expect(await model.respondCalls == warmed, "the model is not asked without a scope")
    }

    @Test func theFilesComeFromTheListingTheWindowHolds() async throws {
        let (window, _, files) = await editorWindowParts(roots: ["/p"])
        await window.refreshContext()
        await files.setListing("/p", ["api/confirm.go"])
        await window.openPane(kind: "editor")
        await window.toggleEditorColumn(.files)
        #expect(window.editorFiles.listings["/p"]?.files == ["api/confirm.go"])
        func reads() async -> Int { await files.calls.filter { $0.hasPrefix("files_list ") }.count }
        let before = await reads()
        #expect(await window.fastPathScope(for: "open confirm.go").files == ["/p/api/confirm.go"])
        #expect(await reads() == before, "a line makes no files_list round trip")
    }

    @Test func aLineTypedInAnotherPlaceDispatchesNothing() async {
        let (window, calls, _) = await makeFastPathWindow(reply: #"{"action":"settings_open","params":{}}"#)
        let typedIn = window.turnScope
        window.seedForTesting(providerId: "", rootPath: "/p", thoughts: 0, project: "other", environment: "qa")
        #expect(await window.runFastPath("open settings", scope: typedIn) == .toAgent)
        #expect(await calls.all().isEmpty)
    }

    @Test func aSessionBackedModelIsNotWarmed() async {
        let (_, _, model) = await makeFastPathWindow(reply: #"{"action":"agent","params":{}}"#, kind: "claude-code")
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await model.respondCalls == 0)
    }

    @Test func aReceiptNeverEndsOnAMissingParam() {
        #expect(WindowModel.fastPathReceiptText(action: "pane_sort", params: .object(["pane": .string("db-1")])) == "Ran: clear the sort")
        #expect(WindowModel.fastPathReceiptText(action: "pane_sort", params: .object(["pane": .string("db-1"), "column": .string("id")]))
                == "Ran: sort by id")
        #expect(WindowModel.fastPathReceiptText(action: "db_page", params: .object(["pane": .string("db-1")])) == "Ran: next page")
        #expect(WindowModel.fastPathReceiptText(action: "db_page", params: .object(["pane": .string("db-1"), "to": .string("3")]))
                == "Ran: page 3")
    }
}
