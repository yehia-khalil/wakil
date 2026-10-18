# Background agents, Plan 3 of 4: one agent per place, kept alive while the operator is elsewhere

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A window keeps one agent per place, each with its own thread, canvas, socket and waiting
approval. Every place the operator leaves stays alive in memory, and a switch of organisation,
project or environment never stops, holds or tears down any of it. Quitting stops every agent.

**Architecture:**
- **Places own their state.** The window's single-agent fields move into `PlaceAgent`, one per
  `Place`, held in `WindowModel.agents`. The window's existing properties (`thoughts`,
  `turnInFlight`, `pending`, `sessionStarted`, …) become reads of the **on-screen place's** entry,
  so the views barely change.
- **Writes go to the caller's own scope.** A dispatch's writes land in the caller's own scope
  through a second task-local, `ScopeRouting.home`, bound in `ActionRegistry.dispatch` beside
  Plan 1's `dispatchCaller`. `LayoutStore` and `PaneStore` read it before their on-screen `scope`.
  Terminal sessions remember their home scope.
- **The environment is part of the scope.** `LayoutScope` gains the environment and uses the
  project's registry key. Layout files move to per-environment paths, and the old file is still
  read as a fallback.
- **Each agent has its own socket and approval.** Each agent gets its own `MCPSocketServer`, and
  the confirmation broker holds one parked proposal per place.
- **Org switches stop tearing down.** They no longer queue, ask, refuse or clear. Only org-bound
  state is re-derived: settings, accounts, `lookup`, the palette, the window's clients and
  capacity.

**Tech Stack:** Swift 6 / Swift Testing (WakilKit; WakilApp only where views read a renamed
property). No Go changes.

**Spec:** `docs/superpowers/specs/2026-10-16-background-agents-design.md`: *Each place stays
alive*, *The switches*, *Layout scope and the environment*, *Quit*, *Errors and edges*. Plans 1–2
are on the branches below this one.

## Global Constraints

- **The place is the key.** `Place(organization:project:environment:)`, with `project` = the
  **registry key** (Plan 1). A place has at most one agent.
- **Rulings carried into this plan** (recorded in the ledger):
  - **R1 (operator, 2026-10-16: "it waits"):** an *agent's* parked proposal never expires; it
    waits until the operator approves or cancels it (Rule 4). A UI-origin proposal keeps today's
    timeout.
  - **R2:** the org switch's unsaved-tabs prompt is **removed**, because nothing is discarded any
    more. The spec says "unchanged" in one section and "removed" in another, and removal follows
    from "every place stays alive". The quit prompt stays.
  - **R3 (migration):** a layout file written before this plan (no environment in its path) is
    read as the seed for **every** environment of that project that has no file of its own.
    Nothing is deleted or rewritten. New writes go to the per-environment path. Rollback is
    reverting the branch, since the old files are untouched.
  - **R4:** background git and editor watchers are **not** added. A background place's git and
    editor panes catch up when the operator returns (`restorePaneContents` on return). The spec
    promises nothing is stopped, not that hidden panes refresh live.
- **Unchanged behaviour.** Operator dispatches (`session == nil`) target the on-screen scope
  exactly as today.
- **Interaction Rules.**
  - Rule 6: nothing moves the operator. A background `pane_focus` never takes the keyboard.
  - Rule 1: switching away asks nothing.
  - Rule 4: a waiting agent's plane keeps Cancel.
  - Rule 5: a working agent still shows in its own place's thread and Core.
- Commits carry no `Co-Authored-By` or "Generated with" lines. Run `make shaders build` before
  `make app-test` in a fresh worktree. If a full run hangs, first run `sample` on the
  `swiftpm-testing-helper` pid and save it to `.scratch/background-work/`, then kill it, run
  `rm -rf app/.build`, and rerun.
- Every new `WindowModel` property is classified in `InvalidationContractTests`.

## Review Focus

1. **A background agent opens a pane.** Expected: it lands in the agent's place's canvas, the
   screen's canvas is unchanged, and no focus moves. *(Task 2,
   `aBackgroundAgentsPaneLandsInItsOwnCanvas`.)*
2. **Two agents in two places each park a write.** Expected: both wait, neither is `.busy`, and
   each place's plane shows only its own. *(Task 5,
   `twoPlacesEachHoldTheirOwnParkedProposal`.)*
3. **An org switch while an agent works.** Expected: no queue, no prompt, no refusal. The agent
   keeps streaming into its own thread, and its shell keeps running. *(Task 6,
   `anOrgSwitchLeavesTheRunningAgentAlone`.)*
4. **An existing user's saved layout.** Expected: after upgrade, every environment of that
   project opens the old arrangement until it saves its own. *(Task 1,
   `aLegacyProjectFileSeedsEveryEnvironment`.)*
5. **Quit with three agents running.** Expected: all three harnesses are stopped and all their
   sockets closed. *(Task 7, `quittingStopsEveryPlacesAgent`.)*

---

### Task 1: the environment joins the layout scope

**Files:**
- Modify: `app/Sources/WakilKit/Core/LayoutScope.swift`. Add `environment`, and build `projectSeed`
  and `.initial` with it.
- Modify: `app/Sources/WakilKit/App/WindowModel.swift`.
  - `activateLayout` (~:2204): build the scope from `projectKey` and `environment`. Today it uses
    the display name `project`.
  - `switchEnvironment` (~:2423) and the observation pump's environment branch (~:1063–1079):
    switching environment activates that environment's scope instead of refetching the current
    one.
- Modify: `app/Sources/WakilKit/Layout/LayoutPersistence.swift` (~:235–242). Paths become
  `org/[conversations/<root>/]<projectKey>@<environment>.json`, with the R3 fallback read.
- Test: `LayoutPersistenceTests.swift`, `WindowModelTests.swift` (the D11 group at ~:4441–7148), and
  `ApiEnvironmentTests.swift`

**Interfaces:**
- Produces: `LayoutScope(organization: String, project: String, environment: String, lineageRoot:
  String? = nil)`. `project` is the registry key.
- Produces: `LayoutPersistence` reads `<key>@<env>.json`. If that is absent, it reads the legacy
  `<name>.json` and then `<key>.json`. It writes only `<key>@<env>.json`.

- [ ] **Step 1: Write the failing tests**
  - `twoEnvironmentsOfOneProjectKeepTwoCanvases`: open a db pane in staging, switch to
    production. Expect production to show its own canvas (empty or seeded), and switching back to
    show staging's pane with its rows untouched (no refetch).
  - `aLegacyProjectFileSeedsEveryEnvironment`: a pre-existing `api.json` (no environment) is
    loaded for staging and for production, each into its own scope. A save in staging writes
    `api@staging.json`, and `api.json` is unchanged on disk.
  - `theScopeIsKeyedByRegistryKeyNotDisplayName`: the registry key is `api` and the name is
    `API Service`, so the path uses `api`.
  - Rewrite the D11 tests whose premise was "the same canvas refetches". Replace them with "the
    environment's own canvas appears, and API replies never cross environments". Delete none
    silently: each changed test's name and intent goes in your report.

- [ ] **Step 2: Run them and see them fail**

  Run: `cd app && swift test --filter 'twoEnvironmentsOfOneProject|aLegacyProjectFileSeeds|theScopeIsKeyedByRegistryKey'`
  Expected: the build fails (no `environment:`) or the assertions fail.

- [ ] **Step 3: Implement.** The legacy fallback is read-only, and the file stays on disk.

- [ ] **Step 4: Run the Swift suite**

  Run: `make app-test`
  Expected: PASS.

- [ ] **Step 5: Commit** with the message `Layout: the environment joins the scope; a legacy project file seeds every environment`.

### Task 2: a dispatch's writes land in its caller's own scope

**Files:**
- Modify: `app/Sources/WakilKit/Core/LayoutScope.swift`. Add `enum ScopeRouting { @TaskLocal static
  var home: LayoutScope? }`.
- Modify: `app/Sources/WakilKit/Registry/ActionRegistry.swift`. `dispatch` binds `ScopeRouting.$home`
  from `scopeLookup(caller)` around the handler, next to `$dispatchCaller`. Add
  `setScopeLookup(_:)`.
- Modify: `app/Sources/WakilKit/Layout/LayoutStore.swift` and `app/Sources/WakilKit/Panes/PaneStore.swift`
  (and the `+Api`/`+Editor`/`+Terminal`/`+Git` extensions, through the shared `panes` accessor).
  Every implicit-current-scope read or write uses `ScopeRouting.home ?? scope`.
  `LayoutStore.focusRequests` emits nothing when `home` is set and differs from `scope`.
- Modify: `app/Sources/WakilKit/Panes/PaneStore.swift`. Add `cancelDBReads(in scope:)`. Make
  `WindowModel.activateLayout` and `restorePaneContents` cancel only the outgoing or target
  scope, not every scope.
- Modify: `app/Sources/WakilKit/Terminal/TerminalStore.swift`. Each session records the home scope
  it was opened in (`ScopeRouting.home ?? panes.activeScope`), and `publish` writes through
  `panes.inScope(home)`. Also modify `app/Sources/WakilKit/Terminal/TerminalMirror.swift`:
  `pump`/`backfill` take the target scope.
- Test: create `app/Tests/WakilKitTests/ScopeRoutingTests.swift`

**Interfaces:**
- Consumes: `ActionRegistry.dispatchCaller`, `pinnedPlace(of:)` (Plan 2), and `LayoutScope` with
  the environment (Task 1).
- Produces: `ActionRegistry.setScopeLookup(_ lookup: @escaping @Sendable (DispatchCaller) async ->
  LayoutScope?)`. A nil return means the on-screen scope.
- Produces: `ScopeRouting.home`, and `PaneStore.cancelDBReads(in:)`.
- The window installs the lookup in Task 3, using the agent's scope. Until then, tests install
  their own.

- [ ] **Step 1: Write the failing tests**
  - `aBackgroundAgentsPaneLandsInItsOwnCanvas`: with the lookup returning scope B while the
    screen is A, `pane_open` and `db_run_query` through the registry. Expect the pane and its rows
    in B, A's snapshot unchanged, and no focus request emitted.
  - `anOperatorDispatchStillTargetsTheScreen`: `session == nil`, so the writes go to A as today.
  - `aBackgroundShellsOutputStaysInItsOwnScope`: a terminal opened with home B, then the screen
    switches to A. Its published blocks land in B's pane store.
  - `swappingScopesCancelsOnlyThatScopesReads`: a read in flight in B survives activating A.

- [ ] **Step 2: Run them and see them fail**

  Run: `cd app && swift test --filter ScopeRoutingTests`
  Expected: the build fails or the assertions fail.

- [ ] **Step 3: Implement.** Keep `PaneStore.inScope` as the synchronous form, and have both share
  one resolved-scope accessor.

- [ ] **Step 4: Run the Swift suite**

  Run: `make app-test`
  Expected: PASS.

- [ ] **Step 5: Commit** with the message `Stores: a dispatch writes into its caller's own scope; background shells publish home`.

### Task 3: one agent per place

**Files:**
- Create: `app/Sources/WakilKit/App/PlaceAgent.swift`
- Modify: `app/Sources/WakilKit/App/WindowModel.swift`:
  - the per-agent fields listed under Interfaces move into `PlaceAgent`
  - `send`, `resume`, `setProvider`, `startEventPump`, `markSessionStarted`, `enterConversation`
    and `retainAgentPlace` act on the on-screen place's entry
  - `agentCaller` becomes per entry
  - install the Task 2 scope lookup and the Plan 2 production lookup per agent
- Modify: `app/Sources/WakilKit/Harness/ResumeBroker.swift`. `ResumeRequest` carries the caller's
  `Place`, so an agent's `session_resume` acts on its own place.
- Modify: the WakilApp views that read the renamed properties, only where a property stops
  being directly settable.
- Test: create `app/Tests/WakilKitTests/PlaceAgentTests.swift`, and update `InvalidationContractTests.swift`

**Interfaces:**
- Produces: `@MainActor final class PlaceAgent`. It holds `place: Place`, `harness:
  AgentHarness?`, `sessionId: String?`, `thoughts: [ThoughtRow]`, `nextThoughtId`, `turnInFlight:
  Bool`, `mirror: TerminalMirrorFeed`, `eventPump: Task<Void, Never>?`, `eventPumpGeneration`,
  `lineageRoot: String?`, `assignedSessionId: String?`, `sessionStarted: Bool`, `providerId:
  String`, `caller: DispatchCaller`, and `layoutScope: LayoutScope?`.
- Produces: `WindowModel.agents: [Place: PlaceAgent]` (`private(set)`) and `WindowModel.currentAgent:
  PlaceAgent?` (the entry for `place`). `thoughts`, `turnInFlight`, `sessionId`, `sessionStarted`,
  `lineageRoot` and `coreState` read `currentAgent`, falling back to empty values.
- Produces: `WindowModel.agentPlaces: Set<Place>`, the keys of entries with a live harness. It is
  passed to `placeClients.retain` and `placeContexts.retain`.
- The event pump captures its `PlaceAgent`. `append`, `mirror.pump` (into the agent's
  `layoutScope`) and the `.result` handling write to that entry, wherever the screen is.

- [ ] **Step 1: Write the failing tests**
  - `twoPlacesRunTwoAgentsAtOnce`: send in A, switch to B, send in B. Expect two harnesses
    started with two different `Place`s, both live, and `agents.count == 2`.
  - `aBackgroundAgentsEventsLandInItsOwnThread`: a scripted harness in A emits events while the
    screen shows B. Expect A's `thoughts` to grow, B's not to, and A's `turnInFlight` to clear on
    `.result`.
  - `returningToAPlaceShowsItsThreadAndAgent`: switch back to A, so `thoughts` and `sessionId` are
    A's.
  - `sendingInAPlaceWithAnAgentTalksToIt`: a second send in A goes to A's harness, and no new
    harness starts.
  - `anAgentsResumeActsOnItsOwnPlace`: a `session_resume` from A's agent while B is on screen
    replaces A's session, and B is untouched.

- [ ] **Step 2: Run them and see them fail**

  Run: `cd app && swift test --filter PlaceAgentTests`
  Expected: the build fails.

- [ ] **Step 3: Implement.** Keep the window's public API names, so the WakilApp churn stays
  small.

- [ ] **Step 4: Run the Swift suite**

  Run: `make app-test`
  Expected: PASS.

- [ ] **Step 5: Commit** with the message `Agents: one per place, each with its own thread, turn and session`.

### Task 4: each agent has its own socket

**Files:**
- Modify: `app/Sources/WakilApp/WindowSession.swift` (~:70, ~:181–197, ~:363–371, and shutdown).
  Add a per-agent socket server factory, so that `harnessFactory` receives the agent's socket path.
- Modify: `app/Sources/WakilKit/App/WindowModel.swift` and `PlaceAgent.swift`. Each entry owns a socket
  handle started before its harness and stopped when the entry's harness is dropped.
- Test: `app/Tests/WakilKitTests/PlaceAgentTests.swift`, `app/Tests/WakilKitTests/MCPServerTests.swift`

**Interfaces:**
- Produces: `harnessFactory: @Sendable (Place, ProviderSelection, String /* socketPath */) ->
  AgentHarness?`.
- Produces: an injected `agentSocketFactory: @Sendable (String /* path */, @escaping @Sendable ()
  async -> DispatchCaller) async throws -> AgentSocket` with `stop() async`. The real one builds
  `MCPSocketServer(surface:socketPath:caller:)`, and tests record the calls.
- The socket path is `<tmp>/wakil-<windowSessionId>-<agentSessionId-prefix>.sock`, kept under the
  unix socket path limit (104 bytes). The test asserts the length.

- [ ] **Step 1: Write the failing tests**
  - `twoAgentsGetTwoSocketsEachAnsweringForItsOwnPlace`: two agents, so two factory calls with
    different paths, and each `caller` returns its own place and session.
  - `droppingAnAgentStopsItsSocket`: a resume replaces A's session, so A's old socket is stopped
    and a new one started.
  - `theSocketPathFitsTheUnixLimit`.

- [ ] **Step 2: Run them and see them fail**

  Run: `cd app && swift test --filter 'twoAgentsGetTwoSockets|droppingAnAgentStopsItsSocket|theSocketPathFits'`
  Expected: the build fails.

- [ ] **Step 3: Implement.** Remove the window-wide `MCPSocketServer` (one per agent replaces it).

- [ ] **Step 4: Run the Swift suite**

  Run: `make app-test`
  Expected: PASS.

- [ ] **Step 5: Commit** with the message `Agents: each session answers on its own socket`.

### Task 5: one waiting approval per place

**Files:**
- Modify: `app/Sources/WakilKit/Gate/ConfirmationBroker.swift`, `app/Sources/WakilKit/Gate/PendingMutation.swift`
- Modify: `app/Sources/WakilKit/MCP/MCPServer.swift` (`parkForConfirmation` passes the caller's
  place), and `app/Sources/WakilKit/App/WindowModel.swift`: `parkAndAwait` passes `place`;
  `confirmationPump` keeps `[Place: PendingMutation]`; `pending` reads the on-screen place's
  entry; approve and cancel address the proposal's place.
- Test: `app/Tests/WakilKitTests/ConfirmationBrokerTests.swift`

**Interfaces:**
- Produces: `PendingMutation.place: Place`.
- Produces: `ConfirmationBroker.request(_ proposal: PendingMutation) async -> Outcome`, keyed by
  `proposal.place`, so it is `.busy` only for a second proposal **in the same place**. Also
  `current(for place: Place) -> PendingMutation?`, `all() -> [Place: PendingMutation]`,
  `updates() -> AsyncStream<[Place: PendingMutation]>`, `approve(id:)`, and `cancel(id:)`.
- R1: a proposal with `origin == .agent` has no timeout. A `.ui` proposal keeps `defaultTimeout`.
- Produces: `WindowModel.waitingPlaces: Set<Place>`, places with a parked proposal, for Plan 4's
  chips.

- [ ] **Step 1: Write the failing tests**
  - `twoPlacesEachHoldTheirOwnParkedProposal`: two agent proposals in A and B. Neither is
    `.busy`, `all()` has both, and approving A resolves only A.
  - `aSecondProposalInTheSamePlaceIsStillRefused`: keeps today's guarantee for each place.
  - `anAgentsProposalWaitsPastTheOldTimeout`: run with a short `defaultTimeout`. An agent proposal
    is still parked after it, and a UI proposal expires as before.
  - `thePlaneShowsOnlyTheScreensPlace`: `pending` reflects the on-screen place, and switching
    place shows the other one's proposal.

- [ ] **Step 2: Run them and see them fail**

  Run: `cd app && swift test --filter ConfirmationBrokerTests`
  Expected: the build fails or the assertions fail.

- [ ] **Step 3: Implement.**

- [ ] **Step 4: Run the Swift suite**

  Run: `make app-test`
  Expected: PASS.

- [ ] **Step 5: Commit** with the message `Gate: one waiting approval per place; an agent's waits until the operator answers`.

### Task 6: switches stop tearing down

**Files:**
- Modify: `app/Sources/WakilKit/App/WindowModel.swift`:
  - `setOrganization` (~:7009) drops the refusal on a parked confirmation, `harness?.stop()` and
    the generation bump.
  - `invalidateForOrgChange` (~:1908–2130) keeps only the genuinely org-bound resets: settings,
    accounts, login, `lookup`, palette, vocabulary, the window clients (through `orgSwitcher`),
    capacity, and the gate's on-screen production flags, which `refreshContext` re-derives.
    It drops everything else: thread, harness, mirror, pending, lineage, `clearAllScopes` on both
    stores, `cancelAllDBReads`, `terminals.shutdownAll`, editor buffers and autosave, and tables
    and databases. Those are now per scope or per agent, or re-read by `refreshContext`.
  - Delete `queuedOrgSwitch`, `cancelQueuedSwitch`, `stopTurnAndSwitchNow`,
    `fireQueuedSwitchIfReady`, `performOrganisationSwitch`'s queue branch, `firingQueuedSwitch`,
    `queuedSwitchCancellationCount`, `unsavedSwitchApproved`, and `send`'s queued-switch refusal.
  - R2: `requestOrganizationSwitch` no longer asks about unsaved tabs.
- Modify: the WakilApp views that drew the queued-switch affordance.
- Modify: `InvalidationContractTests.swift`, re-classifying what now survives an org switch, and
  `OrgSwitchTests.swift` / `WindowModelUnsavedTests.swift`. Rewrite or delete the
  queue/refusal/teardown tests listed in the plan's source map, naming each in your report with
  what replaced it.
- Test: `app/Tests/WakilKitTests/OrgSwitchTests.swift`

**Interfaces:**
- Consumes: `PlaceAgent`/`agents` (Task 3), the per-place broker (Task 5), and per-scope stores
  (Task 2).
- Produces: an org switch is `setOrganization(org)`, which runs the org-bound resets, then
  `orgSwitcher`, then `refreshContext`. It never stops a harness, a shell or a read.

- [ ] **Step 1: Write the failing tests**
  - `anOrgSwitchLeavesTheRunningAgentAlone`: a turn is in flight in initech/api/staging, then
    `requestOrganizationSwitch("umbrella")`. Expect no queue, the switch done at once, the
    initech agent's harness not stopped, its events still landing in its own thread, and its
    shell still running.
  - `anOrgSwitchWithAParkedApprovalSwitchesAnyway`: initech's proposal stays parked, and
    switching back shows it.
  - `anOrgSwitchWithUnsavedTabsAsksNothingAndKeepsThem`: switch away and back, and the buffers
    are intact and still dirty.
  - `comingBackToAnOrgFindsItsCanvasAsLeft`: panes and rows untouched, with no refetch.

- [ ] **Step 2: Run them and see them fail**

  Run: `cd app && swift test --filter 'anOrgSwitchLeaves|anOrgSwitchWithAParked|anOrgSwitchWithUnsaved|comingBackToAnOrg'`
  Expected: FAIL.

- [ ] **Step 3: Implement.** Delete the dead code. Don't leave it unreachable.

- [ ] **Step 4: Run the Swift suite**

  Run: `make app-test`
  Expected: PASS.

- [ ] **Step 5: Commit** with the message `Switches: changing organisation, project or environment never stops, holds or discards anything`.

### Task 7: quit stops every agent

**Files:**
- Modify: `app/Sources/WakilKit/App/WindowModel.swift` `shutdown()` (~:8397): stop every
  `PlaceAgent`'s harness, pump and socket, and keep `terminals.shutdownAll(.finish)`.
- Modify: `docs/architecture/runtime.md` and `flows.md`: the per-place agent table, scope routing,
  sockets per agent, the per-place broker, and the switch with no teardown.
- Test: `ShutdownContractTests.swift`

- [ ] **Step 1: Write the failing test** `quittingStopsEveryPlacesAgent`: three agents in three
  places, then `shutdown()`. Expect all three harnesses stopped, all three sockets stopped, and
  every pump cancelled.

- [ ] **Step 2: Run it and see it fail**

  Run: `cd app && swift test --filter quittingStopsEveryPlacesAgent`
  Expected: FAIL. Only the current agent is stopped.

- [ ] **Step 3: Implement.**

- [ ] **Step 4: Run the Swift suite**

  Run: `make app-test`
  Expected: PASS.

- [ ] **Step 5: Commit** with the message `Quit: stop every place's agent`.

### After Task 7

The e2e auditor (`docs/agents/e2e.md`) owes these checks:
- Start an agent in place A, switch org, start an agent in B, and return to A. A's thread shows
  its work, and the journal has both agents' entries.
- Plus the retrodiction "a switch retargets a running agent", which the spec's Testing section
  names.
