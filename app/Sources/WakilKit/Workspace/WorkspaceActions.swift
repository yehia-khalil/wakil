import Foundation

/// Workspaces, piece 1: the actions over the record. `workspace_list` is the agent's and the
/// operator's read; archive, restore, Bring to Main and Move to workspace… are the operator's (the
/// card's ⋯ menu, piece 3): an agent does not move work out from under another, nor itself.
public func registerWorkspaceActions(
    into registry: ActionRegistry, router: WorkspaceRouter,
    organization: @escaping @Sendable () async -> String?
) async {
    @Sendable func string(_ params: JSONValue, _ key: String) -> String? {
        if case .object(let o) = params, case .string(let s)? = o[key] { return s }
        return nil
    }
    @Sendable func required(_ params: JSONValue, _ key: String, _ action: String) throws -> String {
        guard let v = string(params, key), !v.isEmpty else { throw StandardActionError.missingParam(action: action, param: key) }
        return v
    }
    /// The organisation the call is for: an agent's own (Invariant 4), else the window's.
    @Sendable func org(_ action: String) async throws -> String {
        var o = pinnedPlace(of: ActionRegistry.dispatchCaller)?.organization
        if o == nil { o = await organization() }
        guard let o, !o.isEmpty else { throw WorkspaceWriteError(description: "\(action): no organisation is open") }
        if let failure = await router.load(org: o) { throw WorkspaceWriteError(description: "\(action): \(failure)") }
        return o
    }
    @Sendable func schema(_ props: [String: JSONValue], required: [String] = []) -> JSONValue {
        .object(["type": .string("object"), "properties": .object(props), "required": .array(required.map { .string($0) })])
    }
    let text: JSONValue = .object(["type": .string("string")])

    await registry.register(Action(
        name: "workspace_list",
        description: "List the organisation's workspaces — of project when given; an agent's own project's by default — "
            + "each with its name, environment, tickets, parent (a branch-off's), branch, archived, and its checkouts: "
            + "repo (Main's folder), path (the copy, null when none is made), branch, base, holder (the live "
            + "conversation holding it), in Main; and the conversations in it (lineage roots) with the live ones' states. "
            + "Main is not listed: it is the project's own folders.",
        kind: .read, audience: .agentReachable,
        schema: schema(["project": text]),
        handler: { params in
            _ = try await org("workspace_list")
            let project = string(params, "project") ?? pinnedPlace(of: ActionRegistry.dispatchCaller)?.project
            let rows = await router.listing(project: project?.isEmpty == true ? nil : project)
            return .object(["workspaces": .array(rows.map(\.json))])
        }))

    await registry.register(Action(
        name: "workspace_archive",
        description: "Archive a workspace (decision 11): refused while a conversation in it is working; with one waiting "
            + "on the operator, refused unless confirm. Each copy with uncommitted work is snapshotted "
            + "(refs/wakil/snapshots/<workspace>/<repo>) and every copy removed; branches stay. workspace_restore brings it back.",
        kind: .mutate, audience: .operatorOnly,
        schema: schema(["workspace": text, "confirm": .object(["type": .string("boolean")])], required: ["workspace"]),
        handler: { params in
            _ = try await org("workspace_archive")
            let id = try required(params, "workspace", "workspace_archive")
            let confirmed: Bool = if case .object(let o) = params, o["confirm"] == .bool(true) { true } else { false }
            let w = try await router.archive(id, confirmed: confirmed)
            return .object(["workspace": .string(w.id), "archived": .bool(w.archived)])
        },
        price: (production: .allow, otherwise: .allow)))

    await registry.register(Action(
        name: "workspace_restore",
        description: "Restore an archived workspace: listed again; each copy is re-made at its next write with its snapshot put back.",
        kind: .control, audience: .operatorOnly,
        schema: schema(["workspace": text], required: ["workspace"]),
        handler: { params in
            _ = try await org("workspace_restore")
            let w = try await router.restore(try required(params, "workspace", "workspace_restore"))
            return .object(["workspace": .string(w.id), "archived": .bool(w.archived)])
        }))

    await registry.register(Action(
        name: "workspace_bring_home",
        description: "Bring to Main: switch Main's folder of repo (its path or folder name) to the workspace's branch, the "
            + "copy's uncommitted work coming along; the copy is snapshotted and removed first. Refused while a working "
            + "conversation holds that repo. An agent's next change to it takes the branch back into a new copy.",
        kind: .mutate, audience: .operatorOnly,
        schema: schema(["workspace": text, "repo": text], required: ["workspace", "repo"]),
        handler: { params in
            _ = try await org("workspace_bring_home")
            let w = try await router.bringHome(try required(params, "workspace", "workspace_bring_home"),
                                               repo: try required(params, "repo", "workspace_bring_home"))
            return .object(["workspace": .string(w.id)])
        },
        price: (production: .allow, otherwise: .allow)))

    await registry.register(Action(
        name: "workspace_set_environment",
        description: "Change the environment a workspace belongs to (decision 28): its record and the conversations started "
            + "in it from now; running conversations keep the environment they started in.",
        kind: .control, audience: .operatorOnly,
        schema: schema(["workspace": text, "environment": text], required: ["workspace", "environment"]),
        handler: { params in
            _ = try await org("workspace_set_environment")
            let w = try await router.setEnvironment(try required(params, "workspace", "workspace_set_environment"),
                                                    to: try required(params, "environment", "workspace_set_environment"))
            return .object(["workspace": .string(w.id), "environment": .string(w.environment)])
        }))

    await registry.register(Action(
        name: "conversation_move",
        description: "Move to workspace… (decision 6): put a live conversation in another workspace of its project, or in "
            + "Main (workspace \"main\"), while it holds no copy; one holding a copy is not moved, so no change is stranded.",
        kind: .control, audience: .operatorOnly,
        schema: schema(["conversation": text, "workspace": text], required: ["conversation", "workspace"]),
        handler: { params in
            _ = try await org("conversation_move")
            let conversation = try required(params, "conversation", "conversation_move")
            let target = try required(params, "workspace", "conversation_move")
            let w = try await router.move(conversation, to: target == "main" ? nil : target)
            return .object(["conversation": .string(conversation), "workspace": w.map { .string($0.id) } ?? .string("main")])
        }))
}
