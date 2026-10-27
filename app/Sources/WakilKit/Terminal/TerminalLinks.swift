import Foundation

/// One link in a terminal line: where it sits, in `Character` offsets into the line, and the URL it
/// opens.
public struct TerminalLink: Sendable, Equatable {
    public let range: Range<Int>
    public let url: URL

    public init(range: Range<Int>, url: URL) {
        self.range = range
        self.url = url
    }
}

/// Which text in a terminal line is a link (3c-iii ruling 14), and a row's style runs cut at a
/// link's edges so the view draws the link in its run's own style.
///
/// **Only text that itself starts with `http://` or `https://` is a link.** `NSDataDetector` alone
/// would link `example.com` and `main.go`-shaped names, and a terminal is full of file names; the
/// scheme the program printed is what makes it a web address. Where the URL ends (a trailing `.`,
/// a closing `)`) is the detector's call.
public enum TerminalLinks {
    /// Built once: every visible row of every terminal pane asks on every draw.
    private static let detector =
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    public static func find(in line: String) -> [TerminalLink] {
        matches(in: line).compactMap { match in
            guard let range = Range(NSRange(match.utf16), in: line) else { return nil }
            let start = line.distance(from: line.startIndex, to: range.lowerBound)
            return TerminalLink(range: start..<(start + line[range].count), url: match.url)
        }
    }

    /// `runs` with every run cut where a link starts or ends, each piece paired with the URL it
    /// belongs to (`nil` outside a link). A link that spans two runs gives a linked piece of each,
    /// keeping each run's own style. Empty pieces are dropped; a row with no link comes back as its
    /// own runs.
    ///
    /// **Counted in UTF-16 units, not Characters.** A style change can fall inside one Character
    /// (a base and its combining mark, the two halves of a flag, a ZWJ sequence), so a row's
    /// Characters are not the sum of its runs' Characters, and cuts counted run by run would drift
    /// from links found in the joined row. UTF-16 units add up across runs, and they are the unit
    /// the detector reports in.
    public static func split(_ runs: [TerminalStyleRun]) -> [(run: TerminalStyleRun, link: URL?)] {
        let links = matches(in: runs.map(\.text).joined())
        guard !links.isEmpty else { return runs.map { ($0, nil) } }
        var pieces: [(run: TerminalStyleRun, link: URL?)] = []
        var offset = 0
        for run in runs {
            let runRange = offset..<(offset + run.text.utf16.count)
            // The run's own cut points: its edges plus every link edge inside it.
            var cuts = [runRange.lowerBound, runRange.upperBound]
            for link in links {
                for edge in [link.utf16.lowerBound, link.utf16.upperBound]
                where edge > runRange.lowerBound && edge < runRange.upperBound {
                    cuts.append(edge)
                }
            }
            cuts = Array(Set(cuts)).sorted()
            for (start, end) in zip(cuts, cuts.dropFirst()) where end > start {
                let from = String.Index(utf16Offset: start - offset, in: run.text)
                let to = String.Index(utf16Offset: end - offset, in: run.text)
                let text = String(String.UnicodeScalarView(run.text.unicodeScalars[from..<to]))
                let link = links.first { $0.utf16.contains(start) }?.url
                pieces.append((TerminalStyleRun(text: text, style: run.style), link))
            }
            offset = runRange.upperBound
        }
        return pieces
    }

    /// Every http(s) link in `line`, in UTF-16 offsets — the unit both `find` and `split` start
    /// from, so the two can never disagree about where a link is.
    private static func matches(in line: String) -> [(utf16: Range<Int>, url: URL)] {
        // Most rows hold no URL at all; skip the detector for them.
        guard line.range(of: "http", options: .caseInsensitive) != nil, let detector else { return [] }
        let whole = NSRange(line.startIndex..<line.endIndex, in: line)
        return detector.matches(in: line, options: [], range: whole).compactMap { match in
            guard let range = Range(match.range, in: line) else { return nil }
            let text = line[range]
            let lowered = text.lowercased()
            guard lowered.hasPrefix("http://") || lowered.hasPrefix("https://"),
                  let url = URL(string: String(text)) ?? match.url,
                  let utf16 = Range(match.range)
            else { return nil }
            return (utf16, url)
        }
    }
}
