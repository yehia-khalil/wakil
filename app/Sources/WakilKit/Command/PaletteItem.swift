import Foundation

/// One project, session or provider as `WindowModel`'s readers list it — what ⌘P's
/// Projects, Sessions and Providers groups (`ItemsSource`) and the Landing's Continue column
/// are built from. The palette itself draws `PaletteEntry`; this is the readers' shape.
/// `payload` is the one string the row needs — a project name, a session id, a provider id.
///
/// **A provider is a ⌘P row, not a ⌘K command** (Phase 2b-vi Task 12): it is a thing the
/// operator switches TO, as a project and a session are, and its only argument is the id
/// already on the row. `.action` and `.pane` are the old sheets' kinds and no reader makes
/// them now.
public struct PaletteItem: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Equatable {
        case action, pane, project, session, provider
    }

    public let id: String
    public let kind: Kind
    public let title: String
    public let subtitle: String
    public let payload: String
    public let caution: Bool

    public init(id: String, kind: Kind, title: String, subtitle: String, payload: String, caution: Bool = false) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.payload = payload
        self.caution = caution
    }
}

/// How well `query` matches `candidate`, or `nil` if it does not match at
/// all. Higher is better.
///
/// A subsequence matcher: every character of `query` must appear in
/// `candidate`, in order, but not necessarily adjacently — so `pm` finds
/// `pane_move`. Written by hand rather than pulled in, because it is
/// twenty lines and a dependency here would be the only one in the
/// package.
///
/// Scoring rewards the two things that make a fuzzy match feel right:
///
/// - **Word boundaries.** A character matched at the start of the string
///   or just after `_`, `-`, `.` or a space is worth much more than one
///   matched mid-word. This is what makes `pm` rank `pane_move` above
///   `compamy`.
/// - **Adjacency.** Consecutive matched characters are worth more than
///   scattered ones, so an exact prefix beats a match spread across the
///   whole string.
///
/// An empty query matches everything with the same score, so an untyped
/// palette shows its source list in its own order rather than a shuffled
/// one.
public func fuzzyScore(_ query: String, against candidate: String) -> Int? {
    fuzzyScore(needle: Array(query.lowercased()), haystack: Array(candidate.lowercased()))
}

/// `fuzzyScore` over text already lowercased and split into characters, so a caller scoring
/// one word against many rows (`PaletteSearch.rank`) does that once per word and row.
func fuzzyScore(needle: [Character], haystack: [Character]) -> Int? {
    guard !needle.isEmpty else { return 0 }

    var score = 0
    var needleIndex = 0
    var previousMatch: Int?

    for (index, character) in haystack.enumerated() {
        guard needleIndex < needle.count, character == needle[needleIndex] else { continue }

        var points = 1
        let isBoundary = index == 0 || "_-. ".contains(haystack[index - 1])
        if isBoundary { points += 8 }
        if let previous = previousMatch, previous == index - 1 { points += 4 }

        score += points
        previousMatch = index
        needleIndex += 1
    }

    return needleIndex == needle.count ? score : nil
}
