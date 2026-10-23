import Foundation

/// One commit in a file's history, as `git_file_history` answers it (3a-v-a). `path` is the file's
/// name at that commit, which differs from today's after a rename.
public struct GitCommitInfo: Sendable, Equatable, Hashable, Codable, Identifiable {
    public var id: String
    public var parents: [String]
    public var author: String
    public var email: String
    public var date: String
    public var subject: String
    public var body: String
    public var path: String

    public init(id: String, parents: [String] = [], author: String, email: String = "", date: String,
                subject: String, body: String = "", path: String) {
        (self.id, self.parents, self.author, self.email, self.date, self.subject, self.body, self.path)
            = (id, parents, author, email, date, subject, body, path)
    }
}

/// Who last changed one line, as `git_blame` answers it. A line not yet committed has an all-zero id.
public struct GitBlameInfo: Sendable, Equatable, Codable {
    public var line: Int
    public var id: String
    public var author: String
    public var date: String
    public var subject: String

    public init(line: Int, id: String, author: String, date: String, subject: String) {
        (self.line, self.id, self.author, self.date, self.subject) = (line, id, author, date, subject)
    }

    public var uncommitted: Bool { id.allSatisfy { $0 == "0" } }
}

/// The commit a diff tab shows one file's change in: `path` is the file's name at that commit,
/// `parentPath` its name in the commit before when a rename lies between them.
public struct GitCommitRef: Sendable, Hashable, Codable {
    public var id: String
    public var path: String
    public var parentPath: String?

    public init(id: String, path: String, parentPath: String? = nil) {
        (self.id, self.path, self.parentPath) = (id, path, parentPath)
    }
}

/// What a non-Changes diff tab compares (3a-iv, 3a-v-a): a stash against its base, or a commit
/// against its first parent.
public enum EditorDiffSource: Sendable, Hashable {
    case stash(String)
    case commit(GitCommitRef)

    public var stashID: String? { if case .stash(let id) = self { id } else { nil } }
}

/// A commit's two sides for `git_show`: the file before it (under the name it had there) and after it.
public func editorCommitDiffRevs(_ c: GitCommitRef) -> (original: String, modified: String) {
    ("commit-parent:\(c.id)" + (c.parentPath.map { ":\($0)" } ?? ""), "commit:\(c.id)")
}

/// `a.txt (abc1234)`: the file's name at that commit and the commit's short id.
public func editorCommitTabTitle(path: String, id: String) -> String {
    "\((path as NSString).lastPathComponent) (\(id.prefix(7)))"
}

/// How long ago `iso` was, as VS Code's Timeline and blame say it.
public func editorRelativeAge(_ iso: String, now: Date = Date()) -> String {
    let f = ISO8601DateFormatter()
    guard let date = f.date(from: iso) else { return "" }
    let s = max(0, Int(now.timeIntervalSince(date)))
    func ago(_ n: Int, _ unit: String) -> String { n == 1 ? "1 \(unit) ago" : "\(n) \(unit)s ago" }
    switch s {
    case ..<60: return "just now"
    case ..<3600: return ago(s / 60, "minute")
    case ..<86_400: return ago(s / 3600, "hour")
    case ..<(14 * 86_400): return ago(s / 86_400, "day")
    case ..<(60 * 86_400): return ago(s / (7 * 86_400), "week")
    case ..<(730 * 86_400): return ago(s / (30 * 86_400), "month")
    default: return ago(s / (365 * 86_400), "year")
    }
}

/// The annotation at the end of the cursor's line: `Ada Lovelace, 3 days ago • Seed the search page`.
public func editorBlameText(_ b: GitBlameInfo, now: Date = Date()) -> String {
    b.uncommitted ? "Not committed yet" : "\(b.author), \(editorRelativeAge(b.date, now: now)) • \(b.subject)"
}

/// The part of a diff tab's key that tells its source apart: `stash@<id>/`, `commit@<id>/`, or nothing.
public func editorDiffSourceKey(_ source: EditorDiffSource?) -> String {
    switch source {
    case .stash(let id)?: "stash@\(id)/"
    case .commit(let c)?: "commit@\(c.id)/"
    case nil: ""
    }
}

/// A diff tab's source as tab params: `stash: <id>`, or `commit: {id, path, parentPath?}`.
public func editorDiffSourceParams(_ source: EditorDiffSource?) -> [String: JSONValue] {
    switch source {
    case .stash(let id)?: return ["stash": .string(id)]
    case .commit(let c)?:
        var o: [String: JSONValue] = ["id": .string(c.id), "path": .string(c.path)]
        if let p = c.parentPath { o["parentPath"] = .string(p) }
        return ["commit": .object(o)]
    case nil: return [:]
    }
}

/// Reads `editorDiffSourceParams` back.
public func editorDiffSource(_ d: [String: JSONValue]) -> EditorDiffSource? {
    if case .string(let id)? = d["stash"] { return .stash(id) }
    if case .object(let c)? = d["commit"], case .string(let id)? = c["id"], case .string(let p)? = c["path"] {
        if case .string(let pp)? = c["parentPath"] { return .commit(GitCommitRef(id: id, path: p, parentPath: pp)) }
        return .commit(GitCommitRef(id: id, path: p))
    }
    return nil
}

/// One editor pane's blame, by tab key (3a-v-a R1): fetched per tab text, read per cursor line. Each
/// fetch takes a generation; a reply that lands after a newer fetch for its tab began writes nothing.
public struct EditorBlameCache: Sendable {
    private var gens: [String: Int] = [:]
    private var lines: [String: [Int: GitBlameInfo]] = [:]

    public init() {}

    public mutating func begin(key: String) -> Int {
        let g = (gens[key] ?? 0) + 1
        gens[key] = g
        return g
    }

    @discardableResult
    public mutating func land(key: String, gen: Int, lines new: [GitBlameInfo]) -> Bool {
        guard gens[key] == gen else { return false }
        lines[key] = Dictionary(new.map { ($0.line, $0) }, uniquingKeysWith: { a, _ in a })
        return true
    }

    public func line(key: String, _ n: Int) -> GitBlameInfo? { lines[key]?[n] }

    /// A tab closed, or blame switched off: what it held goes.
    public mutating func forget(key: String) { lines[key] = nil }
}

/// The blame annotation's hover, as Monaco markdown: the subject, who and when, the short id, and the
/// two actions (the page's `wakil.blame.open` and `wakil.blame.copy` commands). Nil for a line not yet
/// committed: there is no commit to show.
public func editorBlameHover(_ b: GitBlameInfo, now: Date = Date()) -> String? {
    guard !b.uncommitted else { return nil }
    func escaped(_ s: String) -> String {
        var out = ""
        for c in s { if "\\`*_{}[]()<>#+-.!|".contains(c) { out.append("\\") }; out.append(c) }
        return out
    }
    return "**\(escaped(b.subject))**\n\n\(escaped(b.author)) · \(editorRelativeAge(b.date, now: now)) · `\(b.id.prefix(7))`"
        + "\n\n[Open Changes](command:wakil.blame.open) · [Copy Commit ID](command:wakil.blame.copy)"
}
