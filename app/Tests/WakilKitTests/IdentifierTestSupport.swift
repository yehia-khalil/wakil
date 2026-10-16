import Foundation
@testable import WakilKit

/// An `IdentifierSource` whose answer the test supplies. Shared by
/// `VocabularyStoreTests` and `WindowIdentifierTests`.
struct FixedSource: IdentifierSource {
    let kind: IdentifierSourceKind
    let name: String
    let answer: @Sendable (ContextStore.ActiveContext) async throws -> [Identifier]
    func identifiers(for context: ContextStore.ActiveContext) async throws -> [Identifier] {
        try await answer(context)
    }
}

/// An `AgentHarness` that records every text `send` was handed, so a test
/// can read what the agent actually received.
actor RecordingHarness: AgentHarness {
    private(set) var sentTexts: [String] = []
    private let stream: AsyncStream<HarnessEvent>
    private let continuation: AsyncStream<HarnessEvent>.Continuation

    init() {
        (stream, continuation) = AsyncStream<HarnessEvent>.makeStream()
    }

    func start(sessionId: String, resumingFrom parentSessionId: String?, workingDirectory: String) async throws {}
    func send(_ text: String) async throws { sentTexts.append(text) }
    nonisolated func events() -> AsyncStream<HarnessEvent> { stream }
    func interrupt() async {}
    func stop() async { continuation.finish() }
}
