import Foundation
import Testing
@testable import WakilKit

/// A quick model that answers one reply after an optional delay, and counts what it was asked.
private actor ScriptedQuickModel: QuickModel {
    nonisolated let serves: Set<QuickOperation>
    private let reply: String
    private let delay: Duration
    /// How many calls wait `delay`; the rest answer at once.
    private let slowCalls: Int
    private(set) var calls = 0
    private(set) var shutdowns = 0

    init(serves: Set<QuickOperation>, reply: String, delay: Duration = .zero, slowCalls: Int = .max) {
        self.serves = serves
        self.reply = reply
        self.delay = delay
        self.slowCalls = slowCalls
    }

    func infill(_ request: InfillRequest) async throws -> String {
        calls += 1
        if delay > .zero, calls <= slowCalls { try await Task.sleep(for: delay) }
        return reply
    }

    func respond(_ request: RespondRequest) async throws -> String { try await infill(InfillRequest(
        prefix: request.input, suffix: "", path: "", language: "", extras: [], multiline: false)) }

    func shutdown() async { shutdowns += 1 }
}

/// What the factory was asked for, in order.
private actor FactoryLog {
    private(set) var asked: [(record: QuickProviderRecord, org: String)] = []
    func note(_ record: QuickProviderRecord, _ org: String) { asked.append((record, org)) }
}

/// `wakil-ctx` as far as quick tasks need it: a config tree that the settings writes change, and a
/// `get_context` naming whichever organisation the switch went to.
private actor QuickBackend: ToolCaller {
    var tree: JSONValue
    var org: String
    var active: String
    /// When set, `config_tree` answers this tool error instead of the tree.
    var configFailure: String?
    /// The provider ids `unlink_provider` was asked to remove.
    var removed: [String] = []
    /// The arguments `update_org` was last called with.
    private(set) var lastUpdateOrg: [String: JSONValue]?

    func fail(_ message: String?) { configFailure = message }

    init(tree: JSONValue, org: String = "initech", active: String = "") {
        self.tree = tree
        self.org = org
        self.active = active
    }

    func use(org: String, tree: JSONValue) {
        self.org = org
        self.tree = tree
    }

    func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        switch name {
        case "config_tree":
            if let configFailure {
                return .object([
                    "isError": .bool(true),
                    "content": .array([.object(["type": .string("text"), "text": .string(configFailure)])]),
                ])
            }
            return .object(["structuredContent": tree])
        case "get_context":
            return .object(["structuredContent": .object([
                "Org": .string(org), "Environment": .string(""),
                "RootPaths": .array([]), "ActiveProvider": .string(active),
            ])])
        case "set_editor_settings":
            if case .object(let fields) = arguments, case .bool(let on)? = fields["ghostText"],
               case .object(var root) = tree {
                root["editor"] = .object(["ghostText": .bool(on)])
                tree = .object(root)
            }
            return .object(["structuredContent": .object([:])])
        case "update_org":
            if case .object(let fields) = arguments, case .object(var root) = tree,
               case .object(var org)? = root["org"] {
                lastUpdateOrg = fields
                for (key, value) in fields where key != "id" { org[key] = value }
                root["org"] = .object(org)
                tree = .object(root)
            }
            return .object(["structuredContent": .object([:])])
        case "set_local_provider":
            if case .object(let fields) = arguments, case .object(var root) = tree {
                var provider = fields
                provider["kind"] = .string("local")
                // Go resolves what a local model serves (3b-ix); the app no longer sends it.
                provider["serves"] = .array([.string("infill"), .string("respond")])
                root["providers"] = .array([.object(provider)])
                tree = .object(root)
            }
            return .object(["structuredContent": .object([:])])
        case "unlink_provider":
            // Go clears the gone provider from `quickProvider` too (`UnlinkProvider`'s pointers).
            if case .object(let fields) = arguments, case .string(let id)? = fields["id"],
               case .object(var root) = tree, case .array(let providers)? = root["providers"],
               case .object(var org)? = root["org"] {
                root["providers"] = .array(providers.filter {
                    if case .object(let p) = $0 { return p["id"] != .string(id) } else { return true }
                })
                if org["quickProvider"] == .string(id) { org["quickProvider"] = .string("") }
                root["org"] = .object(org)
                tree = .object(root)
                removed.append(id)
            }
            return .object(["structuredContent": .object(["recordRemoved": .bool(true)])])
        default:
            return .object(["structuredContent": .object([:])])
        }
    }
}

private func treeJSON(org: String = "initech", quick: String, ghost: Bool, baseURL: String = "http://127.0.0.1:8012")
    -> JSONValue
{
    .object([
        "org": .object(["id": .string(org), "quickProvider": .string(quick), "ghostText": .bool(ghost)]),
        "providers": .array([
            .object([
                "id": .string("qwen"), "kind": .string("local"),
                "baseURL": .string(baseURL), "serves": .array([.string("infill")]),
            ]),
            .object([
                "id": .string("main"), "kind": .string("claude-code"),
                "serves": .array([.string("infill"), .string("respond")]),
            ]),
        ]),
        "projects": .array([]),
        "editor": .object(["ghostText": .bool(ghost)]),
    ])
}

private let anyRequest = InfillRequest(prefix: "a", suffix: "", path: "", language: "", extras: [], multiline: false)

@MainActor
private func makeWindow(
    tree: JSONValue, providerId: String = "test-provider",
    factory: @escaping @Sendable (QuickProviderRecord, String) async throws -> (any QuickModel)?
) async -> WindowModel {
    let model = WindowModel.forTesting(
        scratchRoot: testScratchRoot, organization: "initech",
        context: ContextStore(client: QuickBackend(tree: tree)), providerId: providerId,
        quickModelFactory: factory)
    await model.rebuildQuickTasks()
    return model
}

/// A window whose registry carries the real settings actions, so a save goes through `dispatch`
/// as the pane's does.
@MainActor
private func makeSettingsWindow(
    backend: QuickBackend,
    factory: @escaping @Sendable (QuickProviderRecord, String) async throws -> (any QuickModel)?
) async throws -> WindowModel {
    let dir = testScratchRoot.appendingPathComponent("quick-tasks-\(UUID().uuidString)")
    let registry = ActionRegistry(journalDirectory: dir, sessionId: "quick-tasks")
    let panes = PaneStore(kinds: PaneKinds.standard)
    await registerStandardActions(into: registry, context: backend, panes: panes, db: nil, resumes: ResumeBroker())
    let model = WindowModel(
        registry: registry, panes: panes, layout: LayoutStore(), context: ContextStore(client: backend),
        harnessFactory: { _, _, _ in nil }, resumes: ResumeBroker(),
        rootPath: "/tmp/wakil-quick-tasks", providerId: "main",
        lookupFactory: { _ in AlwaysSucceedsCredentialsLookupForTesting() },
        quickModelFactory: factory, environment: "")
    model.setOrganizationForTesting("initech")
    await model.rebuildQuickTasks()
    return model
}

@Suite @MainActor struct WindowModelQuickTasksTests {
    @Test func ghostSuggestionRoutesThroughTheQuickProvider() async throws {
        let fake = ScriptedQuickModel(serves: [.infill], reply: "ConfirmedAt = time.Now()")
        let model = await makeWindow(tree: treeJSON(quick: "qwen", ghost: true)) { record, _ in
            record.id == "qwen" ? fake : nil
        }
        let r = InfillRequest(prefix: "b.", suffix: "", path: "a.go", language: "go", extras: [], multiline: false)
        #expect(model.ghostTextEnabled)
        #expect(await model.ghostSuggestion(pane: "p1", request: r, generation: model.quickTasksGeneration) == "ConfirmedAt = time.Now()")
        #expect(await model.ghostDebounce() == .milliseconds(250))
        #expect(await model.quickTaskStatus() == QuickTaskStatus(answered: ["qwen"], routedInfill: "qwen"))
    }

    /// With no quick provider the active one answers, and a session-backed model waits longer.
    @Test func theActiveProviderAnswersWhenNoQuickProviderIsChosen() async throws {
        let log = FactoryLog()
        let fake = ScriptedQuickModel(serves: [.infill, .respond], reply: "x")
        let model = await makeWindow(tree: treeJSON(quick: "", ghost: true), providerId: "main") { record, org in
            await log.note(record, org)
            return fake
        }
        #expect(await model.ghostSuggestion(pane: "p1", request: anyRequest, generation: model.quickTasksGeneration) == "x")
        let asked = await log.asked
        #expect(asked.map(\.record.id) == ["main"])
        #expect(asked.map(\.org) == ["initech"])
        #expect(asked.first?.record.serves == [.infill, .respond])
        #expect(await model.ghostDebounce() == .milliseconds(500))
    }

    @Test func switchedOffAsksNothing() async {
        let fake = ScriptedQuickModel(serves: [.infill], reply: "x")
        let model = await makeWindow(tree: treeJSON(quick: "qwen", ghost: false)) { _, _ in fake }
        #expect(!model.ghostTextEnabled)
        #expect(await model.ghostSuggestion(pane: "p1", request: anyRequest, generation: model.quickTasksGeneration) == nil)
        #expect(await fake.calls == 0)
    }

    @Test func orgSwitchCancelsAndRebuilds() async throws {
        let slow = ScriptedQuickModel(serves: [.infill], reply: "old org", delay: .seconds(5))
        let model = await makeWindow(tree: treeJSON(quick: "qwen", ghost: true)) { _, _ in slow }
        let pending = Task { await model.ghostSuggestion(pane: "p1", request: anyRequest, generation: model.quickTasksGeneration) }
        // Past the debounce and into the model call, however loaded the machine is.
        while await slow.calls == 0 { try await Task.sleep(for: .milliseconds(20)) }
        await model.rebuildQuickTasks()          // what the org-switch path calls
        #expect(await pending.value == nil)
        #expect(await slow.shutdowns == 1)
    }

    /// The org switch itself rebuilds: the new organisation's tree is read and its models made for it.
    @Test func theOrgSwitchRebuildsForTheNewOrganisation() async throws {
        let log = FactoryLog()
        let old = ScriptedQuickModel(serves: [.infill], reply: "alpha")
        let new = ScriptedQuickModel(serves: [.infill], reply: "beta")
        let backend = QuickBackend(tree: treeJSON(org: "alpha", quick: "qwen", ghost: true), org: "alpha")
        let model = WindowModel.forTesting(
            scratchRoot: testScratchRoot, organization: "alpha",
            context: ContextStore(client: backend),
            quickModelFactory: { record, org in
                await log.note(record, org)
                return org == "alpha" ? old : new
            })
        await model.rebuildQuickTasks()
        #expect(await model.ghostSuggestion(pane: "p1", request: anyRequest, generation: model.quickTasksGeneration) == "alpha")

        await backend.use(org: "beta", tree: treeJSON(org: "beta", quick: "qwen", ghost: true))
        await model.setOrganization("beta")

        #expect(model.organization == "beta")
        #expect(await old.shutdowns == 1)
        #expect(await model.ghostSuggestion(pane: "p1", request: anyRequest, generation: model.quickTasksGeneration) == "beta")
        #expect(await log.asked.map(\.org) == ["alpha", "beta"])
    }

    /// Turning ghost-text off in Settings takes effect without reopening the window.
    @Test func savingTheGhostTextSwitchRebuilds() async throws {
        let backend = QuickBackend(tree: treeJSON(quick: "qwen", ghost: true))
        let fake = ScriptedQuickModel(serves: [.infill], reply: "x")
        let model = try await makeSettingsWindow(backend: backend) { _, _ in fake }
        #expect(model.ghostTextEnabled)

        #expect(await model.saveOrganisationSwitch(.ghostText, on: false) == nil)

        #expect(!model.ghostTextEnabled)
        #expect(await model.ghostSuggestion(pane: "p1", request: anyRequest, generation: model.quickTasksGeneration) == nil)
    }

    @Test func theOrgSwitchesDriveGhostTextAndTheFastPath() async {
        let tree: JSONValue = .object([
            "org": .object([
                "id": .string("initech"), "quickProvider": .string("qwen"),
                "ghostText": .bool(false), "fastPath": .bool(true),
            ]),
            "providers": .array([.object([
                "id": .string("qwen"), "kind": .string("local"), "baseURL": .string("http://127.0.0.1:8012"),
                "serves": .array([.string("infill"), .string("respond")]),
            ])]),
            "projects": .array([]),
            "editor": .object(["ghostText": .bool(true)]),
        ])
        let model = await makeWindow(tree: tree, providerId: "qwen") { _, _ in
            ScriptedQuickModel(serves: [.infill, .respond], reply: "x")
        }
        #expect(model.ghostTextEnabled == false)
        #expect(model.fastPathEnabled == true)
    }

    @Test func rebuildReadsTheConversationNamesSwitch() async {
        func tree(_ names: JSONValue?) -> JSONValue {
            var org: [String: JSONValue] = ["id": .string("initech"), "quickProvider": .string("qwen")]
            if let names { org["conversationNames"] = names }
            return .object([
                "org": .object(org),
                "providers": .array([.object([
                    "id": .string("qwen"), "kind": .string("local"), "baseURL": .string("http://127.0.0.1:8012"),
                ])]),
                "projects": .array([]),
            ])
        }
        let off = await makeWindow(tree: tree(.bool(false)), providerId: "qwen") { _, _ in
            ScriptedQuickModel(serves: [.respond], reply: "x")
        }
        #expect(off.conversationNamesEnabled == false)
        let unset = await makeWindow(tree: tree(nil), providerId: "qwen") { _, _ in
            ScriptedQuickModel(serves: [.respond], reply: "x")
        }
        #expect(unset.conversationNamesEnabled == true)
    }

    @Test func commitDraftsFollowsTheOrgSwitch() async {
        func tree(_ drafts: JSONValue?) -> JSONValue {
            var org: [String: JSONValue] = ["id": .string("initech"), "quickProvider": .string("qwen")]
            if let drafts { org["commitDrafts"] = drafts }
            return .object([
                "org": .object(org),
                "providers": .array([.object([
                    "id": .string("qwen"), "kind": .string("local"), "baseURL": .string("http://127.0.0.1:8012"),
                ])]),
                "projects": .array([]),
            ])
        }
        let off = await makeWindow(tree: tree(.bool(false)), providerId: "qwen") { _, _ in
            ScriptedQuickModel(serves: [.respond], reply: "x")
        }
        #expect(off.commitDraftsEnabled == false)
        // A tree from before 3a-ii-b carries no switch: on.
        let unset = await makeWindow(tree: tree(nil), providerId: "qwen") { _, _ in
            ScriptedQuickModel(serves: [.respond], reply: "x")
        }
        #expect(unset.commitDraftsEnabled == true)
    }

    @Test func savingASwitchDispatchesUpdateOrgWithABoolean() async throws {
        let backend = QuickBackend(tree: treeJSON(quick: "qwen", ghost: true))
        let model = try await makeSettingsWindow(backend: backend) { _, _ in
            ScriptedQuickModel(serves: [.infill], reply: "x")
        }
        let refusal = await model.saveOrganisationSwitch(.fastPath, on: true)
        #expect(refusal == nil)
        #expect(await backend.lastUpdateOrg?["fastPath"] == .bool(true))
        #expect(model.fastPathEnabled == true)
    }

    /// A local model's new URL is what the next request reaches, and the old model is shut down.
    @Test func savingALocalProviderRebuilds() async throws {
        let log = FactoryLog()
        let backend = QuickBackend(tree: treeJSON(quick: "qwen", ghost: true))
        let first = ScriptedQuickModel(serves: [.infill], reply: "first")
        let second = ScriptedQuickModel(serves: [.infill], reply: "second")
        let model = try await makeSettingsWindow(backend: backend) { record, _ in
            await log.note(record, "")
            return record.baseURL == "http://127.0.0.1:8012" ? first : second
        }
        #expect(await model.ghostSuggestion(pane: "p1", request: anyRequest, generation: model.quickTasksGeneration) == "first")

        let refusal = await model.setLocalProvider(
            id: "qwen", label: "Qwen", baseURL: "http://127.0.0.1:9000")

        #expect(refusal == nil)
        #expect(await first.shutdowns == 1)
        #expect(await model.ghostSuggestion(pane: "p1", request: anyRequest, generation: model.quickTasksGeneration) == "second")
        #expect(await log.asked.last?.record.baseURL == "http://127.0.0.1:9000")
    }

    /// Removing the local model in Settings unlinks it in its own organisation, shuts its model
    /// down, and the next request goes to the agent's provider.
    @Test func removingALocalProviderUnlinksItAndFallsBack() async throws {
        let backend = QuickBackend(tree: treeJSON(quick: "qwen", ghost: true))
        let local = ScriptedQuickModel(serves: [.infill], reply: "local")
        let agent = ScriptedQuickModel(serves: [.infill], reply: "agent")
        let model = try await makeSettingsWindow(backend: backend) { record, _ in
            record.id == "qwen" ? local : agent
        }
        #expect(await model.ghostSuggestion(pane: "p1", request: anyRequest, generation: model.quickTasksGeneration) == "local")

        #expect(await model.removeLocalProvider(id: "qwen") == nil)

        #expect(await backend.removed == ["qwen"])
        #expect(await local.shutdowns == 1)
        #expect(await model.ghostSuggestion(pane: "p1", request: anyRequest, generation: model.quickTasksGeneration) == "agent")
    }

    /// A cancelled pane's request comes back empty, and the next request on that pane still answers.
    @Test func ghostCancelReleasesThePendingRequestOnly() async throws {
        let model0 = ScriptedQuickModel(serves: [.infill], reply: "next", delay: .seconds(5), slowCalls: 1)
        let model = await makeWindow(tree: treeJSON(quick: "qwen", ghost: true)) { _, _ in model0 }
        let pending = Task { await model.ghostSuggestion(pane: "p1", request: anyRequest, generation: model.quickTasksGeneration) }
        while await model0.calls == 0 { try await Task.sleep(for: .milliseconds(20)) }
        model.ghostCancel(pane: "p1")
        #expect(await pending.value == nil)
        #expect(await model.ghostSuggestion(pane: "p1", request: anyRequest, generation: model.quickTasksGeneration) == "next")
    }

    /// A closed pane's ghost session goes with it — whoever closed it — and an open pane's stays.
    @Test func closingAPaneReleasesItsGhostSession() async throws {
        let (model, _) = await editorWindowWithFiles()
        await model.refreshContext()
        #expect(await model.openPane(kind: "editor"))
        #expect(await model.openPane(kind: "editor"))
        let panes = model.layoutSnapshot.panes.map(\.id)
        try #require(panes.count == 2)
        for pane in panes {
            model.ghostSessions[pane] = GhostTextSession(suggest: { _ in "" }, debounce: { .zero })
        }
        #expect(await model.closePane(id: panes[0]))
        #expect(model.ghostSessions[panes[0]] == nil)
        #expect(model.ghostSessions[panes[1]] != nil)
    }

    /// Only a pane that LEFT the canvas loses its session: a refresh (the one every dispatch
    /// triggers) never drops one for a pane it has not seen go — its request may be in flight.
    @Test func aRefreshKeepsTheSessionOfAPaneItNeverSawClose() async throws {
        let (model, _) = await editorWindowWithFiles()
        await model.refreshContext()
        model.ghostSessions["p1"] = GhostTextSession(suggest: { _ in "" }, debounce: { .zero })
        await model.refreshLayout()
        #expect(model.ghostSessions["p1"] != nil)
    }

    /// A configuration that cannot be read stops ghost-text, and Settings is told why, whole (Rule 8);
    /// the next rebuild that reads it clears the reason.
    @Test func anUnreadableConfigurationIsReportedWholeAndClearedOnRecovery() async throws {
        let backend = QuickBackend(tree: treeJSON(quick: "qwen", ghost: true))
        let why = "config_tree: org.json: unexpected end of JSON input at line 7"
        await backend.fail(why)
        let fake = ScriptedQuickModel(serves: [.infill], reply: "x")
        let model = WindowModel.forTesting(
            scratchRoot: testScratchRoot, organization: "initech",
            context: ContextStore(client: backend), quickModelFactory: { _, _ in fake })
        await model.rebuildQuickTasks()
        #expect(await model.quickTaskStatus().configError == why)
        #expect(await model.quickTaskStatus().errors == [:])
        #expect(await model.ghostSuggestion(pane: "p1", request: anyRequest, generation: model.quickTasksGeneration) == nil)

        await backend.fail(nil)
        await model.rebuildQuickTasks()
        #expect(await model.quickTaskStatus().configError == nil)
        #expect(await model.ghostSuggestion(pane: "p1", request: anyRequest, generation: model.quickTasksGeneration) == "x")
    }

    @Test func endpointErrorsReachTheWindow() async throws {
        struct Down: QuickModel {
            let serves: Set<QuickOperation> = [.infill]
            func infill(_ request: InfillRequest) async throws -> String {
                throw QuickModelError.unreachable("connection refused at http://127.0.0.1:8012")
            }
            func respond(_ request: RespondRequest) async throws -> String { "" }
            func shutdown() async {}
        }
        let model = await makeWindow(tree: treeJSON(quick: "qwen", ghost: true)) { _, _ in Down() }
        #expect(await model.ghostSuggestion(pane: "p1", request: anyRequest, generation: model.quickTasksGeneration) == nil)
        let status = await model.quickTaskStatus()
        #expect(status.errors == ["qwen": "connection refused at http://127.0.0.1:8012"])
        #expect(status.routedInfill == "qwen")
        #expect(status.answered.isEmpty)
    }

    /// A provider named "config" keeps its own error: the configuration's is not in the same map.
    @Test func aProviderIdConfigDoesNotCollideWithTheConfigurationError() async throws {
        struct Down: QuickModel {
            let serves: Set<QuickOperation> = [.infill]
            func infill(_ request: InfillRequest) async throws -> String { throw QuickModelError.failed("HTTP 500") }
            func respond(_ request: RespondRequest) async throws -> String { "" }
            func shutdown() async {}
        }
        let tree: JSONValue = .object([
            "org": .object(["id": .string("initech"), "quickProvider": .string("config")]),
            "providers": .array([.object([
                "id": .string("config"), "kind": .string("local"),
                "baseURL": .string("http://127.0.0.1:8012"), "serves": .array([.string("infill")]),
            ])]),
            "projects": .array([]),
            "editor": .object(["ghostText": .bool(true)]),
        ])
        let model = await makeWindow(tree: tree) { _, _ in Down() }
        #expect(await model.ghostSuggestion(pane: "p1", request: anyRequest, generation: model.quickTasksGeneration) == nil)
        let status = await model.quickTaskStatus()
        #expect(status.errors == ["config": "HTTP 500"])
        #expect(status.configError == nil)
    }

    /// A request built in one organisation is never asked of the next one's model (Invariant 4):
    /// the scope it was built in carries the generation, and a rebuild in between makes it stale.
    @Test func aRequestBuiltBeforeAnOrgSwitchIsNeverAskedOfTheNewOrg() async throws {
        let old = ScriptedQuickModel(serves: [.infill], reply: "alpha")
        let new = ScriptedQuickModel(serves: [.infill], reply: "beta")
        let backend = QuickBackend(tree: treeJSON(org: "alpha", quick: "qwen", ghost: true), org: "alpha")
        let model = WindowModel.forTesting(
            scratchRoot: testScratchRoot, organization: "alpha",
            context: ContextStore(client: backend),
            quickModelFactory: { _, org in org == "alpha" ? old : new })
        await model.rebuildQuickTasks()
        let scope = await model.ghostSchema()

        await backend.use(org: "beta", tree: treeJSON(org: "beta", quick: "qwen", ghost: true))
        await model.setOrganization("beta")

        #expect(await model.ghostSuggestion(pane: "p1", request: anyRequest, generation: scope.generation) == nil)
        #expect(await new.calls == 0)
        #expect(await old.calls == 0)
        // A request built now, in the new organisation, is asked.
        let fresh = await model.ghostSchema()
        #expect(await model.ghostSuggestion(pane: "p1", request: anyRequest, generation: fresh.generation) == "beta")
    }

    /// The schema's tables regroup from the vocabulary's names in the order they were gathered, so a
    /// column named like another table's keeps its own table.
    @Test func theVocabularyKeepsTheGatheredOrder() {
        let names = [
            Identifier(text: "bookings", kind: .table, origin: "core", source: .schema),
            Identifier(text: "id", kind: .column, origin: "core", source: .schema),
            Identifier(text: "guests", kind: .table, origin: "core", source: .schema),
            Identifier(text: "id", kind: .column, origin: "core", source: .schema),
        ]
        #expect(GhostSchema.tables(from: Vocabulary(names).names) == [
            GhostTable(name: "bookings", columns: ["id"]), GhostTable(name: "guests", columns: ["id"]),
        ])
    }
}
