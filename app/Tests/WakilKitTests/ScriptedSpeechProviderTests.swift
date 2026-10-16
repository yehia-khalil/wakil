import Testing
import Foundation
@testable import WakilKit

private func collect(_ stream: AsyncStream<SpeechEvent>) async -> [SpeechEvent] {
    var out: [SpeechEvent] = []
    for await event in stream { out.append(event) }
    return out
}

@Test func playsItsStepsThenAFinalOfWhatWasHeardOnStop() async {
    let provider = ScriptedSpeechProvider(steps: [
        .init(after: 0, event: .started(device: "Test Mic")),
        .init(after: 0, event: .partial(settled: "open the", volatile: "book")),
    ])
    let stream = provider.start(locale: Locale(identifier: "en-US"))
    try? await Task.sleep(for: .milliseconds(50))
    await provider.stop()
    let events = await collect(stream)
    #expect(events == [
        .started(device: "Test Mic"),
        .partial(settled: "open the", volatile: "book"),
        .final("open the book"),
    ])
}

@Test func cancelFinishesWithNoFinal() async {
    let provider = ScriptedSpeechProvider(steps: [.init(after: 0, event: .partial(settled: "x", volatile: ""))])
    let stream = provider.start(locale: Locale(identifier: "en-US"))
    try? await Task.sleep(for: .milliseconds(50))
    await provider.cancel()
    let events = await collect(stream)
    #expect(!events.contains { if case .final = $0 { return true }; return false })
}

@Test func loadsAScriptFile() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("speech-\(UUID().uuidString).json")
    try Data(#"""
    [{"after":0,"kind":"started","device":"Scripted Mic"},
     {"after":0.2,"kind":"audio"},
     {"after":0.1,"kind":"partial","settled":"open the","volatile":"booking"},
     {"after":0,"kind":"downloading","fraction":0.5,"totalBytes":1000},
     {"after":0,"kind":"denied"},
     {"after":0,"kind":"permissionPending"},
     {"after":0,"kind":"failed","message":"boom"},
     {"after":0,"kind":"final","text":"open the booking"}]
    """#.utf8).write(to: url)
    let steps = try ScriptedSpeechProvider.load(url.path)
    #expect(steps.map(\.event) == [
        .started(device: "Scripted Mic"), .audio,
        .partial(settled: "open the", volatile: "booking"),
        .downloading(fraction: 0.5, totalBytes: 1000), .denied, .permissionPending, .failed("boom"),
        .final("open the booking"),
    ])
    #expect(steps[1].after == 0.2)
}

private func finals(_ events: [SpeechEvent]) -> Int {
    events.filter { if case .final = $0 { return true }; return false }.count
}

@Test func aScriptThatHasItsOwnFinalYieldsExactlyOneAfterStop() async {
    let provider = ScriptedSpeechProvider(steps: [
        .init(after: 0, event: .partial(settled: "open", volatile: "")),
        .init(after: 0, event: .final("open")),
    ])
    let stream = provider.start(locale: Locale(identifier: "en-US"))
    try? await Task.sleep(for: .milliseconds(50))
    await provider.stop()
    let events = await collect(stream)
    #expect(finals(events) == 1)
}

@Test func stoppingTwiceYieldsOneFinal() async {
    let provider = ScriptedSpeechProvider(steps: [.init(after: 0, event: .partial(settled: "x", volatile: ""))])
    let stream = provider.start(locale: Locale(identifier: "en-US"))
    try? await Task.sleep(for: .milliseconds(50))
    await provider.stop()
    await provider.stop()
    let events = await collect(stream)
    #expect(finals(events) == 1)
}
