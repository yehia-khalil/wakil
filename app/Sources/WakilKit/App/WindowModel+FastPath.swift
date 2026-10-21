import Foundation

extension WindowModel {
    /// What the fast path's model may name for `line` (spec §The prompt and the scope): the top 20
    /// file matches by ⌘P's matcher, and every project, environment, database, table, open pane and api entry.
    /// Read from what the window holds — no dispatch, so a line journals nothing and leaves the
    /// status line alone (Rule 8).
    public func fastPathScope(for line: String) async -> FastPathScope {
        let files = Self.fastPathFiles(for: line, in: await fastPathFileEntries())
        let environments = settings?.projects.first { $0.name == project }?.environments.map(\.name) ?? []
        var seen = Set<String>()
        let tables = (await vocabulary?.current().names ?? [])
            .filter { $0.kind == .table }.map(\.text).filter { seen.insert($0).inserted }
        return FastPathScope(
            files: files, roots: rootPaths, projects: settings?.projects.map(\.name) ?? [],
            environments: environments, activeEnvironment: environment,
            // The query line's list, refreshed with the context: the settings tree is read only
            // once Settings opens, and the walk's first line found it empty (3b-ix walk).
            databases: databases, tables: tables,
            panes: layoutSnapshot.panes.map { FastPathPane(id: $0.id, kind: $0.kind, title: $0.title) },
            apiEntries: (await apiListing(http: paletteClients.http))?.map(\.name) ?? [])
    }

    /// ⌘P's file rows, from the listings the trees already hold; a `files_list` per root only when
    /// the window holds none.
    func fastPathFileEntries() async -> [PaletteEntry] {
        let held = gitRootPaths.compactMap { editorFiles.listings[$0] }.filter { $0.error == nil }
        guard !held.isEmpty else { return await paletteFilesSource()?.entries() ?? [] }
        let withIgnored = editorSettings.app.showIgnored
        return held.flatMap { FilesSource.rows(root: $0.root, files: $0.files, ignored: withIgnored ? $0.ignored : []) }
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
/// refusal whole. "Ask the agent instead" re-sends `line` to `scope`, the place it was typed in,
/// with its `source` (the composer stamps both).
public struct FastPathReceipt: Sendable, Equatable {
    public var line: String
    public var text: String
    public var refused: Bool
    public var scope: WindowModel.TurnScope?
    public var source: WindowModel.TurnSource
    public init(line: String, text: String, refused: Bool,
                scope: WindowModel.TurnScope? = nil, source: WindowModel.TurnSource = .typed) {
        self.line = line; self.text = text; self.refused = refused; self.scope = scope; self.source = source
    }
}

public enum FastPathOutcome: Sendable, Equatable { case ran(FastPathReceipt), refused(FastPathReceipt), toAgent }

extension WindowModel {
    nonisolated static let fastPathLocalDeadline: Duration = .milliseconds(400)
    nonisolated static let fastPathSessionDeadline: Duration = .milliseconds(2500)
    static let fastPathKeyboardHold: Duration = .milliseconds(1500)

    /// Asks the org's quick model whether `line` is one allowed action and, if every check holds,
    /// dispatches it as the operator's own click (Invariant 2). Anything else is `.toAgent`.
    /// `typed` is where the operator pressed Return (the composer reads it then): the action is
    /// theirs there, or not at all. The scope, the schemas and the model's answer all fit inside
    /// the deadline; the routed model alone is asked, never the session's as a fall-back.
    public func runFastPath(_ line: String, scope typed: TurnScope? = nil) async -> FastPathOutcome {
        let typedIn = (typed ?? turnScope).place
        guard fastPathEnabled, let tasks = quickTasks, place == typedIn else { return .toAgent }
        let generation = quickTasksGeneration
        let org = organization
        let deadline = await tasks.routedKind(.respond) == "local" ? Self.fastPathLocalDeadline : Self.fastPathSessionDeadline
        let route = await FastPath.within(deadline) { [self] in
            let scope = await fastPathScope(for: line)
            let schemas = await fastPathSchemas()
            return await FastPath.route(line, scope: scope, schemas: schemas, deadline: deadline) {
                try await tasks.respond($0, fallback: false)
            }
        } ?? .agent
        guard generation == quickTasksGeneration, org == organization, place == typedIn,
              case .action(let name, let params) = route else { return .toAgent }
        composerHoldsKeyboardUntil = .now + Self.fastPathKeyboardHold
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
        let database = p("database").isEmpty ? "" : " in \(p("database"))"
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
        case "db_read_table": said = "show \(p("table"))\(database)"
        case "db_describe_table": said = "describe \(p("table"))\(database)"
        case "db_list_tables": said = "list the tables\(database)"
        case "db_page":       // `to` is "next", "previous", "first" or a page number
            let to = p("to")
            said = to.isEmpty ? "next page" : Int(to) == nil ? "\(to) page" : "page \(to)"
        case "db_refetch": said = "refresh \(p("pane"))"
        case "pane_open": said = "open a \(p("kind")) pane"
        case "pane_focus": said = "focus \(p("id"))"
        case "pane_close": said = "close \(p("id"))"
        case "pane_maximize": said = "maximize \(p("id"))"
        case "pane_restore": said = "restore the layout"
        case "pane_sort": said = p("column").isEmpty ? "clear the sort" : "sort by \(p("column"))"
        case "term_open": said = "open a terminal"
        case "api_open": said = "open the \(p("entry")) api"
        case "settings_open": said = "open settings"
        default: said = action
        }
        return "Ran: \(said)"
    }
}

/// The ⓘ beside QUICK TASKS: what the two features do and, as plainly, what the fast path won't,
/// so an operator does not expect an edit or a query from it (3b-ix walk). Markdown, inline only;
/// the deadlines are the ones the fast path runs under, so the text cannot drift from them.
public var quickTasksAbout: String {
    func seconds(_ d: Duration) -> String {
        let ms = Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
        return String(format: "%g s", ms / 1000)
    }
    let local = seconds(WindowModel.fastPathLocalDeadline)
    let other = seconds(WindowModel.fastPathSessionDeadline)
    return """
    **Ghost-text** suggests the rest of the line as you type in the editor. Tab accepts it.

    **Fast path** runs a short command the moment you press Return, without the agent: "open checkout.go", "line 40", "switch to staging", "show tables in core". If it guessed wrong, click **Ask the agent instead**.

    It only opens, shows, switches and closes things Wakil knows (files, tables, panes, environments). It never edits, queries or runs commands, and does one thing per line. Anything else, or a model slower than \(local) (\(other) if not local), goes to the agent.

    Best with a local model. On *Same as agent* it is off by default, since every line would wait for Claude first.
    """
}
