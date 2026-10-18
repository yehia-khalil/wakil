# Background agents, Plan 1 of 4: the agent's own processes keep its place, and the journal says where

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An agent's own MCP servers resolve against the place its session started in, not the
place on screen. The agent can no longer switch project or environment itself. Every journal
entry records its organisation, project and environment, and the agent session that caused it.

**Architecture:** `wakilcore` gains a *pinned place*: when `WAKIL_PROJECT` / `WAKIL_ENVIRONMENT`
are set, `ReadActive` overlays them on `active.json`, and a pinned process refuses to change
them. The window launches each session's agent-facing servers (`agentFacingServers`) with the
place on screen at launch, so they stay put when the operator moves. In Swift, a `Place` value
replaces the bare `environment: String` that `ActionRegistry.dispatch` and `MCPSocketServer`
pass around. It carries the triple into `JournalEntry`, together with the session id.
`ctx_set_project` / `ctx_set_environment` become operator-only.

The window's own binaries (paths 2 and 4 in the spec), the per-place state and the chips belong to
Plans 2–4. After this plan, a project or environment switch still retargets the agent's *Wakil
actions* (through the shim). It no longer retargets the agent's own `wakil-pm`, `wakil-recall` and
`wakil-git`.

**Tech Stack:** Go 1.27 (`internal/wakilcore`, `cmd/wakil-ctx`), Swift 6 / Swift Testing
(WakilKit).

**Spec:** `docs/superpowers/specs/2026-10-16-background-agents-design.md`, *Pinning* paths 3 and
the agent's own context-switch actions; *The journal*.

**The four plans:**
1. This one: pinned processes, `Place`, journal fields, agent context switches refused.
2. The window's binaries and handlers resolve against the calling agent's place (spec paths 1,
   2 and 4, including the write gate).
3. Per-place state: the agent table, stores kept alive, the switches stop tearing down, and the
   environment joins the layout scope.
4. The chips, and the charter, design-language and glossary amendments (Decision 41).

Plans 2–4 are written once the plan before them has landed, because each one names code the
previous plan creates.

## Global Constraints

- A place is an (organization, project, environment) triple; *absent means unset, never the
  empty string* (the rule `childProcessEnvironment` and `terminalChildEnvironment` already
  hold).
- `WAKIL_PROJECT` holds a project **name** (the registry key, as the terminal already exports
  it). `active.json`'s `project` field stays a project.json **path**.
- The window's own children (`WakilWiring.childProcessEnvironment`) must **not** get
  `WAKIL_PROJECT` / `WAKIL_ENVIRONMENT`. They follow the place on screen until Plan 2.
- Agent-facing tool schemas grow no project or environment argument (amended Invariant 5).
- Invariant 4: a pinned project must still pass `Resolve()`'s `proj.Org == CurrentOrg()` check.
  Pinning never bypasses it.
- Old journal lines (no `organization`/`project`/`session` keys) must still decode.
- Commits carry no `Co-Authored-By` or "Generated with" lines.
- One unit of work per PR, stacked, as `CONTRIBUTING.md` says.

## Review Focus

1. **A pinned project that isn't registered, or that belongs to another org.** Expected: `Resolve`
   fails whole, naming the pinned value. It never falls back to `active.json`, because a silent
   fallback is the very retarget this plan removes. *(Task 1, `TestReadActivePinnedUnknownProjectFails`
   and `TestResolvePinnedProjectOtherOrgRefused`.)*
2. **`WAKIL_PROJECT=""`.** Expected: treated as unset. *(Task 1,
   `TestReadActiveEmptyPinIsUnset`.)*
3. **Journal lines written before this change.** Expected: they decode, with the new fields nil.
   *(Task 3, `journalEntryDecodesALineWithoutPlaceFields`.)*
4. **A terminal pane's shell.** It already exports `WAKIL_PROJECT` / `WAKIL_ENVIRONMENT`, so a
   `wakil` command run there now resolves against the pane's place, not against `active.json`.
   Expected: this is the spec's intent. *(Task 1's tests cover the Go side. Note it in the PR
   body.)*
5. **The agent asks to switch environment.** Expected: denied with a reason that says its place
   is fixed and that the operator can start an agent in the other place. It is not a
   production-confirmation plane. *(Task 4,
   `theAgentCannotMoveItsOwnPlace`.)*

---

### Task 1: `wakilcore` honours a pinned place

**Files:**
- Modify: `internal/wakilcore/active.go` (`ReadActive`, new `PinnedPlace`)
- Modify: `internal/wakilcore/resolve.go:180-218` (`SetProjectChecked`)
- Modify: `cmd/wakil-ctx/main.go:52-67` (`setEnvironment`)
- Test: `internal/wakilcore/active_test.go`, `cmd/wakil-ctx/main_test.go`

**Interfaces:**
- Produces: `func PinnedPlace() (project string, environment string)`. Each value is the
  variable's content, or `""` when it is unset or empty.
- Produces: `ReadActive()`. When `WAKIL_PROJECT` is set, `Project` is the registry's path for that
  name. When `WAKIL_ENVIRONMENT` is set, `Environment` is that value. `Provider` always comes from
  the file.
- Produces: the error text `"this process's place is pinned to <project>/<environment> — it cannot
  switch project or environment"`. `SetProjectChecked` and `wakil-ctx`'s `setEnvironment` return
  it, as a `UserError`, when the axis they write is pinned.

- [ ] **Step 1: Write the failing tests** in `active_test.go`, using `mkOrgDir` and the registry
  helpers the existing tests use:
  - `TestReadActivePinnedProjectOverridesFile`: `active.json` says project A, env `staging`.
    `WAKIL_PROJECT=b` and `WAKIL_ENVIRONMENT=local` are set. Expect `ReadActive()` to return
    B's registered path, `local`, and the file's `Provider`.
  - `TestReadActivePinnedEnvironmentOnly`: only `WAKIL_ENVIRONMENT` is set. Expect the project
    from the file and the environment from the variable.
  - `TestReadActiveEmptyPinIsUnset`: `WAKIL_PROJECT=""`. Expect the file's project.
  - `TestReadActivePinnedUnknownProjectFails`: `WAKIL_PROJECT=nope`. Expect an error containing
    `"nope"` and `"not registered"`.
  - `TestResolvePinnedProjectOtherOrgRefused`: the pinned project's project.json declares another
    org. Expect `Resolve()` to fail with the existing "belongs to org" error.
  - `TestSetProjectCheckedRefusedWhenPinned`: `WAKIL_PROJECT` is set. Expect `SetProjectChecked("a")`
    to return an error containing `"pinned"`, and `active.json` to be unchanged.
  - In `cmd/wakil-ctx/main_test.go`, `TestSetEnvironmentRefusedWhenPinned`: the same, for
    `setEnvironment`.

- [ ] **Step 2: Run them and see them fail**

  Run: `go test ./internal/wakilcore ./cmd/wakil-ctx -run 'Pinned|EmptyPin'`
  Expected: FAIL. `PinnedPlace` is undefined, or the assertions show the file's values.

- [ ] **Step 3: Implement.** `ReadActive` reads the file as it does today, then applies
  `PinnedPlace()`. The project name goes through `LoadRegistry()`. A missing name returns
  `UserError("pinned project %q is not registered in this org")`. `SetProjectChecked` checks for a
  pinned project before it writes. `setEnvironment` checks for either pin before it writes, because
  a pinned project with an unpinned environment still belongs to an agent's fixed place.
  `WriteActive` is unchanged: the provider write (`setActiveProvider`) must keep working in any
  process.

- [ ] **Step 4: Run the Go suite**

  Run: `make test`
  Expected: PASS, docs-check included.

- [ ] **Step 5: Commit**

  ```bash
  git add internal/wakilcore/active.go internal/wakilcore/resolve.go internal/wakilcore/active_test.go cmd/wakil-ctx/main.go cmd/wakil-ctx/main_test.go
  git commit -m "wakilcore: honour a pinned place from WAKIL_PROJECT/WAKIL_ENVIRONMENT"
  ```

### Task 2: a session's agent-facing servers launch pinned to its place

**Files:**
- Create: `app/Sources/WakilKit/Core/Place.swift`
- Modify: `app/Sources/WakilKit/App/AgentMCPConfig.swift:36-70` (`agentMCPConfigJSON`)
- Modify: `app/Sources/WakilKit/App/WindowModel.swift:461,785,867` (`harnessFactory`'s type) and
  `:6145-6160` (`startHarness`)
- Modify: `app/Sources/WakilApp/WindowSession.swift:182-199` (the factory closure), and every
  test that builds a `harnessFactory`
- Test: `app/Tests/WakilKitTests/WindowModelTests.swift` (beside the existing
  `agentMCPConfigJSON` tests at ~2066–2290)

**Interfaces:**
- Produces: `public struct Place: Sendable, Hashable, Codable { public let organization: String;
  public let project: String; public let environment: String }` with a memberwise `public init`.
  Plans 2–4 key everything on it.
- Produces: `agentMCPConfigJSON(shimExecutable:socketPath:binaries:place:provider:) -> String`.
  `place: Place?` replaces `organization: String?`, and an empty member is not exported.
- Produces: `harnessFactory: @Sendable (Place, ProviderSelection) -> AgentHarness?`.
- Produces: `WindowModel.place: Place`, a computed property built from `organization`, `project`
  and `environment`.

- [ ] **Step 1: Write the failing tests**
  - `agentConfigPinsEveryServerToThePlace`: build the config with
    `Place(organization: "initech", project: "api", environment: "staging")`. Expect the shim and
    every `agentFacingServers` entry to have `WAKIL_ORG=initech`, `WAKIL_PROJECT=api` and
    `WAKIL_ENVIRONMENT=staging`.
  - `agentConfigOmitsEmptyPlaceMembers`: a `Place` with an empty environment. Expect no
    `WAKIL_ENVIRONMENT` key at all.
  - `harnessIsBuiltForThePlaceOnScreenAtSend`: a `WindowModel` with a recording factory, in
    initech/api/staging. Expect the factory to receive exactly that `Place` when the first `send`
    starts the harness.
  - Update the existing `agentMCPConfigJSON` tests to the new parameter, keeping their
    assertions.

- [ ] **Step 2: Run them and see them fail**

  Run: `cd app && swift test --filter 'agentConfig|harnessIsBuiltForThePlace'`
  Expected: the build fails, because `Place` and the `place:` parameter don't exist yet.

- [ ] **Step 3: Implement.** Add `Place`. Change `agentMCPConfigJSON` and the factory type.
  `startHarness` passes `place`. In `WindowSession` the closure passes `place` through to
  `agentMCPConfigJSON`. Don't touch `childProcessEnvironment`.

- [ ] **Step 4: Run the Swift suite**

  Run: `make app-test`
  Expected: PASS.

- [ ] **Step 5: Commit**

  ```bash
  git add app/Sources/WakilKit/Core/Place.swift app/Sources/WakilKit/App/AgentMCPConfig.swift app/Sources/WakilKit/App/WindowModel.swift app/Sources/WakilApp/WindowSession.swift app/Tests/WakilKitTests
  git commit -m "Agent: launch a session's own servers pinned to the place it started in"
  ```

### Task 3: dispatch carries a place and a session, and the journal records both

**Files:**
- Modify: `app/Sources/WakilKit/Registry/Journal.swift:35-75` (`JournalEntry`)
- Modify: `app/Sources/WakilKit/Registry/ActionRegistry.swift:182-240,541-560` (`dispatch`,
  `appendJournalEntry`, and the other `appendJournalEntry` callers at 332–426)
- Modify: `app/Sources/WakilKit/MCP/MCPServer.swift`, renaming every `environment: @Sendable ()
  async -> String` (lines ~206, 608, 765, 1061–1083, 1157, 1240–1247) to
  `caller: @Sendable () async -> DispatchCaller`
- Modify: `app/Sources/WakilKit/App/WindowModel.swift`, at every `registry.dispatch(` call (1158,
  4469, 4876, and the `dispatch` helper they go through)
- Modify: `app/Sources/WakilApp/WindowSession.swift:367`
- Test: a new `app/Tests/WakilKitTests/JournalPlaceTests.swift`, plus updated call sites in
  `ActionRegistryTests`, `MCPServerTests`, `WriteGateTests` and the others the compiler names

**Interfaces:**
- Consumes: `Place` (Task 2).
- Produces: `public struct DispatchCaller: Sendable { public let place: Place; public let session:
  String? }` in `Core/Place.swift`.
- Produces: `ActionRegistry.dispatch(name:params:origin:caller:confirmation:)`. `caller:
  DispatchCaller` replaces `environment: String`. The gate reads `caller.place.environment`, so its
  behaviour doesn't change.
- Produces: `JournalEntry` gains `organization: String?`, `project: String?` and `session:
  String?`. `environment` keeps its name and position.
- Produces: `MCPSocketServer(surface:socketPath:caller:)`.
- Produces: `WindowModel.agentCaller: DispatchCaller`, which is `place` with `sessionId`. UI
  dispatches pass `DispatchCaller(place: place, session: nil)`.

- [ ] **Step 1: Write the failing tests** in `JournalPlaceTests.swift`:
  - `journalRecordsTheCallersPlaceAndSession`: dispatch a registered read with `caller =
    DispatchCaller(place: Place(organization: "initech", project: "api", environment: "staging"),
    session: "s-1")`. Expect the journal line to decode with those four values.
  - `operatorDispatchRecordsNoSession`: the same with `session: nil`. Expect `session == nil` and
    the place fields set.
  - `journalEntryDecodesALineWithoutPlaceFields`: decode a literal pre-change line
    (`{"id":"x","ts":…,"action":"db_run_query","params":{},"origin":"ui","environment":"staging","outcome":"ok"}`).
    Expect `organization`, `project` and `session` to be nil.
  - `socketDispatchJournalsTheAgentCaller`: in `MCPServerTests`, a `tools/call` through a server
    whose `caller` returns session `"s-2"`. Expect the journal line to carry `"s-2"` and `origin
    == .agent`.

- [ ] **Step 2: Run them and see them fail**

  Run: `cd app && swift test --filter 'JournalPlaceTests|socketDispatchJournalsTheAgentCaller'`
  Expected: the build fails, because `DispatchCaller` and the `caller:` parameter don't exist yet.

- [ ] **Step 3: Implement** the signature change all the way through. This is mechanical apart
  from one point. The server reads `caller()` twice for a parked request, before and after the
  park, just as it reads `environmentProvider` today. Keep that, because the operator can move
  between the two reads. `journalTerminalRun` passes the place the run happened in, which is
  `activeShellContext`'s triple.

- [ ] **Step 4: Run the Swift suite**

  Run: `make app-test`
  Expected: PASS.

- [ ] **Step 5: Commit**

  ```bash
  git add app/Sources/WakilKit app/Sources/WakilApp/WindowSession.swift app/Tests/WakilKitTests
  git commit -m "Journal: record each dispatch's organisation, project and session"
  ```

### Task 4: the agent cannot switch its own place

**Files:**
- Modify: `app/Sources/WakilKit/Registry/StandardActions.swift`, making the `ctx_set_project` and
  `ctx_set_environment` declarations (~375–410) `audience: .operatorOnly`
- Modify: `app/Sources/WakilKit/MCP/PermissionPrompt.swift:91-100` (`operatorOnlyActions`) and
  `operatorOnlyDenialMessage` (~211)
- Modify: `app/Sources/WakilKit/Harness/AgentInstructions.swift:35-45` (rule 4)
- Test: `app/Tests/WakilKitTests/PermissionPromptTests.swift`; `ActionClassificationTests` (which
  pins audience and the set to agree); and any agent-origin `ctx_set_environment` test in
  `MCPServerTests` (~886–970) or `WriteGateTests` that assumed the agent could switch

**Interfaces:**
- Produces: the denial text for both names: `"An agent's place is fixed when its session starts
  (Invariant 5). Tell the operator which place the work needs; they can start an agent there."`

- [ ] **Step 1: Write the failing test** `theAgentCannotMoveItsOwnPlace`. For each of
  `ctx_set_project` and `ctx_set_environment`, expect `permissionDecision` to return `.deny`, with
  a reason containing `"place is fixed"` and not containing `"confirm"`. Also expect
  `agentAllowedTools` to leave both names out.

- [ ] **Step 2: Run it and see it fail**

  Run: `cd app && swift test --filter 'theAgentCannotMoveItsOwnPlace|ActionClassification'`
  Expected: FAIL, with `.allow`.

- [ ] **Step 3: Implement.** Change the audience, the set, and the denial case. Rewrite rule 4 so
  it reads: *Your place — organisation, project, environment — is fixed when your session
  starts. You cannot switch it. If the work needs another place, say so and let the operator
  start an agent there.* Drop the sentences about production being held and about nothing
  blocking a project switch. Then fix or delete the tests that relied on an agent switching:
  the production-switch confirmation tests stay for **UI-origin** switches.

- [ ] **Step 4: Run the Swift suite**

  Run: `make app-test`
  Expected: PASS.

- [ ] **Step 5: Commit**

  ```bash
  git add app/Sources/WakilKit app/Tests/WakilKitTests
  git commit -m "Agent: refuse the agent's own project and environment switches"
  ```

### After Task 4

Hand the branch to the e2e auditor (`docs/agents/e2e.md`). The checks it owes:
- An agent session starts in place A, the operator switches to B, and a `wakil-git` or `wakil-pm`
  call from the agent still answers for A.
- A retrodiction patch that strips `WAKIL_PROJECT` from the agent config must turn that check
  red.
