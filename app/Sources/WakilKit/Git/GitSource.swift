import Foundation

/// The files a git pane lists, as names the voice resolver can match: each file's full
/// path, and its base name without the extension (`BookingController`), which is the form
/// "booking controller" folds onto. `PaneSource` emits nothing for a git pane, so the two
/// never double-emit. A file in two groups (partly staged) is one name.
public struct GitSource: IdentifierSource {
    public let kind = IdentifierSourceKind.panes
    public let name = "git"
    let layout: LayoutStore
    let panes: PaneStore

    public init(layout: LayoutStore, panes: PaneStore) {
        self.layout = layout
        self.panes = panes
    }

    public func identifiers(for context: ContextStore.ActiveContext) async throws -> [Identifier] {
        var out: [Identifier] = []
        var seen = Set<Identifier>()
        func add(_ text: String, _ origin: String) {
            guard !text.isEmpty else { return }
            let id = Identifier(text: text, kind: .file, origin: origin, source: .panes)
            if seen.insert(id).inserted { out.append(id) }
        }
        for pane in await layout.snapshot().panes where pane.kind == "git" {
            for root in await panes.gitSnapshot(paneId: pane.id).roots {
                let origin = "git · \(root.name)"
                for file in root.files {
                    add(file.path, origin)
                    let base = ((file.path as NSString).lastPathComponent as NSString).deletingPathExtension
                    add(base, origin)
                }
            }
        }
        return out
    }
}
