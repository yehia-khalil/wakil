# Flows

Three paths through the code, one hop per line. Swift paths are under `app/Sources/`.

## 1. An operator click (a db pane re-runs its query)

1. **The view.** A control in `DBPane` / `DataSurface` (`WakilApp/`) calls the closure `Canvas.swift`
   gave it: `Task { await model.dispatchFromSurface(name, params) }`.
2. **`WindowModel.dispatchFromSurface`** → `dispatchFromSurfaceRan`
   (`WakilKit/App/WindowModel.swift`). `pane_set_column_width` goes to `dispatchLayout` instead,
   because a column width lives on `Pane` in `LayoutStore`.
3. **`WindowModel.dispatch`** (private) calls `registry.dispatch(name:params:origin: .ui,
   environment:confirmation: nil)`. The window never pre-supplies a confirmation.
4. **`ActionRegistry.dispatch`** (`WakilKit/Registry/ActionRegistry.swift`) looks the action up (an
   unknown name is journalled `unknown` and throws `ActionError.unknown`).
5. **`writeGate`** (`WakilKit/Gate/WriteGate.swift`) prices it from the action's `kind`, `origin`,
   `price` and the project's production flags: `.allow` runs; `.gate` without `"confirm"` is
   journalled `gated` and throws `needsConfirmation`; `.block` is journalled `blocked` and throws
   `blockedInProduction`.
6. **The handler** runs, with `ActionRegistry.dispatchOrigin` bound to the origin. For
   `db_run_query` it is in `registerStandardActions` (`WakilKit/Registry/StandardActions.swift`).
7. **`callChecked`** → **`MCPClient.callTool`** (`WakilKit/MCP/MCPClient.swift`) sends `tools/call`
   over stdio. A result with `isError: true` becomes `StandardActionError.serverError`.
8. **The binary** (`cmd/wakil-db`, tool `query`) resolves the active environment's database and
   answers rows.
9. **The handler writes the stores**: `layout.setFetch(fetch, id:)` (`LayoutStore`: page and sort,
   persisted with the layout) and `panes.setRows(...)` (`PaneStore`: the rows).
10. **The journal.** `dispatch` appends one entry (`ok` or `error`, with params redacted per the
    action's `secretParams`) to `~/.wakil/journal/<sessionId>.jsonl`. A successful dispatch is also
    published to `dispatches()` subscribers.
11. **`refreshPanes()`** reads every pane on the canvas back out of `PaneStore`
    (`snapshot(paneId:kind:)`) into `tables` and `editables` (db panes), and **`setCell`** puts
    each pane's snapshot in its own `PaneSnapshotCell` in `paneCells`. For `pane_sort` and `db_*`,
    `refreshLayout()` follows.
12. **The pane's view redraws** from the `@Observable` state it read (`model.table(pane.id)` here;
    `model.terminal(_:)`, `api(_:)` or `editor(_:)` for the other kinds, each one pane's cell).

On `needsConfirmation` at step 5, `dispatch` calls `parkAndAwait`, which parks a `PendingMutation`
in the `ConfirmationBroker`. The `ConfirmationPlane` shows it; `confirmPending(typed: "confirm")`
approves and the action is dispatched again with `confirmation: "confirm"`.

## 2. An agent tool call

1. **Launch.** `buildLaunch` (`WakilKit/Harness/ClaudeCodeCLIHarness.swift`) starts `claude` with
   `--mcp-config` (from `agentMCPConfigJSON`: the `wakil` shim plus `agentFacingServers`),
   `--strict-mcp-config`, `--permission-prompt-tool mcp__wakil__approve_tool_use`, and
   `--allowedTools` from `agentAllowedTools`: every `.read` and `.control` action except those in
   `operatorOnlyActions` (never a `.mutate`), plus `read_pane`, `read_layout` and the agent-facing
   servers.
2. **Permission.** For a tool not on `--allowedTools` (for example `db_run_mutation`), the CLI first
   calls `approve_tool_use`. It travels the same path as steps 3 to 5 and is answered by
   `permissionPromptReply` → **`permissionDecision`** (`WakilKit/MCP/PermissionPrompt.swift`): deny
   anything not named `mcp__wakil__…`, allow `read_pane` and `read_layout`, deny
   `operatorOnlyActions`, allow other registered actions.
3. **The shim.** `claude` writes `tools/call` to the stdio of `Wakil --mcp-shim --socket <path>`;
   `runShim` (`WakilKit/MCP/Shim.swift`) copies it to the unix socket unparsed.
4. **`MCPSocketServer`** (`WakilKit/MCP/MCPServer.swift`) reads the frame and calls `handle`.
5. **`handleToolsCall`**: `read_pane`, `read_layout` and `approve_tool_use` are answered in the
   window. Anything else is dispatched.
6. **`registry.dispatch(..., origin: .agent, caller:, confirmation:)`**, where the caller is
   `caller`, the one the session's own socket was started with (its place, session and conversation: the call and any proposal it parks name the conversation they belong to); the gate reads its environment, and its place pins its clients and its canvas (`ScopeRouting.home`), wherever the screen is. Steps 4 to 10 of flow 1 apply. For
   `.control` the gate differs by origin. The agent cannot switch project or environment at all:
   `ctx_set_project` and `ctx_set_environment` are operator-only, because an agent's place is fixed
   when its session starts.
7. **On `needsConfirmation`, `parkForConfirmation`** builds a `PendingMutation` carrying its place and
   calls `confirmations.request`, holding the tool call open. The broker holds one proposal per
   place. `WindowModel`'s confirmation pump sets `parkedProposals`, and `ConfirmationPlane` draws
   the on-screen place's `pending`; another place's waits unseen until the operator returns.
8. **The operator decides.** `confirmPending(typed: "confirm")` → `.approved`: the environment is
   re-read and the same call is dispatched again with `confirmation: "confirm"`, origin still
   `.agent`. Cancel → `.cancelled`; another already parked in the same place → `.busy`. An agent's proposal
   never expires (it waits until decided); only a UI proposal can resolve `.expired`. Each
   returns a JSON-RPC error to the agent.
9. **The reply** goes back over the socket, through the shim, to `claude`, and the window reads its
   panes back as in flow 1. `read_pane` answers from the same `PaneStore` the window draws.

**An agent's page act (3c-ii)** is flow 2 with the price asked per call:

1. **Read.** `browser_read_page` (`.read`) runs `BrowserPageAgent`'s script, fits the text to the cap,
   records the read in the tab (memory only) and answers with the page marked untrusted.
2. **Price per call.** `browser_click` and its kin are `.mutate` with a `callPrice`: `dispatch` works out
   the caller's home, then asks the action for this call's price under the handler's own task-locals.
   `browserActTarget` checks the ref against the tab's last read; the price is the site's
   (`browserActPrice`): *gate* for a production site, or for a site this conversation has not allowed;
   *allow* otherwise. Any failure to describe the call prices *allow*, and the handler then refuses it.
3. **Plane.** On *gate*, `parkForConfirmation` asks the action's `proposal` for the statement and the ask:
   `site` (Let the agent use <site>?) or `productionSite` (the red plane, `PRODUCTION`, the element named).
   A typed request's site question is answered by a click, a spoken one by the typed word, and a
   production act always by the typed word.
4. **Re-dispatch.** Approval re-dispatches the same call. A `site` approval adds the site to the
   conversation's allow-list first. The handler checks the ref again, then `BrowserPageAgent` waits out the
   operator's typing, runs the act in the page and answers with the page after it; the thread shows one
   line per act. If the page changed since the read, the act is refused and adds no site.

## 3. An org switch

1. **The request.** `OrgPlane` (`WakilApp/OrgPlane.swift`) calls
   **`WindowModel.requestOrganizationSwitch(_:)`**, which calls `setOrganization` at once. Nothing
   waits on a turn and nothing asks about unsaved tabs: a switch stops, holds and discards nothing.
2. **`setOrganization(_:)`** refuses only while a switch is in progress or for the org already open.
   A waiting approval in any place does not hold it. It cancels the operator's db reads in flight in the org being left
   (`PaneStore.cancelOperatorDBReads`); an agent's reads, on its pinned client, keep running.
3. **`invalidateForOrgChange()`** resets what belongs to the organisation itself: the vocabulary,
   context, production flags (in the registry too), settings, accounts, login state, provider id,
   `lookup`, roots, capacity, the palette, the editor's pending requests and unsaved prompt, and the
   window's git status and its `gitRoots` mirror (of the screen's roots only, 3b-iii).
   Every place keeps its own state: its agent (harness, socket, thread, turn, conversation), its
   waiting approval, both stores' scopes (canvas and rows), its shells and its editor buffers. See
   [state.md](state.md).
4. **`orgSwitcher(org)`**, which is **`WakilWiring.switchOrg(to:)`**, stops and restarts each
   Wakil-owned client under the new `WAKIL_ORG` with no provider. Any client that does not come back
   puts a line in `status`, and the window is left with no organisation (its canvas put away, still
   in memory).
5. **`organization = org`**, a fresh credentials lookup (`lookupFactory(org)`), and
   **`refreshContext()`**, which reads `get_context` for the new org (project, environment,
   production flags, provider, roots), tells the vocabulary, and activates that place's canvas. A
   place already visited this session comes back from memory, as it was left, with no refetch;
   only its git and editor panes re-read the disk (`catchUpReturnedCanvas`).

An agent left in the outgoing org keeps working there: its clients are pinned to its place
(`PlaceClients`), its credentials resolve in its own org, and its events land in its own thread.
The next harness is built for the new org: `harnessFactory` takes the org as a parameter, so its MCP
config carries the new `WAKIL_ORG`.

## 4. Switching and closing a conversation

A place holds any number of live conversations, one on screen. ⌘N, a home line, a chip (another
organisation's agent only: the home lists the screen's own), ⌘P's Running group and ⌘⇧W are operator clicks or the actions `session_new`, `session_switch` and
`session_close`; the actions are `.control`, operator-only, and reach the window through
`ConversationBroker` (`Harness/ConversationBroker.swift`), drained by a pump, as `session_resume` is.

1. **New.** `WindowModel.newConversation(_:)` puts the on-screen conversation into the background,
   untouched, and the place draws its Landing. Nothing is asked and nothing is stopped.
2. **Switch.** `WindowModel.switchToConversation(_:in:)` brings a live conversation on screen:
   the same session, its thread, canvas, panes and composer draft. It never forks and never touches
   a turn in flight. Only an ended conversation resumes as a fork.
3. **Close.** `WindowModel.closeConversation(_:)` asks first only when the target has a turn in
   flight or a write waiting (`closeQuestion`, a `CloseConversationQuestion`); otherwise it closes
   at once. An unsaved tab refuses first, before any question (`<name> has unsaved changes in
   <titles> — save or close them first.`). `answerCloseQuestion(close:)` takes the answer. Closing stops the agent through
   `stopSession(of:)`, closes the conversation's panes as on quit, and the conversation moves to
   Continue. The place then shows its next live conversation, or its Landing.
