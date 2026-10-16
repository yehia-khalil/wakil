// sttspike — the harness for docs/wakil/2d-stt-probe.md.
//
// Throwaway, outside the repo, per this project's probe convention. Feeds the
// SAME audio files through both engines so engine accuracy is never confounded
// with how clearly a given take was spoken.
//
//   sttspike <dir-of-wavs>            both engines
//   sttspike <dir-of-wavs> apple      Apple only
//   sttspike <dir-of-wavs> whisper    WhisperKit only
//
// Prints one line per (engine, file). Scoring is by hand against §3's table —
// deliberately, because §4's rules (a split identifier counts as a miss) need a
// human reading the transcript, not a string comparison that would hide it.

import AVFoundation
import Foundation
import Speech
import WhisperKit

// The identifier list, verbatim from the probe's §3. Fed to WhisperKit as
// prompt conditioning — the feature SpeechAnalyzer dropped and the entire
// reason Whisper is still a candidate.
let wakilVocabulary = """
Wakil vocabulary: writeRef, wakilcore, AssertSQLMutation, edit_quote, edit_bit, \
transaction_read_only, hardenMySQLWriteConfig, describeEditability, ctx_adopt_provider, \
JSONValue, writeGate, WakilWindow.swift, paths.go, internal/wakilcore, \
phase-2c-ii-acceptance.md, acc-staging-core-write, wakil-acceptance-2, wakilacc, \
wakil-pm, make app-test, INI-2835, 2c-ii-b, 2b-viii, Invariant 6, Umbrella.
"""

// The same identifiers as `wakilVocabulary`, as a list rather than a sentence —
// which is the shape AnalysisContext.contextualStrings wants.
let wakilIdentifiers: [String] = [
    "writeRef", "wakilcore", "AssertSQLMutation", "edit_quote", "edit_bit",
    "transaction_read_only", "hardenMySQLWriteConfig", "describeEditability",
    "ctx_adopt_provider", "JSONValue", "writeGate", "WakilWindow.swift", "paths.go",
    "internal/wakilcore", "phase-2c-ii-acceptance.md", "acc-staging-core-write",
    "wakil-acceptance-2", "wakilacc", "wakil-pm", "make app-test", "INI-2835",
    "2c-ii-b", "2b-viii", "Invariant 6", "Umbrella", "staging", "core", "production",
    "events",
]

func wavFiles(in dir: String) -> [URL] {
    let url = URL(fileURLWithPath: dir)
    let all = (try? FileManager.default.contentsOfDirectory(at: url,
                                                            includingPropertiesForKeys: nil)) ?? []
    return all.filter { ["wav", "m4a", "caf", "aiff"].contains($0.pathExtension.lowercased()) }
              .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

// MARK: - Apple: SpeechAnalyzer + SpeechTranscriber (macOS 26)

func transcribeApple(_ url: URL) async throws -> String {
    let locale = Locale(identifier: "en-US")
    let transcriber = SpeechTranscriber(locale: locale,
                                        transcriptionOptions: [],
                                        reportingOptions: [],
                                        attributeOptions: [])

    // The model is downloaded on first use, not bundled. A probe that silently
    // ran an unavailable locale would score Apple at zero for the wrong reason.
    if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
        try await request.downloadAndInstall()
    }

    let analyzer = SpeechAnalyzer(modules: [transcriber])

    // SpeechAnalyzer DOES have contextual biasing: AnalysisContext.contextualStrings.
    // The 2026 benchmark write-ups saying macOS 26 "dropped custom vocabulary" are
    // wrong about this API — the symbol is in the macOS 27.0 SDK's
    // Speech.swiftinterface, and SpeechAnalyzer.setContext(_:) attaches it.
    if ProcessInfo.processInfo.environment["STTSPIKE_NO_CONTEXT"] == nil {
        let ctx = AnalysisContext()
        ctx.contextualStrings[.general] = wakilIdentifiers
        try await analyzer.setContext(ctx)
        let back = await analyzer.context.contextualStrings[.general] ?? []
        FileHandle.standardError.write(
            "  [context: set \(wakilIdentifiers.count), read back \(back.count)]\n".data(using: .utf8)!)
    }

    let file = try AVAudioFile(forReading: url)

    // The collector returns its String rather than mutating a captured var:
    // under Swift 6 strict concurrency the captured-var form is a data race.
    let collector = Task { () -> String in
        var text = ""
        for try await result in transcriber.results {
            text += String(result.text.characters)
        }
        return text
    }
    if let last = try await analyzer.analyzeSequence(from: file) {
        try await analyzer.finalizeAndFinish(through: last)
    } else {
        try await analyzer.finalizeAndFinishThroughEndOfInput()
    }
    let text = (try? await collector.value) ?? ""
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - WhisperKit, large-v3-turbo, with prompt conditioning
//
// NOTE the model name. WhisperKit's Core ML repo calls OpenAI's large-v3-turbo
// "openai_whisper-large-v3-v20240930" (its release date). "large-v3-turbo" does
// not resolve, and "openai_whisper-large-v3_turbo" is a DIFFERENT thing — plain
// large-v3 with a turbo compute-unit config. Getting this wrong measures the
// wrong model and the error message does not say so.

func makeWhisper() async throws -> WhisperKit {
    try await WhisperKit(WhisperKitConfig(model: "openai_whisper-large-v3-v20240930", download: true))
}

func transcribeWhisper(_ pipe: WhisperKit, _ url: URL) async throws -> String {
    var options = DecodingOptions(
        language: "en",
        temperature: 0,
        temperatureFallbackCount: 3,
        usePrefillPrompt: ProcessInfo.processInfo.environment["STTSPIKE_NO_PREFILL"] == nil,
        withoutTimestamps: ProcessInfo.processInfo.environment["STTSPIKE_NO_TS"] != nil,
        compressionRatioThreshold: nil,
        logProbThreshold: nil,
        noSpeechThreshold: nil)
    // Prompt conditioning is the ONLY reason Whisper is still a candidate —
    // SpeechAnalyzer dropped custom vocabulary. Tokenized exactly as
    // WhisperKit's own CLI does it, special tokens filtered out.
    if !ProcessInfo.processInfo.environment.keys.contains("STTSPIKE_NO_PROMPT"),
       let tok = pipe.tokenizer {
        let promptText = ProcessInfo.processInfo.environment["STTSPIKE_PROMPT"] ?? wakilVocabulary
        let all = tok
            .encode(text: " " + promptText.trimmingCharacters(in: .whitespaces))
            .filter { $0 < tok.specialTokens.specialTokenBegin }
        FileHandle.standardError.write("  [prompt: \(all.count) tokens]\n".data(using: .utf8)!)
        options.promptTokens = all
    }
    let results: [TranscriptionResult] =
        try await pipe.transcribe(audioPath: url.path, decodeOptions: options)
    return results.map(\.text).joined(separator: " ")
                  .trimmingCharacters(in: .whitespacesAndNewlines)
}


// MARK: - Record mode
//
// Built in rather than shelling out: this machine has no ffmpeg, sox or rec,
// and the filenames have to line up with the probe's §3 numbering or the
// scoring table cannot be read against the transcripts.

let builtInUtterances: [String] = [
    "Open the DB pane on staging core",
    "Show me edit_quote on the core database",
    "What's the writeRef on this database?",
    "Does wakilcore export AssertSQLMutation?",
    "Move INI-2835 to review",
    "Read the acceptance runbook for 2c-ii-b",
    "What did 2b-viii's walk find?",
    "Switch the org to Umbrella",
    "Set transaction_read_only to one",
    "Grep for hardenMySQLWriteConfig",
    "Open WakilWindow.swift",
    "Run make app-test",
    "What's in phase-2c-ii-acceptance.md?",
    "Show the JSONValue integer case",
    "Which provider is wakil-pm running under?",
    "Start a session on the wakil-acceptance-2 project",
    "Delete from edit_bit where id equals three",
    "Is ctx_adopt_provider operator-only?",
    "Check Invariant 6 in the charter",
    "What's the writeGate doing on production?",
    "Open paths.go in internal/wakilcore",
    "Show me acc-staging-core-write",
    "Does describeEditability return early?",
    "List the databases on wakilacc",
    "Re-run the query on the events pane",
]

/// `record <out-dir> <utterances.tsv>` reads a later set: the first tab-separated
/// field of each non-comment line. Without it, §3's set.
nonisolated(unsafe) let utterances: [String] = {
    let a = CommandLine.arguments
    guard a.count >= 4, a[1] == "record" else { return builtInUtterances }
    guard let text = try? String(contentsOfFile: a[3], encoding: .utf8) else {
        FileHandle.standardError.write("cannot read \(a[3])\n".data(using: .utf8)!); exit(2)
    }
    return text.split(separator: "\n").filter { !$0.hasPrefix("#") && !$0.isEmpty }
        .map { String($0.split(separator: "\t", maxSplits: 1)[0]) }
}()

final class Recorder: NSObject {
    private var recorder: AVAudioRecorder?

    // 16 kHz mono PCM — what both engines resample to anyway. Recording it
    // directly means neither engine is measured through a conversion the
    // other did not get.
    private let settings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatLinearPCM),
        AVSampleRateKey: 16000.0,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
    ]

    func start(_ url: URL) throws {
        let r = try AVAudioRecorder(url: url, settings: settings)
        r.record()
        recorder = r
    }

    func stop() {
        recorder?.stop()
        recorder = nil
    }
}

func runRecord(into dir: String) {
    let outDir = URL(fileURLWithPath: dir)
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

    print("""
    Recording \(utterances.count) utterances into \(outDir.path)

    For each one: press Enter to START, speak it, press Enter to STOP.
    Type "r" then Enter at the START prompt to re-record the previous one.
    Type "q" then Enter to stop early — files already written are kept.

    Speak at a normal working pace, in a normal working room. Do not
    enunciate for the microphone; the point is what Wakil will receive.

    """)

    let rec = Recorder()
    var i = 0
    while i < utterances.count {
        let n = String(format: "%02d", i + 1)
        let url = outDir.appendingPathComponent("\(n).wav")
        print("[\(i + 1)/\(utterances.count)]  \(utterances[i])")
        print("  Enter to start > ", terminator: "")
        let cmd = (readLine() ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if cmd == "q" { print("stopped early"); return }
        if cmd == "r" { i = max(0, i - 1); continue }

        do { try rec.start(url) } catch {
            print("  could not start recording: \(error)")
            print("  If this is a permissions error, grant your terminal Microphone access")
            print("  in System Settings > Privacy & Security > Microphone, then re-run.")
            return
        }
        print("  RECORDING — Enter to stop > ", terminator: "")
        _ = readLine()
        rec.stop()

        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        print("  wrote \(n).wav (\((size ?? 0) / 1024) KB)\n")
        i += 1
    }
    print("done — \(utterances.count) files in \(outDir.path)")
}

// MARK: - Run

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: sttspike record <out-dir> [utterances.tsv]   |   sttspike <dir-of-wavs> [apple|whisper]\n".data(using: .utf8)!)
    exit(2)
}
if args[1] == "record" {
    guard args.count >= 3 else {
        FileHandle.standardError.write("usage: sttspike record <out-dir>\n".data(using: .utf8)!)
        exit(2)
    }
    runRecord(into: args[2])
    exit(0)
}

let which = args.count >= 3 ? args[2] : "both"
let files = wavFiles(in: args[1])
guard !files.isEmpty else {
    FileHandle.standardError.write("no audio files in \(args[1])\n".data(using: .utf8)!)
    exit(2)
}
print("# \(files.count) file(s), engine: \(which)\n")

if which == "both" || which == "apple" {
    print("## Apple — SpeechAnalyzer / SpeechTranscriber")
    for f in files {
        let start = Date()
        do {
            let text = try await transcribeApple(f)
            print(String(format: "%@\t%.2fs\t%@", f.lastPathComponent, -start.timeIntervalSinceNow, text))
        } catch {
            print("\(f.lastPathComponent)\tERROR\t\(error)")
        }
    }
    print("")
}

if which == "both" || which == "whisper" {
    print("## WhisperKit — large-v3-turbo, prompt-conditioned")
    do {
        var shared = try await makeWhisper()
        for f in files {
            let start = Date()
            do {
                // A FRESH pipeline per file. WhisperKit 0.18.0 transcribes only
                // the FIRST file correctly when promptTokens is set and returns
                // empty for every file after it — see TextDecoder.swift's own
                // note that prefill "breaks if it starts at non-zero index".
                // Reusing one instance would have scored Whisper at 1/25.
                if ProcessInfo.processInfo.environment["STTSPIKE_REUSE"] == nil {
                    shared = try await makeWhisper()
                }
                let text = try await transcribeWhisper(shared, f)
                print(String(format: "%@\t%.2fs\t%@", f.lastPathComponent, -start.timeIntervalSinceNow, text))
            } catch {
                print("\(f.lastPathComponent)\tERROR\t\(error)")
            }
        }
    } catch {
        print("WhisperKit init failed: \(error)")
    }
}
