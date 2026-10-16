import Foundation
import Testing
@testable import WakilKit

/// `scripts/probe/` holds both recordings from `2d-stt-probe.md` §10.
private let probeDirectory = URL(fileURLWithPath: #filePath)   // app/Tests/WakilKitTests/IdentifierCorpusTests.swift
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("scripts/probe")

private func lines(_ relative: String) throws -> [String] {
    try String(contentsOf: probeDirectory.appendingPathComponent(relative), encoding: .utf8)
        .split(separator: "\n").map(String.init)
}

/// `sttspike` output: `NN.wav\tseconds\ttranscript` lines under `## Apple`.
private func transcripts(_ relative: String) throws -> [String] {
    try lines(relative).filter { $0.split(separator: "\t").count == 3 }
        .map { String($0.split(separator: "\t")[2]) }
}

private let snapshot: Vocabulary = {
    let texts = (try? lines("stt-set2/vocab-snapshot-2026-10-06.txt")) ?? []
    return Vocabulary(texts.map { Identifier(text: $0, kind: .code, origin: "snapshot", source: .code) })
}()

/// §4's exact rule: case-sensitive, not inside a longer identifier.
private func exact(_ ident: String, in text: String) -> Bool {
    let pattern = "(?<![\\w.-])" + NSRegularExpression.escapedPattern(for: ident) + "(?![\\w-])"
    return text.range(of: pattern, options: .regularExpression) != nil
}

private func score(_ transcripts: [String], truth: [[String]]) -> (recovered: Int, wrong: Int) {
    var recovered = 0, wrong = 0
    for (text, idents) in zip(transcripts, truth) {
        let resolutions = IdentifierResolver.resolve(text, in: snapshot)
        let suggested = Set(resolutions.flatMap { $0.candidates.map(\.text) })
        recovered += idents.filter { !exact($0, in: text) && suggested.contains($0) }.count
        wrong += resolutions.filter { r in !r.candidates.contains { idents.contains($0.text) } }.count
    }
    return (recovered, wrong)
}

/// §3's identifiers, in order — `scripts/probe/stt-score.py`'s IDENT.
private let setOneTruth: [[String]] = [
    ["staging", "core"], ["edit_quote"], ["writeRef"], ["rafiqcore", "AssertSQLMutation"],
    ["INI-2835"], ["2c-ii-b"], ["2b-viii"], ["Umbrella"], ["transaction_read_only"],
    ["hardenMySQLWriteConfig"], ["RafiqWindow.swift"], ["make app-test"],
    ["phase-2c-ii-acceptance.md"], ["JSONValue"], ["rafiq-pm"], ["rafiq-acceptance-2"],
    ["edit_bit"], ["ctx_adopt_provider"], ["Invariant 6"], ["writeGate", "production"],
    ["paths.go", "internal/rafiqcore"], ["acc-staging-core-write"], ["describeEditability"],
    ["rafiqacc"], ["events"],
]

@Test func setOneRecoversAtLeastWhatTheProbeMeasured() throws {
    let transcripts = try transcripts("stt-2026-10-06-apple.tsv")
    #expect(transcripts.count == setOneTruth.count)
    let result = score(transcripts, truth: setOneTruth)
    #expect(result.recovered >= 6)   // §10: fold +6
    #expect(result.wrong <= 4)       // §10 measured 6; the resolver measures 4 here
}

@Test func setTwoRecoversAtLeastWhatTheProbeMeasured() throws {
    let truth = try lines("stt-set2/utterances.tsv").filter { !$0.hasPrefix("#") }
        .map { $0.split(separator: "\t")[1].split(separator: ",").map(String.init) }
    let transcripts = try transcripts("stt-set2/apple-2026-10-06.tsv")
    #expect(transcripts.count == truth.count)
    let result = score(transcripts, truth: truth)
    #expect(result.recovered >= 12)  // §10: fold +11; the punctuation strip adds one
    #expect(result.wrong <= 2)       // §10: 2 wrong
}
