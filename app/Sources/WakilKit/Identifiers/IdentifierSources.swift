import Foundation

/// Answers "which names are in scope for this context?" — the seam Jira
/// keys (2c-vi) and the editor (Phase 3) plug into later.
public protocol IdentifierSource: Sendable {
    var kind: IdentifierSourceKind { get }
    /// For the journal: which source failed.
    var name: String { get }
    func identifiers(for context: ContextStore.ActiveContext) async throws -> [Identifier]
    /// The names, plus the parts of this source that failed while the rest
    /// answered (one root of several, one database of several). Throws
    /// only when nothing answered. `VocabularyStore` reads sources through
    /// this, so each partial failure is journalled whole (Interaction Rule 8).
    func gather(for context: ContextStore.ActiveContext) async throws -> IdentifierGathering
}

/// What one source answered: its names, and each failed part's whole reason.
public struct IdentifierGathering: Sendable {
    public let names: [Identifier]
    public let failures: [String]

    public init(names: [Identifier], failures: [String] = []) {
        self.names = names
        self.failures = failures
    }
}

extension IdentifierSource {
    /// A source with no parts either answers whole or throws.
    public func gather(for context: ContextStore.ActiveContext) async throws -> IdentifierGathering {
        IdentifierGathering(names: try await identifiers(for: context))
    }
}

/// Wakil's own names: registered actions, and the active org, project
/// and environment. The capability servers' tool names are not known in
/// Swift, so they are not here (spec, corrected 2026-10-06).
public struct WakilSource: IdentifierSource {
    public let kind = IdentifierSourceKind.wakil
    public let name = "wakil"
    let registry: ActionRegistry

    public init(registry: ActionRegistry) { self.registry = registry }

    public func identifiers(for context: ContextStore.ActiveContext) async throws -> [Identifier] {
        var out = await registry.all().map {
            Identifier(text: $0.name, kind: .action, origin: "wakil", source: .wakil)
        }
        out.append(Identifier(text: context.org, kind: .org, origin: "wakil", source: .wakil))
        out.append(Identifier(text: context.project, kind: .project, origin: context.org, source: .wakil))
        out.append(Identifier(text: context.environment, kind: .environment,
                              origin: "\(context.org) · \(context.project)", source: .wakil))
        return out.filter { !$0.text.isEmpty }
    }
}

/// A pane kind's snapshot that offers names to the vocabulary (`PaneSource`). Conform in the kind's
/// own folder; a kind that offers none (git: `GitSource` reads repositories instead) does not.
public protocol OffersIdentifiers {
    func identifiers(origin: String) -> [Identifier]
}

/// The data surface conforms here rather than in `Panes/`, because `Panes -> Identifiers` would make
/// a new mutual pair.
extension DataSurfaceSnapshot: OffersIdentifiers {
    public func identifiers(origin: String) -> [Identifier] {
        var out: [Identifier] = []
        if let table = editable?.table {
            out.append(Identifier(text: table, kind: .table, origin: origin, source: .panes))
        }
        out += columns.map { Identifier(text: $0, kind: .column, origin: origin, source: .panes) }
        return out
    }
}

/// What is on screen: open panes' tables and columns, terminals' working
/// directories, api panes' endpoints.
public struct PaneSource: IdentifierSource {
    public let kind = IdentifierSourceKind.panes
    public let name = "panes"
    let layout: LayoutStore
    let panes: PaneStore

    public init(layout: LayoutStore, panes: PaneStore) {
        self.layout = layout
        self.panes = panes
    }

    public func identifiers(for context: ContextStore.ActiveContext) async throws -> [Identifier] {
        var out: [Identifier] = []
        for pane in await layout.snapshot().panes {
            let origin = "pane · \(pane.title)"
            let contents = await panes.snapshot(paneId: pane.id, kind: pane.kind).contents
            if let offering = contents as? any OffersIdentifiers { out += offering.identifiers(origin: origin) }
        }
        return out.filter { !$0.text.isEmpty }
    }
}
