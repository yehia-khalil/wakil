import Foundation

/// One phrase in a turn that folds to names Wakil knows.
public struct Resolution: Sendable, Equatable {
    /// The words as the operator wrote them, punctuation stripped.
    public let phrase: String
    /// At most `IdentifierResolver.maxCandidates`, best first.
    public let candidates: [Identifier]
    /// How many further candidates were cut.
    public let more: Int

    public init(phrase: String, candidates: [Identifier], more: Int) {
        self.phrase = phrase
        self.candidates = candidates
        self.more = more
    }
}

/// The fold matcher `2d-stt-probe.md` §10 measured. Pure: no I/O, no
/// state. **No near matching** — it failed the fresh recording.
public enum IdentifierResolver {
    public static let maxRunWords = 6
    public static let maxCandidates = 3
    public static let maxResolutions = 8

    public static func resolve(_ text: String, in vocabulary: Vocabulary) -> [Resolution] {
        let words = text.split(whereSeparator: \.isWhitespace).map(stripPunctuation).filter { !$0.isEmpty }
        guard !words.isEmpty, vocabulary.count > 0 else { return [] }
        var used = [Bool](repeating: false, count: words.count)
        var found: [(start: Int, resolution: Resolution)] = []
        for length in stride(from: min(maxRunWords, words.count), through: 1, by: -1) {
            for start in 0...(words.count - length) where !used[start..<(start + length)].contains(true) {
                let phrase = words[start..<(start + length)].joined(separator: " ")
                let names = vocabulary.names(folded: identifierFold(phrase))
                guard !names.isEmpty else { continue }
                for i in start..<(start + length) { used[i] = true }
                // Already says it: the operator wrote the name, nothing to resolve.
                // The name's edges are stripped like the typed words', so
                // `/v1/orders` or `_private` typed exactly is not offered back.
                if names.contains(where: { stripPunctuation($0.text).lowercased() == phrase.lowercased() }) { continue }
                let ranked = names.sorted(by: rankedBefore)
                found.append((start, Resolution(
                    phrase: phrase,
                    candidates: Array(ranked.prefix(maxCandidates)),
                    more: max(0, ranked.count - maxCandidates))))
            }
        }
        // Over the cap, the turn is probably pasted output: no note at all.
        guard found.count <= maxResolutions else { return [] }
        return found.sorted { $0.start < $1.start }.map(\.resolution)
    }

    /// Leading and trailing punctuation off; inner dots and the rest stay.
    static func stripPunctuation<S: StringProtocol>(_ word: S) -> String {
        let edge = CharacterSet.punctuationCharacters.union(.symbols)
        return String(word).trimmingCharacters(in: edge)
    }

    static func rankedBefore(_ a: Identifier, _ b: Identifier) -> Bool {
        if a.source != b.source { return a.source < b.source }
        if a.origin.count != b.origin.count { return a.origin.count < b.origin.count }
        return a.text < b.text
    }
}
