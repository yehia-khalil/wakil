import Foundation

/// The hint 2d-i hands the agent under the operator's unchanged text, and
/// the one-line `RESOLVED` row the thought thread shows for it. Plain
/// text, so any harness can read it (Invariant 1).
public enum TurnNote {
    public static let header =
        "[Wakil: identifiers in scope that match words in this turn — a hint, not a correction]"

    public static func render(_ resolutions: [Resolution]) -> String? {
        guard !resolutions.isEmpty else { return nil }
        let lines = resolutions.map { r -> String in
            let names = r.candidates.map { "\($0.text) (\($0.kind.rawValue) · \($0.origin))" }
                .joined(separator: ", ")
            return "- \"\(r.phrase)\" → \(names)" + (r.more > 0 ? " and \(r.more) more" : "")
        }
        return ([header] + lines).joined(separator: "\n")
    }

    public static func row(_ resolutions: [Resolution]) -> String {
        resolutions.compactMap { r in r.candidates.first.map { "\(r.phrase) → \($0.text)" } }
            .joined(separator: " · ")
    }

    /// For a rebuilt thread: the transcript holds what was sent, which is
    /// the typed text plus the note. Returns the typed text and the row.
    public static func split(_ sent: String) -> (typed: String, row: String?) {
        guard let range = sent.range(of: "\n\n" + header + "\n") else { return (sent, nil) }
        let typed = String(sent[..<range.lowerBound])
        let pairs = sent[range.upperBound...].split(separator: "\n").compactMap { line -> String? in
            // - "phrase" → text (kind · origin)…
            guard line.hasPrefix("- \""), let close = line.range(of: "\" → ") else { return nil }
            let phrase = line[line.index(line.startIndex, offsetBy: 3)..<close.lowerBound]
            let afterArrow = line[close.upperBound...]
            // Find the candidate text: everything up to the first " ("
            guard let metaStart = afterArrow.range(of: " (") else { return nil }
            let first = String(afterArrow[..<metaStart.lowerBound])
            return "\(phrase) → \(first)"
        }
        return (typed, pairs.isEmpty ? nil : pairs.joined(separator: " · "))
    }

    /// For a session title: the typed text of a first prompt, which
    /// `session_list` cuts to 200 runes plus "…". A cut that lands before
    /// the header's own line break leaves no whole header for `split` to
    /// find, so a tail that is a prefix of the note's opening is dropped
    /// too. Only a cut text — one ending in "…" — is treated this way.
    public static func title(_ firstPrompt: String) -> String {
        let typed = split(firstPrompt).typed
        guard typed.hasSuffix("…") else { return typed }
        let cut = typed.dropLast()
        let opening = "\n\n" + header + "\n"
        for length in stride(from: min(cut.count, opening.count), through: 1, by: -1)
        where cut.hasSuffix(opening.prefix(length)) {
            return String(cut.dropLast(length))
        }
        return typed
    }
}
