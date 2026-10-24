import Testing
import Foundation
@testable import WakilKit

/// Each dispatch journals the place it acted in and the agent session that asked,
/// so a line says where it happened, not only which environment was judged.

private let initechStaging = Place(organization: "initech", project: "api", environment: "staging")

private func registryWithRead() async -> ActionRegistry {
    let r = ActionRegistry(
        journalDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
        sessionId: "s1")
    await r.register(Action(name: "db_run_query", description: "run a query",
                            kind: .read, schema: .object(["type": .string("object")])) { p in p })
    return r
}

@Test func journalRecordsTheCallersPlaceAndSession() async throws {
    let r = await registryWithRead()
    _ = try await r.dispatch(
        name: "db_run_query", params: .object([:]), origin: .agent,
        caller: DispatchCaller(place: initechStaging, session: "s-1"), confirmation: nil)
    let entry = try #require(try await r.journalEntries().last)
    #expect(entry.organization == "initech")
    #expect(entry.project == "api")
    #expect(entry.environment == "staging")
    #expect(entry.session == "s-1")
}

@Test func operatorDispatchRecordsNoSession() async throws {
    let r = await registryWithRead()
    _ = try await r.dispatch(
        name: "db_run_query", params: .object([:]), origin: .ui,
        caller: DispatchCaller(place: initechStaging, session: nil), confirmation: nil)
    let entry = try #require(try await r.journalEntries().last)
    #expect(entry.session == nil)
    #expect(entry.organization == "initech")
    #expect(entry.project == "api")
    #expect(entry.environment == "staging")
}

@Test func journalEntryDecodesALineWithoutPlaceFields() throws {
    let line = #"{"id":"x","ts":0,"action":"db_run_query","params":{},"origin":"ui","environment":"staging","outcome":"ok"}"#
    let decoder = JSONDecoder()
    let entry = try decoder.decode(JournalEntry.self, from: Data(line.utf8))
    #expect(entry.environment == "staging")
    #expect(entry.organization == nil)
    #expect(entry.project == nil)
    #expect(entry.session == nil)
}

extension DispatchCaller {
    /// A caller in a fixed test place, for tests that only care which environment is judged.
    static func test(_ environment: String, session: String? = nil, conversation: String? = nil) -> DispatchCaller {
        DispatchCaller(
            place: Place(organization: "org", project: "proj", environment: environment),
            session: session, conversation: conversation)
    }
}

// MARK: - Follow-up lines carry the caller too

@Test func anAgentDispatchThatJournalsUncertainCarriesSessionAndPlace() async throws {
    let r = await registryWithRead()
    await r.register(Action(name: "db_slow", description: "slow", kind: .read,
                            schema: .object(["type": .string("object")])) { _ in
        throw StandardActionError.mutationFateUnknown(action: "db_slow", statement: "x", seconds: 1)
    })
    let surface = MCPSurface(registry: r, panes: PaneStore(), layout: LayoutStore(), confirmations: ConfirmationBroker())
    let call = JSONRPCMessage(id: .number(1), method: "tools/call",
                              params: .object(["name": .string("db_slow"), "arguments": .object([:])]),
                              result: nil, error: nil)
    _ = await handle(call, surface: surface, caller: { DispatchCaller(place: initechStaging, session: "s-3") })
    let uncertain = try #require(try await r.journalEntries().first { $0.outcome == "uncertain" })
    #expect(uncertain.session == "s-3")
    #expect(uncertain.organization == "initech")
    #expect(uncertain.project == "api")
    #expect(uncertain.environment == "staging")
}

@Test func aSentRequestLineCarriesTheDispatchesPlaceAndSession() async throws {
    let r = await registryWithRead()
    await r.register(Action(name: "api_send", description: "send", kind: .read,
                            schema: .object(["type": .string("object")])) { [r] params in
        // What `api_send`'s handler does: it has no caller of its own, so it reads the dispatch's.
        let caller = try #require(ActionRegistry.dispatchCaller)
        try await r.journalSentRequest(
            action: "api_send", params: params, origin: ActionRegistry.dispatchOrigin,
            caller: caller, url: "https://x.example/a", outcome: "sent")
        return .null
    })
    _ = try await r.dispatch(
        name: "api_send", params: .object([:]), origin: .agent,
        caller: DispatchCaller(place: initechStaging, session: "s-4"), confirmation: nil)
    let sent = try #require(try await r.journalEntries().first { $0.outcome == "sent" })
    #expect(sent.session == "s-4")
    #expect(sent.organization == "initech")
    #expect(sent.project == "api")
}

@Test func anUnsetOrganisationAndProjectJournalAsAbsent() async throws {
    let r = await registryWithRead()
    _ = try await r.dispatch(
        name: "db_run_query", params: .object([:]), origin: .debug,
        caller: DispatchCaller(place: Place(organization: "", project: "", environment: "staging"), session: ""),
        confirmation: nil)
    let entry = try #require(try await r.journalEntries().last)
    #expect(entry.organization == nil)
    #expect(entry.project == nil)
    #expect(entry.session == nil)
    #expect(entry.environment == "staging")
}

private func journalLine(dispatchedAs caller: DispatchCaller, origin: ActionOrigin) async throws -> String {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let r = ActionRegistry(journalDirectory: dir, sessionId: "s1")
    await r.register(Action(name: "db_run_query", description: "run a query",
                            kind: .read, schema: .object(["type": .string("object")])) { p in p })
    _ = try await r.dispatch(
        name: "db_run_query", params: .object([:]), origin: origin, caller: caller, confirmation: nil)
    let text = try String(contentsOf: dir.appendingPathComponent("s1.jsonl"), encoding: .utf8)
    return try #require(text.split(separator: "\n").last.map(String.init))
}

@Test func anAgentsEntryNamesItsConversation() async throws {
    let line = try await journalLine(
        dispatchedAs: DispatchCaller(place: initechStaging, session: "s-1", conversation: "conv-1"),
        origin: .agent)
    #expect(line.contains("\"conversation\":\"conv-1\""))
}

@Test func theOperatorsEntryNamesNoConversation() async throws {
    let line = try await journalLine(
        dispatchedAs: DispatchCaller(place: initechStaging, session: nil), origin: .ui)
    #expect(!line.contains("\"conversation\""))
}
