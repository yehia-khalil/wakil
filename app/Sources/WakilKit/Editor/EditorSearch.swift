import Foundation

/// One hit of a project search. `column` is 1-based UTF-16.
public struct EditorSearchMatch: Sendable, Equatable {
    public var root: String
    public var path: String
    public var line: Int
    public var column: Int
    public var preview: String
    public init(root: String, path: String, line: Int, column: Int, preview: String) {
        self.root = root
        self.path = path
        self.line = line
        self.column = column
        self.preview = preview
    }
}

public struct EditorSearchState: Sendable, Equatable {
    public var query: String
    public var caseSensitive: Bool
    public var wholeWord: Bool
    public var regex: Bool
    public var inFlight: Bool
    /// Bumps per search started or cancelled; a reply for an older serial is dropped.
    public var serial: Int
    /// The 2,000-match cap: only the first 2,000 matches are shown.
    public var truncated: Bool
    /// Some root's listing hit the 50,000-file cap: only the first 50,000 files are searched.
    public var filesTruncated: Bool
    /// The files over 2 MB the last search skipped, root-relative (3b-vii).
    public var skippedLarge: [String] = []
    public var changedSince: Bool
    /// The operator or the agent stopped the last search before it finished: the column says so, so a
    /// stopped search never looks like one that found nothing. The next search, or an empty query, clears it.
    public var cancelled: Bool
    public var error: String?
    public var results: [EditorSearchMatch]
    /// The Replace field, its preview, the run in flight and the latest replace (3b-ii-b).
    public var replace: EditorReplaceState

    public static let truncatedNote = "only the first 2,000 matches are shown"
    public static let filesTruncatedNote = "only the first 50,000 files are searched"

    public init(query: String, caseSensitive: Bool, wholeWord: Bool, regex: Bool, inFlight: Bool, serial: Int,
                truncated: Bool, filesTruncated: Bool = false, changedSince: Bool, cancelled: Bool = false,
                error: String?, results: [EditorSearchMatch], replace: EditorReplaceState = .closed) {
        self.query = query
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
        self.regex = regex
        self.inFlight = inFlight
        self.serial = serial
        self.truncated = truncated
        self.filesTruncated = filesTruncated
        self.changedSince = changedSince
        self.cancelled = cancelled
        self.error = error
        self.results = results
        self.replace = replace
    }

    public static let empty = EditorSearchState(query: "", caseSensitive: false, wholeWord: false, regex: false,
                                                inFlight: false, serial: 0, truncated: false, changedSince: false,
                                                error: nil, results: [])
}

public struct EditorSearchFile: Sendable, Equatable {
    public var path: String
    public var matches: [EditorSearchMatch]
    public init(path: String, matches: [EditorSearchMatch]) {
        self.path = path
        self.matches = matches
    }
}

public struct EditorSearchGroup: Sendable, Equatable {
    public var root: String
    public var files: [EditorSearchFile]
    public init(root: String, files: [EditorSearchFile]) {
        self.root = root
        self.files = files
    }
}

public func editorSearchGroups(_ results: [EditorSearchMatch]) -> [EditorSearchGroup] {
    var groups: [EditorSearchGroup] = []
    for r in results {
        if groups.last?.root != r.root { groups.append(EditorSearchGroup(root: r.root, files: [])) }
        var g = groups.removeLast()
        if g.files.last?.path != r.path { g.files.append(EditorSearchFile(path: r.path, matches: [])) }
        g.files[g.files.count - 1].matches.append(r)
        groups.append(g)
    }
    return groups
}

/// Where a result line marks its match: every match of the search's query and switches in `preview`,
/// as 0-based UTF-16 offsets — `editorFindMatches` (the matcher `editor_find` uses) over the one line.
/// A pattern that does not compile marks nothing; the search's own error says why.
public func editorSearchMarks(preview: String, search: EditorSearchState) -> [Range<Int>] {
    guard let ranges = try? editorFindMatches(preview, query: search.query, caseSensitive: search.caseSensitive,
                                              wholeWord: search.wholeWord, regex: search.regex) else { return [] }
    // A preview is one line; a match running past it (a regex over "\n") is not one to mark.
    return ranges.compactMap { r in
        r.start.line == 1 && r.end.line == 1 ? (r.start.column - 1)..<(r.end.column - 1) : nil
    }
}

/// The find the agent asked for; the renderer opens Monaco's bar once per `serial`.
public struct EditorFindRequest: Sendable, Equatable {
    public var query: String
    public var caseSensitive: Bool
    public var wholeWord: Bool
    public var regex: Bool
    public var serial: Int
    public init(query: String, caseSensitive: Bool, wholeWord: Bool, regex: Bool, serial: Int) {
        self.query = query
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
        self.regex = regex
        self.serial = serial
    }
}

/// What Monaco's find bar last said.
public struct EditorFindReport: Sendable, Equatable {
    public var query: String
    public var caseSensitive: Bool
    public var wholeWord: Bool
    public var regex: Bool
    public var count: Int
    public var shown: Bool
    public init(query: String, caseSensitive: Bool, wholeWord: Bool, regex: Bool, count: Int, shown: Bool) {
        self.query = query
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
        self.regex = regex
        self.count = count
        self.shown = shown
    }
}

public struct EditorFindError: Error, Sendable, Equatable, CustomStringConvertible {
    public let description: String
    public init(description: String) { self.description = description }
}

/// Every match of `query` in `text`, as Monaco would mark them: 1-based lines, UTF-16 columns
/// (NSString ranges are UTF-16). Literal unless `regex`; an invalid pattern throws its message whole.
public func editorFindMatches(_ text: String, query: String, caseSensitive: Bool, wholeWord: Bool,
                              regex: Bool) throws -> [EditorRange] {
    guard !query.isEmpty else { return [] }
    var pattern = regex ? query : NSRegularExpression.escapedPattern(for: query)
    if wholeWord { pattern = "\\b(?:\(pattern))\\b" }
    let re: NSRegularExpression
    do {
        re = try NSRegularExpression(pattern: pattern, options: caseSensitive ? [] : [.caseInsensitive])
    } catch {
        throw EditorFindError(description: "find: \(query) is not a valid regular expression (\(error.localizedDescription))")
    }
    let ns = text as NSString
    var lineStarts = [0]
    for i in 0..<ns.length where ns.character(at: i) == 10 { lineStarts.append(i + 1) }
    func position(_ offset: Int) -> EditorPosition {
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi { let mid = (lo + hi + 1) / 2; if lineStarts[mid] <= offset { lo = mid } else { hi = mid - 1 } }
        return EditorPosition(line: lo + 1, column: offset - lineStarts[lo] + 1)
    }
    return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
        guard m.range.length > 0 else { return nil }
        return EditorRange(start: position(m.range.location), end: position(m.range.location + m.range.length))
    }
}

@MainActor public final class EditorDebounce {
    private let delay: Duration
    private var task: Task<Void, Never>?
    public init(delay: Duration) { self.delay = delay }
    public func schedule(_ body: @escaping @MainActor () async -> Void) {
        task?.cancel()
        let delay = delay
        task = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await body()
        }
    }
    public func cancel() { task?.cancel(); task = nil }
}

/// The line under the results naming the files over 2 MB search skipped (3b-vii); nil when none.
public func editorSkippedLargeNote(_ paths: [String]) -> String? {
    guard !paths.isEmpty else { return nil }
    let head = paths.prefix(3).joined(separator: ", ")
    let more = paths.count > 3 ? ", …and \(paths.count - 3) more" : ""
    return "\(paths.count) file\(paths.count == 1 ? "" : "s") over 2 MB not searched: \(head)\(more)"
}
