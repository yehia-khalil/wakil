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
    /// The file's name at that commit, and its name in the commit before when a rename lies between
    /// them: the commit's two sides for Open Changes (3a-v-a walk, step 8).
    public var path: String?
    public var parentPath: String?
    /// 3c-i: the commit is on a remote-tracking branch (`git_blame` asked with `pushed`).
    public var pushed: Bool?
    /// 3c-i: the commit's page on its host, set by `editor_blame` only for a pushed commit of a root
    /// whose `origin` is on GitHub, GitLab or Bitbucket: the hover's Open on GitHub.
    public var web: GitCommitWebPage?

    public init(line: Int, id: String, author: String, date: String, subject: String,
                path: String? = nil, parentPath: String? = nil, pushed: Bool? = nil, web: GitCommitWebPage? = nil) {
        (self.line, self.id, self.author, self.date, self.subject) = (line, id, author, date, subject)
        (self.path, self.parentPath, self.pushed, self.web) = (path, parentPath, pushed, web)
    }

    public var uncommitted: Bool { id.allSatisfy { $0 == "0" } }
}

/// A commit's page on the web (3c-i): `host` names the site for the hover's link (`GitHub`).
public struct GitCommitWebPage: Sendable, Equatable, Codable {
    public var host: String
    public var url: String

    public init(host: String, url: String) { (self.host, self.url) = (host, url) }
}

/// The hosts a commit has a web page on (3c-i). The same three `GitProvider` names for accounts
/// (`Panes/GitAccountSetup.swift`); kept here so `Git/` does not reach into `Panes/`.
public enum GitWebHost: String, Sendable, CaseIterable {
    case github = "github.com", gitlab = "gitlab.com", bitbucket = "bitbucket.org"

    public var title: String {
        switch self {
        case .github: "GitHub"
        case .gitlab: "GitLab"
        case .bitbucket: "Bitbucket"
        }
    }
}

/// The repository a git remote names on GitHub, GitLab or Bitbucket: the host and its path
/// (`owner/repo`; on GitLab a group's subgroups too). The remote may be scp-like
/// (`git@github.com:owner/repo.git`), `ssh://` or `https://`; credentials, a port, a trailing `/`
/// and `.git` are dropped. Nil for any other host or form (an ssh alias, a self-hosted GitLab,
/// a file remote): no page is offered rather than a wrong one.
public func gitRemoteWebRepository(_ remote: String) -> (host: GitWebHost, path: String)? {
    let raw = remote.trimmingCharacters(in: .whitespacesAndNewlines)
    var host: String, path: String
    if let r = raw.range(of: "://") {
        let scheme = raw[..<r.lowerBound].lowercased()
        guard scheme == "https" || scheme == "ssh", let u = URLComponents(string: raw), let h = u.host else { return nil }
        (host, path) = (h, u.path)
    } else {
        // scp-like: [user@]host:path, with no slash before the colon.
        guard let colon = raw.firstIndex(of: ":"), !raw[..<colon].contains("/") else { return nil }
        let left = raw[..<colon]
        host = String(left.split(separator: "@", omittingEmptySubsequences: false).last ?? left)
        path = String(raw[raw.index(after: colon)...])
    }
    guard let site = GitWebHost(rawValue: host.lowercased()) else { return nil }
    var parts = path.split(separator: "/").map(String.init)
    if let last = parts.last, last.lowercased().hasSuffix(".git") { parts[parts.count - 1] = String(last.dropLast(4)) }
    // Each segment as the three hosts allow a name: letters, digits, `.`, `_`, `-` — so no `?`, `#`, `%`
    // or space (a percent-decoded https path can hold them) ever reaches the page's URL.
    let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
    guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.allSatisfy(allowed.contains) }) else { return nil }
    switch site {
    // A lone `-` is GitLab's route separator (`/-/commit/`), never a group or project.
    case .gitlab: guard parts.count >= 2, !parts.contains("-") else { return nil }
    case .github, .bitbucket: guard parts.count == 2 else { return nil }
    }
    return (site, parts.joined(separator: "/"))
}

/// `commit`'s page on the host `remote` is on, or nil when it is not GitHub, GitLab or Bitbucket
/// (`gitRemoteWebRepository`) or `commit` is not a commit id.
public func gitCommitWebPage(remote: String, commit: String) -> GitCommitWebPage? {
    guard let (site, path) = gitRemoteWebRepository(remote),
          commit.count >= 7, commit.allSatisfy(\.isHexDigit), !commit.allSatisfy({ $0 == "0" }) else { return nil }
    let id = commit.lowercased()
    let url: String = switch site {
    case .github: "https://\(site.rawValue)/\(path)/commit/\(id)"
    case .gitlab: "https://\(site.rawValue)/\(path)/-/commit/\(id)"
    case .bitbucket: "https://\(site.rawValue)/\(path)/commits/\(id)"
    }
    return GitCommitWebPage(host: site.title, url: url)
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
/// against its first parent. 3a-v-b: `.conflict`, a conflicted file's current side against its incoming.
public enum EditorDiffSource: Sendable, Hashable {
    case stash(String)
    case commit(GitCommitRef)
    case conflict

    public var stashID: String? { if case .stash(let id) = self { id } else { nil } }
}

/// The commit blame's Open Changes opens: under the file's name at that commit (today's when the reply
/// names none), with the name before it across a rename.
public func editorBlameCommitRef(_ b: GitBlameInfo, currentPath: String) -> GitCommitRef {
    GitCommitRef(id: b.id, path: b.path ?? currentPath, parentPath: b.parentPath)
}

/// A commit's two sides for `git_show`: the file before it (under the name it had there) and after it.
public func editorCommitDiffRevs(_ c: GitCommitRef) -> (original: String, modified: String) {
    ("commit-parent:\(c.id)" + (c.parentPath.map { ":\($0)" } ?? ""), "commit:\(c.id)")
}

/// A conflict's two sides for `git_show` (3a-v-b): current (index stage 2) and incoming (stage 3). A
/// side git has no stage for (a delete/modify conflict) comes back absent and reads empty.
public func editorConflictDiffRevs() -> (original: String, modified: String) { ("ours", "theirs") }

/// `a.txt (Current ↔ Incoming)`: Compare Changes' tab.
public func editorConflictTabTitle(path: String) -> String {
    "\((path as NSString).lastPathComponent) (Current ↔ Incoming)"
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

/// The part of a diff tab's key that tells its source apart: `stash@<id>/`, `commit@<id>/`,
/// `conflict/`, or nothing.
public func editorDiffSourceKey(_ source: EditorDiffSource?) -> String {
    switch source {
    case .stash(let id)?: "stash@\(id)/"
    case .commit(let c)?: "commit@\(c.id)\(c.parentPath.map { ":" + $0 } ?? "")/"
    case .conflict?: "conflict/"
    case nil: ""
    }
}

/// A diff tab's source as tab params: `stash: <id>`, `commit: {id, path, parentPath?}`, or `conflict: true`.
public func editorDiffSourceParams(_ source: EditorDiffSource?) -> [String: JSONValue] {
    switch source {
    case .stash(let id)?: return ["stash": .string(id)]
    case .commit(let c)?:
        var o: [String: JSONValue] = ["id": .string(c.id), "path": .string(c.path)]
        if let p = c.parentPath { o["parentPath"] = .string(p) }
        return ["commit": .object(o)]
    case .conflict?: return ["conflict": .bool(true)]
    case nil: return [:]
    }
}

/// Reads `editorDiffSourceParams` back.
public func editorDiffSource(_ d: [String: JSONValue]) -> EditorDiffSource? {
    if case .string(let id)? = d["stash"] { return .stash(id) }
    if d["conflict"] == .bool(true) { return .conflict }
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
    /// The text each key's landed blame was fetched for, and the text a fetch in flight is for.
    private var fetchedFor: [String: String] = [:]
    private var inFlight: [String: (gen: Int, text: String)] = [:]

    public init() {}

    /// Whether `key` showing `text` needs a fetch: not when one landed for that text (until the status
    /// moves, `invalidate`) and not while one is in flight for it — a snapshot never restarts it.
    public func needsFetch(key: String, text: String) -> Bool {
        fetchedFor[key] != text && inFlight[key]?.text != text
    }

    /// Whether any blame has landed for `key`: the first fetch is not debounced.
    public func fetched(key: String) -> Bool { lines[key] != nil }

    public mutating func begin(key: String, text: String = "") -> Int {
        let g = (gens[key] ?? 0) + 1
        gens[key] = g
        inFlight[key] = (g, text)
        return g
    }

    /// The fetch `gen` was cancelled before it landed: the next snapshot may start another.
    public mutating func abandon(key: String, gen: Int) {
        if inFlight[key]?.gen == gen { inFlight[key] = nil }
    }

    @discardableResult
    public mutating func land(key: String, gen: Int, lines new: [GitBlameInfo]) -> Bool {
        guard gens[key] == gen else { return false }
        lines[key] = Dictionary(new.map { ($0.line, $0) }, uniquingKeysWith: { a, _ in a })
        fetchedFor[key] = inFlight[key]?.text
        inFlight[key] = nil
        return true
    }

    public func line(key: String, _ n: Int) -> GitBlameInfo? { lines[key]?[n] }

    /// A line of `key`'s landed blame from commit `id`: the hover's actions name only the commit.
    public func commit(key: String, id: String) -> GitBlameInfo? {
        lines[key]?.values.filter { $0.id == id }.min { $0.line < $1.line }
    }

    /// The root's status moved (a commit, a checkout): every landed blame is fetched again, and shown
    /// until the new one lands.
    public mutating func invalidate() { fetchedFor = [:] }

    /// A tab closed, or blame switched off: what it held goes.
    public mutating func forget(key: String) {
        lines[key] = nil
        fetchedFor[key] = nil
        inFlight[key] = nil
    }
}

/// What a root's blame is fetched again on when it changes: its branch, detached head, ahead count and
/// changed-file count (a commit, a checkout, a pull). The editor's landed blames and `editor_blame`'s
/// cached `origin` both follow it.
public func editorBlameRefreshMark(_ r: GitRootState) -> String {
    "\(r.root)|\(r.branch)|\(r.detached)|\(r.ahead)|\(r.files.count)"
}

/// The blame annotation's hover, as Monaco markdown: the subject, who and when, the short id, and the
/// actions (the page's `wakil.blame.open` and `wakil.blame.copy` commands, and 3c-i's
/// `wakil.blame.web` when the commit has a page on its host). Nil for a line not yet committed: there
/// is no commit to show.
public func editorBlameHover(_ b: GitBlameInfo, now: Date = Date()) -> String? {
    guard !b.uncommitted else { return nil }
    func escaped(_ s: String) -> String {
        var out = ""
        for c in s { if "\\`*_{}[]()<>#+-.!|".contains(c) { out.append("\\") }; out.append(c) }
        return out
    }
    return "**\(escaped(b.subject))**\n\n\(escaped(b.author)) · \(editorRelativeAge(b.date, now: now)) · `\(b.id.prefix(7))`"
        + "\n\n[Open Changes](command:wakil.blame.open) · [Copy Commit ID](command:wakil.blame.copy)"
        + (b.web.map { " · [Open on \(escaped($0.host)) ↗](command:wakil.blame.web)" } ?? "")
}
