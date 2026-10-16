import Foundation

// The Changes view's rows and the choices behind them (3b-iii), pure, because WakilApp has no test
// target. The status is the window's (`GitStatus`); the highlight and collapsed roots are the pane's.

private func editorChangesRank(_ group: String) -> Int {
    switch GitGroup(rawValue: group) {
    case .staged?: 0
    case .changed?: 1
    case .untracked?, nil: 2
    }
}

/// Step order within one root: staged, changes, untracked, then path in byte order.
private func editorChangesPrecedes(_ a: EditorChangesRow, _ b: EditorChangesRow) -> Bool {
    let ra = editorChangesRank(a.group), rb = editorChangesRank(b.group)
    if ra != rb { return ra < rb }
    return a.path.utf8.lexicographicallyPrecedes(b.path.utf8)
}

private func editorChangesRows(of r: GitRootState) -> [EditorChangesRow] {
    r.files.map { EditorChangesRow(root: r.root, path: $0.path, group: $0.group.rawValue) }
        .sorted(by: editorChangesPrecedes)
}

/// Every row the view draws, in step order: roots in project order, a collapsed root's rows left
/// out, then staged, changes, untracked, then path.
public func editorChangesRows(_ roots: [GitRootState], closed: Set<String>) -> [EditorChangesRow] {
    roots.filter { !closed.contains($0.root) }.flatMap(editorChangesRows(of:))
}

/// The row `delta` away from `from` among the drawn rows, clamped at both ends; the first row when
/// `from` is nil or not drawn; nil when nothing is drawn.
public func editorChangesStep(_ roots: [GitRootState], closed: Set<String>, from: EditorChangesRow?,
                              by delta: Int) -> EditorChangesRow? {
    let rows = editorChangesRows(roots, closed: closed)
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

/// The status row a Changes row names, or nil when it is not in that group now.
public func editorChangesFile(_ row: EditorChangesRow, in roots: [GitRootState]) -> GitFileRow? {
    roots.first { $0.root == row.root }?.files.first { $0.path == row.path && $0.group.rawValue == row.group }
}

/// The letter a Files tree row shows at its right edge, or nil for an unchanged file. A file both
/// staged and changed shows its working-tree letter: Changes, then Untracked, then Staged.
public func editorTreeStatus(root: String, relative: String, roots: [GitRootState]) -> String? {
    guard let r = roots.first(where: { $0.root == root }) else { return nil }
    let rows = r.files.filter { $0.path == relative }
    for group in [GitGroup.changed, .untracked, .staged] {
        if let f = rows.first(where: { $0.group == group }) { return f.status }
    }
    return nil
}
