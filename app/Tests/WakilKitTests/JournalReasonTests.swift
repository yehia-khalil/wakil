import Testing
import Foundation
@testable import WakilKit

/// **Decision 35: a failed action journals why** (#323). Before it, a handler
/// that threw wrote `outcome: "error"` and nothing else, so the walk that hit
/// "the binding could not be written" had to infer its cause.
///
/// The reason is the error's own sentence — the one the pane shows and the
/// agent is sent — with each marked parameter's value replaced, and capped.
/// **Unlike `params`, this IS a byte search**: a sentence is a blob the
/// registry did not compose, so the only way to keep a secret out of it is
/// to look for the secret's bytes (`JournalRedactionTests` explains why
/// `params` must not).

private struct Failure: Error, CustomStringConvertible {
    let description: String
}

private func scratchJournal() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
}

private func failing(
    _ name: String, with message: String, kind: ActionKind = .control, secretParams: Set<String> = []
) -> Action {
    Action(
        name: name, description: "test", kind: kind,
        audience: .operatorOnly, schema: .object([:]),
        handler: { _ in throw Failure(description: message) },
        secretParams: secretParams)
}

private func dispatchExpectingFailure(
    _ registry: ActionRegistry, _ name: String, _ params: JSONValue = .object([:])
) async {
    _ = try? await registry.dispatch(
        name: name, params: params, origin: .ui, environment: "staging", confirmation: nil)
}

@Test func aFailedActionJournalsItsReason() async throws {
    let registry = ActionRegistry(journalDirectory: scratchJournal(), sessionId: "s1")
    await registry.register(failing("ctx_add_provider", with: "claudePath is required"))

    await dispatchExpectingFailure(registry, "ctx_add_provider")

    let entries = try await registry.journalEntries()
    #expect(entries.map(\.outcome) == ["error"])
    #expect(entries.first?.reason == "claudePath is required")
}

@Test func aReasonQuotingAMarkedParameterReadsRedacted() async throws {
    let registry = ActionRegistry(journalDirectory: scratchJournal(), sessionId: "s1")
    let dsn = "mysql://root:hunter2@db.internal:3306/orders"
    await registry.register(failing(
        "db_set_dsn", with: "cannot connect with \(dsn): refused", secretParams: ["dsn"]))

    await dispatchExpectingFailure(
        registry, "db_set_dsn", .object(["database": .string("orders"), "dsn": .string(dsn)]))

    let reason = try #require(try await registry.journalEntries().first?.reason)
    #expect(reason == "cannot connect with [redacted]: refused")
    #expect(!reason.contains("hunter2"))
}

@Test func aLongReasonIsCapped() async throws {
    let registry = ActionRegistry(journalDirectory: scratchJournal(), sessionId: "s1")
    await registry.register(failing("noisy", with: String(repeating: "e", count: 1000)))

    await dispatchExpectingFailure(registry, "noisy")

    let reason = try #require(try await registry.journalEntries().first?.reason)
    #expect(reason == String(repeating: "e", count: 300) + "…")
}

@Test func onlyAFailureCarriesAReason() async throws {
    let registry = ActionRegistry(journalDirectory: scratchJournal(), sessionId: "s1")
    await registry.register(Action(
        name: "fine", description: "test", kind: .control,
        audience: .operatorOnly, schema: .object([:]), handler: { _ in .null }))

    _ = try await registry.dispatch(
        name: "fine", params: .object([:]), origin: .ui, environment: "staging", confirmation: nil)
    await dispatchExpectingFailure(registry, "no_such_action")

    let entries = try await registry.journalEntries()
    #expect(entries.map(\.outcome) == ["ok", "unknown"])
    #expect(entries.allSatisfy { $0.reason == nil })
}

@Test func aLineWrittenBeforeReasonsStillDecodes() throws {
    let line = #"{"id":"a","ts":813047746.97,"action":"x","params":{},"origin":"ui","outcome":"error"}"#
    let entry = try JSONDecoder().decode(JournalEntry.self, from: Data(line.utf8))
    #expect(entry.outcome == "error")
    #expect(entry.reason == nil)
}
