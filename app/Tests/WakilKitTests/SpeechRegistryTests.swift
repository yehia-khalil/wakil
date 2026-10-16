import Testing
import Foundation
@testable import WakilKit

private func engine(_ id: String, _ name: String) -> SpeechEngine {
    SpeechEngine(id: id, name: name, make: { ScriptedSpeechProvider(steps: []) })
}

@Test func aMissingIdResolvesToApple() {
    let registry = SpeechRegistry(engines: [engine("apple", "Apple")])
    let (found, note) = registry.resolve("")
    #expect(found?.id == "apple")
    #expect(note == nil)
}

@Test func aKnownIdResolvesToItself() {
    let registry = SpeechRegistry(engines: [engine("apple", "Apple"), engine("whisper", "Whisper")])
    #expect(registry.resolve("whisper").engine?.id == "whisper")
}

/// Interaction rule 7: override or ignore, don't refuse — and say which.
@Test func anUnknownIdFallsBackToAppleAndSaysSo() {
    let registry = SpeechRegistry(engines: [engine("apple", "Apple")])
    let (found, note) = registry.resolve("deepgram")
    #expect(found?.id == "apple")
    #expect(note == "unknown engine 'deepgram', using Apple")
}

@Test func noEngineAtAllIsSaidRatherThanCrashing() {
    let registry = SpeechRegistry(engines: [])
    let (found, note) = registry.resolve("")
    #expect(found == nil)
    #expect(note == "no speech engine is available on this Mac")
}

/// The e2e override wins over any stored id, but the Speech row's note is
/// computed without it, so the pane still describes the organisation.
@Test func theOverrideWinsForListeningButNotForTheSettingsNote() {
    let registry = SpeechRegistry(engines: [engine("apple", "Apple")], override: engine("scripted", "Scripted"))
    #expect(registry.resolve("deepgram").engine?.id == "scripted")
    #expect(registry.note(for: "deepgram") == "unknown engine 'deepgram', using Apple")
}
