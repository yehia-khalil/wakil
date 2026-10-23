import Foundation

/// The file the Timeline and blame are about for `tab` (R2): a file tab's path relative to its root, or
/// a diff tab's root and path. Nil for a scratch tab or no tab.
public func editorTimelineSubject(_ tab: EditorTab?) -> (root: String, path: String)? {
    switch tab?.subject {
    case .file(let path, let root)? where path.hasPrefix(root + "/"): (root, String(path.dropFirst(root.count + 1)))
    case .diff(let root, let path, _, _)?: (root, path)
    default: nil
    }
}

/// One row of the Timeline (3a-v-a): the file's uncommitted changes, a commit, or the next page.
public enum EditorTimelineRow: Sendable, Equatable {
    case uncommitted
    case commit(GitCommitInfo)
    case more
}

/// The Timeline's rows: `Uncommitted changes` on top when the file differs from HEAD, the commits
/// newest first, and `Load more` last when the last page came back full.
public func editorTimelineRows(_ commits: [GitCommitInfo], uncommitted: Bool, more: Bool) -> [EditorTimelineRow] {
    (uncommitted ? [.uncommitted] : []) + commits.map(EditorTimelineRow.commit) + (more ? [.more] : [])
}

/// A full page may have another after it; a short one is the end.
public func editorTimelineHasMore(pageCount: Int) -> Bool { pageCount >= 50 }

/// What a Timeline row opens: the commit under the file's name there, and the name before it when the
/// next older row (the file as it was) is named differently — a rename between them.
public func editorTimelineCommitRef(_ c: GitCommitInfo, older: GitCommitInfo?) -> GitCommitRef {
    GitCommitRef(id: c.id, path: c.path, parentPath: older.flatMap { $0.path != c.path ? $0.path : nil })
}

/// Whether the Timeline shows `Uncommitted changes`, and the Changes diff it opens: the file's unstaged
/// changes when it has any (or its tab is unsaved), else its staged ones; nil when it matches HEAD.
public func editorTimelineUncommittedGroup(_ rows: [GitFileRow], path: String, dirty: Bool) -> GitGroup? {
    let groups = Set(rows.filter { $0.path == path }.map(\.group))
    if groups.contains(.changed) || dirty { return .changed }
    return groups.contains(.staged) ? .staged : nil
}
