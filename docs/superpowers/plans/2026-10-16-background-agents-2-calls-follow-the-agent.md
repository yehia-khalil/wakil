# Background agents, Plan 2 of 4: an agent's calls resolve against its own place

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every call an agent makes through Wakil's own actions — database, API, git, files,
context, terminal open, the write gate — resolves against the place its session started in,
whatever the operator has moved the screen to.

**Architecture:** The window remembers the session's place when it starts the harness
(`agentPlace`), and the socket's caller uses it. Handlers keep calling the same `ToolCaller` they
captured today, but each captured client is now a `PlaceRoutedCaller`. It reads the dispatch's
`ActionRegistry.dispatchCaller` task-local, which Plan 1 binds around every handler. When the
caller's place is the place on screen (or is incomplete), it forwards to the window's own
client, which behaves exactly as today. Otherwise it forwards to a pinned client from a
per-place pool, `PlaceClients`. Pool clients are started with
`WAKIL_ORG`/`WAKIL_PROJECT`/`WAKIL_ENVIRONMENT`, so Plan 1's Go pin does the rest.

The same task-local makes the window-side readers place-aware: `ActiveShellContext`,
`GitRootsSource`, and the gate's production flags. Off-screen places are resolved from the
pinned `wakil-ctx`'s `get_context`, cached per place in `PlaceContexts`.

**Plan 2 does not** touch pane, layout or terminal stores, the confirmation broker or the switches
(Plan 3), or the UI (Plan 4). A window still runs one agent. Plan 3 generalises `agentPlace` to
one per place.

**Tech Stack:** Swift 6 / Swift Testing (WakilKit). No Go changes.

**Spec:** `docs/superpowers/specs/2026-10-16-background-agents-design.md`, *Pinning* paths 1, 2
and 4. Plan 1 (`docs/superpowers/plans/2026-10-16-background-agents-1-pinned-processes.md`) is
on the branch below this one.

## Global Constraints

- A place is `Place(organization:project:environment:)`, where `project` is the **registry key**.
  It is *complete* when organization and project are non-empty. An incomplete caller place
  always routes to the window's own clients: a session started with no project follows the
  operator until Plan 3 (Plan 1's ruling).
- **Invariant 4 stays structural.** A pool client for org A is its own process with `WAKIL_ORG=A`,
  built by `WakilWiring.childProcessEnvironment` plus the two pins. It is never a window client
  re-pointed, and a window client is never re-pointed for an agent.
- **Same place, same path.** A caller whose place equals the place on screen must reach the
  window's existing clients and the window's `environmentProduction`, so every existing test keeps
  its meaning.
- The agent-facing tool schemas grow no project or environment argument (Invariant 5).
- Pool clients carry `WAKIL_IN_WINDOW=1` like the window's own, because they are the window's
  children. `wakil-http` mutations depend on it.
- Commits carry no `Co-Authored-By` or "Generated with" lines. Run `make shaders build` before
  `make app-test` in a fresh worktree.

## Review Focus

1. **The agent and the operator in the same place.** Expected: no pool client is started, and the
   call goes to the window's client. *(Task 2,
   `aCallerOnTheScreensPlaceUsesTheWindowsClient`.)*
2. **An agent in org A while the screen shows org B.** Expected: its database call goes to a pool
   client whose environment says `WAKIL_ORG=A`, and the window's clients are never re-pointed.
   *(Task 2, `anOffScreenCallerGetsAPinnedClientForItsOwnOrg`.)*
3. **A mutation parked for confirmation while the operator switches.** Expected: it is judged
   after the park against the agent's place, not the new screen. *(Task 1,
   `aParkedAgentMutationIsJudgedInTheAgentsPlace`.)*
4. **An agent in production while the screen shows staging.** Expected: the gate prices its write
   as production. *(Task 3, `theGateUsesTheAgentsPlacesProductionFlags`.)*
5. **The harness replaced** (resume, a provider switch, or an org switch that clears it).
   Expected: pool clients for places no live session uses are stopped, so nothing leaks a
   process. *(Task 2, `retainStopsClientsForPlacesNoLongerInUse`, and Task 1's wiring.)*

---

### Task 1: the window remembers the session's place, and the socket uses it

**Files:**
- Modify: `app/Sources/WakilKit/App/WindowModel.swift`: `agentCaller` (:46); where a harness
  is committed, which is `send` (:6265/:6291), `resume` (:6527), `setProvider` (:6804) and
  `invalidateForOrgChange` (:1966)
- Test: `app/Tests/WakilKitTests/WindowModelTests.swift`, `app/Tests/WakilKitTests/MCPServerTests.swift`

**Interfaces:**
- Produces: `WindowModel.agentPlace: Place?` (`private(set)`). It is the `Place` the factory was
  called with for the live session, set in the same statement block that commits `harness` and
  `sessionId`, and `nil` wherever they are cleared.
- Produces: `WindowModel.agentCaller` is `DispatchCaller(place: agentPlace ?? place, session:
  sessionId)`.

- [ ] **Step 1: Write the failing tests**
  - `theAgentCallerKeepsTheSessionsPlaceAcrossAProjectSwitch` (WindowModelTests): send in
    initech/api/staging, then `setProject("billing")`. Expect `agentCaller.place == Place(
    organization: "initech", project: "api", environment: "staging")`, while `place.project ==
    "billing"`.
  - `aResumedSessionTakesThePlaceOnScreenAtResume`: the `resume` path sets `agentPlace` to the
    place it passed the factory.
  - `anOrgSwitchClearsTheAgentPlace`: after `setOrganization`, `agentPlace == nil`.
  - `aParkedAgentMutationIsJudgedInTheAgentsPlace` (MCPServerTests): a server whose `caller`
    returns a model-like box. The agent's place is staging, and the screen moves to production
    while the call is parked. Expect the post-park dispatch to journal `environment ==
    "staging"`. This pins that the socket reads the *agent's* place twice, not the screen's.

- [ ] **Step 2: Run them and see them fail**

  Run: `cd app && swift test --filter 'theAgentCallerKeeps|aResumedSessionTakes|anOrgSwitchClearsTheAgentPlace|aParkedAgentMutationIsJudgedInTheAgentsPlace'`
  Expected: FAIL. `agentPlace` doesn't exist, or the place follows the screen.

- [ ] **Step 3: Implement.** Commit `agentPlace` beside `harness` at each site, using the same
  `place` value the factory call received (capture it in a local before the factory call).

- [ ] **Step 4: Run the Swift suite**

  Run: `make app-test`
  Expected: PASS.

- [ ] **Step 5: Commit**

  ```bash
  git add app/Sources/WakilKit/App/WindowModel.swift app/Tests/WakilKitTests
  git commit -m "Agent: the socket's caller is the session's own place, not the screen's"
  ```

### Task 2: a pinned client pool, and handlers that route through it

**Files:**
- Create: `app/Sources/WakilKit/App/PlaceClients.swift` (`PlaceClients`, `ClientRole`,
  `PlaceRoutedCaller`)
- Modify: `app/Sources/WakilKit/App/AppWiring.swift`. `build` (:265–368) wraps each client
  handed to a `register*` function. `stopAll`/shutdown also stops the pool. Add an `exported
  pinnedEnvironment(for:)` beside `childProcessEnvironment` (:609).
- Modify: `app/Sources/WakilKit/App/WindowModel.swift`. After each `agentPlace` change, call
  `placeClients.retain(Set([agentPlace].compactMap { $0 }))`.
- Test: create `app/Tests/WakilKitTests/PlaceClientsTests.swift`

**Interfaces:**
- Consumes: `Place`, `DispatchCaller`, `ActionRegistry.dispatchCaller` (Plan 1);
  `WindowModel.agentPlace` (Task 1).
- Produces: `enum ClientRole: String, Sendable, CaseIterable { case context = "wakil-ctx",
  database = "wakil-db", http = "wakil-http", git = "wakil-git", files = "wakil-files" }`.
- Produces: `actor PlaceClients`, with:
  - `init(start: @escaping @Sendable (ClientRole, Place) async throws -> any ToolCaller,
    stop: @escaping @Sendable (any ToolCaller) async -> Void)`
  - `func client(_ role: ClientRole, for place: Place) async throws -> any ToolCaller`, which
    starts the client lazily, at most one per (role, place), even under concurrent first calls
  - `func retain(_ places: Set<Place>) async`, which stops and forgets every client whose place
    is not in the set
  - `func stopAll() async`
- Produces: `struct PlaceRoutedCaller: ToolCaller`, `init(role: ClientRole, window: any
  ToolCaller, pool: PlaceClients, screen: @escaping @Sendable () async -> Place)`. `callTool`
  forwards to `window` unless `ActionRegistry.dispatchCaller?.place` is complete and differs from
  `await screen()`. In that case it forwards to `try await pool.client(role, for: place)`.
- Produces: `WakilWiring.pinnedEnvironment(for place: Place, from: [String: String], provider:
  String?) -> [String: String]`, which is `childProcessEnvironment(from:org: place.organization,
  provider:)` plus `WAKIL_PROJECT` and `WAKIL_ENVIRONMENT`, with an empty member omitted.
- Produces: `WakilWiring.placeClients: PlaceClients`, and the screen-place closure installed by
  `useActiveContext(of:)` (so it reads `model.place`).

- [ ] **Step 1: Write the failing tests** in `PlaceClientsTests.swift`, using `RecordingToolCaller`
  (`ToolCallerTests.swift:10`) and a recording `start` closure:
  - `aCallerOnTheScreensPlaceUsesTheWindowsClient`: bind `ActionRegistry.$dispatchCaller` to the
    screen's place, and `callTool` through a `PlaceRoutedCaller`. Expect the window recorder to
    have one call and `start` never called.
  - `noCallerUsesTheWindowsClient`: no task-local bound, so the window client is used.
  - `anIncompleteCallerPlaceUsesTheWindowsClient`: `Place(organization: "initech", project: "",
    environment: "")`, so the window client is used.
  - `anOffScreenCallerGetsAPinnedClientForItsOwnOrg`: the caller is
    initech/api/staging and the screen is umbrella/web/prod. Expect `start` called once with
    `(.database, that place)` and the pool recorder to receive the call.
  - `concurrentFirstCallsStartOneClient`: 10 concurrent calls for the same (role, place) give
    exactly one `start`.
  - `retainStopsClientsForPlacesNoLongerInUse`: start clients for two places, `retain([first])`.
    Expect `stop` called for the second only, and a later call for the second starts a fresh one.
  - `pinnedEnvironmentCarriesTheWholePlaceAndTheWindowMarker` (pure): `WAKIL_ORG`,
    `WAKIL_PROJECT`, `WAKIL_ENVIRONMENT` and `WAKIL_IN_WINDOW == "1"`. An empty environment
    member is omitted.

- [ ] **Step 2: Run them and see them fail**

  Run: `cd app && swift test --filter PlaceClientsTests`
  Expected: the build fails, because `PlaceClients` doesn't exist yet.

- [ ] **Step 3: Implement.** The pool stores `[Key: Task<any ToolCaller, Error>]`, so concurrent
  first calls share one start. In `build`, `start` makes an `MCPClient` for the role's binary with
  `pinnedEnvironment` and `start()`s it, and `stop` calls `stop()` on it. Every `register*` call
  that takes a client gets a `PlaceRoutedCaller` over the window's client instead: ctx, db, http,
  git, and files (both `filesClient` and the `EditorFileLists` it wraps, so route the client
  inside it). `switchOrg` still re-points only the window's own clients.

- [ ] **Step 4: Run the Swift suite**

  Run: `make app-test`
  Expected: PASS.

- [ ] **Step 5: Commit**

  ```bash
  git add app/Sources/WakilKit/App app/Tests/WakilKitTests/PlaceClientsTests.swift
  git commit -m "Wiring: an off-screen caller's calls go to clients pinned to its own place"
  ```

### Task 3: window-side readers and the gate follow the caller's place

**Files:**
- Create: `app/Sources/WakilKit/App/PlaceContexts.swift`
- Modify: `app/Sources/WakilKit/App/AppWiring.swift`. `useActiveContext(of:)` (:214–222) makes the
  shell-context and git-roots closures caller-aware.
- Modify: `app/Sources/WakilKit/Registry/ActionRegistry.swift`. `dispatch` (:182–202) takes
  production from a lookup for the caller's place.
- Modify: `app/Sources/WakilKit/App/WindowModel.swift`. Install the lookup, and call
  `placeContexts.retain` beside `placeClients.retain`.
- Modify: `docs/architecture/runtime.md`. Describe the routing (the pool, the task-local, and the
  on-screen fallback) where the agent path is described.
- Test: create `app/Tests/WakilKitTests/PlaceContextsTests.swift`, and add to `WriteGateTests.swift`
  or `ProductionDeclarationTests.swift`

**Interfaces:**
- Consumes: `PlaceClients.client(.context, for:)` (Task 2) and `ContextStore(client:).current() ->
  ContextStore.ActiveContext` (`Context/ContextStore.swift:216`), which carries `rootPaths` and
  `environmentProduction`.
- Produces: `actor PlaceContexts`, with:
  - `init(clients: PlaceClients)`
  - `func context(for place: Place) async throws -> ContextStore.ActiveContext`, cached per
    place
  - `func retain(_ places: Set<Place>)`
- Produces: `ActionRegistry.setProductionLookup(_ lookup: @escaping @Sendable (Place) async ->
  EnvironmentProduction?)`. `dispatch` uses `await lookup(caller.place) ?? environmentProduction`.
  The window's lookup returns `nil` for the screen's place or an incomplete one (the window's own
  flags apply). For an off-screen place it returns the cached context's `environmentProduction`,
  or `EnvironmentProduction.undeclared` if resolving failed. Never `nil` there, because that
  would let the screen's declarations judge another project.
- Produces: `WindowModel.shellContext(forCaller:)` and `gitRootPaths(forCaller:)`. Each takes
  `Place?` and returns the same shape as `activeShellContext` / `gitRootPaths`. An off-screen
  complete place gives `(place.organization, place.project, place.environment,
  rootPaths.first ?? rootPath)` and the context's `rootPaths`. Anything else gives the existing
  values. `useActiveContext` passes `ActionRegistry.dispatchCaller?.place`.

- [ ] **Step 1: Write the failing tests**
  - `anOffScreenCallerSeesItsOwnRoots` (PlaceContextsTests, with a `GitRootsContext`-style fake
    as the pool's ctx client): bind the caller to api while the screen is billing. Expect
    `gitRoots.current()` to return api's roots.
  - `anOffScreenCallersTerminalOpensInItsOwnPlace`: through the wiring's `shellContext`, `current()`
    returns the caller's org, project and environment, and api's first root.
  - `theScreensCallerSeesTheWindowsValues`: same place as the screen, so the existing values are
    returned and the pool's ctx is never called.
  - `theGateUsesTheAgentsPlacesProductionFlags`: the screen is staging (not production), and
    the agent's place resolves with `environmentProduction` declaring its environment
    production. A `mutate`-kind agent dispatch must come back `.gate`/`.block` as production
    does, where the same dispatch from the screen's place is allowed.
  - `aFailedResolveFallsBackToTheNameRule`: the off-screen place's `get_context` throws, and the
    screen's flags declare `production` *not* production. An agent mutation in an environment
    named `production` is still priced as production, by the name rule over `.undeclared`.

- [ ] **Step 2: Run them and see them fail**

  Run: `cd app && swift test --filter 'PlaceContextsTests|theGateUsesTheAgentsPlacesProductionFlags|aFailedResolveFallsBack'`
  Expected: the build fails or the assertions fail, showing the screen's values.

- [ ] **Step 3: Implement.** `PlaceContexts` caches successes only, so a failed resolve is retried
  on the next call.

- [ ] **Step 4: Run the Swift suite**

  Run: `make app-test`
  Expected: PASS.

- [ ] **Step 5: Commit**

  ```bash
  git add app/Sources/WakilKit app/Tests/WakilKitTests docs/architecture/runtime.md
  git commit -m "Gate and readers: an off-screen caller's roots, shell context and production flags are its own place's"
  ```

### After Task 3

The e2e auditor (`docs/agents/e2e.md`) owes these checks:
- An agent session starts in place A, the operator switches project to B, and the agent's
  `db_run_query` returns A's rows.
- A retrodiction that makes `PlaceRoutedCaller` always forward to the window client must turn
  that check red.
