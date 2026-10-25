import Foundation

/// One of a connection's tools as its server lists it now, with the server's own word on it:
/// readOnly, writes, destructive, or "" when it says nothing.
public struct ConnectionTool: Sendable, Equatable, Identifiable {
    public var name: String
    public var hint: String
    public var id: String { name }

    public init(name: String, hint: String) {
        self.name = name
        self.hint = hint
    }
}

/// What `wakil-connect --list` answered: the tools, or the server's error with every stored
/// secret already blanked out.
public enum ConnectionListing: Sendable, Equatable {
    case tools([ConnectionTool])
    case error(String)
}

/// A connection's status line on Settings → Connections (design-language §5: green, amber, red).
public enum ConnectionStatus: Sendable, Equatable {
    case connected(tools: [ConnectionTool], checkedAt: Date)
    case needsSignIn
    /// The server's error, whole (Rule 8).
    case failing(String)
}

/// A ready-made connection the operator can add (Go's `ConnectionCatalog`).
public struct ConnectionKindEntry: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var signIn: String
    public var fields: [SettingsConnectionField]

    public init(id: String, title: String, signIn: String, fields: [SettingsConnectionField] = []) {
        self.id = id
        self.title = title
        self.signIn = signIn
        self.fields = fields
    }
}

/// `wakil-connect --list`'s one line: `{"tools":[{name,hint}]}`, or `{"error":…}`. Anything else
/// — no line, a crash — is a failure that says what came back.
public func parseConnectionListing(_ data: Data, exitCode: Int32) -> ConnectionListing {
    let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)), case .object(let o) = value else {
        return .error(text.isEmpty ? "\(wakilConnectBinaryName) exited \(exitCode) and said nothing" : text)
    }
    if case .string(let e)? = o["error"], !e.isEmpty { return .error(e) }
    guard case .array(let rows)? = o["tools"] else {
        return .error(text)
    }
    return .tools(rows.compactMap { row in
        guard case .object(let r) = row, case .string(let name)? = r["name"] else { return nil }
        if case .string(let hint)? = r["hint"] { return ConnectionTool(name: name, hint: hint) }
        return ConnectionTool(name: name, hint: "")
    })
}

/// Whether a server's error is it asking to be signed in: an HTTP 401 or 403, or its own words.
public func connectionErrorWantsSignIn(_ error: String) -> Bool {
    let e = error.lowercased()
    return ["401", "403", "unauthorized", "sign in"].contains { e.contains($0) }
}

/// Settings → Connections: every call is an operator-only `ctx_connection_*` dispatch for the
/// organisation named, and Settings is read again after a write — and that organisation's entry in
/// the connections box, when it is not the active one. Each answers its refusal's own
/// sentence, whole (Rule 8).
extension WindowModel {
    func connectionCall(org: String, _ name: String, _ params: [String: JSONValue],
                        refresh: Bool = false) async -> (JSONValue?, String?) {
        var p = params
        p["id"] = .string(org)
        let result: (JSONValue?, String?)
        do {
            let reply = try await registry.dispatch(name: name, params: .object(p), origin: .ui,
                                                    caller: DispatchCaller(place: place, session: nil), confirmation: nil)
            if case .object(let o) = reply, let fields = o["structuredContent"] { result = (fields, nil) } else { result = (reply, nil) }
        } catch is CancellationError {
            result = (nil, nil)
        } catch {
            result = (nil, statusDescribingFailure(name, error))
        }
        if refresh {
            await refreshSettings()
            if org != settings?.org.id { await refreshAgentConnections(org: org) }
        }
        return result
    }

    /// `org`'s entry in the connections box read again, for a write to an organisation that is not
    /// the active one: Settings reads only the active organisation's tree, and the next launch in
    /// `org` must see what was just written. A read that fails leaves the entry as it was.
    func refreshAgentConnections(org: String) async {
        let result = try? await registry.dispatch(
            name: "ctx_config_tree_for", params: .object(["id": .string(org)]), origin: .ui,
            caller: DispatchCaller(place: place, session: nil), confirmation: nil)
        guard let tree = decodeSettingsTree(fromResult: result), tree.org.id == org else { return }
        agentConnectionsBox.set(org: org, connections: tree.org.connections)
    }

    private static func string(_ v: JSONValue?, _ key: String) -> String? {
        if case .object(let o)? = v, case .string(let s)? = o[key] { return s }
        return nil
    }

    /// The organisation's connection called `name`, as the last Settings read drew it.
    public func settingsConnection(org: String, name: String) -> SettingsConnection? {
        guard let tree = settings, tree.org.id == org else { return nil }
        return tree.org.connections.first { $0.name == name }
    }

    /// The ready-made list **+ Add connection** offers, before **Custom server**.
    public func connectionCatalog() async -> [ConnectionKindEntry] {
        let (reply, _) = await connectionCall(org: organization, "ctx_connection_catalog", [:])
        guard case .object(let o)? = reply, case .array(let rows)? = o["kinds"] else { return [] }
        return rows.compactMap { row in
            guard let id = Self.string(row, "id") else { return nil }
            var fields: [SettingsConnectionField] = []
            if case .object(let r) = row, case .array(let fs)? = r["fields"],
               let data = try? JSONEncoder().encode(JSONValue.array(fs)),
               let decoded = try? JSONDecoder().decode([SettingsConnectionField].self, from: data) {
                fields = decoded
            }
            return ConnectionKindEntry(id: id, title: Self.string(row, "title") ?? id,
                                       signIn: Self.string(row, "signIn") ?? "none", fields: fields)
        }
    }

    /// Adds a connection of `kind` (a catalog id, or "custom" with its transport and its address or
    /// command) and answers the name it was stored under. An empty `name` takes the kind's.
    public func addConnection(org: String, kind: String, name: String, transport: String = "", url: String = "",
                              command: String = "", args: [String] = []) async -> (name: String?, error: String?) {
        var p: [String: JSONValue] = ["kind": .string(kind)]
        for (k, v) in [("name", name), ("transport", transport), ("url", url), ("command", command)] where !v.isEmpty {
            p[k] = .string(v)
        }
        if !args.isEmpty { p["args"] = .array(args.map { .string($0) }) }
        let (reply, error) = await connectionCall(org: org, "ctx_connection_add", p, refresh: true)
        return (Self.string(reply, "name"), error)
    }

    /// Changes what is given — a rename, a custom server's address, command or arguments, or
    /// non-secret field values (an empty value clears it) — and leaves the rest.
    public func updateConnection(org: String, name: String, newName: String? = nil, url: String? = nil,
                                 command: String? = nil, args: [String]? = nil,
                                 values: [String: String] = [:]) async -> String? {
        var p: [String: JSONValue] = ["name": .string(name)]
        if let newName { p["newName"] = .string(newName) }
        if let url { p["url"] = .string(url) }
        if let command { p["command"] = .string(command) }
        if let args { p["args"] = .array(args.map { .string($0) }) }
        if !values.isEmpty { p["values"] = .object(values.mapValues { .string($0) }) }
        return await connectionCall(org: org, "ctx_connection_update", p, refresh: true).1
    }

    /// Removes a connection, and its Keychain item with it. Asks nothing (Rule 1: configuration,
    /// not work).
    public func removeConnection(org: String, name: String) async -> String? {
        await connectionCall(org: org, "ctx_connection_remove", ["name": .string(name)], refresh: true).1
    }

    /// Keeps secret values in the connection's Keychain item, merged with what is there: a catalog
    /// field's id, or a custom server's `env:<NAME>` / `header:<Name>`.
    public func setConnectionSecrets(org: String, name: String, values: [String: String]) async -> String? {
        await connectionCall(org: org, "ctx_connection_secrets_set",
                             ["name": .string(name), "values": .object(values.mapValues { .string($0) })], refresh: true).1
    }

    /// One tool's **Allow agent** switch. A locked (destructive) tool is refused by Go.
    public func setConnectionAllow(org: String, name: String, tool: String, allow: Bool) async -> String? {
        await connectionCall(org: org, "ctx_connection_allow_set",
                             ["name": .string(name), "tool": .string(tool), "allow": .bool(allow)], refresh: true).1
    }

    /// **Allow every tool the server marks read-only**: one switch per tool hinted read-only whose
    /// switch is off as the gate reads it (`connectionToolRows`: the stored switch, else on for a
    /// read-only hint) — so only one the operator turned off is written. Stops at the first
    /// refusal and answers it.
    public func allowReadOnlyTools(org: String, name: String) async -> String? {
        guard let c = settingsConnection(org: org, name: name) else { return "no connection \(name) in \(org)" }
        for tool in c.hints.keys.sorted() where c.hints[tool] == "readOnly" && (c.allow[tool] ?? true) == false {
            let (_, error) = await connectionCall(org: org, "ctx_connection_allow_set",
                                                  ["name": .string(name), "tool": .string(tool), "allow": .bool(true)])
            if let error {
                await refreshSettings()
                return error
            }
        }
        await refreshSettings()
        return nil
    }

    /// Checks a connection once with `wakil-connect --list`. Tools → connected, and the hints it
    /// read are recorded (`connection_update`) when they changed; an error that is the server
    /// asking to be signed in, or one from a connection never signed in, → needs sign-in; any
    /// other → failing, with the error whole.
    public func checkConnection(org: String, name: String) async -> ConnectionStatus {
        let listing = await connectionLister(org, name)
        let stored = settingsConnection(org: org, name: name)
        switch listing {
        case .tools(let tools):
            let hints = Dictionary(tools.map { ($0.name, $0.hint) }, uniquingKeysWith: { a, _ in a })
            if !Task.isCancelled, stored?.hints != hints {
                _ = await connectionCall(org: org, "ctx_connection_update",
                                         ["name": .string(name), "hints": .object(hints.mapValues { .string($0) })],
                                         refresh: true)
            }
            return .connected(tools: tools, checkedAt: Date())
        case .error(let error):
            let neverSignedIn = stored.map { $0.signIn != "none" && !$0.signedIn } ?? false
            return connectionErrorWantsSignIn(error) || neverSignedIn ? .needsSignIn : .failing(error)
        }
    }

    /// Browser sign-in: start, open the page in the browser, wait for it, read Settings again.
    /// Cancelling the calling task ends the wait and keeps nothing (Rule 4); a cancel answers nil.
    public func signIn(org: String, name: String) async -> String? {
        let (start, error) = await connectionCall(org: org, "ctx_connection_signin_start", ["name": .string(name)])
        if let error { return error }
        guard !Task.isCancelled else { return nil }
        guard let page = Self.string(start, "url"), let url = URL(string: page) else {
            return "ctx_connection_signin_start: the sign-in page it answered is not an address"
        }
        openURL(url)
        let (done, waitError) = await connectionCall(org: org, "ctx_connection_signin_wait", ["name": .string(name)])
        guard !Task.isCancelled else { return nil }
        if let waitError { return waitError }
        if let account = Self.string(done, "account"), !account.isEmpty { connectionAccounts["\(org)/\(name)"] = account }
        await refreshSettings()
        return nil
    }

    /// Forgets a browser sign-in's tokens.
    public func signOut(org: String, name: String) async -> String? {
        connectionAccounts["\(org)/\(name)"] = nil
        return await connectionCall(org: org, "ctx_connection_signout", ["name": .string(name)], refresh: true).1
    }

    /// The Jira connection's sign-in: email and API token, kept as today's `jira:<org>`.
    public func setJiraToken(org: String, email: String, token: String) async -> String? {
        await connectionCall(org: org, "ctx_jira_token_set", ["email": .string(email), "token": .string(token)], refresh: true).1
    }
}

/// `wakil-pm`'s tools, as the Jira connection's page lists them: no switches, because their
/// prices are Wakil's own (Invariant 6). Kept beside `cmd/wakil-pm`'s three `AddTool`s.
public let wakilPMToolNames = ["my_issues", "search_issues", "get_issue"]

// MARK: - What Settings → Connections draws

/// A connection row's dot and word (design-language §5): green connected, amber needs sign-in,
/// red failing; unchecked before its first check, dim.
public enum ConnectionDot: Sendable, Equatable {
    case connected, needsSignIn, failing, unchecked

    public var word: String {
        switch self {
        case .connected: "connected"
        case .needsSignIn: "needs sign-in"
        case .failing: "failing"
        case .unchecked: "not checked"
        }
    }
}

/// The dot for a connection: its last check when there is one; before that, a sign-in kind never
/// signed in already needs one.
public func connectionDot(_ c: SettingsConnection, status: ConnectionStatus?) -> ConnectionDot {
    switch status {
    case .connected?: return .connected
    case .needsSignIn?: return .needsSignIn
    case .failing?: return .failing
    case nil: return c.signIn != "none" && !c.signedIn ? .needsSignIn : .unchecked
    }
}

/// The Jira entry's dot: it needs a site and a stored sign-in; it is checked by `wakil-pm` itself.
public func jiraDot(_ org: SettingsOrg) -> ConnectionDot {
    !org.jiraBase.isEmpty && org.jiraTokenStored ? .connected : .needsSignIn
}

/// The status line: "Connected · 9 tools · checked 2 min ago", or the error whole (Rule 8).
public func connectionStatusLine(_ status: ConnectionStatus, now: Date = Date()) -> String {
    switch status {
    case .connected(let tools, let at):
        let count = tools.count == 1 ? "1 tool" : "\(tools.count) tools"
        let minutes = Int(now.timeIntervalSince(at) / 60)
        let ago = minutes < 1 ? "checked just now" : "checked \(minutes) min ago"
        return "Connected · \(count) · \(ago)"
    case .needsSignIn:
        return "Needs sign-in"
    case .failing(let error):
        return error
    }
}

/// One row of the Tools table: **Tool · Server says · Allow agent**.
public struct ConnectionToolRow: Sendable, Equatable, Identifiable {
    public var name: String
    /// read-only, writes, destructive or —.
    public var says: String
    public var allowed: Bool
    public var locked: Bool
    public var id: String { name }
}

/// The table's rows: the tools a check just listed, else the ones last recorded, by name. The
/// switch is Go's `ToolAllowed`: a destructive tool is locked off; else the operator's switch;
/// with none, only a read-only tool is on.
public func connectionToolRows(_ c: SettingsConnection, live: [ConnectionTool]? = nil) -> [ConnectionToolRow] {
    let tools = live ?? c.hints.keys.sorted().map { ConnectionTool(name: $0, hint: c.hints[$0] ?? "") }
    return tools.map { tool in
        let says = ["readOnly": "read-only", "writes": "writes", "destructive": "destructive"][tool.hint] ?? "—"
        if tool.hint == "destructive" {
            return ConnectionToolRow(name: tool.name, says: says, allowed: false, locked: true)
        }
        return ConnectionToolRow(name: tool.name, says: says, allowed: c.allow[tool.name] ?? (tool.hint == "readOnly"), locked: false)
    }
}

/// A custom server's secret entries, from its Keychain keys: `env:<NAME>` an environment
/// variable, `header:<Name>` a header.
public func connectionSecretEntries(_ c: SettingsConnection) -> [(kind: String, name: String, key: String)] {
    c.secretKeys.compactMap { key in
        if key.hasPrefix("env:") { return ("Environment variable", String(key.dropFirst(4)), key) }
        if key.hasPrefix("header:") { return ("Header", String(key.dropFirst(7)), key) }
        return nil
    }
}
