import Foundation

/// The composer's fast path (3b-ix, Decision 10 amended): a line that asks for exactly one
/// navigation action runs it without an agent turn. The model proposes; this checks.
public struct FastPathPane: Sendable, Equatable, Codable {
    public var id: String
    public var kind: String
    public var title: String
    public init(id: String, kind: String, title: String) { self.id = id; self.kind = kind; self.title = title }
}

public struct FastPathScope: Sendable, Equatable {
    public var files: [String]
    public var roots: [String]
    public var projects: [String]
    public var environments: [String]
    public var activeEnvironment: String
    public var databases: [String]
    public var tables: [String]
    public var panes: [FastPathPane]
    public var apiEntries: [String]
    public init(files: [String] = [], roots: [String] = [], projects: [String] = [], environments: [String] = [],
                activeEnvironment: String = "", databases: [String] = [], tables: [String] = [], panes: [FastPathPane] = [],
                apiEntries: [String] = []) {
        self.files = files; self.roots = roots; self.projects = projects; self.environments = environments
        self.activeEnvironment = activeEnvironment; self.databases = databases; self.tables = tables; self.panes = panes
        self.apiEntries = apiEntries
    }

    /// What the model sees for each file, and the path it stands for: the path relative to its
    /// root (the longest that holds it), and the root's name in front where two roots share the
    /// rest. A short name is a few tokens to copy back, where an absolute path is dozens and
    /// misses a local model's deadline (3b-ix walk). A file under no root keeps its path.
    public var fileNames: [(name: String, path: String)] {
        let relative = files.map { path -> (rel: String, root: String?) in
            guard let root = roots.filter({ path.hasPrefix($0 + "/") }).max(by: { $0.count < $1.count })
            else { return (path, nil) }
            return (String(path.dropFirst(root.count + 1)), root)
        }
        var count: [String: Int] = [:]
        for r in relative { count[r.rel, default: 0] += 1 }
        return zip(files, relative).map { path, r in
            guard let root = r.root, count[r.rel]! > 1 else { return (r.rel, path) }
            return ((root as NSString).lastPathComponent + "/" + r.rel, path)
        }
    }
}

public enum FastPathRoute: Sendable, Equatable {
    case action(name: String, params: JSONValue)
    case agent
}

/// What a param must name: something in scope, or anything (`free`: a search query, a line).
/// `closablePane` is an open pane that is not a terminal: closing one ends its shell.
public enum FastPathParam: Sendable { case file, project, environment, database, table, pane, closablePane, apiEntry, root, free }

public struct FastPathAction: Sendable {
    public var params: [String: FastPathParam]
    public init(_ params: [String: FastPathParam]) { self.params = params }
}

public enum FastPath {
    /// The 26 navigation actions and the params the model may set (spec §The allowed list).
    /// Every other param — `discard` first — is dropped before dispatch.
    public static let allowed: [String: FastPathAction] = [
        "editor_open": .init(["path": .file, "line": .free]),
        "editor_goto": .init(["line": .free, "column": .free]),
        "editor_search": .init(["query": .free]),
        "editor_find": .init(["query": .free]),
        "editor_tree_reveal": .init(["path": .file]),
        "editor_new_scratch": .init(["language": .free]),
        "editor_close": .init(["path": .file]),
        "editor_focus_tab": .init(["index": .free]),
        "editor_changes_select": .init(["path": .file]),       // R4: root and group are derived
        "editor_set_language": .init(["language": .free]),
        "ctx_set_environment": .init(["name": .environment]),
        "ctx_set_project": .init(["name": .project]),
        // `database` picks one where the environment has several; with none, wakil-db refuses (3b-ix walk).
        "db_read_table": .init(["table": .table, "database": .database]),
        "db_describe_table": .init(["table": .table, "database": .database]),
        "db_list_tables": .init(["database": .database]),
        "db_page": .init(["pane": .pane, "to": .free]),
        "db_refetch": .init(["pane": .pane]),
        "pane_open": .init(["kind": .free]),
        "pane_focus": .init(["id": .pane]),
        "pane_close": .init(["id": .closablePane]),
        "pane_maximize": .init(["id": .pane]),
        "pane_restore": .init([:]),
        "pane_sort": .init(["pane": .pane, "column": .free, "direction": .free]),
        // A root in scope, or dropped: the model sees no directories, and the 1.5B made one up ("zsh").
        "term_open": .init(["path": .root]),
        "api_open": .init(["entry": .apiEntry]),
        "settings_open": .init([:]),
    ]

    public static let replySchema: String = {
        let names = (allowed.keys.sorted() + ["agent"]).map { "\"\($0)\"" }.joined(separator: ",")
        return #"{"type":"object","properties":{"action":{"type":"string","enum":["# + names
            + #"]},"params":{"type":"object"}},"required":["action","params"]}"#
    }()

    /// Rules, the action list and worked examples: stable for a window, so a server's prompt cache
    /// holds them (measured: worked examples took the 1.5B from 10 to 14 of 16).
    public static func instructions(actions schemas: [String: JSONValue]) -> String {
        let list = allowed.keys.sorted().map { name -> String in
            let params = allowed[name]!.params.keys.sorted().joined(separator: ", ")
            return "- \(name)(\(params))"
        }.joined(separator: "\n")
        return """
        You route one line an operator typed in a developer tool. If the line asks for exactly ONE \
        of the actions below and every name it needs is in SCOPE, answer with that action and its \
        params. Otherwise answer {"action": "agent", "params": {}}. A question, a change, a fix or \
        a delete is ALWAYS agent, even when it names a file or a table. Never invent a path, table, \
        pane id, project or environment: copy them exactly from SCOPE.

        ACTIONS:
        \(list)

        EXAMPLES (line -> answer):
        - "go to qa" -> {"action": "ctx_set_environment", "params": {"name": "qa"}}
        - "show payments" -> {"action": "db_read_table", "params": {"table": "payments"}}
        - "tables in core" -> {"action": "db_list_tables", "params": {"database": "core"}}
        - "what columns does invoices have" -> {"action": "db_describe_table", "params": {"table": "invoices"}}
        - "close the bookings table" -> {"action": "pane_close", "params": {"id": "db-1"}}
        - "line 40" -> {"action": "editor_goto", "params": {"line": 40}}
        - "how does refund work?" -> {"action": "agent", "params": {}}
        - "rename Confirm to Accept" -> {"action": "agent", "params": {}}
        - "drop the old refunds" -> {"action": "agent", "params": {}}
        - "open checkout.go" (not in SCOPE) -> {"action": "agent", "params": {}}
        """
    }

    public static func input(_ line: String, scope: FastPathScope) -> String {
        struct Wire: Encodable {
            let files: [String]; let projects: [String]; let environments: [String]
            let active_environment: String; let databases: [String]; let tables: [String]; let open_panes: [FastPathPane]
            let api_entries: [String]
        }
        let wire = Wire(files: scope.fileNames.map(\.name), projects: scope.projects, environments: scope.environments,
                        active_environment: scope.activeEnvironment, databases: scope.databases, tables: scope.tables,
                        open_panes: scope.panes, api_entries: scope.apiEntries)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let json = (try? enc.encode(wire)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return "SCOPE: \(json)\nLINE: \(line)"
    }

    /// The checks, in order; the first that fails answers `.agent`.
    public static func check(reply: String, scope: FastPathScope, schemas: [String: JSONValue]) -> FastPathRoute {
        guard let data = reply.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let top) = value,
              case .string(let name)? = top["action"] else { return .agent }
        guard name != "agent", let action = allowed[name], let schema = schemas[name] else { return .agent }
        let given: [String: JSONValue]
        if case .object(let p)? = top["params"] { given = p } else { given = [:] }

        var params: [String: JSONValue] = [:]
        let needed = Set(required(schema))
        for (key, kind) in action.params {
            guard let raw = given[key] else { continue }
            let property = property(schema, key)
            // An optional param that is not its type is dropped and the rest runs (Rule 7): the 1.5B
            // copies the path into `line` on "open confirm.go" (3b-ix walk). A required one cannot be.
            guard let typed = conform(raw, to: property.type) else {
                if needed.contains(key) { return .agent } else { continue }
            }
            if kind == .root, !inScope(typed, kind, scope) { continue }
            if let allowed = property.values, !allowed.contains(typed) { return .agent }
            guard inScope(typed, kind, scope) else { return .agent }
            params[key] = kind == .file ? filePath(typed, scope).map(JSONValue.string) ?? typed : typed
        }
        if name == "editor_changes_select" {
            guard case .string(let path)? = params["path"],
                  let root = scope.roots.filter({ path.hasPrefix($0 + "/") }).max(by: { $0.count < $1.count })
            else { return .agent }
            params = ["root": .string(root), "path": .string(String(path.dropFirst(root.count + 1))),
                      "group": .string("changed")]
        }
        for key in required(schema) where params[key] == nil { return .agent }
        return .action(name: name, params: .object(params))
    }

    public static func route(_ line: String, scope: FastPathScope, schemas: [String: JSONValue],
                             deadline: Duration,
                             respond: @escaping @Sendable (RespondRequest) async throws -> String) async -> FastPathRoute {
        guard !asksToDelete(line) else { return .agent }
        let request = RespondRequest(instructions: instructions(actions: schemas), input: input(line, scope: scope),
                                     jsonSchema: replySchema, maxTokens: 80)
        guard let reply = await within(deadline, { try? await respond(request) }) else { return .agent }
        return check(reply: reply, scope: scope, schemas: schemas)
    }

    /// `work`'s answer, or nil once `deadline` passes, whichever comes first. The loser is cancelled
    /// and left to finish on its own: a model that ignores cancellation (a session-backed one parked
    /// behind another turn) cannot hold the line past the deadline.
    public static func within<T: Sendable>(_ deadline: Duration, _ work: @escaping @Sendable () async -> T?) async -> T? {
        let first = FirstAnswer<T>()
        return await withCheckedContinuation { continuation in
            first.arm(continuation)
            first.race([
                Task { first.answer(await work()) },
                Task { try? await Task.sleep(for: deadline); first.answer(nil) },
            ])
        }
    }

    // MARK: - Checks

    /// Words that open a request to delete. The prompt says a delete is always the agent's, and the
    /// 1.5B still answered "delete the draft bookings" with closing the bookings pane (3b-ix walk),
    /// so such a line is not asked at all. The first word only: "open delete_user.go" is a file.
    static let deleteWords: Set<String> = ["delete", "drop", "remove", "truncate", "erase", "purge", "wipe"]

    static func asksToDelete(_ line: String) -> Bool {
        let words = line.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        let first = words.first == "please" ? words.dropFirst().first : words.first
        return first.map(deleteWords.contains) ?? false
    }

    /// The registry schema's `type` for `key`, and its `enum` when it has one.
    private static func property(_ schema: JSONValue, _ key: String) -> (type: String?, values: [JSONValue]?) {
        guard case .object(let s) = schema, case .object(let props)? = s["properties"],
              case .object(let p)? = props[key] else { return (nil, nil) }
        var type: String?
        if case .string(let t)? = p["type"] { type = t }
        var values: [JSONValue]?
        if case .array(let e)? = p["enum"] { values = e }
        return (type, values)
    }

    private static func required(_ schema: JSONValue) -> [String] {
        guard case .object(let s) = schema, case .array(let r)? = s["required"] else { return [] }
        return r.compactMap { if case .string(let k) = $0 { return k } else { return nil } }
    }

    /// The value as the schema's type, converting a string of digits for a number (R3) and a number
    /// for a string ("page 3"), or nil.
    static func conform(_ v: JSONValue, to type: String?) -> JSONValue? {
        switch (type, v) {
        case (nil, _): return v
        case ("string", .string): return v
        case ("string", .integer(let n)): return .string(String(n))
        case ("string", .number(let n)):
            return .string(n.rounded() == n && abs(n) < 1e15 ? String(Int64(n)) : String(n))
        case ("integer", .integer), ("number", .integer), ("number", .number): return v
        case ("integer", .number(let n)) where n.rounded() == n: return .integer(Int64(n))
        case ("integer", .string(let s)):
            guard let n = Int64(s.trimmingCharacters(in: .whitespaces)) else { return nil }
            return .integer(n)
        case ("number", .string(let s)):
            guard let n = Double(s.trimmingCharacters(in: .whitespaces)) else { return nil }
            return .number(n)
        case ("boolean", .bool): return v
        default: return nil
        }
    }

    /// The absolute path a file name the model gave stands for: a name from `fileNames`, or (as
    /// before) a path in scope copied whole.
    private static func filePath(_ v: JSONValue, _ scope: FastPathScope) -> String? {
        guard case .string(let s) = v else { return nil }
        if let hit = scope.fileNames.first(where: { $0.name == s }) { return hit.path }
        return scope.files.contains(s) ? s : nil
    }

    private static func inScope(_ v: JSONValue, _ kind: FastPathParam, _ scope: FastPathScope) -> Bool {
        guard kind != .free else { return true }
        guard case .string(let s) = v else { return false }
        switch kind {
        case .file: return filePath(v, scope) != nil
        case .project: return scope.projects.contains(s)
        case .environment: return scope.environments.contains(s)
        case .database: return scope.databases.contains(s)
        case .table: return scope.tables.contains(s)
        case .pane: return scope.panes.contains { $0.id == s }
        case .closablePane: return scope.panes.contains { $0.id == s && $0.kind != "terminal" }
        case .apiEntry: return scope.apiEntries.contains(s)
        case .root: return scope.roots.contains(s)
        case .free: return true
        }
    }
}

/// The one answer `FastPath.within` takes: the first `answer` resumes the caller and cancels both
/// racers; every later one is dropped.
private final class FirstAnswer<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?
    private var racers: [Task<Void, Never>] = []
    private var done = false

    func arm(_ c: CheckedContinuation<T?, Never>) { lock.withLock { continuation = c } }

    func race(_ tasks: [Task<Void, Never>]) {
        let finished = lock.withLock { () -> Bool in
            if !done { racers = tasks }
            return done
        }
        if finished { tasks.forEach { $0.cancel() } }
    }

    func answer(_ value: T?) {
        let (c, losers) = lock.withLock { () -> (CheckedContinuation<T?, Never>?, [Task<Void, Never>]) in
            guard !done else { return (nil, []) }
            done = true
            defer { continuation = nil; racers = [] }
            return (continuation, racers)
        }
        guard let c else { return }
        c.resume(returning: value)
        losers.forEach { $0.cancel() }
    }
}
