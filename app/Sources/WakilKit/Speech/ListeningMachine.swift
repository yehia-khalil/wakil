import Foundation

/// Push-to-talk (2d-ii), as a pure state machine: every input carries the
/// time it happened, and every transition returns the effects
/// `ComposerModel` must run. No clock, no engine, no AppKit — so every
/// rule below is a unit test.
public struct ListeningMachine: Sendable, Equatable {
    /// ⌥ must be held alone this long before listening starts, so ⌥ used as
    /// a modifier never opens the microphone.
    public static let armDelay: Double = 0.18
    /// No sound at all for this long after listening starts names the
    /// input device (design-language §12's silence case, in words).
    public static let silenceAfter: Double = 1.5
    /// How long after release to wait for the engine's `.final` before
    /// landing what was already heard.
    public static let finishTimeout: Double = 2.0

    public enum Phase: Sendable, Equatable {
        case idle
        case arming(since: Double)
        case listening(since: Double)
        case finishing(since: Double)
    }

    public enum Notice: Sendable, Equatable {
        case heardNothing(device: String)
        case denied
        case permissionPending
        case downloading(fraction: Double, totalBytes: Int64)
    }

    public enum Effect: Sendable, Equatable {
        case startEngine
        case stopEngine
        case cancelEngine
        case land(String)
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var settled = ""
    public private(set) var volatile = ""
    public private(set) var notice: Notice?
    /// A permission notice that stays after the hold ends, until the next
    /// ⌥ press: a refusal or a pending macOS prompt usually ends the hold
    /// itself (the prompt takes the key window), and a sentence that left
    /// with it was never read (2d-ii walk).
    public private(set) var standingNotice: Notice?
    private var device = "the microphone"
    private var heardSound = false

    public init() {}

    /// Listening or finishing — what the room's state follows.
    public var isListening: Bool {
        switch phase {
        case .listening, .finishing: return true
        case .idle, .arming: return false
        }
    }

    /// Listening and still holding — the only phase an engine may start in.
    public var isCapturing: Bool {
        if case .listening = phase { return true }
        return false
    }

    public var heard: String {
        [settled, volatile]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    public mutating func optionDown(at now: Double) -> [Effect] {
        guard phase == .idle else { return [] }
        standingNotice = nil
        phase = .arming(since: now)
        return []
    }

    public mutating func optionUp(at now: Double) -> [Effect] {
        switch phase {
        case .arming:
            phase = .idle
            return []
        case .listening:
            phase = .finishing(since: now)
            return [.stopEngine]
        case .idle, .finishing:
            return []
        }
    }

    /// Listening, still holding, with words already heard: another key must
    /// not type into the field behind the bar, so the bar swallows it.
    public var swallowsOtherInput: Bool {
        if case .listening = phase { return !heard.isEmpty }
        return false
    }

    /// Another key, chord or click. While arming it spoils the hold (⌥ was a
    /// modifier). While listening with nothing heard yet it is a late chord:
    /// behave like Esc. With words heard, leave the hold alone.
    public mutating func otherInput() -> [Effect] {
        switch phase {
        case .arming:
            phase = .idle
            return []
        case .listening where heard.isEmpty:
            reset()
            return [.cancelEngine]
        default:
            return []
        }
    }

    public mutating func escape() -> [Effect] {
        switch phase {
        case .listening, .finishing:
            reset()
            return [.cancelEngine]
        case .arming:
            phase = .idle
            return []
        case .idle:
            return []
        }
    }

    public mutating func resigned(at now: Double) -> [Effect] { optionUp(at: now) }

    public mutating func tick(at now: Double) -> [Effect] {
        switch phase {
        case .arming(let since) where now - since >= Self.armDelay:
            reset()
            phase = .listening(since: now)
            return [.startEngine]
        case .listening(let since):
            if !heardSound, notice == nil, now - since >= Self.silenceAfter {
                notice = .heardNothing(device: device)
            }
            return []
        case .finishing(let since) where now - since >= Self.finishTimeout:
            let text = heard
            reset()
            return text.isEmpty ? [.cancelEngine] : [.cancelEngine, .land(text)]
        default:
            return []
        }
    }

    /// `now`, when the caller has it, lets `.started` restart the silence clock.
    public mutating func receive(_ event: SpeechEvent, at now: Double? = nil) -> [Effect] {
        guard isListening else { return [] }
        switch event {
        case .started(let name):
            device = name
            // Listening begins now: a model download is over, and the
            // silence rule counts from here, not from the key going down.
            if case .downloading = notice { notice = nil }
            if let now, case .listening = phase { phase = .listening(since: now) }
            return []
        case .audio:
            heardSound = true
            if case .heardNothing = notice { notice = nil }
            if case .downloading = notice { notice = nil }
            return []
        case .partial(let newSettled, let newVolatile):
            settled = newSettled
            volatile = newVolatile
            heardSound = true
            if case .heardNothing = notice { notice = nil }
            if case .downloading = notice { notice = nil }
            return []
        case .downloading(let fraction, let total):
            notice = .downloading(fraction: fraction, totalBytes: total)
            return []
        case .denied:
            notice = .denied
            standingNotice = .denied
            return []
        case .permissionPending:
            notice = .permissionPending
            standingNotice = .permissionPending
            return []
        case .final(let text):
            guard case .finishing = phase else {
                settled = text
                volatile = ""
                return []
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // An empty final does not discard what was already heard.
            let landing = trimmed.isEmpty ? heard : trimmed
            reset()
            return landing.isEmpty ? [] : [.land(landing)]
        case .failed(let message):
            let text = heard
            reset()
            return text.isEmpty ? [.failed(message)] : [.land(text), .failed(message)]
        }
    }

    private mutating func reset() {
        phase = .idle
        settled = ""
        volatile = ""
        notice = nil
        heardSound = false
        device = "the microphone"
    }
}
