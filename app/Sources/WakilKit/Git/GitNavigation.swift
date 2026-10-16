import Foundation

private let groupOrder: [GitGroup: Int] = [.staged: 0, .changed: 1, .untracked: 2]

/// Every row in step order: roots in project order, then staged, changed, untracked, then path.
public func gitRows(_ roots: [GitRootState]) -> [GitSelection] {
    roots.flatMap { r in
        r.files
            .sorted { a, b in
                let ga = groupOrder[a.group]!, gb = groupOrder[b.group]!
                if ga != gb { return ga < gb }
                return a.path.utf8.lexicographicallyPrecedes(b.path.utf8)   // byte order
            }
            .map { GitSelection(root: r.root, path: $0.path, group: $0.group) }
    }
}

/// The row `delta` away from `current`, clamped at both ends. nil when there are no rows.
public func gitStep(_ roots: [GitRootState], from current: GitSelection?, by delta: Int) -> GitSelection? {
    let rows = gitRows(roots)
    guard !rows.isEmpty else { return nil }
    guard let current, let i = rows.firstIndex(of: current) else { return rows.first }
    return rows[min(max(i + delta, 0), rows.count - 1)]
}

/// Rule 6. Where the selection goes when `before` is replaced by `after`.
public enum GitReselect: Equatable { case keep(GitSelection), moved(GitSelection), unfold(root: String) }

/// Where the selection lands after a refresh per Rule 6. If the file the operator
/// was viewing moved groups (e.g., `git add` changed it from Changed to Staged),
/// follow it to its new group. If it vanished, move to the row that took its position,
/// or unfold the root if nothing remains. If the path appears in multiple groups,
/// prefer the original group, else the first in step order.
public func gitReselect(_ selection: GitSelection, before: [GitRootState], after: [GitRootState]) -> GitReselect {
    let afterRows = gitRows(after)

    // Find all occurrences of the same path in the same root after the refresh.
    let samePathAfter = afterRows.filter { $0.root == selection.root && $0.path == selection.path }

    // If the exact selection still exists
    if samePathAfter.contains(selection) {
        // If it's the only occurrence of this path → keep
        if samePathAfter.count == 1 {
            return .keep(selection)
        }
        // If the path appears in multiple groups (partly staged) → moved (indicate state change)
        return .moved(selection)
    }

    // The exact selection is gone. Check if the same path exists in a different group.
    if !samePathAfter.isEmpty {
        // Prefer the original group if it exists there
        if let inOriginalGroup = samePathAfter.first(where: { $0.group == selection.group }) {
            return .moved(inOriginalGroup)
        }
        // Otherwise, prefer the first in step order
        let sorted = samePathAfter.sorted { a, b in
            let ga = groupOrder[a.group]!, gb = groupOrder[b.group]!
            return ga < gb
        }
        return .moved(sorted.first!)
    }

    // Path is gone from this root. Check if the root has any files left.
    let sameRootAfter = afterRows.filter { $0.root == selection.root }
    guard !sameRootAfter.isEmpty else { return .unfold(root: selection.root) }

    // Move to the row at the index the selection held, or the last row if out of bounds.
    let sameRootBefore = gitRows(before).filter { $0.root == selection.root }
    let i = sameRootBefore.firstIndex(of: selection) ?? 0
    return .moved(sameRootAfter[min(i, sameRootAfter.count - 1)])
}
