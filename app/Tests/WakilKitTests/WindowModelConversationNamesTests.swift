import Foundation
import Testing
@testable import WakilKit

// Names phase, Task 5: after a conversation's first clean exchange the organisation's quick model
// is asked once for a name (spec, "Calls made" 6-8).

private let org = "initech"
private let place = Place(organization: org, project: "api", environment: "staging")

/// A quick model that answers `reply` (or throws `failure`), records every request, and holds the
/// first `gated` calls until `release()`.
private actor NamingModel: QuickModel {
    nonisolated let serves: Set<QuickOperation> = [.respond]
    private let reply: String
    private let failure: QuickModelError?
    private var gated: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var requests: [RespondRequest] = []

    init(reply: String = #"{"name": "Fixture"}"#, failure: QuickModelError? = nil, gated: Int = 0) {
        self.reply = reply
        self.failure = failure
        self.gated = gated
    }

    func infill(_ request: InfillRequest) async throws -> String { throw QuickModelError.unsupported(.infill) }

    func respond(_ request: RespondRequest) async throws -> String {
        requests.append(request)
        if gated > 0 {
            gated -= 1
            await withCheckedContinuation { waiters.append($0) }
        }
        if let failure { throw failure }
        return reply
    }

    func release() {
        let all = waiters
        waiters = []
        for w in all { w.resume() }
    }

    var waiting: Int { waiters.count }

    func shutdown() async {}
}

/// `wakil-ctx` as far as the quick tasks need it: one organisation whose Quick tasks provider is a
/// local model serving `respond`, with conversation names on unless `names` says otherwise.
private actor NamesBackend: ToolCaller {
    var names: Bool
    init(names: Bool) { self.names = names }

    func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        switch name {
        case "config_tree":
            return .object(["structuredContent": .object([
                "org": .object([
                    "id": .string(org), "quickProvider": .string("qwen"), "conversationNames": .bool(names),
                ]),
                "providers": .array([.object([
                    "id": .string("qwen"), "kind": .string("local"), "baseURL": .string("http://127.0.0.1:8012"),
                    "serves": .array([.string("respond")]),
                ])]),
                "projects": .array([]),
            ])])
        default:
            return .object(["structuredContent": .object([:])])
        }
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
    let quick: NamingModel
    /// The `HOME` the window's `~/.wakil` is under; `orgs/initech` exists in it.
    let home: URL

    var wakil: URL { home.appendingPathComponent(".wakil", isDirectory: true) }

    init(quick: NamingModel = NamingModel(), names: Bool = true) async throws {
        self.quick = quick
        let harnesses = Harnesses()
        self.harnesses = harnesses
        let model = WindowModel.forTesting(
            scratchRoot: testScratchRoot, organization: org,
            harnessFactory: { place, _ in harnesses.make(place) },
            context: ContextStore(client: NamesBackend(names: names)),
            providerId: "qwen",
            quickModelFactory: { _, _ in quick })
        home = testScratchRoot.appendingPathComponent("names-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".wakil/orgs/\(org)", isDirectory: true), withIntermediateDirectories: true)
        model.browserHome = home
        model.seedForTesting(
            providerId: "qwen", rootPath: "/tmp/wakil-window-model-for-testing", thoughts: 0,
            project: place.project, environment: place.environment)
        await model.rebuildQuickTasks()
        self.model = model
    }

    /// Sends `text` and ends the turn with `reply`, then waits for any naming it started.
    @discardableResult
    func turn(_ text: String = "fix the login test", reply: String? = "Looking at auth", isError: Bool = false,
              settle: Bool = true) async throws -> PlaceAgent {
        #expect(await model.send(text))
        let harness = try #require(harnesses.in(place).last)
        let agent = try #require(model.conversations.values.first { $0.place == place })
        if let reply { harness.emit(.assistantText(reply)) }
        harness.emit(.result(isError: isError, text: nil))
        #expect(await waitUntil { !agent.turnInFlight })
        if settle { await model.settleConversationNaming() }
        return agent
    }

    /// `resume` reads the parent's transcript first: an empty one, under the window's provider.
    func registerSessionRead() async {
        await model.registryForTesting.register(Action(
            name: "session_read", description: "test double", kind: .read,
            schema: .object(["type": .string("object")]),
            handler: { _ in
                .object(["structuredContent": .object([
                    "cwd": .string("/tmp"), "provider": .string("qwen"), "parent": .string(""),
                    "truncated": .bool(false), "entries": .array([]),
                ])])
            }))
    }

    func namingEntries() async throws -> [JournalEntry] {
        try await model.registryForTesting.journalEntries().filter { $0.action == "conversation_named" }
    }
}

@Suite @MainActor struct WindowModelConversationNamesTests {
    @Test func theFirstCleanTurnAsksOnceWithTheMessageAndReplyStart() async throws {
        let f = try await Fixture()
        let agent = try await f.turn()
        #expect(await f.quick.requests == [
            ConversationNames.request(firstMessage: "fix the login test", replyStart: "Looking at auth"),
        ])
        #expect(agent.aiName == "Fixture")
        #expect(agent.title == "Fixture")
        try await f.turn("and the signup test", reply: "Sure")
        #expect(await f.quick.requests.count == 1)
    }

    @Test func anErroredFirstTurnDoesNotUseTheAsk() async throws {
        let f = try await Fixture()
        let agent = try await f.turn(reply: nil, isError: true)
        #expect(await f.quick.requests.isEmpty)
        #expect(!agent.namingAsked)
        try await f.turn("try again", reply: "Looking at auth")
        #expect(await f.quick.requests.count == 1)
        #expect(await f.quick.requests.first?.input == "MESSAGE: fix the login test\n\nREPLY: Looking at auth")
        #expect(agent.aiName == "Fixture")
    }

    /// Ruling R9 (a): an errored turn's text is not the reply sent; REPLY is the first clean exchange's.
    @Test func anErroredTurnsTextIsNotTheReplySent() async throws {
        let f = try await Fixture()
        try await f.turn(reply: "Something went wrong", isError: true)
        try await f.turn("try again", reply: "Looking at auth")
        #expect(await f.quick.requests.map(\.input) == ["MESSAGE: fix the login test\n\nREPLY: Looking at auth"])
    }

    /// Ruling R9 (b): settling waits for the journal line too, not only the name.
    @Test func settlingWaitsForTheJournalLine() async throws {
        for _ in 0..<5 {
            let f = try await Fixture()
            try await f.turn()
            #expect(f.model.conversationNamingTasks.isEmpty && f.model.conversationNamingJournals.isEmpty)
            #expect(try await f.namingEntries().count == 1)
        }
    }

    @Test func offAsksNothing() async throws {
        let f = try await Fixture(names: false)
        let agent = try await f.turn()
        #expect(await f.quick.requests.isEmpty)
        #expect(agent.title == "fix the login test")
    }

    @Test func aResumedConversationIsNeverAsked() async throws {
        let f = try await Fixture()
        await f.registerSessionRead()
        await f.model.resume(sessionId: "parent-1")
        #expect(f.model.status == "")
        let agent = try #require(f.model.conversations.values.first { $0.place == place })
        #expect(agent.namingAsked)
        try await f.turn()
        #expect(await f.quick.requests.isEmpty)
        #expect(agent.aiName == nil)
    }

    /// A conversation whose process went away is revived by forking its own session on the next send:
    /// the same conversation, not a resume, so its first clean exchange is still asked.
    @Test func aRevivedConversationIsStillAsked() async throws {
        let f = try await Fixture()
        await f.registerSessionRead()
        let agent = try await f.turn(reply: nil, isError: true)
        try #require(f.harnesses.in(place).last).finish()
        #expect(await waitUntil { agent.sessionEnded })
        try await f.turn("try again")
        #expect(f.harnesses.in(place).count == 2)
        #expect(await f.quick.requests.count == 1)
        #expect(agent.aiName == "Fixture")
    }

    @Test func anotherOrganisationsConversationWaitsForItsOwnQuickTasks() async throws {
        let f = try await Fixture()
        #expect(await f.model.send("fix the login test"))
        let harness = try #require(f.harnesses.in(place).last)
        let agent = try #require(f.model.conversations.values.first { $0.place == place })
        f.model.setOrganizationForTesting("globex")
        harness.emit(.assistantText("Looking at auth"))
        harness.emit(.result(isError: false, text: nil))
        #expect(await waitUntil { !agent.turnInFlight })
        await f.model.settleConversationNaming()
        #expect(await f.quick.requests.isEmpty)
        #expect(!agent.namingAsked)

        f.model.setOrganizationForTesting(org)
        await f.model.rebuildQuickTasks()
        await f.model.settleConversationNaming()
        #expect(await f.quick.requests.count == 1)
        #expect(agent.aiName == "Fixture")
    }

    /// A reply a rebuild dropped is asked again of the new quick tasks at once: that rebuild's own
    /// `nameDueConversations` ran while the old ask was still in flight, so nothing else would ask it.
    @Test func aReplyDroppedByARebuildIsAskedAgainAtOnce() async throws {
        let quick = NamingModel(gated: 2)
        let f = try await Fixture(quick: quick)
        let agent = try await f.turn(settle: false)
        #expect(await waitUntil { await quick.waiting == 1 })
        await f.model.rebuildQuickTasks()
        await quick.release()
        // The first reply is dropped, and the second ask is made and held, with no rebuild between.
        #expect(await waitUntil { await quick.waiting == 1 })
        #expect(await quick.requests.count == 2)
        #expect(agent.aiName == nil)
        #expect(agent.namingAsked)
        #expect(try await f.namingEntries().isEmpty)

        await quick.release()
        await f.model.settleConversationNaming()
        #expect(agent.aiName == "Fixture")
        #expect(try await f.namingEntries().count == 1)
    }

    /// Dropped while a rebuild is under way: whichever lands first — the drop (no quick tasks yet, so
    /// that rebuild's `nameDueConversations` asks) or the rebuild (the drop asks) — it is asked once more.
    @Test func aReplyDroppedDuringARebuildIsAskedExactlyOnceMore() async throws {
        let quick = NamingModel(gated: 1)
        let f = try await Fixture(quick: quick)
        let agent = try await f.turn(settle: false)
        #expect(await waitUntil { await quick.waiting == 1 })
        let rebuild = Task { await f.model.rebuildQuickTasks() }
        await quick.release()
        await rebuild.value
        await f.model.settleConversationNaming()
        #expect(await quick.requests.count == 2)
        #expect(agent.aiName == "Fixture")
    }

    @Test func anOrganisationSwitchDropsTheReplyAndAsksAgainOnReturn() async throws {
        let quick = NamingModel(gated: 1)
        let f = try await Fixture(quick: quick)
        let agent = try await f.turn(settle: false)
        #expect(await waitUntil { await quick.waiting == 1 })
        await f.model.invalidateForOrgChange()
        #expect(f.model.conversationNamingTasks.isEmpty)
        #expect(!agent.namingAsked)
        await quick.release()
        await f.model.settleConversationNaming()
        #expect(agent.aiName == nil)
        #expect(try await f.namingEntries().isEmpty)

        await f.model.rebuildQuickTasks()   // back in its organisation, as the switch ends
        await f.model.settleConversationNaming()
        #expect(await quick.requests.count == 2)
        #expect(agent.aiName == "Fixture")
    }

    @Test func aFailureKeepsTheMessageTitleAndIsNotRetried() async throws {
        let f = try await Fixture(quick: NamingModel(failure: .failed("qwen: model exploded")))
        let agent = try await f.turn()
        #expect(agent.title == "fix the login test")
        #expect(agent.aiName == nil)
        #expect(agent.namingAsked)
        #expect(await f.model.quickTaskStatus().errors["qwen"] == "qwen: model exploded")
        #expect(try await f.namingEntries().map(\.outcome) == ["qwen: model exploded"])
        await f.model.rebuildQuickTasks()
        try await f.turn("again")
        #expect(await f.quick.requests.count == 1)
    }

    @Test func anUnreadableReplyIsRecordedForSettings() async throws {
        let f = try await Fixture(quick: NamingModel(reply: "no idea"))
        let agent = try await f.turn()
        let error = "the model's reply was not a conversation name: no idea"
        #expect(agent.aiName == nil)
        #expect(agent.namingAsked)
        #expect(await f.model.quickTaskStatus().errors["qwen"] == error)
        #expect(try await f.namingEntries().map(\.outcome) == [error])
    }

    @Test func aLateReplyNeverHidesTheOperatorsName() async throws {
        let quick = NamingModel(gated: 1)
        let f = try await Fixture(quick: quick)
        let agent = try await f.turn(settle: false)
        #expect(await waitUntil { await quick.waiting == 1 })
        agent.operatorName = "Mine"
        await quick.release()
        await f.model.settleConversationNaming()
        #expect(agent.aiName == "Fixture")
        #expect(agent.title == "Mine")
    }

    @Test func theNameGoesToDiskUnderTheLineageRoot() async throws {
        let f = try await Fixture()
        let agent = try await f.turn()
        let root = try #require(agent.lineageRoot)
        let stored = try ConversationNameFile(org: org, home: f.wakil).read()
        #expect(stored[root] == StoredConversationName(ai: "Fixture"))
    }

    @Test func aSaveThatFailsSaysSoAndTheNameHolds() async throws {
        let f = try await Fixture()
        let file = ConversationNameFile(org: org, home: f.wakil)
        try FileManager.default.removeItem(at: f.wakil.appendingPathComponent("orgs/\(org)"))
        let agent = try await f.turn()
        #expect(agent.aiName == "Fixture")
        #expect(f.model.status.hasPrefix("conversation names: could not save \(file.path): "))
        #expect(f.model.status.hasSuffix(" — the name holds until Wakil quits"))
    }

    @Test func eachAskIsJournalledWithoutTheWords() async throws {
        let f = try await Fixture()
        try await f.turn()
        let entries = try await f.namingEntries()
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.params == .object([
            "provider": .string("qwen"), "messageChars": .integer(18), "replyChars": .integer(15),
        ]))
        #expect(entry.outcome == "ok: Fixture")
        let line = String(decoding: try JSONEncoder().encode(entry), as: UTF8.self)
        #expect(!line.contains("fix the login test"))
        #expect(!line.contains("Looking at auth"))
    }
}
