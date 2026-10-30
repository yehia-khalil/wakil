import Foundation

/// What a conversation's thread says when the write rule moved it (spec, piece 1; Rule 8: an
/// error whole).
public enum WorkspaceLine: Equatable, Sendable {
    case started(name: String, repo: String, branch: String, uncommitted: Int)
    case tookOver(repo: String, from: String)
    case branchedOff(name: String, repo: String, branch: String, holder: String)
    /// A Start another conversation's first write (item 8): a child workspace from the parent
    /// branch `from` at `commit` (nil: unread), never the holder's copy; `uncommitted` is the holder's
    /// copy's (nil: unread), not carried.
    case branchedOffAt(name: String, repo: String, branch: String, from: String, commit: String?, holder: String,
                       uncommitted: Int?)
    /// The same, where the workspace `parent` has no copy of the repo: a child of its own.
    case branchedOffNoCopy(name: String, repo: String, parent: String)
    case tookFromMain(repo: String, branch: String, base: String, carried: Bool)
    case addFailed(repo: String, message: String)
    case madeCheckout(repo: String, branch: String, note: String?)
    /// workspace_start (amendment 2026-10-30, decision 10 refined): a copy from the base the agent
    /// chose, in Main (a new workspace) or in its workspace.
    case startedFrom(name: String, repo: String, base: String, branch: String)
    case madeFrom(repo: String, base: String, branch: String)
    case moved(name: String)
    case switchBranchedOff(branch: String, holder: String, fresh: String)
    /// The record could not be saved after a copy was made: the copy was taken back (`leftAt` nil),
    /// or could not be and is still there (amendment 2026-10-30, the walk).
    case recordFailed(repo: String, reason: String, leftAt: String?)

    public var text: String {
        switch self {
        case .started(let name, let repo, let branch, let n):
            let tail: String
            switch n {
            case 0: tail = "Your folder is untouched."
            case 1: tail = "Your folder is untouched; your 1 uncommitted change there is not in the copy."
            default: tail = "Your folder is untouched; your \(n) uncommitted changes there are not in the copy."
            }
            return "Started workspace ‘\(name)’ — a copy of \(repo) on `\(branch)`, from the commit your folder is on. \(tail)"
        case .tookOver(let repo, let from):
            return "Took over \(repo) from ‘\(from)’ (idle)."
        case .branchedOff(let name, let repo, let branch, let holder):
            return "‘\(holder)’ is working in \(repo), so this conversation branched off into workspace ‘\(name)’ on `\(branch)`."
        case .branchedOffAt(let name, let repo, let branch, let from, let commit, let holder, let n):
            let at = commit.map { "Branched off \(from) at \($0)." } ?? "Branched off \(from) at its last commit."
            let left: String
            switch n {
            case nil: left = "Wakil could not read ‘\(holder)’'s copy, so it cannot say what is uncommitted there."
            case 0?: left = "‘\(holder)’ has no uncommitted changes in its copy."
            case 1?: left = "‘\(holder)’ has 1 uncommitted change in its copy that is not in yours."
            case let n?: left = "‘\(holder)’ has \(n) uncommitted changes in its copy that are not in yours."
            }
            return "\(at) \(left) This conversation works in workspace ‘\(name)’, a copy of \(repo) on `\(branch)`."
        case .branchedOffNoCopy(let name, let repo, let parent):
            return "‘\(parent)’ has no copy of \(repo), so this conversation branched off into workspace ‘\(name)’ and "
                + "makes its own copy of \(repo) there."
        case .tookFromMain(let repo, let branch, let base, let carried):
            let tail = carried ? ", and its uncommitted changes came along into the copy." : "."
            return "Took `\(branch)` from your folder of \(repo): your folder is back on `\(base)`\(tail)"
        case .addFailed(let repo, let message):
            return "Could not make a copy of \(repo), so the change was not made:\n\(message)"
        case .madeCheckout(let repo, let branch, let note):
            let base = "Made a copy of \(repo) in this workspace, on `\(branch)`."
            return note.map { "\(base) \($0)." } ?? base
        case .startedFrom(let name, let repo, let base, let branch):
            return "Started workspace ‘\(name)’ — a copy of \(repo) from `\(base)` on `\(branch)`. Your folder is untouched."
        case .madeFrom(let repo, let base, let branch):
            return "Made a copy of \(repo) from `\(base)` on `\(branch)`."
        case .moved(let name):
            return "Moved to workspace ‘\(name)’."
        case .switchBranchedOff(let branch, let holder, let fresh):
            return "‘\(holder)’ is working on `\(branch)`, so this copy switched to a new branch `\(fresh)` off its tip."
        case .recordFailed(let repo, let reason, nil):
            return "Made a copy of \(repo) but could not save the workspace record, so the copy was taken back (nothing had "
                + "been written in it) and the change was not made. Your folder is untouched:\n\(reason)"
        case .recordFailed(let repo, let reason, let path?):
            return "Made a copy of \(repo) but could not save the workspace record, so the change was not made. The copy "
                + "could not be taken back and is still at \(path):\n\(reason)"
        }
    }
}
