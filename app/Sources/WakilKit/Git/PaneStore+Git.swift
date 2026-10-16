import Foundation

// The git kind's store methods (pluggable pane kinds): same actor, same names as before.
extension PaneStore {
    /// The git pane's snapshot for `paneId`, or the empty one — on the same
    /// terms as `api(_:)`: a pane of another kind answers empty.
    public func gitSnapshot(paneId: String) -> GitSnapshot { contents(GitPaneKind.self, paneId) }

    /// Replaces a git pane's snapshot. A pane of another kind has the write
    /// discarded rather than its contents corrupted.
    public func setGit(paneId: String, _ snapshot: GitSnapshot) { setContents(GitPaneKind.self, paneId, snapshot) }

    /// Reads, changes and writes a git pane's snapshot in one turn on this
    /// actor, returning whatever `change` returns. The git actions write
    /// from several tasks at once — a refresh, a diff landing, a select —
    /// and a `gitSnapshot` then `setGit` pair would let one undo another
    /// across the await between them. A pane of another kind is left alone
    /// and `change` sees a scratch copy.
    ///
    /// **Nor is an entry made for a pane this store holds nothing for, unless
    /// `create` says so** (final review, item 8). A diff or a read landing after
    /// its pane closed (`drop(paneId:)`) would otherwise bring the closed pane's
    /// entry back, held for the life of the process. Only the start of an action
    /// whose handler has just found the pane open — a refresh marking its roots
    /// loading, a select — creates; everything that lands later only updates.
    @discardableResult
    public func updateGit<T: Sendable>(
        paneId: String, create: Bool = false, _ change: @Sendable (inout GitSnapshot) -> T
    ) -> T {
        var s = gitSnapshot(paneId: paneId)
        let result = change(&s)
        if holdsContents(paneId: paneId) || create { setGit(paneId: paneId, s) }
        return result
    }
}
