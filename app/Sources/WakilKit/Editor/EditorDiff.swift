import Foundation

/// The revisions a diff compares, by group (3a-i's `gitDiffRevs`, with deletions):
/// - Staged: HEAD against the index.
/// - Changes: the index against the working tree.
/// - Untracked: nothing against the working tree.
/// - Deleted (`D`): the original against nothing on the right, since nothing is left to read.
/// - Conflicted (`U`, always in Changes): HEAD against the working tree, because mid-merge the index
///   holds stages, not one version.
public func editorDiffRevs(_ group: GitGroup, status: String?) -> (original: String?, modified: String?) {
    if group == .changed, status == "U" { return ("HEAD", "worktree") }
    let deleted = status == "D"
    switch group {
    case .staged: return ("HEAD", deleted ? nil : "index")
    case .changed: return ("index", deleted ? nil : "worktree")
    case .untracked: return (nil, "worktree")
    }
}

/// Whether ⌘⏎ (`editor_open_file`) may open a diff's file. No for a deleted file's diff, or for a
/// Staged diff whose file is gone from the working tree (a `D` in Changes).
public func editorDiffOpensFile(root: String, path: String, group: GitGroup, roots: [GitRootState]) -> Bool {
    guard let r = roots.first(where: { $0.root == root }) else { return true }
    let rows = r.files.filter { $0.path == path }
    if rows.contains(where: { $0.group == .changed && $0.status == "D" }) { return false }
    if rows.first(where: { $0.group == group })?.status == "D" { return false }
    return true
}

/// ⌘⏎ in a focused editor pane (R10): open the file when the active tab is a diff that may, else
/// it is Maximize Pane as everywhere else.
public func editorCommandReturnOpensFile(_ s: EditorSnapshot?, roots: [GitRootState]) -> Bool {
    guard let s, let i = s.active, i < s.tabs.count,
          case .diff(let root, let path, let group) = s.tabs[i].subject else { return false }
    return editorDiffOpensFile(root: root, path: path, group: group, roots: roots)
}

/// A diff tab's own name for its group, in its title.
func editorDiffGroupTitle(_ g: GitGroup) -> String {
    switch g {
    case .staged: "Staged"
    case .changed: "Changes"
    case .untracked: "Untracked"
    }
}

/// One diff fetch per diff tab of each pane: a new fetch for a tab cancels its last, and a tab's
/// fetch is cancelled when its tab is replaced (Rules 4, 5).
///
/// **Synchronous, behind a lock, so it can be called inside `PaneStore.updateEditor`** — the turn
/// that writes the tab also starts the fetch that owns it (3a-i's `GitFlights`, for the same reason).
final class EditorDiffFlights: @unchecked Sendable {
    private let lock = NSLock()
    private var flights: [String: [String: Task<Void, Never>]] = [:]   // pane -> tab key -> fetch

    func start(_ pane: String, key: String, _ body: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        lock.withLock {
            flights[pane]?[key]?.cancel()
            let task = Task { await body() }
            flights[pane, default: [:]][key] = task
            return task
        }
    }

    func cancel(_ pane: String, key: String) {
        lock.withLock { _ = flights[pane]?.removeValue(forKey: key).map { $0.cancel() } }
    }

    func drop(_ pane: String) {
        lock.withLock { flights.removeValue(forKey: pane)?.values.forEach { $0.cancel() } }
    }
}
