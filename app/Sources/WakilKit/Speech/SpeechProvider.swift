import Foundation

/// What a speech engine reports while it listens (2d-ii). Decision 18's
/// "audio in, text out", plus the three things the composer bar must be
/// able to say in words: nothing heard, permission refused, model loading.
///
/// **`.audio` is presence, never a level.** design-language §12 forbids a
/// meter; the only thing the app does with sound is notice its absence.
public enum SpeechEvent: Sendable, Equatable {
    /// Audio is flowing from this input device. The first event once audio
    /// flows; `.downloading`, `.denied` or `.failed` may come before it.
    case started(device: String)
    /// Sound above the engine's floor arrived. Rate-limited by the engine.
    case audio
    /// The engine's current reading: words it will not revise, then its
    /// unsettled tail.
    case partial(settled: String, volatile: String)
    /// The whole utterance, after `stop()`. Exactly once, then the stream ends.
    case final(String)
    /// Microphone permission is refused.
    case denied
    /// Microphone access has never been asked, and the macOS prompt is
    /// being raised now. The prompt takes the key window, which ends the
    /// hold, so the bar says what to do next instead of falling silent.
    case permissionPending
    /// The engine's model is downloading. `totalBytes` is 0 when unknown.
    case downloading(fraction: Double, totalBytes: Int64)
    /// The engine failed. The stream ends after this.
    case failed(String)
}

/// One speech-to-text engine (Invariant 11: pluggable, per organization).
///
/// Contract: `start` returns a stream. `.started(device:)` is the first event
/// once audio flows, but `.downloading`, `.denied` or `.failed` may precede
/// it (or replace it). `stop()` asks the engine to finish; the stream then
/// yields exactly one `.final` and ends. `cancel()` ends the stream with no
/// `.final`. A provider instance serves one hold; the registry makes a new
/// one each time.
public protocol SpeechProvider: AnyObject, Sendable {
    func start(locale: Locale) -> AsyncStream<SpeechEvent>
    func stop() async
    func cancel() async
}

/// A registered engine: its `org.json` id, the name the Speech row shows,
/// and how to make one.
public struct SpeechEngine: Sendable {
    public let id: String
    public let name: String
    public let make: @Sendable () -> any SpeechProvider

    public init(id: String, name: String, make: @escaping @Sendable () -> any SpeechProvider) {
        self.id = id
        self.name = name
        self.make = make
    }
}

/// Which engines exist, and which one an organization's `speechProvider`
/// names. A new engine is one conformance and one entry here.
public struct SpeechRegistry: Sendable {
    public static let defaultId = "apple"

    public let engines: [SpeechEngine]
    /// Replaces every lookup when set — the e2e harness's scripted engine,
    /// so a check never reaches a real microphone.
    public let override: SpeechEngine?

    public init(engines: [SpeechEngine], override: SpeechEngine? = nil) {
        self.engines = engines
        self.override = override
    }

    /// The engine to listen with for a stored id, and a sentence when the
    /// stored id could not be honoured.
    public func resolve(_ stored: String) -> (engine: SpeechEngine?, note: String?) {
        if let override { return (override, nil) }
        return lookup(stored)
    }

    /// The Speech row's note for a stored id, ignoring any override.
    public func note(for stored: String) -> String? { lookup(stored).note }

    private func lookup(_ stored: String) -> (engine: SpeechEngine?, note: String?) {
        let id = stored.isEmpty ? Self.defaultId : stored
        if let exact = engines.first(where: { $0.id == id }) { return (exact, nil) }
        guard let fallback = engines.first(where: { $0.id == Self.defaultId }) else {
            return (nil, "no speech engine is available on this Mac")
        }
        return (fallback, "unknown engine '\(stored)', using \(fallback.name)")
    }
}
