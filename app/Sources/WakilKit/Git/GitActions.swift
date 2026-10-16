import Foundation

/// What a git pane has in flight: its one diff fetch.
///
/// **Synchronous, behind a lock, so it can be called inside `PaneStore.updateGit`.** The
/// diff flight is started in the same actor turn that writes the selection it is for, so
/// whichever write of the selection came last also started the flight that owns the diff
/// (Interaction Rules 4 and 5). Started anywhere later, two selects — or a select and a
/// refresh's reselect — could write in one order and start in the other: the older
/// flight cancels the newer, then fails its own selection check, and the diff loads
/// forever. `Mutex` would say this better, but it needs macOS 15.
final class GitFlights: @unchecked Sendable {
    private let lock = NSLock()
    private var diffs: [String: Task<Void, Never>] = [:]

    /// Cancels the pane's diff flight and starts `body` as its new one.
    func startDiff(_ pane: String, _ body: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        lock.withLock {
            diffs[pane]?.cancel()
            let task = Task { await body() }
            diffs[pane] = task
            return task
        }
    }

    /// Forgets `pane`: cancels its diff in flight. Called when
    /// the pane closes (`PaneStore.drop` → `onDrop`), so nothing of a closed pane keeps
    /// running or is held.
    func drop(_ pane: String) {
        lock.withLock {
            diffs.removeValue(forKey: pane)?.cancel()
        }
    }
}

/// The editor language a diff is shown in, from the file's extension.
func gitLanguage(for path: String) -> String {
    switch (path as NSString).pathExtension.lowercased() {
    case "php": "php"
    case "swift": "swift"
    case "ts", "tsx": "typescript"
    case "js", "jsx": "javascript"
    case "vue", "html": "html"
    case "go": "go"
    case "py": "python"
    case "json": "json"
    case "md": "markdown"
    case "sql": "sql"
    case "yml", "yaml": "yaml"
    case "css": "css"
    default: "plaintext"
    }
}

/// A wakil-git call's outcome: its `structuredContent`, or the reason it failed as one
/// whole text (Interaction Rule 8). Only cancellation is thrown.
private enum GitToolOutcome: Sendable {
    case ok([String: JSONValue])
    case failed(String)
}

private func gitTool(_ git: any ToolCaller, _ name: String, _ arguments: [String: JSONValue]) async throws
    -> GitToolOutcome
{
    let result: JSONValue
    do {
        result = try await git.callTool(
            name: name, arguments: .object(arguments), timeout: MCPClient.readReplyTimeout)
    } catch is CancellationError {
        throw CancellationError()
    } catch {
        if Task.isCancelled { throw CancellationError() }
        return .failed(String(describing: error))
    }
    guard case .object(let obj) = result else { return .failed("\(name) answered with no object") }
    if case .bool(true)? = obj["isError"] {
        return .failed(mcpErrorText(from: obj) ?? "\(name) failed with no message")
    }
    guard case .object(let content)? = obj["structuredContent"] else {
        return .failed("\(name) answered with no structuredContent")
    }
    return .ok(content)
}

/// The revisions a diff compares, by group: staged is HEAD against the index, changed is
/// the index against the working tree, and an untracked file has no original at all.
///
/// **A conflicted row (status `U`, always in Changes — R13) is HEAD against the working
/// tree.** Mid-merge the index holds the file's stages, not one version, so `index` has
/// nothing to show; HEAD is what this branch had, the working tree is where the markers
/// are. Index stages wait for 3a-ii.
func gitDiffRevs(_ group: GitGroup, status: String?) -> (original: String?, modified: String) {
    if group == .changed, status == "U" { return ("HEAD", "worktree") }
    switch group {
    case .staged: return ("HEAD", "index")
    case .changed: return ("index", "worktree")
    case .untracked: return (nil, "worktree")
    }
}

private func gitPane(_ params: JSONValue, action: String, layout: LayoutStore?) async throws -> String {
    guard let pane = optionalString(params, "pane"), !pane.isEmpty else {
        throw StandardActionError.missingParam(action: action, param: "pane")
    }
    try await requireOpenPane(pane, action: action, layout: layout)
    return pane
}

private func gitSchema(_ properties: [String: JSONValue], required: [String]) -> JSONValue {
    var props = properties
    props["pane"] = .object(["type": .string("string")])
    return .object([
        "type": .string("object"),
        "properties": .object(props),
        "required": .array((["pane"] + required).map { .string($0) }),
    ])
}

/// Registers the git pane's actions.
///
/// **One path for the operator and the agent.** The pane's clicks and keys dispatch these
/// same actions, so what the operator did and what the agent did are journalled alike, and
/// each returns the pane's snapshot (`PaneStore.readPane`) — what the pane now shows.
///
/// `git_refresh` re-reads `git_status` for one root or all of them, each root in parallel
/// and each on its own terms: a root that fails carries its error whole and never hides a
/// sibling (Interaction Rule 8). The selection then follows Rule 6 (`gitReselect`), and its
/// diff is fetched again. `git_select` folds the list away and fetches the picked file's
/// diff; `git_step` moves the selection through `gitRows`' order and then selects.
/// `git_fold` and `git_unfold` only fold — unfolding keeps the selection, so folding again
/// is back where the operator was.
///
/// **A select cancels the diff in flight** for its pane (Rules 4 and 5): the fetch it
/// replaced never lands, even when its reply arrives last. A diff is written only by the
/// flight that is still current, for the selection it was started for.
///
/// `.read` for a refresh, `.control` for the rest: none of them reaches past the pane but
/// to read git, so none is `.mutate` and none is gated in production.
public func registerGitActions(
    into registry: ActionRegistry,
    panes: PaneStore,
    layout: LayoutStore?,
    status: GitStatus
) async {
    let git = status.git
    let flights = GitFlights()
    await panes.onDrop { pane in flights.drop(pane) }

    @Sendable func snapshot(_ pane: String) async -> JSONValue {
        await panes.readPane(paneId: pane, kind: "git")
    }

    /// Starts `selection`'s diff as the pane's one flight. Called only from inside the
    /// `updateGit` turn that wrote `selection` — see `GitFlights`.
    @Sendable func diffFlight(
        _ pane: String, _ selection: GitSelection, status: String?, _ git: any ToolCaller
    ) -> Task<Void, Never> {
        let revs = gitDiffRevs(selection.group, status: status)
        let language = gitLanguage(for: selection.path)
        @Sendable func side(_ rev: String?) async throws -> GitToolOutcome {
            guard let rev else { return .ok([:]) }
            return try await gitTool(git, "git_show", [
                "root": .string(selection.root), "path": .string(selection.path), "rev": .string(rev),
            ])
        }
        return flights.startDiff(pane) {
            let outcome: (GitToolOutcome, GitToolOutcome)
            do {
                async let original = side(revs.original)
                async let modified = side(revs.modified)
                outcome = try await (original, modified)
            } catch {
                return   // cancelled: the selection that replaced this one owns the diff now
            }
            await panes.updateGit(paneId: pane) { s in
                guard !Task.isCancelled, s.selection == selection else { return }
                switch outcome {
                case (.failed(let text), _), (_, .failed(let text)):
                    s.diff = GitDiffState(original: "", modified: "", language: language, binary: false,
                                          bytes: 0, lines: 0, truncated: false, error: text, loading: false)
                case (.ok(let o), .ok(let m)):
                    let original = gitString(o, "text"), modified = gitString(m, "text")
                    func lines(_ t: String) -> Int {
                        t.isEmpty ? 0 : t.split(separator: "\n", omittingEmptySubsequences: false).count
                    }
                    s.diff = GitDiffState(
                        original: original, modified: modified, language: language,
                        binary: o["binary"] == .bool(true) || m["binary"] == .bool(true),
                        // The larger side: a deletion's size is its original's.
                        bytes: max(o["bytes"]?.intValue ?? 0, m["bytes"]?.intValue ?? 0),
                        lines: max(lines(original), lines(modified)),
                        truncated: o["truncated"] == .bool(true) || m["truncated"] == .bool(true),
                        error: nil, loading: false)
                }
            }
        }
    }

    /// Points the pane at `selection`, folds the list away, and fetches the diff — the
    /// selection and its flight in one turn.
    @Sendable func select(_ pane: String, _ selection: GitSelection, _ git: any ToolCaller) async {
        await select(pane, git) { _ in selection }
    }

    /// Points the pane at what `choose` picks from the snapshot as it is in this same turn —
    /// nothing when it picks nil. A step reads the selection it moves from here, so two steps
    /// at once move two rows, not both from the same one (final review, item 7).
    @Sendable func select(
        _ pane: String, _ git: any ToolCaller, _ choose: @escaping @Sendable (GitSnapshot) -> GitSelection?
    ) async {
        let flight: Task<Void, Never>? = await panes.updateGit(paneId: pane, create: true) { s in
            guard let selection = choose(s) else { return nil }
            let language = gitLanguage(for: selection.path)
            s.selection = selection
            s.folded = true
            s.inView = nil
            s.diff = GitDiffState(original: "", modified: "", language: language, binary: false,
                                  bytes: 0, lines: 0, truncated: false, error: nil, loading: true)
            return diffFlight(pane, selection, status: gitFileRow(selection, in: s.roots)?.status, git)
        }
        await flight?.value
    }

    /// Takes the window's status as it now is into the pane. **Only a write made before any await
    /// may create the pane's entry** (final review item 8): `create` is true for the write before a
    /// read, and false for the one after it, so a pane closed while the read was parked is not
    /// brought back. A status still loading only lists its roots; once it has landed the selection
    /// moves per Rule 6 and its diff is read again.
    @Sendable func adopt(_ pane: String, _ git: any ToolCaller, create: Bool) async {
        let fresh = await status.roots
        let landed = !fresh.contains { $0.loading }
        let reload: Task<Void, Never>? = await panes.updateGit(paneId: pane, create: create) { s in
            let before = s.roots
            s.roots = fresh
            guard landed, fresh != before, let selection = s.selection else { return nil }
            switch gitReselect(selection, before: before, after: s.roots) {
            case .keep(let next), .moved(let next):
                s.selection = next
                s.diff?.loading = true
                return diffFlight(pane, next, status: gitFileRow(next, in: s.roots)?.status, git)
            case .unfold(let root):
                s.selection = nil
                s.folded = false
                s.diff = nil
                s.inView = root
                return nil
            }
        }
        await reload?.value
    }

    @Sendable func requireGit(_ action: String) throws -> any ToolCaller {
        guard let git else { throw StandardActionError.missingClient(action: action, role: "git") }
        return git
    }

    await registry.register(Action(
        name: "git_refresh",
        description: "Re-read git status for the git pane: one root (root, an absolute path that "
            + "is one of the active project's roots) or, naming none, every root. With read false, "
            + "takes the window's status as it already is (the window read it on a file event). "
            + "Each root is read on its own; one that fails shows its error and hides nothing else. The "
            + "selection stays on its file, follows it to another group, or moves to the row "
            + "that took its place; its diff is read again. Returns the pane's snapshot.",
        kind: .read,
        audience: .agentReachable,
        schema: gitSchema(["root": .object(["type": .string("string")]),
                           "read": .object(["type": .string("boolean")])], required: []),
        handler: { params in
            let pane = try await gitPane(params, action: "git_refresh", layout: layout)
            let git = try requireGit("git_refresh")
            let only = optionalString(params, "root")
            if let only {
                let all = await status.projectRoots()
                guard all.contains(only) else {
                    throw GitActionError.notAProjectRoot(action: "git_refresh", root: only, roots: all)
                }
            }
            if case .object(let o) = params, o["read"] == .bool(false) {
                // The window read it (or is reading it): take what it holds, loading or landed.
                await adopt(pane, git, create: true)
            } else {
                let ticket = await status.begin(only: only)
                await adopt(pane, git, create: true)     // every root listed, loading, before the read
                await status.finish(ticket)
                await adopt(pane, git, create: false)    // after a read that may have been slow
            }
            return await snapshot(pane)
        }))

    await registry.register(Action(
        name: "git_select",
        description: "Open one changed file's diff in the git pane: root (absolute), path "
            + "(relative to root) and group (staged, changed or untracked — a partly staged "
            + "file is in two). Folds the list away. Staged compares HEAD with the index, "
            + "changed the index with the working tree (a conflicted file, status U, HEAD with "
            + "the working tree), untracked nothing with the working "
            + "tree. A select cancels the diff still loading. Returns the pane's snapshot; "
            + "the diff's texts are not in it — read them with git_show.",
        kind: .control,
        audience: .agentReachable,
        schema: gitSchema([
            "root": .object(["type": .string("string")]),
            "path": .object(["type": .string("string")]),
            "group": .object(["type": .string("string"),
                              "enum": .array(GitGroup.allCases.map { .string($0.rawValue) })]),
        ], required: ["root", "path", "group"]),
        handler: { params in
            let pane = try await gitPane(params, action: "git_select", layout: layout)
            let git = try requireGit("git_select")
            for key in ["root", "path", "group"] where optionalString(params, key) == nil {
                throw StandardActionError.missingParam(action: "git_select", param: key)
            }
            let root = optionalString(params, "root")!, path = optionalString(params, "path")!
            let named = optionalString(params, "group")!
            guard let group = GitGroup(rawValue: named) else {
                throw GitActionError.unknownGroup(action: "git_select", group: named)
            }
            let all = await status.projectRoots()
            guard all.contains(root) else {
                throw GitActionError.notAProjectRoot(action: "git_select", root: root, roots: all)
            }
            await select(pane, GitSelection(root: root, path: path, group: group), git)
            return await snapshot(pane)
        }))

    await registry.register(Action(
        name: "git_step",
        description: "Move the git pane's selection delta rows (1 next, -1 previous) through "
            + "every root's files in order — roots in project order, then staged, changed, "
            + "untracked — stopping at either end, and open that file's diff as git_select "
            + "does. With nothing selected, the first file. Returns the pane's snapshot.",
        kind: .control,
        audience: .agentReachable,
        schema: gitSchema(["delta": .object(["type": .string("integer")])], required: ["delta"]),
        handler: { params in
            let pane = try await gitPane(params, action: "git_step", layout: layout)
            let git = try requireGit("git_step")
            guard case .object(let object) = params, let delta = object["delta"]?.intValue else {
                throw StandardActionError.missingParam(action: "git_step", param: "delta")
            }
            await select(pane, git) { s in gitStep(s.roots, from: s.selection, by: delta) }
            return await snapshot(pane)
        }))

    for (name, folded) in [("git_fold", true), ("git_unfold", false)] {
        await registry.register(Action(
            name: name,
            description: folded
                ? "Fold the git pane's file list away, leaving the open diff. Returns the pane's snapshot."
                : "Unfold the git pane's file list. The selection and its diff stay, so folding "
                    + "again returns to them. Returns the pane's snapshot.",
            kind: .control,
            audience: .agentReachable,
            schema: gitSchema([:], required: []),
            handler: { params in
                let pane = try await gitPane(params, action: name, layout: layout)
                await panes.updateGit(paneId: pane) { $0.folded = folded }
                return await snapshot(pane)
            }))
    }
}
