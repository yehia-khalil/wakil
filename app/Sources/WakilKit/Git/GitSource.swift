import Foundation

/// The files the window's git status lists (3b-iii), as names the voice resolver can match: each
/// file's full path, and its base name without the extension (`BookingController`), which is the
/// form "booking controller" folds onto. It offers them while the window keeps the status, that is,
/// while an editor pane is open; before the first read there are none. A file in two groups (partly
/// staged) is one name.
public struct GitSource: IdentifierSource {
    public let kind = IdentifierSourceKind.panes
    public let name = "git"
    let status: GitStatus

    public init(status: GitStatus) {
        self.status = status
    }

    public func identifiers(for context: ContextStore.ActiveContext) async throws -> [Identifier] {
        var out: [Identifier] = []
        var seen = Set<Identifier>()
        func add(_ text: String, _ origin: String) {
            guard !text.isEmpty else { return }
            let id = Identifier(text: text, kind: .file, origin: origin, source: .panes)
            if seen.insert(id).inserted { out.append(id) }
        }
        for root in await status.roots {
            let origin = "git · \(root.name)"
            for file in root.files {
                add(file.path, origin)
                let base = ((file.path as NSString).lastPathComponent as NSString).deletingPathExtension
                add(base, origin)
            }
        }
        return out
    }
}
