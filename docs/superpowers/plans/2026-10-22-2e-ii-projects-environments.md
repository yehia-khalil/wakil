# 2e-ii: projects and environments from Settings — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add, rename and remove a project and an environment from the Settings pane, through
six operator-only actions backed by one Go writer per file.

**Architecture:** Go `internal/wakilcore` gets six lifecycle writers that work on
`project.json`, `projects.json` and `active.json`. `wakil-ctx` exposes each one as a tool, and
WakilKit registers six `.control`, operator-only `ctx_*` actions over those tools. The window
gets six methods that dispatch the actions, refresh, and move layout files. The Settings pane
turns its two dimmed rows into live buttons and adds Name fields and Remove buttons.

**Tech Stack:** Go (`internal/wakilcore`, `cmd/wakil-ctx`, go-sdk MCP); Swift 6 / SwiftUI
(WakilKit, WakilApp); the e2e harness (`e2e/checks/seeded/*.jsonl`).

**Spec:** `docs/superpowers/specs/2026-10-22-2e-ii-projects-environments-design.md`

## Global Constraints

- Read-modify-write from disk at dispatch, never a flush of cached pane state (Decision 21).
  Every project.json write goes through `SaveProject`.
- All six actions are `kind: .control` and `audience: .operatorOnly`, and are listed in
  `operatorOnlyActions` (Decision 30). They have no price.
- No new `wakil` CLI verbs.
- A name is refused when it is empty after trimming, contains `/`, or is already used in its
  scope (org for projects, project for environments). The refusal names the clash.
- A refusal is a `UserError` whose text is shown whole under the field. The field keeps what was
  typed (Rules 2, 7, 8).
- No dialog for any of the six (Rule 1). The only modal is the macOS folder picker the operator
  opens.
- Trash copy name: `project.json (before removing <env> HH:MM)`. If the Trash fails, nothing is
  removed.
- Default new environment name: `new-environment`, then `new-environment-2`, `-3`, … for the
  first free one.
- Rename and remove are refused while an agent runs in that project or environment. The text is
  `<agent> is running in <project>[ / <env>] — an agent keeps its own place (Invariant 5); stop
  it first`.
- Accessibility identifiers:
  - `settings.tree.addProject` and `settings.tree.project.<p>.addEnvironment`;
  - `settings.project.name`, `settings.environment.name`, `settings.project.remove` and
    `settings.environment.remove`.
- Every commit message has no `Co-Authored-By` trailer and no "Generated with" line.

## Review Focus

1. **Renaming a project whose folder holds a hand-edited project.json with a key this build
   doesn't know:** the key drops, as `SaveProject` documents. The rename must keep every
   *known* key, roots and environments included. This is pinned in Task 1.
2. **Removing the active environment while panes are open in it:** the window moves to the first
   remaining environment and shows its layout. Nothing crashes on the old scope. This is pinned
   in Task 5.
3. **Renaming the active project:** the place line and the switcher show the new name, and
   `active.json` still resolves, because it stores the path and not the name. Pinned in Task 1
   (Go) and Task 5 (window).
4. **Adding a folder that is already registered, under a different name:** refused, with the
   registered name shown. No second row appears. Pinned in Task 1.
5. **Typing a name and switching to another tree node without pressing Return:** the name is
   saved on blur, as the Git fields are. A refused name stays in the field with its error.
   Pinned in Task 7's `2e-ii-name-refusals` check.

---

### Task 1: Go — project lifecycle writers

**Files:**
- Create: `internal/wakilcore/projectlife.go`
- Test: `internal/wakilcore/projectlife_test.go`

**Interfaces:**
- Consumes: `LoadProject`, `SaveProject`, `LoadRegistryFor`, `SaveRegistry`, `ReadActiveUnpinned`,
  `WriteActive`, `CurrentOrg`, `UserError` (all existing).
- Produces:
  - `func CreateProject(folder, name string) (ProjectEntry, error)`. `folder` is absolute.
    The org is `CurrentOrg()`.
  - `func RenameProject(old, new string) error`
  - `func RemoveProject(name string) error`
  - `func ValidName(name string) (string, error)`, which trims and refuses an empty name or one
    with `/`. Task 2 uses it too.

- [ ] **Step 1: Write the failing tests** in `projectlife_test.go`, using the temp-HOME setup
  the existing `registry_test.go` uses:
  - `TestCreateProjectWritesFileAndRow`: an empty folder gets `.wakil/project.json` with name,
    org and roots `[{path: folder}]`, and the registry has `name → {path: <folder>/.wakil/project.json}`.
  - `TestCreateProjectAdoptsExistingFile`: an existing file with environments keeps them
    byte-for-byte equal after loading, and only the registry row is added.
  - `TestCreateProjectRefusesOtherOrg`: a file with `org: "other"` → error containing `"other"`
    and `Invariant 4`, and no row.
  - `TestCreateProjectRefusesRegisteredFolder`: the same folder added twice under different
    names → the error names the first name.
  - `TestCreateProjectRefusesNameClash`, `TestValidNameRefusesEmptyAndSlash`.
  - `TestRenameProjectRewritesFileAndKey`: roots, environments and editor survive, the registry
    key changes, and the old key is gone.
  - `TestRenameProjectRestoresRegistryOnFileFailure`: make project.json read-only → error, and
    the registry and file are unchanged.
  - `TestRenameActiveProjectStillResolves`: `ReadActiveUnpinned().Project` equals the same path
    after the rename.
  - `TestRemoveProjectKeepsFile`: the row is gone and project.json still exists.
  - `TestRemoveActiveProjectPicksFirstRemaining`: with projects `a` (active) and `b`, removing
    `a` makes `active.Project` `b`'s path. Removing the last project leaves `Project == ""`.

- [ ] **Step 2: Run** `go test ./internal/wakilcore -run 'Project(Life|)|ValidName|CreateProject|RenameProject|RemoveProject'`
  Expected: FAIL (undefined functions).

- [ ] **Step 3: Implement** the four functions in `projectlife.go`.
  - `RenameProject` writes project.json first, then the registry. If the registry write fails,
    it writes the old project.json back.
  - Active updates use `ReadActiveUnpinned`/`WriteActive`. "First remaining" is the first by
    sorted registry key.

- [ ] **Step 4: Run** the Step 2 command. Expected: PASS. Then `go test ./internal/wakilcore`
  passes.

- [ ] **Step 5: Commit** `git add internal/wakilcore/projectlife*.go && git commit -m "wakilcore: create, rename and remove a project — one writer per file, the folder's project.json adopted as it is"`

### Task 2: Go — environment lifecycle writers

**Files:**
- Create: `internal/wakilcore/envlife.go`
- Test: `internal/wakilcore/envlife_test.go`
- Modify: `internal/wakilcore/fileops.go` only if a shared helper for running `trashBin` is
  needed. Reuse the existing `trashBin` variable so tests can stub it.

**Interfaces:**
- Consumes: `ValidName` (Task 1), `LoadProject`, `SaveProject`, `ReadActiveUnpinned`,
  `WriteActive`, `trashBin`.
- Produces:
  - `func CreateEnvironment(projectPath string) (string, error)`, which returns the minted name.
  - `func RenameEnvironment(projectPath, old, new string) error`
  - `func RemoveEnvironment(projectPath, name string, now time.Time) (trashed string, err error)`,
    where `trashed` is the copy's file name.

- [ ] **Step 1: Write the failing tests:**
  - `TestCreateEnvironmentMintsFirstFreeName`: an empty map gives `new-environment`. With that
    taken, `new-environment-2`. It has empty databases and API entries.
  - `TestRenameEnvironmentKeepsContents`: databases (refs unchanged, e.g.
    `db:p:staging:orders`), api and production survive under the new key.
  - `TestRenameEnvironmentRefusesClashAndInvalid`.
  - `TestRenameActiveEnvironmentFollows`: `active.Environment` becomes the new name when the
    active project is this one.
  - `TestRemoveEnvironmentTrashesCopyFirst`: stub `trashBin` with a script that records its
    argument. The recorded file's name is
    `project.json (before removing staging 14:02)`, its content equals the pre-removal file,
    and the key is gone afterwards.
  - `TestRemoveEnvironmentTrashFailureRemovesNothing`: the stub exits 1 → error, and the key is
    still there.
  - `TestRemoveActiveEnvironmentPicksFirstRemaining`: sorted first, or `""` when none remain.
  - Each refuses a project whose `org` isn't the current one, with the message
    `RemoveDatabase` uses.

- [ ] **Step 2: Run** `go test ./internal/wakilcore -run Environment` → FAIL.

- [ ] **Step 3: Implement** the functions in `envlife.go`. Write the copy into
  `os.MkdirTemp`, then run `trashBin` on it. The `HH:MM` is formatted from `now` in local time.

- [ ] **Step 4: Run** the Step 2 command, then `go test ./internal/wakilcore` → PASS.

- [ ] **Step 5: Commit** `git commit -m "wakilcore: create, rename and remove an environment — removal puts a copy of project.json in the Trash first"`

### Task 3: wakil-ctx — six tools

**Files:**
- Modify: `cmd/wakil-ctx/main.go` (args structs near `removeDatabaseArgs` :235; tools after
  `remove_database` :704)
- Test: `cmd/wakil-ctx/schema_test.go`, `cmd/wakil-ctx/main_test.go`

**Interfaces:**
- Consumes: Tasks 1 and 2.
- Produces these MCP tools (params in camelCase):
  - `create_project {folder, name}` → `{name, path}`
  - `rename_project {name, newName}`
  - `remove_project {name}`
  - `create_environment {projectPath}` → `{name}`
  - `rename_environment {projectPath, name, newName}`
  - `remove_environment {projectPath, name}` → `{trashed}`
  - Errors use `toolErr`, as `remove_database` does.

- [ ] **Step 1: Write the failing tests.**
  - `schema_test.go` gets the six tool names and their required params.
  - `main_test.go` gets one round-trip per tool against a temp HOME, in the existing style.
- [ ] **Step 2: Run** `go test ./cmd/wakil-ctx` → FAIL.
- [ ] **Step 3: Implement.** Each description states what is kept: the file on a project
  remove, and the Trash copy on an environment remove.
- [ ] **Step 4: Run** `go test ./cmd/wakil-ctx` → PASS.
- [ ] **Step 5: Commit** `git commit -m "wakil-ctx: six tools for project and environment create, rename and remove"`

### Task 4: WakilKit — six actions and the agent pin

**Files:**
- Modify: `app/Sources/WakilKit/Registry/StandardActions.swift` (after `db_remove_database`,
  ~:935); `app/Sources/WakilKit/MCP/PermissionPrompt.swift:91` (`operatorOnlyActions`);
  `app/Sources/WakilApp/WakilWiring.swift` (or wherever `registerStandardActions` is called in
  production) to pass the pin hook.
- Test: `app/Tests/WakilKitTests/StandardActionsTests.swift`

**Interfaces:**
- Consumes: Task 3's tools.
- Produces:
  - Actions `ctx_create_project`, `ctx_rename_project`, `ctx_remove_project`,
    `ctx_create_environment`, `ctx_rename_environment` and `ctx_remove_environment`. Their
    params are the same as Task 3's tools, plus `project` (the registry name) on the three
    environment actions, used for the pin check.
  - A new defaulted parameter on `registerStandardActions`:
    `agentIn: (@Sendable (_ project: String, _ environment: String?) async -> String?)? = nil`.
    It returns the running agent's display name, or nil. With `environment == nil` it matches
    any environment of the project.

- [ ] **Step 1: Write the failing tests:**
  - All six are `.control` and `.operatorOnly`, and are in `operatorOnlyActions`.
  - Each forwards to its tool with the right arguments (use the existing fake `ToolCaller`).
  - With `agentIn` returning `"agent-1"`, `ctx_rename_project` and `ctx_remove_environment`
    throw an error whose description contains `Invariant 5` and `agent-1`, and the tool is not
    called. Create actions are never pinned.
- [ ] **Step 2: Run** `make app-test` filtered to `StandardActionsTests` (`cd app && swift test --filter StandardActionsTests`) → FAIL.
- [ ] **Step 3: Implement.** The production `agentIn` reads `WindowModel.agents` (`[Place:
  PlaceAgent]`) for an agent whose session is live.
- [ ] **Step 4: Run** the filter → PASS.
- [ ] **Step 5: Commit** `git commit -m "WakilKit: six operator-only ctx_* actions for projects and environments; rename and remove refused where an agent runs (Invariant 5)"`

### Task 5: Window — dispatch, refresh, layout move, active place

**Files:**
- Modify: `app/Sources/WakilKit/App/WindowModel.swift` (beside `removeDatabase`, :3165);
  `app/Sources/WakilKit/Layout/LayoutPersistence.swift`
- Test: `app/Tests/WakilKitTests/WindowModelProjectLifecycleTests.swift` (new),
  `app/Tests/WakilKitTests/LayoutPersistenceTests.swift`

**Interfaces:**
- Consumes: Task 4's actions.
- Produces, on `WindowModel` (each returns nil on success, or the failure text as
  `removeDatabase` does):
  - `func createProject(folder: String) async -> (name: String?, error: String?)`, where the
    name defaults to the folder's last path component;
  - `func renameProject(_ old: String, to new: String) async -> String?`
  - `func removeProject(_ name: String) async -> String?`
  - `func createEnvironment(project: String, projectPath: String) async -> (name: String?, error: String?)`
  - `func renameEnvironment(project: String, projectPath: String, _ old: String, to new: String) async -> String?`
  - `func removeEnvironment(project: String, projectPath: String, _ name: String) async -> (receipt: String?, error: String?)`.
    The receipt is `Removed <name> — a copy of project.json is in the Trash`.
- On `LayoutPersistence`:
  - `func renameProject(organization: String, from: String, to: String) throws`, which moves
    every `<from>@*.json` at the org level;
  - `func renameEnvironment(organization: String, project: String, from: String, to: String) throws`.
  - Neither touches `conversations/`. (Superseded by the final review: both move the conversations' files too.)

- [ ] **Step 1: Write the failing tests:**
  - LayoutPersistence: after `renameProject`, `load` for the new name returns the saved
    snapshot and the old file is gone. The same for an environment. A missing source is a no-op.
  - Window (fake context client in the `WindowModelChangesWritesTests` style):
    - a rename of the active environment leaves `place.environment` equal to the new name, and
      the saved layout comes back;
    - a removal of the active environment switches to the first remaining one, and the old
      scope's panes are dropped without a crash;
    - a failed action returns the tool's text whole, and `settings` is refreshed either way.
- [ ] **Step 2: Run** `cd app && swift test --filter 'WindowModelProjectLifecycle|LayoutPersistence'` → FAIL.
- [ ] **Step 3: Implement.** After each successful dispatch:
  `refreshContext()` → `refreshSettings()`. On a rename, move the layout first.
- [ ] **Step 4: Run** the filter, then `make app-test` → PASS.
- [ ] **Step 5: Commit** `git commit -m "Window: project and environment create, rename, remove — the place follows, a renamed scope keeps its layout"`

### Task 6: Settings pane — buttons, Name fields, Remove

**Files:**
- Modify: `app/Sources/WakilApp/SettingsPane.swift`:
  - the tree rows at :334 and :337 (`notThisPhase` becomes buttons);
  - the `.project` page at :678 and the `.environment` page at :699, where the "#45" note is
    deleted;
  - the `gone(name)` handling at ~:2276.
- Modify: `app/Sources/WakilKit/Panes/SettingsTree.swift` if selection needs a "select parent
  heading" helper.
- Test: `app/Tests/WakilKitTests/SettingsPaneTests.swift`, for the identifiers and the
  selection after removal, wherever that logic sits in WakilKit.

**Interfaces:**
- Consumes: Task 5's window methods.
- Produces the identifiers in Global Constraints.

- [ ] **Step 1: Write failing WakilKit tests** for the selection logic:
  - after a project removal, selection is the PROJECTS heading;
  - after an environment removal, selection is the project node;
  - after a create, selection is the new node.
- [ ] **Step 2: Run** `cd app && swift test --filter SettingsPane` → FAIL.
- [ ] **Step 3: Implement:**
  - **+ Add a project:** `NSOpenPanel` (directories only, one). On OK it calls
    `createProject`, selects the new node, and focuses and selects the Name field (Rule 3).
  - **+ Add an environment:** the same, without the panel.
  - **Name:** saved on blur with the Git fields' blur-save pattern. Return also saves. The error
    is shown under the field and the text is kept.
  - **Remove:** a spinner while in flight, disabled meanwhile (Rule 5), and the receipt shown at
    the parent.
- [ ] **Step 4: Run** the filter and `make app-test` → PASS. Run `make build` → succeeds.
- [ ] **Step 5: Commit** `git commit -m "Settings: + Add a project and + Add an environment are live; Name fields rename on leave; Remove on each page"`

### Task 7: e2e, runbook, charter

**Files:**
- Create in `e2e/checks/seeded/`:
  - `2e-ii-project-lifecycle.jsonl`
  - `2e-ii-environment-lifecycle.jsonl`
  - `2e-ii-rename-active-environment.jsonl`
  - `2e-ii-name-refusals.jsonl`
- Create: `docs/wakil/phase-2e-ii-acceptance.md`
- Modify: `docs/wakil/decisions.md` (a Decision 21 amendment dated 2026-10-22); `PRODUCT.md`
  (one line under Settings); `docs/wakil/north-star.md` (nothing until walked).

- [ ] **Step 1: Write the checks** in the style of `2e-settings-databases-dispatch.jsonl`.
  - Project lifecycle: `dispatch ctx_create_project {folder: "{fixtureRoot}/e2e-new", name: "e2e-new"}`;
    the tree contains it. Rename it through `settings.project.name` (type, then click another
    node: blur). The tree has the new name and not the old one. Remove it with
    `settings.project.remove`, and it's absent. Dispatch the create again, and the project is
    back.
  - Environment lifecycle: click `settings.tree.project.e2e-project.addEnvironment`. The tree
    contains `new-environment`. Rename it to `qa`, remove it, and the tree contains
    `a copy of project.json is in the Trash`.
  - Rename active environment: rename `staging` while it is active. The environment chip reads
    the new name.
  - Name refusals: an empty name, `a/b`, and a clash each show their text and leave the typed
    text in the field.
  - The fixture folder `e2e-new` comes from the seed. If the seed lacks an empty folder, add
    one in the seeded fixture setup.
- [ ] **Step 2: Run** `make e2e E2E_ONLY="<the four files>"` → PASS. Then `make e2e-new` →
  each red against the merge-base. Commit the proofs.
- [ ] **Step 3: Write the runbook.** Setup, then walk rows: the folder picker (the harness
  can't drive it), Put Back of the Trash copy, Rule 3 focus on create, the agent-pin refusal with
  a real agent, and voice reaching the agent and being told it can't. Add the machine-walk
  markers as in `phase-3a-ii-acceptance.md`.
- [ ] **Step 4: Charter.** Decision 21 amendment: environment create/rename/remove and project
  create/rename/remove are in the pane, and #97's ruling still holds for other project fields and
  the machine block. PRODUCT.md gets one line. Run `make docs-check` and report its output (the
  north-star word count is red before this work).
- [ ] **Step 5: Commit** `git commit -m "2e-ii e2e: project and environment lifecycle, the active rename, refusals; runbook; Decision 21 amended"`
