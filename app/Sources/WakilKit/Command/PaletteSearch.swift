import Foundation

/// Multi-word search over `PaletteEntry` rows.
///
/// Every word of the query must match the title, the subtitle or the kind,
/// in any order, so "catalog api" and "api catalog" find the same row.
public enum PaletteSearch {
    /// The words each `kindLabel` answers to, so "db" finds a table. Keyed by the labels the
    /// sources really produce: a pane row's label is its pane kind, so `db` is a key too.
    public static let aliases: [String: Set<String>] = [
        "table": ["db", "database", "table"],
        "database": ["db", "database"],
        "db": ["db", "database", "table"],
        "api": ["api"],
        "terminal": ["term", "terminal"],
        "pane": ["pane"],
        "project": ["project"],
        "session": ["session"],
        "provider": ["provider"],
        "command": ["command"],
        "ticket": ["ticket"],
        "pull request": ["pr", "pull", "request"],
    ]

    /// The query lowercased and split on spaces and tabs.
    public static func words(_ query: String) -> [String] {
        query.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    }

    /// The summed best-field score of every word, or `nil` when any word
    /// matches nothing. Higher is better; a title hit outweighs a subtitle
    /// hit, which outweighs a kind hit.
    public static func score(_ entry: PaletteEntry, words: [String]) -> Int? {
        score(entry, words: words.map(Word.init))
    }

    /// One query word, folded and split into characters once per `rank`, not once per row.
    struct Word {
        let raw: String
        let folded: String
        let letters: [Character]
        init(_ word: String) {
            raw = word
            folded = identifierFold(word)
            letters = Array(word.lowercased())
        }
    }

    /// One field of one row, folded once per row however many words ask about it. Its tokens
    /// are folded only when a word misses the whole.
    struct Field {
        let text: String
        let folded: String
        private var foldedTokens: [String]?
        private var letters: [Character]?

        init(_ text: String) {
            self.text = text
            folded = identifierFold(text)
        }

        /// A prefix of the folded whole or of one of its tokens beats a subsequence (2d-i).
        mutating func score(_ word: Word) -> Int? {
            if !word.folded.isEmpty {
                if folded.hasPrefix(word.folded) { return 1_000 + word.folded.count }
                if foldedTokens == nil {
                    foldedTokens = text.lowercased().split(whereSeparator: { " _-.·/".contains($0) })
                        .map { identifierFold(String($0)) }
                }
                if foldedTokens!.contains(where: { $0.hasPrefix(word.folded) }) { return 500 + word.folded.count }
            }
            if letters == nil { letters = Array(text.lowercased()) }
            return fuzzyScore(needle: word.letters, haystack: letters!)
        }
    }

    static func score(_ entry: PaletteEntry, words: [Word]) -> Int? {
        if words.isEmpty { return 0 }
        var kindWords = aliases[entry.kindLabel] ?? [entry.kindLabel.lowercased()]
        // An open or new pane row is labelled by its kind, and is a pane as well.
        if entry.group == .openPanes || entry.group == .newPane { kindWords.insert("pane") }
        var title = Field(entry.title)
        var subtitle: Field?
        var total = 0
        for w in words {
            let titleScore = title.score(w)
            // A title prefix (≥ 500 per word, ×100) always outweighs the best subtitle score
            // the same word could reach ((1 000 + its length) ×10), so the subtitle is not read.
            if let t = titleScore, t >= 500 {
                total += t * 100
                continue
            }
            if subtitle == nil { subtitle = Field(entry.subtitle) }
            let subtitleScore = subtitle!.score(w).map { $0 * 10 }
            let kind: Int? = kindWords.contains(w.raw) ? 1 : nil
            guard let best = [titleScore.map { $0 * 100 }, subtitleScore, kind].compactMap({ $0 }).max()
            else { return nil }
            total += best
        }
        return total
    }

    /// A prefix of the folded whole or of one of its tokens beats a
    /// subsequence (2d-i).
    static func wordScore(_ word: String, _ text: String) -> Int? {
        var field = Field(text)
        return field.score(Word(word))
    }

    /// The title's matched letters, for the view to draw bright over the dim rest: for each
    /// word that matches the title at all, the letters `wordScore` matched it by — the folded
    /// prefix of the whole title, else of one of its tokens, else the scattered letters.
    /// Sorted, and adjacent runs joined. A word that matched only the subtitle or the kind
    /// lights nothing here.
    public static func highlights(_ entry: PaletteEntry, words: [String]) -> [Range<String.Index>] {
        let title = entry.title
        var ranges: [Range<String.Index>] = []
        for word in words where wordScore(word, title) != nil {
            ranges += titleRanges(word, title)
        }
        return joined(ranges.sorted { $0.lowerBound < $1.lowerBound })
    }

    private static let separators: Set<Character> = [" ", "_", "-", ".", "·", "/"]

    private static func titleRanges(_ word: String, _ title: String) -> [Range<String.Index>] {
        let fw = identifierFold(word)
        if !fw.isEmpty {
            if identifierFold(title).hasPrefix(fw) { return foldRun(title, from: title.startIndex, count: fw.count) }
            var i = title.startIndex
            while i < title.endIndex {
                let startsToken = !separators.contains(title[i])
                    && (i == title.startIndex || separators.contains(title[title.index(before: i)]))
                if startsToken {
                    let end = title[i...].firstIndex { separators.contains($0) } ?? title.endIndex
                    if identifierFold(String(title[i..<end])).hasPrefix(fw) {
                        return foldRun(title, from: i, count: fw.count)
                    }
                }
                i = title.index(after: i)
            }
        }
        // Scattered letters, matched as `fuzzyScore` matches them: in order, first come.
        let needle = Array(word.lowercased())
        var n = 0
        var out: [Range<String.Index>] = []
        var i = title.startIndex
        while i < title.endIndex, n < needle.count {
            let next = title.index(after: i)
            if title[i].lowercased() == String(needle[n]) {
                out.append(i..<next)
                n += 1
            }
            i = next
        }
        return n == needle.count ? out : []
    }

    /// The characters from `start` whose folds add up to `count` folded letters; a character
    /// that folds to nothing (a space, `…`, `é`) is passed over, not lit.
    private static func foldRun(_ title: String, from start: String.Index, count: Int) -> [Range<String.Index>] {
        var consumed = 0
        var out: [Range<String.Index>] = []
        var i = start
        while i < title.endIndex, consumed < count {
            let next = title.index(after: i)
            let folded = identifierFold(String(title[i])).count
            if folded > 0 {
                out.append(i..<next)
                consumed += folded
            }
            i = next
        }
        return out
    }

    private static func joined(_ sorted: [Range<String.Index>]) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        for r in sorted {
            if let last = out.last, r.lowerBound <= last.upperBound {
                out[out.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
            } else {
                out.append(r)
            }
        }
        return out
    }

    /// The entries that match every word, best first; ties keep input order.
    /// An empty query returns `entries` as given. An error row stays visible
    /// while the first word is in its title, so a failing source is not
    /// silently hidden by the search that would have listed it.
    ///
    /// **Tiers before score** (`PaletteTier`): `.key` rows — a ticket named by its key or a number,
    /// and its PRs — come first, in the order given (the ticket, then its PRs), whatever they score;
    /// the source matched them. `.belowResources` rows rank among themselves by score and are placed
    /// after the last undimmed file or table, else before the first row of a group after tickets.
    public static func rank(_ entries: [PaletteEntry], query: String) -> [PaletteEntry] {
        let ws = words(query)
        if ws.isEmpty { return entries }
        let folded = ws.map(Word.init)
        let sorted = entries.enumerated()
            .compactMap { i, e -> (Int, Int, PaletteEntry)? in
                if let s = score(e, words: folded) { return (s, i, e) }
                if e.tier == .key { return (0, i, e) }
                if e.isError, e.title.lowercased().contains(ws[0]) { return (0, i, e) }
                return nil
            }
            .sorted { a, b in
                let ka = a.2.tier == .key, kb = b.2.tier == .key
                if ka || kb { return ka != kb ? ka : a.1 < b.1 }
                // Dimmed rows (gitignored files) after every undimmed match, however well they score.
                if a.2.isDimmed != b.2.isDimmed { return !a.2.isDimmed }
                return (a.0, -a.1) > (b.0, -b.1)
            }
            .map(\.2)
        let below = sorted.filter { $0.tier == .belowResources }
        guard !below.isEmpty else { return sorted }
        var rest = sorted.filter { $0.tier != .belowResources }
        let at = rest.lastIndex { $0.group == .resources && !$0.isDimmed }.map { $0 + 1 }
            ?? rest.firstIndex { $0.tier != .key && ($0.group > .tickets || $0.isDimmed) }
            ?? rest.count
        rest.insert(contentsOf: below, at: at)
        return rest
    }

    /// The entries that match every word, in the order given: `#`'s tickets keep their urgency order.
    /// An empty query returns `entries`; an error row stays as in `rank`.
    public static func filter(_ entries: [PaletteEntry], query: String) -> [PaletteEntry] {
        let ws = words(query)
        if ws.isEmpty { return entries }
        let folded = ws.map(Word.init)
        return entries.filter { e in
            score(e, words: folded) != nil || (e.isError && e.title.lowercased().contains(ws[0]))
        }
    }
}
