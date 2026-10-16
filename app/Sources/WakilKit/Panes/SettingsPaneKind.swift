import Foundation

/// The settings pane. `PaneStore` never holds contents for it: everything it draws is re-read from
/// disk on open (Decision 30), and `read_pane` answers for it from the config tree
/// (`MCPServer.readPane`). It is a kind so that its name is known and it never re-runs on restore.
enum SettingsPaneKind: PaneKind {
    struct Snapshot: PaneKindSnapshot {}
    static let names = ["settings"]
    static var emptyContents: Void { () }
    static var emptySnapshot: Snapshot? { nil }
    // `rerunsSubjectOnRestore` stays false, and cannot be otherwise: a settings pane is never written
    // to a layout file, so no restore ever reaches it. It holds no subject either; everything it
    // draws is re-read from disk on open, so staleness is structurally impossible (Decision 30).
    static func snapshot(of contents: Void, in store: isolated PaneStore) -> Snapshot { Snapshot() }
    /// Nothing: `MCPServer.readPane` answers a settings pane from the config tree.
    static func readPane(_ snapshot: Snapshot, in store: isolated PaneStore) -> [String: JSONValue] { [:] }
}
