import Testing
import Foundation
@testable import WakilKit

/// A harness whose `send` always succeeds, so `WindowModel.send` reaches
/// the line that marks the turn as started.
private final class AcceptingHarness: AgentHarness, @unchecked Sendable {
    private let stream: AsyncStream<HarnessEvent>
    private let continuation: AsyncStream<HarnessEvent>.Continuation
    private(set) var sent: [String] = []
    init() { (stream, continuation) = AsyncStream<HarnessEvent>.makeStream() }
    func start(sessionId: String, resumingFrom parentSessionId: String?, workingDirectory: String) async throws {}
    func send(_ text: String) async throws { sent.append(text) }
    func events() -> AsyncStream<HarnessEvent> { stream }
    func interrupt() async {}
    func stop() async { continuation.finish() }
}

@MainActor
@Test func listeningDrivesTheCoreState() {
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot)
    #expect(model.coreState == .idle)
    model.setListening(true)
    #expect(model.coreState == .listening)
    model.setListening(false)
    #expect(model.coreState == .idle)
}

@MainActor
@Test func aSentTurnAppearsAsAYouRow() async {
    let harness = AcceptingHarness()
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot, harnessFactory: { _, _ in harness })
    await model.send("show tables")
    #expect(model.thoughts.contains { $0.label == "you" && $0.detail == "show tables" })
}

@MainActor
@Test func aVoiceTurnIsJournalledAsVoice() async throws {
    let harness = AcceptingHarness()
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot, harnessFactory: { _, _ in harness })
    await model.send("show tables", via: .voice)
    let entries = try await model.registryForTesting.journalEntries()
    let entry = try #require(entries.last { $0.action == "voice_turn" })
    #expect(entry.params == .object(["via": .string("voice")]))
}

@MainActor
@Test func aTypedTurnWritesNoVoiceLine() async throws {
    let harness = AcceptingHarness()
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot, harnessFactory: { _, _ in harness })
    await model.send("show tables")
    let entries = try await model.registryForTesting.journalEntries()
    #expect(!entries.contains { $0.action == "voice_turn" })
}

@MainActor
@Test func aSpeechFailureIsAWholeRedRow() {
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot)
    let message = String(repeating: "the engine stopped because ", count: 10)
    model.appendSpeechFailure(message)
    #expect(model.thoughts.last == ThoughtRow(id: model.thoughts.last!.id, label: "speech", detail: message, isError: true))
}

/// Review focus 4: the engine id is the CURRENT organisation's.
@MainActor
@Test func speechEngineIdIsReReadAfterTheOrgChanges() async {
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot)
    model.setSettingsForTesting(SettingsTree(org: SettingsOrg(id: "alpha", speechProvider: "apple")))
    #expect(await model.speechEngineId() == "apple")
    model.setSettingsForTesting(nil)   // what invalidateForOrgChange does
    model.setSettingsForTesting(SettingsTree(org: SettingsOrg(id: "beta", speechProvider: "whisper")))
    #expect(await model.speechEngineId() == "whisper")
}

private struct SendRefused: Error {}
private final class RefusingHarness: AgentHarness, @unchecked Sendable {
    private let stream: AsyncStream<HarnessEvent>
    private let continuation: AsyncStream<HarnessEvent>.Continuation
    init() { (stream, continuation) = AsyncStream<HarnessEvent>.makeStream() }
    func start(sessionId: String, resumingFrom parentSessionId: String?, workingDirectory: String) async throws {}
    func send(_ text: String) async throws { throw SendRefused() }
    func events() -> AsyncStream<HarnessEvent> { stream }
    func interrupt() async {}
    func stop() async { continuation.finish() }
}

@MainActor
@Test func aFailedVoiceSendWritesNoVoiceLine() async throws {
    let harness = RefusingHarness()
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot, harnessFactory: { _, _ in harness })
    await model.send("show tables", via: .voice)
    let entries = try await model.registryForTesting.journalEntries()
    #expect(!entries.contains { $0.action == "voice_turn" })
}
