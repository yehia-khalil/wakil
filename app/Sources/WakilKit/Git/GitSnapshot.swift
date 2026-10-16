import Foundation

/// Which list a changed file sits in: what is staged, what is changed in the
/// working tree, or what git does not track yet.
public enum GitGroup: String, Sendable, Codable, CaseIterable { case staged, changed, untracked }

/// One file in one group of one root's status.
public struct GitFileRow: Sendable, Equatable, Hashable {
    public var path: String
    public var origPath: String?
    public var group: GitGroup
    public var status: String

    public init(path: String, origPath: String?, group: GitGroup, status: String) {
        self.path = path
        self.origPath = origPath
        self.group = group
        self.status = status
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

    public init(root: String, name: String, branch: String, detached: String, ahead: Int,
                behind: Int, files: [GitFileRow], error: String?, loading: Bool) {
        self.root = root
        self.name = name
        self.branch = branch
        self.detached = detached
        self.ahead = ahead
        self.behind = behind
        self.files = files
        self.error = error
        self.loading = loading
    }
}

/// The file the operator has open, in the root and group it was picked from.
public struct GitSelection: Sendable, Equatable, Hashable {
    public var root: String
    public var path: String
    public var group: GitGroup

    public init(root: String, path: String, group: GitGroup) {
        self.root = root
        self.path = path
        self.group = group
    }
}

/// The two sides of the open file's diff. The texts are large, so
/// `read_pane` publishes only the facts about them.
public struct GitDiffState: Sendable, Equatable {
    public var original: String
    public var modified: String
    public var language: String
    public var binary: Bool
    public var bytes: Int
    public var lines: Int
    public var truncated: Bool
    public var error: String?
    public var loading: Bool

    public init(original: String, modified: String, language: String, binary: Bool, bytes: Int,
                lines: Int, truncated: Bool, error: String?, loading: Bool) {
        self.original = original
        self.modified = modified
        self.language = language
        self.binary = binary
        self.bytes = bytes
        self.lines = lines
        self.truncated = truncated
        self.error = error
        self.loading = loading
    }
}

/// Everything a git pane holds: the project's roots, the selection, whether
/// the list is folded, and the open diff.
public struct GitSnapshot: Sendable, Equatable {
    public var roots: [GitRootState]
    public var selection: GitSelection?
    public var folded: Bool
    public var diff: GitDiffState?
    /// The root the unfolded list scrolls to when a refresh took the selected file's root's
    /// last file away (Rule 6: the list unfolds with that root in view). nil otherwise; a
    /// select clears it.
    public var inView: String?

    public init(roots: [GitRootState], selection: GitSelection?, folded: Bool, diff: GitDiffState?,
                inView: String? = nil) {
        self.roots = roots
        self.selection = selection
        self.folded = folded
        self.diff = diff
        self.inView = inView
    }

    public static let empty = GitSnapshot(roots: [], selection: nil, folded: false, diff: nil)
}
