import Foundation

/// A draft that landed in `root`'s box and the text it replaced ("" for an empty box).
public struct ChangesDraftReplacement: Sendable, Equatable {
    public var root: String
    public var replaced: String
    public var serial: Int
}

/// The commit box's ✨ (3a-ii-b, Decision 42): `CommitDraft` over the window's quick tasks, landing in
/// the root's box. The box is the operator's (Rule 2): a draft replaces it only on their press, the
/// replaced text is returned so the view can undo it (R3), and typing while one is in flight wins (R4).
extension WindowModel {
    /// Drafts into `root`'s box. Returns the text the draft replaced ("" for an empty box), or nil when
    /// nothing landed — an error then is on `changesErrors[root]`, whole.
    public func changesDraft(root: String) async -> String? {
        let before = changesMessages[root] ?? ""
        guard (try? await changesDraftMessage(root: root)) != nil else { return nil }
        return before
    }

    /// Ends `root`'s draft in flight (✕). Nothing lands and nothing is shown as an error.
    public func changesCancelDraft(root: String) { changesDraftTasks[root]?.cancel() }

    /// The draft, put in the box and answered: what `editor_changes_draft_message` returns. Throws the
    /// refusal or failure it also shows under the box; a draft overtaken by typing, a cancel or another
    /// generation (an org switch, a quick-tasks rebuild) throws `CancellationError` and touches nothing.
    public func changesDraftMessage(root: String) async throws -> String {
        let action = "editor_changes_draft_message"
        func refuse(_ text: String) -> Error {
            changesErrors[root] = text
            return EditorFilesError(description: text)
        }
        guard changesDraftTasks[root] == nil else { throw refuse("a draft is already running in \(changesRootName(root))") }
        guard commitDraftsEnabled else {
            throw refuse("commit drafts are off for \(organization) — Settings → Providers → Quick tasks")
        }
        guard let tasks = quickTasks else { throw refuse("\(QuickModelError.noProvider(.respond))") }
        guard let git = gitStatus?.git else { throw refuse(StandardActionError.missingClient(action: action, role: "git").description) }
        let files = await gitStatus?.roots.first { $0.root == root }?.files ?? []
        guard !files.isEmpty else { throw refuse("nothing to draft from: \(changesRootName(root)) has no changes") }
        let staged = files.contains { $0.group == .staged }
        let untracked = staged ? [] : files.filter { $0.group == .untracked }.map(\.path)
        let committed = files.filter { $0.group == (staged ? .staged : .changed) }.map(\.path)
        let examples = changesHistory[root] ?? []
        let rules = commitInstructions
        let generation = quickTasksGeneration, changes = changesGeneration
        changesErrors[root] = nil
        changesDrafting.insert(root)
        let task = Task { () async throws -> String in
            let reply = try await callCheckedTool(
                git, tool: "git_diff", arguments: .object(["root": .string(root), "side": .string(staged ? "staged" : "changed")]),
                action: action, timeout: MCPClient.readReplyTimeout)
            var diff = "", truncated = false
            let fields: JSONValue = if case .object(let o) = reply, let s = o["structuredContent"] { s } else { reply }
            if case .object(let o) = fields {
                if case .string(let t)? = o["text"] { diff = t }
                truncated = o["truncated"] == .bool(true)
            }
            try Task.checkCancellation()
            let request = CommitDraft.request(diff: diff, truncated: truncated, files: committed, untracked: untracked,
                                              examples: examples, commitInstructions: rules)
            return try CommitDraft.parse(try await tasks.respond(request))
        }
        changesDraftTasks[root] = task
        defer {
            // An org switch may have emptied these and a new draft taken the root since.
            if changesDraftTasks[root] == task {
                changesDraftTasks[root] = nil
                changesDrafting.remove(root)
            }
        }
        let message: String
        do {
            message = try await task.value
        } catch {
            if task.isCancelled || error is CancellationError || generation != quickTasksGeneration
                || changes != changesGeneration { throw CancellationError() }
            changesErrors[root] = statusDescribingFailure(action, error)
            throw error
        }
        guard !task.isCancelled, generation == quickTasksGeneration, changes == changesGeneration else {
            throw CancellationError()
        }
        let replaced = changesMessages[root] ?? ""
        changesHistoryCursor[root] = nil
        changesMessages[root] = message
        changesLastDraft = ChangesDraftReplacement(root: root, replaced: replaced, serial: (changesLastDraft?.serial ?? 0) + 1)
        return message
    }

    private func changesRootName(_ root: String) -> String {
        if let n = gitRoots.first(where: { $0.root == root })?.name, !n.isEmpty { return n }
        return (root as NSString).lastPathComponent
    }
}
