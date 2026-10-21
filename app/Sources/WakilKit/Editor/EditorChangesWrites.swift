import Foundation

/// The roots with a git write running (3a-ii). One write per root at a time: a second is refused,
/// another root's is not. One per window assembly (`WakilWiring.gitWrites`); the actions begin and end
/// here and the window reads `running(_:)` for the spinners.
public actor GitWriteFlights {
    private var roots: Set<String> = []
    public init() {}
    /// Claims `root`; false when a write already holds it.
    public func begin(_ root: String) -> Bool { roots.insert(root).inserted }
    public func end(_ root: String) { roots.remove(root) }
    public func running(_ root: String) -> Bool { roots.contains(root) }
}

/// Registers the seven `editor_changes_*` git writes (3a-ii). Each is a mutation priced allow in every
/// environment: a stage, an unstage and a commit stay on this Mac and undo; a discard goes to the Trash.
func registerEditorChangesWrites(
    into registry: ActionRegistry, gitStatus: GitStatus?, panes: PaneStore, layout: LayoutStore?,
    writes: GitWriteFlights
) async {
    @Sendable func strings(_ params: JSONValue, _ key: String) -> [String]? {
        guard case .object(let o) = params, case .array(let a)? = o[key] else { return nil }
        return a.compactMap { if case .string(let s) = $0 { s } else { nil } }
    }
    @Sendable func bool(_ params: JSONValue, _ key: String) -> Bool? {
        guard case .object(let o) = params, case .bool(let b)? = o[key] else { return nil }
        return b
    }
    @Sendable func requireString(_ params: JSONValue, _ key: String, action: String) throws -> String {
        guard let v = optionalString(params, key) else {
            throw StandardActionError.missingParam(action: action, param: key)
        }
        return v
    }
    @Sendable func relative(_ path: String, to root: String) -> String {
        path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
    }
    @Sendable func rootState(_ root: String) async -> GitRootState? {
        await gitStatus?.roots.first { $0.root == root }
    }
    @Sendable func rootName(_ root: String) async -> String {
        if let n = await rootState(root)?.name, !n.isEmpty { return n }
        return (root as NSString).lastPathComponent
    }
    /// `paths`, else every path of `group` in the root's last status; refuses when neither names a file.
    @Sendable func targets(_ params: JSONValue, root: String, action: String) async throws -> [String] {
        if let paths = strings(params, "paths"), !paths.isEmpty { return paths.map { relative($0, to: root) } }
        if let g = optionalString(params, "group") {
            guard let group = GitGroup(rawValue: g) else {
                throw EditorFilesError(description: "\(action): group is staged, changed or untracked")
            }
            let rows = await rootState(root)?.files.filter { $0.group == group }.map(\.path) ?? []
            guard !rows.isEmpty else { throw EditorFilesError(description: "\(action): nothing is \(g) in \(await rootName(root))") }
            return rows
        }
        throw StandardActionError.missingParam(action: action, param: "paths")
    }
    /// The tool's own fields: `structuredContent` when the reply nests them there.
    @Sendable func fields(_ result: JSONValue) -> JSONValue {
        if case .object(let o) = result, let s = o["structuredContent"] { return s }
        return result
    }
    /// One write on `root`: refused while another runs there, the root's status read again after.
    @Sendable func write(
        _ root: String, action: String, _ body: @Sendable (any ToolCaller) async throws -> JSONValue
    ) async throws -> JSONValue {
        guard let git = gitStatus?.git else { throw StandardActionError.missingClient(action: action, role: "git") }
        guard await writes.begin(root) else {
            throw EditorFilesError(description: "\(action): a git write is already running in \(await rootName(root))")
        }
        let result: JSONValue
        do { result = try await body(git) } catch {
            await writes.end(root)
            await gitStatus?.refresh(only: root)
            throw error
        }
        await writes.end(root)
        await gitStatus?.refresh(only: root)
        return fields(result)
    }
    @Sendable func call(
        _ git: any ToolCaller, _ tool: String, _ args: [String: JSONValue], action: String,
        timeout: TimeInterval = MCPClient.mutationReplyTimeout
    ) async throws -> JSONValue {
        try await callCheckedTool(git, tool: tool, arguments: .object(args), action: action, timeout: timeout)
    }
    @Sendable func rootSchema(_ extra: [String: JSONValue] = [:], required: [String] = ["root"]) -> JSONValue {
        var props: [String: JSONValue] = ["root": .object(["type": .string("string")])]
        for (k, v) in extra { props[k] = v }
        return .object(["type": .string("object"), "properties": .object(props),
                        "required": .array(required.map { .string($0) })])
    }
    let pathsSchema: JSONValue = .object(["type": .string("array"), "items": .object(["type": .string("string")])])
    let groupSchema: JSONValue = .object(["type": .string("string"), "enum": .array(GitGroup.allCases.map { .string($0.rawValue) })])
    let price: (production: GateDecision, otherwise: GateDecision) = (production: .allow, otherwise: .allow)

    /// stage / unstage / discard share one shape: root plus paths or a group.
    @Sendable func pathWrite(_ name: String, tool: String, description: String) async {
        await registry.register(Action(
            name: name, description: description, kind: .mutate, audience: .agentReachable,
            schema: rootSchema(["paths": pathsSchema, "group": groupSchema]),
            handler: { params in
                let root = try requireString(params, "root", action: name)
                let paths = try await targets(params, root: root, action: name)
                return try await write(root, action: name) { git in
                    try await call(git, tool, ["root": .string(root), "paths": .array(paths.map { .string($0) })], action: name)
                }
            },
            price: price))
    }
    await pathWrite("editor_changes_stage", tool: "git_stage",
        description: "Stage files in one root: paths (relative to root, or absolute), or group (changed or untracked) for every file in it. Allowed everywhere; editor_changes_unstage reverses it.")
    await pathWrite("editor_changes_unstage", tool: "git_unstage",
        description: "Unstage files in one root: paths, or group (staged) for every staged file. The working tree is untouched. Allowed everywhere.")
    await pathWrite("editor_changes_discard", tool: "git_discard",
        description: "Discard the working-tree changes of files in one root: paths, or group (changed or untracked). Discarded files go to the Trash, where Finder's Put Back restores them; answers trashed, the names. Allowed everywhere.")

    await registry.register(Action(
        name: "editor_changes_commit",
        description: "Commit what is staged in one root — or, with all (the default when nothing is staged), every change there, untracked files included — with message. Runs the repository's hooks and signing, as the organisation's git identity when Settings sets one. Allowed everywhere: a commit stays on this Mac and editor_changes_undo_commit reverses it.",
        kind: .mutate, audience: .agentReachable,
        schema: rootSchema(["message": .object(["type": .string("string")]),
                            "all": .object(["type": .string("boolean")])], required: ["root", "message"]),
        handler: { params in
            let root = try requireString(params, "root", action: "editor_changes_commit")
            let message = try requireString(params, "message", action: "editor_changes_commit")
            let staged = await rootState(root)?.files.contains { $0.group == .staged } ?? false
            let all = bool(params, "all") ?? !staged
            return try await write(root, action: "editor_changes_commit") { git in
                try await call(git, "git_commit", ["root": .string(root), "message": .string(message), "all": .bool(all)],
                               action: "editor_changes_commit", timeout: MCPClient.gitWriteReplyTimeout)
            }
        },
        price: price))

    await registry.register(Action(
        name: "editor_changes_amend",
        description: "Amend the last commit in one root with what is staged, and message when given (else its message is kept). Runs hooks and signing. Allowed everywhere.",
        kind: .mutate, audience: .agentReachable,
        schema: rootSchema(["message": .object(["type": .string("string")])]),
        handler: { params in
            let root = try requireString(params, "root", action: "editor_changes_amend")
            var built: [String: JSONValue] = ["root": .string(root)]
            if let m = optionalString(params, "message") { built["message"] = .string(m) }
            let args = built
            return try await write(root, action: "editor_changes_amend") { git in
                try await call(git, "git_amend", args, action: "editor_changes_amend", timeout: MCPClient.gitWriteReplyTimeout)
            }
        },
        price: price))

    await registry.register(Action(
        name: "editor_changes_undo_commit",
        description: "Undo the last commit in one root, keeping its changes staged; answers message, the commit's message. Allowed everywhere.",
        kind: .mutate, audience: .agentReachable,
        schema: rootSchema(),
        handler: { params in
            let root = try requireString(params, "root", action: "editor_changes_undo_commit")
            return try await write(root, action: "editor_changes_undo_commit") { git in
                try await call(git, "git_undo_commit", ["root": .string(root)], action: "editor_changes_undo_commit")
            }
        },
        price: price))

    await registry.register(Action(
        name: "editor_changes_stage_hunk",
        description: "Stage one change of an open file: path (absolute) and hunk (its index in the file's changes, default the one the peek shows). The index gains only that change; the buffer is untouched. Allowed everywhere.",
        kind: .mutate, audience: .agentReachable,
        schema: rootSchema(["path": .object(["type": .string("string")]), "hunk": .object(["type": .string("integer")])],
                           required: ["path"]).withoutRequired("root"),
        handler: { params in
            let action = "editor_changes_stage_hunk"
            let path = try requireString(params, "path", action: action)
            var found: EditorTab?
            if let layout {
                for pane in await layout.snapshot().panes where pane.kind == "editor" {
                    if let t = await panes.editorSnapshot(paneId: pane.id).tabs.first(where: { $0.path == path }) { found = t; break }
                }
            }
            guard let tab = found else { throw EditorFilesError(description: "\(action): \(path) is not open in an editor pane") }
            guard let base = tab.baseline else {
                throw EditorFilesError(description: "\(action): \(path) has no index text to compare (untracked, or outside a repository)")
            }
            guard let hunk = (params.objectValue?["hunk"]?.intValue) ?? tab.peek else {
                throw StandardActionError.missingParam(action: action, param: "hunk")
            }
            guard let content = editorStagedText(base: base, text: tab.text, hunk: hunk) else {
                throw EditorFilesError(description: "\(action): \(path) has no change \(hunk)")
            }
            let known = await gitStatus?.roots.map(\.root) ?? []
            var root = known.filter { path.hasPrefix($0 + "/") }.max { $0.count < $1.count }
            if root == nil, case .file(_, let r) = tab.subject { root = r }
            guard let root else { throw EditorFilesError(description: "\(action): \(path) is in no git root of the project") }
            let rel = relative(path, to: root)
            return try await write(root, action: action) { git in
                let blob = fields(try await call(git, "git_blob", ["root": .string(root), "path": .string(rel)], action: action,
                                                 timeout: MCPClient.readReplyTimeout))
                guard case .object(let b) = blob, case .string(let expect)? = b["blob"] else {
                    throw EditorFilesError(description: "\(action): git_blob answered no blob for \(rel)")
                }
                return try await call(git, "git_stage_hunk",
                                      ["root": .string(root), "path": .string(rel), "content": .string(content), "expect": .string(expect)],
                                      action: action)
            }
        },
        price: price))
}

private extension JSONValue {
    var objectValue: [String: JSONValue]? { if case .object(let o) = self { o } else { nil } }
    @Sendable func withoutRequired(_ key: String) -> JSONValue {
        guard case .object(var o) = self, case .array(let r)? = o["required"] else { return self }
        o["required"] = .array(r.filter { $0 != .string(key) })
        if case .object(var p)? = o["properties"] { p[key] = nil; o["properties"] = .object(p) }
        return .object(o)
    }
}
