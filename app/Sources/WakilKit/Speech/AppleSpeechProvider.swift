import Foundation

extension SpeechRegistry {
    /// The engines this build ships, plus the e2e override when
    /// `WAKIL_SPEECH_SCRIPT` names a script. An unreadable script becomes an
    /// engine that fails with the path, never a silent fall-through to the
    /// real microphone.
    public static func standard(environment: [String: String]) -> SpeechRegistry {
        var engines: [SpeechEngine] = []
        #if canImport(Speech)
        if #available(macOS 26.0, *) {
            engines.append(SpeechEngine(id: "apple", name: "Apple", make: { AppleSpeechProvider() }))
        }
        #endif
        var override: SpeechEngine?
        if let path = environment["WAKIL_SPEECH_SCRIPT"], !path.isEmpty {
            let steps: [ScriptedSpeechProvider.Step]
            do {
                steps = try ScriptedSpeechProvider.load(path)
            } catch {
                steps = [.init(after: 0, event: .failed("speech script \(path) unreadable: \(error)"))]
            }
            override = SpeechEngine(id: "scripted", name: "Scripted", make: { ScriptedSpeechProvider(steps: steps) })
        }
        return SpeechRegistry(engines: engines, override: override)
    }
}

#if canImport(Speech)
import AVFoundation
import CoreAudio
import Speech

/// One speech-model install per locale, for the whole process. Created as an
/// unstructured task that no hold's `stop()` or `cancel()` reaches, so the
/// first-use download survives the operator letting go of ⌥, and the next hold
/// joins it instead of starting a second. A failed install is dropped when it
/// ends, so the next hold retries; the failure itself stays on the `Install`
/// every waiting hold already has.
@available(macOS 26.0, *)
actor SpeechAssetInstaller {
    static let shared = SpeechAssetInstaller()

    final class Install: @unchecked Sendable {
        private let lock = NSLock()
        private var _progress: Progress?
        private var _result: Result<Void, Error>?
        var progress: Progress? { lock.withLock { _progress } }
        var result: Result<Void, Error>? { lock.withLock { _result } }
        func setProgress(_ progress: Progress) { lock.withLock { _progress = progress } }
        func finish(_ result: Result<Void, Error>) { lock.withLock { _result = result } }
    }

    private var installs: [String: Install] = [:]

    func install(for transcriber: SpeechTranscriber, locale: Locale) -> Install {
        let key = locale.identifier
        if let running = installs[key] { return running }
        let install = Install()
        installs[key] = install
        Task {
            do {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    install.setProgress(request.progress)
                    try await request.downloadAndInstall()
                }
                install.finish(.success(()))
            } catch {
                install.finish(.failure(error))
            }
            self.remove(key, install)
        }
        return install
    }

    private func remove(_ key: String, _ install: Install) {
        if installs[key] === install { installs[key] = nil }
    }
}

/// Apple's on-device engine (`SpeechAnalyzer` + `SpeechTranscriber`, macOS
/// 26), the default since open question 10 closed. Audio never leaves the
/// machine. Plumbing follows `scripts/probe/sttspike`, changed from a file
/// to a live input tap. Vocabulary biasing is deliberately not set:
/// `2d-stt-probe.md` §6.1 measured `contextualStrings` inert.
@available(macOS 26.0, *)
public final class AppleSpeechProvider: SpeechProvider, @unchecked Sendable {
    /// RMS above this counts as sound. Presence only — never drawn.
    private static let soundFloor: Float = 0.01

    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var runner: Task<Void, Never>?
    private var collector: Task<String, Error>?
    private var stopping = false
    private var cancelled = false

    /// Written on the audio thread only; boxed so the tap closure can mutate it.
    private final class SoundClock: @unchecked Sendable {
        var last = Date.distantPast
    }

    public init() {}

    public func start(locale: Locale) -> AsyncStream<SpeechEvent> {
        let (events, out) = AsyncStream<SpeechEvent>.makeStream()
        // Strong on purpose: the post-run release must happen even when the
        // coordinator has dropped its reference. The task ends, so no leak.
        // And `run` cannot hang on a stop or cancel: every flag check and
        // every touch of the engine shares one lock with `releaseAudio`, so
        // a stop/cancel is either seen before the engine starts (run returns
        // without starting it) or finds it running and stops it; cancel also
        // cancels the stored collector, the only thing `run` can wait on.
        let task = Task {
            await self.run(locale: locale, out: out)
            self.releaseAudio()
            out.finish()
        }
        lock.withLock { runner = task }
        return events
    }

    public func stop() async {
        let analyzer: SpeechAnalyzer? = lock.withLock {
            if stopping || cancelled { return nil }
            stopping = true
            return self.analyzer
        }
        releaseAudio()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
    }

    public func cancel() async {
        let (analyzer, runner, collector): (SpeechAnalyzer?, Task<Void, Never>?, Task<String, Error>?) = lock.withLock {
            if cancelled { return (nil, nil, nil) }
            cancelled = true
            return (self.analyzer, self.runner, self.collector)
        }
        releaseAudio()
        collector?.cancel()
        await analyzer?.cancelAndFinishNow()
        runner?.cancel()
    }

    /// Removes the tap, stops the engine and ends the analyzer's input.
    /// Idempotent. Called on stop, cancel, and when the run ends by itself
    /// (`.final` or `.failed`), since the coordinator drops its reference
    /// after a natural end without calling `cancel()`.
    private func releaseAudio() {
        // Under the lock, so it never overlaps `run`'s installTap/prepare/start.
        // The tap closure never takes this lock, so removeTap cannot deadlock.
        lock.withLock {
            engine?.inputNode.removeTap(onBus: 0)
            engine?.stop()
            input?.finish()
            engine = nil
            input = nil
        }
    }

    private func run(locale: Locale, out: AsyncStream<SpeechEvent>.Continuation) async {
        // Never asked before (every fresh ad-hoc build is new to macOS):
        // say so first, because the prompt about to appear takes the key
        // window and ends the hold (2d-ii walk).
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            out.yield(.permissionPending)
        }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            out.yield(.denied)
            // Exactly one `.final` after `stop()`, even when access is refused.
            if lock.withLock({ stopping && !cancelled }) { out.yield(.final("")) }
            return
        }
        do {
            let transcriber = SpeechTranscriber(
                locale: locale, transcriptionOptions: [],
                // `.fastResults` as well as `.volatileResults`: without it the
                // volatile tail lags the voice by whole chunks, so a short
                // sentence showed nothing while held and only its final on
                // release (found on the 2d-ii walk). The pair is what Apple's
                // `.progressiveTranscription` preset sets for live captions.
                reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
            // The install belongs to the process, not to this hold: releasing
            // ⌥ stops or cancels the hold, never the download. This hold
            // watches it, and a later hold joins the same one.
            let install = await SpeechAssetInstaller.shared.install(for: transcriber, locale: locale)
            while true {
                if let result = install.result {
                    try result.get()
                    break
                }
                let flags: (cancelled: Bool, stopping: Bool) = lock.withLock { (cancelled, stopping) }
                if flags.cancelled { return }
                if flags.stopping {
                    out.yield(.final(""))
                    return
                }
                if let progress = install.progress {
                    out.yield(.downloading(fraction: progress.fractionCompleted, totalBytes: progress.totalUnitCount))
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            // A release or cancel that landed while the model was loading.
            let early: (cancelled: Bool, stopping: Bool) = lock.withLock { (cancelled, stopping) }
            if early.cancelled { return }
            if early.stopping {
                out.yield(.final(""))
                return
            }
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                out.yield(.failed("the speech model accepts no audio format this Mac offers"))
                return
            }
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            // Load the model before audio arrives, so the first words are
            // transcribed while the operator is still speaking rather than
            // after a cold start eats the opening of a short hold.
            try await analyzer.prepareToAnalyze(in: format)
            let (inputs, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
            let engine = AVAudioEngine()
            let node = engine.inputNode
            let natural = node.outputFormat(forBus: 0)
            guard let converter = AVAudioConverter(from: natural, to: format) else {
                out.yield(.failed("cannot convert \(natural) to \(format)"))
                return
            }
            let clock = SoundClock()
            // ONE critical section: the flag re-check, the store, installTap,
            // prepare and start. `releaseAudio` takes the same lock, so it
            // runs entirely before (the check below sees it and the tap is
            // never installed) or entirely after (the engine is fully
            // started and gets stopped).
            let flags: (cancelled: Bool, stopping: Bool) = try lock.withLock {
                if cancelled || stopping { return (cancelled, stopping) }
                self.engine = engine
                self.analyzer = analyzer
                self.input = inputContinuation
                node.installTap(onBus: 0, bufferSize: 4096, format: natural) { buffer, _ in
                    if Self.rms(buffer) > Self.soundFloor, Date().timeIntervalSince(clock.last) > 0.2 {
                        clock.last = Date()
                        out.yield(.audio)
                    }
                    if let converted = Self.convert(buffer, with: converter, to: format) {
                        inputContinuation.yield(AnalyzerInput(buffer: converted))
                    }
                }
                engine.prepare()
                try engine.start()
                return (false, false)
            }
            if flags.cancelled { return }
            if flags.stopping {
                out.yield(.final(""))
                return
            }
            out.yield(.started(device: Self.inputDeviceName()))

            // Stored under the lock so `cancel()` can cancel it; a cancel
            // that already happened is seen here.
            let collector: Task<String, Error>? = lock.withLock {
                if cancelled { return nil }
                let task = Task { () -> String in
                    var settled = ""
                    for try await result in transcriber.results {
                        let text = String(result.text.characters)
                        if result.isFinal {
                            settled += text
                            out.yield(.partial(settled: settled, volatile: ""))
                        } else {
                            out.yield(.partial(settled: settled, volatile: text))
                        }
                    }
                    return settled
                }
                self.collector = task
                return task
            }
            guard let collector else { return }
            try await analyzer.start(inputSequence: inputs)
            let final = try await collector.value
            if lock.withLock({ cancelled }) { return }
            out.yield(.final(final.trimmingCharacters(in: .whitespacesAndNewlines)))
        } catch is CancellationError {
            return
        } catch {
            if lock.withLock({ cancelled }) { return }
            out.yield(.failed(String(describing: error)))
        }
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
        return (sum / Float(buffer.frameLength)).squareRoot()
    }

    private static func convert(
        _ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil ? output : nil
    }

    /// The default input device's name, for "Hearing nothing from …".
    private static func inputDeviceName() -> String {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr
        else { return "the microphone" }
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioObjectPropertyName
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr,
              let value = name?.takeRetainedValue() as String?
        else { return "the microphone" }
        return value
    }
}
#endif
