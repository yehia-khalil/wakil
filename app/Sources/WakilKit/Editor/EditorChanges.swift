import Foundation

// The Changes view's rows and the choices behind them (3b-iii), pure, because WakilApp has no test
// target. The status is the window's (`GitStatus`); the highlight, collapsed roots and closed groups
// are the pane's.

private func editorChangesRank(_ group: String) -> Int {
    switch GitGroup(rawValue: group) {
    case .conflicts?: 0
    case .staged?: 1
    case .changed?: 2
    case .untracked?, nil: 3
    }
}

/// Step order within one root: merge changes, staged, changes, untracked, then path in byte order.
private func editorChangesPrecedes(_ a: EditorChangesRow, _ b: EditorChangesRow) -> Bool {
    let ra = editorChangesRank(a.group), rb = editorChangesRank(b.group)
    if ra != rb { return ra < rb }
    return a.path.utf8.lexicographicallyPrecedes(b.path.utf8)
}

private func editorChangesRows(of r: GitRootState) -> [EditorChangesRow] {
    r.files.map { EditorChangesRow(root: r.root, path: $0.path, group: $0.group.rawValue) }
        .sorted(by: editorChangesPrecedes)
}

/// Every row the view draws, in step order: roots in project order, a collapsed root's rows and a
/// closed group's rows left out, then merge changes, staged, changes, untracked, then path.
public func editorChangesRows(_ roots: [GitRootState], closed: Set<String>,
                              closedGroups: Set<EditorChangesGroup> = []) -> [EditorChangesRow] {
    roots.filter { !closed.contains($0.root) }.flatMap(editorChangesRows(of:))
        .filter { !closedGroups.contains(EditorChangesGroup(root: $0.root, group: $0.group)) }
}

/// The row `delta` away from `from` among the drawn rows, clamped at both ends; the first row when
/// `from` is nil or not drawn; nil when nothing is drawn. A closed group is skipped as a collapsed
/// root is, and stays closed (Rule 6).
public func editorChangesStep(_ roots: [GitRootState], closed: Set<String>,
                              closedGroups: Set<EditorChangesGroup> = [], from: EditorChangesRow?,
                              by delta: Int) -> EditorChangesRow? {
    let rows = editorChangesRows(roots, closed: closed, closedGroups: closedGroups)
    guard !rows.isEmpty else { return nil }
    guard let from, let i = rows.firstIndex(of: from) else { return rows.first }
    return rows[min(max(i + delta, 0), rows.count - 1)]
}

/// Where the highlight is after a refresh (Rule 6, R6).
/// - Still listed: it stays.
/// - Its file is still in its root but in another group (`git add`): it follows the file, to the
///   first such row in step order.
/// - Its file is gone: it moves to the root's next row in step order, else the last.
/// - Its root has nothing left: nil.
/// - Its root not read yet (absent, or loading with no files): kept, since nothing says it went.
public func editorChangesResolve(_ highlight: EditorChangesRow?, roots: [GitRootState]) -> EditorChangesRow? {
    guard let h = highlight else { return nil }
    guard let r = roots.first(where: { $0.root == h.root }), !(r.loading && r.files.isEmpty) else { return h }
    let rows = editorChangesRows(of: r)
    if rows.contains(h) { return h }
    if let moved = rows.first(where: { $0.path == h.path }) { return moved }
    guard !rows.isEmpty else { return nil }
    return rows.first(where: { editorChangesPrecedes(h, $0) }) ?? rows.last
}

/// Where the highlight goes when a group closes over it (3a-ii): kept when it is still drawn (or
/// nil); else its root's next drawn row in step order, else the drawn row before it, else nil — so
/// a highlight is never left on a row the view does not draw, and never jumps to another root.
public func editorChangesShown(_ highlight: EditorChangesRow?, roots: [GitRootState], closed: Set<String>,
                               closedGroups: Set<EditorChangesGroup>) -> EditorChangesRow? {
    guard let h = highlight else { return nil }
    let drawn = Set(editorChangesRows(roots, closed: closed, closedGroups: closedGroups))
    guard !drawn.contains(h), let r = roots.first(where: { $0.root == h.root }) else { return h }
    let rows = editorChangesRows(of: r)
    return rows.first { drawn.contains($0) && editorChangesPrecedes(h, $0) }
        ?? rows.last { drawn.contains($0) && editorChangesPrecedes($0, h) }
}

/// Closed groups in the order the view draws them: by root, then merge changes, staged, changes, untracked.
public func editorChangesSortedGroups(_ groups: Set<EditorChangesGroup>) -> [EditorChangesGroup] {
    groups.sorted { a, b in
        if a.root != b.root { return a.root.utf8.lexicographicallyPrecedes(b.root.utf8) }
        return editorChangesRank(a.group) < editorChangesRank(b.group)
    }
}

/// The status row a Changes row names, or nil when it is not in that group now.
public func editorChangesFile(_ row: EditorChangesRow, in roots: [GitRootState]) -> GitFileRow? {
    roots.first { $0.root == row.root }?.files.first { $0.path == row.path && $0.group.rawValue == row.group }
}

/// The letter a Files tree row shows at its right edge, or nil for an unchanged file. A file both
/// staged and changed shows its working-tree letter: a conflict's `U` first, then Changes, Untracked, Staged.
public func editorTreeStatus(root: String, relative: String, roots: [GitRootState]) -> String? {
    guard let r = roots.first(where: { $0.root == root }) else { return nil }
    let rows = r.files.filter { $0.path == relative }
    for group in [GitGroup.conflicts, .changed, .untracked, .staged] {
        if let f = rows.first(where: { $0.group == group }) { return f.status }
    }
    return nil
}
