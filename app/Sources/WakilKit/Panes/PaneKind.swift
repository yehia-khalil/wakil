import Foundation

/// One kind of pane: what `PaneStore` holds for each pane of it, what it holds for the whole store,
/// and what readers get back (pluggable pane kinds). A kind's conformance and its store methods live
/// in its own folder, as `extension PaneStore`; `App/PaneKinds.swift` is the one list naming every
/// kind. `Panes/` names none.
public protocol PaneKind: SendableMetatype {
    /// One pane's state.
    associatedtype Contents: Sendable
    /// State this kind keeps for the whole store (Api: recent sends, flight subscribers, the
    /// resolution mark). `Void` for most kinds.
    associatedtype Shared: Sendable = Void
    /// What a reader gets for one pane.
    associatedtype Snapshot: PaneKindSnapshot

    /// The `Pane.kind` strings this kind serves.
    static var names: [String] { get }
    static var emptyContents: Contents { get }
    static var emptyShared: Shared { get }
    /// What a pane of this kind that was never written answers; `nil` answers no contents at all
    /// (settings, whose `read_pane` is built from the config tree instead).
    static var emptySnapshot: Snapshot? { get }
    /// Whether a restored pane of this kind re-runs its subject (a read). Never true for a kind whose
    /// subject can be a write: an api pane's last request may have been a `POST`.
    static var rerunsSubjectOnRestore: Bool { get }

    static func snapshot(of contents: Contents, in store: isolated PaneStore) -> Snapshot
    static func failure(of contents: Contents) -> String?
    /// What the agent's `read_pane` sees for this kind, merged into the envelope (`kind`,
    /// `failure`); store-isolated because Api's previews read data-surface rows (#192).
    /// **Every key of the kind is always present**, including when false, empty or null, unless
    /// the kind's own doc says otherwise.
    static func readPane(_ snapshot: Snapshot, in store: isolated PaneStore) -> [String: JSONValue]
    /// `switchScope(to:)` calls this on the kind's store-wide state.
    static func sharedAfterSwitchingScope(_ shared: Shared) -> Shared
    /// `switchScope(to:adoptingFrom:)` calls this: `outgoing`'s panes are now `incoming`'s.
    static func sharedAfterAdoptingScope(_ shared: Shared, from outgoing: LayoutScope, to incoming: LayoutScope) -> Shared
}

extension PaneKind {
    public static var rerunsSubjectOnRestore: Bool { false }
    public static func failure(of contents: Contents) -> String? { nil }
    public static func sharedAfterSwitchingScope(_ shared: Shared) -> Shared { shared }
    public static func sharedAfterAdoptingScope(
        _ shared: Shared, from outgoing: LayoutScope, to incoming: LayoutScope
    ) -> Shared { shared }
}

extension PaneKind where Shared == Void {
    public static var emptyShared: Void { () }
}

/// A pane kind's snapshot. Equality across kinds is false.
public protocol PaneKindSnapshot: Sendable, Equatable {}

extension PaneKindSnapshot {
    func isEqual(to other: any PaneKindSnapshot) -> Bool { (other as? Self) == self }
}

/// One pane in `PaneStore`: which kind holds it, and that kind's contents, held opaquely.
struct PaneSlot {
    let kind: any PaneKind.Type
    var contents: any Sendable
    var kindID: ObjectIdentifier { ObjectIdentifier(kind) }
}
