import Foundation
import Testing
@testable import WakilKit

private func scratch() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private actor RecordingCaller: ToolCaller {
    private(set) var calls: [(tool: String, arguments: JSONValue)] = []
    func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        calls.append((name, arguments))
        return .object(["structuredContent": .object([:])])
    }
    func recorded() -> [(tool: String, arguments: JSONValue)] { calls }
}

private func registryWithRecordingContext() async throws -> (ActionRegistry, RecordingCaller) {
    let caller = RecordingCaller()
    let registry = ActionRegistry(journalDirectory: try scratch(), sessionId: "editor-settings")
    await registerStandardActions(
        into: registry, context: caller, panes: PaneStore(), db: nil,
        resumes: ResumeBroker(), providerSwitches: ProviderSwitchBroker())
    return (registry, caller)
}

@Suite struct EditorSettingsTests {
    @Test func theTreeDecodesBothEditorTiers() throws {
        let json = """
        {"structuredContent":{"org":{"id":"acme","displayName":"","jiraBase":"","defaultProvider":""},
         "providers":[],"projects":[{"name":"w","path":"/p.json","roots":[],"environments":[],
           "editor":{"tabSize":2,"insertSpaces":false}}],
         "editor":{"fontSize":15,"wordWrap":true,"autosave":"focus"}}}
        """
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        let tree = try #require(decodeSettingsTree(fromResult: value))
        #expect(tree.editor == SettingsEditor(fontSize: 15, wordWrap: true, autosave: .focus))
        #expect(tree.editorError == nil)
        #expect(tree.projects.first?.editor == SettingsProjectEditor(tabSize: 2, insertSpaces: false))
    }

    /// An older wakil-ctx answers no editor keys: the tree still decodes, with the defaults.
    @Test func aTreeWithNoEditorKeysDecodesToTheDefaults() throws {
        let json = """
        {"structuredContent":{"org":{"id":"acme","displayName":"","jiraBase":"","defaultProvider":""},
         "providers":[],"projects":[{"name":"w","path":"/p.json"}]}}
        """
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        let tree = try #require(decodeSettingsTree(fromResult: value))
        #expect(tree.editor == .defaults)
        #expect(tree.projects.first?.editor == .defaults)
    }

    @Test func editorSettingsDecodeFlatAndMapToViewOptions() throws {
        let json = """
        {"structuredContent":{"fontSize":14,"wordWrap":true,"autosave":"pause","tabSize":2,"insertSpaces":false}}
        """
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        let s = try #require(decodeEditorSettings(fromResult: value))
        #expect(s.app.autosave == .pause)
        #expect(s.viewOptions == EditorViewOptions(fontSize: 14, wordWrap: true, tabSize: 2, insertSpaces: false))
        #expect(s.appError == nil)
    }

    /// An unknown autosave value reads as off — the editor never guesses a write.
    @Test func anUnknownAutosaveModeReadsAsOff() throws {
        let json = #"{"structuredContent":{"fontSize":12,"wordWrap":false,"autosave":"always","tabSize":4,"insertSpaces":true}}"#
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        #expect(decodeEditorSettings(fromResult: value)?.app.autosave == .off)
    }

    @Test func theAppWriteForwardsOnlyTypedKeysItKnows() async throws {
        let (registry, caller) = try await registryWithRecordingContext()
        _ = try await registry.dispatch(
            name: "ctx_set_editor_settings",
            params: .object(["fontSize": .integer(14), "wordWrap": .string("yes"), "bogus": .bool(true)]),
            origin: .ui, caller: .test("staging"), confirmation: nil)
        let calls = await caller.recorded()
        guard calls.count == 1, case .object(let arguments) = calls[0].arguments else {
            Issue.record("expected one call, got \(calls)"); return
        }
        #expect(calls[0].tool == "set_editor_settings")
        #expect(arguments == ["fontSize": .integer(14)])
    }

    @Test func theProjectWriteNeedsAProjectPath() async throws {
        let (registry, caller) = try await registryWithRecordingContext()
        await #expect(throws: (any Error).self) {
            try await registry.dispatch(
                name: "ctx_set_project_editor_settings", params: .object(["tabSize": .integer(2)]),
                origin: .ui, caller: .test("staging"), confirmation: nil)
        }
        #expect(await caller.recorded().isEmpty)
        _ = try await registry.dispatch(
            name: "ctx_set_project_editor_settings",
            params: .object(["projectPath": .string("/p.json"), "tabSize": .integer(2), "insertSpaces": .bool(false)]),
            origin: .ui, caller: .test("staging"), confirmation: nil)
        let calls = await caller.recorded()
        #expect(calls.last?.tool == "set_project_editor_settings")
        #expect(calls.last?.arguments == .object([
            "projectPath": .string("/p.json"), "tabSize": .integer(2), "insertSpaces": .bool(false),
        ]))
    }

    /// Decision 30: the agent reads and never writes, and the refusal names why.
    @Test func theWritesAreOperatorOnlyAndTheReadIsNot() async throws {
        let (registry, _) = try await registryWithRecordingContext()
        let all = await registry.all()
        let read = try #require(all.first { $0.name == "ctx_editor_settings" })
        #expect(read.kind == .read && read.audience == .agentReachable)
        for name in ["ctx_set_editor_settings", "ctx_set_project_editor_settings"] {
            let action = try #require(all.first { $0.name == name })
            #expect(action.kind == .control && action.audience == .operatorOnly)
            #expect(operatorOnlyActions.contains(name))
            let decision = permissionDecision(toolName: "mcp__wakil__\(name)", knownActions: [name, "ctx_editor_settings"])
            guard case .deny(let reason) = decision else {
                Issue.record("\(name) must be denied, got \(decision)"); return
            }
            #expect(reason.contains("Decision 30"))
            #expect(reason.contains("ctx_editor_settings"))
        }
    }

    @Test func thePartTwoKeysDecodeAndDefault() throws {
        let json = #"{"structuredContent":{"fontSize":12,"wordWrap":false,"autosave":"off","showIgnored":false,"tabSize":4,"insertSpaces":true,"heavyFolders":["storage"]}}"#
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        let s = try #require(decodeEditorSettings(fromResult: value))
        #expect(s.app.showIgnored == false)
        #expect(s.project.heavyFolders == ["storage"])
        let older = #"{"structuredContent":{"fontSize":12,"wordWrap":false,"autosave":"off","tabSize":4,"insertSpaces":true}}"#
        let o = try #require(decodeEditorSettings(fromResult: try JSONDecoder().decode(JSONValue.self, from: Data(older.utf8))))
        #expect(o.app.showIgnored == true)
        #expect(o.project.heavyFolders == ["vendor", "node_modules"])
    }

    /// An empty list is a value: only .git is heavy.
    @Test func anEmptyHeavyFolderListDecodesEmpty() throws {
        let json = #"{"structuredContent":{"tabSize":4,"insertSpaces":true,"heavyFolders":[]}}"#
        let s = try #require(decodeEditorSettings(fromResult: try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))))
        #expect(s.project.heavyFolders == [])
    }

    @Test func anEmptyHeavyFolderListIsForwardedAsEmpty() async throws {
        let (registry, caller) = try await registryWithRecordingContext()
        _ = try await registry.dispatch(
            name: "ctx_set_project_editor_settings",
            params: .object(["projectPath": .string("/p.json"), "heavyFolders": .array([])]),
            origin: .ui, caller: .test("staging"), confirmation: nil)
        let calls = await caller.recorded()
        #expect(calls.count == 1)
        #expect(calls[0].arguments == .object(["projectPath": .string("/p.json"), "heavyFolders": .array([])]))
    }

    @Test func theWritesForwardShowIgnoredAndTheHeavyFolders() async throws {
        let (registry, caller) = try await registryWithRecordingContext()
        _ = try await registry.dispatch(
            name: "ctx_set_editor_settings", params: .object(["showIgnored": .bool(false)]),
            origin: .ui, caller: .test("staging"), confirmation: nil)
        _ = try await registry.dispatch(
            name: "ctx_set_project_editor_settings",
            params: .object(["projectPath": .string("/p.json"),
                             "heavyFolders": .array([.string("storage"), .string("dist")])]),
            origin: .ui, caller: .test("staging"), confirmation: nil)
        _ = try await registry.dispatch(
            name: "ctx_set_project_editor_settings",
            params: .object(["projectPath": .string("/p.json"), "heavyFolders": .array([.string("a"), .integer(3)])]),
            origin: .ui, caller: .test("staging"), confirmation: nil)
        let calls = await caller.recorded()
        #expect(calls.count == 3)
        #expect(calls[0].arguments == .object(["showIgnored": .bool(false)]))
        #expect(calls[1].arguments == .object([
            "projectPath": .string("/p.json"), "heavyFolders": .array([.string("storage"), .string("dist")]),
        ]))
        // A list holding anything but strings is not Go's shape: it is not forwarded.
        #expect(calls[2].arguments == .object(["projectPath": .string("/p.json")]))
    }
}

@Suite @MainActor struct WindowEditorSettingsTests {
    /// With no wakil-ctx answering, the window keeps the defaults rather than failing.
    @Test func aReadThatFailsKeepsTheDefaults() async throws {
        let (model, _, _) = await editorWindowParts(roots: ["/p/api"])
        await model.refreshEditorSettings()
        #expect(model.editorSettings == .defaults)
    }

    @Test func anOrgSwitchResetsTheEditorSettings() async throws {
        let (model, _, _) = await editorWindowParts(roots: ["/p/api"])
        model.editorSettings = EditorSettings(
            app: SettingsEditor(fontSize: 20, wordWrap: true, autosave: .pause),
            project: .defaults, appError: nil)
        await model.invalidateForOrgChange()
        #expect(model.editorSettings == .defaults)
    }

    /// A refused write answers its sentence, for the pane to show beside the field.
    @Test func aRefusedWriteAnswersItsSentence() async throws {
        let (model, _, _) = await editorWindowParts(roots: ["/p/api"])
        let refusal = await model.saveEditorSettings(["fontSize": .integer(14)])
        #expect(refusal?.isEmpty == false)
    }
}

/// The ghost-text switch travels with the other app-wide editor fields, and only as a boolean.
@Test func theGhostTextSwitchIsForwarded() async throws {
    let caller = GhostRecordingCaller()
    let registry = ActionRegistry(
        journalDirectory: testScratchRoot.appendingPathComponent(UUID().uuidString), sessionId: "ghost-switch")
    await registerStandardActions(into: registry, context: caller, panes: PaneStore(), db: nil, resumes: ResumeBroker())
    _ = try await registry.dispatch(
        name: "ctx_set_editor_settings", params: .object(["ghostText": .bool(false)]),
        origin: .ui, caller: .test("staging"), confirmation: nil)
    _ = try await registry.dispatch(
        name: "ctx_set_editor_settings", params: .object(["ghostText": .string("off")]),
        origin: .ui, caller: .test("staging"), confirmation: nil)
    #expect(await caller.arguments == [.object(["ghostText": .bool(false)]), .object([:])])
}

private actor GhostRecordingCaller: ToolCaller {
    private(set) var arguments: [JSONValue] = []
    func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        self.arguments.append(arguments)
        return .object(["structuredContent": .object([:])])
    }
}
