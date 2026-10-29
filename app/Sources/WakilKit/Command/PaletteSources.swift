import Foundation

/// One ⌘P group's rows, read from wherever they live.
///
/// **Never throws.** A source that cannot answer contributes one `isError` row carrying the whole
/// error, and every other source still lists (rule 8): a database that refuses its connection
/// must not hide the open panes.
///
/// `group` is here, beyond the brief's `id` and `entries()`, because `openModeEntries` must place
/// a source's `loading…` row before the source has said anything.
public protocol PaletteSource: Sendable {
    /// "panes", "newPane", "tables", "apis", "changedFiles", "projects", "sessions", "providers".
    var id: String { get }
    var group: PaletteGroup { get }
    func entries() async -> [PaletteEntry]
}

// MARK: - Clients

/// The children the palette reads directly, drawing no pane: `wakil-db` for tables, `wakil-http`
/// for API entries, `wakil-git` for changed files while no editor pane keeps the window's status. A `nil` client's source
/// is left out, as an unwired action is.
public struct PaletteClients: Sendable {
    public var database: (any ToolCaller)?
    public var http: (any ToolCaller)?
    public var git: (any ToolCaller)?
    public var files: (any ToolCaller)?

    public init(database: (any ToolCaller)? = nil, http: (any ToolCaller)? = nil, git: (any ToolCaller)? = nil,
                files: (any ToolCaller)? = nil) {
        self.database = database
        self.http = http
        self.git = git
        self.files = files
    }
}

// MARK: - Open mode

/// Every source's rows, ordered by `PaletteGroup` (sources keep their own order within a group).
///
/// **Typing is never blocked by a slow source** (Review Focus 1). Every source runs at once; one
/// still running at `timeout` contributes a `loading…` row and this returns anyway. Each late
/// source that lands calls `onLate` with the **whole list again** — every source's rows so far,
/// `loading…` still standing for any that have not — so the caller swaps its root list in one
/// move (`PaletteModel.contextChanged`) rather than merging.
///
/// A `loading…` row is `isError`: it is shown, but Return on it runs nothing.
public func openModeEntries(
    _ sources: [any PaletteSource], timeout: Duration = .milliseconds(800),
    onLate: @escaping @Sendable ([PaletteEntry]) -> Void = { _ in }
) async -> [PaletteEntry] {
    let collector = SourceCollector(sources: sources.map { ($0.id, $0.group) }, onLate: onLate)
    for (index, source) in sources.enumerated() {
        Task { await collector.finish(index, await source.entries()) }
    }
    let timer = Task {
        try? await Task.sleep(for: timeout)
        await collector.timeUp()
    }
    await collector.waitForAllOrTimeout()
    timer.cancel()
    return await collector.release()
}

/// The shared state of one `openModeEntries` call: which sources have answered, and whether the
/// first list has gone out (after which an answer is late and goes to `onLate`).
private actor SourceCollector {
    private let sources: [(id: String, group: PaletteGroup)]
    private let onLate: @Sendable ([PaletteEntry]) -> Void
    private var results: [Int: [PaletteEntry]] = [:]
    private var released = false
    private var expired = false
    private var waiter: CheckedContinuation<Void, Never>?

    init(sources: [(id: String, group: PaletteGroup)], onLate: @escaping @Sendable ([PaletteEntry]) -> Void) {
        self.sources = sources
        self.onLate = onLate
    }

    private var allIn: Bool { results.count == sources.count }

    func finish(_ index: Int, _ rows: [PaletteEntry]) {
        results[index] = rows
        if released {
            onLate(merged())
        } else if allIn {
            wake()
        }
    }

    func timeUp() {
        expired = true
        wake()
    }

    func waitForAllOrTimeout() async {
        guard !allIn, !expired else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func release() -> [PaletteEntry] {
        released = true
        return merged()
    }

    private func wake() {
        waiter?.resume()
        waiter = nil
    }

    private func merged() -> [PaletteEntry] {
        let rows = sources.indices.flatMap { i in
            results[i] ?? [loadingEntry(sourceId: sources[i].id, group: sources[i].group)]
        }
        return rows.enumerated()
            .sorted { ($0.element.group, $0.offset) < ($1.element.group, $1.offset) }
            .map(\.element)
    }
}

private func loadingEntry(sourceId: String, group: PaletteGroup) -> PaletteEntry {
    PaletteEntry(id: "loading:\(sourceId)", group: group, title: "loading…", subtitle: group.label,
                 kindLabel: "", verb: "", action: noAction, isError: true)
}

/// An error row: shown whole, never run (`PaletteModel.confirm` refuses `isError` rows).
private func errorEntry(
    id: String, group: PaletteGroup, title: String, error: String, kindLabel: String
) -> PaletteEntry {
    PaletteEntry(id: "error:\(id)", group: group, title: title, subtitle: error, kindLabel: kindLabel,
                 verb: "", action: noAction, isError: true)
}

/// The action an unrunnable row carries. Nothing dispatches it: only `isError` rows hold it.
private let noAction = PaletteAction.dispatch(action: "", params: .null)

// MARK: - Open panes

/// One open pane as ⌘P reads it: its identity plus what it holds.
public struct PaneSummary: Sendable, Equatable {
    public let id: String
    public let kind: String
    public let title: String
    /// db: the table, else the database; api: the entry; terminal: the cwd.
    public let holds: String

    public init(id: String, kind: String, title: String, holds: String) {
        self.id = id
        self.kind = kind
        self.title = title
        self.holds = holds
    }

    /// `apiEntry` lives in `PaneStore`, not on the pane, so the caller reads it.
    public init(pane: Pane, apiEntry: String? = nil) {
        let holds: String
        switch pane.kind {
        case "db":
            switch pane.fetch?.query {
            case .table(_, let name)?, .columns(_, let name)?: holds = name
            case let query?: holds = query.database ?? ""
            case nil: holds = ""
            }
        case "terminal": holds = pane.terminalPath ?? ""
        case "api": holds = apiEntry ?? ""
        default: holds = ""
        }
        self.init(id: pane.id, kind: pane.kind, title: pane.title, holds: holds)
    }
}

/// Open panes: Return focuses the pane.
public struct OpenPanesSource: PaletteSource {
    public let id = "panes"
    public let group = PaletteGroup.openPanes
    private let panes: @Sendable () async -> [PaneSummary]

    public init(panes: @escaping @Sendable () async -> [PaneSummary]) {
        self.panes = panes
    }

    public func entries() async -> [PaletteEntry] {
        await panes().map { p in
            PaletteEntry(id: "pane:\(p.id)", group: group, title: p.title, subtitle: p.holds,
                         kindLabel: p.kind, verb: "open", action: .focusPane(id: p.id))
        }
    }
}

// MARK: - Running

/// Every live conversation, across every place (conversations 2 of 3): Return switches to it —
/// the same session, brought on screen, no fork and no cost (`session_switch`).
public struct RunningConversationsSource: PaletteSource {
    public let id = "running"
    public let group = PaletteGroup.running
    private let conversations: @Sendable () async -> [LiveConversation]

    public init(conversations: @escaping @Sendable () async -> [LiveConversation]) {
        self.conversations = conversations
    }

    public func entries() async -> [PaletteEntry] {
        await conversations().map { c in
            PaletteEntry(
                id: "running:\(c.id)", group: group, title: c.title,
                subtitle: "\(c.placeLabel) \u{00b7} \(c.state.rawValue)", kindLabel: "conversation",
                verb: "switch to",
                action: .dispatch(action: "session_switch", params: .object(["conversation": .string(c.id)])),
                isProduction: c.isProduction, state: c.state,
                // Names, Calls made 11: ⌘R on the row, the name step for its conversation.
                rename: conversationRename(id: c.id, current: c.title, fallback: c.fallbackTitle))
        }
    }
}

/// The name step's subject for a live conversation (names, Calls made 10–12): `conversation_rename`
/// with its id, so the reply's `renaming` is that id wherever the operator is when it runs.
public func conversationRename(id: String, current: String, fallback: String) -> PaletteRename {
    PaletteRename(
        action: "conversation_rename", params: .object(["conversation": .string(id)]),
        current: current, fallback: fallback, placeholder: conversationNamePlaceholder)
}

/// The name step's placeholder for a conversation, ⌘K's and ⌘P's alike.
public let conversationNamePlaceholder = "Conversation name"

/// The name step's subject for a browser tab (names, spec §3 and Calls made 12): `browser_rename_tab`
/// with its pane and tab, so the rename lands on that tab and selects nothing (Rule 6). `current` is the
/// tab's `label`, `fallback` its `pageLabel`.
public func tabRename(pane: String, tab: String, current: String, fallback: String) -> PaletteRename {
    PaletteRename(
        action: "browser_rename_tab", params: .object(["pane": .string(pane), "tab": .string(tab)]),
        current: current, fallback: fallback, placeholder: tabNamePlaceholder)
}

/// The name step's placeholder for a browser tab, ⌘K's and a tile's alike.
public let tabNamePlaceholder = "Tab name"

// MARK: - New pane

/// The kinds the palette may open, in the order they are offered. `pane_open` refuses
/// `settings`, so it is never one.
private let paneKindOrder = ["db", "terminal", "api", "editor", "browser"]

private func offeredKinds(_ kinds: Set<String>) -> [String] {
    let offered = kinds.subtracting([Pane.settingsKind])
    return paneKindOrder.filter(offered.contains) + offered.subtracting(paneKindOrder).sorted()
}

/// The operator's name for a kind — the pane-kind choice row's title.
public func paneKindTitle(kind: String) -> String {
    switch kind {
    case "db": "Database"
    case "terminal": "Terminal"
    case "api": "API client"
    case "editor": "Editor"
    case "browser": "Browser"
    default: kind
    }
}

/// The new-pane row's title. A kind this table does not know still gets a row.
public func newPaneTitle(kind: String) -> String {
    switch kind {
    case "db": "New Database pane"
    case "terminal": "New Terminal"
    case "api": "New API client"
    case "editor": "New Editor pane"
    case "browser": "New Browser pane"
    default: "New \(kind) pane"
    }
}

/// One row per kind in `kinds` except `settings`, so a kind added to `Pane.kinds` appears here
/// with no palette change.
public func newPaneEntries(kinds: Set<String> = Pane.kinds) -> [PaletteEntry] {
    offeredKinds(kinds).map { kind in
        PaletteEntry(id: "newpane:\(kind)", group: .newPane, title: newPaneTitle(kind: kind),
                     subtitle: "", kindLabel: kind, verb: "open",
                     action: .dispatch(action: "pane_open", params: .object(["kind": .string(kind)])))
    }
}

public struct NewPaneSource: PaletteSource {
    public let id = "newPane"
    public let group = PaletteGroup.newPane
    private let kinds: Set<String>

    public init(kinds: Set<String> = Pane.kinds) {
        self.kinds = kinds
    }

    public func entries() async -> [PaletteEntry] { newPaneEntries(kinds: kinds) }
}

// MARK: - Tables

/// The window's table listings, per environment and database, so a reopened ⌘P lists tables
/// without asking `wakil-db` again. A failure is never stored.
public actor TableCache {
    private var tableLists: [String: [String]] = [:]
    private var databaseLists: [String: [String]] = [:]

    public init() {}

    public func tables(env: String, database: String) -> [String]? { tableLists[key(env, database)] }

    public func store(env: String, database: String, tables: [String]) {
        tableLists[key(env, database)] = tables
    }

    public func databases(env: String) -> [String]? { databaseLists[env] }

    public func storeDatabases(env: String, _ names: [String]) { databaseLists[env] = names }

    public func clear() {
        tableLists = [:]
        databaseLists = [:]
    }

    private func key(_ env: String, _ database: String) -> String { "\(env)\u{0}\(database)" }
}

/// Database tables: one drill row per database, then its tables.
///
/// Calls `wakil-db`'s `list_databases` and `list_tables` directly, the tools `db_list_databases`
/// and `db_list_tables` call, without drawing a pane. Each database is listed on its own, so one
/// that fails is one whole-error row titled with its name and the rest still list.
///
/// `entries()` answers from the cache when it can; `refresh()` asks again and replaces it.
public struct TablesSource: PaletteSource {
    public let id = "tables"
    public let group = PaletteGroup.resources
    private let db: any ToolCaller
    private let environment: @Sendable () async -> String
    private let cache: TableCache

    public init(db: any ToolCaller, environment: @escaping @Sendable () async -> String, cache: TableCache) {
        self.db = db
        self.environment = environment
        self.cache = cache
    }

    public func entries() async -> [PaletteEntry] { await list(fresh: false) }

    /// Asks `wakil-db` again, ignoring the cache, and stores the answer.
    public func refresh() async -> [PaletteEntry] { await list(fresh: true) }

    /// A database row's drill step: that database's table rows. `nil` for a `commandId` that is
    /// not `drill:tables:<database>`, so the caller can try its other sources.
    public func drillEntries(commandId: String) async -> [PaletteEntry]? {
        let prefix = "drill:\(id):"
        guard commandId.hasPrefix(prefix) else { return nil }
        let database = String(commandId.dropFirst(prefix.count))
        let env = await environment()
        return rows(database: database, env: env, listing: await tables(database, env: env, fresh: false),
                    drillRow: false)
    }

    private func list(fresh: Bool) async -> [PaletteEntry] {
        let env = await environment()
        let databases: [String]
        switch await listDatabases(env: env, fresh: fresh) {
        case .success(let names): databases = names
        case .failure(let error):
            return [errorEntry(id: "databases", group: group, title: "Databases", error: error.text,
                               kindLabel: "database")]
        }
        let listings = await withTaskGroup(of: (Int, Result<[String], ListingError>).self) { tasks in
            for (i, database) in databases.enumerated() {
                tasks.addTask { (i, await tables(database, env: env, fresh: fresh)) }
            }
            var byIndex: [Int: Result<[String], ListingError>] = [:]
            for await (i, listing) in tasks { byIndex[i] = listing }
            return byIndex
        }
        return databases.enumerated().flatMap { i, database in
            rows(database: database, env: env, listing: listings[i]!, drillRow: true)
        }
    }

    private func rows(
        database: String, env: String, listing: Result<[String], ListingError>, drillRow: Bool
    ) -> [PaletteEntry] {
        switch listing {
        case .failure(let error):
            return [errorEntry(id: "db:\(database)", group: group, title: database, error: error.text,
                               kindLabel: "database")]
        case .success(let tables):
            let drill = PaletteEntry(
                id: "db:\(database)", group: group, title: database, subtitle: env, kindLabel: "database",
                verb: "open", action: .drill(sourceId: id, value: database))
            let tableRows = tables.map { table in
                PaletteEntry(
                    id: "table:\(database)/\(table)", group: group, title: table,
                    subtitle: "\(database) · \(env)", kindLabel: "table", verb: "open",
                    action: .dispatch(action: "db_read_table", params: .object([
                        "database": .string(database), "table": .string(table),
                    ])))
            }
            return (drillRow ? [drill] : []) + tableRows
        }
    }

    private func listDatabases(env: String, fresh: Bool) async -> Result<[String], ListingError> {
        if !fresh, let cached = await cache.databases(env: env) { return .success(cached) }
        let result = await call("list_databases", .object([:]))
        if case .success(let value) = result {
            let names = databaseNames(fromListResult: value)
            await cache.storeDatabases(env: env, names)
            return .success(names)
        }
        return result.map { _ in [] }
    }

    private func tables(_ database: String, env: String, fresh: Bool) async -> Result<[String], ListingError> {
        if !fresh, let cached = await cache.tables(env: env, database: database) { return .success(cached) }
        let result = await call("list_tables", .object(["database": .string(database)]))
        guard case .success(let value) = result else { return result.map { _ in [] } }
        let names = (containerListPaneContents(from: value)?.rows ?? []).compactMap { row -> String? in
            if case .string(let name)? = row.first { return name }
            return nil
        }
        await cache.store(env: env, database: database, tables: names)
        return .success(names)
    }

    private func call(_ tool: String, _ arguments: JSONValue) async -> Result<JSONValue, ListingError> {
        await checkedCall(db, tool: tool, arguments: arguments)
    }
}

/// A listing's failure, carried whole as the row's subtitle.
struct ListingError: Error {
    let text: String
}

/// `tool` on `client`, with a thrown transport failure and an `isError` result both turned into
/// the failure's whole text — the same two failures `StandardActions.callChecked` reads.
private func checkedCall(
    _ client: any ToolCaller, tool: String, arguments: JSONValue
) async -> Result<JSONValue, ListingError> {
    do {
        let result = try await client.callTool(
            name: tool, arguments: arguments, timeout: MCPClient.readReplyTimeout)
        if case .object(let obj) = result, case .bool(true)? = obj["isError"] {
            return .failure(ListingError(text: mcpErrorText(from: obj) ?? "\(tool) failed with no message"))
        }
        return .success(result)
    } catch {
        return .failure(ListingError(text: "\(tool): \(error)"))
    }
}

// MARK: - API entries

/// The active environment's API entries, from `wakil-http`'s `list_apis`. An environment that
/// declares none contributes no rows, so the group is hidden.
public struct ApiEntriesSource: PaletteSource {
    public let id = "apis"
    public let group = PaletteGroup.resources
    private let http: any ToolCaller
    private let environment: @Sendable () async -> String

    public init(http: any ToolCaller, environment: @escaping @Sendable () async -> String) {
        self.http = http
        self.environment = environment
    }

    public func entries() async -> [PaletteEntry] {
        let env = await environment()
        switch await checkedCall(http, tool: "list_apis", arguments: .object([:])) {
        case .failure(let error):
            return [errorEntry(id: id, group: group, title: "API entries", error: error.text, kindLabel: "api")]
        case .success(let result):
            return apiEntries(from: result).map { entry in
                PaletteEntry(id: "api:\(entry.name)", group: group, title: entry.name, subtitle: env,
                             kindLabel: "api", verb: "open",
                             action: .dispatch(action: "api_open", params: .object(["entry": .string(entry.name)])))
            }
        }
    }
}

// MARK: - Open tabs and bookmarks

/// One open browser tab as ⌘P shows it: the window has already chosen the title and subtitle.
public struct PaletteBrowserTab: Sendable, Equatable {
    public let pane: String
    public let tab: String
    public let title: String
    public let subtitle: String
    public init(pane: String, tab: String, title: String, subtitle: String) {
        self.pane = pane; self.tab = tab; self.title = title; self.subtitle = subtitle
    }
}

/// One bookmark as ⌘P shows it.
public struct PaletteBookmark: Sendable, Equatable {
    public let url: String
    public let title: String
    public let subtitle: String
    public init(url: String, title: String, subtitle: String) {
        self.url = url; self.title = title; self.subtitle = subtitle
    }
}

/// Every tab of every browser pane on the canvas. A row switches to the tab and focuses its pane.
public struct BrowserTabsSource: PaletteSource {
    public let id = "browsertabs"
    public let group = PaletteGroup.resources
    private let tabs: @Sendable () async -> [PaletteBrowserTab]

    public init(tabs: @escaping @Sendable () async -> [PaletteBrowserTab]) {
        self.tabs = tabs
    }

    public func entries() async -> [PaletteEntry] {
        await tabs().map { row in
            PaletteEntry(
                id: "browsertab:\(row.pane)/\(row.tab)", group: group, title: row.title,
                subtitle: row.subtitle, kindLabel: "tab", verb: "switch to",
                action: .dispatch(action: "browser_select_tab", params: .object([
                    "pane": .string(row.pane), "tab": .string(row.tab), "focus": .bool(true),
                ])))
        }
    }
}

/// The organisation's bookmarks, in the order given (newest first). A row opens the page in a new tab.
public struct BookmarksSource: PaletteSource {
    public let id = "bookmarks"
    public let group = PaletteGroup.resources
    private let bookmarks: @Sendable () async -> [PaletteBookmark]

    public init(bookmarks: @escaping @Sendable () async -> [PaletteBookmark]) {
        self.bookmarks = bookmarks
    }

    public func entries() async -> [PaletteEntry] {
        await bookmarks().map { mark in
            PaletteEntry(
                id: "bookmark:\(mark.url)", group: group, title: mark.title,
                subtitle: mark.subtitle, kindLabel: "bookmark", verb: "open",
                action: .dispatch(action: "browser_open", params: .object([
                    "url": .string(mark.url), "newTab": .bool(true),
                ])))
        }
    }
}

// MARK: - Changed files

/// Changed files, one row per file per group — a partly staged file is two rows, as it is two
/// rows in the editor's Changes view.
///
/// The rows come from `status`: the window's while an editor pane keeps it live, else a read made
/// for the palette alone. Each row dispatches `editor_changes_select` with no `pane`, so the focused
/// or first editor pane opens the file's diff tab, or a new editor pane opens for it (3b-iii).
///
/// A root that is loading or failed contributes nothing: the Changes view is where a root's error
/// is read, and a non-repository root would otherwise be a standing error row in every ⌘P.
public struct ChangedFilesSource: PaletteSource {
    public let id = "changedFiles"
    public let group = PaletteGroup.resources
    private let status: @Sendable () async -> [GitRootState]

    public init(status: @escaping @Sendable () async -> [GitRootState]) {
        self.status = status
    }

    public func entries() async -> [PaletteEntry] {
        await status().filter { $0.error == nil && !$0.loading }.flatMap { root in
            root.files.map { file in
                PaletteEntry(
                    id: "file:\(file.group.rawValue):\(root.root)/\(file.path)", group: group,
                    title: (file.path as NSString).lastPathComponent,
                    subtitle: "\(gitGroupLabel(file.group).capitalized) · \(root.name)", kindLabel: "git",
                    verb: "open",
                    action: .dispatch(action: "editor_changes_select", params: .object([
                        "root": .string(root.root), "path": .string(file.path),
                        "group": .string(file.group.rawValue),
                    ])))
            }
        }
    }
}

/// Every file in the project's roots (3b-i), one row each — `config.go · internal/wakilcore · api` —
/// opening in an editor pane. The palette spec left this seam for it: *"All files in a root join when
/// the editor ships, through the same source seam."* A root that cannot be listed is one error row,
/// and every other root still lists (rule 8). A root whose list was cut at the cap ends with a note row.
public struct FilesSource: PaletteSource {
    public let id = "files"
    public let group = PaletteGroup.resources
    private let files: any ToolCaller
    private let roots: @Sendable () async -> [String]

    private let showIgnored: @Sendable () async -> Bool

    /// `showIgnored` answers the operator's setting (3b-v part 2): false leaves the gitignored
    /// files out rather than listing them dimmed.
    public init(files: any ToolCaller, roots: @escaping @Sendable () async -> [String],
                showIgnored: @escaping @Sendable () async -> Bool = { true }) {
        self.files = files
        self.roots = roots
        self.showIgnored = showIgnored
    }

    public func entries() async -> [PaletteEntry] {
        var rows: [PaletteEntry] = []
        let withIgnored = await showIgnored()
        for root in await roots() {
            let rootName = (root as NSString).lastPathComponent
            let result: JSONValue
            do {
                result = try await files.callTool(name: "files_list", arguments: .object(["root": .string(root)]),
                                                  timeout: MCPClient.readReplyTimeout)
            } catch {
                rows.append(errorEntry(id: root, group: group, title: String(describing: error), error: "files", kindLabel: "file"))
                continue
            }
            guard case .object(let obj) = result else { continue }
            if case .bool(true)? = obj["isError"] {
                rows.append(errorEntry(id: root, group: group, title: mcpErrorText(from: obj) ?? "files_list failed for \(root)",
                                     error: "files", kindLabel: "file"))
                continue
            }
            guard case .object(let content)? = obj["structuredContent"], case .array(let list)? = content["files"] else { continue }
            // Tracked files, then the gitignored ones dimmed (3b-ii): a path is never in both lists,
            // and the cap counts the two together.
            var ignored: [JSONValue] = []
            if case .array(let a)? = content["ignored"] { ignored = a }
            // Rule 8: a list cut short says so, first, in the palette's note style, rather than
            // hiding files. The cut is made before any search, so typing more cannot reach the rest.
            if content["truncated"] == .bool(true) {
                rows.append(errorEntry(
                    id: "truncated:\(root)", group: group, title: rootName,
                    error: "\(rootName): only the first \((list.count + ignored.count).formatted()) files are listed and searched; open a deeper root for the rest",
                    kindLabel: "file"))
            }
            func strings(_ a: [JSONValue]) -> [String] { a.compactMap { if case .string(let s) = $0 { s } else { nil } } }
            rows += Self.rows(root: root, files: strings(list), ignored: withIgnored ? strings(ignored) : [])
        }
        return rows
    }

    /// One root's rows: its tracked files, then the `ignored` ones dimmed. The fast path builds the
    /// same rows from the listing the window already holds.
    static func rows(root: String, files: [String], ignored: [String]) -> [PaletteEntry] {
        let rootName = (root as NSString).lastPathComponent
        var rows: [PaletteEntry] = []
        for (paths, dimmed) in [(files, false), (ignored, true)] {
            for rel in paths {
                let folder = (rel as NSString).deletingLastPathComponent
                rows.append(PaletteEntry(
                    id: "editorfile:\(root)/\(rel)", group: .resources, title: (rel as NSString).lastPathComponent,
                    subtitle: folder.isEmpty ? rootName : "\(folder) · \(rootName)", kindLabel: "file",
                    verb: "open", action: .openInEditor(path: "\(root)/\(rel)"), isDimmed: dimmed))
            }
        }
        return rows
    }
}

// MARK: - Tickets

/// A pull request of a ticket in flight, as ⌘P lists it under its ticket.
public struct PaletteTicketPR: Sendable, Equatable {
    public let id: String
    /// `#212 ini-142-login`.
    public let title: String
    /// Its most urgent state in words.
    public let words: String
    /// `ticket_open`'s params, scrolled to this PR.
    public let open: JSONValue

    public init(id: String, title: String, words: String, open: JSONValue) {
        self.id = id
        self.title = title
        self.words = words
        self.open = open
    }
}

/// One ticket in flight — or a PR with no ticket key — as ⌘P reads it. The window maps its
/// `ticketNeedsRows` to these, so `Command` holds nothing of the editor.
public struct PaletteTicket: Sendable, Equatable {
    public let id: String
    /// `INI-142  Login org page`; a keyless PR `#215 · api`.
    public let title: String
    /// Its most urgent state in words: `#212 · 3 comments`.
    public let words: String
    public let key: String?
    /// The ticket's number (142 of INI-142) and its PRs' numbers: a bare number matching one is key-shaped.
    public let numbers: [Int]
    public let prs: [PaletteTicketPR]
    /// `ticket_open`'s params.
    public let open: JSONValue
    /// `ticket_hand_off_open`'s params; nil when no project holds the ticket's branch (an agent needs a root).
    public let handOff: JSONValue?
    /// The urgency tier, 1 most urgent, and the newest activity (RFC 3339): `#` lists by these.
    public let tier: Int
    public let activity: String

    public init(id: String, title: String, words: String, key: String?, numbers: [Int], prs: [PaletteTicketPR],
                open: JSONValue, handOff: JSONValue?, tier: Int, activity: String) {
        self.id = id
        self.title = title
        self.words = words
        self.key = key
        self.numbers = numbers
        self.prs = prs
        self.open = open
        self.handOff = handOff
        self.tier = tier
        self.activity = activity
    }
}

/// Whether one query word is key-shaped: a project key's pattern (`ini-142` for key `INI`), or a bare
/// number equal to a ticket's or a PR's number.
public func paletteKeyShaped(_ word: String, projectKeys: [String], numbers: Set<Int>) -> Bool {
    let w = word.lowercased()
    if !w.isEmpty, w.allSatisfy(\.isASCII), w.allSatisfy(\.isNumber) { return Int(w).map(numbers.contains) ?? false }
    guard let dash = w.lastIndex(of: "-") else { return false }
    let prefix = w[..<dash], digits = w[w.index(after: dash)...]
    guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
    return projectKeys.contains { $0.lowercased() == prefix }
}

/// Tickets in flight, already read — never a search of the PM tool (spec, ⌘P). Its rows depend on the
/// line as typed (`query`, `#` included):
///
/// - **Empty**: nothing, so ⌘P opened empty is exactly today's list.
/// - **`#…`**: every ticket, by tier then newest activity, no PR rows; the model filters by the words.
/// - **A key-shaped word** (`paletteKeyShaped`): the ticket it names and its PRs at `.key`, above every
///   row; every other ticket at `.belowResources`.
/// - **Words**: every ticket at `.belowResources`, after files and tables, before projects.
///
/// Return dispatches `ticket_open`; ⌘↩ `window.ticketHandOff` — `ticket_open`, then
/// `ticket_hand_off_open` from the ticket's header — on a row whose ticket has a hand-off.
public struct TicketSource: PaletteSource {
    public let id = "tickets"
    public let group = PaletteGroup.tickets
    private let tickets: @Sendable () async -> [PaletteTicket]
    private let query: @Sendable () -> String
    private let keys: [String]

    public init(tickets: @escaping @Sendable () async -> [PaletteTicket], query: @escaping @Sendable () -> String,
                keys: [String]) {
        self.tickets = tickets
        self.query = query
        self.keys = keys
    }

    public func entries() async -> [PaletteEntry] {
        let line = query()
        if !line.hasPrefix("#"), PaletteSearch.words(line).isEmpty { return [] }
        return entries(await tickets())
    }

    /// `entries()` over tickets already in hand: the window's fast path for each line typed.
    public func entries(_ all: [PaletteTicket]) -> [PaletteEntry] {
        let line = query()
        if line.hasPrefix("#") {
            return Self.byUrgency(all).map { row($0, tier: .ordinary) }
        }
        let words = PaletteSearch.words(line)
        if words.isEmpty { return [] }
        let numbers = Set(all.flatMap(\.numbers))
        let keyWords = words.filter { paletteKeyShaped($0, projectKeys: keys, numbers: numbers) }
        var keyed: [PaletteEntry] = [], others: [PaletteEntry] = []
        for t in all {
            let named = keyWords.contains { w in t.key?.lowercased() == w || Int(w).map(t.numbers.contains) == true }
            if named {
                keyed.append(row(t, tier: .key))
                keyed += t.prs.map { prRow($0, of: t) }
            } else {
                others.append(row(t, tier: .belowResources))
            }
        }
        return keyed + others
    }

    private func row(_ t: PaletteTicket, tier: PaletteTier) -> PaletteEntry {
        PaletteEntry(id: "ticket:\(t.id)", group: group, title: t.title, subtitle: t.words, kindLabel: "ticket",
                     verb: "open", action: .dispatch(action: "ticket_open", params: t.open), tier: tier,
                     altAction: Self.handOff(t, open: t.open), altVerb: t.handOff == nil ? nil : Self.handOffVerb)
    }

    private func prRow(_ pr: PaletteTicketPR, of t: PaletteTicket) -> PaletteEntry {
        PaletteEntry(id: "ticketpr:\(pr.id)", group: group, title: pr.title, subtitle: pr.words,
                     kindLabel: "pull request", verb: "open", action: .dispatch(action: "ticket_open", params: pr.open),
                     tier: .key, altAction: Self.handOff(t, open: pr.open),
                     altVerb: t.handOff == nil ? nil : Self.handOffVerb)
    }

    static let handOffVerb = "hand to agent"

    /// ⌘↩: the window runs `open` (`ticket_open`), then `handOff` (`ticket_hand_off_open`).
    private static func handOff(_ t: PaletteTicket, open: JSONValue) -> PaletteAction? {
        t.handOff.map { .dispatch(action: "window.ticketHandOff", params: .object(["open": open, "handOff": $0])) }
    }

    /// By tier, then newest activity first; ties keep the order given.
    static func byUrgency(_ tickets: [PaletteTicket]) -> [PaletteTicket] {
        let f = ISO8601DateFormatter()
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func date(_ s: String) -> Date { f.date(from: s) ?? frac.date(from: s) ?? .distantPast }
        return tickets.enumerated().sorted { a, b in
            if a.element.tier != b.element.tier { return a.element.tier < b.element.tier }
            let da = date(a.element.activity), db = date(b.element.activity)
            if da != db { return da > db }
            return a.offset < b.offset
        }.map(\.element)
    }
}

// MARK: - Projects, sessions, providers

/// What `WindowModel`'s ⌘P readers return: rows, and a note when the listing is incomplete.
public typealias PaletteItemsReader = @Sendable () async -> (items: [PaletteItem], note: String?)

/// Projects, sessions or providers, over `WindowModel`'s existing readers
/// (`projectPaletteItems`, `sessionPaletteItems`, `providerPaletteItems`). A reader's note is an
/// error row beside its rows, so an incomplete listing says it is incomplete.
public struct ItemsSource: PaletteSource {
    public let id: String
    public let group: PaletteGroup
    private let kindLabel: String
    private let action: @Sendable (String) -> PaletteAction
    private let read: PaletteItemsReader

    init(id: String, group: PaletteGroup, kindLabel: String,
         action: @escaping @Sendable (String) -> PaletteAction, read: @escaping PaletteItemsReader) {
        self.id = id
        self.group = group
        self.kindLabel = kindLabel
        self.action = action
        self.read = read
    }

    /// **The current organisation's only** (Invariant 4): the reader is asked for `organisation()`
    /// and nothing else, so another organisation's project never reaches a row.
    public static func projects(
        organisation: @escaping @Sendable () async -> String,
        read: @escaping @Sendable (String) async -> (items: [PaletteItem], note: String?)
    ) -> ItemsSource {
        ItemsSource(id: "projects", group: .projects, kindLabel: "project", action: { .setProject($0) },
                    read: { await read(await organisation()) })
    }

    public static func sessions(read: @escaping PaletteItemsReader) -> ItemsSource {
        ItemsSource(id: "sessions", group: .sessions, kindLabel: "session",
                    action: { .resumeSession($0) }, read: read)
    }

    public static func providers(read: @escaping PaletteItemsReader) -> ItemsSource {
        ItemsSource(id: "providers", group: .providers, kindLabel: "provider",
                    action: { .setProvider($0) }, read: read)
    }

    public func entries() async -> [PaletteEntry] {
        let (items, note) = await read()
        let rows = items.map { item in
            PaletteEntry(id: "\(kindLabel):\(item.payload)", group: group, title: item.title,
                         subtitle: item.subtitle, kindLabel: kindLabel, verb: "switch to",
                         action: action(item.payload), isCaution: item.caution)
        }
        guard let note else { return rows }
        return rows + [errorEntry(id: id, group: group, title: group.label, error: note, kindLabel: kindLabel)]
    }
}

// MARK: - Choices

/// Where a choice step's values come from. Each defaults to nothing, so a caller fills only what
/// it has.
public struct ChoiceReaders: Sendable {
    /// The environments, and why they could not be listed: a failure is drawn as one whole
    /// error row (rule 8), as projects' and providers' are.
    public var environments: @Sendable () async -> (listings: [EnvironmentListing], note: String?)
    /// The current organisation's projects (see `ItemsSource.projects`).
    public var projects: PaletteItemsReader
    public var providers: PaletteItemsReader
    public var paneKinds: Set<String>
    /// 3a-iv: the active root's local branches, the current one marked.
    public var branches: PaletteItemsReader

    public init(
        environments: @escaping @Sendable () async -> (listings: [EnvironmentListing], note: String?)
            = { ([], nil) },
        projects: @escaping PaletteItemsReader = { ([], nil) },
        providers: @escaping PaletteItemsReader = { ([], nil) },
        paneKinds: Set<String> = Pane.kinds,
        branches: @escaping PaletteItemsReader = { ([], nil) }
    ) {
        self.branches = branches
        self.environments = environments
        self.projects = projects
        self.providers = providers
        self.paneKinds = paneKinds
    }
}

/// A choice step's rows. **Each row's `id` is the raw value the command receives** — an
/// environment name, a project name, a provider id, a pane kind — so these, alone among palette
/// rows, are not prefixed. An environment row carries the environment's own production flag
/// (Decision 26), which the view draws red.
public func choiceEntries(_ source: ChoiceSource, readers: ChoiceReaders) async -> [PaletteEntry] {
    func row(_ value: String, _ title: String, _ subtitle: String, _ kind: String,
             production: Bool = false, caution: Bool = false) -> PaletteEntry {
        PaletteEntry(id: value, group: .choices, title: title, subtitle: subtitle, kindLabel: kind,
                     verb: "choose", action: noAction, isProduction: production, isCaution: caution)
    }
    func items(_ read: PaletteItemsReader, _ kind: String) async -> [PaletteEntry] {
        let (items, note) = await read()
        let rows = items.map { row($0.payload, $0.title, $0.subtitle, kind, caution: $0.caution) }
        guard let note else { return rows }
        return rows + [errorEntry(id: "choices:\(kind)", group: .choices, title: kind, error: note, kindLabel: kind)]
    }
    switch source {
    case .environments:
        let (listings, note) = await readers.environments()
        let rows = listings.map {
            row($0.name, $0.name, $0.isProduction ? "production" : "", "environment", production: $0.isProduction)
        }
        guard let note else { return rows }
        return rows + [errorEntry(id: "choices:environment", group: .choices, title: "environment", error: note,
                                  kindLabel: "environment")]
    case .projects: return await items(readers.projects, "project")
    case .providers: return await items(readers.providers, "provider")
    case .paneKinds:
        return offeredKinds(readers.paneKinds).map { row($0, paneKindTitle(kind: $0), "", "pane") }
    case .languages:
        return editorLanguageChoices.map { row($0, $0, "", "language") }
    case .branches: return await items(readers.branches, "branch")
    }
}
