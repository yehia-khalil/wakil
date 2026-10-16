import Testing
import Foundation
@testable import WakilKit

/// The journal records every action's params and, since Decision 35, why a
/// failure failed — so it is the operator's alone, like the transcripts
/// beside it (0600), not readable by every account on the Mac.

private func mode(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

private func dispatchOne(_ registry: ActionRegistry) async throws {
    await registry.register(Action(
        name: "fine", description: "test", kind: .control,
        audience: .operatorOnly, schema: .object([:]), handler: { _ in .null }))
    _ = try await registry.dispatch(
        name: "fine", params: .object([:]), origin: .ui, environment: "staging", confirmation: nil)
}

@Test func aNewJournalIsTheOperatorsAlone() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let registry = ActionRegistry(journalDirectory: directory, sessionId: "s1")

    try await dispatchOne(registry)

    #expect(try mode(directory) == 0o700)
    #expect(try mode(directory.appendingPathComponent("s1.jsonl")) == 0o600)
}

@Test func aJournalWrittenWorldReadableIsTightenedOnItsNextLine() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
    let file = directory.appendingPathComponent("s1.jsonl")
    #expect(FileManager.default.createFile(
        atPath: file.path, contents: Data(), attributes: [.posixPermissions: 0o644]))
    let registry = ActionRegistry(journalDirectory: directory, sessionId: "s1")

    try await dispatchOne(registry)

    #expect(try mode(directory) == 0o700)
    #expect(try mode(file) == 0o600)
}
