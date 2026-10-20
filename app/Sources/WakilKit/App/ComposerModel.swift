import Foundation
import Observation

/// The composer bar's model (2d-ii): the draft the operator types into and
/// speech lands in, and the coordinator that runs `ListeningMachine`'s
/// effects against a speech engine. `WakilApp` forwards ⌥, other keys,
/// clicks, Esc, app deactivation and a ~20 Hz tick; everything decided is
/// decided here or in the machine.
@MainActor
@Observable
public final class ComposerModel {
    public var draft = ""
    /// UTF-16 offset, as `NSTextView` reports it.
    public var caret = 0
    public private(set) var machine = ListeningMachine()
    /// True from a landing until the draft is sent or emptied.
    public private(set) var landedUnsent = false
    /// Bumped on every landing; the bar focuses its field when it changes.
    public private(set) var focusToken = 0

    /// What a fast-path line did (3b-ix): kept until the next line, "Ask the agent instead" or Esc.
    public private(set) var receipt: FastPathReceipt?

    private let window: WindowModel
    private let fastPathRunner: (String, WindowModel.TurnScope) async -> FastPathOutcome
    private let speech: SpeechRegistry
    private let now: @MainActor () -> Double
    private var provider: (any SpeechProvider)?
    private var pump: Task<Void, Never>?
    /// Which hold an engine belongs to, so a late engine from an earlier
    /// hold is cancelled instead of adopted.
    private var hold = 0

    public init(
        window: WindowModel, speech: SpeechRegistry,
        now: @escaping @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime },
        fastPathRunner: ((String, WindowModel.TurnScope) async -> FastPathOutcome)? = nil
    ) {
        self.window = window
        self.fastPathRunner = fastPathRunner ?? { [window] line, scope in await window.runFastPath(line, scope: scope) }
        self.speech = speech
        self.now = now
    }

    public var bar: ComposerBarContent {
        .make(machine: machine, landedUnsent: landedUnsent && !draft.isEmpty)
    }

    public func optionDown() { run(machine.optionDown(at: now())) }
    public func optionUp() { run(machine.optionUp(at: now())) }
    /// Another key, chord or click. True when the key must be swallowed so it
    /// cannot type into the field behind a listening bar that has words.
    @discardableResult
    public func otherInput() -> Bool {
        let swallow = machine.swallowsOtherInput
        run(machine.otherInput())
        return swallow
    }
    public func resigned() { run(machine.resigned(at: now())) }
    public func tick() { run(machine.tick(at: now())) }

    /// True when Esc belonged to listening and must not reach anything else.
    public func escape() -> Bool {
        let consumed = machine.phase != .idle
        run(machine.escape())
        return consumed
    }

    public func edited(draft: String, caret: Int) {
        self.draft = draft
        self.caret = caret
        if draft.isEmpty { landedUnsent = false }
    }

    public func submit() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let source: WindowModel.TurnSource = landedUnsent ? .voice : .typed
        // Read before the first await: the line belongs to the place it was typed in.
        let scope = window.turnScope
        draft = ""
        caret = 0
        landedUnsent = false
        receipt = nil
        switch await fastPathRunner(text, scope) {
        case .ran(var r), .refused(var r):
            // Rule 2: a refused line is kept here, with Ask the agent instead, which re-sends it
            // where it was typed and as it came (a spoken line stays a voice turn).
            r.scope = scope
            r.source = source
            receipt = r
            return
        case .toAgent:
            break
        }
        let started = await window.send(text, via: source, scope: scope)
        // No turn started (no harness, a failed send): the
        // operator's words come back. Not if they have typed since.
        if !started, draft.isEmpty {
            draft = text
            caret = (text as NSString).length
            landedUnsent = source == .voice
        }
    }

    /// Sends the line a receipt answered to the agent after all: to the place it was typed in, with
    /// its source.
    public func askAgentInstead() async {
        guard let r = receipt else { return }
        receipt = nil
        _ = await window.send(r.line, via: r.source, scope: r.scope)
    }

    /// Clears the receipt (the bar calls it on Esc in an empty composer).
    public func dismissReceipt() { receipt = nil }

    private func run(_ effects: [ListeningMachine.Effect]) {
        window.setListening(machine.isListening)
        for effect in effects {
            switch effect {
            case .startEngine:
                hold += 1
                start(hold: hold)
            case .stopEngine:
                let current = provider
                Task { await current?.stop() }
            case .cancelEngine:
                let current = provider
                provider = nil
                pump?.cancel()
                pump = nil
                Task { await current?.cancel() }
            case .land(let text):
                let landed = ComposerText.insert(text, into: draft, at: caret)
                draft = landed.draft
                caret = landed.caret
                landedUnsent = true
                focusToken += 1
            case .failed(let message):
                window.appendSpeechFailure(message)
            }
        }
        // A hold that ended on its own (landed, failed) leaves nothing for the
        // next hold's stop/cancel to reach. Cleared, not cancelled: the stream
        // has already ended in those cases.
        if machine.phase == .idle {
            provider = nil
            pump = nil
        }
        window.setListening(machine.isListening)
    }

    private func start(hold: Int) {
        Task { [weak self] in
            guard let self else { return }
            let stored = await self.window.speechEngineId()
            // Released, Esc'd or re-held while the lookup ran: start nothing.
            guard self.hold == hold, self.machine.isCapturing else { return }
            guard let engine = self.speech.resolve(stored).engine else {
                self.run(self.machine.receive(.failed("no speech engine is available on this Mac")))
                return
            }
            let provider = engine.make()
            self.provider = provider
            let events = provider.start(locale: Locale(identifier: "en-US"))
            self.pump = Task { [weak self] in
                for await event in events {
                    guard let self, self.hold == hold else { return }
                    self.run(self.machine.receive(event, at: self.now()))
                }
            }
        }
    }
}
