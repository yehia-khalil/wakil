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

/// What the composer shows after a fast-path line: the operator's words, and either what ran or the
/// refusal whole. "Ask the agent instead" re-sends `line`.
public struct FastPathReceipt: Sendable, Equatable {
    public var line: String
    public var text: String
    public var refused: Bool
    public init(line: String, text: String, refused: Bool) { self.line = line; self.text = text; self.refused = refused }
}

public enum FastPathOutcome: Sendable, Equatable { case ran(FastPathReceipt), refused(FastPathReceipt), toAgent }

extension WindowModel {
    static let fastPathLocalDeadline: Duration = .milliseconds(300)
    static let fastPathSessionDeadline: Duration = .milliseconds(2500)

    /// Asks the org's quick model whether `line` is one allowed action and, if every check holds,
    /// dispatches it as the operator's own click (Invariant 2). Anything else is `.toAgent`.
    public func runFastPath(_ line: String) async -> FastPathOutcome {
        guard fastPathEnabled, let tasks = quickTasks else { return .toAgent }
        let generation = quickTasksGeneration
        let org = organization
        let typedIn = place     // where the operator pressed Return: the action is theirs there, or not at all
        let scope = await fastPathScope(for: line)
        let schemas = await fastPathSchemas()
        let deadline = await tasks.routedKind(.respond) == "local" ? Self.fastPathLocalDeadline : Self.fastPathSessionDeadline
        let route = await FastPath.route(line, scope: scope, schemas: schemas, deadline: deadline) { try await tasks.respond($0) }
        guard generation == quickTasksGeneration, org == organization, place == typedIn,
              case .action(let name, let params) = route else { return .toAgent }
        do {
            _ = try await registry.dispatch(
                name: name, params: params, origin: .ui,
                caller: DispatchCaller(place: typedIn, session: nil, via: "fastPath"), confirmation: nil)
            return .ran(FastPathReceipt(line: line, text: Self.fastPathReceiptText(action: name, params: params), refused: false))
        } catch {
            return .refused(FastPathReceipt(line: line, text: statusDescribingFailure(name, error), refused: true))
        }
    }

    /// The receipt's words for an action and its params.
    public static func fastPathReceiptText(action: String, params: JSONValue) -> String {
        func p(_ k: String) -> String {
            guard case .object(let o) = params, let v = o[k] else { return "" }
            switch v {
            case .string(let s): return s
            case .integer(let n): return String(n)
            case .number(let n): return String(n)
            default: return ""
            }
        }
        let file = (p("path") as NSString).lastPathComponent
        let said: String
        switch action {
        case "editor_open": said = "open \(file)"
        case "editor_goto": said = "go to line \(p("line"))"
        case "editor_search": said = "search for \(p("query"))"
        case "editor_find": said = "find \(p("query"))"
        case "editor_tree_reveal": said = "reveal \(file)"
        case "editor_new_scratch": said = "new scratch tab"
        case "editor_close": said = "close \(file)"
        case "editor_focus_tab": said = "switch tab"
        case "editor_changes_select": said = "show the changes in \(file)"
        case "editor_set_language": said = "set the language to \(p("language"))"
        case "ctx_set_environment": said = "switch environment to \(p("name"))"
        case "ctx_set_project": said = "switch project to \(p("name"))"
        case "db_read_table": said = "show \(p("table"))"
        case "db_describe_table": said = "describe \(p("table"))"
        case "db_list_tables": said = "list the tables"
        case "db_page": said = "page \(p("to"))"
        case "db_refetch": said = "refresh \(p("pane"))"
        case "pane_open": said = "open a \(p("kind")) pane"
        case "pane_focus": said = "focus \(p("id"))"
        case "pane_close": said = "close \(p("id"))"
        case "pane_maximize": said = "maximize \(p("id"))"
        case "pane_restore": said = "restore the layout"
        case "pane_sort": said = "sort by \(p("column"))"
        case "term_open": said = "open a terminal"
        case "api_open": said = "open the \(p("entry")) api"
        case "settings_open": said = "open settings"
        default: said = action
        }
        return "Ran: \(said)"
    }
}
