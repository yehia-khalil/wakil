import Foundation
import Testing
@testable import WakilKit

// Names phase, Task 6: `conversation_rename` names a conversation — the operator's name wins over the
// model's, empty clears, an agent renames only its own — and names persist under the lineage root
// (spec, "Calls made" 2, 3, 4, 8; Rules 6, 7, 8).

private let org = "initech"
private let place = Place(organization: org, project: "api", environment: "staging")

/// A quick model that names every conversation "Model".
private actor ModelNamer: QuickModel {
    nonisolated let serves: Set<QuickOperation> = [.respond]
    func infill(_ request: InfillRequest) async throws -> String { throw QuickModelError.unsupported(.infill) }
    func respond(_ request: RespondRequest) async throws -> String { #"{"name": "Model"}"# }
    func shutdown() async {}
}

/// `wakil-ctx` as far as the quick tasks need it: conversation names on, a local `respond` model.
private actor NamesBackend: ToolCaller {
    func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        guard name == "config_tree" else { return .object(["structuredContent": .object([:])]) }
        return .object(["structuredContent": .object([
            "org": .object(["id": .string(org), "quickProvider": .string("qwen"), "conversationNames": .bool(true)]),
            "providers": .array([.object([
                "id": .string("qwen"), "kind": .string("local"), "baseURL": .string("http://127.0.0.1:8012"),
                "serves": .array([.string("respond")]),
            ])]),
            "projects": .array([]),
        ])])
    }
}

@MainActor
private func waitUntil(_ condition: @MainActor () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(2 * testWaitLoadMultiplier)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    return await condition()
}

@MainActor
private struct Fixture {
    let model: WindowModel
    let harnesses: Harnesses
    let home: URL

    var wakil: URL { home.appendingPathComponent(".wakil", isDirectory: true) }
    var file: ConversationNameFile { ConversationNameFile(org: org, home: wakil) }

    /// `thoughts > 0` puts a conversation on screen that has no lineage root yet.
    init(thoughts: Int = 0) async throws {
        let harnesses = Harnesses()
        self.harnesses = harnesses
        let requests = ConversationBroker()
        let model = WindowModel.forTesting(
            scratchRoot: testScratchRoot, organization: org,
            harnessFactory: { place, _ in harnesses.make(place) },
            context: ContextStore(client: NamesBackend()), providerId: "qwen",
            quickModelFactory: { _, _ in ModelNamer() }, conversationRequests: requests)
        await model.registryForTesting.register(conversationRenameAction(
            conversationRequests: requests,
            liveConversations: { [weak model] place in await model?.liveConversationRows(in: place) ?? [] }))
        home = testScratchRoot.appendingPathComponent("rename-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".wakil/orgs/\(org)", isDirectory: true), withIntermediateDirectories: true)
        model.browserHome = home
        model.seedForTesting(
            providerId: "qwen", rootPath: "/tmp/wakil-window-model-for-testing", thoughts: thoughts,
            project: place.project, environment: place.environment)
        await model.rebuildQuickTasks()
        self.model = model
    }

    /// Sends `text` and ends its turn cleanly, the naming it started settled.
    @discardableResult
    func turn(_ text: String = "fix the login test") async throws -> PlaceAgent {
        #expect(await model.send(text))
        let agent = try #require(model.currentAgent)
        let harness = try #require(harnesses.in(place).last)
        harness.emit(.assistantText("Looking at auth"))
        harness.emit(.result(isError: false, text: nil))
        #expect(await waitUntil { !agent.turnInFlight })
        await model.settleConversationNaming()
        return agent
    }

    @discardableResult
    func rename(_ params: [String: JSONValue], origin: ActionOrigin = .ui, caller conversation: String? = nil)
        async throws -> JSONValue {
        try await model.registryForTesting.dispatch(
            name: "conversation_rename", params: .object(params), origin: origin,
            caller: DispatchCaller(place: place, session: conversation.map { "s-\($0)" }, conversation: conversation),
            confirmation: nil)
    }

    func refusal(_ params: [String: JSONValue], origin: ActionOrigin, caller: String?) async -> String? {
        do {
            _ = try await rename(params, origin: origin, caller: caller)
            return nil
        } catch {
            return "\(error)"
        }
    }

    func registerResumeReads(root: String) async {
        await model.registryForTesting.register(Action(
            name: "session_read", description: "test double", kind: .read,
            schema: .object(["type": .string("object")]),
            handler: { _ in
                .object(["structuredContent": .object([
                    "cwd": .string("/tmp"), "provider": .string("qwen"), "parent": .string(""),
                    "truncated": .bool(false), "entries": .array([]),
                ])])
            }))
        await model.registryForTesting.register(Action(
            name: "session_get", description: "test double", kind: .read,
            schema: .object(["type": .string("object")]),
            handler: { _ in .object(["structuredContent": .object(["lineageRoot": .string(root)])]) }))
    }
}

@Suite @MainActor struct ConversationRenameTests {
    @Test func theOperatorRenamesAndClearsBackToTheModelsName() async throws {
        let f = try await Fixture()
        let agent = try await f.turn()
        #expect(agent.title == "Model")

        let reply = try await f.rename(["name": .string("Mine")])
        #expect(await waitUntil { agent.title == "Mine" })
        #expect(reply == .object(["renaming": .null, "name": .string("Mine")]))
        let root = try #require(agent.lineageRoot)
        #expect(try f.file.read()[root] == StoredConversationName(operator: "Mine", ai: "Model"))

        try await f.rename(["conversation": .string(agent.id), "name": .string("")])
        #expect(await waitUntil { agent.operatorName == nil })
        #expect(agent.title == "Model")
        #expect(try f.file.read()[root] == StoredConversationName(ai: "Model"))
    }

    @Test func aWhitespaceNameClearsAndANameIsCleaned() async throws {
        let f = try await Fixture()
        let agent = try await f.turn()
        let reply = try await f.rename(["conversation": .string(agent.id), "name": .string("  login\n  bug ")])
        #expect(reply == .object(["renaming": .string(agent.id), "name": .string("login bug")]))
        #expect(await waitUntil { agent.operatorName == "login bug" })

        let cleared = try await f.rename(["conversation": .string(agent.id), "name": .string("  \n")])
        #expect(cleared == .object(["renaming": .string(agent.id), "name": .null]))
        #expect(await waitUntil { agent.operatorName == nil })
        #expect(agent.title == "Model")
    }

    @Test func theAgentRenamesItsOwnConversation() async throws {
        let f = try await Fixture()
        let first = try await f.turn()
        await f.model.newConversation()
        let second = try await f.turn("now the signup page")
        #expect(f.model.currentAgent === second)

        let reply = try await f.rename(["name": .string("Auth work")], origin: .agent, caller: first.id)
        #expect(reply == .object(["renaming": .string(first.id), "name": .string("Auth work")]))
        #expect(await waitUntil { first.title == "Auth work" })
        #expect(second.operatorName == nil)

        // Naming itself by its own id is the same.
        try await f.rename(["conversation": .string(first.id), "name": .string("Auth")], origin: .agent, caller: first.id)
        #expect(await waitUntil { first.title == "Auth" })
    }

    @Test func theAgentIsRefusedAnotherConversation() async throws {
        let f = try await Fixture()
        let first = try await f.turn()
        await f.model.newConversation()
        let second = try await f.turn("now the signup page")
        let refusal = await f.refusal(
            ["conversation": .string(second.id), "name": .string("x")], origin: .agent, caller: first.id)
        #expect(refusal == "conversation_rename: an agent renames only its own conversation "
            + "(conversations call 5: an agent does not know about the others)")
        try await f.rename(["conversation": .string(first.id), "name": .string("marker")], origin: .agent, caller: first.id)
        #expect(await waitUntil { first.operatorName == "marker" })
        #expect(second.operatorName == nil)
    }

    @Test func anUnknownConversationIsRefusedBeforeParking() async throws {
        let f = try await Fixture()
        let agent = try await f.turn()
        let refusal = await f.refusal(["conversation": .string("nope"), "name": .string("x")], origin: .ui, caller: nil)
        #expect(refusal == "conversation_rename: no live conversation nope")
        // Nothing was parked: the next rename is the only one to land.
        try await f.rename(["conversation": .string(agent.id), "name": .string("marker")])
        #expect(await waitUntil { agent.operatorName == "marker" })
    }

    @Test func aRenameOnALandingNamesNothing() async throws {
        let f = try await Fixture()
        let agent = try await f.turn()
        await f.model.newConversation()
        let reply = try await f.rename(["name": .string("lost")])
        #expect(reply == .object(["renaming": .null, "name": .string("lost")]))
        try await f.rename(["conversation": .string(agent.id), "name": .string("marker")])
        #expect(await waitUntil { agent.operatorName == "marker" })
        #expect(f.model.currentAgent == nil)
    }

    @Test func aRenameBeforeTheFirstTurnIsWrittenWhenTheRootIsSet() async throws {
        let f = try await Fixture(thoughts: 1)
        let agent = try #require(f.model.currentAgent)
        #expect(agent.lineageRoot == nil)
        try await f.rename(["conversation": .string(agent.id), "name": .string("Mine")])
        #expect(await waitUntil { agent.title == "Mine" })
        #expect(agent.namesUnsaved)
        #expect(try f.file.read().isEmpty)

        try await f.turn()
        let root = try #require(agent.lineageRoot)
        #expect(!agent.namesUnsaved)
        #expect(try f.file.read()[root] == StoredConversationName(operator: "Mine", ai: "Model"))
        #expect(agent.title == "Mine")
    }

    @Test func anAINameThatLandedBeforeTheRootIsWrittenWithIt() async throws {
        let f = try await Fixture(thoughts: 1)
        let agent = try #require(f.model.currentAgent)
        agent.aiName = "Early"
        agent.namesUnsaved = true
        try await f.rename(["conversation": .string(agent.id), "name": .string("Mine")])
        #expect(await waitUntil { agent.operatorName == "Mine" })
        #expect(await f.model.send("go"))
        let root = try #require(agent.lineageRoot)
        #expect(try f.file.read()[root] == StoredConversationName(operator: "Mine", ai: "Early"))
    }

    @Test func aResumeReadsTheStoredNames() async throws {
        let f = try await Fixture()
        try f.file.set(root: "r1", operator: .some("Mine"), ai: .some("Theirs"))
        await f.registerResumeReads(root: "r1")
        await f.model.resume(sessionId: "parent-1")
        #expect(f.model.status == "")
        let agent = try #require(f.model.currentAgent)
        #expect(agent.lineageRoot == "r1")
        #expect(agent.operatorName == "Mine")
        #expect(agent.aiName == "Theirs")
        #expect(agent.title == "Mine")
    }

    @Test func aFailedSaveKeepsTheNameAndSaysWhy() async throws {
        let f = try await Fixture()
        let agent = try await f.turn()
        try FileManager.default.removeItem(at: f.wakil.appendingPathComponent("orgs/\(org)"))
        try await f.rename(["conversation": .string(agent.id), "name": .string("Mine")])
        #expect(await waitUntil { agent.title == "Mine" })
        #expect(f.model.status.hasPrefix("conversation names: could not save \(f.file.path): "))
        #expect(f.model.status.hasSuffix(" — the name holds until Wakil quits"))
    }

    @Test func renamingNeverSwitchesTheScreen() async throws {
        let f = try await Fixture()
        let first = try await f.turn()
        await f.model.newConversation()
        let second = try await f.turn("now the signup page")
        let screen = f.model.screenConversations
        try await f.rename(["conversation": .string(first.id), "name": .string("Background")])
        #expect(await waitUntil { first.title == "Background" })
        #expect(f.model.screenConversations == screen)
        #expect(f.model.currentAgent === second)
    }
}
