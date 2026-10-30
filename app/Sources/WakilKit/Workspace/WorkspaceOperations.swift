import Foundation

/// One workspace as a listing shows it (piece 3's home screen reads the same): its record, and for
/// each checkout who holds it now, and each live conversation in it with its state.
public struct WorkspaceListing: Sendable, Equatable {
    public let workspace: Workspace
    /// Repo → the live conversation holding its checkout.
    public let holders: [String: String]
    /// Live conversation ids in it, with their states.
    public let live: [String: ConversationState]

    public var json: JSONValue {
        let w = workspace
        let checkouts: [JSONValue] = w.checkouts.map { co in
            var o: [String: JSONValue] = [
                "repo": .string(co.repo), "branch": .string(co.branch), "inMain": .bool(co.inMain),
                "path": co.path.map { .string($0) } ?? .null,
                "holder": holders[co.repo].map { .string($0) } ?? .null,
            ]
            if let base = co.base { o["base"] = .string(base) }
            if let p = co.ports { o["ports"] = .object(["first": .integer(Int64(p.first)), "count": .integer(Int64(p.count))]) }
            if let s = co.snapshot { o["snapshot"] = .string(s) }
            return .object(o)
        }
        return .object([
            "id": .string(w.id), "name": .string(w.name), "project": .string(w.project),
            "environment": .string(w.environment), "tickets": .array(w.tickets.map { .string($0) }),
            "parent": w.parent.map { .string($0) } ?? .null, "branch": w.branch.map { .string($0) } ?? .null,
            "archived": .bool(w.archived), "checkouts": .array(checkouts),
            "conversations": .array(w.conversations.map { .string($0) }),
            "live": .array(live.keys.sorted().map { .object(["conversation": .string($0), "state": .string(live[$0]!.rawValue)]) }),
        ])
    }
}

extension WorkspaceRouter {
    /// Every workspace of `project` (all projects when nil) of the organisation in memory, with
    /// holders and live conversations: `workspace_list`, `session_list`'s map, the home screen.
    public func listing(project: String? = nil) async -> [WorkspaceListing] {
        let states = await hooks?.states() ?? [:]
        let holds = await store.holders()
        var out: [WorkspaceListing] = []
        for w in await store.all() where project == nil || w.project == project {
            var holders: [String: String] = [:]
            for (h, c) in holds where h.workspace == w.id { holders[h.repo] = c }
            var live: [String: ConversationState] = [:]
            for c in await store.members(of: w.id) { live[c] = states[c] ?? .idle }
            out.append(WorkspaceListing(workspace: w, holders: holders, live: live))
        }
        return out
    }

    /// `rows` with each conversation's workspace named (`session_list`'s live half).
    public func annotate(_ rows: [LiveConversation]) async -> [LiveConversation] {
        var out: [LiveConversation] = []
        for var row in rows {
            let root = await hooks?.conversation(row.id)?.lineageRoot
            if let w = await store.workspace(ofConversation: row.id, root: root) { row.workspace = (w.id, w.name) }
            out.append(row)
        }
        return out
    }

    /// Makes sure the record in memory is `org`'s.
    public func load(org: String) async -> String? {
        await store.ensure(org: org)
        return await store.loadFailure
    }

    private func named(_ id: String) async throws -> Workspace {
        guard let w = await store.workspace(id) else {
            throw WorkspaceWriteError(description: "There is no workspace \(id)")
        }
        return w
    }

    /// The workspace `id` names: its id, else its slug when one workspace of the organisation has it
    /// (a slug is unique within a project, and is the folder name the operator sees).
    private func named(idOrSlug id: String) async throws -> Workspace {
        if let w = await store.workspace(id) { return w }
        let bySlug = await store.all().filter { $0.slug == id }
        guard bySlug.count == 1, let w = bySlug.first else {
            throw WorkspaceWriteError(description: "There is no workspace \(id)")
        }
        return w
    }

    private func title(_ conversation: String) async -> String {
        await hooks?.conversation(conversation)?.title ?? "a conversation"
    }

    /// Archive (decision 11): refused while a conversation in it is working; one waiting on the
    /// operator is asked about first (`confirmed`). Each checkout with uncommitted work is
    /// snapshotted under refs/wakil/snapshots/<workspace>/<repo>, then removed; branches stay.
    public func archive(_ id: String, confirmed: Bool) async throws -> Workspace {
        try await serially {
            let w = try await self.named(id)
            let states = await self.hooks?.states() ?? [:]
            for c in await self.store.members(of: id) {
                if states[c] == .working {
                    throw WorkspaceWriteError(description: "‘\(await self.title(c))’ is working in ‘\(w.name)’; archive it once it stops")
                }
                if states[c] == .waiting, !confirmed {
                    throw WorkspaceWriteError(description: "‘\(await self.title(c))’ is waiting for you in ‘\(w.name)’; archive anyway with confirm true")
                }
            }
            var checkouts = w.checkouts
            for i in checkouts.indices {
                guard let path = checkouts[i].path else { continue }
                let ref = "refs/wakil/snapshots/\(w.slug)/\(checkouts[i].repoName)"
                let r = try await self.call("git_worktree_remove", ["root": .string(checkouts[i].repo), "path": .string(path), "snapshot": .string(ref)])
                checkouts[i].path = nil
                if let sha = self.string(r, "snapshot"), !sha.isEmpty { checkouts[i].snapshot = ref }
                // Saved after each one, so a failure part-way leaves the record true to the disk.
                let done = checkouts
                await self.store.update(id) { $0.checkouts = done }
                try? await self.store.save()
            }
            for c in await self.store.members(of: id) { await self.store.release(c) }
            await self.store.update(id) { $0.archived = true }
            try await self.store.save()
            return try await self.named(id)
        }
    }

    /// Restore: the workspace is listed again; each checkout is re-made at its next write, its
    /// snapshot put back (`CheckoutStart.existingBranch`).
    public func restore(_ id: String) async throws -> Workspace {
        try await serially {
            _ = try await self.named(id)
            await self.store.update(id) { $0.archived = false }
            try await self.store.save()
            return try await self.named(id)
        }
    }

    /// Bring to Main: Main's folder of `repo` switches to the workspace's branch, the checkout's
    /// uncommitted work coming along; the checkout is snapshotted and removed first. Refused while a
    /// working conversation of the workspace holds that repo.
    public func bringHome(_ id: String, repo: String) async throws -> Workspace {
        try await serially {
            let w = try await self.named(id)
            guard let co = w.checkout(of: repo) ?? w.checkouts.first(where: { $0.repoName == repo }) else {
                throw WorkspaceWriteError(description: "‘\(w.name)’ has no copy of \(repo)")
            }
            let states = await self.hooks?.states() ?? [:]
            if let holder = await self.store.holder(of: WorkspaceHold(workspace: id, repo: co.repo)), holderIsWorking(states[holder]) {
                throw WorkspaceWriteError(description: "‘\(await self.title(holder))’ is working in \(co.repoName); bring it to Main once it stops")
            }
            var snapshot = co.snapshot
            if let path = co.path {
                let ref = "refs/wakil/snapshots/\(w.slug)/\(co.repoName)"
                let r = try await self.call("git_worktree_remove", ["root": .string(co.repo), "path": .string(path), "snapshot": .string(ref)])
                if let sha = self.string(r, "snapshot"), !sha.isEmpty { snapshot = ref }
                await self.store.update(id) { ws in
                    if let i = ws.checkouts.firstIndex(where: { $0.repo == co.repo }) {
                        ws.checkouts[i].path = nil
                        ws.checkouts[i].snapshot = snapshot
                    }
                }
                try? await self.store.save()
            }
            _ = try await self.call("git_switch", ["root": .string(co.repo), "branch": .string(co.branch), "carry": .string("bring")])
            if let snapshot {
                _ = try await self.call("git_snapshot_apply", ["root": .string(co.repo), "ref": .string(snapshot)])
            }
            await self.store.update(id) { ws in
                if let i = ws.checkouts.firstIndex(where: { $0.repo == co.repo }) {
                    ws.checkouts[i].inMain = true
                    ws.checkouts[i].snapshot = nil
                }
            }
            for (h, _) in await self.store.holders() where h.workspace == id && h.repo == co.repo {
                await self.store.unhold(h)
            }
            try await self.store.save()
            return try await self.named(id)
        }
    }

    /// Decision 28: a workspace belongs to one environment; the operator changes it from its view's
    /// header. Running conversations keep the environment they started in (Decision 41's pin); the
    /// next conversation started in the workspace, and its data panes, follow the record
    /// (`WorkspaceRouterHooks.environmentChanged`, once the record is saved).
    public func setEnvironment(_ id: String, to environment: String) async throws -> Workspace {
        let (w, old) = try await serially { () -> (Workspace, String) in
            let clean = environment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { throw WorkspaceWriteError(description: "workspace_set_environment: name an environment") }
            let found = try await self.named(idOrSlug: id)
            await self.store.update(found.id) { $0.environment = clean }
            try await self.store.save()
            return (try await self.named(found.id), found.environment)
        }
        if old != w.environment { await hooks?.environmentChanged(w, old) }
        return w
    }

    /// Move to workspace… (decision 6): only while the conversation holds no checkout; `to` nil
    /// is Main. A conversation holding one stays, so no change is stranded; its next write in
    /// another workspace's repo branches off there instead.
    public func move(_ conversation: String, to id: String?) async throws -> Workspace? {
        try await serially {
            guard let facts = await self.hooks?.conversation(conversation) else {
                throw WorkspaceWriteError(description: "There is no live conversation \(conversation)")
            }
            await self.store.ensure(org: facts.organization)
            if await self.store.holdsAny(conversation) {
                throw WorkspaceWriteError(description: "‘\(facts.title)’ holds a copy in its workspace, so it is not moved (decision 6): "
                    + "its changes would be stranded. Start a new conversation in the other workspace instead.")
            }
            var target: Workspace?
            if let id {
                let w = try await self.named(id)
                guard w.project == facts.project else {
                    throw WorkspaceWriteError(description: "‘\(w.name)’ is in project \(w.project), not \(facts.project)")
                }
                guard !w.archived else { throw WorkspaceWriteError(description: "‘\(w.name)’ is archived; restore it first") }
                target = w
            }
            await self.store.move(conversation, root: facts.lineageRoot, to: id)
            try? await self.store.save()
            if let target {
                await self.hooks?.say(conversation, .moved(name: target.name))
                await self.hooks?.moved(conversation, nil, target)
            }
            return target
        }
    }
}
