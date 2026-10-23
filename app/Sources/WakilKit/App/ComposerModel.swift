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
    /// The draft and caret of every screen not shown, by `WindowModel.screenKey` (conversations
    /// 2 of 3): text only — a landed-unsent mark does not travel.
    private var drafts: [String: (draft: String, caret: Int)] = [:]
    /// The screen the draft on show belongs to, and the one the hold in progress was begun on:
    /// words heard before a switch land in the draft they were spoken into, not the one switched to.
    private var screen: String
    private var holdScreen: String?

    public init(
        window: WindowModel, speech: SpeechRegistry,
        now: @escaping @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime },
        fastPathRunner: ((String, WindowModel.TurnScope) async -> FastPathOutcome)? = nil
    ) {
        self.window = window
        self.fastPathRunner = fastPathRunner ?? { [window] line, scope in await window.runFastPath(line, scope: scope) }
        self.speech = speech
        self.now = now
        self.screen = window.screenKey
        window.onScreenChange = { [weak self] from, to, focusComposer in
            self?.screenChanged(from: from, to: to, focusComposer: focusComposer)
        }
    }

    /// The screen moved from `from` to `to` (`WindowModel.onScreenChange`): dictation stops
    /// (`resigned`), the draft and caret are kept under `from`, and `to`'s come back — empty for
    /// a screen never typed on. `focusComposer` hands the field the keyboard (ruling 7). A
    /// fast-path receipt answered a line typed on the screen left, and goes.
    ///
    /// One screen renamed (`WindowModel.isSameScreenRenamed`) — a Landing whose first message
    /// made it a conversation — is not a change: only its key moves, and the draft (what was
    /// typed while that message went out), a hold and the keyboard stay where they are.
    public func screenChanged(from: String, to: String, focusComposer: Bool) {
        if window.isSameScreenRenamed(from: from, to: to) {
            if holdScreen == screen || holdScreen == from { holdScreen = to }
            screen = to
            return
        }
        resigned()
        receipt = nil
        drafts[from] = (draft, caret)
        let next = drafts.removeValue(forKey: to)
        draft = next?.draft ?? ""
        caret = next?.caret ?? 0
        landedUnsent = false
        // A hold begun on the screen on show was spoken into the draft just kept under `from`.
        if holdScreen == screen { holdScreen = from }
        screen = to
        if focusComposer { focusToken += 1 }
    }

    public var bar: ComposerBarContent {
        .make(machine: machine, landedUnsent: landedUnsent && !draft.isEmpty, draft: draft, caret: caret)
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
        // Read before the first await: the line belongs to the conversation it was typed on —
        // on a Landing, the one its first message starts (`WindowModel.pinTurnScope`) — and the
        // screen it was typed on is where it comes back to.
        let scope = window.pinTurnScope()
        let typedOn = screen
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
        // No turn started (no harness, a failed send, a screen gone): the operator's words come
        // back to the screen they were typed on (Rule 2) — on show, or kept for it when the
        // screen has moved — not to whichever is shown now. Not if they have typed there since.
        guard !started else { return }
        if screen == typedOn || window.isSameScreenRenamed(from: typedOn, to: screen) {
            guard draft.isEmpty else { return }
            draft = text
            caret = (text as NSString).length
            landedUnsent = source == .voice
        } else if drafts[typedOn]?.draft.isEmpty ?? true {
            drafts[typedOn] = (text, (text as NSString).length)
        }
    }

    /// Sends the line a receipt answered to the agent after all: to the place it was typed in, with
    /// its source. No turn started (no harness, a failed send): the line comes back, as `submit`'s
    /// does (Rule 2), unless the operator has typed since.
    public func askAgentInstead() async {
        guard let r = receipt else { return }
        receipt = nil
        let started = await window.send(r.line, via: r.source, scope: r.scope)
        if !started, draft.isEmpty {
            draft = r.line
            caret = (r.line as NSString).length
            landedUnsent = r.source == .voice
        }
    }

    /// Clears the receipt (the bar calls it on Esc in an empty composer).
    public func dismissReceipt() { receipt = nil }

    private func run(_ effects: [ListeningMachine.Effect]) {
        window.setListening(machine.isListening)
        for effect in effects {
            switch effect {
            case .startEngine:
                hold += 1
                holdScreen = screen
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
                if let spokenIn = holdScreen, spokenIn != screen {
                    // Spoken into a screen since left: it lands there, waiting, unfocused.
                    let left = drafts[spokenIn] ?? ("", 0)
                    let landed = ComposerText.insert(text, into: left.draft, at: left.caret)
                    drafts[spokenIn] = (landed.draft, landed.caret)
                    continue
                }
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
            holdScreen = nil
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
