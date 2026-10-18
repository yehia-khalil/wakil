import Testing
import Foundation
@testable import WakilKit

@MainActor
private final class Clock {
    var t: Double = 0
}

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

/// Wraps a scripted provider and counts the calls the model makes to it.
private final class RecordingProvider: SpeechProvider, @unchecked Sendable {
    private let inner: ScriptedSpeechProvider
    private let lock = NSLock()
    private var _stops = 0
    private var _cancels = 0
    init(steps: [ScriptedSpeechProvider.Step]) { inner = ScriptedSpeechProvider(steps: steps) }
    var stops: Int { lock.withLock { _stops } }
    var cancels: Int { lock.withLock { _cancels } }
    func start(locale: Locale) -> AsyncStream<SpeechEvent> { inner.start(locale: locale) }
    func stop() async { lock.withLock { _stops += 1 }; await inner.stop() }
    func cancel() async { lock.withLock { _cancels += 1 }; await inner.cancel() }
}

private final class Made: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [RecordingProvider] = []
    func add(_ p: RecordingProvider) { lock.withLock { list.append(p) } }
    var all: [RecordingProvider] { lock.withLock { list } }
}

@MainActor
private func model(
    steps: [ScriptedSpeechProvider.Step], clock: Clock, made: Made? = nil, harnessAvailable: Bool = true
) -> (ComposerModel, WindowModel, AcceptingHarness) {
    let harness = AcceptingHarness()
    let window = WindowModel.forTesting(scratchRoot: testScratchRoot, harnessFactory: { _, _ in harnessAvailable ? harness : nil })
    window.setSettingsForTesting(SettingsTree(org: SettingsOrg(id: "test-org")))
    let registry = SpeechRegistry(engines: [
        SpeechEngine(id: "apple", name: "Apple", make: {
            let p = RecordingProvider(steps: steps)
            made?.add(p)
            return p
        }),
    ])
    return (ComposerModel(window: window, speech: registry, now: { clock.t }), window, harness)
}

/// Lets the model's start/pump tasks run.
private func settle() async { for _ in 0..<20 { await Task.yield() }; try? await Task.sleep(for: .milliseconds(30)) }

/// Waits until `done`, up to 2 s. What a hold hears and what its release lands reach the model
/// through task hops (the engine's start, its stop, then the pump), which a loaded full-suite
/// run can delay past any fixed wait; a check that asserts what arrived waits for it to arrive.
@MainActor
private func settle(until done: () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(2)
    while !done(), ContinuousClock.now < deadline {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
@Test func holdThenReleaseLandsTheWordsUnsent() async {
    let clock = Clock()
    let (composer, window, harness) = model(steps: [
        .init(after: 0, event: .started(device: "Test Mic")),
        .init(after: 0, event: .partial(settled: "show", volatile: "tables")),
    ], clock: clock)
    composer.optionDown()
    clock.t = 0.2; composer.tick()
    #expect(window.coreState == .listening)
    await settle(until: { !composer.machine.settled.isEmpty })
    #expect(composer.bar == .hearing(settled: "show", volatile: "tables", hint: ComposerBarContent.releaseHint))
    clock.t = 1; composer.optionUp()
    await settle(until: { composer.machine.phase == .idle })
    #expect(composer.draft == "show tables")
    #expect(composer.landedUnsent)
    #expect(composer.focusToken == 1)
    #expect(window.coreState == .idle)
    #expect(!window.thoughts.contains { $0.label == "you" }, "nothing is sent until Return")
    #expect(harness.sent.isEmpty, "nothing is sent until Return")
}

@MainActor
@Test func speechLandsAtTheCaretOfWhatWasTyped() async {
    let clock = Clock()
    let (composer, _, _) = model(steps: [.init(after: 0, event: .partial(settled: "all", volatile: ""))], clock: clock)
    composer.edited(draft: "show tables", caret: 5)
    composer.optionDown(); clock.t = 0.2; composer.tick()
    await settle(until: { !composer.machine.settled.isEmpty })
    clock.t = 1; composer.optionUp()
    await settle(until: { composer.machine.phase == .idle })
    #expect(composer.draft == "show all tables")
}

@MainActor
@Test func escapeWhileHoldingKeepsTheTypedDraft() async {
    let clock = Clock()
    let (composer, window, harness) = model(steps: [.init(after: 0, event: .partial(settled: "drop", volatile: ""))], clock: clock)
    composer.edited(draft: "keep me", caret: 7)
    composer.optionDown(); clock.t = 0.2; composer.tick()
    await settle()
    #expect(composer.escape())
    await settle()
    #expect(composer.draft == "keep me")
    #expect(window.coreState == .idle)
}

@MainActor
@Test func composerEscapeWhenIdleIsNotConsumed() {
    let (composer, _, _) = model(steps: [], clock: Clock())
    #expect(!composer.escape())
}

/// Review focus 2.
@MainActor
@Test func releaseBeforeTheEngineStartsNeverStartsIt() async {
    let clock = Clock()
    let (composer, _, _) = model(steps: [.init(after: 0, event: .partial(settled: "late", volatile: ""))], clock: clock)
    composer.optionDown(); clock.t = 0.2; composer.tick()
    composer.optionUp()                     // before any await: the engine lookup has not finished
    await settle()
    clock.t = 3; composer.tick()            // finish timeout
    await settle()
    #expect(composer.draft == "")
    #expect(composer.machine.phase == .idle)
}

@MainActor
@Test func aFailureLandsWhatWasHeardAndAddsARedRow() async {
    let clock = Clock()
    let (composer, window, harness) = model(steps: [
        .init(after: 0, event: .partial(settled: "open", volatile: "the")),
        .init(after: 0.01, event: .failed("engine stopped")),
    ], clock: clock)
    composer.optionDown(); clock.t = 0.2; composer.tick()
    await settle(until: { composer.machine.phase == .idle })
    #expect(composer.draft == "open the")
    #expect(window.thoughts.last?.label == "speech")
    #expect(window.thoughts.last?.isError == true)
}

@MainActor
@Test func submitSendsAndClearsAndMarksVoice() async throws {
    let clock = Clock()
    let (composer, window, harness) = model(steps: [.init(after: 0, event: .partial(settled: "show tables", volatile: ""))], clock: clock)
    composer.optionDown(); clock.t = 0.2; composer.tick()
    await settle(until: { !composer.machine.settled.isEmpty })
    clock.t = 1; composer.optionUp()
    await settle(until: { composer.machine.phase == .idle })
    await composer.submit()
    #expect(composer.draft == "")
    #expect(!composer.landedUnsent)
    #expect(harness.sent == ["show tables"])
    #expect(window.thoughts.contains { $0.label == "you" && $0.detail == "show tables" })
    let entries = try await window.registryForTesting.journalEntries()
    #expect(entries.contains { $0.action == "voice_turn" })
}

@MainActor
@Test func aTypedSubmitIsNotMarkedVoice() async throws {
    let (composer, window, harness) = model(steps: [], clock: Clock())
    composer.edited(draft: "show tables", caret: 11)
    await composer.submit()
    #expect(harness.sent == ["show tables"])
    let entries = try await window.registryForTesting.journalEntries()
    #expect(!entries.contains { $0.action == "voice_turn" })
}

/// A hold that ended on its own must not leave its engine behind for the
/// next hold's early release to stop.
@MainActor
@Test func aFinishedHoldsEngineIsNotStoppedByTheNextHold() async {
    let clock = Clock()
    let made = Made()
    let (composer, _, _) = model(steps: [.init(after: 0, event: .partial(settled: "one", volatile: ""))], clock: clock, made: made)
    composer.optionDown(); clock.t = 0.2; composer.tick()
    await settle(until: { !composer.machine.settled.isEmpty })
    clock.t = 1; composer.optionUp()
    await settle(until: { composer.machine.phase == .idle })
    #expect(composer.draft == "one")
    #expect(made.all.count == 1)
    let first = made.all[0]
    let stopsAfterFirst = first.stops
    let cancelsAfterFirst = first.cancels
    clock.t = 5; composer.optionDown(); clock.t = 5.2; composer.tick()
    composer.optionUp()                     // before the second engine is adopted
    await settle()
    #expect(first.stops == stopsAfterFirst)
    #expect(first.cancels == cancelsAfterFirst)
}

@MainActor
@Test func submittingWhitespaceSendsNothing() async {
    let (composer, window, harness) = model(steps: [], clock: Clock())
    composer.edited(draft: "   ", caret: 3)
    await composer.submit()
    #expect(!window.thoughts.contains { $0.label == "you" })
    #expect(harness.sent.isEmpty)
}

@MainActor
@Test func aSubmitThatStartsNoTurnGivesTheDraftBack() async {
    let (composer, window, harness) = model(steps: [], clock: Clock(), harnessAvailable: false)
    composer.edited(draft: "show tables", caret: 11)
    await composer.submit()
    #expect(composer.draft == "show tables")
    #expect(composer.caret == 11)
    #expect(harness.sent.isEmpty)
    #expect(!window.thoughts.contains { $0.label == "you" })
}

@MainActor
@Test func aSubmitThatStartsATurnStaysCleared() async {
    let (composer, _, harness) = model(steps: [], clock: Clock())
    composer.edited(draft: "show tables", caret: 11)
    await composer.submit()
    #expect(composer.draft == "")
    #expect(harness.sent == ["show tables"])
}

@MainActor
@Test func aKeyAfterTheArmWithNothingHeardClosesTheMicAndPassesThrough() async {
    let clock = Clock()
    let (composer, window, _) = model(steps: [], clock: clock)
    composer.optionDown(); clock.t = 0.2; composer.tick()
    #expect(window.isListening)
    #expect(composer.otherInput() == false)
    #expect(!composer.machine.isListening)
}

@MainActor
@Test func aKeyWhileWordsAreHeardIsSwallowedAndKeepsListening() async {
    let clock = Clock()
    let (composer, _, _) = model(steps: [.init(after: 0, event: .partial(settled: "open", volatile: ""))], clock: clock)
    composer.optionDown(); clock.t = 0.2; composer.tick()
    await settle()
    #expect(composer.otherInput() == true)
    #expect(composer.machine.isCapturing)
}
