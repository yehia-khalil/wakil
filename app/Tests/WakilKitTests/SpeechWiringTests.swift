import Testing
import Foundation
@testable import WakilKit

/// The never-wired-parameter class: tests inject fakes, so only this test
/// says the production registry actually contains Apple.
@Test func theStandardRegistryRegistersAppleOnMacOS26() {
    let registry = SpeechRegistry.standard(environment: [:])
    if #available(macOS 26.0, *) {
        #expect(registry.engines.map(\.id) == ["apple"])
        #expect(registry.engines.first?.name == "Apple")
        #expect(registry.override == nil)
    } else {
        #expect(registry.engines.isEmpty)
    }
}

@Test func aSpeechScriptOverridesTheMicrophone() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("speech-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data(#"[{"after":0,"kind":"started","device":"Scripted Mic"}]"#.utf8).write(to: url)
    let registry = SpeechRegistry.standard(environment: ["WAKIL_SPEECH_SCRIPT": url.path])
    #expect(registry.resolve("apple").engine?.id == "scripted")
}

/// A bad script must not silently fall through to the real microphone.
@Test func anUnreadableSpeechScriptFailsLoudly() async {
    let registry = SpeechRegistry.standard(environment: ["WAKIL_SPEECH_SCRIPT": "/nonexistent/script.json"])
    guard let engine = registry.resolve("").engine else { Issue.record("no engine"); return }
    #expect(engine.id == "scripted")
    // Held: the provider's player task only references it weakly.
    let provider = engine.make()
    var events: [SpeechEvent] = []
    for await event in provider.start(locale: Locale(identifier: "en-US")) { events.append(event) }
    guard case .failed(let message)? = events.last else { Issue.record("expected .failed, got \(events)"); return }
    #expect(message.contains("/nonexistent/script.json"))
}
