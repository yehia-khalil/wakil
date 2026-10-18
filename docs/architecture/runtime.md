# Runtime: who creates and owns what

One window is one assembly. Two entry points build it the same way: the window
(`WindowSession.start`, `app/Sources/WakilApp/WindowSession.swift`) and the headless `--dispatch`
mode (`runDispatchFile`, `app/Sources/WakilApp/main.swift`). Both call `WakilWiring.build`, so an
action that works in a debug script works in the window.

## `WakilWiring.build`

`app/Sources/WakilKit/App/AppWiring.swift`. It takes a journal directory, a session id, the
executable's directory and an environment, and returns a `WakilWiring`. In order, it:

1. Builds the child environment (`childProcessEnvironment`; see below).
2. Starts four `MCPClient`s, each eagerly: `contextClient` (`wakil-ctx`), `databaseClient`
   (`wakil-db`), `httpClient` (`wakil-http`), `gitClient` (`wakil-git`). A binary that is not found
   or fails its handshake leaves that client `nil` and adds a line to `diagnostics`. That is not
   fatal: the actions stay registered and fail per call, naming the missing client.
3. Creates the stores and brokers: `PaneStore(kinds: PaneKinds.standard)` (`App/PaneKinds.swift`), `LayoutStore`, `ActionRegistry` (with the journal
   directory and session id), `ResumeBroker`, `ProviderSwitchBroker`, `TerminalStore(panes:)`.
4. Registers the actions:
   - `registerStandardActions` (`Registry/StandardActions.swift`)
   - `registerLayoutActions` (`Layout/LayoutActions.swift`)
   - `registerPaneContentActions` (`Registry/PaneContentActions.swift`)
   - `registerTerminalActions` (`Terminal/TerminalActions.swift`), given an `ActiveShellContext`
   - `registerApiActions` (`Api/ApiActions.swift`), which returns the `ApiPaneResolver`
   - `GitStatus` (`Git/GitStatus.swift`), built over the git client and `GitRootsSource`, handed to
     the editor actions, `GitSource` and the window (3b-iii: the Git pane's actions are gone)
   - `registerEditorActions` (`Editor/EditorActions.swift`), given the files client, the window's
     file lists, the `GitStatus` and `GitRootsSource`
5. Tells the registry the active project's production flags (`setEnvironmentProduction`), read
   through `ContextStore`, so `--dispatch` prices environments correctly with no window.
6. Builds the `VocabularyStore`: live sources `WakilSource`, `PaneSource`, `GitSource` (which reads
   the `GitStatus`); cached
   sources `SchemaSource` (when there is a database client) and `CodeSource` (cache under
   `~/.wakil/vocabulary`).
7. Returns the wiring, adding `FSEventsRootWatcher()`, a `ConfirmationBroker()` and
   `SpeechRegistry.standard(environment:)`.

What the wiring offers:

- **`wakilOwnedClients`** — the four clients as one list. `switchOrg` and `shutdown` iterate it, and
  `everyWakilOwnedClientJoinsTheOrgSwitch` (`AppWiringTests`) fails if a client property is left out.
- **`mcpSurface`** — the registry, pane store, layout store, confirmations and a settings reader as
  one `MCPSurface`. It is the only public way to get one, so the socket server cannot be given one
  assembly's registry and another's stores.
- **`useActiveContext(of:)`** — points the terminal actions' `ActiveShellContext` and the
  `GitRootsSource` the `GitStatus` and the editor's git actions read at the live `WindowModel`.
  Both are read on every call, never captured, and for the dispatch's caller (see
  [An agent's calls follow its own place](#an-agents-calls-follow-its-own-place)).
- **`switchOrg(to:)`** — stops and restarts every Wakil-owned client in place under the new org,
  with `provider: nil`. In place, because the action handlers captured these client instances.
- **`shutdown()`** — stops the root watcher, every Wakil-owned client, and every terminal.

## `WindowSession.start`

1. Picks a session id (a UUID) and the journal directory `~/.wakil/journal` (from `HOME`).
2. Calls `WakilWiring.build`; its `diagnostics` become the window's `notes`.
3. Builds `agentSocketFactory`: given a path and a caller, it starts an
   `MCPSocketServer(surface: wiring.mcpSurface, socketPath:, caller:, screen:)`. `screen` reads the
   model's place, filled in once the model exists; `initialize` reports it beside the socket's own
   place (`initializeMeta`), which is how the e2e harness picks its channel.
4. Reads the active context once through `ContextStore` for the first project root and the active
   provider id.
5. Locates the `wakil` CLI and builds three factories: `lookupFactory` (per org,
   `WakilCLICredentialsLookup`), `mintFactory` (`WakilCLIProviderMint`), and `harnessFactory`. The
   harness factory builds, per selection and socket path, `agentMCPConfigJSON` (the shim plus
   `agentFacingServers`)
   and a `ClaudeCodeCLIHarness` with `agentAllowedTools` computed from the registry. If the `wakil`
   binary is missing, the window opens with no agent and a note says why.
6. Creates the `WindowModel`, handing it the wiring's registry, stores, brokers, vocabulary, root
   watcher and palette clients, a `LayoutPersistence` under `~/.wakil/layouts`, the factories, and
   `orgSwitcher: { wiring.switchOrg(to:) }`.
7. Calls `wiring.useActiveContext(of: model)` and creates the `ComposerModel`.

No socket is started here: the model opens one for each place it shows (see below).

## `WindowModel`

`app/Sources/WakilKit/App/WindowModel.swift`, `@MainActor @Observable`. It holds references to the
registry, the stores, the brokers and the harness; it owns the window's state (context, snapshots,
thought thread, status).

- **Actions change pane contents; the window mostly reads.** Operator and agent actions change pane
  contents through `registry.dispatch` and their handlers (the window's own calls go through its
  private `dispatch`, origin `.ui`). `WindowModel` itself writes `PaneStore` only for:
  - failure marks: `panes.setFailure` (a failed page, refetch or query-line run);
  - api focus and responses: `panes.addApiFocus`, `panes.setApiFocus`, and
    `panes.clearApiResponses(to:)` on an environment change;
  - a terminal proposal accepted or discarded: `panes.setTerminalProposal(paneId:, nil)`;
  - scopes: `panes.switchScope(to:)` / `switchScope(to:adoptingFrom:)` when the window activates a layout
    scope (`activateLayout`), and `.initial` when an org switch lands where there is no project
    (`putAwayCanvas`). No switch forgets a scope.

  The window then reads everything back: `refreshPanes()` walks `LayoutStore`'s panes and asks
  `PaneStore.snapshot(paneId:kind:)` for each, filling `tables` and `editables` and each pane's
  `PaneSnapshotCell` in `paneCells`. This is the same store `read_pane` answers the agent from
  (`PaneStore.readPane(paneId:kind:)`).
  *Convention*; no test enforces it.
- **One agent per place** (`App/PlaceAgent.swift`): `WindowModel.agents` holds a `PlaceAgent` per
  `Place` — its harness, session, thread, turn, conversation (`lineageRoot`) and `Bash` mirror —
  and keeps each alive while the screen shows another place. The window's `thoughts`,
  `turnInFlight`, `sessionId`, `sessionStarted` and `lineageRoot` read the on-screen place's
  entry (`currentAgent`). Each entry's event pump writes to that entry, and mirrors into that
  place's canvas, wherever the screen is. An agent's `session_resume` names its place
  (`ResumeRequest.place`), so the fork replaces that place's session. A place has at most one
  agent, and `resume` reads and records as that agent (a caller carrying `agent.sessionId ??
  agent.assignedSessionId`), so an agent with no session yet still reaches its own place's store.
- **One waiting approval per place** (`ConfirmationBroker`, `Gate/ConfirmationBroker.swift`): the
  broker keys what it parks by `Place` and refuses a second in the same place (`.busy`).
  `WindowModel.parkedProposals` mirrors it; `pending` is the on-screen place's entry and the plane
  draws only that, while `waitingPlaces` marks the others. An agent's proposal never expires: it
  waits until the operator approves or cancels it (Rule 4). Only a UI-origin proposal times out.
- **It starts a harness per session** through `harnessFactory`: first turn, every resume, every
  provider switch. A stopped `ClaudeCodeCLIHarness` is spent.
- **It runs the pumps** that consume the harness's events, confirmations, resumes, provider switches
  and terminal runs. `shutdown()` cancels them all (`ShutdownContractTests`).

## An agent's calls follow its own place

An agent session is pinned to the place (organisation, project registry key, environment) it
started in. Each session has its own socket, at `agentSocketPath` (`wakil-<agent session id>.sock`
in the per-user temporary directory: the directory plus 48 bytes, so a directory of up to 55
characters fits `sun_path`'s 104), whose caller is that place with the session's id. **A place's
socket opens when the place is shown**, at launch and on every switch, before any turn
(`WindowModel.openShownSocket`, from `activateLayout`; after an org switch lands, not during it).
It reserves the session id the place's first session then starts with, and that session takes the
socket (`makeSession`); once per place, never per visit, and never one that follows the screen. A
resume or provider switch starts its fork's or fresh session's own socket before the harness and
stops the one it replaces. The harness's MCP config names the session's socket; it is stopped after
the harness on a resume, a provider switch and shutdown; an org, project or environment switch
stops none of them. A socket that will not start
does not refuse the session: the session tries once more, then runs without Wakil's own tools and
its status says why. Every call the
session makes acts there, wherever the screen is:

- **The task-local.** `ActionRegistry.dispatch` binds `ActionRegistry.dispatchCaller` around every
  handler, so anything a handler calls can ask whom the dispatch is for without a parameter
  (Invariant 5: the agent's tool schemas name no project or environment).
- **Who is calling decides.** `pinnedPlace(of:)` (`Core/Place.swift`) is the one rule everything
  below asks: a caller with a session and a complete place (organisation and project set) is an
  agent, answered for its own place even while the screen shows that same place. A caller without
  a session — the operator's own dispatches — takes the window's path whatever place it carries.
  Never a comparison with the screen: `setProject` and `switchEnvironment` rewrite `active.json`
  before the window's `place` moves, so in between an agent on the old place would compare equal
  while the window's clients already answer for the new one.
- **The pool.** Every handler `build` registers reaches Go through a `PlaceRoutedCaller`. An agent
  caller goes to `PlaceClients`: one lazily started client per (binary, place), each its own
  process under `pinnedEnvironment` (`WAKIL_ORG`, `WAKIL_PROJECT`, `WAKIL_ENVIRONMENT`,
  `WAKIL_IN_WINDOW=1`, and the launch's `WAKIL_PROVIDER` only in the launch's org). A window
  client is never re-pointed for an agent (Invariant 4). After `stopAll` the pool starts nothing.
- **The window-side readers.** `term_open`, the api pane, and the git and editor actions' roots read
  `WindowModel.shellContext(forCaller:)` and `gitRootPaths(forCaller:)`. An agent caller gets its
  own place and its own project's roots, read by `PlaceContexts` through the pool's `wakil-ctx`
  and kept per place. If the read fails, it gets no roots, never the window's. `EditorFileLists`
  keeps the window's listings only: an agent's `files_list` is read fresh through the pool.
- **The gate.** `dispatch` asks the window's production lookup (`setProductionLookup`) for the
  caller first: an agent is priced by its own project's declarations, or by the name rule
  (`.undeclared`) if they cannot be read. Never by the screen's.
- **The window's path.** The operator's dispatches, an incomplete place, or no caller at all (a
  read the window makes itself) take the window's own clients, roots and flags. `--dispatch`
  dispatches with no session, so nothing routes.

`WindowModel` retains every place with a live agent (`agentPlaces`) in `PlaceContexts` and
`PlaceClients` whenever a harness changes, and the pool stops the clients of places no session
holds any more.

**A switch tears nothing down.** Changing organisation, project or environment moves the screen
and re-reads the new place; it stops no agent, socket, pump, shell or waiting approval and discards
no canvas (flow 3). What a switch does touch is the operator's own db reads in the organisation
left (`PaneStore.cancelOperatorDBReads`), which went out on the window's clients.

**Writes follow the place too.** The window installs `setScopeLookup`: an agent caller's dispatch
is bound (`ScopeRouting.home`) to its `PlaceAgent.layoutScope`, so its panes land in its own
place's canvas. Every other dispatch is bound to the scope on screen when it began
(`setScreenScope`), so a reply after a switch still lands where it was asked. After each dispatch
the window writes any off-screen agent's changed arrangement to that place's file.

## Where binaries are found

`WakilWiring.binaryURL(named:executableDirectory:environment:)`, three layouts in order:

1. **`WAKIL_BIN_DIR/<name>`**, when the variable is set. **Exclusive**: if the binary is not there,
   the answer is `nil`, with no fallback. Set-but-empty means no binaries.
2. **`<executable dir>/../Resources/<name>`** — the app bundle's `Contents/Resources`, where
   `scripts/make-app-bundle.sh` copies every Go binary.
3. **`<checkout root>/bin/<name>`** — the nearest ancestor of the executable's directory holding a
   `go.mod` or `app/Package.swift`. Only that one `bin/` is tried.

`notFoundDiagnostic` says which paths were tried.

## The child environment

`WakilWiring.childProcessEnvironment(from:org:provider:)` builds the Go children's environment key
by key, never passing the parent's through:

- `HOME` and `PATH` from the launching environment.
- `WAKIL_IN_WINDOW=1`, always (`wakil-http`'s `send` requires it).
- `WAKIL_ORG` and `WAKIL_PROVIDER` when given and non-empty (parameters, because the window can change
  them mid-session).
- `WAKIL_KEYCHAIN` when set in the launching environment (forwarded: fixed for the process's life).

`AppWiringTests` pins the exact key sets. The agent's servers get `WAKIL_ORG` and `WAKIL_PROVIDER`
from `agentMCPConfigJSON`. The `claude` process itself gets `CLAUDE_CONFIG_DIR`,
`CLAUDE_CODE_OAUTH_TOKEN`, `HOME` and `PATH` (`buildLaunch` in `Harness/ClaudeCodeCLIHarness.swift`).

## Lifetimes

| Thing | Born | Dies |
|---|---|---|
| The four Wakil-owned `MCPClient`s | `WakilWiring.build` | `WakilWiring.shutdown`; restarted in place by `switchOrg` |
| Pool clients (`PlaceClients`) | an agent's first call for its place | `retain` when no session holds the place; `WakilWiring.shutdown` |
| `PlaceAgent`, one per place | the place's first turn, pane or resume | `WindowModel.shutdown` (a switch never drops it) |
| `MCPSocketServer`, one per agent session | `WindowModel`, when its place is first shown (a resume's or provider switch's: before its harness) | after that harness stops: next harness, `WindowModel.shutdown` for every place's agent and every shown place's socket |
| `ClaudeCodeCLIHarness` (and the shim and agent servers `claude` spawns) | `WindowModel` on a session start, resume or provider switch | `harness.stop()`: next harness, `WindowModel.shutdown` |
| Terminal PTYs (`TerminalStore`) | `term_open` | `pane_close`, shutdown (`shutdownAll()`) |
| Pane contents (`PaneStore`), arrangements (`LayoutStore`) | first write | the window (no switch forgets a scope); arrangements also persist to disk |

**Shutdown order** (`WindowSession.shutdown`): `model.shutdown()` (every place's event pump and the
window's pumps cancelled, then every agent's harness stopped and then its socket, then every
shown place's socket no session took, then terminals
closed; `quittingStopsEveryPlacesAgent`, `ShutdownContractTests`) → `wiring.shutdown()`. Each `claude` child, and the
shim it spawned, is gone before the socket the shim connects to is closed. `--dispatch` calls
`wiring.shutdown()` before it exits.
