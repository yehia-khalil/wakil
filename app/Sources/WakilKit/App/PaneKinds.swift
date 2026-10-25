import Foundation

/// Every pane kind this build knows — the one place they are all named (`App/` may use every folder).
/// `WakilWiring.build` hands it to `PaneStore(kinds:)`. A new kind adds one line here
/// (`CONTRIBUTING.md`, "A new pane kind").
enum PaneKinds {
    static let standard: [any PaneKind.Type] = [
        DataSurfacePaneKind.self,
        TerminalPaneKind.self,
        ApiPaneKind.self,
        SettingsPaneKind.self,
        EditorPaneKind.self,
        BrowserPaneKind.self,
    ]

    static func kind(named name: String) -> (any PaneKind.Type)? {
        standard.first { $0.names.contains(name) }
    }

    /// Whether `name` is served by `kind`.
    static func `is`(_ name: String, _ kind: any PaneKind.Type) -> Bool {
        Self.kind(named: name).map { ObjectIdentifier($0) == ObjectIdentifier(kind) } ?? false
    }
}

extension DataSurfacePaneKind: PaneRestorable {
    /// D12: a refetch that failed must not leave the pane looking empty, so its refusal is recorded.
    static func restoreStep(for pane: Pane) -> PaneRestoreStep? {
        guard pane.fetch != nil else { return nil }
        return PaneRestoreStep(action: "db_refetch", params: .object(["pane": .string(pane.id)]), recordsFailure: true)
    }
}
