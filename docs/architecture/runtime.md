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
  `GitRootsSource` the `GitStatus` and the editor's git actions read at the live `WindowModel`. Both are read on every call, never captured.
- **`switchOrg(to:)`** — stops and restarts every Wakil-owned client in place under the new org,
  with `provider: nil`. In place, because the action handlers captured these client instances.
- **`shutdown()`** — stops the root watcher, every Wakil-owned client, and every terminal.

## `WindowSession.start`

1. Picks a session id (a UUID) and the journal directory `~/.wakil/journal` (from `HOME`).
2. Calls `WakilWiring.build`; its `diagnostics` become the window's `notes`.
3. Chooses the socket path: `wakil-<sessionId>.sock` in the per-user temporary directory.
4. Reads the active context once through `ContextStore` for the first project root and the active
   provider id.
5. Locates the `wakil` CLI and builds three factories: `lookupFactory` (per org,
   `WakilCLICredentialsLookup`), `mintFactory` (`WakilCLIProviderMint`), and `harnessFactory`. The
   harness factory builds, per selection, `agentMCPConfigJSON` (the shim plus `agentFacingServers`)
   and a `ClaudeCodeCLIHarness` with `agentAllowedTools` computed from the registry. If the `wakil`
   binary is missing, the window opens with no agent and a note says why.
6. Creates the `WindowModel`, handing it the wiring's registry, stores, brokers, vocabulary, root
   watcher and palette clients, a `LayoutPersistence` under `~/.wakil/layouts`, the factories, and
   `orgSwitcher: { wiring.switchOrg(to:) }`.
7. Calls `wiring.useActiveContext(of: model)` and creates the `ComposerModel`.
8. Creates and starts `MCPSocketServer(surface: wiring.mcpSurface, socketPath:,
   environmentProvider: { model.environment })`. A socket that will not bind becomes a note.

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
    scope (`activateLayout`), and `panes.clearAllScopes()` in `invalidateForOrgChange()`.

  The window then reads everything back: `refreshPanes()` walks `LayoutStore`'s panes and asks
  `PaneStore.snapshot(paneId:kind:)` for each, filling `tables` and `editables` and each pane's
  `PaneSnapshotCell` in `paneCells`. This is the same store `read_pane` answers the agent from
  (`PaneStore.readPane(paneId:kind:)`).
  *Convention*; no test enforces it.
- **It starts a harness per session** through `harnessFactory`: first turn, every resume, every
  provider switch. A stopped `ClaudeCodeCLIHarness` is spent.
- **It runs the pumps** that consume the harness's events, confirmations, resumes, provider switches
  and terminal runs. `shutdown()` cancels them all (`ShutdownContractTests`).

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
| `MCPSocketServer` | `WindowSession.start` | `WindowSession.shutdown` |
| `ClaudeCodeCLIHarness` (and the shim and agent servers `claude` spawns) | `WindowModel` on a session start, resume or provider switch | `harness.stop()`: org switch, next harness, `WindowModel.shutdown` |
| Terminal PTYs (`TerminalStore`) | `term_open` | `pane_close`, an org switch (`shutdownAll(runStream: .keepOpen)`), shutdown (`.finish`) |
| Pane contents (`PaneStore`), arrangements (`LayoutStore`) | first write | `clearAllScopes()` on an org switch; arrangements also persist to disk |

**Shutdown order** (`WindowSession.shutdown`): `model.shutdown()` (pumps cancelled, harness stopped,
terminals closed) → `socketServer.stop()` → `wiring.shutdown()`. The `claude` child, and the shim it
spawned, is gone before the socket the shim connects to is closed. `--dispatch` calls
`wiring.shutdown()` before it exits.
