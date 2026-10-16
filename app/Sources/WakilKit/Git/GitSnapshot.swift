import Foundation

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
    /// A diff tab's file is no longer in its group (committed, staged, discarded): the tab says so
    /// and stays open until closed, its last texts kept (3b-iii, Rule 7).
    public var noLongerChanged: Bool

    public init(original: String, modified: String, language: String, binary: Bool, bytes: Int,
                lines: Int, truncated: Bool, error: String?, loading: Bool, noLongerChanged: Bool = false) {
        self.original = original
        self.modified = modified
        self.language = language
        self.binary = binary
        self.bytes = bytes
        self.lines = lines
        self.truncated = truncated
        self.error = error
        self.loading = loading
        self.noLongerChanged = noLongerChanged
    }

    static func loading(_ language: String) -> GitDiffState {
        GitDiffState(original: "", modified: "", language: language, binary: false, bytes: 0, lines: 0,
                     truncated: false, error: nil, loading: true)
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
