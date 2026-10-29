import Foundation

/// Workspaces, piece 2: a project's **Running** settings (decisions 13–15). Operator-only like
/// every Settings write (Decision 30): what runs on the operator's machine, and the secrets it
/// gets, are theirs to write; the agent reaches running only through `workspace_run` and only
/// the saved recipe. Each is a forward to wakil-ctx's recipe tools; a refusal comes back whole.
public let runningSettingsActions = [
    "running_read", "running_detect", "running_draft_all", "running_save", "running_secret_set",
    "running_try", "running_try_end",
]

public func registerRunningActions(
    into registry: ActionRegistry, context: (any ToolCaller)?, runner: WorkspaceRunner
) async {
    let str: JSONValue = .object(["type": .string("string")])
    let strings: JSONValue = .object(["type": .string("array"), "items": str])
    let object: JSONValue = .object(["type": .string("object")])
    for (name, tool, description, properties, required, kind, secrets) in [
        ("running_read", "recipe_list",
         "A project's Running settings as stored: recipes, each repo's recipe, overrides and doesntRun with its "
            + "effective recipe and where each field came from, and every problem. Operator-only.",
         ["projectPath": str], [String](), ActionKind.read, [String]()),
        ("running_detect", "recipe_detect",
         "Detect how one repo runs from its files (no model); a draft, nothing saved (Rule 9). Operator-only.",
         ["repo": str, "projectPath": str], ["repo"], .read, []),
        ("running_draft_all", "recipe_draft_all",
         "Draft all: recipes for every repo, alike ones grouped, shared services proposed, questions; nothing saved. "
            + "Operator-only.",
         ["repos": strings, "projectPath": str], [], .read, []),
        ("running_save", "recipe_save",
         "Save recipes (by name; null deletes one) and repos' run settings ({recipe, overrides, doesntRun}) into "
            + "project.json; refused whole, every problem listed, when anything would not validate. Operator-only.",
         ["recipes": object, "repos": object, "projectPath": str], [], .control, []),
        ("running_secret_set", "recipe_secret_set",
         "Keep an env variable's secret in the Keychain under run:<project>:<owner>:<variable>; answers the ref the "
            + "recipe names. Operator-only.",
         ["project": str, "owner": str, "variable": str, "value": str], ["project", "owner", "variable", "value"], .control, ["value"]),
    ] {
        await registry.register(Action(
            name: name, description: description, kind: kind, audience: .operatorOnly,
            schema: .object(["type": .string("object"), "properties": .object(properties),
                             "required": .array(required.map { .string($0) })]),
            handler: { params in
                guard let context else { throw StandardActionError.missingClient(action: name, role: "context") }
                var arguments: [String: JSONValue] = [:]
                for key in required { arguments[key] = .string(try runParam(params, key, action: name)) }
                if case .object(let o) = params {
                    for key in properties.keys where arguments[key] == nil { if let v = o[key], v != .null { arguments[key] = v } }
                }
                return try await callCheckedTool(context, tool: tool, arguments: .object(arguments), action: name,
                                             timeout: name == "running_draft_all" ? 60 : MCPClient.mutationReplyTimeout)
            },
            secretParams: Set(secrets)))
    }

    await registry.register(Action(
        name: "running_try",
        description: "Try a repo's saved recipe (decision 13) in a throwaway workspace: a copy of the repo from its "
            + "folder's commit, its own ports; services, setup, the processes headless, the ready check, then the "
            + "processes stopped and teardown run. Answers the workspace (end it with running_try_end), passed, and "
            + "every step with its output whole. Cancel stops it. Operator-only.",
        kind: .control, audience: .operatorOnly,
        schema: .object(["type": .string("object"), "properties": .object([
            "repo": str, "root": str, "project": str, "environment": str, "projectPath": str,
        ]), "required": .array([.string("repo"), .string("root"), .string("project")])]),
        handler: { params in
            func s(_ k: String) -> String? { if case .object(let o) = params, case .string(let v)? = o[k], !v.isEmpty { v } else { nil } }
            let (w, result) = try await runner.tryRecipe(
                repo: try runParam(params, "repo", action: "running_try"),
                root: try runParam(params, "root", action: "running_try"),
                project: try runParam(params, "project", action: "running_try"),
                environment: s("environment") ?? "", projectPath: s("projectPath"))
            return .object([
                "workspace": .string(w), "passed": .bool(result.passed),
                "steps": .array(result.steps.map { st in .object([
                    "phase": .string(st.phase), "name": .string(st.name), "command": .string(st.command), "ok": .bool(st.ok),
                    "exitCode": .integer(Int64(st.exitCode)), "output": .string(st.output), "seconds": .number(st.seconds),
                    "detail": .string(st.detail),
                ]) }),
                "ready": result.ready.map { .object(["ready": .bool($0.ready), "detail": .string($0.detail)]) } ?? .null,
            ])
        }))

    await registry.register(Action(
        name: "running_try_end",
        description: "End a Try: its throwaway workspace is archived and forgotten (the form closed). Operator-only.",
        kind: .control, audience: .operatorOnly,
        schema: .object(["type": .string("object"), "properties": .object(["workspace": str]),
                         "required": .array([.string("workspace")])]),
        handler: { params in
            let id = try runParam(params, "workspace", action: "running_try_end")
            try await runner.endTry(id)
            return .object(["workspace": .string(id)])
        }))
}

/// A required string param, present and not empty.
func runParam(_ params: JSONValue, _ key: String, action: String) throws -> String {
    if case .object(let o) = params, case .string(let v)? = o[key], !v.isEmpty { return v }
    throw StandardActionError.missingParam(action: action, param: key)
}
