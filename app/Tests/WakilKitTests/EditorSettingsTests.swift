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

    /// 3c-i. The browser tier rides in the same tree; an older answer without it reads as the defaults.
    @Test func theTreeDecodesTheBrowserTier() throws {
        func tree(_ extra: String) throws -> SettingsTree {
            let json = """
            {"structuredContent":{"org":{"id":"acme","displayName":"","jiraBase":"","defaultProvider":""},
             "providers":[],"projects":[]\(extra)}}
            """
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
            return try #require(decodeSettingsTree(fromResult: value))
        }
        #expect(try tree(#","browser":{"searchEngine":"kagi","startPage":"https://example.com"}"#).browser
            == SettingsBrowser(searchEngine: "kagi", startPage: "https://example.com"))
        #expect(try tree("").browser == SettingsBrowser.defaults)
        #expect(SettingsBrowser.defaults == SettingsBrowser(searchEngine: "google", startPage: ""))
    }

    /// 3c-i. The browser setting is the operator's to write, as its editor twin is; the agent may read it.
    @Test func theBrowserSettingWriteIsOperatorOnlyAndTheReadIsNot() async throws {
        let (registry, _) = try await registryWithRecordingContext()
        let set = try #require(await registry.all().first { $0.name == "ctx_set_browser_settings" })
        let read = try #require(await registry.all().first { $0.name == "ctx_browser_settings" })
        #expect(set.audience == .operatorOnly && set.kind == .control)
        #expect(read.audience == .agentReachable && read.kind == .read)
        #expect(operatorOnlyActions.contains("ctx_set_browser_settings"))
        #expect(!operatorOnlyActions.contains("ctx_browser_settings"))
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

    /// 3c-iii. A call that sets only `searchSuggestions` reaches the tool; it was dropped silently.
    @Test func theBrowserWriteForwardsSearchSuggestionsAlone() async throws {
        let (registry, caller) = try await registryWithRecordingContext()
        _ = try await registry.dispatch(
            name: "ctx_set_browser_settings", params: .object(["searchSuggestions": .bool(true)]),
            origin: .ui, caller: .test("staging"), confirmation: nil)
        let calls = await caller.recorded()
        guard calls.count == 1, case .object(let arguments) = calls[0].arguments else {
            Issue.record("expected one call, got \(calls)"); return
        }
        #expect(calls[0].tool == "set_browser_settings")
        #expect(arguments == ["searchSuggestions": .bool(true)])
    }

    /// 3d-i. `tabs` and `nameGroups` reach the tool, `false` included.
    @Test func theBrowserWriteForwardsTabsAndNameGroups() async throws {
        let (registry, caller) = try await registryWithRecordingContext()
        _ = try await registry.dispatch(
            name: "ctx_set_browser_settings",
            params: .object(["tabs": .string("vertical"), "nameGroups": .bool(false)]),
            origin: .ui, caller: .test("staging"), confirmation: nil)
        let calls = await caller.recorded()
        guard calls.count == 1, case .object(let arguments) = calls[0].arguments else {
            Issue.record("expected one call, got \(calls)"); return
        }
        #expect(arguments == ["tabs": .string("vertical"), "nameGroups": .bool(false)])
    }

    // 3a-v-a e2e audit: Inline blame's Off never reached Go.
    @Test func theAppWriteForwardsInlineBlame() async throws {
        let (registry, caller) = try await registryWithRecordingContext()
        _ = try await registry.dispatch(
            name: "ctx_set_editor_settings", params: .object(["inlineBlame": .bool(false)]),
            origin: .ui, caller: .test("staging"), confirmation: nil)
        let calls = await caller.recorded()
        guard calls.count == 1, case .object(let arguments) = calls[0].arguments else {
            Issue.record("expected one call, got \(calls)"); return
        }
        #expect(arguments == ["inlineBlame": .bool(false)])
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
            #expect(reason.contains("only the operator changes editor settings"))
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

/// 3a-ii-b: the commit-drafts switch reaches `update_org` with the other quick-task switches, and
/// only as a boolean (found by the e2e run: the action forwarded it nowhere, and Settings' Off did nothing).
@Test func theCommitDraftsSwitchIsForwarded() async throws {
    let caller = GhostRecordingCaller()
    let registry = ActionRegistry(
        journalDirectory: testScratchRoot.appendingPathComponent(UUID().uuidString), sessionId: "drafts-switch")
    await registerStandardActions(into: registry, context: caller, panes: PaneStore(), db: nil, resumes: ResumeBroker())
    _ = try await registry.dispatch(
        name: "ctx_update_org", params: .object(["id": .string("o"), "commitDrafts": .bool(false)]),
        origin: .ui, caller: .test("staging"), confirmation: nil)
    _ = try await registry.dispatch(
        name: "ctx_update_org", params: .object(["id": .string("o"), "commitDrafts": .string("off")]),
        origin: .ui, caller: .test("staging"), confirmation: nil)
    #expect(await caller.arguments == [.object(["id": .string("o"), "commitDrafts": .bool(false)]), .object(["id": .string("o")])])
}

/// 3a-iii-a: the pull strategy reaches `update_org` as a string, and the account tools forward their
/// fields (the 3a-ii-b lesson: a key not forwarded is dropped silently).
@Test func thePullStrategyAndTheAccountToolsAreForwarded() async throws {
    let caller = GhostRecordingCaller()
    let registry = ActionRegistry(
        journalDirectory: testScratchRoot.appendingPathComponent(UUID().uuidString), sessionId: "git-accounts")
    await registerStandardActions(into: registry, context: caller, panes: PaneStore(), db: nil, resumes: ResumeBroker())
    _ = try await registry.dispatch(
        name: "ctx_update_org", params: .object(["id": .string("o"), "pullStrategy": .string("merge")]),
        origin: .ui, caller: .test("staging"), confirmation: nil)
    _ = try await registry.dispatch(
        name: "ctx_git_account_add",
        params: .object(["id": .string("o"), "host": .string("github.com"), "provider": .string("github"),
                         "method": .string("ssh"), "keyPath": .string("/k")]),
        origin: .ui, caller: .test("staging"), confirmation: nil)
    _ = try await registry.dispatch(
        name: "ctx_git_account_remove", params: .object(["id": .string("o"), "host": .string("github.com")]),
        origin: .ui, caller: .test("staging"), confirmation: nil)
    #expect(await caller.arguments == [
        .object(["id": .string("o"), "pullStrategy": .string("merge")]),
        .object(["id": .string("o"), "host": .string("github.com"), "provider": .string("github"),
                 "method": .string("ssh"), "keyPath": .string("/k")]),
        .object(["id": .string("o"), "host": .string("github.com")]),
    ])
    let d = try #require(await registry.descriptor(named: "ctx_git_account_add"))
    #expect(d.audience == .operatorOnly)
}

/// 3a-iii-a: a token and a passphrase reach their tools but never the journal.
@Test func gitSecretsNeverReachTheJournal() async throws {
    let caller = GhostRecordingCaller()
    let dir = testScratchRoot.appendingPathComponent(UUID().uuidString)
    let registry = ActionRegistry(journalDirectory: dir, sessionId: "git-secrets")
    await registerStandardActions(into: registry, context: caller, panes: PaneStore(), db: nil, resumes: ResumeBroker())
    _ = try await registry.dispatch(
        name: "ctx_git_token_set", params: .object(["id": .string("o"), "host": .string("github.com"), "token": .string("tok-SECRET-1")]),
        origin: .ui, caller: .test("staging"), confirmation: nil)
    _ = try await registry.dispatch(
        name: "ctx_git_key_passphrase_set",
        params: .object(["id": .string("o"), "host": .string("github.com"), "passphrase": .string("pass-SECRET-2")]),
        origin: .ui, caller: .test("staging"), confirmation: nil)
    #expect(await caller.arguments.count == 2)
    let journal = try String(contentsOf: try #require(FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?
        .compactMap { $0 as? URL }.first { $0.pathExtension == "jsonl" }), encoding: .utf8)
    #expect(!journal.contains("tok-SECRET-1"))
    #expect(!journal.contains("pass-SECRET-2"))
}

/// An SSH GitHub account's API access token reaches its tool and never the journal; the device poll
/// carries `apiAccess` as a boolean.
@Test func apiAccessTokenIsRedactedInTheJournal() async throws {
    let caller = GhostRecordingCaller()
    let dir = testScratchRoot.appendingPathComponent(UUID().uuidString)
    let registry = ActionRegistry(journalDirectory: dir, sessionId: "api-access-secret")
    await registerStandardActions(into: registry, context: caller, panes: PaneStore(), db: nil, resumes: ResumeBroker())
    _ = try await registry.dispatch(
        name: "ctx_git_api_access_token_set",
        params: .object(["id": .string("o"), "host": .string("github.com"), "token": .string("tok-SECRET-9")]),
        origin: .ui, caller: .test("staging"), confirmation: nil)
    #expect(await caller.arguments == [.object(["id": .string("o"), "host": .string("github.com"), "token": .string("tok-SECRET-9")])])
    let journal = try String(contentsOf: try #require(FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?
        .compactMap { $0 as? URL }.first { $0.pathExtension == "jsonl" }), encoding: .utf8)
    #expect(!journal.contains("tok-SECRET-9"))
}

/// Setting, testing or removing an account's API access moves a credential, so an agent is refused.
@Test func apiAccessActionsAreOperatorOnly() async throws {
    let caller = GhostRecordingCaller()
    let registry = ActionRegistry(
        journalDirectory: testScratchRoot.appendingPathComponent(UUID().uuidString), sessionId: "api-access-agent")
    await registerStandardActions(into: registry, context: caller, panes: PaneStore(), db: nil, resumes: ResumeBroker())
    for name in ["ctx_git_api_access_token_set", "ctx_git_api_access_remove", "ctx_git_api_access_test"] {
        let d = try #require(await registry.descriptor(named: name))
        #expect(d.audience == .operatorOnly)
        #expect(operatorOnlyActions.contains(name))
        await #expect(throws: (any Error).self) {
            _ = try await registry.dispatch(
                name: name, params: .object(["id": .string("o"), "host": .string("github.com"), "token": .string("t")]),
                origin: .agent, caller: .test("staging"), confirmation: nil)
        }
    }
    #expect(await caller.arguments.isEmpty)
}

/// 3a-iii-b: the organisation's three agent texts reach `update_org`, and the tree reads both levels.
@Test func theAgentTextsAreForwardedAndRead() async throws {
    let caller = GhostRecordingCaller()
    let registry = ActionRegistry(
        journalDirectory: testScratchRoot.appendingPathComponent(UUID().uuidString), sessionId: "agent-texts")
    await registerStandardActions(into: registry, context: caller, panes: PaneStore(), db: nil, resumes: ResumeBroker())
    _ = try await registry.dispatch(
        name: "ctx_update_org", params: .object(["id": .string("o"), "gitCommitInstructions": .string("Imperative subject")]),
        origin: .ui, caller: .test("staging"), confirmation: nil)
    _ = try await registry.dispatch(
        name: "ctx_set_project_agent_instructions",
        params: .object(["projectPath": .string("/p/project.json"), "general": .string("Ask first")]),
        origin: .ui, caller: .test("staging"), confirmation: nil)
    #expect(await caller.arguments == [
        .object(["id": .string("o"), "gitCommitInstructions": .string("Imperative subject")]),
        .object(["projectPath": .string("/p/project.json"), "general": .string("Ask first")]),
    ])
    let json = #"{"id":"o","agentGeneral":"G","gitCommitInstructions":"C","gitPRInstructions":"P"}"#
    let org = try JSONDecoder().decode(SettingsOrg.self, from: Data(json.utf8))
    #expect(org.agentGeneral == "G" && org.gitCommitInstructions == "C" && org.gitPRInstructions == "P")
    let project = try JSONDecoder().decode(SettingsProject.self, from: Data(#"{"name":"api","agent":{"commits":"K"}}"#.utf8))
    #expect(project.agent == SettingsAgentTexts(general: "", commits: "K", pullRequests: ""))
}

/// 3c-i. The browser actions read a cache the window keeps, so a new tab reads memory and writes
/// no journal line.
@Suite @MainActor struct WindowBrowserSettingsTests {
    @Test func aReadThatFailsKeepsTheDefaultsAndLeavesTheCacheEmpty() async throws {
        let (model, _, _) = await editorWindowParts(roots: ["/p/api"])
        await model.refreshBrowserSettings()
        #expect(model.browserSettings == .defaults)
        #expect(model.browserSettingsCache.current == nil)
    }

    /// A write that reaches the registry by another route — a socket call, an e2e dispatch — never
    /// passes `saveBrowserSettings`, so the window re-reads on seeing it go by (night run 2026-10-29:
    /// the vertical tab column stayed hidden after a dispatched `tabs: vertical`).
    @Test func aWriteFromAnotherRouteIsReadBack() async throws {
        let (model, _, _) = await editorWindowParts(roots: ["/p/api"])
        let registry = model.registryForTesting
        let stored = StoredTabs()
        await registry.register(Action(name: "ctx_browser_settings", description: "", kind: .read,
                                       schema: .object([:])) { _ in
            .object(["structuredContent": .object([
                "searchEngine": .string("google"), "startPage": .string(""), "tabs": .string(await stored.tabs)])])
        })
        await registry.register(Action(name: "ctx_set_browser_settings", description: "", kind: .control,
                                       schema: .object([:])) { _ in
            await stored.set("vertical")
            return .object([:])
        })
        _ = try await registry.dispatch(
            name: "ctx_set_browser_settings", params: .object(["tabs": .string("vertical")]), origin: .ui,
            caller: DispatchCaller(place: model.place, session: nil), confirmation: nil)
        for _ in 0..<100 where model.browserSettings.tabs != "vertical" { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.browserSettings.tabs == "vertical")
    }

    private actor StoredTabs {
        var tabs = "horizontal"
        func set(_ value: String) { tabs = value }
    }

    @Test func aRefusedWriteAnswersItsSentence() async throws {
        let (model, _, _) = await editorWindowParts(roots: ["/p/api"])
        let refusal = await model.saveBrowserSettings(["searchEngine": .string("kagi")])
        #expect(refusal?.isEmpty == false)
    }

    @Test func theCacheReadsOnceThenServesWhatItHolds() async throws {
        let cache = BrowserSettingsCache()
        let count = ReadCounter()
        let first = await cache.value { count.bump(); return SettingsBrowser(searchEngine: "bing", startPage: "") }
        let second = await cache.value { count.bump(); return nil }
        #expect(first.searchEngine == "bing")
        #expect(second.searchEngine == "bing")
        #expect(count.value == 1)
        cache.current = SettingsBrowser(searchEngine: "kagi", startPage: "")
        #expect(await cache.value { nil }.searchEngine == "kagi")
    }
}

private final class ReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}
