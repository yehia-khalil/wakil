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
    public var tables: [String]
    public var panes: [FastPathPane]
    public var apiEntries: [String]
    public init(files: [String] = [], roots: [String] = [], projects: [String] = [], environments: [String] = [],
                activeEnvironment: String = "", tables: [String] = [], panes: [FastPathPane] = [],
                apiEntries: [String] = []) {
        self.files = files; self.roots = roots; self.projects = projects; self.environments = environments
        self.activeEnvironment = activeEnvironment; self.tables = tables; self.panes = panes
        self.apiEntries = apiEntries
    }
}

public enum FastPathRoute: Sendable, Equatable {
    case action(name: String, params: JSONValue)
    case agent
}

/// What a param must name: something in scope, or anything (`free`: a search query, a line).
public enum FastPathParam: Sendable { case file, project, environment, table, pane, apiEntry, free }

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
        "db_read_table": .init(["table": .table]),
        "db_describe_table": .init(["table": .table]),
        "db_list_tables": .init([:]),
        "db_page": .init(["pane": .pane, "to": .free]),
        "db_refetch": .init(["pane": .pane]),
        "pane_open": .init(["kind": .free]),
        "pane_focus": .init(["id": .pane]),
        "pane_close": .init(["id": .pane]),
        "pane_maximize": .init(["id": .pane]),
        "pane_restore": .init([:]),
        "pane_sort": .init(["pane": .pane, "column": .free, "direction": .free]),
        "term_open": .init(["path": .free]),
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
        - "what columns does invoices have" -> {"action": "db_describe_table", "params": {"table": "invoices"}}
        - "close the terminal" -> {"action": "pane_close", "params": {"id": "terminal-1"}}
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
            let active_environment: String; let tables: [String]; let open_panes: [FastPathPane]
            let api_entries: [String]
        }
        let wire = Wire(files: scope.files, projects: scope.projects, environments: scope.environments,
                        active_environment: scope.activeEnvironment, tables: scope.tables,
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
        for (key, kind) in action.params {
            guard let raw = given[key] else { continue }
            guard let typed = conform(raw, to: propertyType(schema, key)) else { return .agent }
            guard inScope(typed, kind, scope) else { return .agent }
            params[key] = typed
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
        let request = RespondRequest(instructions: instructions(actions: schemas), input: input(line, scope: scope),
                                     jsonSchema: replySchema, maxTokens: 80)
        let reply: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask { try? await respond(request) }
            group.addTask { try? await Task.sleep(for: deadline); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let reply else { return .agent }
        return check(reply: reply, scope: scope, schemas: schemas)
    }

    // MARK: - Checks

    private static func propertyType(_ schema: JSONValue, _ key: String) -> String? {
        guard case .object(let s) = schema, case .object(let props)? = s["properties"],
              case .object(let p)? = props[key], case .string(let t)? = p["type"] else { return nil }
        return t
    }

    private static func required(_ schema: JSONValue) -> [String] {
        guard case .object(let s) = schema, case .array(let r)? = s["required"] else { return [] }
        return r.compactMap { if case .string(let k) = $0 { return k } else { return nil } }
    }

    /// The value as the schema's type, converting a string of digits for a number (R3), or nil.
    private static func conform(_ v: JSONValue, to type: String?) -> JSONValue? {
        switch (type, v) {
        case (nil, _): return v
        case ("string", .string): return v
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

    private static func inScope(_ v: JSONValue, _ kind: FastPathParam, _ scope: FastPathScope) -> Bool {
        guard kind != .free else { return true }
        guard case .string(let s) = v else { return false }
        switch kind {
        case .file: return scope.files.contains(s)
        case .project: return scope.projects.contains(s)
        case .environment: return scope.environments.contains(s)
        case .table: return scope.tables.contains(s)
        case .pane: return scope.panes.contains { $0.id == s }
        case .apiEntry: return scope.apiEntries.contains(s)
        case .free: return true
        }
    }
}
