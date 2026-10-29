import Foundation

extension WorkspaceRouter {
    /// The workspace of the agent whose dispatch this is; nil for the operator, or an agent in Main.
    public func callerWorkspace() async -> Workspace? {
        guard ActionRegistry.dispatchOrigin == .agent,
              let c = ActionRegistry.dispatchCaller?.conversation, !c.isEmpty else { return nil }
        let root = await hooks?.conversation(c)?.lineageRoot
        return await store.workspace(ofConversation: c, root: root)
    }
}

/// Workspaces, piece 2: Run, Stop and Build (decision 12), the agent's as much as the operator's —
/// it runs only the saved recipe, so the actions name a repo and a process, never a command. An
/// agent acts in its own workspace only; the operator names one. Running is the earned write of
/// Decision 106 (Invariant 6): *allow* outside production, *gate* in it (Invariant 8).
public func registerRunActions(
    into registry: ActionRegistry, runner: WorkspaceRunner,
    organization: @escaping @Sendable () async -> String?
) async {
    let router = runner.router
    @Sendable func string(_ params: JSONValue, _ key: String) -> String? {
        if case .object(let o) = params, case .string(let s)? = o[key], !s.isEmpty { return s }
        return nil
    }
    @Sendable func schema(_ props: [String: JSONValue], required: [String] = []) -> JSONValue {
        .object(["type": .string("object"), "properties": .object(props), "required": .array(required.map { .string($0) })])
    }
    let text: JSONValue = .object(["type": .string("string")])
    /// The workspace a call is for: an agent's own (never another's), the operator's named one.
    @Sendable func target(_ params: JSONValue, _ action: String) async throws -> Workspace {
        var o = pinnedPlace(of: ActionRegistry.dispatchCaller)?.organization
        if o == nil { o = await organization() }
        guard let o, !o.isEmpty else { throw RunError("\(action): no organisation is open") }
        if let failure = await router.load(org: o) { throw RunError("\(action): \(failure)") }
        let named = string(params, "workspace")
        if ActionRegistry.dispatchOrigin == .agent {
            guard let mine = await router.callerWorkspace() else {
                throw RunError("\(action): you are in Main, where nothing runs: the app runs in a workspace's copy "
                    + "(decision 12), and your first change makes one. Ask the operator to run it from Main's folder.")
            }
            if let named, named != mine.id, named != mine.slug, named != mine.name {
                throw RunError("\(action): you run only in your own workspace, ‘\(mine.name)’ (decision 12).")
            }
            return mine
        }
        guard let named else { throw StandardActionError.missingParam(action: action, param: "workspace") }
        let all = await router.store.all()
        guard let w = all.first(where: { $0.id == named }) ?? all.first(where: { $0.slug == named }) else {
            throw RunError("There is no workspace \(named)")
        }
        return w
    }
    @Sendable func caller() -> String? {
        ActionRegistry.dispatchOrigin == .agent ? ActionRegistry.dispatchCaller?.conversation : nil
    }

    await registry.register(Action(
        name: "workspace_run",
        description: "Run a repo's saved recipe in your workspace's copy, on its ports (decision 12): its needs and "
            + "services first (once per workspace), copy, clone and setup once per copy, then each process — or only "
            + "process — in a terminal pane titled \"<repo> · <process>\" that you read with read_pane, then the ready "
            + "check. Answers the port (WAKIL_PORT), the processes' panes and whether it is ready. A failing step is "
            + "answered whole. You cannot run any other command: propose it with term_propose. An agent runs only in "
            + "its own workspace; workspace is the operator's.",
        kind: .mutate, audience: .agentReachable,
        schema: schema(["workspace": text, "repo": text, "process": text], required: ["repo"]),
        handler: { params in
            let w = try await target(params, "workspace_run")
            guard let repo = string(params, "repo") else { throw StandardActionError.missingParam(action: "workspace_run", param: "repo") }
            let report = try await runner.run(w.id, repo: repo, process: string(params, "process"), conversation: caller())
            return report.json
        },
        price: (production: .gate, otherwise: .allow)))

    await registry.register(Action(
        name: "workspace_stop",
        description: "Stop a repo's processes in your workspace (their terminals close), or with no repo every process "
            + "and then the services' teardown. Answers what stopped.",
        kind: .mutate, audience: .agentReachable,
        schema: schema(["workspace": text, "repo": text]),
        handler: { params in
            let w = try await target(params, "workspace_stop")
            let stopped = try await runner.stop(w.id, repo: string(params, "repo"))
            return .object(["workspace": .string(w.id), "stopped": .array(stopped.map { .string($0) })])
        },
        price: (production: .gate, otherwise: .allow)))

    await registry.register(Action(
        name: "workspace_build",
        description: "Run a repo's saved one-shot build in your workspace's copy. Answers ok, the exit code and the "
            + "output whole.",
        kind: .mutate, audience: .agentReachable,
        schema: schema(["workspace": text, "repo": text], required: ["repo"]),
        handler: { params in
            let w = try await target(params, "workspace_build")
            guard let repo = string(params, "repo") else { throw StandardActionError.missingParam(action: "workspace_build", param: "repo") }
            let step = try await runner.build(w.id, repo: repo, conversation: caller())
            return .object(["ok": .bool(step.ok), "exitCode": .integer(Int64(step.exitCode)), "command": .string(step.command),
                            "output": .string(step.output), "seconds": .number(step.seconds)])
        },
        price: (production: .gate, otherwise: .allow)))
}
