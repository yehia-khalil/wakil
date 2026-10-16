import Foundation

/// A speech engine that plays a fixed script — the unit tests' fake and the
/// e2e harness's microphone (`WAKIL_SPEECH_SCRIPT`). It keeps the provider
/// contract: on `stop()` it yields a `.final` of what its partials said,
/// unless the script already contained one.
public final class ScriptedSpeechProvider: SpeechProvider, @unchecked Sendable {
    public struct Step: Sendable, Equatable, Decodable {
        public let after: Double
        public let event: SpeechEvent

        public init(after: Double, event: SpeechEvent) {
            self.after = after
            self.event = event
        }

        private enum Keys: String, CodingKey {
            case after, kind, device, settled, volatile, text, fraction, totalBytes, message
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            after = try c.decodeIfPresent(Double.self, forKey: .after) ?? 0
            switch try c.decode(String.self, forKey: .kind) {
            case "started": event = .started(device: try c.decode(String.self, forKey: .device))
            case "audio": event = .audio
            case "partial":
                event = .partial(
                    settled: try c.decodeIfPresent(String.self, forKey: .settled) ?? "",
                    volatile: try c.decodeIfPresent(String.self, forKey: .volatile) ?? "")
            case "final": event = .final(try c.decode(String.self, forKey: .text))
            case "denied": event = .denied
            case "permissionPending": event = .permissionPending
            case "downloading":
                event = .downloading(
                    fraction: try c.decode(Double.self, forKey: .fraction),
                    totalBytes: try c.decodeIfPresent(Int64.self, forKey: .totalBytes) ?? 0)
            case "failed": event = .failed(try c.decode(String.self, forKey: .message))
            case let other:
                throw DecodingError.dataCorruptedError(
                    forKey: .kind, in: c, debugDescription: "unknown speech step kind '\(other)'")
            }
        }
    }

    public static func load(_ path: String) throws -> [Step] {
        try JSONDecoder().decode([Step].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    private let steps: [Step]
    private let lock = NSLock()
    // All mutable state below is guarded by `lock`. Yields happen under it
    // too (AsyncStream.Continuation.yield never blocks), so nothing can be
    // yielded after the stream has finished. No onTermination handler may
    // re-enter this lock.
    private var continuation: AsyncStream<SpeechEvent>.Continuation?
    private var player: Task<Void, Never>?
    private var heard = ""
    private var finished = false

    public init(steps: [Step]) { self.steps = steps }

    public func start(locale: Locale) -> AsyncStream<SpeechEvent> {
        let (stream, continuation) = AsyncStream<SpeechEvent>.makeStream()
        let steps = self.steps
        // Publish the continuation before the player can emit, or a step
        // with after == 0 would be dropped and a final could never finish.
        lock.withLock { self.continuation = continuation }
        let player = Task { [weak self] in
            for step in steps {
                if step.after > 0 { try? await Task.sleep(for: .seconds(step.after)) }
                if Task.isCancelled { return }
                self?.emit(step.event)
            }
        }
        lock.withLock { self.player = player }
        return stream
    }

    public func stop() async {
        lock.withLock {
            if finished { return }
            finished = true
            player?.cancel()
            continuation?.yield(.final(heard))
            continuation?.finish()
        }
    }

    public func cancel() async {
        lock.withLock {
            if finished { return }
            finished = true
            player?.cancel()
            continuation?.finish()
        }
    }

    private func emit(_ event: SpeechEvent) {
        lock.withLock {
            if finished { return }
            if case .partial(let settled, let volatile) = event {
                heard = [settled, volatile].filter { !$0.isEmpty }.joined(separator: " ")
            }
            continuation?.yield(event)
            switch event {
            case .final, .failed:
                finished = true
                continuation?.finish()
            default: break
            }
        }
    }
}
