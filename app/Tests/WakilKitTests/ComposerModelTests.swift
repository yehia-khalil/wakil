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
    #expect(composer.bar == .hearing(before: "", settled: "show", volatile: "tables", after: "",
                                     hint: ComposerBarContent.releaseHint))
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
    // Until "open" arrives nothing is heard, and a key then closes the mic (the test above).
    await settle(until: { !composer.machine.settled.isEmpty })
    #expect(composer.otherInput() == true)
    #expect(composer.machine.isCapturing)
}

// MARK: - The fast path (3b-ix)

/// A composer whose fast path answers `outcome` for every line, over the file's window and harness.
@MainActor
private func makeComposerWithFastPath(outcome: FastPathOutcome) -> (composer: ComposerModel, harness: AcceptingHarness) {
    let harness = AcceptingHarness()
    let window = WindowModel.forTesting(scratchRoot: testScratchRoot, harnessFactory: { _, _ in harness })
    window.setSettingsForTesting(SettingsTree(org: SettingsOrg(id: "test-org")))
    let speech = SpeechRegistry(engines: [])
    return (ComposerModel(window: window, speech: speech, fastPathRunner: { _, _ in outcome }), harness)
}

@MainActor
@Test func aFastPathLineStartsNoTurnAndLeavesAReceipt() async {
    let made = makeComposerWithFastPath(outcome: .ran(FastPathReceipt(
        line: "switch to staging", text: "Ran: switch environment to staging", refused: false)))
    made.composer.edited(draft: "switch to staging", caret: 17)
    await made.composer.submit()
    #expect(made.harness.sent.isEmpty)
    #expect(made.composer.receipt?.text == "Ran: switch environment to staging")
    #expect(made.composer.draft == "")
}

@MainActor
@Test func aRefusedFastPathLineKeepsItsReceiptAndConsumesAVoiceLine() async {
    let made = makeComposerWithFastPath(outcome: .refused(FastPathReceipt(
        line: "close confirm.go", text: "editor_close: unsaved changes", refused: true)))
    made.composer.edited(draft: "close confirm.go", caret: 16)
    await made.composer.submit()
    #expect(made.harness.sent.isEmpty)
    #expect(made.composer.receipt?.refused == true)
    #expect(made.composer.draft == "")
    #expect(!made.composer.landedUnsent)
}

@MainActor
@Test func askTheAgentInsteadSendsTheOriginalLine() async {
    let made = makeComposerWithFastPath(outcome: .ran(FastPathReceipt(
        line: "switch to staging", text: "Ran: switch environment to staging", refused: false)))
    made.composer.edited(draft: "switch to staging", caret: 17)
    await made.composer.submit()
    await made.composer.askAgentInstead()
    #expect(made.harness.sent == ["switch to staging"])
    #expect(made.composer.receipt == nil)
}

@MainActor
@Test func askingTheAgentWithNoAgentBringsTheLineBack() async {
    let window = WindowModel.forTesting(scratchRoot: testScratchRoot)
    window.setSettingsForTesting(SettingsTree(org: SettingsOrg(id: "test-org")))
    let composer = ComposerModel(window: window, speech: SpeechRegistry(engines: []), fastPathRunner: { _, _ in
        .ran(FastPathReceipt(line: "go to qa", text: "Ran: switch environment to qa", refused: false))
    })
    composer.edited(draft: "go to qa", caret: 8)
    await composer.submit()
    #expect(composer.draft == "")
    await composer.askAgentInstead()
    #expect(composer.receipt == nil)
    #expect(composer.draft == "go to qa", "Rule 2: a line no turn took comes back to the composer")
}

@MainActor
@Test func dismissingTheReceiptClearsItAndSendsNothing() async {
    let made = makeComposerWithFastPath(outcome: .ran(FastPathReceipt(line: "x", text: "Ran: x", refused: false)))
    made.composer.edited(draft: "x", caret: 1)
    await made.composer.submit()
    made.composer.dismissReceipt()
    #expect(made.composer.receipt == nil)
    #expect(made.harness.sent.isEmpty)
}

@MainActor
@Test func aLineTheFastPathDoesNotTakeIsSentAsToday() async {
    let made = makeComposerWithFastPath(outcome: .toAgent)
    made.composer.edited(draft: "why is it slow?", caret: 15)
    await made.composer.submit()
    #expect(made.harness.sent == ["why is it slow?"])
    #expect(made.composer.receipt == nil)
}

/// One harness per place the window asked one for, so a test can see whose agent took a turn.
private final class HarnessesByPlace: @unchecked Sendable {
    private let lock = NSLock()
    private var map: [Place: AcceptingHarness] = [:]
    func harness(for place: Place) -> AcceptingHarness {
        lock.withLock {
            if let h = map[place] { return h }
            let h = AcceptingHarness()
            map[place] = h
            return h
        }
    }
    func sent(in place: Place) -> [String] { lock.withLock { map[place]?.sent ?? [] } }
}

@MainActor
@Test func aToAgentLineGoesToThePlaceItWasTypedInEvenIfTheScreenMovedDuringTheWait() async {
    let harnesses = HarnessesByPlace()
    let window = WindowModel.forTesting(scratchRoot: testScratchRoot, harnessFactory: { place, _ in harnesses.harness(for: place) })
    window.setSettingsForTesting(SettingsTree(org: SettingsOrg(id: "test-org")))
    window.seedForTesting(providerId: "main", rootPath: "/a", thoughts: 0, project: "a", environment: "qa")
    let placeA = window.place
    let composer = ComposerModel(window: window, speech: SpeechRegistry(engines: []), fastPathRunner: { _, _ in
        try? await Task.sleep(for: .milliseconds(60))
        return .toAgent
    })
    composer.edited(draft: "why is it slow?", caret: 15)
    let submitting = Task { await composer.submit() }
    try? await Task.sleep(for: .milliseconds(20))
    window.seedForTesting(providerId: "main", rootPath: "/b", thoughts: 0, project: "b", environment: "qa")
    #expect(window.place != placeA)
    await submitting.value
    #expect(harnesses.sent(in: placeA) == ["why is it slow?"])
    #expect(harnesses.sent(in: window.place).isEmpty)
}

@MainActor
@Test func askTheAgentInsteadSendsAVoiceLineToThePlaceItWasSpokenIn() async throws {
    let harnesses = HarnessesByPlace()
    let window = WindowModel.forTesting(scratchRoot: testScratchRoot, harnessFactory: { place, _ in harnesses.harness(for: place) })
    window.setSettingsForTesting(SettingsTree(org: SettingsOrg(id: "test-org")))
    window.seedForTesting(providerId: "main", rootPath: "/a", thoughts: 0, project: "a", environment: "qa")
    let placeA = window.place
    let clock = Clock()
    let speech = SpeechRegistry(engines: [SpeechEngine(id: "apple", name: "Apple", make: {
        RecordingProvider(steps: [.init(after: 0, event: .partial(settled: "close confirm.go", volatile: ""))])
    })])
    var runnerScope: WindowModel.TurnScope?
    let composer = ComposerModel(window: window, speech: speech, now: { clock.t }, fastPathRunner: { line, scope in
        runnerScope = scope
        return .refused(FastPathReceipt(line: line, text: "editor_close: unsaved changes", refused: true))
    })
    composer.optionDown(); clock.t = 0.2; composer.tick()
    await settle(until: { !composer.machine.settled.isEmpty })
    clock.t = 1; composer.optionUp()
    await settle(until: { composer.machine.phase == .idle })
    #expect(composer.landedUnsent)
    await composer.submit()
    #expect(runnerScope?.place == placeA, "the runner is handed the place the line was typed in")
    #expect(composer.receipt?.refused == true)
    window.seedForTesting(providerId: "main", rootPath: "/b", thoughts: 0, project: "b", environment: "qa")
    #expect(window.place != placeA)
    await composer.askAgentInstead()
    #expect(harnesses.sent(in: placeA) == ["close confirm.go"])
    #expect(harnesses.sent(in: window.place).isEmpty)
    let entries = try await window.registryForTesting.journalEntries()
    #expect(entries.contains { $0.action == "voice_turn" }, "the re-send keeps the line's voice provenance")
}

/// 3a-ii walk: a second hold hid what the first had landed, so the operator said the sentence again and
/// it landed twice. The second hold draws the line it already holds, the new words after it.
@MainActor
@Test func aSecondHoldKeepsTheFirstWordsInView() async {
    let clock = Clock()
    let (composer, _, _) = model(steps: [.init(after: 0, event: .partial(settled: "open the", volatile: "book"))],
                                 clock: clock)
    composer.optionDown(); clock.t = 0.2; composer.tick()
    await settle(until: { !composer.machine.settled.isEmpty })
    clock.t = 1; composer.optionUp()
    await settle(until: { composer.machine.phase == .idle })
    #expect(composer.draft == "open the book")

    clock.t = 2; composer.optionDown(); clock.t = 2.2; composer.tick()
    #expect(composer.bar == .hearing(before: "open the book", settled: "", volatile: "", after: "",
                                     hint: ComposerBarContent.releaseHint))
    await settle(until: { !composer.machine.settled.isEmpty })
    #expect(composer.bar == .hearing(before: "open the book ", settled: "open the", volatile: "book", after: "",
                                     hint: ComposerBarContent.releaseHint))
    clock.t = 3; composer.optionUp()
    await settle(until: { composer.machine.phase == .idle })
    #expect(composer.draft == "open the book open the book")
}

@MainActor
@Test func eachScreenKeepsItsOwnDraftAndASwitchStopsDictation() {
    let (composer, _, _) = model(steps: [], clock: Clock())
    let before = composer.focusToken
    composer.edited(draft: "half a thought", caret: 14)
    composer.screenChanged(from: "conv-a", to: "landing:r", focusComposer: true)
    #expect(composer.draft.isEmpty && composer.caret == 0 && composer.focusToken == before + 1)
    composer.screenChanged(from: "landing:r", to: "conv-a", focusComposer: false)
    #expect(composer.draft == "half a thought" && composer.caret == 14)
    #expect(composer.focusToken == before + 1, "not asked to focus")
}

@MainActor
@Test func aSwitchMidHoldStopsListeningAndLandsTheWordsInTheDraftTheyWereSpokenInto() async {
    let clock = Clock()
    let (composer, window, _) = model(steps: [
        .init(after: 0, event: .started(device: "Test Mic")),
        .init(after: 0, event: .partial(settled: "show", volatile: "tables")),
    ], clock: clock)
    composer.edited(draft: "please ", caret: 7)
    composer.optionDown()
    clock.t = 0.2; composer.tick()
    await settle(until: { !composer.machine.settled.isEmpty })

    clock.t = 1; composer.screenChanged(from: "conv-a", to: "conv-b", focusComposer: false)
    await settle(until: { composer.machine.phase == .idle })

    #expect(window.coreState == .idle, "dictation stopped")
    #expect(composer.draft.isEmpty, "nothing lands in the screen switched to")
    composer.screenChanged(from: "conv-b", to: "conv-a", focusComposer: false)
    #expect(composer.draft == "please show tables", "\(composer.draft)")
}

@MainActor
@Test func theComposerFollowsTheWindowsScreenChanges() {
    let (composer, window, _) = model(steps: [], clock: Clock())
    composer.edited(draft: "kept", caret: 4)
    window.onScreenChange?("conv-a", "landing:r", true)
    #expect(composer.draft.isEmpty)
    window.onScreenChange?("landing:r", "conv-a", false)
    #expect(composer.draft == "kept")
}

/// 3c-ii (ruling 13): a spoken line the operator adds typed words to is still spoken — its site
/// question waits for the typed word (Invariant 7) — and only emptying the composer makes what is
/// typed next a typed line.
@MainActor
@Test func aVoiceDraftEditedWithTypedWordsStaysSpokenUntilItIsEmptied() async throws {
    let clock = Clock()
    let (composer, window, harness) = model(steps: [
        .init(after: 0, event: .partial(settled: "say hello", volatile: "")),
    ], clock: clock)
    composer.optionDown(); clock.t = 0.2; composer.tick()
    await settle(until: { !composer.machine.settled.isEmpty })
    clock.t = 1; composer.optionUp()
    await settle(until: { composer.machine.phase == .idle })
    #expect(composer.draft == "say hello" && composer.landedUnsent)

    composer.edited(draft: "say hello then fill the guest name", caret: 34)
    #expect(composer.landedUnsent, "typed words added to a spoken line keep it spoken")
    await composer.submit()
    let agent = try #require(window.currentAgent)
    #expect(harness.sent.last == "say hello then fill the guest name")
    #expect(agent.lastTurnSource == .voice)

    agent.turnInFlight = false
    composer.optionDown(); clock.t = 1.2; composer.tick()
    await settle(until: { !composer.machine.settled.isEmpty })
    clock.t = 2; composer.optionUp()
    await settle(until: { composer.machine.phase == .idle })
    #expect(composer.landedUnsent)
    composer.edited(draft: "", caret: 0)
    #expect(!composer.landedUnsent, "an emptied composer holds nothing spoken")
    composer.edited(draft: "fill the guest name", caret: 19)
    await composer.submit()
    #expect(agent.lastTurnSource == .typed)
}

@MainActor
@Test func theBarHintFollowsTheWindowsKeymap() {
    let (composer, window, _) = model(steps: [], clock: Clock())
    #expect(composer.bar == .draft(hint: "Hold ⌥ to speak · ⌘P open · ⌘K actions"))
    window.keymap = Keymap(overrides: ["window.open": "⌃⌘O", "window.commands": "⌃⌘K"])
    #expect(composer.bar == .draft(hint: "Hold ⌥ to speak · ⌃⌘O open · ⌃⌘K actions"))
}
