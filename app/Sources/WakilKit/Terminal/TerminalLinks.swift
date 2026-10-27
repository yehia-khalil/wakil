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
        // Most rows hold no URL at all; skip the detector for them.
        guard line.range(of: "http", options: .caseInsensitive) != nil, let detector else { return [] }
        let whole = NSRange(line.startIndex..<line.endIndex, in: line)
        return detector.matches(in: line, options: [], range: whole).compactMap { match in
            guard let range = Range(match.range, in: line) else { return nil }
            let text = line[range]
            let lowered = text.lowercased()
            guard lowered.hasPrefix("http://") || lowered.hasPrefix("https://"),
                  let url = URL(string: String(text)) ?? match.url
            else { return nil }
            let start = line.distance(from: line.startIndex, to: range.lowerBound)
            return TerminalLink(range: start..<(start + text.count), url: url)
        }
    }

    /// `runs` with every run cut where a link starts or ends, each piece paired with the URL it
    /// belongs to (`nil` outside a link). A link that spans two runs gives a linked piece of each,
    /// keeping each run's own style. Empty pieces are dropped; a row with no link comes back as its
    /// own runs.
    public static func split(_ runs: [TerminalStyleRun]) -> [(run: TerminalStyleRun, link: URL?)] {
        let links = find(in: runs.map(\.text).joined())
        guard !links.isEmpty else { return runs.map { ($0, nil) } }
        var pieces: [(run: TerminalStyleRun, link: URL?)] = []
        var offset = 0
        for run in runs {
            let characters = Array(run.text)
            let runRange = offset..<(offset + characters.count)
            // The run's own cut points: its edges plus every link edge inside it.
            var cuts = [runRange.lowerBound, runRange.upperBound]
            for link in links {
                for edge in [link.range.lowerBound, link.range.upperBound]
                where edge > runRange.lowerBound && edge < runRange.upperBound {
                    cuts.append(edge)
                }
            }
            cuts = Array(Set(cuts)).sorted()
            for (start, end) in zip(cuts, cuts.dropFirst()) where end > start {
                let text = String(characters[(start - offset)..<(end - offset)])
                let link = links.first { $0.range.contains(start) }?.url
                pieces.append((TerminalStyleRun(text: text, style: run.style), link))
            }
            offset = runRange.upperBound
        }
        return pieces
    }
}
