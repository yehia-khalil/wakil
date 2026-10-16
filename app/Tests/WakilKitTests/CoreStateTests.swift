import Testing
@testable import WakilKit

@Test func theCoreIsIdleWithNoTurnAndThinkingWithOne() {
    #expect(CoreState.forTurn(inFlight: false) == .idle)
    #expect(CoreState.forTurn(inFlight: true) == .thinking)
}

/// 2b-ii spec §4.1, still true under 2b-iv: four states are rendered and the
/// app sets two. The other two exist so 2d wires a microphone into a
/// renderer that is already there.
@Test func allFourStatesExistAndHaveStableRawValues() {
    #expect(CoreState.allCases.count == 4)
    #expect(CoreState.idle.rawValue == "idle")
    #expect(CoreState.listening.rawValue == "listening")
    #expect(CoreState.thinking.rawValue == "thinking")
    #expect(CoreState.speaking.rawValue == "speaking")
}
