import Foundation

/// The window's workspaces (piece 1): the record as last read or written, who holds each checkout,
/// and which workspace each live conversation is in. Holds are live state: a relaunch makes every
/// conversation past (call 14), so nothing is held after one; `lastHolder` in the record remembers
/// the lineage root.
///
/// The record is Go's (`workspaces.json`); `load` and `save` reach it through wakil-git. An
/// unreadable record is kept as `loadFailure`, whole, and nothing is saved over it (Rule 8).
public actor WorkspaceStore {
    private var file = WorkspacesFile()
    private var holds: [WorkspaceHold: String] = [:]
    /// Live conversation id → workspace id. A conversation not here is in Main, unless its lineage
    /// root is listed by a workspace (a resumed conversation goes back to its workspace).
    private var members: [String: String] = [:]
    private var loader: (@Sendable () async throws -> WorkspacesFile)?
    private var saver: (@Sendable (WorkspacesFile) async throws -> Void)?
    /// Why the record could not be read, whole; nil when it was.
    public private(set) var loadFailure: String?
    /// Bumped by every change, so a view can tell its copy is stale.
    public private(set) var revision = 0
    /// The organisation the record in memory is of; nil before the first read.
    public private(set) var organization: String?

    public init() {}

    /// Reads and writes the record through `git` (wakil-git's `workspaces_read` / `workspaces_write`).
    public func use(git: (any ToolCaller)?) {
        guard let git else {
            loader = nil
            saver = nil
            return
        }
        loader = {
            let r = try await callCheckedTool(git, tool: "workspaces_read", arguments: .object([:]),
                                              action: "workspaces_read", timeout: MCPClient.readReplyTimeout)
            return try decodeWorkspaces(r)
        }
        saver = { f in
            let data = try JSONEncoder().encode(f.workspaces)
            let value = try JSONDecoder().decode(JSONValue.self, from: data)
            _ = try await callCheckedTool(git, tool: "workspaces_write", arguments: .object(["workspaces": value]),
                                          action: "workspaces_write", timeout: MCPClient.mutationReplyTimeout)
        }
    }

    /// For tests: a record in memory, saved by `save`.
    public func use(load: (@Sendable () async throws -> WorkspacesFile)?, save: (@Sendable (WorkspacesFile) async throws -> Void)?) {
        loader = load
        saver = save
    }

    /// Reads the record again. A failure is kept whole in `loadFailure`; the record in memory stays
    /// what it was. A read cancelled under its caller is no failure of the record: the organisation
    /// is left unread, so the next `ensure` reads it again.
    @discardableResult
    public func reload() async -> String? {
        guard let loader else { return nil }
        do {
            file = try await loader()
            loadFailure = nil
        } catch is CancellationError {
            organization = nil
        } catch {
            loadFailure = "workspaces.json: \(error)"
        }
        revision += 1
        return loadFailure
    }

    /// Reads `org`'s record when the one in memory is another's (or none was read): the first write
    /// in an organisation after a switch, or an agent of another organisation (Invariant 4).
    public func ensure(org: String) async {
        guard organization != org else { return }
        clear()
        organization = org
        await reload()
    }

    /// Writes the record. Refused while it could not be read, so an unreadable file is never
    /// written over.
    public func save() async throws {
        if let loadFailure { throw WorkspaceWriteError(description: loadFailure + " — nothing was saved over it") }
        guard let saver else { return }
        try await saver(file)
    }

    /// Forgets everything (an organisation switch); `reload` reads the incoming one's.
    public func clear() {
        organization = nil
        file = WorkspacesFile()
        holds = [:]
        members = [:]
        loadFailure = nil
        revision += 1
    }

    public func all() -> [Workspace] { file.workspaces }
    public func workspace(_ id: String) -> Workspace? { file.workspaces.first { $0.id == id } }
    public func holders() -> [WorkspaceHold: String] { holds }

    /// The workspace `conversation` (with lineage root `root`) is in; nil for Main.
    public func workspace(ofConversation conversation: String, root: String? = nil) -> Workspace? {
        if let id = members[conversation] { return workspace(id) }
        guard let root else { return nil }
        return file.workspaces.last { !$0.archived && $0.conversations.contains(root) }
    }

    /// The workspace id of a conversation (pieces 4 and 5); nil for Main.
    public func workspaceId(ofConversation conversation: String, root: String? = nil) -> String? {
        workspace(ofConversation: conversation, root: root)?.id
    }

    /// Whether `conversation` is placed in a workspace this session (not only found by its root).
    public func isMember(_ conversation: String) -> Bool { members[conversation] != nil }

        /// Adds a workspace to the record (in memory; `save` writes it).
    public func add(_ w: Workspace) {
        file.workspaces.append(w)
        revision += 1
    }

    /// Takes a workspace out of the record (in memory) with its members and holds: one whose copy
    /// was taken back because the record could not be saved.
    public func remove(_ id: String) {
        file.workspaces.removeAll { $0.id == id }
        members = members.filter { $0.value != id }
        holds = holds.filter { $0.key.workspace != id }
        revision += 1
    }

    /// Changes one workspace in place; false when there is none with that id.
    @discardableResult
    public func update(_ id: String, _ change: (inout Workspace) -> Void) -> Bool {
        guard let i = file.workspaces.firstIndex(where: { $0.id == id }) else { return false }
        change(&file.workspaces[i])
        revision += 1
        return true
    }

    /// Puts `conversation` in workspace `id` (nil: Main), recording its lineage root there.
    public func move(_ conversation: String, root: String?, to id: String?) {
        if let old = members[conversation] {
            for (hold, holder) in holds where holder == conversation && hold.workspace == old { holds[hold] = nil }
        }
        members[conversation] = id
        if let id, let root, !root.isEmpty {
            update(id) { w in
                if !w.conversations.contains(root) { w.conversations.append(root) }
            }
        }
        revision += 1
    }

    /// `conversation` holds `hold` from now; its lineage root is recorded as the last holder.
    public func hold(_ hold: WorkspaceHold, by conversation: String, root: String?) {
        holds[hold] = conversation
        if let root, !root.isEmpty {
            update(hold.workspace) { w in
                if let i = w.checkouts.firstIndex(where: { $0.repo == hold.repo }) { w.checkouts[i].lastHolder = root }
            }
        }
        revision += 1
    }

    /// Nobody holds `hold` from now (its checkout went to Main).
    public func unhold(_ hold: WorkspaceHold) {
        holds[hold] = nil
        revision += 1
    }

    /// The conversation holding `hold`, if any.
    public func holder(of hold: WorkspaceHold) -> String? { holds[hold] }

    /// A conversation that closed lets go of everything it held.
    public func release(_ conversation: String) {
        for (hold, holder) in holds where holder == conversation { holds[hold] = nil }
        members[conversation] = nil
        revision += 1
    }

    /// Whether `conversation` holds any checkout (decision 6: Move is for one that holds none).
    public func holdsAny(_ conversation: String) -> Bool { holds.values.contains(conversation) }

    /// Every made checkout of `project`'s unarchived workspaces.
    public func checkoutRoots(project: String) -> [String] {
        file.workspaces.filter { !$0.archived && $0.project == project }.flatMap { $0.checkouts.compactMap(\.path) }
    }

    /// The live conversations of `id` (ids).
    public func members(of id: String) -> [String] { members.filter { $0.value == id }.map(\.key).sorted() }
}

/// A refusal or failure of the write rule, its sentence whole.
public struct WorkspaceWriteError: Error, CustomStringConvertible, Equatable {
    public let description: String
    public init(description: String) { self.description = description }
}

/// The record from `workspaces_read`'s reply (its `structuredContent` when nested).
func decodeWorkspaces(_ result: JSONValue) throws -> WorkspacesFile {
    var value = result
    if case .object(let o) = result, let s = o["structuredContent"] { value = s }
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(WorkspacesFile.self, from: data)
}
