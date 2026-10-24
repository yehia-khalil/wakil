import Foundation

// 3a-v-b: what the Changes view says about a conflict and the operation in progress, pure, because
// WakilApp has no test target, and the clash record Undo Apply sends back. `EditorColumn` draws these.

/// One file a stash clash touched, and its work-tree hash at the clash (Undo Apply refuses one changed since).
public struct GitClashFile: Sendable, Equatable, Hashable, Codable {
    public var path: String
    public var hash: String

    public init(path: String, hash: String) {
        self.path = path
        self.hash = hash
    }
}

/// A file the stash touched whose index entry was staged before the apply (mode and hash empty for a
/// staged deletion): Undo Apply puts that entry back, not HEAD's.
public struct GitClashIndex: Sendable, Equatable, Hashable, Codable {
    public var path: String
    public var mode: String
    public var hash: String

    public init(path: String, mode: String, hash: String) {
        (self.path, self.mode, self.hash) = (path, mode, hash)
    }
}

/// A Wakil stash apply, pop or Bring Them Along that stopped on conflicts, as `wakil-git` returns it
/// (`clash`) and `git_stash_undo_apply` takes it back: the stash's id, the files it touched, the
/// untracked ones it created, the paths left unmerged, and the entries staged before it. A list Go
/// sends as `null` or leaves out reads empty.
public struct GitStashClash: Sendable, Equatable, Hashable, Codable {
    public var id: String
    public var files: [GitClashFile]
    public var created: [String]
    public var conflicts: [String]
    public var staged: [GitClashIndex]

    public init(id: String, files: [GitClashFile], created: [String], conflicts: [String], staged: [GitClashIndex] = []) {
        (self.id, self.files, self.created, self.conflicts, self.staged) = (id, files, created, conflicts, staged)
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        files = try c.decodeIfPresent([GitClashFile].self, forKey: .files) ?? []
        created = try c.decodeIfPresent([String].self, forKey: .created) ?? []
        conflicts = try c.decodeIfPresent([String].self, forKey: .conflicts) ?? []
        staged = try c.decodeIfPresent([GitClashIndex].self, forKey: .staged) ?? []
    }
}

extension GitStashClash {
    /// The `clash` field of a stash apply's, pop's or switch's result, when it has one.
    init?(result: JSONValue) {
        guard case .object(let o) = result, let value = o["clash"], case .object = value,
              let data = try? JSONEncoder().encode(value),
              let clash = try? JSONDecoder().decode(GitStashClash.self, from: data) else { return nil }
        self = clash
    }

    /// The record as `git_stash_undo_apply` takes it.
    var json: JSONValue {
        .object([
            "id": .string(id),
            "files": .array(files.map { .object(["path": .string($0.path), "hash": .string($0.hash)]) }),
            "created": .array(created.map { .string($0) }),
            "conflicts": .array(conflicts.map { .string($0) }),
            "staged": .array(staged.map {
                .object(["path": .string($0.path), "mode": .string($0.mode), "hash": .string($0.hash)])
            }),
        ])
    }
}

private func gitId7(_ id: String) -> String { String(id.prefix(7)) }

/// The root header's state, in amber: `merging feature/search`, `rebasing 2/5 onto main`,
/// `cherry-picking abc1234`, `reverting abc1234`.
public func gitOpStateLabel(_ s: GitOpState) -> String {
    switch s.kind {
    case "merge": "merging \(s.incoming)"
    case "rebase": "rebasing \(s.step)/\(s.steps) onto \(s.onto)"
    case "cherry-pick": "cherry-picking \(gitId7(s.head))"
    case "revert": "reverting \(gitId7(s.head))"
    default: s.kind
    }
}

/// The commit button's title: `Continue Rebase` mid-rebase, `Commit Merge` mid-merge, cherry-pick or
/// revert, else `Commit` with something staged and `Commit All` with nothing (Rule 9: the default is
/// everything, and the button says so).
public func changesCommitTitle(_ r: GitRootState) -> String {
    switch r.state?.kind {
    case "rebase"?: return "Continue Rebase"
    case "merge"?, "cherry-pick"?, "revert"?: return "Commit Merge"
    default: return r.files.contains { $0.group == .staged } ? "Commit" : "Commit All"
    }
}

/// Why Commit Merge / Continue Rebase is disabled, beside it: `Resolve 1 conflict first`,
/// `Resolve 3 conflicts first`; nil while the Merge Changes group is empty.
public func changesConflictsReason(_ r: GitRootState) -> String? {
    let n = r.files.filter { $0.group == .conflicts }.count
    guard n > 0 else { return nil }
    return n == 1 ? "Resolve 1 conflict first" : "Resolve \(n) conflicts first"
}

/// A conflicted row's kind, after its name: `both modified` for `UU`, …; the code itself for one git
/// adds later.
public func gitConflictKindLabel(_ xy: String) -> String {
    switch xy {
    case "UU": "both modified"
    case "AA": "both added"
    case "DU": "deleted by us"
    case "UD": "deleted by them"
    case "AU": "added by us"
    case "UA": "added by them"
    case "DD": "both deleted"
    default: xy
    }
}

/// A staged row still holding a whole conflict block, in amber: `a.txt — staged with conflict markers`;
/// nil for any other row.
public func gitRowMarkersNote(_ row: GitFileRow) -> String? {
    guard row.group == .staged, row.markers else { return nil }
    return "\(gitRowName(row)) — staged with conflict markers"
}

/// The incoming side a whole-file take names: the merged branch, the commit a rebase, cherry-pick or
/// revert applies (its short id), or the stash for a stash clash, which has no operation.
public func changesIncomingSide(_ r: GitRootState) -> String {
    guard let s = r.state else { return "the stash" }
    return s.kind == "merge" ? s.incoming : gitId7(s.head)
}

/// A delete/modify conflict (`DU`, `UD`): its row offers Keep File and Delete File, not the Accept Alls.
public func gitConflictIsDeleteModify(_ row: GitFileRow) -> Bool {
    row.kind == "DU" || row.kind == "UD"
}

/// A conflicted row's whole-file choices, in menu order.
public enum GitConflictAction: Sendable, Equatable {
    case takeCurrent, takeIncoming, keep, delete
}

/// What a conflicted row offers: only the sides that exist — added by us (`AU`) has no incoming copy, added
/// by them (`UA`) no current one — and Keep File / Delete File where a side deleted it (`DU`, `UD`, `DD`).
public func gitConflictActions(_ row: GitFileRow) -> [GitConflictAction] {
    switch row.kind {
    case "DU", "UD", "DD": [.keep, .delete]
    case "AU": [.takeCurrent]
    case "UA": [.takeIncoming]
    default: [.takeCurrent, .takeIncoming]
    }
}

/// The ▾ item that aborts the operation, named by its kind: `Abort Merge`, `Abort Rebase`,
/// `Abort Cherry-Pick`, `Abort Revert`.
public func changesAbortTitle(_ s: GitOpState) -> String {
    switch s.kind {
    case "rebase": "Abort Rebase"
    case "cherry-pick": "Abort Cherry-Pick"
    case "revert": "Abort Revert"
    default: "Abort Merge"
    }
}

/// Abort's in-place confirm (Rule 1).
public func changesAbortConfirmation(_ s: GitOpState) -> String {
    "Abort the \(s.kind)? The tree goes back to before it, and your resolutions are lost."
}

/// Skip Commit's in-place confirm.
public func changesSkipConfirmation(id7: String, subject: String) -> String {
    "Skip \(id7) \"\(subject)\"? Its changes are left out of the rebase."
}

/// A whole-file take's in-place confirm: `take` is current (HEAD's), incoming (`incoming`'s) or delete,
/// which takes the side that deleted the file — ours (HEAD) for `DU`, theirs for `UD`.
public func changesTakeConfirmation(path: String, take: String, incoming: String, kind: String = "") -> String {
    switch take {
    case "current":
        return "Take all of HEAD's \(path)? Any edits you made to it are lost."
    case "delete":
        let side = kind == "UD" ? incoming : "HEAD"
        return "Take all of \(side)'s \(path)? Any edits you made to it are lost, and the file is deleted."
    default:
        return "Take all of \(incoming)'s \(path)? Any edits you made to it are lost."
    }
}

/// Undo Apply's in-place confirm, naming the stash by its message.
public func changesUndoApplyConfirmation(message: String) -> String {
    "Undo applying \"\(message)\"? The files it touched go back to HEAD; the stash stays in the list."
}
