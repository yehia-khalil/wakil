import Foundation

/// One local branch as `git_branches` answers it (3a-iv).
public struct GitBranchInfo: Sendable, Equatable, Hashable, Decodable {
    public var name: String
    public var upstream: String
    public var ahead: Int
    public var behind: Int
    /// Commits the current branch lacks: what deleting this one loses.
    public var unmerged: Int
    public var current: Bool

    public init(name: String, upstream: String, ahead: Int, behind: Int, unmerged: Int, current: Bool) {
        (self.name, self.upstream, self.ahead, self.behind, self.unmerged, self.current) = (name, upstream, ahead, behind, unmerged, current)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        upstream = try c.decodeIfPresent(String.self, forKey: .upstream) ?? ""
        ahead = try c.decodeIfPresent(Int.self, forKey: .ahead) ?? 0
        behind = try c.decodeIfPresent(Int.self, forKey: .behind) ?? 0
        unmerged = try c.decodeIfPresent(Int.self, forKey: .unmerged) ?? 0
        current = try c.decodeIfPresent(Bool.self, forKey: .current) ?? false
    }

    private enum CodingKeys: String, CodingKey { case name, upstream, ahead, behind, unmerged, current }
}

/// A root's branches: local ones most recently committed first, remote ones no local tracks.
public struct GitBranchesInfo: Sendable, Equatable, Decodable {
    public var local: [GitBranchInfo]
    public var remote: [String]
    public var current: String
    public var detached: String

    public init(local: [GitBranchInfo], remote: [String], current: String, detached: String) {
        (self.local, self.remote, self.current, self.detached) = (local, remote, current, detached)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        local = try c.decodeIfPresent([GitBranchInfo].self, forKey: .local) ?? []
        remote = try c.decodeIfPresent([String].self, forKey: .remote) ?? []
        current = try c.decodeIfPresent(String.self, forKey: .current) ?? ""
        detached = try c.decodeIfPresent(String.self, forKey: .detached) ?? ""
    }

    private enum CodingKeys: String, CodingKey { case local, remote, current, detached }
}

/// One stash. Actions name it by `index` and `id`: the list is shared with the terminal and every
/// worktree, so a position that no longer holds `id` is refused rather than touching another stash.
public struct GitStashInfo: Sendable, Equatable, Hashable, Decodable, Identifiable {
    public var index: Int
    public var id: String
    public var message: String
    public var branch: String
    /// ISO 8601, as git reports it.
    public var date: String
    public var files: [String]
    /// The part of `files` the stash took untracked.
    public var untracked: [String]

    public init(index: Int, id: String, message: String, branch: String, date: String, files: [String], untracked: [String] = []) {
        (self.index, self.id, self.message, self.branch, self.date, self.files, self.untracked) = (index, id, message, branch, date, files, untracked)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = try c.decode(Int.self, forKey: .index)
        id = try c.decode(String.self, forKey: .id)
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
        branch = try c.decodeIfPresent(String.self, forKey: .branch) ?? ""
        date = try c.decodeIfPresent(String.self, forKey: .date) ?? ""
        files = try c.decodeIfPresent([String].self, forKey: .files) ?? []
        untracked = try c.decodeIfPresent([String].self, forKey: .untracked) ?? []
    }

    private enum CodingKeys: String, CodingKey { case index, id, message, branch, date, files, untracked }
}

/// A row of the branch picker, in VS Code's Quick Pick order.
public enum BranchPickerRow: Sendable, Equatable, Hashable {
    case create(String)
    case createFrom
    case local(GitBranchInfo)
    case remote(String)
    case fetch
}

/// A typed branch name: trimmed, each run of spaces one "-" (VS Code's default).
public func normaliseBranchName(_ s: String) -> String {
    s.split(whereSeparator: \.isWhitespace).joined(separator: "-")
}

/// The picker's rows for `filter`: **Create branch "…"** when the filter names no local branch, then
/// **Create branch from…**, the local branches, the remote ones, and **Fetch** — each list filtered
/// case-insensitively.
public func branchPickerRows(_ b: GitBranchesInfo, filter: String) -> [BranchPickerRow] {
    let typed = normaliseBranchName(filter)
    let needle = typed.lowercased()
    func matches(_ name: String) -> Bool { needle.isEmpty || name.lowercased().contains(needle) }
    var rows: [BranchPickerRow] = []
    if !typed.isEmpty, !b.local.contains(where: { $0.name == typed }) { rows.append(.create(typed)) }
    rows.append(.createFrom)
    rows += b.local.filter { matches($0.name) }.map(BranchPickerRow.local)
    rows += b.remote.filter(matches).map(BranchPickerRow.remote)
    rows.append(.fetch)
    return rows
}

/// What the context line's Branch segment reads for the active root: `main`, `api: main` with several
/// roots, `detached at 3f2a1c9`; nil with no git root.
public func branchSegmentText(_ active: GitRootState?, rootCount: Int) -> String? {
    guard let active else { return nil }
    let text: String
    if !active.branch.isEmpty { text = active.branch }
    else if !active.detached.isEmpty { text = "detached at \(active.detached)" }
    else { return nil }
    return rootCount > 1 ? "\(active.name): \(text)" : text
}

/// The root the operator is in: the one holding the focused tab's file (the innermost), else the first.
public func activeGitRoot(focusedPath: String?, roots: [GitRootState]) -> GitRootState? {
    if let path = focusedPath,
       let hit = roots.filter({ path == $0.root || path.hasPrefix($0.root + "/") }).max(by: { $0.root.count < $1.root.count }) {
        return hit
    }
    return roots.first
}

/// Delete Branch's in-place confirmation (Rule 1): what deleting it loses.
public func deleteBranchConfirmation(_ branch: GitBranchInfo, current: String) -> String {
    switch branch.unmerged {
    case 0: return "Delete \(branch.name)? It is merged into \(current)."
    case 1: return "Delete \(branch.name)? Its 1 commit not on \(current) is kept only in git's reflog."
    default: return "Delete \(branch.name)? Its \(branch.unmerged) commits not on \(current) are kept only in git's reflog."
    }
}

public func dropStashConfirmation(_ s: GitStashInfo) -> String {
    "Drop \"\(s.message)\"? It cannot be applied again."
}

public func dropAllStashesConfirmation(_ count: Int) -> String {
    count == 1 ? "Drop the stash? It cannot be applied again." : "Drop all \(count) stashes? They cannot be applied again."
}

/// A stash file's two diff sides: its base and the stash, or — for an untracked file — nothing and
/// the stash's untracked tree.
public func editorStashDiffRevs(stash: String, untracked: Bool) -> (original: String?, modified: String?) {
    untracked ? (nil, "stash-untracked:\(stash)") : ("stash-base:\(stash)", "stash:\(stash)")
}
