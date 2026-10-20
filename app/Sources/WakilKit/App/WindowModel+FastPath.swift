import Foundation

extension WindowModel {
    /// What the fast path's model may name for `line` (spec §The prompt and the scope): the top 20
    /// file matches by ⌘P's matcher, and every project, environment, table, open pane and api entry.
    public func fastPathScope(for line: String) async -> FastPathScope {
        let entries = await paletteFilesSource()?.entries() ?? []
        let files = Self.fastPathFiles(for: line, in: entries)
        let environments = settings?.projects.first { $0.name == project }?.environments.map(\.name) ?? []
        var seen = Set<String>()
        let tables = (await vocabulary?.current().names ?? [])
            .filter { $0.kind == .table }.map(\.text).filter { seen.insert($0).inserted }
        return FastPathScope(
            files: files, roots: rootPaths, projects: await listProjects().map(\.name),
            environments: environments, activeEnvironment: environment, tables: tables,
            panes: layoutSnapshot.panes.map { FastPathPane(id: $0.id, kind: $0.kind, title: $0.title) },
            apiEntries: (await apiListing(http: paletteClients.http))?.map(\.name) ?? [])
    }

    /// `rank` wants every word to match, and a line leads with a verb no file name holds, so each
    /// word is ranked alone and the lists are dealt out in turn: the best match of each word
    /// first, the same entry once, 20 in all.
    static func fastPathFiles(for line: String, in entries: [PaletteEntry]) -> [String] {
        let lists = line.split(whereSeparator: \.isWhitespace).map { word in
            PaletteSearch.rank(entries, query: String(word)).compactMap { entry -> String? in
                if case .openInEditor(let path) = entry.action { return path } else { return nil }
            }
        }
        var seen = Set<String>()
        var out: [String] = []
        var depth = 0
        while out.count < 20, lists.contains(where: { depth < $0.count }) {
            for list in lists where depth < list.count && out.count < 20 {
                if seen.insert(list[depth]).inserted { out.append(list[depth]) }
            }
            depth += 1
        }
        return out
    }

    /// The registry schema of each allowed action.
    public func fastPathSchemas() async -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for name in FastPath.allowed.keys {
            if let d = await registry.descriptor(named: name) { out[name] = d.schema }
        }
        return out
    }
}
