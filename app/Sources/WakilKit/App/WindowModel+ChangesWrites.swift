import Foundation

/// The Changes view's git writes (3a-ii): per-root drafts, ↑/↓ history, errors, writes in flight and the
/// commit hint. Every write is an `editor_changes_*` dispatch from the UI, so the agent and the operator
/// share one path and one per-root lock (`GitWriteFlights`, in the actions).
extension WindowModel {
    static let changesHistoryLimit = 20

    // MARK: The message box

    public func changesMessageEdited(root: String, text: String) {
        // 3a-ii-b (R4): typing wins over a draft in flight; its reply is dropped when it lands.
        changesDraftTasks[root]?.cancel()
        // The box showing the history entry the cursor stands on is the step's own echo, not typing.
        if let c = changesHistoryCursor[root], let h = changesHistory[root], c < h.count, h[c] == text {
            changesMessages[root] = text
            return
        }
        changesHistoryCursor[root] = nil
        changesMessages[root] = text.isEmpty ? nil : text
    }

    /// ↑ (`-1`, older) and ↓ (`1`, newer). Moves only while the box is empty or still showing the
    /// history entry it stands on: a typed message is not history.
    public func changesHistoryStep(root: String, by delta: Int) {
        let history = changesHistory[root] ?? []
        let draft = changesMessages[root] ?? ""
        let cursor = changesHistoryCursor[root]
        if let c = cursor { guard c < history.count, history[c] == draft else { return } }
        else { guard draft.isEmpty else { return } }
        let next = (cursor ?? -1) - delta
        if next < 0 {
            guard cursor != nil else { return }
            changesHistoryCursor[root] = nil
            changesMessages[root] = nil
        } else if next < history.count {
            changesHistoryCursor[root] = next
            changesMessages[root] = history[next]
        }
    }

    // MARK: Writes

    public func changesCommit(root: String) async {
        let draft = changesMessages[root]
        let message = (draft ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        guard await changesWrite(root, "editor_changes_commit",
                                 ["root": .string(root), "message": .string(message)]) != nil else { return }
        changesRemember(root, message, committedDraft: draft)
    }

    public func changesAmend(root: String) async {
        let draft = changesMessages[root]
        let message = (draft ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var params: [String: JSONValue] = ["root": .string(root)]
        if !message.isEmpty { params["message"] = .string(message) }
        guard await changesWrite(root, "editor_changes_amend", params) != nil else { return }
        if !message.isEmpty { changesRemember(root, message, committedDraft: draft) }
    }

    /// The undone commit's message fills the box only when it is empty: a draft is the operator's.
    public func changesUndoCommit(root: String) async {
        guard let result = await changesWrite(root, "editor_changes_undo_commit", ["root": .string(root)]) else { return }
        guard (changesMessages[root] ?? "").isEmpty else { return }
        let message = Self.changesField(result, "message") ?? ""
        changesHistoryCursor[root] = nil
        changesMessages[root] = message.isEmpty ? nil : message
    }

    public func changesStage(root: String, paths: [String]?, group: GitGroup?) async {
        _ = await changesWrite(root, "editor_changes_stage", Self.changesTargets(root, paths, group))
    }

    public func changesUnstage(root: String, paths: [String]?, group: GitGroup?) async {
        _ = await changesWrite(root, "editor_changes_unstage", Self.changesTargets(root, paths, group))
    }

    public func changesDiscard(root: String, paths: [String]?, group: GitGroup?) async {
        _ = await changesWrite(root, "editor_changes_discard", Self.changesTargets(root, paths, group))
    }

    /// Stages the change the focused editor tab's peek shows; the action refuses a tab with none. The
    /// pane and the peek's hunk are named, so the same file open in another pane is not the one staged.
    public func changesStageHunk() async {
        guard let pane = focusedEditorPane(), let s = editor(pane), let i = s.active, i < s.tabs.count,
              let path = s.tabs[i].path else { return }
        let root = gitRoots.map(\.root).filter { path.hasPrefix($0 + "/") }.max { $0.count < $1.count } ?? ""
        var params: [String: JSONValue] = ["path": .string(path), "pane": .string(pane)]
        if let peek = s.tabs[i].peek { params["hunk"] = .integer(Int64(peek)) }
        _ = await changesWrite(root, "editor_changes_stage_hunk", params)
    }

    /// Stage (or unstage) Selected Ranges (3a-ii-b): `pane`'s active Changes (or Staged) diff tab — the
    /// pane the press was made in, focused or not (final review M1) — with `ranges`, every selection
    /// the page holds, read at the press (ruling R1).
    public func changesStageRanges(pane: String, _ ranges: [EditorLineSpan]) async {
        await changesRanges("editor_changes_stage_ranges", pane, ranges)
    }
    public func changesUnstageRanges(pane: String, _ ranges: [EditorLineSpan]) async {
        await changesRanges("editor_changes_unstage_ranges", pane, ranges)
    }

    private func changesRanges(_ name: String, _ pane: String, _ ranges: [EditorLineSpan]) async {
        guard let s = editor(pane), let i = s.active, i < s.tabs.count,
              case .diff(let root, let path, _, nil) = s.tabs[i].subject else { return }
        let spans: JSONValue = .array(ranges.map { .object(["start": .integer(Int64($0.start)), "end": .integer(Int64($0.end))]) })
        _ = await changesWrite(root, name, ["path": .string(root + "/" + path), "pane": .string(pane), "ranges": spans])
    }

    /// 3a-iii-a: the remote operations, through the same per-root write path as a commit.
    public func changesRemote(root: String, _ button: ChangesRemoteButton) async {
        guard let action = button.action else { return }
        _ = await changesWrite(root, action, ["root": .string(root)])
    }

    public func changesFetch(root: String) async {
        _ = await changesWrite(root, "editor_changes_fetch", ["root": .string(root)])
    }

    /// Ends that root's running dispatch. The write itself may already be past the point of stopping;
    /// whatever the action reports is shown.
    public func changesCancel(root: String) { changesTasks[root]?.cancel() }

    // MARK: Identity and hint

    /// Reads who a commit in `root` would be authored as. Cleared when the read fails: the old hint
    /// may now be wrong.
    public func refreshChangesIdentity(root: String) async {
        guard let git = gitStatus?.git else { return }
        let generation = changesGeneration
        let result = try? await callCheckedTool(
            git, tool: "git_identity", arguments: .object(["root": .string(root)]),
            action: "git_identity", timeout: MCPClient.readReplyTimeout)
        guard generation == changesGeneration else { return }
        // A failed read shows no hint: the old one may now be wrong (a save just changed who commits).
        guard let result, let email = Self.changesField(result, "email") else {
            changesIdentity[root] = nil
            return
        }
        changesIdentity[root] = (email: email, fromConfig: Self.changesField(result, "from") != "organisation")
    }

    /// The message box's placeholder: who a commit is authored as and the key that commits, or only
    /// the key while nobody is known.
    public func changesPlaceholder(root: String) -> String {
        guard let who = changesIdentity[root], !who.email.isEmpty else { return "Message (⌘⏎ to commit)" }
        return who.fromConfig ? "Message · as \(who.email) (from git config) (⌘⏎)" : "Message · as \(who.email) (⌘⏎)"
    }

    // MARK: Plumbing

    /// Records `message` in the root's history and empties the box — unless the operator typed
    /// something else while the write ran (`committedDraft` is what the box held when it started).
    private func changesRemember(_ root: String, _ message: String, committedDraft: String?) {
        var h = changesHistory[root] ?? []
        h.insert(message, at: 0)
        changesHistory[root] = Array(h.prefix(Self.changesHistoryLimit))
        guard changesMessages[root] == committedDraft else { return }
        changesHistoryCursor[root] = nil
        changesMessages[root] = nil
    }

    private static func changesTargets(_ root: String, _ paths: [String]?, _ group: GitGroup?) -> [String: JSONValue] {
        var p: [String: JSONValue] = ["root": .string(root)]
        if let paths { p["paths"] = .array(paths.map { .string($0) }) }
        if let group { p["group"] = .string(group.rawValue) }
        return p
    }

    private static func changesField(_ result: JSONValue, _ key: String) -> String? {
        if case .object(let o) = result, case .object(let s)? = o["structuredContent"] { return changesField(.object(s), key) }
        return optionalString(result, key)
    }

    /// One write: the root is in flight for its length, an error is kept whole (the action's own prefix
    /// included), and a result that lands after an org switch is dropped. Nil on failure or a dropped result.
    func changesWrite(_ root: String, _ name: String, _ params: [String: JSONValue]) async -> JSONValue? {
        // One write per root: the controls are disabled while it runs, and a second one must not
        // touch the first's spinner, task or error.
        guard !changesInFlight.contains(root) else { return nil }
        let generation = changesGeneration
        changesInFlight.insert(root)
        await preemptBackgroundFetch(root)
        let caller = DispatchCaller(place: place, session: nil)
        let registry = self.registry
        let task = Task { @MainActor in
            try await registry.dispatch(name: name, params: .object(params), origin: .ui, caller: caller, confirmation: nil)
        }
        changesTasks[root] = task
        let outcome = await task.result
        guard generation == changesGeneration else { return nil }
        if changesTasks[root] == task {
            changesTasks[root] = nil
            changesInFlight.remove(root)
        }
        switch outcome {
        case .success(let result):
            changesErrors[root] = nil
            return result
        case .failure(let error):
            // Cancel is the operator's own act, not a failure to report.
            if error is CancellationError || task.isCancelled {
                changesErrors[root] = nil
            } else {
                changesErrors[root] = statusDescribingFailure(name, error)
            }
            return nil
        }
    }
}
