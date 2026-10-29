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
    /// Returns once no write runs, or after `limit` seconds; true when none was left running.
    /// `WakilWiring.switchOrg` waits here before it stops wakil-git, so a running commit finishes.
    public func drained(within limit: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(limit)
        while !roots.isEmpty {
            if Date() >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }
}

/// Registers the `editor_changes_*` git writes (3a-ii, and those of 3a-iii to 3a-v-b). Each is a mutation priced allow in every
/// environment: a stage, an unstage and a commit stay on this Mac and undo; a discard goes to the Trash.
/// How long a remote git operation may take before the call gives up: a large push or a slow host.
let gitRemoteReplyTimeout: TimeInterval = 600

func registerEditorChangesWrites(
    into registry: ActionRegistry, gitStatus: GitStatus?, panes: PaneStore, layout: LayoutStore?,
    writes: GitWriteFlights, ticket: EditorTicketStore? = nil
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
    /// `paths`, else every path of `group` in the root's last status; refuses when neither names a file,
    /// or the group is not one this write takes (`groups`). With `renames`, a staged rename brings its
    /// old path along: unstaging only the new one would leave the deletion staged.
    @Sendable func targets(
        _ params: JSONValue, root: String, action: String, groups: [GitGroup], renames: Bool
    ) async throws -> [String] {
        func withRenames(_ paths: [String]) async -> [String] {
            guard renames else { return paths }
            let staged = await rootState(root)?.files.filter { $0.group == .staged } ?? []
            var out: [String] = []
            for p in paths {
                out.append(p)
                if let orig = staged.first(where: { $0.path == p })?.origPath, !out.contains(orig), !paths.contains(orig) {
                    out.append(orig)
                }
            }
            return out
        }
        if let paths = strings(params, "paths"), !paths.isEmpty { return await withRenames(paths.map { relative($0, to: root) }) }
        if let g = optionalString(params, "group") {
            guard let group = GitGroup(rawValue: g) else {
                throw EditorFilesError(description: "\(action): group is conflicts, staged, changed or untracked")
            }
            guard groups.contains(group) else {
                throw EditorFilesError(description:
                    "\(action) takes group \(groups.map(\.rawValue).joined(separator: " or ")), not \(g)")
            }
            let rows = await rootState(root)?.files.filter { $0.group == group }.map(\.path) ?? []
            guard !rows.isEmpty else { throw EditorFilesError(description: "\(action): nothing is \(g) in \(await rootName(root))") }
            return await withRenames(rows)
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
    @Sendable func pathWrite(
        _ name: String, tool: String, groups: [GitGroup], renames: Bool = false, description: String
    ) async {
        await registry.register(Action(
            name: name, description: description, kind: .mutate, audience: .agentReachable,
            schema: rootSchema(["paths": pathsSchema, "group": groupSchema]),
            handler: { params in
                let root = try requireString(params, "root", action: name)
                let paths = try await targets(params, root: root, action: name, groups: groups, renames: renames)
                return try await write(root, action: name) { git in
                    try await call(git, tool, ["root": .string(root), "paths": .array(paths.map { .string($0) })], action: name)
                }
            },
            price: price))
    }
    await pathWrite("editor_changes_stage", tool: "git_stage", groups: [.changed, .untracked],
        description: "Stage files in one root: paths (relative to root, or absolute), or group (changed or untracked) for every file in it. Allowed everywhere; editor_changes_unstage reverses it.")
    await pathWrite("editor_changes_unstage", tool: "git_unstage", groups: [.staged], renames: true,
        description: "Unstage files in one root: paths, or group (staged) for every staged file; a staged rename's old path is unstaged with it. A path with nothing staged is left as it is. The working tree is untouched. Allowed everywhere.")
    await pathWrite("editor_changes_discard", tool: "git_discard", groups: [.changed, .untracked],
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
        description: "Stage one change of an open file: path (absolute), hunk (its index in the file's changes, default the one the peek shows) and pane (the editor pane whose tab to use; default the first with the file open). The index gains only that change; the buffer is untouched. Allowed everywhere.",
        kind: .mutate, audience: .agentReachable,
        schema: rootSchema(["path": .object(["type": .string("string")]), "hunk": .object(["type": .string("integer")]),
                            "pane": .object(["type": .string("string")])],
                           required: ["path"]).withoutRequired("root"),
        handler: { params in
            let action = "editor_changes_stage_hunk"
            let path = try requireString(params, "path", action: action)
            var found: EditorTab?
            if let layout {
                // The given pane first: the same file open in two panes can show two different changes.
                let wanted = optionalString(params, "pane")
                let editors = await layout.snapshot().panes.filter { $0.kind == "editor" }
                for pane in editors.filter({ $0.id == wanted }) + editors.filter({ $0.id != wanted }) {
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
                // R1: the guard is the id of the text the peek was computed from (the tab's baseline), so an
                // index that moved since refuses in Go. Asking git for the blob now would compare it to itself.
                let expect = gitBlobId(base)
                return try await call(git, "git_stage_hunk",
                                      ["root": .string(root), "path": .string(rel), "content": .string(content), "expect": .string(expect)],
                                      action: action)
            }
        },
        price: price))

    // 3a-ii-b: Stage and Unstage Selected Ranges. A diff's two sides — the tab's when one is open for
    // the path in that group (the given pane first), else read fresh — and the selected lines of
    // the modified side; the index gains (or loses) only those, through git_stage_hunk's guard.
    @Sendable func rangeWrite(_ name: String, group: GitGroup, description: String) async {
        await registry.register(Action(
            name: name, description: description,
            kind: .mutate, audience: .agentReachable,
            schema: rootSchema(["path": .object(["type": .string("string")]),
                                "ranges": .object(["type": .string("array"), "items": .object([
                                    "type": .string("object"),
                                    "properties": .object(["start": .object(["type": .string("integer")]),
                                                           "end": .object(["type": .string("integer")])])])]),
                                "pane": .object(["type": .string("string")])],
                               required: ["path"]).withoutRequired("root"),
            handler: { params in
                let path = try requireString(params, "path", action: name)
                let known = await gitStatus?.roots.map(\.root) ?? []
                guard let root = known.filter({ path.hasPrefix($0 + "/") }).max(by: { $0.count < $1.count }) else {
                    throw EditorFilesError(description: "\(name): \(path) is in no git root of the project")
                }
                let rel = relative(path, to: root)
                let rows = await rootState(root)?.files.filter { $0.path == rel } ?? []
                if rows.contains(where: { $0.group == .conflicts || $0.status == "U" }) {
                    throw EditorFilesError(description: "\(name): \(rel) has a merge conflict; its index holds stages, not one text")
                }
                if group == .staged, rows.contains(where: { $0.group == .staged && $0.status == "D" }) {
                    throw EditorFilesError(description: "\(name): \(rel) is staged as deleted; − on its row unstages it")
                }
                // Final review M2: a deleted file has no lines to select; + on its row stages the deletion.
                if group == .changed, rows.contains(where: { $0.group == .changed && $0.status == "D" }) {
                    throw EditorFilesError(description: "\(name): \(rel) is deleted; + on its row stages the deletion")
                }
                var tab: EditorTab?
                if let layout {
                    let wanted = optionalString(params, "pane")
                    let editors = await layout.snapshot().panes.filter { $0.kind == "editor" }
                    for pane in editors.filter({ $0.id == wanted }) + editors.filter({ $0.id != wanted }) {
                        // A refreshing tab (loading) keeps the texts on screen, which the selection is of
                        // (final review I2); a first load's empty texts hold no change and are refused.
                        if let t = await panes.editorSnapshot(paneId: pane.id).tabs.first(where: {
                            if case .diff(root, rel, group, nil) = $0.subject { $0.diffState != nil } else { false }
                        }) { tab = t; break }
                    }
                }
                let state: GitDiffState
                if let d = tab?.diffState {
                    state = d
                } else {
                    guard let git = gitStatus?.git else { throw StandardActionError.missingClient(action: name, role: "git") }
                    let revs = group == .staged ? ("HEAD", "index") : ("index", "worktree")
                    func show(_ rev: String) async throws -> (text: String, binary: Bool, truncated: Bool, bytes: Int) {
                        let f = fields(try await call(git, "git_show", ["root": .string(root), "path": .string(rel), "rev": .string(rev)],
                                                      action: name, timeout: MCPClient.readReplyTimeout))
                        guard case .object(let o) = f else { return ("", false, false, 0) }
                        let text: String = if case .string(let t)? = o["text"] { t } else { "" }
                        return (text, o["binary"] == .bool(true), o["truncated"] == .bool(true), Int(o["bytes"]?.intValue ?? 0))
                    }
                    let a = try await show(revs.0), b = try await show(revs.1)
                    state = GitDiffState(original: a.text, modified: b.text, language: "", binary: a.binary || b.binary,
                                         bytes: max(a.bytes, b.bytes), lines: 0, truncated: a.truncated || b.truncated,
                                         error: nil, loading: false)
                }
                if let banner = gitDiffBanner(state) {
                    throw EditorFilesError(description: "\(name): \(rel) is \(banner); part of it cannot be staged without losing the rest")
                }
                if editorHunkLines(state.original).count > editorHunksLineCap || editorHunkLines(state.modified).count > editorHunksLineCap {
                    throw EditorFilesError(description: "\(name): \(rel) is over \(editorHunksLineCap) lines; its changes are not compared")
                }
                let spans: [EditorLineSpan]
                if case .object(let o) = params, case .array(let a)? = o["ranges"] {
                    spans = a.compactMap { v in
                        guard case .object(let r) = v, let s = r["start"]?.intValue, let e = r["end"]?.intValue else { return nil }
                        return EditorLineSpan(start: Int(min(s, e)), end: Int(max(s, e)))
                    }
                } else if let tab {
                    // The page reports a caret as no selection: the caret's line is a one-line one.
                    spans = editorLineSpans([tab.selection ?? EditorRange(start: tab.cursor, end: tab.cursor)])
                } else {
                    throw StandardActionError.missingParam(action: name, param: "ranges")
                }
                let content = group == .staged
                    ? editorUnstagedText(base: state.original, text: state.modified, ranges: spans)
                    : editorStagedText(base: state.original, text: state.modified, ranges: spans)
                guard let content else { throw EditorFilesError(description: "\(name): the selection holds no change") }
                // The guard is the index text the ranges were computed against: the original when
                // staging (index vs work tree), the modified side when unstaging (HEAD vs index).
                let expect = gitBlobId(group == .staged ? state.modified : state.original)
                return try await write(root, action: name) { git in
                    do {
                        return try await call(git, "git_stage_hunk",
                                              ["root": .string(root), "path": .string(rel), "content": .string(content),
                                               "expect": .string(expect)], action: name)
                    } catch let e where "\(e)".contains("the change moved") {
                        throw EditorFilesError(description: "\(name): the change moved — reopen the diff")
                    }
                }
            },
            price: price))
    }
    // 3a-iii-a: the remote operations, with the organisation's account for the remote's host, priced
    // allow for every channel (Decision 44). They take the root's one write lock (R1), so a commit and
    // a push never overlap, and the status is read again after, ahead and behind with it.
    for (name, tool, what) in [
        ("editor_changes_fetch", "git_fetch", "Fetch one root's remote (git fetch --prune) with the organisation's account."),
        ("editor_changes_pull", "git_pull", "Pull one root's upstream by the organisation's pull strategy; a conflict stops it, left in the tree to resolve, and names the paths."),
        ("editor_changes_push", "git_push", "Push one root's branch to its upstream with the organisation's account. Never forces."),
        ("editor_changes_sync", "git_sync", "Pull one root's upstream, then push, stopping at the first failure."),
        ("editor_changes_publish", "git_publish", "Push one root's branch to origin and set it as the upstream."),
    ] {
        await registry.register(Action(
            name: name, description: what + " root (absolute). Allowed everywhere.",
            kind: .mutate, audience: .agentReachable,
            schema: rootSchema(),
            handler: { params in
                let root = try requireString(params, "root", action: name)
                let out = try await write(root, action: name) { git in
                    try await call(git, tool, ["root": .string(root)], action: name, timeout: gitRemoteReplyTimeout)
                }
                // A push starts CI and can open or move a PR: the Ticket view reads the root again.
                if ["editor_changes_push", "editor_changes_sync", "editor_changes_publish"].contains(name) {
                    await ticket?.invalidate(root: root)
                }
                return out
            },
            price: price))
    }

    // 3a-iv: branches and stash (Decision 46). Every write goes through `write`, one per root at a time;
    // none forces. Delete and drop carry an agent price of gate: the operator's click confirms in place,
    // the agent's ask raises the plane.
    @Sendable func intParam(_ params: JSONValue, _ key: String, action: String) throws -> Int {
        guard case .object(let o) = params, let v = o[key]?.intValue else {
            throw StandardActionError.missingParam(action: action, param: key)
        }
        return v
    }
    @Sendable func forward(_ params: JSONValue, _ keys: [String]) -> [String: JSONValue] {
        guard case .object(let o) = params else { return [:] }
        return o.filter { keys.contains($0.key) }
    }
    let string: JSONValue = .object(["type": .string("string")])
    let integer: JSONValue = .object(["type": .string("integer")])
    let boolean: JSONValue = .object(["type": .string("boolean")])
    for (name, tool, what) in [
        ("editor_changes_branches", "git_branches", "Read one root's branches: local ones most recently committed first, remote ones no local tracks, and the current branch."),
        ("editor_changes_stashes", "git_stashes", "Read one root's stashes, newest first, with the files each holds; act on one by its index and id."),
    ] {
        await registry.register(Action(
            name: name, description: what + " root (absolute).", kind: .read, audience: .agentReachable,
            schema: rootSchema(),
            handler: { params in
                let root = try requireString(params, "root", action: name)
                guard let git = gitStatus?.git else { throw StandardActionError.missingClient(action: name, role: "git") }
                return fields(try await call(git, tool, ["root": .string(root)], action: name, timeout: MCPClient.readReplyTimeout))
            }))
    }
    for (name, tool, keys, required, what, agentPrice) in [
        ("editor_changes_switch", "git_switch", ["branch", "carry", "track"], ["root", "branch"],
         "Switch one root to a branch (track: a remote branch to create it from). Changes in the way come back as blocked unless carry is stash or bring (stash, switch, pop); bring's clash is left in the tree to resolve, the stash kept, and editor_changes_stash_undo_apply puts it back when the stash's files had no changes of the operator's own before the pop. Never forces.", GateDecision?.none),
        ("editor_changes_branch_create", "git_switch", ["name", "from"], ["root", "name"],
         "Create a branch in one root and switch to it, from the current commit or from; an existing name is switched to.", nil),
        ("editor_changes_branch_rename", "git_branch_rename", ["to"], ["root", "to"],
         "Rename one root's current branch; a name that exists is refused.", nil),
        ("editor_changes_branch_delete", "git_branch_delete", ["branch", "force"], ["root", "branch"],
         "Delete one root's local branch; with commits no other branch has it is refused unless force. Asks the operator when you ask.", .gate),
        ("editor_changes_stash", "git_stash", ["message", "mode"], ["root"],
         "Stash one root's changes: mode default, untracked or staged, with an optional message.", nil),
        ("editor_changes_stash_apply", "git_stash_apply", ["index", "id"], ["root", "index", "id"],
         "Apply one stash by index and id, keeping it. A clash is left in the tree to resolve; when the stash's files had no changes of the operator's own before the apply, editor_changes_stash_undo_apply puts back the files it touched (otherwise it is resolved by hand).", nil),
        ("editor_changes_stash_pop", "git_stash_pop", ["index", "id"], ["root", "index", "id"],
         "Apply one stash by index and id and drop it. A clash is left in the tree to resolve and the stash kept; when the stash's files had no changes of the operator's own before the pop, editor_changes_stash_undo_apply puts back the files it touched (otherwise it is resolved by hand).", nil),
        ("editor_changes_stash_drop", "git_stash_drop", ["index", "id"], ["root", "index", "id"],
         "Drop one stash by index and id; it cannot be applied again. Asks the operator when you ask.", .gate),
        ("editor_changes_stash_drop_all", "git_stash_drop_all", ["ids"], ["root"],
         "Drop the stashes listed by editor_changes_stashes (ids) in one root's repository — its worktrees share the list; one pushed since is kept. None can be applied again. Asks the operator when you ask.", .gate),
    ] as [(String, String, [String], [String], String, GateDecision?)] {
        var props: [String: JSONValue] = [:]
        for k in keys {
            props[k] = k == "index" ? integer : k == "force" ? boolean
                : k == "ids" ? .object(["type": .string("array"), "items": string]) : string
        }
        await registry.register(Action(
            name: name, description: what + " root (absolute).", kind: .mutate, audience: .agentReachable,
            schema: rootSchema(props, required: required),
            handler: { params in
                let root = try requireString(params, "root", action: name)
                for k in required where k != "root" {
                    if k == "index" { _ = try intParam(params, k, action: name) } else { _ = try requireString(params, k, action: name) }
                }
                var args = forward(params, keys)
                args["root"] = .string(root)
                if name == "editor_changes_branch_create", let n = args.removeValue(forKey: "name") {
                    args["branch"] = n
                    args["create"] = .bool(true)
                }
                if name == "editor_changes_switch", let track = args["track"] {
                    args["create"] = .bool(true)   // a remote branch is checked out as a new local tracking it
                    args["track"] = track
                }
                let callArgs = args
                let result = try await write(root, action: name) { git in
                    try await call(git, tool, callArgs, action: name, timeout: gitRemoteReplyTimeout)
                }
                // 3a-v-b (R4): a clash left in the tree is remembered for Undo Apply.
                if let clash = GitStashClash(result: result) { await gitStatus?.remember(clash, root: root) }
                return result
            },
            price: price, agentPrice: agentPrice))
    }

    // 3a-v-b: merge, rebase and resolving (Decision 47). A stop on conflicts is a result (done false, the
    // paths, the note), not an error. What throws work away — Abort, Skip, a whole-file take, Undo Apply —
    // carries an agent price of gate: the operator's press confirms in place, the agent's ask raises the plane.
    for (name, tool, keys, required, what, agentPrice) in [
        ("editor_changes_merge", "git_merge", ["branch"], ["root", "branch"],
         "Merge a branch into one root's current one (autostashing). One that applies cleanly commits with git's message; conflicts stop it with done false and the paths, left in the tree to resolve.", GateDecision?.none),
        ("editor_changes_rebase", "git_rebase", ["onto"], ["root", "onto"],
         "Rebase one root's current branch onto another (autostashing). Conflicts stop it at one commit with done false and the paths; resolve them, then editor_changes_continue, _skip or _abort.", nil),
        ("editor_changes_continue", "git_continue", ["message"], ["root"],
         "Finish the merge, rebase, cherry-pick or revert in progress in one root once its conflicts are resolved and staged, with message when given (else git's). Refused naming the files that still conflict; a rebase may stop again at the next commit.", nil),
        ("editor_changes_skip", "git_skip", [], ["root"],
         "Skip the commit a rebase in one root stopped on; its changes are left out of the rebase. Asks the operator when you ask.", .gate),
        ("editor_changes_abort", "git_abort", [], ["root"],
         "Abort the merge, rebase, cherry-pick or revert in progress in one root; the tree goes back to before it and the resolutions made are lost. Asks the operator when you ask.", .gate),
    ] as [(String, String, [String], [String], String, GateDecision?)] {
        await registry.register(Action(
            name: name, description: what + " root (absolute).", kind: .mutate, audience: .agentReachable,
            schema: rootSchema(Dictionary(uniqueKeysWithValues: keys.map { ($0, string) }), required: required),
            handler: { params in
                let root = try requireString(params, "root", action: name)
                for k in required where k != "root" { _ = try requireString(params, k, action: name) }
                var args = forward(params, keys)
                args["root"] = .string(root)
                let callArgs = args
                return try await write(root, action: name) { git in
                    try await call(git, tool, callArgs, action: name, timeout: MCPClient.gitWriteReplyTimeout)
                }
            },
            price: price, agentPrice: agentPrice))
    }
    // R1: a whole-file take that loses edits (current, incoming, delete) is gated for the agent; Keep File
    // keeps what is in the tree and is not. `+` on the row stays editor_changes_stage.
    for (name, takes, what, agentPrice) in [
        ("editor_changes_take", ["current", "incoming", "delete"],
         "Resolve one conflicted file whole: path (relative to root, or absolute) and take — current (HEAD's), incoming, or delete for a delete/modify conflict. Stages the result; edits made to the file are lost. Asks the operator when you ask.", GateDecision.gate),
        ("editor_changes_keep_file", [],
         "Resolve one delete/modify conflict by keeping the file as it is in the tree: path (relative to root, or absolute). Stages it.", nil),
    ] as [(String, [String], String, GateDecision?)] {
        var props: [String: JSONValue] = ["path": string]
        if !takes.isEmpty { props["take"] = .object(["type": .string("string"), "enum": .array(takes.map { .string($0) })]) }
        await registry.register(Action(
            name: name, description: what + " root (absolute).", kind: .mutate, audience: .agentReachable,
            schema: rootSchema(props, required: takes.isEmpty ? ["root", "path"] : ["root", "path", "take"]),
            handler: { params in
                let root = try requireString(params, "root", action: name)
                let path = relative(try requireString(params, "path", action: name), to: root)
                var take = "keep"
                if !takes.isEmpty {
                    take = try requireString(params, "take", action: name)
                    guard takes.contains(take) else {
                        throw EditorFilesError(description: "\(name): take is current, incoming or delete, not \(take)")
                    }
                }
                let args: [String: JSONValue] = ["root": .string(root), "path": .string(path), "take": .string(take)]
                return try await write(root, action: name) { git in try await call(git, "git_resolve", args, action: name) }
            },
            price: price, agentPrice: agentPrice))
    }
    // Call 13 / R4: Undo Apply sends back the clash this session's own stash apply, pop or Bring Them Along
    // left in the root (Go records one only when the stash's files were clean before the apply); Go
    // refuses it naming any file changed since, or a stash that is gone.
    await registry.register(Action(
        name: "editor_changes_stash_undo_apply",
        description: "Undo the stash apply, pop or Bring Them Along that clashed in one root this session: the files it touched go back to HEAD, the untracked ones it created are removed, and the stash stays in the list. Refused, naming the file, when one changed since the clash, or when the stash is gone. Asks the operator when you ask. root (absolute).",
        kind: .mutate, audience: .agentReachable,
        schema: rootSchema(),
        handler: { params in
            let name = "editor_changes_stash_undo_apply"
            let root = try requireString(params, "root", action: name)
            guard let clash = await gitStatus?.clashes[root] else {
                throw EditorFilesError(description: "\(name): No stash clash to undo")
            }
            let result = try await write(root, action: name) { git in
                try await call(git, "git_stash_undo_apply", ["root": .string(root), "clash": clash.json], action: name)
            }
            await gitStatus?.forgetClash(root)
            return result
        },
        price: price, agentPrice: .gate))

    // 3a-iii-a: clone from a link. The operator's clone may go anywhere and becomes a project in
    // WindowModel.cloneProject; the agent's goes only into the folder the operator last cloned into,
    // and registers nothing — adding a project is the operator's (Decision 30, call 6).
    await registry.register(Action(
        name: "editor_clone",
        description: "Clone a repository from a link (https://…, git@host:…) into the folder the operator last cloned into, "
            + "with the organisation's account for its host: url; folder only as the operator's. Answers path. It does not add a "
            + "project; ask the operator to add it. Allowed everywhere.",
        kind: .mutate, audience: .agentReachable,
        schema: .object(["type": .string("object"),
                         "properties": .object(["url": .object(["type": .string("string")]),
                                                "folder": .object(["type": .string("string")])]),
                         "required": .array([.string("url")])]),
        handler: { params in
            let url = try requireString(params, "url", action: "editor_clone")
            guard let git = gitStatus?.git else { throw StandardActionError.missingClient(action: "editor_clone", role: "git") }
            let byOperator = ActionRegistry.dispatchOrigin == .ui
            var args: [String: JSONValue] = ["url": .string(url), "operator": .bool(byOperator)]
            if let folder = optionalString(params, "folder") { args["folder"] = .string(folder) }
            let reply = fields(try await call(git, "git_clone", args, action: "editor_clone", timeout: gitRemoteReplyTimeout))
            guard !byOperator, case .object(var o) = reply, case .string(let path)? = o["path"] else { return reply }
            o["message"] = .string("Cloned to \(path) — Add as project in Settings → + Add a project")
            return .object(o)
        },
        price: price))

    await rangeWrite(
        "editor_changes_stage_ranges", group: .changed,
        description: "Stage the selected lines of one changed file: path (absolute), ranges ([{start, end}], 1-based "
            + "lines of the working-tree side; default the Changes diff tab's selection) and pane (whose diff tab to "
            + "use; default the first). Only the selected part of each change goes into the index. Allowed everywhere.")
    await rangeWrite(
        "editor_changes_unstage_ranges", group: .staged,
        description: "Unstage the selected lines of one staged file: path (absolute), ranges ([{start, end}], 1-based "
            + "lines of the index side; default the Staged diff tab's selection) and pane. Only the selected part of "
            + "each staged change leaves the index. Allowed everywhere.")
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
