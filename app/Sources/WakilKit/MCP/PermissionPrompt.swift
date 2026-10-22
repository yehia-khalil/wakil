import Foundation

/// What Wakil tells the Claude CLI when it asks whether a tool may be
/// invoked. `.deny` carries the message the agent will read — probe §4
/// measured it arriving verbatim, as `tool_result` content with
/// `is_error: true`, so the wording here is wording the agent sees.
public enum PermissionDecision: Equatable, Sendable {
    case allow
    case deny(String)
}

/// The name of the third hand-written tool on Wakil's MCP surface, and the
/// value `buildLaunch` spells into `--permission-prompt-tool`.
///
/// A named constant for the reason `readPaneToolName` is one, with a
/// sharper failure mode: probe §8 measured the CLI refusing at the first
/// permission check when the name it was given is not in `tools/list`, and
/// putting that error in front of the agent. A mismatch here is a session
/// in which every gated tool fails and nothing in the app looks wrong.
public let permissionPromptToolName = "approve_tool_use"

/// Bare action names — no `mcp__wakil__` prefix — that must never be
/// reachable by the agent, even though each is `.control` and therefore
/// both dispatchable without a mutation gate and present in
/// `knownActions` (`ActionRegistry.all()` names every registered action
/// regardless of kind).
///
/// **Why a kind check alone cannot do this job.** `agentAllowedTools`
/// filters `.control` IN by design — layout and `session_resume` rely on
/// that free pass — so no `.control` action
/// can be kept from the agent by its kind. `session_set_provider` is the
/// first one that must be: an agent that could switch its own account
/// could move itself to a provider whose sessions the operator is not
/// watching.
///
/// **`ctx_set_provider` (Phase 2b-vi Task 9, fix round 1) belongs here for
/// a related but distinct reason: the launch-time read, not the live
/// swap.** It cannot move the CURRENT session's account by itself — only
/// `WindowModel.setProvider`'s live swap does that, and an agent still
/// cannot reach `session_set_provider` to trigger one. But
/// `ctx_set_provider` writes `active.json`'s `Provider` field, which
/// `WindowSession.swift` reads (`activeContext?.activeProvider`) to decide
/// which account the NEXT window opens under. An agent that could call it
/// freely could not switch its own account today, but could pick which
/// account Wakil runs under after the next relaunch — a deferred form of
/// exactly what this set exists to forbid, just paid out one launch later
/// instead of immediately.
///
/// **Why absence from a list cannot do this job either, which is the
/// finding this constant exists to close.** Before this constant existed,
/// `session_set_provider` was kept off `agentAllowedTools`'s output by
/// registering it only after that list was already computed. That failed:
/// `permission-prompt-probe.md` §1 measured an unlisted MCP tool being
/// ROUTED to `approve_tool_use` rather than auto-denied — the entire
/// reason this bridge exists — and `permissionDecision` (below) allowed
/// anything in `knownActions`, which `MCPServer` derives from the LIVE
/// registry and therefore already contained the action by the time any
/// real tool call could arrive. Absence from one list bought nothing once
/// a second list said yes.
///
/// **This constant is consulted from two places, and both matter.**
/// `agentAllowedTools` (`App/AgentMCPConfig.swift`) excludes these names from
/// the agent's `--allowedTools` outright — necessary because §6 of the
/// same probe measured that an ALLOW-LISTED tool never even reaches
/// `approve_tool_use`: pre-approval bypasses this file entirely, so an
/// action left on `--allowedTools` could never be refused here no matter
/// what this function said. And `permissionDecision` below denies it
/// explicitly, checked before the ordinary `knownActions` allow — the
/// actual refusal, for the case (routing, a future bug, a `--dispatch`
/// caller with its own registry) where the CLI asks about it anyway. A
/// gate the agent cannot get to is safe by construction; a gate the agent
/// CAN get to and that says no is safe by decision. This constant is
/// deliberately both.
///
/// The org entries were added by 2b-viii, for two reasons worth keeping
/// separate rather than blurring:
///
/// - `ctx_create_org` and `ctx_adopt_provider` are the strong case: an
///   agent that could create an org or bind an account into one could move
///   Invariant 4's own credential boundary.
/// - `ctx_list_orgs` and `ctx_list_machine_providers` are the weaker case,
///   and it is stated rather than inherited by association. They move no
///   boundary, and reading across orgs is established practice —
///   `provider add` has always done it. They are denied because
///   enumerating every org and config dir on the machine is not something
///   a session scoped to ONE org has any business doing.
///
/// `ctx_get_context` is deliberately absent: it is not an action
/// (`ContextStore.swift:38`), and it is how the window reads its own
/// context.
public let operatorOnlyActions: Set<String> = [
    // provider capacity: the agent may not forge a reading the operator chooses accounts by.
    "capacity_record",
    "session_set_provider", "ctx_set_provider",
    // An agent's place is fixed when its session starts (Invariant 5); only the operator moves it.
    "ctx_set_project", "ctx_set_environment",
    "ctx_list_orgs", "ctx_create_org",
    "ctx_list_machine_providers", "ctx_adopt_provider",
    // 2e (#200). `ctx_list_accounts` is the settings pane's account
    // table, and it joins the weaker case above rather than a new one: it
    // moves no boundary, and what it does is enumerate every account and
    // config dir on the machine — which a session scoped to ONE
    // organisation has no business doing. A Keychain presence check per
    // row makes that objection no weaker. The agent still reads the
    // ACTIVE organisation's accounts through `ctx_config_tree`.
    "ctx_list_accounts",
    // 2e-ii. Adding, renaming and removing a project or an environment is the operator's: an
    // agent's place is fixed when its session starts (Invariant 5), and these rewrite the
    // registry and the project files it stands in.
    "ctx_create_project", "ctx_rename_project", "ctx_remove_project",
    "ctx_create_environment", "ctx_rename_environment", "ctx_remove_environment",
    // 3b-v (Decision 38). Decision 30 kept for the editor's settings: they carry no credential,
    // but autosave decides when the operator's files are written, and showing ignored files
    // and the heavy folders decide what search covers; the operator, not the agent, chooses.
    "ctx_set_editor_settings", "ctx_set_project_editor_settings",
    // 3b-viii (Decision 42). Which model reads the operator's code is the operator's choice.
    "ctx_set_local_provider",
    // 2c-iii. The seventh member, and the one whose reason is NOT that the
    // agent could move a boundary by calling it — it is that the shell in
    // a terminal pane carries the active organisation, project and
    // environment (`terminalChildEnvironment`: those three variables, and
    // no secret of its own). The agent already has a bare shell outside
    // Wakil that Wakil cannot stop, so what a pane run would buy it is
    // the inside of the credential boundary that context establishes, not
    // reach; the refusal defends Invariant 4, and the residue
    // of credentialed commands Wakil has no capability for (`kubectl get
    // pods`, `aws s3 ls`, `docker ps`) is rare rather than daily, so it is
    // worth exactly one Enter.
    //
    // Invariant 6's other half is why no shape of this ships: it admits no
    // write that cannot be classified, and a shell command cannot be.
    // `classify_statement` works on SQL because SQL has a bounded grammar
    // and enumerated verbs; a shell has neither — `ls > file` writes,
    // `find -delete` deletes, and `;`, `&&`, `|` and `$()` compose
    // anything out of anything.
    "term_run",
    // 2e (#198). The eighth member, and the weakest case on its own
    // merits — opening a pane damages nothing and moves no boundary.
    // It is here because every OTHER settings action is operator-only on
    // a reason that does hold: the organisation's three strings and the
    // database DSN write across Invariant 4's boundary from the wrong
    // side, the browser login opens a browser, the mint creates a
    // 365-day credential, and the unlink destroys one. Decision 30 rules
    // settings "a pane the agent may read and never drive", and an agent
    // able to open a surface it may drive no part of holds a handle to
    // nothing.
    //
    // **Reading is untouched, and that is the new asymmetry.**
    // `ctx_config_tree` is `.read`, agent-reachable and deliberately
    // absent from this set; `read_pane` answers for a settings pane and
    // `read_layout` names it under `overlay`. The snapshot stays whole.
    "settings_open",
    // 2e (#199). `defaultProvider` names which account an organisation's
    // projects fall back to, so an agent that could set it would be
    // choosing which credentials Wakil reaches for — Invariant 4's
    // boundary, and the same objection `ctx_set_provider` above already
    // carries one level down. The other two strings are harmless on their
    // own and travel with it: a per-field denylist would be a second
    // policy engine for one action.
    "ctx_update_org",
    // 2e (#202). The strongest case in this set: it opens a browser on
    // the operator's machine and begins an authentication AS them.
    // Nothing about that is a boundary an agent could argue for being
    // inside.
    "ctx_provider_login",
    // 2e (#204). It binds an account into an organisation, which is
    // Invariant 4's boundary — `ctx_adopt_provider`'s reason exactly, and
    // it falls into that family's sentence below.
    "ctx_add_provider",
    // 2e (#206). The mirror of `ctx_adopt_provider`: removing a binding
    // moves what an organisation can reach, which is Invariant 4's own
    // boundary. It falls into that family's sentence below.
    "ctx_unlink_provider",
    // 2e (#207). **The reason NEW to this set.** Every other member
    // objects to what the agent could REACH; these two object to what it
    // would CARRY. A DSN is typed by a human, so it travels through the
    // action's own parameters — and `JournalEntry.params` is written
    // verbatim on every dispatch, refused ones included. The journal's
    // redaction rule (#197) keeps it out of the log; this keeps the agent
    // out of the gesture.
    //
    // `db_remove_database` joins it because granting and revoking a
    // database's configuration is the same control surface, and an agent
    // that could drop a row could make a database unreachable without
    // touching a credential.
    "db_set_dsn", "db_remove_database",
]

/// The message `permissionDecision` gives an agent denied one of
/// `operatorOnlyActions`.
///
/// **Why this is a switch and not one shared sentence.** T13-R1 (2b-viii
/// acceptance ruling) found that the brief's own draft test for this task
/// asserted only `reason.contains("operator")` — which the pre-existing
/// provider wording ("the operator chooses which account a session runs
/// under; you cannot switch it") already satisfies. Reusing it for
/// `ctx_list_orgs` would tell an agent that asked to list organisations
/// that it may not switch which account a session runs under: a true
/// sentence about the wrong family, answering a question the agent never
/// asked. Four families, four sentences:
///
/// - `session_set_provider` / `ctx_set_provider`: switching or persisting
///   which account a session runs under. Kept byte-for-byte from before
///   this task — see `operatorOnlyActions`'s own history.
/// - `ctx_create_org` / `ctx_adopt_provider`: the strong case, named
///   explicitly as moving Invariant 4's credential boundary.
/// - `ctx_list_orgs` / `ctx_list_machine_providers`: the weaker case,
///   named explicitly as a session-scope objection rather than a boundary
///   one — see `operatorOnlyActions`'s own doc comment for why the two
///   must not be conflated.
/// - `term_run`: 2c-iii's own family. Not a boundary the agent could move
///   and not a session-scope objection either — the active organisation,
///   project and environment a terminal pane's shell already carries, and
///   so the credential boundary that context establishes, which the agent
///   would otherwise step inside with the operator's Enter substituted for
///   its own. Named `term_propose` explicitly, so the sentence also says
///   what to do instead rather than only what it may not do.
/// - The six project and environment actions (2e-ii): an agent's place is fixed
///   (Invariant 5), and these rewrite the registry and project files it stands
///   in. Not the org family's sentence, which is about Invariant 4.
private func operatorOnlyDenialMessage(toolName: String, action: String) -> String {
    switch action {
    case "session_set_provider", "ctx_set_provider":
        return "\(toolName): the operator chooses which account a session runs under; you "
            + "cannot switch it. Ask the operator to switch it in the Wakil window instead."
    case "ctx_set_project", "ctx_set_environment":
        return "\(toolName): An agent's place is fixed when its session starts (Invariant 5). "
            + "Tell the operator which place the work needs; they can start an agent there."
    case "ctx_create_project", "ctx_rename_project", "ctx_remove_project",
         "ctx_create_environment", "ctx_rename_environment", "ctx_remove_environment":
        return "\(toolName): only the operator adds, renames and removes projects and "
            + "environments. An agent's place is fixed when its session starts (Invariant 5), "
            + "and these rewrite the registry and the project files it stands in. You may READ "
            + "them: ctx_config_tree answers every project and environment. Ask the operator to "
            + "do it in the settings pane (\u{2318},)."
    case "ctx_list_orgs", "ctx_list_machine_providers", "ctx_list_accounts":
        return "\(toolName): this session is scoped to one organisation. Enumerating every "
            + "organisation and config dir on this machine is not something a session scoped "
            + "to one org has any business doing. Ask the operator to do it in the Wakil "
            + "window instead."
    case "settings_open":
        return "\(toolName): only the operator opens the settings pane. Everything on it "
            + "either crosses the credential boundary an organisation is (Invariant 4) or "
            + "creates and destroys credentials, so none of it is yours to drive — and a "
            + "surface you can open but not use is a handle to nothing. You may still READ "
            + "it: ctx_config_tree answers the same configuration the pane draws, read_pane "
            + "answers for the pane itself, and read_layout names it under overlay. Ask the "
            + "operator to press \u{2318}, if they need it on screen."
    case "term_run":
        return "\(toolName): only the operator runs a command in a terminal pane. That "
            + "shell carries the active organisation, project and environment, and running "
            + "there would put you inside the credential boundary that context establishes "
            + "— which is the whole of what running there would add, since you already have "
            + "a shell of your own, outside Wakil. Use term_propose to put the exact command "
            + "in front of the operator; their Enter puts it in their prompt, and a second "
            + "one runs it. Nothing you can pass to this tool will change that answer, so "
            + "do not retry it."
    case "ctx_provider_login":
        return "\(toolName): only the operator signs in. This opens a browser on their "
            + "machine and authenticates as them, which is not something you may begin on "
            + "their behalf. Ask them to add the account from the settings pane (\u{2318},)."
    case "db_set_dsn", "db_remove_database":
        return "\(toolName): only the operator configures a database. A connection string is a "
            + "secret the operator types, and calling this would put it in your own tool "
            + "parameters — which is the one thing Wakil's design for credentials exists to "
            + "avoid. You may READ what is configured: ctx_config_tree reports each database's "
            + "name, driver and Keychain entry name, and never a value. Ask the operator to set "
            + "it in the settings pane (\u{2318},)."
    case "ctx_set_editor_settings", "ctx_set_project_editor_settings":
        return "\(toolName): only the operator changes editor settings (Decision 30). Autosave "
            + "decides when their files are written, the font, wrap and tabs are how they read and "
            + "type, and showing ignored files and the heavy folders decide what search covers "
            + "— choices that are theirs. You may READ them: ctx_editor_settings "
            + "answers the settings in force. Ask the operator to change them in the settings "
            + "pane (\u{2318},)."
    case "ctx_update_org":
        return "\(toolName): only the operator edits an organisation's settings. Its default "
            + "account decides which credentials Wakil reaches for when a project names none, "
            + "which is the credential boundary an organisation is (Invariant 4). You may READ "
            + "these values — ctx_config_tree answers all three. Ask the operator to change "
            + "them in the settings pane (\u{2318},)."
    case "capacity_record":
        return "\(toolName): readings are recorded from the agent's own stream, not supplied by the "
            + "agent. Read them with ctx_capacity."
    default:
        // ctx_create_org, ctx_adopt_provider, ctx_add_provider,
        // ctx_unlink_provider
        return "\(toolName): creating an organisation or adopting an account into one moves "
            + "the credential boundary an organisation is (Invariant 4); only the operator "
            + "may do that. Ask the operator to do it in the Wakil window instead."
    }
}

/// Whether a tool may be *invoked*. Not whether what it does may happen.
///
/// **This distinction is the whole design.** The CLI asks one question —
/// may this tool be called — and Wakil answers that and only that. Whether
/// the call then executes is decided where it is decided today:
/// `ActionRegistry.dispatch`, then `writeGate`, then a human at the
/// confirmation plane. A bridge that consulted `writeGate` would be a
/// second place where state changes are allowed or refused, which is
/// exactly what Invariant 2 exists to prevent.
///
/// **Every kind is allowed, `.mutate` included, and that is the point.**
/// `agentAllowedTools` filters `.mutate` off the session's allow list and
/// must keep doing so; this function is what the CLI consults *because* of
/// that filter. Before it existed, an unlisted tool in a `-p` session was
/// denied outright by the CLI — the request never reached Wakil's socket,
/// so `ConfirmationBroker` never parked it and no confirmation plane ever
/// appeared (`docs/wakil/phase-2a-probe.md` §6).
///
/// **The default branch is a security boundary, not a fallthrough.** Probe
/// §7 measured `--permission-prompt-tool` routing Claude's own built-in
/// tools here too: `Write` and a non-trivial `Bash` both arrive, with a
/// bare `tool_name`. Today Wakil passes no prompt tool, so those are
/// auto-denied for want of an approval surface; naming one makes Wakil the
/// answerer. Allowing by default would remove that restriction while
/// appearing to add one — the agent would gain `Bash` and `Write` in the
/// same change meant to tighten the gate.
///
/// **What it cannot reach.** Probe §7 and §11 also measured read-only
/// built-ins being auto-allowed by CLI policy without this function being
/// consulted at all. Those cannot be denied here because the question
/// never arrives. That is already true of Wakil today and is not changed
/// either way by this function; the honest summary is that it denies every
/// built-in it is *asked* about.
///
/// **The set it cannot reach is bounded by path, not by tool name.**
/// Re-measured 2026-09-10 (probe §7's table) after the first version of
/// this paragraph named `Read`, `Glob` and read-only `Bash` outright and
/// the bridge's acceptance run then refused a `Read` it said was
/// unreachable. `Read ./inside.txt` and `Bash cat inside.txt` never arrive
/// here; `Read /tmp/…` and `Bash cat /tmp/…` both do, and both take the
/// default branch below. `Glob` is struck rather than corrected — it is
/// not in 2.1.266's tool list, so nothing about it was ever measured.
///
/// **The default branch's wording is therefore imprecise, deliberately and
/// with a cost.** It says *"Wakil does not run \(toolName)"*, which reads
/// as a claim about the tool, while the CLI may well have run that same
/// tool a moment earlier on an in-cwd path — a real agent noticed exactly
/// that during the re-measurement and said so. The alternative is worse:
/// this function is given a tool name and an empty-by-design view of
/// policy, so it cannot know *why* it was asked, and a message that
/// guessed at path scope would be wrong whenever the CLI asked for some
/// other reason. A blunt true statement of Wakil's own rule — this agent
/// may call Wakil's actions and nothing else — beats a precise-sounding
/// guess about someone else's.
///
/// `knownActions` is passed in rather than read from a registry so this
/// stays pure and testable, and is derived from `ActionRegistry.all()` at
/// the call site rather than listed anywhere, so it cannot fall behind the
/// action set — the same derivation `agentAllowedTools` uses.
public func permissionDecision(toolName: String, knownActions: [String]) -> PermissionDecision {
    let prefix = "mcp__\(wakilShimServerName)__"
    guard toolName.hasPrefix(prefix) else {
        // Built-ins (bare names), other MCP servers, and lookalikes such as
        // `mcp__wakil-pm__…`, which shares this prefix up to its tenth
        // character and diverges at the separator.
        return .deny(
            "Wakil does not run \(toolName). This session's agent may call Wakil's own "
            + "actions and nothing else — use one of those, or ask the operator to do it "
            + "in the Wakil window.")
    }
    let bare = String(toolName.dropFirst(prefix.count))

    if bare == permissionPromptToolName {
        return .deny("\(toolName) answers permission questions; it does not ask them.")
    }
    if bare == readPaneToolName || bare == readLayoutToolName {
        return .allow
    }
    // Checked BEFORE the ordinary `knownActions` allow below, and that
    // order is the entire point: `session_set_provider` IS in
    // `knownActions` (it is a registered action, just like any other),
    // so an ordinary allow-by-kind check would say yes to it. See
    // `operatorOnlyActions`'s own doc comment for the full argument —
    // this is the actual refusal, not the action's absence from any list.
    if operatorOnlyActions.contains(bare) {
        return .deny(operatorOnlyDenialMessage(toolName: toolName, action: bare))
    }
    if knownActions.contains(bare) {
        return .allow
    }
    return .deny(
        "\(toolName) is not a registered Wakil action. Call tools/list to see what is.")
}

/// `approve_tool_use`'s `tools/list` entry.
///
/// **Written for the agent that will read it.** Probe §8 measured that this
/// tool cannot be hidden: a `tools/list` omitting it makes the CLI refuse at
/// the first permission check and puts the error in front of the agent. So
/// the agent will see this description, and it says plainly that calling the
/// tool directly accomplishes nothing — an agent that understands this is
/// not asking Wakil's permission for anything is an agent that does not try
/// to use it as one.
public let permissionPromptToolListEntry = JSONValue.object([
    "name": .string(permissionPromptToolName),
    // Read-only in the protocol's sense — `permissionPromptReply` is a pure
    // function of its arguments and changes nothing — even though what it
    // answers is a question about a write. See `toolListEntry` for why the
    // hint is emitted at all.
    "annotations": .object(["readOnlyHint": .bool(true)]),
    "description": .string(
        "Wakil's answer to the Claude CLI when the CLI asks whether some tool may be "
        + "invoked. The CLI calls this by itself; calling it yourself does nothing, because "
        + "nothing is listening to the answer. It decides only whether a tool can be "
        + "reached, never whether what that tool does may happen — a mutation still has to "
        + "be confirmed by the operator in Wakil's window."),
    "inputSchema": .object([
        "type": .string("object"),
        "properties": .object([
            "tool_name": .object(["type": .string("string")]),
            "input": .object(["type": .string("object")]),
            "tool_use_id": .object(["type": .string("string")]),
        ]),
        "required": .array([.string("tool_name")]),
    ]),
])

/// Answers one CLI permission question in the shape probe §3 measured: a
/// `tools/call` result whose single text content block carries the JSON
/// `{"behavior":"allow","updatedInput":{…}}` or
/// `{"behavior":"deny","message":"…"}`. The JSON is the block's **text**,
/// not a JSON result object — get that wrong and the CLI cannot read the
/// answer at all.
///
/// It never returns a `JSONRPCError`. A JSON-RPC error is not an answer to
/// *may this run*, the CLI's handling of one here is unmeasured, and the
/// failure direction that costs nothing is refusal.
func permissionPromptReply(
    id: JSONRPCID,
    arguments: JSONValue,
    knownActions: [String]
) -> JSONRPCMessage {
    guard case .object(let object) = arguments,
          case .string(let toolName)? = object["tool_name"] else {
        return permissionPromptEnvelope(id: id, body: .object([
            "behavior": .string("deny"),
            "message": .string(
                "A permission request arrived with no \"tool_name\", so Wakil could not tell "
                + "what was being asked about. Nothing was allowed and nothing ran."),
        ]))
    }

    // The target tool's schema is the target tool's business. Refusing an
    // input this function cannot read would deny calls `dispatch` would
    // have handled.
    var input = JSONValue.object([:])
    if let candidate = object["input"], case .object = candidate { input = candidate }

    switch permissionDecision(toolName: toolName, knownActions: knownActions) {
    case .allow:
        // Verbatim. Probe §5: `updatedInput` replaces the tool's arguments
        // wholesale and the agent is never told, so anything rebuilt here
        // silently rewrites the call that was proposed.
        return permissionPromptEnvelope(id: id, body: .object([
            "behavior": .string("allow"),
            "updatedInput": input,
        ]))
    case .deny(let message):
        // Probe §4: this string reaches the agent verbatim, as
        // `tool_result` content with `is_error: true`.
        return permissionPromptEnvelope(id: id, body: .object([
            "behavior": .string("deny"),
            "message": .string(message),
        ]))
    }
}

/// Wraps a decision body in the `tools/call` result shape.
///
/// `.sortedKeys` so the same question renders identically twice running: two
/// otherwise identical sessions should not differ in a log because a
/// dictionary walked in a different order.
///
/// The encode cannot fail for the two bodies above — both are string-keyed
/// objects of strings and an echoed `JSONValue` — and if it somehow did, a
/// denial is the only safe thing to say.
private func permissionPromptEnvelope(id: JSONRPCID, body: JSONValue) -> JSONRPCMessage {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let text = (try? encoder.encode(body)).flatMap { String(data: $0, encoding: .utf8) }
        ?? #"{"behavior":"deny","message":"Wakil could not encode its answer."}"#
    return JSONRPCMessage(id: id, result: .object([
        "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
    ]))
}
