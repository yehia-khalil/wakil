import Foundation

/// Errors a standard action's handler throws for reasons of its own —
/// as opposed to a `ContextStoreError` or an `MCPClientError` relayed
/// unchanged from a lower layer.
public enum StandardActionError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The action needs an `MCPClient` that `registerStandardActions`
    /// was given as `nil`. The two strings are the action's own name and
    /// which client role it needed ("context" or "database"), so the
    /// thrown error names exactly what is missing rather than just
    /// failing silently or crashing on a forced unwrap.
    case missingClient(action: String, role: String)
    /// The caller's `params` object was missing a required key.
    case missingParam(action: String, param: String)
    /// The tool call reached the server and it reported `isError: true`.
    /// The message is the server's own text, verbatim — see
    /// `mcpErrorText(from:)`.
    case serverError(action: String, message: String)
    /// A MUTATION's tool call ran out of its reply budget
    /// (`MCPClient.mutationReplyTimeout`) before the server answered.
    ///
    /// **This is not a failure report, and its wording must never read as
    /// one.** Wakil stopped waiting; nothing stopped the statement. It may
    /// still be executing inside the engine, and it may already have
    /// committed. A caller told "it failed" would be told the one thing
    /// that is certainly not known — and, worse, an operator who believes
    /// it would re-confirm, applying an `INSERT` twice.
    ///
    /// A read has no equivalent case on purpose: abandoning a read costs
    /// nothing, so `MCPClientError.timeout` is left to speak for itself
    /// there.
    case mutationFateUnknown(action: String, statement: String, seconds: TimeInterval)
    /// The caller named a pane that is not open. `open` is every pane id
    /// that *is*, so the message can say what to use instead rather than
    /// only what was wrong.
    ///
    /// **This is an error and not a silent write.** Until it existed, an
    /// explicit `pane` was passed through unchecked: rows went into
    /// `PaneStore` under whatever key was given, and a key no pane holds
    /// is a pane nothing draws. The canvas read "no rows" while the tool
    /// result showed the rows plainly, so the agent — and the operator
    /// reading over its shoulder — had every reason to believe it had
    /// worked. That is the same failure as DEFECT X (`docs/wakil/
    /// phase-2c-i-acceptance.md` §5.6), which fixed the *default* pane and
    /// left the explicit one able to reach it.
    case unknownPane(action: String, pane: String, open: [String])
    /// The caller asked a pane to re-run, page or re-sort its query, and
    /// the pane has no query. A pane that has never been queried is not an
    /// error to *open*; it is an error to ask one to run again.
    case paneHasNoQuery(action: String, pane: String)
    /// The caller asked `db_page` to move a pane whose current result
    /// cannot be paged at all — a table list, an `EXPLAIN`, a `SHOW`.
    ///
    /// **Refused before the offset moves, not after.** `refetchPane` forces
    /// `offset: 0` for `.tables`/`.columns` regardless of what
    /// `PaneFetch.offset` already says, so a pane whose last `setRows` was
    /// not pageable can already carry a stale, nonzero offset that a page
    /// move would only compound: `Pane.fetch.offset` would read the moved
    /// value while the pane still shows the one complete page it always
    /// has, and Task 13's footer would compute a row range off the wrong
    /// number. `db_page`'s handler checks `PaneStore.pageable(paneId:)`
    /// before calling `PaneFetch.page(to:)` or `LayoutStore.setFetch`, so
    /// this is thrown with the pane's fetch completely untouched.
    case paneNotPageable(action: String, pane: String)
    /// A read is already running on this pane (Interaction Rule 5).
    case readInFlight(action: String, pane: String)
    /// `db_cancel` on a pane with no read running. Refused rather than a silent success, which
    /// would tell the agent it stopped something.
    case nothingInFlight(action: String, pane: String)

    public var description: String {
        switch self {
        case .missingClient(let action, let role):
            return "\(action): no \(role) MCP client was provided"
        case .missingParam(let action, let param):
            return "\(action): missing required param \"\(param)\""
        case .serverError(let action, let message):
            return "\(action): \(message)"
        case .unknownPane(let action, let pane, let open):
            let known = open.isEmpty
                ? "no panes are open"
                : "open panes: " + open.map { "\"\($0)\"" }.joined(separator: ", ")
            return "\(action): no pane with id \"\(pane)\" is open — \(known). "
                + "A pane's id is what \"pane_open\" returns and what \"read_layout\" "
                + "lists; it is not the pane's title."
        case .mutationFateUnknown(let action, let statement, let seconds):
            return "\(action): no reply from the database after \(Int(seconds))s. "
                + "THE STATEMENT MAY STILL BE RUNNING, AND MAY ALREADY HAVE COMMITTED — "
                + "this is NOT a report that nothing happened. Wakil stopped waiting; it did not "
                + "stop the statement. Check the database itself to find out what it did, and do "
                + "not simply run this again on the assumption that it did nothing — repeating an "
                + "INSERT would apply it twice. Statement: \(statement)"
        case .paneHasNoQuery(let action, let pane):
            return "\(action): pane \"\(pane)\" is not showing a query yet — "
                + "run db_run_query, db_read_table or db_list_tables against it first"
        case .readInFlight(let action, let pane):
            return "\(action): a read is already running on pane \(pane) — wait for it, or cancel it with db_cancel"
        case .nothingInFlight(let action, let pane):
            return "\(action): nothing is running on pane \(pane) — there is no read to cancel"
        case .paneNotPageable(let action, let pane):
            return "\(action): pane \"\(pane)\"'s current result cannot be paged — "
                + "a table list, an EXPLAIN or a SHOW has no second page to move to"
        }
    }
}

/// Registers Wakil's standard action set — the actions an AI agent or the
/// UI can dispatch through `ActionRegistry` — into `registry`.
///
/// Twenty-six actions are registered here. Seventeen are `ActionKind.read`
/// (`ctx_list_projects`, `ctx_list_providers`, `ctx_list_orgs`,
/// `ctx_list_machine_providers`, `db_list_databases`,
/// `db_run_query`, `db_list_tables`, `db_describe_table`, `db_read_table`,
/// `db_refetch`, `db_page`, `db_classify_statement`, `db_render_update`,
/// `pane_sort`, `session_get`, `session_list`, `session_read`), eight are
/// `.control` (the three `ctx_` setters, `ctx_create_org`,
/// `ctx_adopt_provider`, `session_resume`, `session_record_parent` and
/// `session_set_provider`, below), and one — `db_run_mutation` — is
/// `.mutate`. The seven newest reads before `db_render_update` are 2c-ii's:
/// each one reaches a database, which is what keeps it out of `.control`
/// — and `pane_sort` moved here from `PaneContentActions.swift` and
/// changed kind for exactly that reason, because sorting an incomplete
/// result re-queries. `db_render_update` itself reaches a database too,
/// and its own registration comment (beside `db_run_mutation`, below)
/// argues at length for why `.read` is still correct even though the
/// connection it opens is the writable one.
/// The `ctx_` setters change Wakil's own selection of what
/// is active, not the outside world the gate exists to protect, so the
/// environment must never block them — gating a context switch in
/// `production` would block it in exactly the case where an operator most
/// needs to go *look* at something.
/// `session_resume`, `session_record_parent` and `session_set_provider`
/// are `.control` for the same reason: each changes only Wakil's own
/// state (an agent process, a lineage file, an active provider id) and
/// touches nothing outside Wakil, which is what the gate exists to
/// protect (see `session_record_parent`'s own registration below for the
/// fuller argument). **`session_set_provider` is the one `.control`
/// action the agent must never reach anyway** — see its own registration
/// below for why `.control`'s usual free pass through
///
/// `ctx_list_orgs` and `ctx_list_machine_providers`, added by Phase
/// 2b-viii Task 13, are `.read` for the same reason as the other
/// `ctx_list_*` actions beside them — see each one's own registration
/// comment. `ctx_create_org` and `ctx_adopt_provider`, added by the same
/// task, are `.control` rather than `.mutate`: each writes only to this
/// machine's own `~/.wakil` tree, never a customer database, which is
/// what `.mutate` and the write gate exist to catch — but unlike the
/// `ctx_` setters, which merely SELECT among values that already exist,
/// these two MINT a new organisation or move an account's home into one,
/// which is why all four are additionally in `operatorOnlyActions`
/// (`PermissionPrompt.swift`) even though `.control` and `.read` are
/// ordinarily agent-reachable by default — see that constant's own doc
/// comment for the two separate reasons the four are split into.
/// `agentAllowedTools` does not apply to it, and what does instead.
///
/// **`ctx_set_provider`, added by Phase 2b-vi Task 9, is different from
/// `session_set_provider` even though the two names look alike.**
/// `session_set_provider` is the operator/UI-only request that tells a
/// live `WindowModel` to actually swap its running harness — the thing
/// this file's `.control` classification above is arguing about.
/// `ctx_set_provider` is the much smaller, purely bookkeeping action
/// `WindowModel.setProvider` dispatches AFTER that swap has already
/// succeeded, to persist the chosen id into `active.json`'s fourth axis
/// (Task 7) so it survives past this window's lifetime. It needs no
/// broker of its own — unlike `session_set_provider`, it dispatches
/// straight to `wakil-ctx`'s `set_provider` tool exactly like
/// `ctx_set_project` and `ctx_set_environment` dispatch to theirs, with no
/// live `WindowModel` required to act on it.
///
/// **It is, however, IN `operatorOnlyActions` (fix round 1, acceptance
/// review) — do not read "no broker of its own" as "safe for the agent".**
/// The write this performs is exactly the field `WindowSession.swift`
/// reads (`activeContext?.activeProvider`) to decide which account the
/// NEXT window opens under. An agent that could call this freely still
/// could not swap its OWN running session — that still requires
/// `session_set_provider`, which it cannot reach — but it could choose
/// which account Wakil runs under after the next relaunch, a deferred
/// form of exactly what `session_set_provider`'s exclusion exists to
/// forbid. "A remembered default" was this comment's own understatement
/// before the fix: a *chosen* default an agent picked for its own next
/// launch is not a merely stale value, it is the thing Task 8's two
/// layers exist to prevent, paid out one launch later instead of
/// immediately.
///
/// Both setters are operator-only: an agent's place is fixed when its
/// session starts, so the agent cannot switch project or environment at
/// all. 2a classified both `.read` and the 2026-09-08 acceptance run found
/// the consequence: asked only to list projects, the agent also set the
/// active one, and nothing stopped it
/// (`docs/wakil/phase-2a-acceptance.md` §6). `ctx_set_environment` still
/// declares `targetEnvironmentParam: "name"`, so `writeGate` would hold an
/// agent-originated switch into production if one ever reached it — a
/// second layer behind the audience, not the thing that stops the agent.
///
/// **`ctx_set_project` deliberately declares no target.**
/// `wakilcore.SetProjectChecked` keeps the current environment name when
/// the incoming project defines one by that name and otherwise clears it
/// to `""` — there is no per-project "last environment" stored anywhere to
/// restore. So a project switch can only preserve the current environment
/// or drop to none; it cannot elevate staging into production, and there
/// is nothing for the gate to catch. `ctxSetProjectCannotElevateInto
/// Production` below pins that Phase 1 behaviour, so a change to it fails
/// here rather than quietly widening the gate.
///
/// **Wakil ships exactly one `.mutate` action, and this is where it lives.**
/// `db_run_mutation` (below) is it, added by Phase 2b-iii. Until 2026-09-09
/// this sentence read "Wakil still ships zero `.mutate` actions", which is
/// what made `phase-2a-acceptance.md`'s checks 5 and 6 unrunnable: the gate
/// was fully built and fully tested with nothing to gate.
///
/// A second `.mutate` action is a deliberate decision, not a routine
/// addition — Invariant 6 asks for a justification per adapter, and
/// `MutationActionTests` pins the count at one so that adding another fails
/// a test rather than passing unremarked.
///
/// **On the names.** Each is `<area>_<verb>`: the `ctx_` / `db_` / `session_`
/// prefix is what distinguishes *Wakil's* action from the underlying Go
/// server tool it calls, which is a different thing with a shorter name —
/// `ctx_set_project` here dispatches to `wakil-ctx`'s `set_project`, and
/// `db_run_query` to `wakil-db`'s `query`. The prefix exists so those two
/// namespaces cannot be confused; the Phase 1 tool names are not changed by
/// anything in this file.
///
/// The separator is an underscore rather than the dot these names first
/// used, because `MCPServer` projects every registered action onto Wakil's
/// MCP surface and the `claude` CLI turns each one into
/// `mcp__<server>__<tool>` before handing it to the Anthropic API, whose
/// documented tool-name rule is `^[a-zA-Z0-9_-]{1,128}$` — which a dot does
/// not satisfy. The CLI does not normalise the name on the way past: its
/// name-construction path was *read* (`claude` 2.1.263), not run — no test
/// or build step in this repo invokes `claude` — and the per-part lookup it
/// applies is an alias map that returns unknown names unchanged, not a
/// sanitiser. Whether the API would in fact reject a dotted name has not
/// been observed live, and confirming it would mean spending the operator's
/// subscription; dot-free names cost nothing and make the question moot.
/// `everyRegisteredActionNameSatisfiesTheAnthropicToolNameRule`
/// (`StandardActionsTests`) holds the line for future actions.
///
/// `context` and `db` are `ToolCaller`s rather than `MCPClient`s, and
/// optional. The port is what makes an action testable without spawning a
/// Go binary (see `ToolCaller`); the optionality is what makes it testable
/// without any adapter at all — passing `nil` for one still registers
/// every action that needs it, and that action's handler throws
/// `StandardActionError.missingClient` instead of crashing on a forced
/// unwrap or silently returning something that looks like success.
///
/// The reply budgets the handlers pass — `MCPClient.readReplyTimeout` and
/// `MCPClient.mutationReplyTimeout` — stay on the concrete client on
/// purpose: they describe the real transport, not the call, and no test
/// needs to vary them.
public func registerStandardActions(
    into registry: ActionRegistry,
    context: (any ToolCaller)?,
    panes: PaneStore,
    db: (any ToolCaller)?,
    resumes: ResumeBroker,
    // Defaulted, unlike `resumes` above, so the ~30 existing call sites in
    // this module's test target — none of which exercise a provider
    // switch — keep compiling unchanged. The one production call site
    // (`WakilWiring.build`) always passes its own `providerSwitches`
    // explicitly, the same way it already does for `resumes`.
    providerSwitches: ProviderSwitchBroker = ProviderSwitchBroker(),
    // Defaulted for the identical reason `providerSwitches` above is: the
    // ~30 existing call sites in this module's test target register with
    // no layout at all and must keep compiling unchanged. `db_run_query`'s
    // handler treats a `nil` layout exactly as `queryTargetPane` documents
    // — the old `"db"` default, unchanged. The one production call site
    // (`WakilWiring.build`) always passes its own `layout` explicitly.
    layout: LayoutStore? = nil,
    // 2e-ii. Defaulted for the same reason as the two above: no test but the pin's own runs an
    // agent. Names the agent running in a project (and, when `environment` is given, in that
    // environment of it), or nil. `ctx_rename_project`, `ctx_remove_project`,
    // `ctx_rename_environment` and `ctx_remove_environment` ask it before touching a place an
    // agent is pinned to (Invariant 5). The one production call site passes the window's.
    agentIn: (@Sendable (_ project: String, _ environment: String?) async -> String?)? = nil,
    // Conversations 2 of 3. Defaulted for `providerSwitches`' reason: no existing call site
    // starts or switches a conversation. The one production call site (`WakilWiring.build`)
    // passes the broker the window drains.
    conversationRequests: ConversationBroker = ConversationBroker(),
    // Conversations 2 of 3, defaulted for the same reason: the window's live conversations,
    // every place's (nil) or one place's, which `session_list` lists beside Go's past sessions.
    // The one production call site passes `LiveConversationLookup`'s read.
    liveConversations: (@Sendable (Place?) async -> [LiveConversation])? = nil,
    // The organisation on screen, for an unpinned caller's `live` (the operator, `--dispatch`):
    // the one Go's past half answers for. Nil, or answering nil, lists no live conversation —
    // never every organisation's.
    liveOrganization: (@Sendable () async -> String?)? = nil
) async {
    // Every dispatch is homed in the canvas on screen when it began, unless its caller has one of
    // its own (`ActionRegistry.setScreenScope`): a db read, a git status or a page whose reply
    // lands after a switch writes where it was asked.
    registry.setScreenScope { await panes.activeScope }
    await registry.register(Action(
        name: "ctx_list_projects",
        description: "List projects in the active organization, with any misfiled or unreadable entries named.",
        kind: .read,
        audience: .agentReachable,
        schema: .object(["type": .string("object"), "properties": .object([:])]),
        handler: { _ in
            guard let context else {
                throw StandardActionError.missingClient(action: "ctx_list_projects", role: "context")
            }
            return try await callChecked(
                context, tool: "list_projects", arguments: .object([:]),
                action: "ctx_list_projects", timeout: MCPClient.readReplyTimeout)
        }
    ))

    // **The action `wakil-ctx` has shipped since Phase 1 and nothing in
    // `app/` ever called.** `ctx_set_environment` existed from 2a and takes
    // a free-string `name`, so the window could *switch* to an environment
    // it could not *enumerate* — which is why the only working control was a
    // raw `TextField` the operator typed a guess into, and why ⌘P listed
    // panes, projects, sessions and providers but never environments.
    // Invariant 8 puts the active environment permanently on screen while
    // the set it belongs to was unreadable; this is the missing half.
    //
    // `.read`, exactly like `ctx_list_projects` above: the names of a
    // project's environments and whether each is read-only leak nothing —
    // no host, no DSN, no credential. The DSN lives in the Keychain and
    // never travels with this listing (see `dsn-in-secret`).
    //
    // **What it returns, and what it does not.** The Go tool answers a flat
    // `map[string]bool` of name → read-only, and read-only there means
    // "none of this environment's databases is configured for writing", with
    // an environment holding no databases reporting `true` vacuously. It
    // carries NO count of databases or APIs. `ContextStates.dc.html` draws
    // rows reading "3 databases · 1 API" and this action cannot feed them;
    // the control therefore draws the name and the read-only fact, which is
    // what actually ships. Closing that gap is a Go-side change to a walked
    // Phase 1 server, which is a decision and not a detail — recorded rather
    // than taken here.
    await registry.register(Action(
        name: "ctx_list_environments",
        description: "List the active project's environments and whether each is read-only. "
            + "An environment reports read-only unless at least one of its databases is "
            + "configured for writing; one with no databases reports read-only vacuously.",
        kind: .read,
        audience: .agentReachable,
        schema: .object(["type": .string("object"), "properties": .object([:])]),
        handler: { _ in
            guard let context else {
                throw StandardActionError.missingClient(
                    action: "ctx_list_environments", role: "context")
            }
            return try await callChecked(
                context, tool: "list_environments", arguments: .object([:]),
                action: "ctx_list_environments", timeout: MCPClient.readReplyTimeout)
        }
    ))

    // Added by Phase 2b-vi Task 12, alongside `WindowModel.setProvider`
    // finally becoming reachable from the window at all — acceptance
    // found `session_set_provider` had no palette route to it, and
    // `providerPaletteItems()` needed a way to learn what the org even
    // HAS to offer as ⌘P rows. `wakil-ctx`'s `list_providers` (Task 12,
    // Go side) is that source: id, kind, and label only, never a
    // credential — see `ProviderSummary`'s own doc comment for why that
    // is structural rather than a promise this handler has to keep by
    // hand. `.read`, exactly like `ctx_list_projects` beside it: reading
    // the id/kind/label of every provider the org has leaks nothing an
    // agent could not already ask a human, and is not in
    // `operatorOnlyActions` — that set exists for the two actions that
    // actually MOVE the running account (`session_set_provider`) or its
    // next-launch default (`ctx_set_provider`), neither of which this
    // is.
    await registry.register(Action(
        name: "ctx_list_providers",
        description: "List the providers (accounts) registered in the active organization: "
            + "each one's id, kind, and label when it has one. Never a credential.",
        kind: .read,
        audience: .agentReachable,
        schema: .object(["type": .string("object"), "properties": .object([:])]),
        handler: { _ in
            guard let context else {
                throw StandardActionError.missingClient(action: "ctx_list_providers", role: "context")
            }
            return try await callChecked(
                context, tool: "list_providers", arguments: .object([:]),
                action: "ctx_list_providers", timeout: MCPClient.readReplyTimeout)
        }
    ))

    // **Never a silent no-op on refusal**, per spec §6. `wakil-ctx` refuses
    // to switch to a project filed under a different organisation than the
    // one currently active (`SetProjectChecked` in
    // `internal/wakilcore/resolve.go`) — organisations are a credential
    // boundary, so that refusal is Invariant 4 in the small. `callChecked`
    // is what turns it from an `isError: true` result that reads as success
    // into a thrown `StandardActionError.serverError` carrying the server's
    // own text. Verified against the real binary by
    // `ctxSetProjectRefusesAProjectFiledUnderAnotherOrg` below in
    // `StandardActionsTests`, which drives this action — spec §6 asks for
    // the refusal proved "through this new path", so the test dispatches
    // rather than calling the client directly.
    await registry.register(Action(
        name: "ctx_set_project",
        description: "Switch the active project (must belong to the active org).",
        kind: .control,
        audience: .operatorOnly,
        schema: nameParamSchema,
        handler: { params in
            guard let context else {
                throw StandardActionError.missingClient(action: "ctx_set_project", role: "context")
            }
            let name = try requireStringParam(params, "name", action: "ctx_set_project")
            return try await callChecked(
                context, tool: "set_project", arguments: .object(["name": .string(name)]),
                action: "ctx_set_project", timeout: MCPClient.readReplyTimeout)
        }
    ))

    await registry.register(Action(
        name: "ctx_set_environment",
        description: "Switch the active environment within the active project.",
        kind: .control,
        audience: .operatorOnly,
        schema: nameParamSchema,
        handler: { params in
            guard let context else {
                throw StandardActionError.missingClient(action: "ctx_set_environment", role: "context")
            }
            let name = try requireStringParam(params, "name", action: "ctx_set_environment")
            return try await callChecked(
                context, tool: "set_environment", arguments: .object(["name": .string(name)]),
                action: "ctx_set_environment", timeout: MCPClient.readReplyTimeout)
        },
        // The only action in Wakil that names a target environment. See
        // `writeGate`: this is what gates an agent switching *into*
        // production while leaving an operator's own switch free.
        targetEnvironmentParam: "name"
    ))

    // **No `targetEnvironmentParam`, for the same reason `ctx_set_project`
    // declares none.** A provider switch cannot elevate the active
    // environment — `active.json`'s Environment field is untouched by it
    // (`setActiveProvider` in `cmd/wakil-ctx/main.go` reads, sets only
    // `Provider`, and writes back) — so there is nothing here for
    // `writeGate` to catch.
    //
    // **This is registered directly, not parked through
    // `ProviderSwitchBroker`.** `session_set_provider` above must park
    // because no `WindowModel` exists yet when this function runs; this
    // action needs no `WindowModel` at all; it is a stateless write to
    // `wakil-ctx`'s own file, indistinguishable in kind from
    // `ctx_set_project` or `ctx_set_environment` immediately above it.
    await registry.register(Action(
        name: "ctx_set_provider",
        description: "Persist the operator's chosen provider (account) as the active "
            + "context's fourth axis, independent of the active project and environment. "
            + "This is bookkeeping only — it does not itself move a live session to another "
            + "account; `WindowModel.setProvider` dispatches this AFTER that swap has "
            + "already succeeded, so the choice survives past this window's lifetime.",
        kind: .control,
        audience: .operatorOnly,
        schema: nameParamSchema,
        handler: { params in
            guard let context else {
                throw StandardActionError.missingClient(action: "ctx_set_provider", role: "context")
            }
            let name = try requireStringParam(params, "name", action: "ctx_set_provider")
            return try await callChecked(
                context, tool: "set_provider", arguments: .object(["name": .string(name)]),
                action: "ctx_set_provider", timeout: MCPClient.readReplyTimeout)
        }
    ))

    // Added by Phase 2b-viii Task 13, alongside `create_org` and the two
    // `list_machine_providers` / `adopt_provider` pairs below — the org
    // plane's Go side (`wakil-ctx`) already exposed all four; this task
    // is only their Wakil registration. **All four are in
    // `operatorOnlyActions`** (`PermissionPrompt.swift`) — see that
    // constant's own doc comment for why the two list actions and the
    // two write actions are excluded for two DIFFERENT reasons rather
    // than one shared one.
    //
    // `.read`, exactly like `ctx_list_providers` above: `list_orgs`
    // (`cmd/wakil-ctx/main.go`) never returns a credential, only each
    // org's id, Jira site and account COUNT — never the accounts
    // themselves (see `OrgSummary`'s own doc comment on the Go side) — so
    // this is a read of the same shape as every other `ctx_list_*`
    // action here, not a database mutation and not a selection change.
    // It reaches with no active org set by design (`listOrgs` never calls
    // `CurrentOrg()`), which is exactly why it is operator-only rather
    // than merely unlisted: a session scoped to one org has no business
    // asking what every OTHER org on the machine is.
    await registry.register(Action(
        name: "ctx_list_orgs",
        description: "List every organisation registered on this machine: id, Jira site "
            + "when it has one, and how many accounts it holds. Never a credential. "
            + "Operator-only.",
        kind: .read,
        audience: .operatorOnly,
        schema: .object(["type": .string("object"), "properties": .object([:])]),
        handler: { _ in
            guard let context else {
                throw StandardActionError.missingClient(action: "ctx_list_orgs", role: "context")
            }
            return try await callChecked(
                context, tool: "list_orgs", arguments: .object([:]),
                action: "ctx_list_orgs", timeout: MCPClient.readReplyTimeout)
        }
    ))

    // **`.control`, not `.read` and not `.mutate`.** `create_org` writes
    // a new `org.json` under this machine's own `~/.wakil` tree
    // (`wakilcore.CreateOrg`) — it never touches a customer database, so
    // it is not the kind of write `.mutate` and the write gate exist to
    // catch. It is closer to the `ctx_` setters immediately above, which
    // are `.control` because they change Wakil's own state rather than
    // the outside world the gate protects — except a setter only
    // SELECTS among org/project/environment/provider values that already
    // exist, while this one MINTS a new organisation, i.e. a new
    // Invariant-4 credential boundary. That is the strong half of why it
    // is additionally in `operatorOnlyActions` even though `.control`
    // actions are ordinarily agent-reachable by default — see that
    // constant's own doc comment.
    await registry.register(Action(
        name: "ctx_create_org",
        description: "Create a new organisation. The display name and Jira site are both "
            + "optional; an organisation without a display name falls back to showing its id, "
            + "and one without a Jira site simply has no Jira scope. Refuses to overwrite an "
            + "existing organisation. Operator-only.",
        kind: .control,
        audience: .operatorOnly,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string")]),
                "displayName": .object(["type": .string("string")]),
                "jiraBase": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("id")]),
        ]),
        handler: { params in
            guard let context else {
                throw StandardActionError.missingClient(action: "ctx_create_org", role: "context")
            }
            let id = try requireStringParam(params, "id", action: "ctx_create_org")
            var arguments: [String: JSONValue] = ["id": .string(id)]
            if case .object(let obj) = params, case .string(let displayName)? = obj["displayName"] {
                arguments["displayName"] = .string(displayName)
            }
            if case .object(let obj) = params, case .string(let jiraBase)? = obj["jiraBase"] {
                arguments["jiraBase"] = .string(jiraBase)
            }
            return try await callChecked(
                context, tool: "create_org", arguments: .object(arguments),
                action: "ctx_create_org", timeout: MCPClient.readReplyTimeout)
        }
    ))

    // `.read`, for the identical reason `ctx_list_orgs` above is:
    // `list_machine_providers` (Go side) never returns a credential, only
    // (org, provider) pairs with a config dir — see `MachineProviderListing`
    // / `wakilcore.MachineProvider`'s own doc comments. It is reachable
    // with no active org set, same as `ctx_list_orgs`, and denied for the
    // same weaker reason: this is the deliberate, operator-only place
    // cross-org provider detail is exposed (`main.go`'s own comment on
    // `OrgSummary`), and a session scoped to one org has no business
    // enumerating every config dir on the machine.
    await registry.register(Action(
        name: "ctx_list_machine_providers",
        description: "List every account registered anywhere on this machine, as (org, "
            + "provider) pairs with the config dir and the organisation that homes it. "
            + "Never a credential. Operator-only.",
        kind: .read,
        audience: .operatorOnly,
        schema: .object(["type": .string("object"), "properties": .object([:])]),
        handler: { _ in
            guard let context else {
                throw StandardActionError.missingClient(
                    action: "ctx_list_machine_providers", role: "context")
            }
            return try await callChecked(
                context, tool: "list_machine_providers", arguments: .object([:]),
                action: "ctx_list_machine_providers", timeout: MCPClient.readReplyTimeout)
        }
    ))

    // 2e (#198). The settings pane's ONE read, and the only one it has:
    // the pane caches nothing at all, so this is called on open and on
    // every read rather than held. That beats a watcher this app has never
    // had and makes staleness structurally impossible — measured
    // affordable during the map.
    //
    // **`.read` and agent-reachable, which is the new asymmetry stated
    // out loud** (Decision 30): the agent may READ settings and drive
    // nothing on it. Every action that changes anything here — this
    // phase's three, and the organisation's three strings — is
    // operator-only; this one changes nothing and answers a question an
    // agent is entitled to ask, namely how this machine is configured.
    //
    // **It publishes no credential and structurally cannot.** A database's
    // REF travels — that is a Keychain entry name, and the operator's own
    // settings pane is where one is worth reading — and nothing on the
    // path from `wakilcore.ConfigTree` to here reads the Keychain at all.
    //
    // **One call rather than N+1.** Assembling the same tree from
    // `ctx_list_projects` plus one `ctx_list_environments` per project
    // would be a round trip per project to answer what one file walk
    // answers, would report nothing about a project that could not be
    // read, and would let the pane draw a tree assembled from several
    // different moments of disk.
    await registry.register(Action(
        name: "ctx_config_tree",
        description: "Read the active organisation's whole configuration, as the settings pane "
            + "draws it: the organisation's display name, Jira site and default provider; the "
            + "accounts it has registered; and every project with its roots, scopes and "
            + "environments, each environment carrying its databases and its API entry. Four "
            + "levels deep, because an ENVIRONMENT holds the databases and the API, not a "
            + "project. Providers sit beside the projects, not under one, because a binding is "
            + "(organisation, account id) and cannot nest. Projects that could not be read, and "
            + "those whose file declares another organisation, are NAMED rather than dropped — "
            + "so an empty projects list with a non-empty unreadable list means \"could not "
            + "look\", never \"there are none\". A database's Keychain entry name is reported; "
            + "no credential value ever is.",
        kind: .read,
        audience: .agentReachable,
        schema: .object(["type": .string("object"), "properties": .object([:])]),
        handler: { _ in
            try await readConfigTree(context)
        }
    ))

    // The same tree for a NAMED organisation, for the app's own launch read (a session launching
    // in an organisation other than the window's active one learns that organisation's
    // connections). **Operator-only**, because it is the one read that crosses the organisation
    // boundary (Invariant 4): the agent reads the active organisation's tree through
    // `ctx_config_tree` and nothing else's.
    await registry.register(Action(
        name: "ctx_config_tree_for",
        description: "Read one named organisation's whole configuration, as ctx_config_tree reads "
            + "the active one's. Operator-only.",
        kind: .read,
        audience: .operatorOnly,
        schema: .object([
            "type": .string("object"),
            "properties": .object(["id": .object(["type": .string("string")])]),
            "required": .array([.string("id")]),
        ]),
        handler: { params in
            guard let context else {
                throw StandardActionError.missingClient(action: "ctx_config_tree_for", role: "context")
            }
            guard case .object(let o) = params, case .string(let id)? = o["id"], !id.isEmpty else {
                throw StandardActionError.missingParam(action: "ctx_config_tree_for", param: "id")
            }
            return try await readConfigTree(context, organisation: id)
        }
    ))

    // 2e (#200). The settings pane's account table: every account on
    // this machine, each row carrying its credential's PRESENCE and its
    // sign-in's LIVENESS.
    //
    // **Operator-only, on `ctx_list_machine_providers`' own reasoning** —
    // the weaker of the two reasons in that set, stated rather than
    // inherited by association. It moves no boundary; what it does is
    // enumerate every account and config dir on the machine, which is not
    // something a session scoped to ONE organisation has any business
    // doing. This one adds a Keychain presence check per row, which makes
    // the objection no weaker.
    //
    // **The agent is not thereby blind to settings.** `ctx_config_tree`
    // is agent-reachable and answers the active organisation's own
    // accounts; what it does not answer is every OTHER organisation's,
    // which is exactly the line `ctx_list_machine_providers` already
    // draws.
    await registry.register(Action(
        name: "ctx_list_accounts",
        description: "Every account registered anywhere on this machine, as one flat table with "
            + "kind as a column. Each row carries the organisation holding the binding, the "
            + "account id, kind, label, config dir, the organisation that homes that directory, "
            + "and whether the binding is the active organisation's. Each also carries its "
            + "credential's Keychain entry NAME and whether an item exists at it — never the "
            + "value — plus that entry's modification date, from which the minted token's "
            + "365-day clock runs; and liveness, which describes the operator's SIGN-IN and not "
            + "the minted token, so a lapsed sign-in does not mean a broken session. "
            + "Operator-only.",
        kind: .read,
        audience: .operatorOnly,
        schema: .object(["type": .string("object"), "properties": .object([:])]),
        handler: { _ in
            guard let context else {
                throw StandardActionError.missingClient(action: "ctx_list_accounts", role: "context")
            }
            return try await callChecked(
                context, tool: "list_accounts", arguments: .object([:]),
                action: "ctx_list_accounts", timeout: MCPClient.readReplyTimeout)
        }
    ))

    // 2e (#202). **The first browser trip**, and it returns at once.
    //
    // **Two actions rather than one**, because every `ctx_*` action is a
    // thin proxy on a ten-second reply timeout while a browser login takes
    // minutes. This one derives the directory, hands the work to a
    // `ProviderLoginSession`, and returns what the pane needs to draw its
    // band; the session publishes the rest.
    //
    // **Operator-only, and this is the strongest case in the set.** It
    // opens a browser on the operator's machine and begins an
    // authentication as them. Nothing about it is a boundary the agent
    // could argue for being inside.
    //
    // **`.control`**: it writes no record and creates no credential —
    // nothing is recorded until #204's mint succeeds, which is what makes
    // today's orphaned bindings unreproducible by construction.
    await registry.register(Action(
        name: "ctx_provider_login",
        description: "Begin adding an account by signing in through the browser. Returns at "
            + "once with the derived config dir and how many browser trips the add will cost — "
            + "one when that directory already holds a live sign-in, two otherwise. The trip "
            + "itself runs on a session the pane watches, because a browser login takes minutes "
            + "and this reply does not wait for it. Nothing is recorded and no credential "
            + "exists when this returns. Operator-only: it opens a browser and authenticates as "
            + "the operator.",
        kind: .control,
        audience: .operatorOnly,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string")]),
                "kind": .object(["type": .string("string")]),
                "label": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("id")]),
        ]),
        handler: { params in
            guard let context else {
                throw StandardActionError.missingClient(
                    action: "ctx_provider_login", role: "context")
            }
            let id = try requireStringParam(params, "id", action: "ctx_provider_login")
            // Derived in Go, resolved ONCE there, and returned so that the
            // spawn and any later record use the same string. Deriving it
            // in Swift would be a second implementation of the rule whose
            // whole content is that there is one.
            let derived = try await callChecked(
                context, tool: "derive_config_dir", arguments: .object(["id": .string(id)]),
                action: "ctx_provider_login", timeout: MCPClient.readReplyTimeout)
            guard case .object(let object) = derived,
                  case .object(let structured)? = object["structuredContent"],
                  case .string(let configDir)? = structured["configDir"],
                  !configDir.isEmpty
            else {
                throw StandardActionError.serverError(
                    action: "ctx_provider_login",
                    message: "the config dir could not be derived for \(id)")
            }
            return .object(["id": .string(id), "configDir": .string(configDir)])
        }
    ))

    // 2e (#204). **The commit, and it comes AFTER the mint.**
    //
    // No `orgs[]` and no choosing: one record, for the organisation the
    // operator is standing in. Another organisation adopts the same
    // account later from its own pane, which is `ctx_adopt_provider` and
    // is a different gesture with a different cost.
    //
    // Go refuses unless a credential is already stored, which makes
    // today's orphaned bindings unreproducible by construction: no record
    // exists until a credential does. That is a CHECK rather than an
    // ordering convention a later caller could get wrong.
    //
    // **Operator-only**, for `ctx_adopt_provider`'s reason: it binds an
    // account into an organisation, which is Invariant 4's boundary.
    await registry.register(Action(
        name: "ctx_add_provider",
        description: "Write the binding for an account that has just been minted, for the "
            + "ACTIVE organisation and no other — there is no list of organisations and no "
            + "choosing. Refuses unless a credential is already stored for it: the record is "
            + "written after the credential, never before. Returns the new row with its "
            + "credential presence and its sign-in liveness. Operator-only.",
        kind: .control,
        audience: .operatorOnly,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string")]),
                "configDir": .object(["type": .string("string")]),
                "kind": .object(["type": .string("string")]),
                "label": .object(["type": .string("string")]),
                "claudePath": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("id"), .string("configDir")]),
        ]),
        handler: { params in
            guard let context else {
                throw StandardActionError.missingClient(action: "ctx_add_provider", role: "context")
            }
            let id = try requireStringParam(params, "id", action: "ctx_add_provider")
            // The config dir is REQUIRED rather than re-derived here. It
            // is the string the sign-in and the mint both used, resolved
            // once at the derivation — re-deriving it would be a second
            // computation of a value whose whole rule is that there is
            // one.
            let configDir = try requireStringParam(params, "configDir", action: "ctx_add_provider")
            var arguments: [String: JSONValue] = [
                "id": .string(id), "configDir": .string(configDir),
            ]
            // **`claudePath` too** (#259): Go refuses a claude-code binding
            // that records no executable, and this loop used to forward only
            // kind and label, so every account added through the pane was
            // refused with "no agent executable recorded". Found in the 2e
            // walk; no test reached this handler before.
            for key in ["kind", "label", "claudePath"] {
                if case .object(let obj) = params, case .string(let value)? = obj[key],
                   !value.isEmpty
                {
                    arguments[key] = .string(value)
                }
            }
            return try await callChecked(
                context, tool: "add_provider", arguments: .object(arguments),
                action: "ctx_add_provider", timeout: MCPClient.readReplyTimeout)
        }
    ))

    // 2e (#206). **An organisation unlinks a BINDING; it never removes a
    // provider** (Decision 32), and it never refuses.
    //
    // **Operator-only**, for the boundary family's reason: removing a
    // binding moves what an organisation can reach, which is Invariant 4's
    // own boundary — the mirror of `ctx_adopt_provider`.
    //
    // **`.control` and not `.mutate`**: it writes only this machine's
    // `~/.wakil` tree and its Keychain, never a customer database, so
    // `price` is never consulted and the gate's `.gate` branch is never
    // reached. What protects it instead is the pane-local confirmation —
    // one of exactly two in this phase — because a destructive action owes
    // one only where the gate supplies none.
    await registry.register(Action(
        name: "ctx_unlink_provider",
        description: "Remove one organisation's binding to an account. Deletes the record, that "
            + "organisation's Keychain item, and every stale pointer to the gone account. "
            + "Backfills any sharing record that was inheriting from this one first, so nothing "
            + "is stranded. Never refuses, and never touches the config directory. Reports "
            + "whether this was the last binding to the account, and always states that Wakil "
            + "cannot destroy the long-lived credential it created. Operator-only.",
        kind: .control,
        audience: .operatorOnly,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string")]),
                "org": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("id")]),
        ]),
        handler: { params in
            guard let context else {
                throw StandardActionError.missingClient(
                    action: "ctx_unlink_provider", role: "context")
            }
            let id = try requireStringParam(params, "id", action: "ctx_unlink_provider")
            var arguments: [String: JSONValue] = ["id": .string(id)]
            if case .object(let obj) = params, case .string(let org)? = obj["org"], !org.isEmpty {
                arguments["org"] = .string(org)
            }
            return try await callChecked(
                context, tool: "unlink_provider", arguments: .object(arguments),
                action: "ctx_unlink_provider", timeout: MCPClient.readReplyTimeout)
        }
    ))

    // 2e (#207). **The journal's redaction rule gets its first caller.**
    //
    // This is the ONE case in the phase where the agent would carry the
    // secret in its own parameters — which is the reason new to the
    // operator-only set: every other member objects to what the agent
    // could REACH, and this one objects to what it would carry. A provider
    // credential is minted and stored in Go precisely so nothing travels;
    // a DSN is typed by a human, so it must.
    //
    // `secretParams: ["dsn", "writeDsn"]` is therefore not decoration.
    // `JournalEntry.params` is written verbatim on every dispatch,
    // including refused and blocked ones, so without the mark this action
    // would put a database password in the audit log on the first attempt
    // — refused attempts included.
    //
    // **`.control`**: it writes one file under the operator's own tree and
    // one Keychain item, never a customer database. So `price` is never
    // consulted and the gate's `.gate` branch is never reached — which is
    // exactly why the DSN write owes a PANE-LOCAL confirmation, a
    // destructive action owing one only where the gate supplies none.
    await registry.register(Action(
        name: "db_set_dsn",
        description: "Store a database's connection string and record the database in an "
            + "environment. The connection string goes to the Keychain; the project file gets "
            + "the Keychain entry NAME and never the value. Read-modify-write from disk, so a "
            + "file edited by hand meanwhile keeps what this write does not touch. Granting "
            + "write access is a separate parameter needing its own second credential, because "
            + "write authority is proven to the database server rather than asserted. "
            + "Operator-only: this is the one action in the settings pane whose parameters "
            + "would carry a secret.",
        kind: .control,
        audience: .operatorOnly,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "projectPath": .object(["type": .string("string")]),
                "environment": .object(["type": .string("string")]),
                "name": .object(["type": .string("string")]),
                "driver": .object(["type": .string("string")]),
                "dsn": .object(["type": .string("string")]),
                "grantWrite": .object(["type": .string("boolean")]),
                "writeDsn": .object(["type": .string("string")]),
            ]),
            "required": .array([
                .string("projectPath"), .string("environment"), .string("name"),
                .string("driver"), .string("dsn"),
            ]),
        ]),
        handler: { params in
            guard let context else {
                throw StandardActionError.missingClient(action: "db_set_dsn", role: "context")
            }
            var arguments: [String: JSONValue] = [:]
            for key in ["projectPath", "environment", "name", "driver", "dsn"] {
                arguments[key] = .string(try requireStringParam(params, key, action: "db_set_dsn"))
            }
            if case .object(let obj) = params {
                if case .bool(true)? = obj["grantWrite"] {
                    arguments["grantWrite"] = .bool(true)
                }
                if case .string(let writeDsn)? = obj["writeDsn"], !writeDsn.isEmpty {
                    arguments["writeDsn"] = .string(writeDsn)
                }
            }
            return try await callChecked(
                context, tool: "set_database_dsn", arguments: .object(arguments),
                action: "db_set_dsn", timeout: MCPClient.readReplyTimeout)
        },
        // **The mark, and the whole reason #197 shipped.** Both
        // credentials are marked: a write credential is no less a secret
        // than a read one.
        secretParams: ["dsn", "writeDsn"]
    ))

    // 2e-iv. A database saved as its PARTS: host, port, database, user (or a path, for sqlite) go
    // to project.json, and only the password(s) go to the Keychain, in Go. **Both passwords are
    // secret-bearing**, for `db_set_dsn`'s reason. An empty password means "keep the stored one",
    // so an absent or empty key is simply not forwarded.
    await registry.register(Action(
        name: "db_set_connection",
        description: "Save a database as its parts (host, port, database, user, or a path for "
            + "sqlite) and record it in an environment. Only the password goes to the Keychain; "
            + "passwords are never returned. An empty password keeps the stored one. Granting "
            + "write access takes its own login (writeUser, writePassword). Operator-only: the "
            + "passwords are secrets the operator types.",
        kind: .control,
        audience: .operatorOnly,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "projectPath": .object(["type": .string("string")]),
                "environment": .object(["type": .string("string")]),
                "name": .object(["type": .string("string")]),
                "driver": .object(["type": .string("string")]),
                "host": .object(["type": .string("string")]),
                "port": .object(["type": .string("string")]),
                "database": .object(["type": .string("string")]),
                "user": .object(["type": .string("string")]),
                "path": .object(["type": .string("string")]),
                "password": .object(["type": .string("string")]),
                "grantWrite": .object(["type": .string("boolean")]),
                "writeUser": .object(["type": .string("string")]),
                "writePassword": .object(["type": .string("string")]),
            ]),
            "required": .array([
                .string("projectPath"), .string("environment"), .string("name"), .string("driver"),
            ]),
        ]),
        handler: { params in
            guard let context else {
                throw StandardActionError.missingClient(action: "db_set_connection", role: "context")
            }
            var arguments: [String: JSONValue] = [:]
            for key in ["projectPath", "environment", "name", "driver"] {
                arguments[key] = .string(try requireStringParam(params, key, action: "db_set_connection"))
            }
            if case .object(let obj) = params {
                for key in ["host", "port", "database", "user", "path", "password", "writeUser", "writePassword"] {
                    if case .string(let value)? = obj[key], !value.isEmpty {
                        arguments[key] = .string(value)
                    }
                }
                if case .bool(true)? = obj["grantWrite"] {
                    arguments["grantWrite"] = .bool(true)
                }
            }
            return try await callChecked(
                context, tool: "set_database_connection", arguments: .object(arguments),
                action: "db_set_connection", timeout: MCPClient.readReplyTimeout)
        },
        secretParams: ["password", "writePassword"]
    ))

    // 2e (#207). **Removing a database keeps its Keychain entry** —
    // *unreferenced* is a claim the registry has no standing to make, so
    // this is NOT on the pane-local confirmation list: nothing is
    // destroyed.
    await registry.register(Action(
        name: "db_remove_database",
        description: "Drop a database from an environment. Its Keychain entry is KEPT: the same "
            + "credential may be named by another project or a script this file cannot see, so "
            + "\"unreferenced\" is not something the registry can claim. Operator-only.",
        kind: .control,
        audience: .operatorOnly,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "projectPath": .object(["type": .string("string")]),
                "environment": .object(["type": .string("string")]),
                "name": .object(["type": .string("string")]),
            ]),
            "required": .array([
                .string("projectPath"), .string("environment"), .string("name"),
            ]),
        ]),
        handler: { params in
            guard let context else {
                throw StandardActionError.missingClient(
                    action: "db_remove_database", role: "context")
            }
            var arguments: [String: JSONValue] = [:]
            for key in ["projectPath", "environment", "name"] {
                arguments[key] = .string(
                    try requireStringParam(params, key, action: "db_remove_database"))
            }
            return try await callChecked(
                context, tool: "remove_database", arguments: .object(arguments),
                action: "db_remove_database", timeout: MCPClient.readReplyTimeout)
        }
    ))

    // 2e-iii. The API entries of an environment, and a database's rename and write revocation.
    // Each forwards its parameters as given to the `wakil-ctx` tool of the same shape; an absent
    // key means unchanged. Operator-only; `api_set_entry`'s token is the one secret.
    func str() -> JSONValue { .object(["type": .string("string")]) }
    func ctxForward(
        _ action: String, _ tool: String, description: String,
        required: [String], optional: [String], bools: [String] = [],
        secret: Set<String> = []
    ) async {
        var props: [String: JSONValue] = [:]
        for key in required + optional { props[key] = str() }
        for key in bools { props[key] = .object(["type": .string("boolean")]) }
        await registry.register(Action(
            name: action, description: description, kind: .control, audience: .operatorOnly,
            schema: .object([
                "type": .string("object"), "properties": .object(props),
                "required": .array(required.map { .string($0) }),
            ]),
            handler: { params in
                guard let context else {
                    throw StandardActionError.missingClient(action: action, role: "context")
                }
                var arguments: [String: JSONValue] = [:]
                for key in required {
                    arguments[key] = .string(try requireStringParam(params, key, action: action))
                }
                if case .object(let obj) = params {
                    for key in optional {
                        if case .string(let v)? = obj[key] { arguments[key] = .string(v) }
                    }
                    for key in bools {
                        if case .bool(let v)? = obj[key] { arguments[key] = .bool(v) }
                    }
                }
                return try await callChecked(
                    context, tool: tool, arguments: .object(arguments),
                    action: action, timeout: MCPClient.readReplyTimeout)
            },
            secretParams: secret))
    }
    await ctxForward(
        "api_set_entry", "set_api_entry",
        description: "Add or replace an API entry in an environment. The token goes to the "
            + "Keychain; the project file gets its entry NAME. Operator-only: the token is a secret.",
        required: ["projectPath", "environment", "name", "baseUrl"],
        optional: ["authHeader", "token"], secret: ["token"])
    await ctxForward(
        "api_update_entry", "update_api_entry",
        description: "Rename an API entry or change its base URL or auth header, or clear its "
            + "token. An absent key is unchanged. Operator-only.",
        required: ["projectPath", "environment", "name"],
        optional: ["newName", "baseUrl", "authHeader"], bools: ["clearToken"])
    await ctxForward(
        "api_remove_entry", "remove_api_entry",
        description: "Drop an API entry from an environment. Operator-only.",
        required: ["projectPath", "environment", "name"], optional: [])
    await ctxForward(
        "db_update_database", "update_database",
        description: "Rename a database in an environment, or revoke its write access. "
            + "An absent key is unchanged. Operator-only.",
        required: ["projectPath", "environment", "name"],
        optional: ["newName"], bools: ["revokeWrite"])

    // 2e-ii. Add, rename and remove a project and an environment from Settings: six
    // `.control`, `.operatorOnly` actions over `wakil-ctx`'s six writers, each a plain
    // forward like `db_remove_database` above. Operator-only because the agent's place is
    // fixed when its session starts (Invariant 5) and these move it. A refusal comes back as a
    // tool error carrying the Go `UserError` text whole, which `callChecked` surfaces unchanged.
    //
    // **The pin.** Renaming or removing a place an agent is running in would pull it out from
    // under the session, so those four ask `agentIn` first and refuse by name. The two
    // environment actions take an extra `project` (the registry name) for that check only —
    // the tool's own schema has no such param, so it is not forwarded. Creates are never
    // pinned: nothing an agent holds yet exists.

    // 3a-iii-a: an organisation's git accounts. Operator-only, like every Settings write
    // (Decision 30); the secrets travel through their own tools, never these.
    for (name, tool, keys, required, secrets) in [
        ("ctx_git_account_add", "git_account_add",
         ["id", "host", "provider", "method", "user", "keyPath", "username"], ["id", "host", "provider", "method"], [String]()),
        ("ctx_git_account_remove", "git_account_remove", ["id", "host"], ["id", "host"], []),
        ("ctx_git_host_suggestions", "git_host_suggestions", ["id"], ["id"], []),
        ("ctx_git_ssh_keys", "git_ssh_keys", ["id"], ["id"], []),
        ("ctx_git_key_generate", "git_key_generate", ["id", "host", "comment"], ["id", "host", "comment"], []),
        ("ctx_git_token_set", "git_token_set", ["id", "host", "token"], ["id", "host", "token"], ["token"]),
        ("ctx_git_key_passphrase_set", "git_key_passphrase_set", ["id", "host", "passphrase"], ["id", "host", "passphrase"], ["passphrase"]),
        ("ctx_git_account_test", "git_account_test", ["id", "host"], ["id", "host"], []),
        ("ctx_git_device_start", "git_device_start", ["id", "provider"], ["id", "provider"], []),
        ("ctx_git_device_poll", "git_device_poll", ["id", "provider", "host", "deviceCode", "apiAccess"], ["id", "provider", "host", "deviceCode"], []),
        ("ctx_git_api_access_token_set", "git_api_access_token_set", ["id", "host", "token"], ["id", "host", "token"], ["token"]),
        ("ctx_git_api_access_remove", "git_api_access_remove", ["id", "host"], ["id", "host"], []),
        ("ctx_git_api_access_test", "git_api_access_test", ["id", "host"], ["id", "host"], []),
        ("ctx_git_gh_logins", "git_gh_logins", ["id"], ["id"], []),
        ("ctx_git_gh_import", "git_gh_import", ["id", "host", "user"], ["id", "host", "user"], []),
        ("ctx_set_project_agent_instructions", "set_project_agent_instructions",
         ["projectPath", "general", "commits", "pullRequests", "branches", "messageWakes"], ["projectPath"], []),
    ] {
        await registry.register(Action(
            name: name,
            description: [
                "ctx_git_account_add": "Record an organisation's git account for one host (ssh, token or signin). Operator-only.",
                "ctx_git_account_remove": "Forget an organisation's git account for one host, with its secrets. Operator-only.",
                "ctx_git_host_suggestions": "The hosts an organisation's projects push to, most used first. Operator-only.",
                "ctx_git_ssh_keys": "The key pairs in ~/.ssh, by comment, and which need a passphrase. Operator-only.",
                "ctx_git_key_generate": "Generate an organisation's ssh key for one host; answers the public key. Operator-only.",
                "ctx_git_token_set": "Keep an organisation's token for one host in the Keychain. Operator-only.",
                "ctx_git_key_passphrase_set": "Keep the passphrase of an organisation's picked key in the Keychain. Operator-only.",
                "ctx_git_account_test": "Ask a host who an organisation's account there is. Operator-only.",
                "ctx_git_device_start": "Begin Sign in with a provider (device flow). Operator-only.",
                "ctx_git_device_poll": "Ask once whether a Sign in was approved. Operator-only.",
                "ctx_git_api_access_token_set": "Give an SSH GitHub account API access with an access token, kept in the Keychain. Operator-only.",
                "ctx_git_api_access_remove": "Drop an SSH GitHub account's API access; the account stays. Operator-only.",
                "ctx_git_api_access_test": "Ask GitHub who an SSH account's API access belongs to. Operator-only.",
                "ctx_git_gh_logins": "The GitHub CLI's logins. Operator-only.",
                "ctx_git_gh_import": "Use one of the GitHub CLI's logins as the organisation's account. Operator-only.",
                "ctx_set_project_agent_instructions": "Change one project's agent instructions. Operator-only.",
            ][name] ?? name,
            // The sheet's lists change nothing; the rest write the organisation or the Keychain.
            kind: ["ctx_git_host_suggestions", "ctx_git_ssh_keys", "ctx_git_gh_logins"].contains(name) ? .read : .control,
            audience: .operatorOnly,
            schema: .object([
                "type": .string("object"),
                // `apiAccess` (device poll) is the one switch among the strings.
                "properties": .object(Dictionary(uniqueKeysWithValues: keys.map {
                    // Workspaces piece 4: `messageWakes` is the one number (-1 clears the override).
                    ($0, JSONValue.object(["type": .string(
                        $0 == "apiAccess" ? "boolean" : $0 == "messageWakes" ? "integer" : "string")]))
                })),
                "required": .array(required.map { .string($0) }),
            ]),
            handler: { params in
                guard let context else { throw StandardActionError.missingClient(action: name, role: "context") }
                var arguments: [String: JSONValue] = [:]
                for key in required { arguments[key] = .string(try requireStringParam(params, key, action: name)) }
                for key in keys where arguments[key] == nil {
                    if case .object(let o) = params, case .string(let v)? = o[key] { arguments[key] = .string(v) }
                    if key == "apiAccess", case .object(let o) = params, case .bool(let b)? = o[key] { arguments[key] = .bool(b) }
                    if key == "messageWakes", case .object(let o) = params, case .integer(let n)? = o[key] {
                        arguments[key] = .integer(n)
                    }
                }
                return try await callChecked(
                    context, tool: tool, arguments: .object(arguments), action: name,
                    timeout: MCPClient.readReplyTimeout)
            },
            secretParams: Set(secrets)))
    }

    // Connections: an organisation's own MCP servers, their sign-ins and their Allow agent
    // switches. Operator-only like the git accounts above (Decision 30, Invariant 4): they choose
    // which account an organisation's agents reach a service as, and which of its tools run
    // unasked. The secrets travel in `ctx_connection_secrets_set`'s `values` and
    // `ctx_jira_token_set`'s `token`, marked so the journal redacts them. Params are forwarded as
    // given (some are objects, lists or a switch), each required one checked present.
    let str: JSONValue = .object(["type": .string("string")])
    let strings: JSONValue = .object(["type": .string("array"), "items": str])
    let stringMap: JSONValue = .object(["type": .string("object"), "additionalProperties": str])
    let flag: JSONValue = .object(["type": .string("boolean")])
    let named: [String: JSONValue] = ["id": str, "name": str]
    for (name, tool, description, properties, required, secrets) in [
        ("ctx_connection_catalog", "connection_catalog",
         "The ready-made connections an organisation can add. Operator-only.", [String: JSONValue](), [String](), [String]()),
        ("ctx_connection_add", "connection_add",
         "Add one of an organisation's own MCP servers behind Wakil's gate. Operator-only.",
         ["id": str, "kind": str, "name": str, "transport": str, "url": str, "command": str, "args": strings,
          "signIn": str, "values": stringMap], ["id", "kind"], []),
        ("ctx_connection_update", "connection_update",
         "Change a connection's name, address, command, arguments, non-secret values or recorded tool hints. Operator-only.",
         ["id": str, "name": str, "newName": str, "url": str, "command": str, "args": strings,
          "values": stringMap, "hints": stringMap], ["id", "name"], []),
        ("ctx_connection_remove", "connection_remove",
         "Forget an organisation's connection, with its Keychain item. Operator-only.", named, ["id", "name"], []),
        ("ctx_connection_secrets_set", "connection_secrets_set",
         "Keep a connection's secret values in the Keychain. Operator-only.",
         ["id": str, "name": str, "values": stringMap], ["id", "name", "values"], ["values"]),
        ("ctx_connection_allow_set", "connection_allow_set",
         "Switch one of a connection's tools on or off at the gate. Operator-only.",
         ["id": str, "name": str, "tool": str, "allow": flag], ["id", "name", "tool", "allow"], []),
        ("ctx_connection_signin_start", "connection_signin_start",
         "Begin a connection's browser sign-in; answers the page to open. Operator-only.", named, ["id", "name"], []),
        ("ctx_connection_signin_wait", "connection_signin_wait",
         "Wait for a connection's browser sign-in to finish; cancelling ends it. Operator-only.", named, ["id", "name"], []),
        ("ctx_connection_signout", "connection_signout",
         "Forget a connection's browser sign-in tokens. Operator-only.", named, ["id", "name"], []),
        ("ctx_jira_token_set", "jira_token_set",
         "Keep an organisation's Jira email and API token in the Keychain. Operator-only.",
         ["id": str, "email": str, "token": str], ["id", "email", "token"], ["token"]),
    ] {
        await registry.register(Action(
            name: name,
            description: description,
            kind: name == "ctx_connection_catalog" ? .read : .control,
            audience: .operatorOnly,
            schema: .object([
                "type": .string("object"),
                "properties": .object(properties),
                "required": .array(required.map { .string($0) }),
            ]),
            handler: { params in
                guard let context else { throw StandardActionError.missingClient(action: name, role: "context") }
                var given: [String: JSONValue] = [:]
                if case .object(let o) = params { given = o }
                for key in required where given[key] == nil || given[key] == .null {
                    throw StandardActionError.missingParam(action: name, param: key)
                }
                let arguments = given.filter { properties[$0.key] != nil }
                // A browser sign-in waits for the operator in the browser; Go ends it after ten
                // minutes, and a Cancel ends it sooner (the call's cancellation).
                let timeout = name == "ctx_connection_signin_wait" ? 11 * 60 : MCPClient.readReplyTimeout
                return try await callChecked(
                    context, tool: tool, arguments: .object(arguments), action: name, timeout: timeout)
            },
            secretParams: Set(secrets)))
    }

    await registry.register(Action(
        name: "ctx_create_project",
        description: "Add a project: create its file under a folder and register it. Operator-only.",
        kind: .control,
        audience: .operatorOnly,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "folder": .object(["type": .string("string")]),
                "name": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("folder"), .string("name")]),
        ]),
        handler: { params in
            guard let context else {
                throw StandardActionError.missingClient(
                    action: "ctx_create_project", role: "context")
            }
            var arguments: [String: JSONValue] = [:]
            for key in ["folder", "name"] {
                arguments[key] = .string(
                    try requireStringParam(params, key, action: "ctx_create_project"))
            }
            return try await callChecked(
                context, tool: "create_project", arguments: .object(arguments),
                action: "ctx_create_project", timeout: MCPClient.readReplyTimeout)
        }
    ))

    await registry.register(Action(
        name: "ctx_rename_project",
        description: "Rename a registered project. Refused while an agent is running in it. Operator-only.",
        kind: .control,
        audience: .operatorOnly,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "name": .object(["type": .string("string")]),
                "newName": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("name"), .string("newName")]),
        ]),
        handler: { params in
            guard let context else {
                throw StandardActionError.missingClient(
                    action: "ctx_rename_project", role: "context")
            }
            try await refuseIfAgentRuns(
                agentIn, project: try requireStringParam(params, "name", action: "ctx_rename_project"),
                environment: nil, action: "ctx_rename_project")
            var arguments: [String: JSONValue] = [:]
            for key in ["name", "newName"] {
                arguments[key] = .string(
                    try requireStringParam(params, key, action: "ctx_rename_project"))
            }
            return try await callChecked(
                context, tool: "rename_project", arguments: .object(arguments),
                action: "ctx_rename_project", timeout: MCPClient.readReplyTimeout)
        }
    ))

    await registry.register(Action(
        name: "ctx_remove_project",
        description: "Remove a project from the registry. Its folder is left alone. Refused while an agent is running in it. Operator-only.",
        kind: .control,
        audience: .operatorOnly,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "name": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("name")]),
        ]),
        handler: { params in
            guard let context else {
                throw StandardActionError.missingClient(
                    action: "ctx_remove_project", role: "context")
            }
            try await refuseIfAgentRuns(
                agentIn, project: try requireStringParam(params, "name", action: "ctx_remove_project"),
                environment: nil, action: "ctx_remove_project")
            var arguments: [String: JSONValue] = [:]
            for key in ["name"] {
                arguments[key] = .string(
                    try requireStringParam(params, key, action: "ctx_remove_project"))
            }
            return try await callChecked(
                context, tool: "remove_project", arguments: .object(arguments),
                action: "ctx_remove_project", timeout: MCPClient.readReplyTimeout)
        }
    ))

    await registry.register(Action(
        name: "ctx_create_environment",
        description: "Add an environment to a project; the tool picks the name. Operator-only.",
        kind: .control,
        audience: .operatorOnly,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "projectPath": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("projectPath")]),
        ]),
        handler: { params in
            guard let context else {
                throw StandardActionError.missingClient(
                    action: "ctx_create_environment", role: "context")
            }
            var arguments: [String: JSONValue] = [:]
            for key in ["projectPath"] {
                arguments[key] = .string(
                    try requireStringParam(params, key, action: "ctx_create_environment"))
            }
            return try await callChecked(
                context, tool: "create_environment", arguments: .object(arguments),
                action: "ctx_create_environment", timeout: MCPClient.readReplyTimeout)
        }
    ))

    await registry.register(Action(
        name: "ctx_rename_environment",
        description: "Rename an environment of a project. `project` is the registry name, used only to check that no agent is running there. Operator-only.",
        kind: .control,
        audience: .operatorOnly,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "project": .object(["type": .string("string")]),
                "projectPath": .object(["type": .string("string")]),
                "name": .object(["type": .string("string")]),
                "newName": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("project"), .string("projectPath"), .string("name"), .string("newName")]),
        ]),
        handler: { params in
            guard let context else {
                throw StandardActionError.missingClient(
                    action: "ctx_rename_environment", role: "context")
            }
            try await refuseIfAgentRuns(
                agentIn, project: try requireStringParam(params, "project", action: "ctx_rename_environment"),
                environment: try requireStringParam(params, "name", action: "ctx_rename_environment"),
                action: "ctx_rename_environment")
            var arguments: [String: JSONValue] = [:]
            for key in ["projectPath", "name", "newName"] {
                arguments[key] = .string(
                    try requireStringParam(params, key, action: "ctx_rename_environment"))
            }
            return try await callChecked(
                context, tool: "rename_environment", arguments: .object(arguments),
                action: "ctx_rename_environment", timeout: MCPClient.readReplyTimeout)
        }
    ))

    await registry.register(Action(
        name: "ctx_set_environment_production",
        description: "Declare whether an environment is production: `production` is yes, no, or name (let the environment's name decide). What counts as production sets the agent's price. Operator-only.",
        kind: .control,
        audience: .operatorOnly,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "project": .object(["type": .string("string")]),
                "projectPath": .object(["type": .string("string")]),
                "name": .object(["type": .string("string")]),
                "production": .object([
                    "type": .string("string"),
                    "enum": .array([.string("yes"), .string("no"), .string("name")]),
                ]),
            ]),
            "required": .array([.string("project"), .string("projectPath"), .string("name"), .string("production")]),
        ]),
        handler: { params in
            guard let context else {
                throw StandardActionError.missingClient(
                    action: "ctx_set_environment_production", role: "context")
            }
            var arguments: [String: JSONValue] = [:]
            for key in ["projectPath", "name", "production"] {
                arguments[key] = .string(
                    try requireStringParam(params, key, action: "ctx_set_environment_production"))
            }
            return try await callChecked(
                context, tool: "set_environment_production", arguments: .object(arguments),
                action: "ctx_set_environment_production", timeout: MCPClient.readReplyTimeout)
        }
    ))

    await registry.register(Action(
        name: "ctx_remove_environment",
        description: "Remove an environment of a project; its files are moved to the Trash. `project` is the registry name, used only to check that no agent is running there. Operator-only.",
        kind: .control,
        audience: .operatorOnly,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "project": .object(["type": .string("string")]),
                "projectPath": .object(["type": .string("string")]),
                "name": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("project"), .string("projectPath"), .string("name")]),
        ]),
        handler: { params in
            guard let context else {
                throw StandardActionError.missingClient(
                    action: "ctx_remove_environment", role: "context")
            }
            try await refuseIfAgentRuns(
                agentIn, project: try requireStringParam(params, "project", action: "ctx_remove_environment"),
                environment: try requireStringParam(params, "name", action: "ctx_remove_environment"),
                action: "ctx_remove_environment")
            var arguments: [String: JSONValue] = [:]
            for key in ["projectPath", "name"] {
                arguments[key] = .string(
                    try requireStringParam(params, key, action: "ctx_remove_environment"))
            }
            return try await callChecked(
                context, tool: "remove_environment", arguments: .object(arguments),
                action: "ctx_remove_environment", timeout: MCPClient.readReplyTimeout)
        }
    ))

    // 2e (#199). The settings pane's first WRITE, and the phase's
    // thinnest complete edit — built first for exactly that reason: it
    // proves the whole path (pane form, `.control` action, the existing Go
    // writer, disk, re-read) before anything credential-bearing travels
    // it. Four properties are established here and inherited by every
    // later settings edit.
    //
    // **`.control`, and there is no fourth `ActionKind`.** Nothing outside
    // Wakil is touched — this writes one file in `~/.wakil` — so `price`
    // is never consulted, no settings action reaches the gate's `.gate`
    // branch, and none parks in the broker. The write-price question
    // dissolves rather than being answered.
    //
    // **Operator-only**, which for this action is the strong case rather
    // than the weak one: `defaultProvider` names which account an
    // organisation's projects fall back to, so an agent that could set it
    // would be choosing which credentials Wakil reaches for — Invariant
    // 4's boundary, the same objection `ctx_set_provider` already carries
    // one level down.
    //
    // **The write is read-modify-write from disk at dispatch**, never a
    // flush of cached pane state, which is why every field is optional
    // here: an absent parameter means "leave what is on disk", and a
    // parameter present and empty means "clear it". A file hand-edited
    // while the pane was open therefore survives a save of a different
    // field. Editing config by hand is the product, not a workaround.
    //
    // **The refusal says the cause out loud.** A `defaultProvider` naming
    // no registered account is refused by `normaliseOrg` with the message
    // that already exists for it, rather than accepted and surfaced much
    // later as a "selected" provider that never existed — which reads as
    // something wrong with the account that IS running.
    await registry.register(Action(
        name: "ctx_update_org",
        description: "Change an organisation's display name, Jira site, default account, speech engine or "
            + "quick-tasks provider. "
            + "Read-modify-write: omit a field to leave what is on disk unchanged, or send an "
            + "empty string to clear it — so an edit made to the file by hand while a pane was "
            + "open survives a save of a different field. Refuses a Jira site that is not an "
            + "absolute https Atlassian URL, and a default account not already registered in "
            + "this organisation. Refuses an organisation that does not exist. Operator-only.",
        kind: .control,
        audience: .operatorOnly,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string")]),
                "displayName": .object(["type": .string("string")]),
                "jiraBase": .object(["type": .string("string")]),
                "defaultProvider": .object(["type": .string("string")]),
                "speechProvider": .object(["type": .string("string")]),
                "quickProvider": .object(["type": .string("string")]),
                "gitName": .object(["type": .string("string")]),
                "gitEmail": .object(["type": .string("string")]),
                "ghostText": .object(["type": .string("boolean")]),
                "fastPath": .object(["type": .string("boolean")]),
                "commitDrafts": .object(["type": .string("boolean")]),
                "conversationNames": .object(["type": .string("boolean")]),
                "pullStrategy": .object(["type": .string("string")]),
                "agentGeneral": .object(["type": .string("string")]),
                "gitCommitInstructions": .object(["type": .string("string")]),
                "gitPRInstructions": .object(["type": .string("string")]),
                "gitBranchInstructions": .object(["type": .string("string")]),
                // Workspaces piece 4: Agents woken by messages, 0–99; -1 clears it back to 8.
                "messageWakes": .object(["type": .string("integer")]),
            ]),
            "required": .array([.string("id")]),
        ]),
        handler: { params in
            guard let context else {
                throw StandardActionError.missingClient(action: "ctx_update_org", role: "context")
            }
            // Forwarded key by key rather than passed through wholesale,
            // so that only what the caller actually sent reaches Go. A
            // pass-through would turn every absent field into a present
            // one the moment anything upstream filled it in with a
            // default, which is the read-modify-write rule lost to a
            // convenience.
            guard case .object(let fields) = params, case .string(let id)? = fields["id"] else {
                throw StandardActionError.missingParam(action: "ctx_update_org", param: "id")
            }
            var arguments: [String: JSONValue] = ["id": .string(id)]
            for key in ["displayName", "jiraBase", "defaultProvider", "speechProvider", "quickProvider", "gitName", "gitEmail", "pullStrategy",
                        "agentGeneral", "gitCommitInstructions", "gitPRInstructions", "gitBranchInstructions"] {
                if let value = fields[key], case .string = value { arguments[key] = value }
            }
            for key in ["ghostText", "fastPath", "commitDrafts", "conversationNames"] {
                if let value = fields[key], case .bool = value { arguments[key] = value }
            }
            if let value = fields["messageWakes"], case .integer = value { arguments["messageWakes"] = value }
            return try await callChecked(
                context, tool: "update_org", arguments: .object(arguments),
                action: "ctx_update_org", timeout: MCPClient.readReplyTimeout)
        }
    ))

    // 3b-viii (Decision 42). A local model endpoint the operator runs: its URL. Operator-only on
    // `ctx_update_org`'s reason: which model reads the operator's code is theirs to choose. Go
    // resolves the active organisation itself, so no org travels; forwarded key by key, so only
    // id, label and baseURL reach Go (`serves` is ignored since 3b-ix: a local provider serves
    // every quick task).
    await registry.register(Action(
        name: "ctx_set_local_provider",
        description: "Create or change a local model endpoint for the active organisation: id, optional "
            + "label and baseURL (http or https); it serves every quick task. serves is ignored. "
            + "Wakil installs and starts nothing. Refuses a bad URL and an id already used by "
            + "another kind of account. Operator-only.",
        kind: .control,
        audience: .operatorOnly,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string")]),
                "label": .object(["type": .string("string")]),
                "baseURL": .object(["type": .string("string")]),
                "serves": .object([
                    "type": .string("array"), "items": .object(["type": .string("string")]),
                    "description": .string("ignored"),
                ]),
            ]),
            "required": .array([.string("id")]),
        ]),
        handler: { params in
            guard let context else {
                throw StandardActionError.missingClient(action: "ctx_set_local_provider", role: "context")
            }
            guard case .object(let fields) = params, case .string(let id)? = fields["id"] else {
                throw StandardActionError.missingParam(action: "ctx_set_local_provider", param: "id")
            }
            var arguments: [String: JSONValue] = ["id": .string(id)]
            if case .string? = fields["label"] { arguments["label"] = fields["label"] }
            if case .string? = fields["baseURL"] { arguments["baseURL"] = fields["baseURL"] }
            return try await callChecked(
                context, tool: "set_local_provider", arguments: .object(arguments),
                action: "ctx_set_local_provider", timeout: MCPClient.readReplyTimeout)
        }
    ))

    // 3b-v (Decision 38). The editor's settings: font size, wrap, autosave and showing ignored
    // files app-wide; tab size, tabs-or-spaces and the heavy folders per project. The read is the agent's too; the writes are operator-only
    // on Decision 30, kept — an agent that could change them could change how the operator's
    // files are saved without the operator seeing.
    await registry.register(Action(
        name: "ctx_editor_settings",
        description: "Read the editor settings in force: font size, word wrap, autosave (off, "
            + "pause or focus) and whether gitignored files are shown, from the operator's "
            + "app-wide settings; tab size, tabs-or-spaces and the heavy folders (.git is always "
            + "heavy besides) from the active project. Defaults fill anything unset. appError "
            + "carries settings.json's error, whole, when it cannot be read; the defaults are "
            + "then in force.",
        kind: .read,
        audience: .agentReachable,
        schema: .object(["type": .string("object"), "properties": .object([:])]),
        handler: { _ in
            guard let context else {
                throw StandardActionError.missingClient(action: "ctx_editor_settings", role: "context")
            }
            return try await callChecked(
                context, tool: "editor_settings", arguments: .object([:]),
                action: "ctx_editor_settings", timeout: MCPClient.readReplyTimeout)
        }
    ))

    await registry.register(Action(
        name: "ctx_set_editor_settings",
        description: "Change the app-wide editor settings: fontSize (9 to 24), wordWrap, autosave "
            + "(off, pause or focus), showIgnored (false hides gitignored files from the tree and ⌘P), "
            + "ghostText (false turns AI ghost-text off in every editor and query line), "
            + "inlineBlame (false hides who last changed the cursor's line at its end). "
            + "Read-modify-write: omit a field to leave it. Operator-only.",
        kind: .control,
        audience: .operatorOnly,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "fontSize": .object(["type": .string("integer")]),
                "wordWrap": .object(["type": .string("boolean")]),
                "autosave": .object(["type": .string("string"), "enum": .array([.string("off"), .string("pause"), .string("focus")])]),
                "showIgnored": .object(["type": .string("boolean")]),
                "ghostText": .object(["type": .string("boolean")]),
                "inlineBlame": .object(["type": .string("boolean")]),
            ]),
        ]),
        handler: { params in
            guard let context else {
                throw StandardActionError.missingClient(action: "ctx_set_editor_settings", role: "context")
            }
            // Key by key and type by type, for ctx_update_org's reason: only what the caller sent,
            // and only in the shape Go decodes, reaches Go.
            guard case .object(let fields) = params else {
                throw StandardActionError.missingParam(action: "ctx_set_editor_settings", param: "fontSize")
            }
            var arguments: [String: JSONValue] = [:]
            if case .integer? = fields["fontSize"] { arguments["fontSize"] = fields["fontSize"] }
            if case .bool? = fields["wordWrap"] { arguments["wordWrap"] = fields["wordWrap"] }
            if case .string? = fields["autosave"] { arguments["autosave"] = fields["autosave"] }
            if case .bool? = fields["showIgnored"] { arguments["showIgnored"] = fields["showIgnored"] }
            if case .bool? = fields["ghostText"] { arguments["ghostText"] = fields["ghostText"] }
            if case .bool? = fields["inlineBlame"] { arguments["inlineBlame"] = fields["inlineBlame"] }
            return try await callChecked(
                context, tool: "set_editor_settings", arguments: .object(arguments),
                action: "ctx_set_editor_settings", timeout: MCPClient.readReplyTimeout)
        }
    ))

    // 3c-i. The browser's app-wide setting, beside the editor's. Same shape as its editor twins:
    // the read is the agent's too, the write is operator-only on Decision 30.
    await registry.register(Action(
        name: "ctx_browser_settings",
        description: "Read the browser settings in force: the search engine the address bar uses "
            + "for words that are not a URL (google, duckduckgo, bing or kagi) and the start page a "
            + "new tab opens (empty is blank). Defaults fill anything unset. appError carries "
            + "settings.json's error, whole, when it cannot be read.",
        kind: .read,
        audience: .agentReachable,
        schema: .object(["type": .string("object"), "properties": .object([:])]),
        handler: { _ in
            guard let context else {
                throw StandardActionError.missingClient(action: "ctx_browser_settings", role: "context")
            }
            return try await callChecked(
                context, tool: "browser_settings", arguments: .object([:]),
                action: "ctx_browser_settings", timeout: MCPClient.readReplyTimeout)
        }
    ))

    // 3d-i (Ruling 17). The active organisation's open pull requests, read only. It takes no
    // organisation and no id, and the reply carries no credential.
    await registry.register(Action(
        name: "ctx_github_pull_requests",
        description: "Read the active organisation's open GitHub pull requests: those it wrote "
            + "(reason author) and those awaiting its review (reason review-requested), newest "
            + "update first. absent says why there is no list (no GitHub account, an SSH account, "
            + "no token kept). Read only; no credential is returned.",
        kind: .read,
        audience: .agentReachable,
        schema: .object(["type": .string("object"), "properties": .object([:])]),
        handler: { _ in
            guard let context else {
                throw StandardActionError.missingClient(action: "ctx_github_pull_requests", role: "context")
            }
            return try await callChecked(
                context, tool: "github_pull_requests", arguments: .object([:]),
                action: "ctx_github_pull_requests", timeout: MCPClient.readReplyTimeout)
        }
    ))

    await registry.register(Action(
        name: "ctx_set_browser_settings",
        description: "Change the app-wide browser settings: searchEngine (google, duckduckgo, bing "
            + "or kagi), startPage (an http or https URL, or empty for a blank page), and "
            + "searchSuggestions (true or false; off by default), tabs (horizontal or vertical), "
            + "nameGroups (true or false; on by default), and pictureInPicture "
            + "(true or false; on by default — a playing video floats when you leave its tab). "
            + "Read-modify-write: omit a field to leave it. Operator-only.",
        kind: .control,
        audience: .operatorOnly,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "searchEngine": .object([
                    "type": .string("string"),
                    "enum": .array([.string("google"), .string("duckduckgo"), .string("bing"), .string("kagi")]),
                ]),
                "startPage": .object(["type": .string("string")]),
                "searchSuggestions": .object(["type": .string("boolean")]),
                "tabs": .object([
                    "type": .string("string"),
                    "enum": .array([.string("horizontal"), .string("vertical")]),
                ]),
                "nameGroups": .object(["type": .string("boolean")]),
                "pictureInPicture": .object(["type": .string("boolean")]),
            ]),
        ]),
        handler: { params in
            guard let context else {
                throw StandardActionError.missingClient(action: "ctx_set_browser_settings", role: "context")
            }
            guard case .object(let fields) = params else {
                throw StandardActionError.missingParam(action: "ctx_set_browser_settings", param: "searchEngine")
            }
            var arguments: [String: JSONValue] = [:]
            if case .string? = fields["searchEngine"] { arguments["searchEngine"] = fields["searchEngine"] }
            if case .string? = fields["startPage"] { arguments["startPage"] = fields["startPage"] }
            if case .bool? = fields["searchSuggestions"] { arguments["searchSuggestions"] = fields["searchSuggestions"] }
            if case .string? = fields["tabs"] { arguments["tabs"] = fields["tabs"] }
            if case .bool? = fields["nameGroups"] { arguments["nameGroups"] = fields["nameGroups"] }
            if case .bool? = fields["pictureInPicture"] { arguments["pictureInPicture"] = fields["pictureInPicture"] }
            return try await callChecked(
                context, tool: "set_browser_settings", arguments: .object(arguments),
                action: "ctx_set_browser_settings", timeout: MCPClient.readReplyTimeout)
        }
    ))

    // The keymap's read and its two operator-only writes, beside the other settings tiers.
    await registerKeyboardActions(into: registry, context: context)

    await registry.register(Action(
        name: "ctx_set_project_editor_settings",
        description: "Change one project's editor settings in its project.json: tabSize (1 to 16) "
            + "and insertSpaces (false indents with tabs). A file's own indentation still wins; "
            + "these are the fallback. heavyFolders (the whole list of folder names; .git is always heavy). "
            + "Read-modify-write. Operator-only.",
        kind: .control,
        audience: .operatorOnly,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "projectPath": .object(["type": .string("string")]),
                "tabSize": .object(["type": .string("integer")]),
                "insertSpaces": .object(["type": .string("boolean")]),
                "heavyFolders": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
            ]),
            "required": .array([.string("projectPath")]),
        ]),
        handler: { params in
            guard let context else {
                throw StandardActionError.missingClient(action: "ctx_set_project_editor_settings", role: "context")
            }
            guard case .object(let fields) = params, case .string(let path)? = fields["projectPath"], !path.isEmpty else {
                throw StandardActionError.missingParam(action: "ctx_set_project_editor_settings", param: "projectPath")
            }
            var arguments: [String: JSONValue] = ["projectPath": .string(path)]
            if case .integer? = fields["tabSize"] { arguments["tabSize"] = fields["tabSize"] }
            if case .bool? = fields["insertSpaces"] { arguments["insertSpaces"] = fields["insertSpaces"] }
            // The whole list, and only when every entry is a string — Go's []string.
            if case .array(let items)? = fields["heavyFolders"],
               items.allSatisfy({ if case .string = $0 { true } else { false } }) {
                arguments["heavyFolders"] = .array(items)
            }
            return try await callChecked(
                context, tool: "set_project_editor_settings", arguments: .object(arguments),
                action: "ctx_set_project_editor_settings", timeout: MCPClient.readReplyTimeout)
        }
    ))

    // The project's Jira project (scopes.pm.projectKey): a project's Ticket tab and its ⌘P tickets
    // scope by it, so a project with none is set from Settings. Operator-only like every Settings
    // write (Decision 30).
    await registry.register(Action(
        name: "ctx_set_project_pm_key",
        description: "Set one project's Jira project key (INI) in its project.json; empty clears it. The "
            + "project's Ticket tab and ⌘P tickets show that Jira project's tickets and those on its repos. "
            + "Operator-only.",
        kind: .control,
        audience: .operatorOnly,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "projectPath": .object(["type": .string("string")]),
                "projectKey": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("projectPath"), .string("projectKey")]),
        ]),
        handler: { params in
            guard let context else {
                throw StandardActionError.missingClient(action: "ctx_set_project_pm_key", role: "context")
            }
            guard case .object(let fields) = params, case .string(let path)? = fields["projectPath"], !path.isEmpty else {
                throw StandardActionError.missingParam(action: "ctx_set_project_pm_key", param: "projectPath")
            }
            guard case .string(let key)? = fields["projectKey"] else {
                throw StandardActionError.missingParam(action: "ctx_set_project_pm_key", param: "projectKey")
            }
            return try await callChecked(
                context, tool: "set_project_pm_key",
                arguments: .object(["projectPath": .string(path), "projectKey": .string(key)]),
                action: "ctx_set_project_pm_key", timeout: MCPClient.readReplyTimeout)
        }
    ))

    // **`.control`, for the same reason `ctx_create_org` above is, and the
    // other half of the strong case.** `adopt_provider` (Go side) binds an
    // account that already exists on this machine into ANOTHER
    // organisation as a shared registration (`wakilcore.AddProvider` with
    // `Shared: true`) — it moves no credential (the config dir keeps its
    // existing headless home) but it does move which organisation's
    // boundary that account is reachable from, which is Invariant 4's
    // boundary exactly as much as minting a new org is. It writes only to
    // this machine's own `~/.wakil` tree, never a customer database, so
    // `.control` rather than `.mutate` — and it is in `operatorOnlyActions`
    // for the identical reason `ctx_create_org` is.
    await registry.register(Action(
        name: "ctx_adopt_provider",
        // **The sentence that went in 2e (#201) is "no credential is
        // created or copied."** It was true and it was the defect: a
        // shared account needs the same token stored twice, once per
        // organisation, because `ProviderTokenRef` carries no org — and a
        // binding without the second copy leaves the window refusing to
        // start against a Keychain item that does not exist. Three such
        // bindings are on this machine.
        description: "Bind an account that already exists on this machine into another "
            + "organisation, as a shared registration. Name fromOrg and fromId and the source "
            + "binding's credential is COPIED into the adopting organisation's own Keychain "
            + "item, so the binding can start a session immediately and no browser opens; omit "
            + "them to copy nothing. The resolved agent-binary path is recorded from the "
            + "source. The config dir keeps its existing headless home, unless nothing homes "
            + "it, in which case this binding becomes the home. A source holding no credential "
            + "does not undo the binding — the row is created and reports its credential "
            + "missing, which is repairable from that row. Operator-only.",
        kind: .control,
        audience: .operatorOnly,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "org": .object(["type": .string("string")]),
                "id": .object(["type": .string("string")]),
                "configDir": .object(["type": .string("string")]),
                "kind": .object(["type": .string("string")]),
                "label": .object(["type": .string("string")]),
                "fromOrg": .object(["type": .string("string")]),
                "fromId": .object(["type": .string("string")]),
            ]),
            "required": .array([
                .string("org"), .string("id"), .string("configDir"), .string("kind"),
            ]),
        ]),
        handler: { params in
            guard let context else {
                throw StandardActionError.missingClient(
                    action: "ctx_adopt_provider", role: "context")
            }
            let org = try requireStringParam(params, "org", action: "ctx_adopt_provider")
            let id = try requireStringParam(params, "id", action: "ctx_adopt_provider")
            let configDir = try requireStringParam(params, "configDir", action: "ctx_adopt_provider")
            let providerKind = try requireStringParam(params, "kind", action: "ctx_adopt_provider")
            var arguments: [String: JSONValue] = [
                "org": .string(org), "id": .string(id),
                "configDir": .string(configDir), "kind": .string(providerKind),
            ]
            // `label`, `fromOrg` and `fromId` are all optional and all
            // forwarded only when actually sent. `fromOrg`/`fromId` name
            // the binding whose credential is copied; absent means copy
            // nothing, which is the honest shape for a caller that has no
            // source rather than a silent default to some other
            // organisation's item.
            for key in ["label", "fromOrg", "fromId"] {
                if case .object(let obj) = params, case .string(let value)? = obj[key],
                   !value.isEmpty
                {
                    arguments[key] = .string(value)
                }
            }
            return try await callChecked(
                context, tool: "adopt_provider", arguments: .object(arguments),
                action: "ctx_adopt_provider", timeout: MCPClient.readReplyTimeout)
        }
    ))

    await registry.register(Action(
        name: "db_list_databases",
        // The writable sentence is load-bearing and is not padding. Until
        // 2026-09-10 this result published a readOnly field that decided
        // nothing while hiding the one that decides everything, and three
        // live agent turns in that day's acceptance run read it, concluded
        // a write was impossible, and declined without ever proposing the
        // mutation — so the write gate under test was never reached at all.
        // Issue #14. Saying what writable does and does not promise is how
        // an agent is stopped from inferring either half of it wrongly.
        description: "List the named database connections in the active environment. "
            + "Each entry carries its name, its driver, and writable: whether that "
            + "database is configured for writing at all. writable false means no "
            + "mutation can run against it by any route. writable true means only that "
            + "a mutation is possible, never that it is permitted — it still passes the "
            + "write gate and a human confirmation.",
        kind: .read,
        audience: .agentReachable,
        schema: .object(["type": .string("object"), "properties": .object([:])]),
        handler: { _ in
            guard let db else {
                throw StandardActionError.missingClient(action: "db_list_databases", role: "database")
            }
            return try await callChecked(
                db, tool: "list_databases", arguments: .object([:]),
                action: "db_list_databases", timeout: MCPClient.readReplyTimeout)
        }
    ))

    await registry.register(Action(
        name: "db_run_query",
        description: "Run a read-only query against a database in the active environment "
            + "and return rows. The rows are also drawn in a pane, so what is on screen "
            + "and what this returns are the same thing.\n"
            + "WHICH PANE: naming a pane means this belongs in that pane — it replaces "
            + "that pane's rows and becomes what that pane is showing. Omitting pane opens "
            + "a NEW pane. So: refining a question you already asked (adding a filter, "
            + "changing a range, sorting) names the pane the last result came back in — "
            + "every result tells you its pane id. Asking a DIFFERENT question names no "
            + "pane, and gets its own pane to sit beside the first.\n"
            + "PAGING: offset skips rows before the first one returned, so offset 500 with "
            + "limit 500 is the second page of the SAME query. Each page REPLACES what the "
            + "pane was showing — pages do not accumulate, so after paging through a table "
            + "the pane holds only the last page you asked for, not all of them. The "
            + "pageable field says whether this result can be paged at all — an EXPLAIN or "
            + "a SHOW cannot. At most 1000 rows come back per query (default 500; a limit "
            + "above 1000 falls back to 500).\n"
            + "Every query you run is drawn as it lands and the operator watches each one, "
            + "so finish with the query whose result should stay on screen.",
        kind: .read,
        audience: .agentReachable,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "query": .object(["type": .string("string")]),
                "database": .object(["type": .string("string")]),
                "limit": .object(["type": .string("number")]),
                "offset": .object([
                    "type": .string("number"),
                    "description": .string(
                        "Rows to skip before the first one returned. 0 is the first page."),
                ]),
                "pane": .object([
                    "type": .string("string"),
                    "description": .string(
                        "The id of an open pane — what \"pane_open\" returns and what "
                        + "\"read_layout\" lists, such as \"db-1\". Not the pane's title. "
                        + "Naming a pane that is not open is an error."),
                ]),
            ]),
            "required": .array([.string("query")]),
        ]),
        handler: { params in
            guard let db else {
                throw StandardActionError.missingClient(action: "db_run_query", role: "database")
            }
            let query = try requireStringParam(params, "query", action: "db_run_query")
            var arguments: [String: JSONValue] = ["query": .string(query)]
            let databaseParam = optionalString(params, "database")
            if let databaseParam { arguments["database"] = .string(databaseParam) }
            if case .object(let obj) = params, let limit = obj["limit"] { arguments["limit"] = limit }
            let explicitPaneParam = optionalString(params, "pane")

            // Checked BEFORE the query runs, not after — see
            // `requireOpenPane`'s doc comment for why.
            try await requireOpenPane(explicitPaneParam, action: "db_run_query", layout: layout)

            let limitParam = optionalIntParam(params, "limit")
            let offsetParam = optionalIntParam(params, "offset") ?? 0
            if offsetParam != 0 { arguments["offset"] = .number(Double(offsetParam)) }

            let sent = arguments
            let outcome = try await dbReadInFlight(paneId: explicitPaneParam, action: "db_run_query", panes: panes) {
                try await callChecked(
                    db, tool: "query", arguments: .object(sent),
                    action: "db_run_query", timeout: MCPClient.readReplyTimeout)
            }
            guard case .landed(let result) = outcome else { return dbCancelledResult(paneId: explicitPaneParam!) }
            // Beyond returning the raw result, feed it into the pane the
            // caller named — or, naming none, a new one. See
            // `queryTargetPane` and `resolvePane`: naming a pane means
            // "this belongs in that pane"; naming none means "this is a
            // different question", and a different question gets its own
            // pane. `db_run_query` stays `.read`: this reads the layout
            // (and, when it opens one, changes it), it never mutates
            // anything outside Wakil.
            guard let contents = dbPaneContents(from: result) else { return result }

            let (target, openedPane) = await resolvePane(
                explicit: explicitPaneParam, title: databaseParam, fallback: "db", layout: layout)

            // The subject this pane is now looking at, recorded so a later
            // refinement — a page, a sort, a relaunch — has something to
            // re-fetch from. `sort` is always `nil` here: sorting is
            // `pane_sort`'s job, and `refetchPane` is the only thing that
            // ever pushes a sort into a tool call — a second path that set
            // a pane's sort would be a second place it could disagree with
            // the first.
            let fetch = PaneFetch(
                query: .sql(database: databaseParam, raw: query),
                offset: offsetParam,
                pageSize: limitParam ?? PaneFetch.defaultPageSize,
                sort: [])
            await layout?.setFetch(fetch, id: target)
            await panes.setRows(
                paneId: target, columns: contents.columns,
                columnTypes: contents.columnTypes,
                columnTypesInferred: contents.columnTypesInferred,
                rows: contents.rows, millis: contents.millis,
                truncated: contents.truncated, pageable: contents.pageable,
                offset: offsetParam, sort: [], listsTables: contents.listsTables,
                editable: contents.editable)
            return annotatedWithPaneOutcome(result, paneId: target, opened: openedPane)
        }
    ))

    // Three actions, no view code: the schema browser IS the data surface,
    // pointed at metadata. `list_tables` is one row per table; `describe_table`
    // is one row per column; both have existed on `wakil-db` since Phase 1,
    // reachable only as raw `mcp__wakil-db__*` passthrough with no pointer
    // path and no journal entry. Each one is `.read`, never `.control` — it
    // reaches a database, which is exactly what `.control` is not for (see
    // this function's own doc comment on the five pane-content actions).
    await registry.register(Action(
        name: "db_list_tables",
        description: "List a database's tables or collections, drawn in a pane as rows — "
            + "one row per table, with its name and its kind. This is how you look at a "
            + "schema: there is no separate browser, the table list IS a result set. "
            + "Naming a pane draws into it; omitting pane opens a new one, the same rule "
            + "db_run_query follows. The list is always complete, so it is never paged.",
        kind: .read,
        audience: .agentReachable,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "database": .object(["type": .string("string")]),
                "pane": .object(["type": .string("string")]),
            ]),
        ]),
        handler: { params in
            guard let db else {
                throw StandardActionError.missingClient(action: "db_list_tables", role: "database")
            }
            let database = optionalString(params, "database")
            let explicit = optionalString(params, "pane")
            try await requireOpenPane(explicit, action: "db_list_tables", layout: layout)
            var arguments: [String: JSONValue] = [:]
            if let database { arguments["database"] = .string(database) }
            let sent = arguments
            let outcome = try await dbReadInFlight(paneId: explicit, action: "db_list_tables", panes: panes) {
                try await callChecked(
                    db, tool: "list_tables", arguments: .object(sent),
                    action: "db_list_tables", timeout: MCPClient.readReplyTimeout)
            }
            guard case .landed(let result) = outcome else { return dbCancelledResult(paneId: explicit!) }
            guard let contents = containerListPaneContents(from: result) else { return result }
            let (target, opened) = await resolvePane(
                explicit: explicit, title: database, fallback: "tables", layout: layout)
            await layout?.setFetch(PaneFetch(query: .tables(database: database)), id: target)
            await panes.setRows(
                paneId: target, columns: contents.columns, columnTypes: contents.columnTypes,
                columnTypesInferred: false, rows: contents.rows, millis: 0,
                truncated: false, pageable: false, offset: 0, sort: [],
                // `true`, not read off a `Rows` this call never receives
                // (`containerListPaneContents` reads a `list_tables`
                // result, never a `Rows`). `offersDrill` checks this field
                // BEFORE the subject, so this is what actually offers the
                // drill here — the subject's own `.tables` branch never
                // runs for this pane (final review, Minor 5); see
                // `PaneTable.listsTables`'s own doc comment for the fuller
                // explanation.
                listsTables: true, editable: nil)
            return annotatedWithPaneOutcome(result, paneId: target, opened: opened)
        }
    ))

    await registry.register(Action(
        name: "db_describe_table",
        description: "Describe one table or collection, drawn in a pane as rows — one row "
            + "per column, with its name, its declared type, and whether it is a key. "
            + "Naming a pane draws into it; omitting pane opens a new one.",
        kind: .read,
        audience: .agentReachable,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "database": .object(["type": .string("string")]),
                "table": .object(["type": .string("string")]),
                "pane": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("table")]),
        ]),
        handler: { params in
            guard let db else {
                throw StandardActionError.missingClient(action: "db_describe_table", role: "database")
            }
            let table = try requireStringParam(params, "table", action: "db_describe_table")
            let database = optionalString(params, "database")
            let explicit = optionalString(params, "pane")
            try await requireOpenPane(explicit, action: "db_describe_table", layout: layout)
            var arguments: [String: JSONValue] = ["name": .string(table)]
            if let database { arguments["database"] = .string(database) }
            let sent = arguments
            let outcome = try await dbReadInFlight(paneId: explicit, action: "db_describe_table", panes: panes) {
                try await callChecked(
                    db, tool: "describe_table", arguments: .object(sent),
                    action: "db_describe_table", timeout: MCPClient.readReplyTimeout)
            }
            guard case .landed(let result) = outcome else { return dbCancelledResult(paneId: explicit!) }
            guard let contents = schemaPaneContents(from: result) else { return result }
            let (target, opened) = await resolvePane(
                explicit: explicit, title: table, fallback: table, layout: layout)
            await layout?.setFetch(
                PaneFetch(query: .columns(database: database, table: table)), id: target)
            await panes.setRows(
                paneId: target, columns: contents.columns, columnTypes: contents.columnTypes,
                columnTypesInferred: false, rows: contents.rows, millis: 0,
                truncated: false, pageable: false, offset: 0, sort: [],
                // `.columns` offers its drill through the subject too
                // (`offersDrill`), against the pane's own table — not
                // through this flag, which stays false here.
                listsTables: false, editable: nil)
            return annotatedWithPaneOutcome(result, paneId: target, opened: opened)
        }
    ))

    await registry.register(Action(
        name: "db_read_table",
        description: "Draw every row of one table or collection in a pane, without writing "
            + "a query. Prefer this over db_run_query with \"SELECT * FROM x\": the driver "
            + "renders the read for its own dialect, which is the only form that also works "
            + "against Mongo, where there is no SQL. It pages like any query — this call "
            + "itself takes no sort, but the pane it draws into can still be sorted "
            + "afterwards with pane_sort, the same as any other pageable pane. "
            + "Naming a pane draws into it; omitting pane opens a new one.",
        kind: .read,
        audience: .agentReachable,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "database": .object(["type": .string("string")]),
                "table": .object(["type": .string("string")]),
                "limit": .object(["type": .string("number")]),
                "offset": .object(["type": .string("number")]),
                "pane": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("table")]),
        ]),
        handler: { params in
            guard let db else {
                throw StandardActionError.missingClient(action: "db_read_table", role: "database")
            }
            let table = try requireStringParam(params, "table", action: "db_read_table")
            let database = optionalString(params, "database")
            let explicit = optionalString(params, "pane")
            try await requireOpenPane(explicit, action: "db_read_table", layout: layout)
            let offset = optionalIntParam(params, "offset") ?? 0
            let limit = optionalIntParam(params, "limit") ?? PaneFetch.defaultPageSize
            var arguments: [String: JSONValue] = [
                "name": .string(table),
                "limit": .number(Double(limit)),
                "offset": .number(Double(offset)),
            ]
            if let database { arguments["database"] = .string(database) }
            let sent = arguments
            let outcome = try await dbReadInFlight(paneId: explicit, action: "db_read_table", panes: panes) {
                try await callChecked(
                    db, tool: "read_table", arguments: .object(sent),
                    action: "db_read_table", timeout: MCPClient.readReplyTimeout)
            }
            guard case .landed(let result) = outcome else { return dbCancelledResult(paneId: explicit!) }
            guard let contents = dbPaneContents(from: result) else { return result }
            let (target, opened) = await resolvePane(
                explicit: explicit, title: table, fallback: table, layout: layout)
            await layout?.setFetch(
                PaneFetch(query: .table(database: database, name: table),
                          offset: offset, pageSize: limit),
                id: target)
            await panes.setRows(
                paneId: target, columns: contents.columns, columnTypes: contents.columnTypes,
                columnTypesInferred: contents.columnTypesInferred, rows: contents.rows,
                millis: contents.millis, truncated: contents.truncated,
                pageable: contents.pageable, offset: offset, sort: [],
                listsTables: contents.listsTables, editable: contents.editable)
            return annotatedWithPaneOutcome(result, paneId: target, opened: opened)
        }
    ))

    // **One re-fetch path, four callers.** Paging, sorting a truncated
    // result, relaunch and the query line's plain Return all mean "run
    // this pane's subject again" — see `refetchPane`'s own doc comment for
    // why that mapping has exactly one home. `db_refetch` and `db_page`
    // are the two of those four callers reachable as their own actions;
    // `pane_sort`'s re-query branch and the window's relaunch restore call
    // `refetchPane` directly, with no action of their own.
    await registry.register(Action(
        name: "db_refetch",
        description: "Run a pane's own query again and redraw it, at whatever page and "
            + "sort it is already on. Use it after a mutation to see the change, or when "
            + "a result may have gone stale. The pane must already be showing something.",
        kind: .read,
        audience: .agentReachable,
        schema: .object([
            "type": .string("object"),
            "properties": .object(["pane": .object(["type": .string("string")])]),
            "required": .array([.string("pane")]),
        ]),
        handler: { params in
            guard let db else {
                throw StandardActionError.missingClient(action: "db_refetch", role: "database")
            }
            let paneId = try requireStringParam(params, "pane", action: "db_refetch")
            try await requireOpenPane(paneId, action: "db_refetch", layout: layout)
            guard let fetch = await layout?.fetch(id: paneId) else {
                throw StandardActionError.paneHasNoQuery(action: "db_refetch", pane: paneId)
            }
            return try await refetchPane(paneId: paneId, fetch: fetch, db: db, panes: panes)
        }
    ))

    await registry.register(Action(
        name: "db_cancel",
        description: "Cancel the read running on a db pane, as the operator's Cancel does. "
            + "The query is stopped on the database too. The rows that were on screen stay, and "
            + "read_pane's cancelledAfterMs says how long it ran. While a read runs, read_pane's "
            + "running is true and a second read on that pane is refused. With nothing running "
            + "it is refused. Writes (db_run_mutation) are never cancellable.",
        // `.control`: it ends a read Wakil started; it changes nothing outside Wakil and is
        // never priced by the gate.
        kind: .control,
        audience: .agentReachable,
        schema: .object([
            "type": .string("object"),
            "properties": .object(["pane": .object(["type": .string("string")])]),
            "required": .array([.string("pane")]),
        ]),
        handler: { params in
            let action = "db_cancel"
            let paneId = try requireStringParam(params, "pane", action: action)
            try await requireOpenPane(paneId, action: action, layout: layout)
            guard await panes.cancelDBRead(paneId: paneId) else {
                throw StandardActionError.nothingInFlight(action: action, pane: paneId)
            }
            return .object(["pane": .string(paneId)])
        }
    ))

    await registry.register(Action(
        name: "db_page",
        description: "Move a pane to another page of its own query and redraw it. "
            + "to is \"next\", \"previous\", \"first\", or a zero-based page number. "
            + "This re-runs the query at a new offset — it is not a scroll, and the rows "
            + "that arrive replace the ones that were there. A pane whose result is not "
            + "pageable (an EXPLAIN, a SHOW, a table list) cannot be paged.",
        kind: .read,
        audience: .agentReachable,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "pane": .object(["type": .string("string")]),
                "to": .object([
                    "type": .string("string"),
                    "description": .string("\"next\", \"previous\", \"first\", or a page number"),
                ]),
            ]),
            "required": .array([.string("pane"), .string("to")]),
        ]),
        handler: { params in
            guard let db else {
                throw StandardActionError.missingClient(action: "db_page", role: "database")
            }
            let paneId = try requireStringParam(params, "pane", action: "db_page")
            let to = try requireStringParam(params, "to", action: "db_page")
            try await requireOpenPane(paneId, action: "db_page", layout: layout)
            guard let current = await layout?.fetch(id: paneId) else {
                throw StandardActionError.paneHasNoQuery(action: "db_page", pane: paneId)
            }
            // RULING R6: refused before the offset moves, not after. A pane
            // whose current result is not pageable (a table list, an
            // EXPLAIN, a SHOW) has no second page — `current.page(to:)`
            // would still compute one and `setFetch` would still record
            // it, leaving `Pane.fetch.offset` reporting a page the pane
            // was never shown. See `StandardActionError.paneNotPageable`'s
            // own doc comment for the fuller argument.
            guard await panes.pageable(paneId: paneId) else {
                throw StandardActionError.paneNotPageable(action: "db_page", pane: paneId)
            }
            // Refused rather than defaulted, the rule `pane_sort`'s
            // direction already follows: reading "sideways" as "next"
            // would page the wrong way and tell nobody.
            let destination: PaneFetch.Page
            switch to {
            case "next": destination = .next
            case "previous": destination = .previous
            case "first": destination = .first
            default:
                // **`safeInt` is the bound, not a second one written here**
                // (final review, Critical 2). A page number arrives on this
                // action as a STRING, so the parse is `Int(to)` — but the
                // range an externally supplied number may occupy has one
                // home in this codebase, and `safeInt`'s own doc comment
                // records this very crash class ("verified: SIGTRAP, exit
                // 133"). `to: "20000000000000000"` was 2e16 * 500 and took
                // the process down; it is refused here as the mistake in
                // the request that it is, while `PaneFetch.clampedOffset`
                // bounds the arithmetic itself so no OTHER caller can reach
                // the trap by another route.
                guard let parsed = Int(to), let n = safeInt(Double(parsed)), n >= 0 else {
                    throw LayoutActionError.badParam(action: "db_page", param: "to", value: to)
                }
                destination = .number(n)
            }
            // **The re-fetch first, the commit after** (final review,
            // Important 6). `setFetch` used to run before `refetchPane`, so
            // a re-fetch that failed — a timeout, a restarted server — left
            // `Pane.fetch` on the new page while `PaneStore` still held
            // (and the footer still honestly reported) the old one. The
            // next `›` then moved a page from THERE and silently skipped
            // everything in between. `next` is still bound exactly once, so
            // the fetch that ran and the fetch that is recorded remain one
            // value rather than two computed the same way.
            let next = current.page(to: destination)
            let result = try await refetchPane(
                paneId: paneId, fetch: next, db: db, panes: panes, action: "db_page")
            // A cancelled (or dropped) read showed nothing new: the fetch stays where the pane is.
            if dbResultWasCancelled(result) { return result }
            await layout?.setFetch(next, id: paneId)
            return result
        }
    ))

    // **Moved here from `PaneContentActions.swift` (Task 12) and re-kinded
    // from `.control` to `.read`.** Spec §7: a pane that can re-query
    // re-queries. Sorting an incomplete result now reaches a database, and
    // `.control` is for state that never leaves Wakil — that is exactly the
    // distinction `ActionKind`'s own doc comment draws, and it is why
    // 2c-i's five remaining pane-content actions are `.control` and this
    // one is not. An action has one kind, so `pane_sort` takes the kind of
    // the strongest thing it can do. It moves beside the other database
    // actions for the same reason: it needs the database client, and
    // `registerPaneContentActions` has none.
    //
    // The rule, from spec §7 as the probe corrected it:
    //   - complete (`!truncated`, `offset == 0`): `PaneStore.reorder` —
    //     client-side, no round trip, and the correct answer rather than a
    //     shortcut, because every matching row is already in hand.
    //   - incomplete (truncated OR a page past the first):
    //     `Pane.fetch.sorted(by:)` then `refetchPane` at offset 0 — a
    //     re-query comes back at page ONE, because sorting page three and
    //     staying on page three would show rows 1,001-1,500 of a
    //     different ordering, the same class of lie the whole rule exists
    //     against.
    await registry.register(Action(
        name: "pane_sort",
        description: "Sort a pane by a column. A pane's sort is an ordered LIST of terms, "
            + "index 0 the primary key and each later term only breaking ties among rows "
            + "already equal on every earlier one — never a single column (D5): naming a "
            + "column not already in the list APPENDS it as a new, lowest-precedence "
            + "tie-breaker, leaving the existing terms and their order untouched; naming a "
            + "column already in the list flips its direction IN PLACE, at the precedence it "
            + "already has, rather than moving it. direction is \"asc\", \"desc\", or \"drop\" "
            + "to remove just that column's own term and leave every other sorted column in "
            + "its own place. Omit column entirely to remove every term.\n"
            + "A pane that can re-query RE-QUERIES: if the rows on screen are only part of "
            + "what matched — truncated, or a later page — this re-runs the pane's query "
            + "with an ORDER BY and comes back at page one, so what you see is the first "
            + "page of the real ordering rather than a re-shuffle of the rows you had. If "
            + "the whole result is already in hand, it is ordered in place with no round "
            + "trip, which is the same answer the engine would give.",
        kind: .read,
        audience: .agentReachable,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "pane": .object(["type": .string("string")]),
                "column": .object(["type": .string("string")]),
                "direction": .object([
                    "type": .string("string"),
                    "enum": .array([.string("asc"), .string("desc"), .string("drop")]),
                ]),
            ]),
            "required": .array([.string("pane")]),
        ]),
        handler: { params in
            let paneId = try requireStringParam(params, "pane", action: "pane_sort")
            try await requireOpenPane(paneId, action: "pane_sort", layout: layout)
            // Refused under a read in flight, before anything changes (Rule 5; final review,
            // Minor 5): a local re-sort recorded now would be reverted when that read lands.
            if await panes.dbReadRunning(paneId: paneId) {
                throw StandardActionError.readInFlight(action: "pane_sort", pane: paneId)
            }

            // Three requests, not two (fix round 2, Task 15). The walked
            // failure: the only removal this action could express was
            // "no column at all", which clears the WHOLE precedence
            // list — correct for that request, and the only one there
            // was, until a secondary column could stay a secondary
            // column across its own clicks (fix round 1). Once it could,
            // its OWN cycle needed a way to end in "gone" without taking
            // every other sorted column down with it: sort by `kind`,
            // then `id`, drop `id` — `kind` must still be there.
            enum SortRequest {
                case set(PaneSort)
                case drop(column: String)
                case clearAll
            }
            let request: SortRequest
            if let column = optionalString(params, "column") {
                let raw = optionalString(params, "direction") ?? "asc"
                if raw == "drop" {
                    request = .drop(column: column)
                } else {
                    // Refused rather than defaulted: silently reading
                    // "sideways" as ascending would sort the wrong way
                    // round and tell nobody.
                    guard let direction = PaneSortDirection(rawValue: raw) else {
                        throw LayoutActionError.badParam(
                            action: "pane_sort", param: "direction", value: raw)
                    }
                    request = .set(PaneSort(column: column, direction: direction))
                }
            } else {
                request = .clearAll
            }

            // **`pageable` is consulted before the sort is written
            // anywhere** (final review, Important 3). `db_page` got that
            // guard as RULING R6; this is the other consumer of the same
            // fact and had none, so a header click on a truncated
            // `SHOW VARIABLES` stored a sort, had the re-fetch refused, and
            // left the pane holding a sort no later `db_refetch` could ever
            // satisfy. `sortCanBeRecorded(on:pageable:)` is the decision,
            // and it lives on values where a test can reach it.
            let current = await layout?.fetch(id: paneId)
            let pageable = await panes.pageable(paneId: paneId)
            // **Built from the sort the pane actually HAS, not from
            // `current.sort`** (final review, Minor 6). A non-pageable
            // pane's `fetch.sort` is never written — `next` is `nil` for
            // it, below, so `setFetch` is never called — so building the
            // next candidate onto `current.sort` meant building onto the
            // SAME never-updated list on every click: sort by
            // `Variable_name`, then by `Value`, and `Variable_name`'s term
            // was gone, because the second click's `candidate` started
            // from `[]` again rather than from what the first click had
            // already recorded. `PaneStore.sort(paneId:)` is that record —
            // written by `reorder` on every call, recordable or not — so
            // starting from it instead means the candidate always builds
            // on what the pane is actually showing.
            let displayed = await panes.sort(paneId: paneId)
            // `candidate` is computed once, on `PaneFetch`'s own pure
            // methods, whether or not the sort turns out to be
            // recordable — so the refine/drop/clear-all logic lives in
            // exactly one place (`PaneFetch.sorted(by:)`,
            // `.sorted(by:descending:)`, `.removingSort(column:)`)
            // rather than being re-derived here for the unrecordable
            // fallback below. `next` is still bound exactly once — fix
            // round 1 caught a first draft that called `current.sorted`
            // a second time to build the re-query's `fetch:`, which is
            // the "two values computed the same way" trap this shape
            // avoids: one binding, read twice, cannot diverge from
            // itself.
            let candidate = current.map { fetch -> PaneFetch in
                var base = fetch
                base.sort = displayed
                switch request {
                case .set(let term): return base.sorted(by: term)
                case .drop(let column): return base.removingSort(column: column)
                case .clearAll: return base.sorted(by: nil)
                }
            }
            let recordable = current.map { sortCanBeRecorded(on: $0.query, pageable: pageable) }
                ?? false
            let next = recordable ? candidate : nil

            // Spec §7, as the probe corrected it. The rows on screen are a
            // subset when they were truncated OR when this is not the
            // first page — and sorting a subset locally is the dishonesty
            // §8 names. Everything else is sorted where it stands, because
            // when every matching row is in hand that IS the engine's
            // answer.
            //
            // An unpageable result never re-queries, whatever else is true
            // of it: there is no statement Wakil could send that would come
            // back sorted, so sorting what is in hand is not a shortcut
            // here, it is the only answer there is — and the footer already
            // admits the subset, because such a result is truncated.
            let incomplete = await panes.resultIsIncomplete(paneId: paneId)
            guard incomplete, pageable, let next, let db else {
                if let next { await layout?.setFetch(next, id: paneId) }
                // `next.sort` is already the refined/dropped/cleared
                // precedence list when the sort could be recorded;
                // `candidate?.sort` is the exact same computation, run
                // one branch earlier, for an unpageable result whose
                // SUBJECT cannot carry it — the pane's rows are still
                // reordered locally, so the request has to be honoured
                // there even though it is never written to `fetch.sort`.
                let sortTerms = next?.sort ?? candidate?.sort ?? []
                await panes.reorder(paneId: paneId, sort: sortTerms)
                return .object([
                    "pane": .string(paneId),
                    "sorted": .bool(!sortTerms.isEmpty),
                    "requeried": .bool(false),
                ])
            }
            // Committed after the re-query came back, for the reason
            // `db_page` commits after its own (Important 6): a sort written
            // ahead of a re-fetch that then failed would leave the pane
            // claiming an ordering it was never shown.
            let result = try await refetchPane(
                paneId: paneId, fetch: next, db: db, panes: panes, action: "pane_sort")
            // Same rule as `db_page`: nothing re-queried, so neither the sort nor `requeried` is recorded.
            if dbResultWasCancelled(result) { return result }
            await layout?.setFetch(next, id: paneId)
            guard case .object(var obj) = result else { return result }
            obj["requeried"] = .bool(true)
            return .object(obj)
        }
    ))

    await registry.register(Action(
        name: "db_classify_statement",
        description: "Say whether a statement is a read, a mutation, or neither, WITHOUT "
            + "running it. kind is \"read\", \"mutation\" or \"neither\"; for \"neither\", "
            + "reason carries the gate's own sentence. The answer comes from the same gates "
            + "that judge the statement when it runs, so it is not a second opinion — but "
            + "it is not permission either: a mutation still passes the write gate and a "
            + "human confirmation.",
        kind: .read,
        audience: .agentReachable,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "database": .object(["type": .string("string")]),
                "statement": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("statement")]),
        ]),
        handler: { params in
            guard let db else {
                throw StandardActionError.missingClient(
                    action: "db_classify_statement", role: "database")
            }
            let statement = try requireStringParam(
                params, "statement", action: "db_classify_statement")
            var arguments: [String: JSONValue] = ["statement": .string(statement)]
            if let database = optionalString(params, "database") {
                arguments["database"] = .string(database)
            }
            return try await callChecked(
                db, tool: "classify_statement", arguments: .object(arguments),
                action: "db_classify_statement", timeout: MCPClient.readReplyTimeout)
        }
    ))

    // Renamed from `session_resume`, which now does what its name says.
    // This is the metadata read it used to be, unchanged.
    await registry.register(Action(
        name: "session_get",
        description: "Get metadata, title and first prompt for one session.",
        kind: .read,
        audience: .agentReachable,
        schema: .object([
            "type": .string("object"),
            "properties": .object(["id": .object(["type": .string("string")])]),
            "required": .array([.string("id")]),
        ]),
        handler: { params in
            guard let context else {
                throw StandardActionError.missingClient(action: "session_get", role: "context")
            }
            let id = try requireStringParam(params, "id", action: "session_get")
            return try await callChecked(
                context, tool: "get_session", arguments: .object(["id": .string(id)]),
                action: "session_get", timeout: MCPClient.readReplyTimeout)
        }
    ))

    // `WindowModel.readThread` is this action's one caller: the window
    // rebuilds a resumed session's thought thread by dispatching this, the
    // same way `session_get` and every other read reaches `wakil-ctx`
    // (Invariant 2 in the small — one path, journaled, for the agent and
    // for the window alike). `limit` is optional on the wire (0 or absent
    // keeps everything), but the window always sends
    // `WindowModel.rebuiltThreadLimit` so the two agree on how much of a
    // long session is worth rebuilding.
    await registry.register(Action(
        name: "session_read",
        description: "Read one session's transcript as thought-thread entries, oldest first, "
            + "together with the working directory it ran in, the provider holding it and the "
            + "session it was forked from. Refuses, naming the directory, when the session's "
            + "working directory is not a root of the active project.",
        kind: .read,
        audience: .agentReachable,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string")]),
                "limit": .object(["type": .string("number")]),
            ]),
            "required": .array([.string("id")]),
        ]),
        handler: { params in
            guard let context else {
                throw StandardActionError.missingClient(action: "session_read", role: "context")
            }
            let id = try requireStringParam(params, "id", action: "session_read")
            var arguments: [String: JSONValue] = ["id": .string(id)]
            if case .object(let obj) = params, let limit = obj["limit"] { arguments["limit"] = limit }
            return try await callChecked(
                context, tool: "read_session", arguments: .object(arguments),
                action: "session_read", timeout: MCPClient.readReplyTimeout)
        }
    ))

    // `.control` by the kind's own definition: it changes Wakil's own
    // state and leaves the world outside Wakil untouched, so the
    // environment never blocks it. That makes `agentAllowedTools` publish
    // it — it filters on `.read || .control` and excludes `.mutate` by
    // KIND, never by name — and no name-based exception is added here,
    // which would be the first of its kind.
    //
    // **It parks and returns rather than performing the swap.** The agent
    // that calls this is about to be replaced by the session it asked
    // for, and the shim's socket dies with the `claude` process, so a
    // reply sent after the swap could never arrive. The window does the
    // work on its own next turn — by which time this answer has already
    // been delivered.
    await registry.register(Action(
        name: "session_resume",
        description:
            "Leave the current agent session and continue a past one, forking it under a new "
            + "session id so the original transcript is untouched. Returns as soon as the "
            + "request is accepted; the switch happens immediately afterwards and ends the "
            + "calling session.",
        kind: .control,
        audience: .agentReachable,
        schema: .object([
            "type": .string("object"),
            "properties": .object(["id": .object(["type": .string("string")])]),
            "required": .array([.string("id")]),
        ]),
        handler: { params in
            let id = try requireStringParam(params, "id", action: "session_resume")
            let caller = ActionRegistry.dispatchCaller
            // An agent's own conversation, or the operator's screen's as it was when they asked
            // (`WindowModel.screenPinnedActions`); nil — `--dispatch` — the screen's at drain.
            await resumes.request(ResumeRequest(
                sessionId: id, place: pinnedPlace(of: caller), conversation: caller?.conversation))
            return .object([
                "resuming": .string(id),
                "note": .string("this session ends as the fork starts"),
            ])
        }
    ))

    // Conversations 3 of 3: `session_close`, beside them on the same terms — `.control` (the
    // conversation is Wakil's own state), operator-only (an agent must not end the operator's
    // conversation), parked on `conversationRequests`, pinned to the conversation it is
    // dispatched in. The window asks first only with work in flight (`closeConversation`).
    await registry.register(Action(
        name: "session_close",
        description: "End the conversation on screen: its agent stops, its panes close as on quit, "
            + "and it moves to Continue. The operator is asked first when its turn is running or it "
            + "has a write waiting. Does nothing on a Landing. Operator use only.",
        kind: .control,
        audience: .operatorOnly,
        schema: .object(["type": .string("object"), "properties": .object([:])]),
        handler: { _ in
            let conversation = ActionRegistry.dispatchCaller?.conversation
            await conversationRequests.request(.close(conversation: conversation))
            return .object(["closing": conversation.map(JSONValue.string) ?? .null])
        }
    ))

    // Conversations 2 of 3. **`.control`**: which conversation a place shows is Wakil's own
    // state, and nothing outside Wakil changes. **Operator-only** (`operatorOnlyActions`): an
    // agent must not push aside the operator's conversation. Both park on `conversationRequests`
    // and return, as `session_set_provider` parks: no `WindowModel` exists when this runs.
    // **Pinned to the conversation they are dispatched in** — a session's own socket names it
    // (`pinnedPlace(of:)`), and the operator's window names the screen's as it was when the
    // gesture was made (`WindowModel.screenPinnedActions`); `--dispatch` names none, which is the
    // screen's when the request drains.
    await registry.register(Action(
        name: "session_new",
        description: "Put the conversation on screen into the background, untouched — its turn "
            + "carries on — and show the place's Landing, where the next turn starts a new "
            + "conversation. Does nothing on a Landing. Operator use only.",
        kind: .control,
        audience: .operatorOnly,
        schema: .object(["type": .string("object"), "properties": .object([:])]),
        handler: { _ in
            let caller = ActionRegistry.dispatchCaller
            let conversation = caller?.conversation
            await conversationRequests.request(.new(conversation: conversation))
            return .object(["backgrounded": conversation.map(JSONValue.string) ?? .null])
        }
    ))

    await registry.register(Action(
        name: "session_switch",
        description: "Bring a live conversation back on screen — the same session, thread and "
            + "canvas, no fork — going to its place first. `conversation` is its id, or its "
            + "title when that names one live conversation in this place. Operator use only.",
        kind: .control,
        audience: .operatorOnly,
        schema: .object([
            "type": .string("object"),
            "properties": .object(["conversation": .object(["type": .string("string")])]),
            "required": .array([.string("conversation")]),
        ]),
        handler: { params in
            let conversation = try requireStringParam(params, "conversation", action: "session_switch")
            await conversationRequests.request(.switchTo(
                conversation: conversation, place: pinnedPlace(of: ActionRegistry.dispatchCaller)))
            return .object(["switching": .string(conversation)])
        }
    ))

    // Names, call 3: beside the `session_*` actions, parked on the same broker for the same reason.
    await registry.register(conversationRenameAction(
        conversationRequests: conversationRequests, liveConversations: liveConversations))
    // Workspaces piece 4: parked on the same broker; the window delivers it.
    await registry.register(conversationMessageAction(
        conversationRequests: conversationRequests, liveConversations: liveConversations))

    // **`.control`, for the identical reason `session_resume` above is:**
    // this changes which account Wakil's own session runs under and
    // touches nothing outside Wakil, so the environment never blocks it.
    //
    // **This is NOT what keeps the agent from calling it.** `.control`
    // actions are published to the agent's `--allowedTools` by kind, with
    // no exception for this one — see `agentAllowedTools`'s own doc
    // comment for why an earlier attempt to keep this ONE `.control`
    // action off that list by registering it late (after the window's
    // `--allowedTools` snapshot was taken) still left the agent able to
    // reach it: an unlisted tool is routed to `approve_tool_use`
    // (`permission-prompt-probe.md` §1), not auto-denied, and nothing was
    // stopping that bridge from answering `allow`. What actually refuses
    // the agent here is `operatorOnlyActions` in
    // `PermissionPrompt.swift`, consulted from TWO places: this action's
    // absence from `agentAllowedTools`'s output (so the CLI must ask
    // about it rather than silently pre-approving it — §6 of the same
    // probe measured that an allow-listed tool never even reaches the
    // prompt tool) AND `permissionDecision`'s own explicit denial once
    // asked. Registration order is irrelevant to either: this line could
    // move anywhere in this file, or into `WindowModel.init`, without
    // changing what the agent can reach.
    //
    // **It parks and returns, exactly like `session_resume` above, and
    // for a related but distinct reason.** `session_resume`'s handler
    // cannot call back into a `WindowModel` because none exists yet when
    // this function runs (`WakilWiring.build`, before any window is
    // opened) — parking is how ANY action registered here reaches a
    // `WindowModel` at all, agent-reachable or not. See
    // `ProviderSwitchBroker`'s own doc comment.
    await registry.register(Action(
        name: "session_set_provider",
        description: "Switch this window's session to another account (provider) already "
            + "registered in this organization, taking effect immediately with no relaunch. "
            + "Operator/UI use only — the agent is refused this tool at the permission layer "
            + "before it ever reaches this handler.",
        kind: .control,
        audience: .operatorOnly,
        schema: .object([
            "type": .string("object"),
            "properties": .object(["provider": .object(["type": .string("string")])]),
            "required": .array([.string("provider")]),
        ]),
        handler: { params in
            let id = try requireStringParam(params, "provider", action: "session_set_provider")
            await providerSwitches.request(ProviderSwitchRequest(providerId: id))
            return .object(["switching": .string(id)])
        }
    ))

    // **`.control`, not `.mutate`.** The write this performs never leaves
    // Wakil's own process: `RecordSessionParent` appends to the active
    // org's lineage file under `~/.wakil`, which is Wakil's bookkeeping
    // about its own sessions, not the database, filesystem or other
    // external system the write gate exists to protect (spec's own
    // definition of what `.mutate` is for). `session_resume` and the two
    // `ctx_` setters are `.control` for the identical reason — a state
    // change whose only witness is Wakil itself — and gating this one in
    // production would refuse to record a lineage link for a resume that
    // had already happened, leaving the chain silently broken exactly
    // when an operator investigating production most needs ⌘P's sessions
    // grouped correctly.
    await registry.register(Action(
        name: "session_record_parent",
        description: "Record that one session was forked from another, in the active org's "
            + "lineage store, so a chain of resumes can be shown as one conversation.",
        kind: .control,
        audience: .agentReachable,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "child": .object(["type": .string("string")]),
                "parent": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("child"), .string("parent")]),
        ]),
        handler: { params in
            guard let context else {
                throw StandardActionError.missingClient(action: "session_record_parent", role: "context")
            }
            let child = try requireStringParam(params, "child", action: "session_record_parent")
            let parent = try requireStringParam(params, "parent", action: "session_record_parent")
            return try await callChecked(
                context, tool: "record_session_parent",
                arguments: .object(["child": .string(child), "parent": .string(parent)]),
                action: "session_record_parent", timeout: MCPClient.readReplyTimeout)
        }
    ))

    // ⌘P's session source. `wakil-ctx` has served `list_sessions` since
    // Phase 1, but 2a wrapped only `get_session` — so `session_get`
    // (`session_resume` before this rename) required an id that nothing in
    // Wakil could produce. This is that missing half.
    await registry.register(Action(
        name: "session_list",
        description:
            "List Claude Code sessions for the active project's roots across every provider the "
            + "active org holds, newest first. Reports how many transcript stores could not be "
            + "read, so an empty list with a non-zero skipped count means \"could not look\", not "
            + "\"none exist\". `live` lists the conversations running in this window now in this "
            + "organization — every project's, or, given `project` and/or `environment`, those "
            + "places' — newest activity first, each with its title and state (working, waiting, done, "
            + "failed, idle), its workspace, and the messages it holds for the operator. Called by an "
            + "agent, `self` marks its own row and `sameWorkspace` the conversations working beside it: "
            + "conversation_message reaches any of them by `conversation` id. Only the operator brings "
            + "one on screen, with ⌘P.",
        kind: .read,
        audience: .agentReachable,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "project": .object(["type": .string("string")]),
                "environment": .object(["type": .string("string")]),
            ]),
        ]),
        handler: { params in
            guard let context else {
                throw StandardActionError.missingClient(action: "session_list", role: "context")
            }
            let past = try await callChecked(
                context, tool: "list_sessions", arguments: .object([:]),
                action: "session_list", timeout: MCPClient.readReplyTimeout)
            guard let liveConversations else { return past }
            let project = optionalStringParam(params, "project")
            let environment = optionalStringParam(params, "environment")
            // **One organisation, always** (north-star non-goal: no query spans two orgs — the
            // organisation is the credential boundary): a pinned session's own, else the one on
            // screen, which is the one Go's past half answered for. None known lists none.
            let organization: String?
            if let pinned = pinnedPlace(of: ActionRegistry.dispatchCaller) {
                organization = pinned.organization
            } else {
                organization = await liveOrganization?()
            }
            let live = await liveConversations(nil).filter { row in
                guard let organization, !organization.isEmpty else { return false }
                return row.place.organization == organization
                    && (project == nil || row.place.project == project)
                    && (environment == nil || row.place.environment == environment)
            }
            // Workspaces piece 4: an agent's own row, and which rows share its workspace, so a
            // message (`conversation_message`) has an address.
            let own = ActionRegistry.dispatchCaller?.conversation
            let key = { (row: LiveConversation) in MessageWorkspace(of: row.workspace, place: row.place).key }
            let ownWorkspace = live.first { $0.id == own }.map(key)
            return withStructured(past, "live", .array(live.map { row in
                guard case .object(var o) = row.json, let own else { return row.json }
                o["self"] = .bool(row.id == own)
                o["sameWorkspace"] = .bool(ownWorkspace != nil && key(row) == ownWorkspace)
                return .object(o)
            }))
        }
    ))

    // Composes the `UPDATE` a cell edit will run, and runs nothing.
    //
    // **This exists so Wakil's Swift half never composes SQL** — the same
    // reason `db_classify_statement` exists. The dialect's quoting, the
    // active connection's own `sql_mode` (which decides how a backslash or
    // a quote inside `value` gets escaped) and the column's type (which
    // decides whether `value` is quoted at all) all live in Go, behind
    // `wakil-db`'s `render_update` tool. A second implementation of any of
    // that nearer the screen would be a second answer to the question that
    // decides what gets escaped, and the two would eventually disagree.
    // `rowKey` is not composed here either — it must come from a result's
    // own `editable.rowKeys`, the driver's own rendering of the `WHERE`
    // clause naming one row, because a hand-assembled key is how a tool
    // updates the wrong row.
    //
    // **`kind: .read` — a decision, not the default, and this paragraph is
    // that decision's record.** `render_update` opens the SAME writable
    // connection `mutate` does, because the escaping this composes has to
    // match the connection that will eventually run it: a `sql_mode` read
    // off a read-only replica could compose a statement the writable
    // primary would then refuse, or worse, execute with different
    // escaping than the one that was validated. That means an agent
    // reaching this — and `.read` actions are exactly the ones
    // `agentAllowedTools` lets an agent reach directly — causes Wakil to
    // pull the WRITE credential out of the Keychain and open a
    // write-capable session, even though nothing is written: a Keychain
    // access, an auth attempt against the real server, a connection slot
    // held for the round trip, and (depending on the server) an
    // audit-log entry, all for a call that composes text and returns it.
    // An agent could use that to probe whether write credentials are
    // valid and reachable in an environment where `db_run_mutation` is
    // blocked outright — production — without ever running a statement.
    //
    // That probe is real, and still `.read` is the right call, for three
    // reasons. First, it executes nothing against user data — the
    // connection is opened, used to ask the server how it would escape a
    // value, and closed; no statement reaches the engine. Second, it
    // composes only text an agent that can already read the schema and
    // reason about SQL could write by hand — the "secret" here is
    // `sql_mode` and dialect trivia, not a capability. Third, the
    // alternative this brief was asked to weigh — `.mutate` — is
    // actively worse: `.mutate` parks an action in the confirmation
    // broker until a human types a confirmation at the keyboard, and the
    // one thing this action's OWN caller (a cell edit in the grid editor)
    // needs is to get a statement back immediately so it can show the
    // human what is about to run. Making composition itself require a
    // human confirmation would mean two confirmations per edit — one to
    // see the statement, one to run it — for a step that does not write
    // anything. `db_run_mutation` remains the one gate that matters: the
    // write gate, the production block and the typed human confirmation
    // all still sit between this action's output and anything happening.
    //
    // What the probe costs, concretely, is bounded by what `db` already
    // is: every `.read` database action here (`db_run_query`,
    // `db_list_tables`, `db_describe_table`, `db_read_table`,
    // `db_classify_statement`) already dials this same client and already
    // proves the READ credential reachable the moment it is dispatched.
    // `render_update` opening the writable half of that same client DOES
    // teach an agent something none of those can: `db_list_databases`
    // reads configuration only, so an entry reporting `writable: true`
    // proves a write credential is *configured*, not that it is *valid* —
    // reaching `render_update` (or `db_run_mutation`) is what actually
    // proves the write credential works. What it does not do is hand the
    // agent a new KIND of thing to detect: every read action here already
    // proves some credential of this client is configured and reachable,
    // so this is a shift in WHICH credential gets exercised (write instead
    // of read), not a new capability to detect that a credential exists
    // at all.
    await registry.register(Action(
        name: "db_render_update",
        description:
            "Compose the UPDATE that writes one cell back, and return it WITHOUT running it. "
            + "table, rowKey and column must all come from the SAME result's editable block — "
            + "editable.table, that row's own entry in editable.rowKeys, and a name from "
            + "editable.columns — never assembled by hand or mixed from two different results: "
            + "this is not cross-checked, so a rowKey paired with the wrong table composes a "
            + "well-formed UPDATE against that other table's row. value is a literal UNLESS it "
            + "begins with \"=\", in which case everything after the \"=\" is raw SQL, NOT a "
            + "value — a bare word there (e.g. \"=status\") is a COLUMN REFERENCE, and the "
            + "statement silently copies that column's value with no error (\"=NOW()\" and "
            + "\"=NULL\" are the safe, intended use of this escape). A literal value that must "
            + "itself begin with \"=\" cannot be expressed through this tool at all; use the "
            + "query line instead. Pass the returned statement to db_run_mutation, which still "
            + "requires the write gate, the production block and a typed human confirmation "
            + "before anything runs.",
        kind: .read,
        audience: .agentReachable,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "database": .object(["type": .string("string")]),
                "table": .object(["type": .string("string")]),
                "rowKey": .object(["type": .string("string")]),
                "column": .object(["type": .string("string")]),
                "columnType": .object(["type": .string("string")]),
                "value": .object(["type": .string("string")]),
            ]),
            "required": .array([
                .string("table"), .string("rowKey"), .string("column"), .string("value"),
            ]),
        ]),
        handler: { params in
            guard let db else {
                throw StandardActionError.missingClient(
                    action: "db_render_update", role: "database")
            }
            // The four required parameters, checked locally rather than
            // forwarded blind: without this, an omitted `value` was not
            // refused here and Go accepts `""` as a real literal, so a
            // schema-violating call would silently compose
            // `SET "col" = ''` instead of being refused as malformed.
            let table = try requireStringParam(params, "table", action: "db_render_update")
            let rowKey = try requireStringParam(params, "rowKey", action: "db_render_update")
            let column = try requireStringParam(params, "column", action: "db_render_update")
            let value = try requireStringParam(params, "value", action: "db_render_update")
            var arguments: [String: JSONValue] = [
                "table": .string(table), "rowKey": .string(rowKey),
                "column": .string(column), "value": .string(value),
            ]
            // `database` and `columnType` stay optional, so destructured
            // once here rather than re-checked per key.
            if case .object(let obj) = params {
                if let database = obj["database"] { arguments["database"] = database }
                if let columnType = obj["columnType"] { arguments["columnType"] = columnType }
            }
            return try await callChecked(
                db, tool: "render_update", arguments: .object(arguments),
                action: "db_render_update", timeout: MCPClient.readReplyTimeout)
        }
    ))

    // Wakil's FIRST `.mutate` action, and as of this writing its only one.
    //
    // Everything about the gate has been in place and untested against a
    // live subject since 2a: `writeGate` blocks `.mutate` outright in
    // production and gates it everywhere else, `ActionRegistry.dispatch`
    // consults it before the handler runs, and `WriteGateTests` covers the
    // full matrix. What was missing was something to gate.
    // `phase-2a-acceptance.md`'s checks 5 and 6 have said "not expressible
    // in 2a" since 2026-09-08 for exactly this reason.
    //
    // It writes NOTHING to the `db` pane, unlike `db_run_query` above. That
    // pane holds columns and rows; a mutation has neither, and projecting a
    // row count into a rows grid would put a fabricated shape on the
    // surface Invariant 3 promises reflects what is actually on screen.
    await registry.register(Action(
        name: "db_run_mutation",
        description:
            "Run ONE INSERT, UPDATE or DELETE against the active environment's database. "
            + "Requires a typed confirmation from the operator, which YOU CANNOT SUPPLY — "
            + "proposing this action parks it until a human confirms it at the keyboard. "
            + "Refused outright when the active environment is production. Schema changes "
            + "(CREATE/DROP/ALTER/TRUNCATE/RENAME/GRANT), multiple statements, and Mongo "
            + "databases are not supported.",
        kind: .mutate,
        audience: .agentReachable,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "statement": .object(["type": .string("string")]),
                "database": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("statement")]),
        ]),
        handler: { params in
            guard let db else {
                throw StandardActionError.missingClient(action: "db_run_mutation", role: "database")
            }
            let statement = try requireStringParam(params, "statement", action: "db_run_mutation")
            var arguments: [String: JSONValue] = ["statement": .string(statement)]
            if case .object(let obj) = params, let database = obj["database"] {
                arguments["database"] = database
            }
            // The ONE call site that does not pass `readReplyTimeout`, and
            // the only one that translates a timeout rather than letting
            // it through. Both halves are load-bearing; see
            // `MCPClient.mutationReplyTimeout` for the first and
            // `mutationCallFailure` for the second.
            do {
                return try await callChecked(
                    db, tool: "mutate", arguments: .object(arguments),
                    action: "db_run_mutation", timeout: MCPClient.mutationReplyTimeout)
            } catch {
                throw mutationCallFailure(
                    error, action: "db_run_mutation", statement: statement,
                    seconds: MCPClient.mutationReplyTimeout)
            }
        }
    ))
}

/// Runs pane `paneId`'s own subject again and redraws it.
///
/// **One path, four callers**: `db_page`, `db_refetch`, `pane_sort`'s
/// re-query branch, and the window's relaunch restore. The mapping from a
/// subject to a tool call is the only hard part of any of them, and four
/// copies of it is four places for it to drift.
///
/// It does not write `Pane.fetch`. The caller does, from the SAME binding
/// it passed here — so the fetch this runs and the fetch the pane records
/// are one value rather than two computed the same way — and `db_page` and
/// `pane_sort` both write it only once this call has come back (final
/// review, Important 6): a fetch committed ahead of a re-fetch that then
/// failed would leave the pane claiming a page, or an ordering, it was
/// never shown.
///
/// **No `layout` parameter** (RULING R3). The brief that first specified
/// this function declared one, but nothing in the body reads it — every
/// caller already writes `Pane.fetch` on `layout` itself before calling
/// this, which is the very reason this function does not, so threading
/// `layout` through here as well would be an unused parameter with no
/// caller that needs it.
///
/// **`.tables` and `.columns` push no `limit`, `offset` or sort into their
/// arguments**, and always call `setRows` with `truncated: false,
/// pageable: false, offset: 0` — a table list or a column list is complete
/// by construction, so there is no page to ask for and no server-side
/// ordering to request; a sort on either is honoured client-side by
/// `setRows`'s own re-sort, hence `sort: fetch.sort` is still passed
/// through to it.
func refetchPane(
    paneId: String, fetch: PaneFetch, db: any ToolCaller, panes: PaneStore,
    action: String = "db_refetch"
) async throws -> JSONValue {
    var arguments: [String: JSONValue] = [:]
    if let database = fetch.query.database { arguments["database"] = .string(database) }

    switch fetch.query {
    case .sql(_, let raw):
        arguments["query"] = .string(raw)
        arguments["limit"] = .number(Double(fetch.pageSize))
        arguments["offset"] = .number(Double(fetch.offset))
        // The wire shape D5 fixed: a list, in precedence order, rather
        // than one scalar column/direction pair — a single term could
        // never express "and then by this", which is what made a second
        // header click fall back to writing `ORDER BY` straight into the
        // SQL. Matches `sortArg` on the Go side exactly.
        arguments["sort"] = .array(fetch.sort.map {
            .object(["column": .string($0.column), "descending": .bool($0.direction == .descending)])
        })
        let sent = arguments
        let outcome = try await dbReadInFlight(paneId: paneId, action: action, panes: panes) {
            try await callChecked(
                db, tool: "query", arguments: .object(sent),
                action: action, timeout: MCPClient.readReplyTimeout)
        }
        guard case .landed(let result) = outcome else { return dbCancelledResult(paneId: paneId) }
        guard let contents = dbPaneContents(from: result) else { return result }
        await panes.setRows(
            paneId: paneId, columns: contents.columns, columnTypes: contents.columnTypes,
            columnTypesInferred: contents.columnTypesInferred, rows: contents.rows,
            millis: contents.millis, truncated: contents.truncated,
            pageable: contents.pageable, offset: fetch.offset, sort: fetch.sort,
            listsTables: contents.listsTables, editable: contents.editable)
        return annotatedWithPaneOutcome(result, paneId: paneId, opened: false)

    case .table(_, let name):
        arguments["name"] = .string(name)
        arguments["limit"] = .number(Double(fetch.pageSize))
        arguments["offset"] = .number(Double(fetch.offset))
        // The wire shape D5 fixed: a list, in precedence order, rather
        // than one scalar column/direction pair — a single term could
        // never express "and then by this", which is what made a second
        // header click fall back to writing `ORDER BY` straight into the
        // SQL. Matches `sortArg` on the Go side exactly.
        arguments["sort"] = .array(fetch.sort.map {
            .object(["column": .string($0.column), "descending": .bool($0.direction == .descending)])
        })
        let sent = arguments
        let outcome = try await dbReadInFlight(paneId: paneId, action: action, panes: panes) {
            try await callChecked(
                db, tool: "read_table", arguments: .object(sent),
                action: action, timeout: MCPClient.readReplyTimeout)
        }
        guard case .landed(let result) = outcome else { return dbCancelledResult(paneId: paneId) }
        guard let contents = dbPaneContents(from: result) else { return result }
        await panes.setRows(
            paneId: paneId, columns: contents.columns, columnTypes: contents.columnTypes,
            columnTypesInferred: contents.columnTypesInferred, rows: contents.rows,
            millis: contents.millis, truncated: contents.truncated,
            pageable: contents.pageable, offset: fetch.offset, sort: fetch.sort,
            listsTables: contents.listsTables, editable: contents.editable)
        return annotatedWithPaneOutcome(result, paneId: paneId, opened: false)

    case .tables:
        // No limit, no offset and no sort pushed: a table list is complete
        // by construction, so there is no page to ask for and the sort, if
        // any, is honoured client-side by `setRows`.
        let sent = arguments
        let outcome = try await dbReadInFlight(paneId: paneId, action: action, panes: panes) {
            try await callChecked(
                db, tool: "list_tables", arguments: .object(sent),
                action: action, timeout: MCPClient.readReplyTimeout)
        }
        guard case .landed(let result) = outcome else { return dbCancelledResult(paneId: paneId) }
        guard let contents = containerListPaneContents(from: result) else { return result }
        await panes.setRows(
            paneId: paneId, columns: contents.columns, columnTypes: contents.columnTypes,
            columnTypesInferred: false, rows: contents.rows, millis: 0,
            truncated: false, pageable: false, offset: 0, sort: fetch.sort,
            listsTables: true, editable: nil)
        return annotatedWithPaneOutcome(result, paneId: paneId, opened: false)

    case .columns(_, let table):
        arguments["name"] = .string(table)
        let sent = arguments
        let outcome = try await dbReadInFlight(paneId: paneId, action: action, panes: panes) {
            try await callChecked(
                db, tool: "describe_table", arguments: .object(sent),
                action: action, timeout: MCPClient.readReplyTimeout)
        }
        guard case .landed(let result) = outcome else { return dbCancelledResult(paneId: paneId) }
        guard let contents = schemaPaneContents(from: result) else { return result }
        await panes.setRows(
            paneId: paneId, columns: contents.columns, columnTypes: contents.columnTypes,
            columnTypesInferred: false, rows: contents.rows, millis: 0,
            truncated: false, pageable: false, offset: 0, sort: fetch.sort,
            listsTables: false, editable: nil)
        return annotatedWithPaneOutcome(result, paneId: paneId, opened: false)
    }
}

/// Translates a failure of the `mutate` tool call into the error Wakil
/// surfaces for it.
///
/// Everything except a reply-budget timeout passes through UNCHANGED: a
/// refusal from `wakilcore.AssertSQLMutation`, a missing `writeRef`, a
/// constraint violation, a dead transport — each of those is a fact about
/// something that did not happen, and the server said so, so there is
/// nothing to reinterpret.
///
/// A timeout is the one case where Wakil knows *less* than the shape of the
/// error suggests. `MCPClientError.timeout` means only that the reply did
/// not arrive in time; `wakil-db` is not cancelled by it, the connection is
/// not rolled back by it, and the statement's fate is simply unknown. Left
/// as-is it would reach `ActionRegistry.dispatch`'s `catch`, be journalled
/// `"error"`, and be reported to whoever asked as a failure — which is how
/// a committed `DELETE` comes to be recorded as a mutation that did not
/// run. `mutationFateUnknown` is that same event said honestly.
///
/// Extracted so the translation has one definition, and originally so it
/// could be tested without a database. Since `ToolCaller` the whole chain
/// is driveable — see `aTimedOutMutationIsJournalledUncertainBesideItsError`
/// — and this stays a named function on its own merit.
func mutationCallFailure(
    _ error: Error, action: String, statement: String, seconds: TimeInterval
) -> Error {
    guard case MCPClientError.timeout = error else { return error }
    return StandardActionError.mutationFateUnknown(
        action: action, statement: statement, seconds: seconds)
}

/// Writes the extra journal line a mutation whose fate is unknown needs,
/// and does nothing at all for any other error.
///
/// **Why this exists as a second line rather than a different `outcome`.**
/// `ActionRegistry.dispatch` is the audit chokepoint and is deliberately
/// left alone: it journals `"error"` whenever a handler throws, and it does
/// not — and must not — inspect which error it was in order to decide what
/// to call the outcome. So the honest record is made *beside* that line
/// rather than instead of it, by the caller, which is also the only layer
/// that knows the `origin` a journal entry has to carry.
///
/// **Read `"error"` followed by `"uncertain"` for one action as a pair**,
/// the way spec §7's `"gated"` → `"ok"` pair is read. It means: Wakil gave
/// up waiting on a statement it had already sent, and the `"error"` line
/// before it is Wakil's report of its own patience running out — NOT
/// evidence that the database did nothing. `dispatch` writes that `"error"`
/// line the moment the handler throws; this function only runs afterwards,
/// once the throw has propagated up to the caller's own `catch` — which is
/// why this line always comes second, never first.
///
/// Journalling is best-effort here, exactly as it is nowhere else: every
/// `dispatch` outcome propagates a journal write failure to its caller.
/// This one cannot, because it runs inside a `catch` that already has an
/// error to report and that error is the more important of the two. A
/// failure to append is therefore swallowed, and what the caller surfaces
/// — `mutationFateUnknown`'s text — still says the whole truth.
///
/// **`caller` must be the value the caller passed to `dispatch`, not a
/// fresh read.** Both live callers re-read the caller's place immediately
/// before dispatching, precisely because it can change while a proposal is
/// parked; reading it a second time here would let the pair of lines
/// disagree about the one condition they exist to record. Capture it once,
/// dispatch with it, and pass that same value here.
public func recordUncertainMutation(
    _ error: Error,
    registry: ActionRegistry,
    action: String,
    params: JSONValue,
    origin: ActionOrigin,
    caller: DispatchCaller
) async {
    guard case StandardActionError.mutationFateUnknown = error else { return }
    try? await registry.journalUncertainMutation(
        action: action, params: params, origin: origin, caller: caller)
}

/// Refuses a `pane` naming a pane that is not open.
///
/// **Checked BEFORE the tool call, not after**: a pane id that names
/// nothing is a mistake in the request, and running a read whose rows have
/// nowhere to go — then reporting success — is the failure this check
/// exists against. A `nil` layout skips it entirely: with no layout there
/// is nothing to check an id against, and inventing a failure would break
/// every `--dispatch` caller.
func requireOpenPane(_ explicit: String?, action: String, layout: LayoutStore?) async throws {
    guard let explicit, !explicit.isEmpty, let open = await layout?.snapshot() else { return }
    guard open.panes.contains(where: { $0.id == explicit }) else {
        throw StandardActionError.unknownPane(
            action: action, pane: explicit, open: open.panes.map(\.id))
    }
}

/// The pane a result belongs in, opening one when none was named — and
/// retitling it when it was.
///
/// Returns the literal `"db"` and `false` when there is no layout to open
/// a pane in — `--dispatch` and tests — which is what that path has always
/// done.
///
/// **`title` is optional, and `nil` means "no name for this subject", not
/// "call it nothing"** — 2c-ii-b walk defect D3. A named pane is retitled
/// only when the caller actually has a name for what it now shows;
/// `db_run_query` has one exactly when the call carried a `database`, and
/// retitling a pane to `fallback`'s `"db"` because a one-database
/// environment let the parameter go unsent would replace a stale name with
/// a worse one. A pane that cannot be named keeps the name it had, which is
/// the pre-existing behaviour and the only honest option left.
///
/// `fallback` is what a NEW pane is called when there is no name — never
/// used for a rename, because a rename has something to lose.
func resolvePane(
    explicit: String?, title: String?, fallback: String, layout: LayoutStore?
) async -> (id: String, opened: Bool) {
    if let named = queryTargetPane(explicit: explicit, layout: nil) {
        if let title { await layout?.retitle(id: named, to: title) }
        return (named, false)
    }
    guard let layout else { return ("db", false) }
    return (await layout.open(kind: "db", title: title ?? fallback).id, true)
}

/// A non-negative integer parameter, or `nil`.
///
/// Rejects a negative, a fraction, a NaN and an infinity rather than
/// coercing them — `safeInt` is the same guard `requireRowIndex` uses.
func optionalIntParam(_ params: JSONValue, _ name: String) -> Int? {
    guard case .object(let obj) = params, let parsed = obj[name]?.intValue, parsed >= 0
    else { return nil }
    return parsed
}

/// Projects a `wakil-db` `query` tool result into what the `db` pane holds,
/// or `nil` if the result is not a recognisable rows payload.
///
/// A free function rather than inline in `db_run_query`'s handler because
/// three actions project the same shape and one definition is the point.
/// It was originally extracted so it could be tested without an
/// `MCPClient`; since `ToolCaller`, the handler around it is testable too,
/// and both are covered. This function is the part of the DB pane's path
/// that was wrong — see the truncation tests in `StandardActionsTests`.
///
/// **Where the fields live.** A tool's typed output is nested one level down
/// inside the `CallToolResult`, under `structuredContent` — not at the
/// result's top level. That nesting was observed directly against the real
/// `bin/wakil-ctx` binary; `ContextStore.current()`'s doc comment records
/// the `get_context` result it was read off. `wakil-db`'s `query` tool was
/// not run for real here — querying a database needs Keychain-backed
/// credentials — so what this reads is `wakilcore.Rows`'s declared JSON
/// shape through that same nesting rather than one observed from the live
/// binary.
///
/// **`truncated` is optional, and its absence means `false`.** The Go field
/// is tagged `json:"truncated,omitempty"` (`internal/wakilcore/dbdriver.go`),
/// so a complete result omits the key entirely. Requiring it — the way
/// `columns` and `rows` are required — would reject every complete result.
/// Losing it is worse, and is the bug this function was extracted to fix:
/// `wakilcore.clampReadLimit` turns an absent or out-of-range `limit` into
/// 500, `WindowModel.runQuery` sends no `limit` at all, so *every* query the
/// window runs is capped at 500 rows — and a capped result that reached the
/// pane without this flag was served to `read_pane`, and so to an LLM, as
/// the whole answer.
///
/// **`nil` rather than an empty table** for an unrecognised shape, so the
/// caller leaves the pane untouched. The query itself already succeeded by
/// the time this runs, and replacing the previous result with an empty
/// table would read on screen as "this query returned no rows".
func dbPaneContents(from result: JSONValue) -> (
    columns: [String], columnTypes: [String], columnTypesInferred: Bool,
    rows: [[JSONValue]], millis: Int64, truncated: Bool, pageable: Bool, listsTables: Bool,
    editable: PaneEditable?
)? {
    guard case .object(let resultObj) = result,
        case .object(let structured)? = resultObj["structuredContent"],
        case .array(let columnValues)? = structured["columns"],
        case .array(let rowValues)? = structured["rows"]
    else {
        return nil
    }
    let columns = columnValues.compactMap { value -> String? in
        if case .string(let s) = value { return s }
        return nil
    }
    // All or nothing, matching wakilcore.Rows.ColumnTypes' own contract: a
    // positionally aligned slice that is short would annotate the wrong
    // columns, which is worse than annotating none.
    var columnTypes: [String] = []
    if case .array(let typeValues)? = structured["columnTypes"] {
        let decoded = typeValues.map { value -> String in
            if case .string(let s) = value { return s }
            return ""
        }
        if decoded.count == columns.count { columnTypes = decoded }
    }
    var columnTypesInferred = false
    if case .bool(let flag)? = structured["columnTypesInferred"] { columnTypesInferred = flag }
    let rows = rowValues.compactMap { value -> [JSONValue]? in
        if case .array(let row) = value { return row }
        return nil
    }
    var millis: Int64 = 0
    // `safeInt64`, not a bare `Int64(value)`: that conversion *traps* on a
    // `NaN` or an out-of-range magnitude, and this reads a number off a
    // subprocess's JSON. The view's projection has guarded the same field
    // since it was written and this one did not (final review Finding 7) —
    // the same guard, so the two cannot disagree about what a millisecond
    // count can be. `0` is the documented default for an absent `millis`
    // and is what an unusable one falls back to.
    if let value = structured["millis"]?.int64Value { millis = value }
    var truncated = false
    if case .bool(let flag)? = structured["truncated"] { truncated = flag }
    let pageable: Bool = {
        if case .bool(let p)? = structured["pageable"] { return p }
        // Absent means a server too old to say. False is the safe answer:
        // it hides the page control rather than offering one that returns
        // a syntax error.
        return false
    }()
    // Absent means a server too old to say, or a driver that never sets it
    // for this statement — either way false is the safe answer: it keeps
    // the drill offered for a `SELECT name FROM tables` from ever being
    // offered by a guess rather than a declaration (`offersDrill`).
    var listsTables = false
    if case .bool(let flag)? = structured["listsTables"] { listsTables = flag }
    return (columns, columnTypes, columnTypesInferred, rows, millis, truncated, pageable,
            listsTables, paneEditable(from: structured))
}

/// Turns a `list_tables` result into pane rows.
///
/// **The schema browser is the data surface, pointed at metadata.** A
/// table list is one row per table with two columns, which is a result
/// set, so it draws on 2c-i's grid with no new view code and is reachable
/// by every route an ordinary result is.
///
/// Never truncated and never pageable: `ListContainers` returns everything
/// the server reports or fails, so there is no second page to ask for and
/// offering the control would be a lie.
func containerListPaneContents(
    from result: JSONValue
) -> (columns: [String], columnTypes: [String], rows: [[JSONValue]])? {
    guard case .object(let obj) = result,
          case .object(let structured)? = obj["structuredContent"],
          case .array(let containers)? = structured["containers"]
    else { return nil }
    let rows: [[JSONValue]] = containers.map { entry in
        guard case .object(let c) = entry else { return [.null, .null] }
        return [c["name"] ?? .null, c["kind"] ?? .null]
    }
    return (columns: ["name", "kind"], columnTypes: ["TEXT", "TEXT"], rows: rows)
}

/// Turns a `describe_table` result into pane rows.
///
/// `key` is carried through `wakilcore.Column.Key`, which `sqlConn.Describe`
/// now populates by reading the table's primary key alongside
/// `rows.ColumnTypes()`. `mongoConn.Describe`, which reads one document and
/// has no primary key to report, still leaves every row's key `false` —
/// so the column is honest per driver rather than false everywhere.
func schemaPaneContents(
    from result: JSONValue
) -> (columns: [String], columnTypes: [String], rows: [[JSONValue]])? {
    guard case .object(let obj) = result,
          case .object(let structured)? = obj["structuredContent"],
          case .array(let columns)? = structured["columns"]
    else { return nil }
    let rows: [[JSONValue]] = columns.map { entry in
        guard case .object(let c) = entry else { return [.null, .null, .bool(false)] }
        return [c["name"] ?? .null, c["type"] ?? .null, c["key"] ?? .bool(false)]
    }
    return (columns: ["name", "type", "key"],
            columnTypes: ["TEXT", "TEXT", "BOOLEAN"], rows: rows)
}

private let nameParamSchema = JSONValue.object([
    "type": .string("object"),
    "properties": .object(["name": .object(["type": .string("string")])]),
    "required": .array([.string("name")]),
])

/// Pulls a required string param `key` out of `params`, or throws
/// `StandardActionError.missingParam` naming `action` and `key`.
private func requireStringParam(_ params: JSONValue, _ key: String, action: String) throws -> String {
    guard case .object(let obj) = params, case .string(let value)? = obj[key] else {
        throw StandardActionError.missingParam(action: action, param: key)
    }
    return value
}

/// An optional string param `key`, or nil when it is absent, not a string, or empty.
private func optionalStringParam(_ params: JSONValue, _ key: String) -> String? {
    guard case .object(let obj) = params, case .string(let value)? = obj[key], !value.isEmpty else {
        return nil
    }
    return value
}

/// `result` with `structuredContent[key] = value`, everything else as it came: a Go tool's
/// answer, carrying one more thing Swift alone knows. A result with no `structuredContent`
/// gains one; one that is not an object is returned as it was.
private func withStructured(_ result: JSONValue, _ key: String, _ value: JSONValue) -> JSONValue {
    guard case .object(var object) = result else { return result }
    var structured: [String: JSONValue] = [:]
    if case .object(let existing)? = object["structuredContent"] { structured = existing }
    structured[key] = value
    object["structuredContent"] = .object(structured)
    return .object(object)
}

/// Calls `tool` on `client` and translates the MCP tool-error convention
/// (a successful JSON-RPC response whose result carries `isError: true`)
/// into a thrown `StandardActionError.serverError`, carrying the server's
/// own message verbatim.
///
/// `ContextStore.callChecked` performs the same translation into its own
/// error type. The two are not one function because the error types differ:
/// this one names the action, so a dispatch failure reads `ctx_set_project:
/// project "widgets" is filed under org "acme"...` rather than leaving the
/// caller to say which action it was. What is genuinely common — pulling
/// the server's message out of the `content` array — *is* shared, as
/// `mcpErrorText` (Context/ContextStore.swift).
///
/// `timeout` is passed through rather than defaulted, so every call site
/// has to state which of `MCPClient`'s two reply budgets it is asking for.
/// A default would silently give a future `.mutate` action the read budget
/// — which is precisely the bug this parameter exists to have prevented.

/// Adds to a `db_run_query` result the one thing the rows themselves cannot
/// say: where on screen they went, and whether getting them there opened a
/// pane that was not open before.
///
/// **Because the honest answer was previously silence.** With no database
/// pane open, `queryTargetPane` falls back to the literal string `"db"` —
/// a pane id `LayoutStore` never mints — and the rows went into `PaneStore`
/// under a key nothing draws. The action returned the database's own result
/// unchanged, so the agent had every reason to report "results were written
/// to the focused DB pane", and did, to an operator looking at an empty
/// canvas. The first fix reported the miss and told the agent the remedy
/// was `pane_open`; the operator walk showed agents relaying the miss
/// rather than remedying it, so `db_run_query` now opens the pane itself
/// and this reports that it did.
private func annotatedWithPaneOutcome(
    _ result: JSONValue, paneId: String, opened: Bool
) -> JSONValue {
    guard case .object(var obj) = result else { return result }
    obj["pane"] = .string(paneId)
    obj["drawn"] = .bool(true)
    if opened {
        obj["paneNote"] = .string(
            "You named no pane, so a new one was opened (id \"\(paneId)\") and the rows "
            + "above are drawn in it. To REFINE this same question — add a filter, change "
            + "a range, page, sort — pass pane: \"\(paneId)\" and it updates in place. "
            + "Ask a different question with no pane and you get another pane beside it.")
    }
    return .object(obj)
}

/// The config tree, read from disk through `wakil-ctx`.
///
/// **One function, two callers, and that is the whole reason it exists
/// rather than being inlined into the action.** `ctx_config_tree`'s
/// handler is one; `read_pane` on a settings pane is the other, and it
/// deliberately does NOT go through `dispatch` — `read_pane` is not an
/// action, changes nothing, and registering it would put a journal row in
/// front of the operator every time the agent reached for a tool
/// (`MCPServer`'s own note on the three hand-written tools). Two call
/// sites assembling the same read separately is the two-code-paths-to-one-
/// state shape Invariant 2 forbids for mutations, and is no better for a
/// read the screen and the agent must agree about.
func readConfigTree(_ context: (any ToolCaller)?, organisation: String? = nil) async throws -> JSONValue {
    guard let context else {
        throw StandardActionError.missingClient(action: "ctx_config_tree", role: "context")
    }
    return try await callChecked(
        context, tool: "config_tree",
        arguments: .object(organisation.map { ["id": .string($0)] } ?? [:]),
        action: "ctx_config_tree", timeout: MCPClient.readReplyTimeout)
}

enum DBReadOutcome {
    case landed(JSONValue)
    case cancelled
}

/// Runs a db read as `paneId`'s flight — the shape of `apiSendInFlight`. With no pane (a
/// query that opens its own pane when it lands) it is a plain call: there is nothing to show
/// `running` on yet. `.cancelled` when `db_cancel` ended the flight, whether the call then
/// threw `CancellationError` or its reply arrived anyway — that reply is dropped. Inside a
/// dispatch it lands in the scope the dispatch began in however the screen has moved; outside
/// one, a read whose project was switched away is dropped (`finishDBRead` is false).
func dbReadInFlight(
    paneId: String?, action: String, panes: PaneStore,
    read: @escaping @Sendable () async throws -> JSONValue
) async throws -> DBReadOutcome {
    guard let paneId else { return .landed(try await read()) }
    let byAgent = pinnedPlace(of: ActionRegistry.dispatchCaller) != nil
    guard let token = await panes.beginDBRead(paneId: paneId, at: Date(), byAgent: byAgent) else {
        throw StandardActionError.readInFlight(action: action, pane: paneId)
    }
    let task = Task { try await read() }
    await panes.armDBRead(paneId: paneId, token: token) { task.cancel() }
    let result: Result<JSONValue, Error> = await withTaskCancellationHandler {
        do { return .success(try await task.value) } catch { return .failure(error) }
    } onCancel: {
        task.cancel()
    }
    guard await panes.finishDBRead(paneId: paneId, token: token) else { return .cancelled }
    return .landed(try result.get())
}

/// What a read action returns when its flight was cancelled.
func dbCancelledResult(paneId: String) -> JSONValue {
    .object(["pane": .string(paneId), "cancelled": .bool(true)])
}

/// Whether `result` is `dbCancelledResult`'s. `refetchPane` returns it for a read that did not
/// land, and callers that commit `Pane.fetch` after it (`db_page`, `pane_sort`) must not.
func dbResultWasCancelled(_ result: JSONValue) -> Bool {
    guard case .object(let fields) = result else { return false }
    return fields["cancelled"] == .bool(true)
}

/// `callChecked` for Registry's other files (`CapacityActions`). Its own name, because the
/// layering test matches symbols by name and `ContextStore` has a private `callChecked` of its
/// own: an internal one here would read as a Context -> Registry link.
func callCheckedTool(
    _ client: any ToolCaller, tool: String, arguments: JSONValue, action: String, timeout: TimeInterval
) async throws -> JSONValue {
    try await callChecked(client, tool: tool, arguments: arguments, action: action, timeout: timeout)
}

/// 2e-ii. Throws, naming the agent, when `agentIn` finds one running in the place a rename or
/// removal would move. The text is the whole refusal — the operator reads it as written.
private func refuseIfAgentRuns(
    _ agentIn: (@Sendable (String, String?) async -> String?)?,
    project: String, environment: String?, action: String
) async throws {
    guard let agentIn, let agent = await agentIn(project, environment) else { return }
    let place = environment.map { "\(project) / \($0)" } ?? project
    throw StandardActionError.serverError(
        action: action,
        message: "\(agent) is running in \(place) — an agent keeps its own place; stop it first")
}

private func callChecked(
    _ client: any ToolCaller, tool: String, arguments: JSONValue, action: String, timeout: TimeInterval
) async throws -> JSONValue {
    let result = try await client.callTool(name: tool, arguments: arguments, timeout: timeout)
    guard case .object(let obj) = result else {
        return result
    }
    if case .bool(true)? = obj["isError"] {
        throw StandardActionError.serverError(action: action, message: mcpErrorText(from: obj) ?? "\(tool) failed with no message")
    }
    return result
}

/// `conversation_rename`'s refusals (names, call 3): Rule 7's "refuse only what a recorded decision
/// forbids, and say which", and Rule 8's whole sentence for an id that names nothing.
public struct ConversationRenameRefusal: Error, Sendable, Equatable, CustomStringConvertible {
    public let description: String
}

/// `conversation_rename` (names, call 3): **`.control`** — a conversation's name is Wakil's own state —
/// and **agent-reachable**, for the agent's own conversation only (conversations call 5: an agent does
/// not know about the others). `conversation` defaults to the caller's, or — the operator's, with none —
/// to the one on screen when the request drains (`WindowModel.renameConversation`); an id that names
/// no live conversation is refused here, before parking, so the caller hears it. `name` is cleaned
/// (call 4); empty or whitespace clears the operator's name. The agent's rename is the operator's name,
/// not a third slot: the later value wins (Rule 7), and the journal records who.
///
/// A builder, as `layoutActions` is, so a test can register it into a window's own registry.
/// `liveConversations` nil (no window, as for a test that wires none) checks nothing.
public func conversationRenameAction(
    conversationRequests: ConversationBroker,
    liveConversations: (@Sendable (Place?) async -> [LiveConversation])?
) -> Action {
    Action(
        name: "conversation_rename",
        description: "Name a live conversation, as the operator's name for it: it wins over the name "
            + "Wakil's quick model gave it. An empty or blank name clears it, back to the model's name "
            + "or the first message. `conversation` is its id; an agent names only its own conversation, "
            + "and omits it.",
        kind: .control,
        audience: .agentReachable,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "conversation": .object(["type": .string("string")]),
                "name": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("name")]),
        ]),
        handler: { params in
            let raw = try requireStringParam(params, "name", action: "conversation_rename")
            let requested = optionalStringParam(params, "conversation")
            let own = ActionRegistry.dispatchCaller?.conversation
            if ActionRegistry.dispatchOrigin == .agent, own == nil || (requested != nil && requested != own) {
                throw ConversationRenameRefusal(description: "conversation_rename: an agent renames only its "
                    + "own conversation (conversations call 5: an agent does not know about the others)")
            }
            let id = requested ?? own
            if let id, let liveConversations, !(await liveConversations(nil)).contains(where: { $0.id == id }) {
                throw ConversationRenameRefusal(description: "conversation_rename: no live conversation \(id)")
            }
            let name = cleanConversationName(raw)
            await conversationRequests.request(.rename(conversation: id, name: name))
            return .object([
                "renaming": id.map(JSONValue.string) ?? .null,
                "name": name.map(JSONValue.string) ?? .null,
            ])
        })
}
