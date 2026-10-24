import Foundation

/// Which list a changed file sits in: what is unmerged (3a-v-b, drawn first), what is staged, what is
/// changed in the working tree, or what git does not track yet. Case order is draw order.
public enum GitGroup: String, Sendable, Codable, CaseIterable { case conflicts, staged, changed, untracked }

/// One file in one group of one root's status.
public struct GitFileRow: Sendable, Equatable, Hashable {
    public var path: String
    public var origPath: String?
    public var group: GitGroup
    public var status: String
    /// 3a-v-b: a conflict's XY (`UU`, `DU`, …); "" outside the conflicts group.
    public var kind: String
    /// 3a-v-b: a staged file still holding a whole conflict block.
    public var markers: Bool

    public init(path: String, origPath: String?, group: GitGroup, status: String, kind: String = "", markers: Bool = false) {
        self.path = path
        self.origPath = origPath
        self.group = group
        self.status = status
        self.kind = kind
        self.markers = markers
    }
}

/// 3a-v-b: the merge, rebase, cherry-pick or revert stopped part-way in a root, as `git_status` names it.
/// `incoming` is a merge's branch (or id), `onto` a rebase's; `step`/`steps` a rebase's place; `head` the
/// commit being replayed, picked or reverted, with its `subject`; `message` git's prepared message.
public struct GitOpState: Sendable, Equatable {
    public var kind: String           // "merge" | "rebase" | "cherry-pick" | "revert"
    public var incoming: String
    public var onto: String
    public var step: Int
    public var steps: Int
    public var head: String
    public var subject: String
    public var message: String

    public init(kind: String, incoming: String = "", onto: String = "", step: Int = 0, steps: Int = 0,
                head: String = "", subject: String = "", message: String = "") {
        (self.kind, self.incoming, self.onto, self.step, self.steps, self.head, self.subject, self.message)
            = (kind, incoming, onto, step, steps, head, subject, message)
    }
}

/// One root's `git status`, or the reason it could not be read. A root that
/// failed carries its own `error`; it never hides a sibling.
public struct GitRootState: Sendable, Equatable {
    public var root: String           // absolute
    public var name: String           // last path component
    public var branch: String         // "" when detached
    public var detached: String       // short SHA or ""
    public var ahead: Int
    public var behind: Int
    public var files: [GitFileRow]    // already in group, then path order
    public var error: String?         // whole text; "not a git repository" for a non-repo
    public var loading: Bool
    /// 3a-iii: the branch's upstream (`origin/main`), "" when it has none — Publish's case.
    public var upstream: String
    /// 3a-v-b: the operation stopped part-way, nil when none is.
    public var state: GitOpState?

    public init(root: String, name: String, branch: String, detached: String, ahead: Int,
                behind: Int, files: [GitFileRow], error: String?, loading: Bool, upstream: String = "",
                state: GitOpState? = nil) {
        self.root = root
        self.name = name
        self.branch = branch
        self.detached = detached
        self.ahead = ahead
        self.behind = behind
        self.files = files
        self.error = error
        self.loading = loading
        self.upstream = upstream
        self.state = state
    }
}


/// Errors the git actions raise for reasons of their own.
public enum GitActionError: Error, Sendable, Equatable, CustomStringConvertible {
    /// `root` is not one of the active project's roots. The pane lists only those, and
    /// wakil-git refuses anything else anyway; refusing here names the roots there are.
    case notAProjectRoot(action: String, root: String, roots: [String])
    /// `group` is not conflicts, staged, changed or untracked.
    case unknownGroup(action: String, group: String)

    public var description: String {
        switch self {
        case .notAProjectRoot(let action, let root, let roots):
            return "\(action): \(root) is not a root of the active project (roots: "
                + roots.joined(separator: ", ") + ")"
        case .unknownGroup(let action, let group):
            return "\(action): group must be conflicts, staged, changed or untracked, not \"\(group)\""
        }
    }
}


func gitString(_ o: [String: JSONValue], _ key: String) -> String {
    if case .string(let s)? = o[key] { return s }
    return ""
}

private func gitGroupRank(_ name: String) -> Int {
    switch GitGroup(rawValue: name) {
    case .conflicts?: 0
    case .staged?: 1
    case .changed?: 2
    case .untracked?, nil: 3
    }
}

/// A root's `git_status`, decoded — or, when the call failed, the root with no files and
/// the failure's whole text as its `error`. A row in a group this build does not know is
/// dropped rather than guessed into one.
func gitRootState(root: String, result: Result<JSONValue, Error>) -> GitRootState {
    let name = (root as NSString).lastPathComponent
    func failed(_ text: String) -> GitRootState {
        GitRootState(root: root, name: name, branch: "", detached: "", ahead: 0, behind: 0,
                     files: [], error: text, loading: false)
    }
    let obj: [String: JSONValue]
    switch result {
    case .failure(let error):
        return failed(String(describing: error))
    case .success(.object(let o)):
        obj = o
    case .success:
        return failed("git_status answered with no object")
    }
    if case .bool(true)? = obj["isError"] {
        return failed(mcpErrorText(from: obj) ?? "git_status failed with no message")
    }
    guard case .object(let s)? = obj["structuredContent"] else {
        return failed("git_status answered with no structuredContent")
    }
    var files: [GitFileRow] = []
    if case .array(let rows)? = s["files"] {
        for case .object(let row) in rows {
            guard let g = GitGroup(rawValue: gitString(row, "group")) else { continue }
            let orig = gitString(row, "origPath")
            files.append(GitFileRow(path: gitString(row, "path"), origPath: orig.isEmpty ? nil : orig,
                                    group: g, status: gitString(row, "status"), kind: gitString(row, "kind"),
                                    markers: row["markers"] == .bool(true)))
        }
    }
    files.sort { a, b in
        let ga = gitGroupRank(a.group.rawValue), gb = gitGroupRank(b.group.rawValue)
        if ga != gb { return ga < gb }
        return a.path.utf8.lexicographicallyPrecedes(b.path.utf8)
    }
    var state: GitOpState?
    if case .object(let o)? = s["state"], !gitString(o, "kind").isEmpty {
        state = GitOpState(kind: gitString(o, "kind"), incoming: gitString(o, "incoming"), onto: gitString(o, "onto"),
                           step: Int(o["step"]?.intValue ?? 0), steps: Int(o["steps"]?.intValue ?? 0),
                           head: gitString(o, "head"), subject: gitString(o, "subject"), message: gitString(o, "message"))
    }
    return GitRootState(root: root, name: name, branch: gitString(s, "branch"), detached: gitString(s, "detached"),
                        ahead: s["ahead"]?.intValue ?? 0, behind: s["behind"]?.intValue ?? 0,
                        files: files, error: nil, loading: false, upstream: gitString(s, "upstream"), state: state)
}


/// A root no refresh has read yet: listed in its place, empty, and loading.
func gitPendingRoot(_ root: String) -> GitRootState {
    GitRootState(root: root, name: (root as NSString).lastPathComponent, branch: "", detached: "",
                 ahead: 0, behind: 0, files: [], error: nil, loading: true)
}

/// The window's git status (3b-iii): one `git_status` per root, read once per watcher wake and
/// shared by everything that shows git — the Changes view, the tree's letters, the gutter's
/// baselines, ⌘P's changed files and the vocabulary. Nothing else reads `git_status` for a pane.
///
/// **Each root is read on its own** and a root that fails carries its own `error`, whole (Rule 8);
/// it never hides a sibling. **A read a newer one superseded lands nothing** — neither its list nor
/// the end of its `loading` — so a slow old reply cannot show a stale list (3a-i's Git pane's
/// generations, moved here). A read cut short by cancellation writes no error; its root keeps what
/// it showed.
public actor GitStatus {
    /// wakil-git: these reads, and the diffs and index texts the editor fetches through it.
    public nonisolated let git: (any ToolCaller)?
    private let roots_: @Sendable () async -> [String]
    /// Every project root in project order, as last read. Empty before the first read and after `reset`.
    public private(set) var roots: [GitRootState] = []
    private var latest: [String: Int] = [:]
    private var generation = 0
    /// 3a-v-b (R4): the last Wakil stash apply, pop or Bring Them Along that clashed, per root, for Undo
    /// Apply — the operator's and the agent's alike, so it lives beside the status both read. Forgotten by
    /// Undo Apply, by a read that finds the root's conflicts group empty, by `reset`, or by a relaunch.
    public private(set) var clashes: [String: GitStashClash] = [:]
    /// The generation each clash was remembered at: only a read begun after it sampled the tree with the
    /// clash in it, so only such a read may forget it (a read in flight across the apply may not).
    private var clashGenerations: [String: Int] = [:]

    public init(git: (any ToolCaller)?, roots: @escaping @Sendable () async -> [String]) {
        self.git = git
        self.roots_ = roots
    }

    /// The active project's roots, asked live (the window's, else `wakil-ctx`'s).
    public func projectRoots() async -> [String] { await roots_() }

    /// A read begun and not yet finished: the roots it reads and its generation.
    struct Ticket: Sendable {
        let targets: [String]
        let generation: Int
    }

    /// Reads `only`, or every root: `begin`, then `finish`.
    public func refresh(only: String? = nil) async {
        await finish(begin(only: only))
    }

    /// **The first half of a read, published before the read is awaited.** Roots the project no
    /// longer has are dropped, roots it gained are listed loading, the ones about to be read are
    /// marked loading, and a root outside the project reads nothing. A caller adopts `roots` between
    /// `begin` and `finish`, so a pane shows every root loading while the read runs.
    func begin(only: String? = nil) async -> Ticket {
        let all = await roots_()
        let targets = only.map { all.contains($0) ? [$0] : [] } ?? all
        let known = Dictionary(roots.map { ($0.root, $0) }, uniquingKeysWith: { a, _ in a })
        roots = all.map { r in
            var state = known[r] ?? gitPendingRoot(r)
            if targets.contains(r) { state.loading = true }
            return state
        }
        generation += 1
        for r in targets { latest[r] = generation }
        return Ticket(targets: targets, generation: generation)
    }

    /// The second half: reads the ticket's roots and lands each one this is still the latest read of.
    func finish(_ ticket: Ticket) async {
        let read = await gitReadStatus(git, roots: ticket.targets)
        roots = roots.map { state in
            guard let outcome = read[state.root], latest[state.root] == ticket.generation else { return state }
            guard let fresh = outcome else {
                var kept = state
                kept.loading = false
                return kept
            }
            if fresh.error == nil, !fresh.files.contains(where: { $0.group == .conflicts }),
               ticket.generation > clashGenerations[state.root] ?? Int.min {
                clashes[state.root] = nil
                clashGenerations[state.root] = nil
            }
            return fresh
        }
    }

    /// Remembers `clash` as `root`'s (R4).
    func remember(_ clash: GitStashClash, root: String) {
        clashes[root] = clash
        clashGenerations[root] = generation
    }
    /// Forgets `root`'s clash: Undo Apply put it back.
    func forgetClash(_ root: String) {
        clashes[root] = nil
        clashGenerations[root] = nil
    }

    /// Forgets every root (an org switch, or no pane left that shows git).
    public func reset() {
        roots = []
        latest = [:]
        clashes = [:]
        clashGenerations = [:]
    }
}

/// Each root's `git_status`, in parallel: the decoded state, or nil when the read was cancelled.
private func gitReadStatus(_ git: (any ToolCaller)?, roots: [String]) async -> [String: GitRootState?] {
    await withTaskGroup(of: (String, GitRootState?).self) { group in
        for r in roots {
            group.addTask {
                guard let git else {
                    return (r, gitRootState(root: r, result: .failure(
                        StandardActionError.missingClient(action: "git_status", role: "git"))))
                }
                let result: Result<JSONValue, Error>
                do {
                    result = .success(try await git.callTool(
                        name: "git_status", arguments: .object(["root": .string(r)]),
                        timeout: MCPClient.readReplyTimeout))
                } catch {
                    result = .failure(error)
                }
                if Task.isCancelled { return (r, nil) }
                if case .failure(let error) = result, error is CancellationError { return (r, nil) }
                return (r, gitRootState(root: r, result: result))
            }
        }
        var states: [String: GitRootState?] = [:]
        for await (r, state) in group { states[r] = state }
        return states
    }
}
