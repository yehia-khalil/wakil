import Foundation

/// A place's old names, a moment after it took a new one (`BrowserTabHost.rehome`): old name → new.
/// The canvas may still draw a pane under the old name for a turn; that pane is not the place on
/// screen. Pure, so the window's guard is pinned by tests (3d-iii).
public enum BrowserRenamedPlaces {
    /// `from` took the name `to`: every old name that led to `from` now leads to `to`, and a name that
    /// leads back to itself (renamed A → B → A) is no old name at all.
    public static func rehome(_ renamed: [LayoutScope: LayoutScope], from: LayoutScope, to: LayoutScope)
        -> [LayoutScope: LayoutScope] {
        guard from != to else { return renamed }
        var next = renamed.mapValues { $0 == from ? to : $0 }
        next[from] = to
        return next.filter { $0.key != $0.value }
    }

    /// A pane under `scope` is on screen: when `scope` is a new name, it is drawn, so its old names
    /// are let go (the transient window is over). Answers whether `scope` is still an old name — a
    /// pane drawn under it is ignored — and the map that remains.
    public static func drawn(_ scope: LayoutScope, renamed: [LayoutScope: LayoutScope])
        -> (isOldName: Bool, renamed: [LayoutScope: LayoutScope]) {
        let remaining = renamed.values.contains(scope) ? renamed.filter { $0.value != scope } : renamed
        return (remaining[scope] != nil, remaining)
    }
}
