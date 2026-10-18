import Foundation

// MARK: - The agent's MCP configuration

/// The bundled Phase 1 binaries the agent is allowed to call directly, per
/// spec §2.1: they "produce *answers*, not pane state". `wakil-ctx`,
/// `wakil-db` and `wakil-http` are deliberately absent — they affect panes,
/// so the registry is their only caller and the agent reaches them only
/// through the `wakil` shim, which dispatches. That is what keeps pane state
/// a single code path (Invariant 2) instead of something an observer
/// reconstructs from the transcript.
///
/// **`wakil-git` joined in 3a-i** (spec: "the agent also gets wakil-git's three read tools
/// over MCP", Invariant 9). Its `git_status`, `git_diff` and `git_show` answer and touch no
/// pane — the pane's own state moves only through the registry's `git_*` actions — so it is
/// an answer binary in exactly §2.1's sense. The window runs a second copy of it for those
/// actions (`WakilWiring.gitClient`); the two never share a process.
public let agentFacingServers = ["wakil-pm", "wakil-recall", "wakil-git"]

/// Builds the `--mcp-config` JSON one session launches with: the `wakil`
/// shim, plus whichever of `agentFacingServers` `binaries` could supply.
///
/// `binaries` is a lookup, not a list to publish: any name in it that is not
/// in `agentFacingServers` is ignored. Combined with `--strict-mcp-config`
/// (which `buildLaunch` always passes), this JSON is the complete set of MCP
/// servers the session has, so what is absent here is unreachable to the
/// agent rather than merely undocumented.
///
/// `place` (as `WAKIL_ORG`, `WAKIL_PROJECT`, `WAKIL_ENVIRONMENT`) and `provider`
/// (`WAKIL_PROVIDER`) go to every
/// server, which is spec §2.4's mechanism for taking org identity off the
/// config dir. They are set on the shim too, not only on the Phase 1
/// binaries — the shim ignores them (`runShim` parses nothing and reads no
/// environment variable at all, per §2.2), and setting them uniformly means
/// the question "which org is this session for" is answered by reading the
/// config once rather than server by server.
public func agentMCPConfigJSON(
    shimExecutable: URL,
    socketPath: String,
    binaries: [String: URL],
    place: Place?,
    provider: String?
) -> String {
    var environment: [String: JSONValue] = [:]
    // Absent means unset, never the empty string (the Go side reads an empty one as unset too).
    // With WAKIL_PROJECT set, the session's environment is WAKIL_ENVIRONMENT alone: absent means
    // no environment, never active.json's (`ReadActive`). Without it, an absent member follows
    // active.json — the operator's window.
    if let place {
        if !place.organization.isEmpty { environment["WAKIL_ORG"] = .string(place.organization) }
        if !place.project.isEmpty { environment["WAKIL_PROJECT"] = .string(place.project) }
        if !place.environment.isEmpty { environment["WAKIL_ENVIRONMENT"] = .string(place.environment) }
    }
    if let provider { environment["WAKIL_PROVIDER"] = .string(provider) }

    var servers: [String: JSONValue] = [
        wakilShimServerName: .object([
            "command": .string(shimExecutable.path),
            "args": .array([.string("--mcp-shim"), .string("--socket"), .string(socketPath)]),
            "env": .object(environment),
        ])
    ]
    for name in agentFacingServers {
        guard let url = binaries[name] else { continue }
        servers[name] = .object([
            "command": .string(url.path),
            "args": .array([]),
            "env": .object(environment),
        ])
    }

    let config = JSONValue.object(["mcpServers": .object(servers)])
    guard let data = try? JSONEncoder().encode(config), let json = String(data: data, encoding: .utf8) else {
        // Unreachable for these cases — every `JSONValue` built above is a
        // string, array or object of the same — but a fallback beats a
        // forced unwrap that could take the window down at launch. An empty
        // server list under `--strict-mcp-config` means the agent gets no
        // tools, which fails visibly in the thought thread.
        return #"{"mcpServers":{}}"#
    }
    return json
}

/// The `--allowedTools` list one session launches with: every tool the agent
/// is permitted to call without an approval prompt.
///
/// **Why this exists at all.** Task 1's live probe (`docs/wakil/phase-2a-probe.md`
/// §6) measured the CLI's permission layer covering MCP tool calls and
/// denying them outright when the session has no approval surface — *"it
/// requires approval, and this session has no approval surface … so it was
/// denied automatically"*. A `-p` session is exactly such a session. Without
/// an allow list the agent is therefore refused **every** Wakil tool,
/// `read_pane` included, and the refusal arrives as a `tool_result` with
/// `is_error` rather than as anything the app could mistake for a bug in its
/// own wiring. The allow list is not a security boundary — see below — it is
/// what stops the CLI from auto-denying a read the registry has already
/// decided is safe.
///
/// **Why the entries are what they are.**
/// - Registry actions are named one at a time, in the CLI's
///   `mcp__<server>__<tool>` form (probe §4: "anything passed to
///   `--allowedTools` must use the prefixed form"), derived from
///   `ActionRegistry.all()` rather than copied — so the list cannot fall
///   behind the action set.
/// - `.read` and `.control` actions, never `.mutate`. In 2a every action was
///   `.read`, so the filter removed nothing; 2b-i Task 9 made the two `ctx_*`
///   setters `.control` and Task 10 (this widening) admitted `.control` so
///   they, and the nine `pane_*` layout actions, are reachable at all. What
///   the filter still guarantees is that the *first* `.mutate` action any
///   phase registers is structurally absent from the allow list instead of
///   quietly pre-approved by a list nobody revisited.
/// - `read_pane` and `read_layout` by name, since both are hand-written
///   rather than projected actions (design §2.3) and so are not in
///   `ActionRegistry.all()`.
/// - `wakil-pm`, `wakil-recall` and `wakil-git` server-wide (`mcp__<server>`,
///   the CLI's whole-server rule form) rather than tool by tool. Their tools
///   are defined in the Go binaries, not here; enumerating them in Swift
///   would be precisely the stale second copy this function is derived to
///   avoid. Spec §5 records that the first two only read — Phase 1's
///   capability layer has zero mutating operations — and `wakil-git` is
///   read-only by construction (3a-i: an allowlist of subcommands and flags,
///   confined to the project's roots). `agentMCPConfigJSON` gives the agent
///   no other servers, `--strict-mcp-config` making that set closed.
///
/// **The `--permission-prompt-tool` this list needs now exists**
/// (`buildLaunch`, and `MCP/PermissionPrompt.swift`). It was owed from 2a,
/// which declined to build it on the grounds that a permission-prompt tool
/// is a refusal surface and 2a registered zero `.mutate` actions — there
/// was nothing for it to refuse. That ceased to be true on 2026-09-09,
/// when 2b-iii registered `db_run_mutation`, and for one day the
/// consequence was concrete rather than theoretical: `.mutate` is filtered
/// off this list, and in a `-p` session an unlisted MCP tool was denied by
/// the CLI itself, so the request never reached Wakil's socket,
/// `ConfirmationBroker` never parked it, and no confirmation plane ever
/// appeared.
///
/// **The filter below still does not name a `.mutate` action, and that has
/// not changed.** Failing closed is the direction to fail in, and
/// pre-approving a `.mutate` action here would put the write gate at the
/// mercy of an allow list nobody thought to revisit. What the prompt tool
/// supplies is the approval surface the CLI needs in order to *ask* — not
/// a wider list. The two are a pair: this list is what runs without being
/// asked about, and `permissionDecision` is who gets asked about
/// everything else.
///
/// **`approve_tool_use` is deliberately absent from this list too.**
/// `permission-prompt-probe.md` §11 ran exactly this shape — a non-empty
/// allow list that excludes the prompt tool — and the CLI reached its
/// designated tool anyway. Adding it would buy nothing and would give the
/// agent a silent route to call it directly.
///
/// The enforcement point meanwhile is
/// `ActionRegistry.dispatch` plus `writeGate` (Invariant 2: actions are the
/// only path to state), and since every name this function emits is a `.read`
/// or `.control` action — never `.mutate` — the allow list grants nothing the
/// registry would not: `.control` actions still go through `dispatch` and
/// `writeGate`, which is what decides whether a given call needs a
/// confirmation, not this list. The live-agent instance of that path is
/// `docs/wakil/phase-2b-iii-acceptance.md` §3's first gap and §2 check 3b;
/// `MCPServerTests.anAgentProposedMutationParksAndRunsOnceApproved` is, until
/// check 3b is walked, the only thing at this call site distinguishing the
/// headless proof of the agent-mutation path from the live one.
///
/// `--permission-mode` is likewise not passed. The modes on offer
/// (`acceptEdits`, `bypassPermissions`, `dontAsk`, `plan`, …) all widen or
/// redirect permission handling for the *built-in* tools as well as MCP ones,
/// and `bypassPermissions` would switch the CLI's layer off entirely — the
/// opposite of what 2b needs to inherit.
///
/// **"Everything else" is now three populations, not one, and the bridge
/// treats them differently.** A `.mutate` action is filtered off this list,
/// reaches `approve_tool_use`, and is *allowed through* by it — the bridge's
/// job is reachability, not refusal, so what refuses or parks it is Wakil's
/// own gate, `ActionRegistry.dispatch` plus `writeGate`, exactly as the two
/// paragraphs above describe. A built-in that would have prompted
/// interactively (`Write`, a non-trivial `Bash`) also reaches the bridge, but
/// `permissionDecision`'s default branch denies it — nothing named it, so
/// nothing approved it. A built-in the CLI's own policy auto-allows never
/// reaches the bridge at all and so cannot be denied there; that was true
/// before this work and is unchanged by it.
///
/// **That auto-allowed set is bounded by path, not by tool name** — probe §7,
/// re-measured 2026-09-10 after this paragraph's first version overstated it.
/// The CLI settles read-only work whose target is inside the session's working
/// directory; the identical tool pointed outside it reaches the bridge and is
/// denied. `Read ./inside.txt` and `Bash cat inside.txt` never arrive;
/// `Read /tmp/…` and `Bash cat /tmp/…` both arrive and are both refused in
/// `permissionDecision`'s own words. Do not restate this as "`Read` cannot be
/// denied": that was the wrong summary, it was repeated in three documents,
/// and it understates what the bridge actually covers.
///
/// Failing closed is still the direction to fail in, and
/// `--permission-mode` remains a flag not passed rather than a flag whose
/// blast radius would have to be explained.
///
/// **What is verified.** The argv only. `ClaudeCodeCLIHarnessTests` asserts
/// the flag and its value, `WindowModelTests` asserts this list against the
/// registry's own action set and against the `--mcp-config` server keys. No
/// test in this repo runs `claude`. That the CLI *honours* these entries —
/// that a live turn calls `mcp__wakil__ctx_list_projects` and is not denied —
/// is confirmed only by standing check 2 of
/// `docs/wakil/phase-2a-acceptance.md`, run by the operator.
public func agentAllowedTools(actions: [ActionDescriptor]) -> [String] {
    // `.read` and `.control`, never `.mutate`.
    //
    // `.control` joined this list in 2b-i and is what makes "put the
    // results next to the terminal" reachable at all — layout actions are
    // `.control`, and a filter on `.read` alone would publish a tool
    // surface the agent could see in `tools/list` and never be permitted
    // to call. The context setters were `.control` too, but an agent's place is
    // fixed when its session starts, so `ctx_set_project` and
    // `ctx_set_environment` are operator-only and filtered below.
    //
    // **`operatorOnlyActions` is the one deliberate exception, and it is
    // NOT optional here.** `session_set_provider` is `.control`, exactly
    // like the actions the paragraph above keeps reachable, and would
    // pass the kind filter the same way they do. It has to be named and
    // excluded explicitly instead, because `permission-prompt-probe.md`
    // §6 measured that an ALLOW-LISTED tool never even reaches
    // `approve_tool_use` — pre-approval here bypasses `permissionDecision`
    // entirely, so `operatorOnlyActions`'s denial there could never run
    // for an action this function still published. Excluding it here and
    // denying it in `permissionDecision` are two halves of one refusal,
    // not two independent safeguards — see `operatorOnlyActions`'s own
    // doc comment.
    //
    // Sorted because `ActionRegistry.all()` walks a dictionary and so has
    // no order of its own: an argv that changed between launches would
    // make two otherwise identical sessions diff differently in a log.
    var tools = actions
        .filter { ($0.kind == .read || $0.kind == .control) && !operatorOnlyActions.contains($0.name) }
        .map { "mcp__\(wakilShimServerName)__\($0.name)" }
        .sorted()
    tools.append("mcp__\(wakilShimServerName)__\(readPaneToolName)")
    tools.append("mcp__\(wakilShimServerName)__\(readLayoutToolName)")
    tools.append(contentsOf: agentFacingServers.map { "mcp__\($0)" })
    return tools
}
