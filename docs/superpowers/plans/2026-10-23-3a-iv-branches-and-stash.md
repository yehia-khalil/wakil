# 3a-iv Branches and Stash Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The operator switches, creates, renames and deletes branches and stashes, applies, pops and drops stashes, from a branch picker in the context line and the Changes view, VS Code's flow; the agent and voice reach the same actions, and delete and drop ask the operator when they ask.

**Architecture:** `GitWriter` in `internal/wakilcore` gains branch and stash writes and two reads; `wakil-git` exposes them as tools under `WAKIL_GIT_WRITES`; WakilKit registers `editor_changes_*` actions over them, priced allow, with a new per-channel price (`agentPrice`) that gates delete and drop for `origin == .agent`; WakilApp draws the Branch segment, the shared picker, the ▾ submenus and the Stashes group.

**Tech Stack:** Go (`internal/wakilcore`, `cmd/wakil-git`), Swift 6 / SwiftUI, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-23-3a-iv-branches-and-stash-design.md`

## Global Constraints

- Never `git switch --force`, `--discard-changes`, `git checkout -f`, or `git branch -M`. Delete uses `-D` only when the caller passes `force: true`.
- Writes run on 3a-ii's write lock and safety args (`gitWriteSafetyArgs`); reads go through `GitRunner` (no repository-chosen program runs).
- Branch names: spaces → `-`, then `git check-ref-format --branch`; git's refusal shown whole.
- Exact copy:
  - refused switch: `Your changes to <paths, comma-separated> would be overwritten by <branch>.` with buttons **Stash and Switch**, **Bring Them Along**, **Cancel**
  - clash: `Switched to <branch>; your changes clash with it and are kept in git stash` (pop/apply clash: `Your stash clashes with <branch>; it is kept in git stash`)
  - moved stash list: `The stash list changed; look again`
  - nothing to stash: `No local changes to stash`
  - cancelled between steps: `Your changes are in git stash (stash@{0})`
  - delete confirm: `Delete <branch>? Its <n> commits not on <current> are kept only in git's reflog.` (merged: `Delete <branch>? It is merged into <current>.`), buttons **Delete** / **Keep it**
  - drop confirm: `Drop "<message>"? It cannot be applied again.`; drop all: `Drop all <n> stashes? They cannot be applied again.`
  - mid-merge/rebase: `A merge is in progress in <root>; finish or abort it first` (rebase likewise)
- Identifiers: `window.contextLine.branch`, `branch.picker.filter`, `branch.picker.row.<name>`, `branch.picker.create`, `branch.picker.createFrom`, `branch.picker.fetch`, `branch.picker.root.<name>`, `branch.picker.blocked.stash|bring|cancel`, `editor.changes.<root>.branch`, `editor.changes.<root>.stashes`, `editor.changes.<root>.stash.<id7>` with `.apply|.pop|.drop|.drop.confirm|.drop.keep`, `editor.changes.<root>.nameField` with `.go`.
- Every new action/tool updates the pinned lists: `AppWiringTests`, `WindowModelPaletteTests`, `StandardActionsTests` (names and `paramsByAction`), `ActionClassificationTests`, `cmd/wakil-git` main_test tool list, `InvalidationContractTests` for new `WindowModel` properties.
- Public repository: example names only (initech, umbrella) in committed text.

## Rulings

- **R1 — Voice reaches delete and drop only through the agent.** They are not added to `FastPath`'s action list, so a spoken "delete fix-login" is an agent turn (`origin == .agent`) and gates. Cost if wrong: a fast-path line could not delete; that is the intent.
- **R2 — The permission plane names what is lost from the params.** The agent's call carries `branch` (or the stash's `message`); the plane shows the action's proposal line as it does for every gated action, and the commit count is the pane's in-place confirmation's. Cost if wrong: the agent-side plane says less than the spec's sentence.
- **R3 — `editor_changes_branch_create` is `git_switch` with `create: true`.** One Go path; two names because the ▾ menu and the agent say "create".

## Review Focus

1. **An untracked file the target branch also has** — the switch is refused and the path is listed, not silently skipped. Test in Task 2.
2. **The stash list moves between reading and acting** (a terminal stashes) — Apply/Pop/Drop by the old index is refused with the exact copy. Test in Task 3.
3. **Bring Them Along whose pop clashes** — the folder is clean on the new branch, the stash is still there, the copy is exact. Test in Task 2.
4. **A detached HEAD** — the segment reads `detached at <sha7>`, the picker marks no branch current, Rename is refused plainly. Tests in Tasks 2 and 5.
5. **Deleting a branch checked out in another worktree** — git's refusal shown whole, nothing deleted. Test in Task 2.

---

### Task 1: The per-channel price

**Files:** Modify `app/Sources/WakilKit/Core/Action.swift` (`agentPrice: GateDecision? = nil`, init parameter), `app/Sources/WakilKit/Gate/WriteGate.swift` (`writeGate(…, agentPrice: GateDecision? = nil, …)`), `app/Sources/WakilKit/Registry/ActionRegistry.swift` (pass `action.agentPrice`). Test: `app/Tests/WakilKitTests/WriteGateTests.swift`.

**Interfaces:** Produces `Action(…, agentPrice:)`; for `.mutate`, `origin == .agent` and `agentPrice != nil` → `agentPrice`; otherwise unchanged (production's `price.production` still applies first when it is `.block`).

- [ ] **Step 1: Failing tests** — `anAgentPriceGatesOnlyTheAgent`: `.mutate`, `price (.allow, .allow)`, `agentPrice .gate` → `.gate` for `.agent`, `.allow` for `.ui` and `.debug`; `noAgentPriceChangesNothing`; `productionBlockStillBlocks`: `price (.block, .allow)`, `agentPrice .gate`, production → `.block` for every origin.
- [ ] **Step 2: Run** `cd app && ../scripts/swift-test.sh --filter WriteGateTests` — Expected: FAIL (no `agentPrice`).
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the filter, then `make app-test` — Expected: PASS.
- [ ] **Step 5: Commit** `3a-iv: a price for the agent's channel`.

### Task 2: Go — branches: list, switch, create, rename, delete

**Files:** Create `internal/wakilcore/gitbranch.go`, `internal/wakilcore/gitbranch_test.go` (fixture: the `remoteFixture` of `gitremote_test.go`).

**Interfaces:** Produces
- `type GitBranch struct { Name, Upstream string; Ahead, Behind, Unmerged int; Current bool; Date time.Time }` (`Unmerged`: commits not on the current branch)
- `type GitBranches struct { Local []GitBranch; Remote []string; Current, Detached string }` — Local most recent first; Remote excludes any a local tracks
- `func ReadBranches(ctx context.Context, g *GitRunner) (GitBranches, error)`
- `type SwitchOptions struct { Create bool; From, Track, Carry string }` (`Carry`: `refuse` default, `stash`, `bring`)
- `type SwitchResult struct { Switched bool; Blocked []string; Stash, Note string }`
- `func (w *GitWriter) Switch(ctx context.Context, branch string, o SwitchOptions) (SwitchResult, error)`
- `func (w *GitWriter) RenameBranch(ctx context.Context, to string) error` (current branch only)
- `func (w *GitWriter) DeleteBranch(ctx context.Context, name string, force bool) error`
- `func NormaliseBranchName(s string) string`

- [ ] **Step 1: Failing tests**:
  - `TestReadBranchesOrdersLocalAndHidesTrackedRemotes`
  - `TestSwitchCarriesChangesItCan`
  - `TestSwitchRefusesAndListsBlockedPaths` (tracked and an untracked file the target has — Review Focus 1)
  - `TestSwitchStashThenSwitch` (`Stash` holds the stash's id)
  - `TestSwitchBringAlong`
  - `TestBringAlongClashLeavesCleanTreeAndStash` (Note is the exact clash copy; `git status --porcelain` empty; one stash — Review Focus 3)
  - `TestCreateExistingNameSwitches`
  - `TestCreateFromBaseAndTrackRemote`
  - `TestNamesNormaliseAndRefuse` (`"fix login"` → `fix-login`; `"a..b"` refused with git's words)
  - `TestRenameRefusesExistingNameAndDetached` (Review Focus 4)
  - `TestDeleteUnmergedNeedsForce` (the error says how many commits)
  - `TestDeleteBranchInAnotherWorktreeRefusedWhole` (Review Focus 5)
  - `TestSwitchRefusesMidMerge` (exact copy)
  - `TestCancelBetweenStashAndPopSaysWhere` (cancel the context after the stash: no switch half-done, Note is the exact cancelled copy)
- [ ] **Step 2: Run** `go test ./internal/wakilcore -run 'Branch|Switch|Names|Rename|Delete'` — Expected: FAIL.
- [ ] **Step 3: Implement.** Switch:
  - `stash` and `bring` use `git stash push --include-untracked -m "wakil: switch to <branch>"`.
  - `bring` then switches and runs `git stash pop`. On a clash it runs `git reset --hard` and `git clean -fd` limited to the paths the pop touched, so the stash keeps every change, and returns the clash Note.
  - Blocked paths come from git's "would be overwritten" message.
- [ ] **Step 4: Run** `go test ./internal/wakilcore` — Expected: PASS.
- [ ] **Step 5: Commit** `3a-iv: branches in GitWriter`.

### Task 3: Go — stash: push, list, apply, pop, drop, and stash diffs

**Files:** Create `internal/wakilcore/gitstash.go`, `gitstash_test.go`; Modify `internal/wakilcore/gitshow.go` (accept `stash@{n}` / a stash id and its `^1`, and `^3` for untracked).

**Interfaces:** Produces
- `type GitStash struct { Index int; ID, Message, Branch string; Date time.Time; Files []string }`
- `func ReadStashes(ctx context.Context, g *GitRunner) ([]GitStash, error)` (Files include untracked)
- `func (w *GitWriter) Stash(ctx context.Context, message, mode string) error` (`default|untracked|staged`)
- `func (w *GitWriter) StashApply(ctx context.Context, index int, id string, pop bool) (note string, err error)`
- `func (w *GitWriter) StashDrop(ctx context.Context, index int, id string) error`
- `func (w *GitWriter) StashDropAll(ctx context.Context) error`

- [ ] **Step 1: Failing tests**:
  - `TestStashModes`
  - `TestNothingToStashSaysSo` (exact copy)
  - `TestReadStashesListsFilesWithUntracked`
  - `TestApplyPopDropByIndexAndID`
  - `TestAMovedStashListIsRefused` (stash again from a second runner between read and drop — exact copy; Review Focus 2)
  - `TestPopClashKeepsStashAndCleansTree`
  - `TestGitShowReadsAStashFile`
- [ ] **Step 2: Run** `go test ./internal/wakilcore -run 'Stash|Show'` — Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `go test ./internal/wakilcore` — Expected: PASS.
- [ ] **Step 5: Commit** `3a-iv: stash in GitWriter`.

### Task 4: `wakil-git` tools

**Files:** Modify `cmd/wakil-git/main.go` (`addWriteTools` and the reads), `cmd/wakil-git/main_test.go`.

**Interfaces:** Consumes Tasks 2–3.
- Reads: `git_branches {root}` → `GitBranches`; `git_stashes {root}` → `{stashes}`.
- Writes:
  - `git_switch {root, branch, create?, from?, track?, carry?}` → `SwitchResult`
  - `git_branch_rename {root, to}`, `git_branch_delete {root, branch, force?}`
  - `git_stash {root, message?, mode?}`
  - `git_stash_apply|git_stash_pop|git_stash_drop {root, index, id}` → `{note}`
  - `git_stash_drop_all {root}`
- Every write tool is wrapped in 3a-iii's `remoteContext` so SIGTERM cancels it cleanly.

- [ ] **Step 1: Failing tests:** the tool-list test names the new tools, and only with `WAKIL_GIT_WRITES=1` for the writes. `TestSwitchToolReportsBlockedPaths` runs a fixture through an in-memory MCP client.
- [ ] **Step 2: Run** `go test ./cmd/wakil-git` — Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `go test ./cmd/...` — Expected: PASS.
- [ ] **Step 5: Commit** `3a-iv: wakil-git branch and stash tools`.

### Task 5: WakilKit — actions, picker rows and the active root

**Files:**
- Create `app/Sources/WakilKit/Editor/EditorChangesBranches.swift` (registration, called beside `registerEditorChangesWrites`).
- Create `app/Sources/WakilKit/Git/BranchPicker.swift` (pure model).
- Create `app/Sources/WakilKit/App/WindowModel+Branches.swift`.
- Modify the pinned test lists (Global Constraints).
- Test: `app/Tests/WakilKitTests/BranchPickerTests.swift`, `WindowModelBranchesTests.swift`.

**Interfaces:**
- Consumes Task 1's `agentPrice` and Task 4's tools.
- Produces these actions:
  - `.read`: `editor_changes_branches {root}`, `editor_changes_stashes {root}`.
  - `.mutate`, `price (.allow, .allow)`: `editor_changes_switch {root, branch, carry?}`, `editor_changes_branch_create {root, name, from?}`, `editor_changes_branch_rename {root, to}`, `editor_changes_stash {root, message?, mode?}`, `editor_changes_stash_apply|_stash_pop {root, index, id}`.
  - The same price plus `agentPrice: .gate`: `editor_changes_branch_delete {root, branch, force?}`, `editor_changes_stash_drop {root, index, id}`, `editor_changes_stash_drop_all {root}`.
  - All are agent-reachable and go through `GitWriteFlights`.
- Produces in `BranchPicker.swift`:
  - `public enum BranchPickerRow: Equatable { case create(String), createFrom, local(GitBranchInfo), remote(String), fetch }`
  - `public func branchPickerRows(_ b: GitBranchesInfo, filter: String) -> [BranchPickerRow]`
  - `public func activeGitRoot(focusedPath: String?, roots: [GitRootState]) -> GitRootState?`
  - `public func branchSegmentText(_ active: GitRootState?, rootCount: Int) -> String?`
  - `public func deleteBranchConfirmation(_ branch: GitBranchInfo, current: String) -> String`
  - `public func dropStashConfirmation(_ s: GitStashInfo) -> String`
- Produces on `WindowModel`:
  - `changesBranches(root:) async -> GitBranchesInfo?`
  - `changesSwitch(root:branch:carry:) async -> ChangesSwitchOutcome` (`.switched(note:)`, `.blocked(paths:)`, `.refused(String)`)
  - `changesStashes(root:) async -> [GitStashInfo]`
  - one `changesWrite` call each for the other writes.
- Produces the stash diff: the diff tab's subject gains `stash: String` (a stash id). `editor_open_diff {root, path, stash}` opens a read-only diff with `<id>^1:<path>` on the left and `<id>:<path>` on the right; an untracked file has nothing on the left and `<id>^3:<path>` on the right.

- [ ] **Step 1: Failing tests:**
  - `branchPickerRows`: the create row only when the filter names no branch; local before remote; filtering is case-insensitive; detached marks none current.
  - `branchSegmentText`: `main`, `api: main`, `detached at 3f2a1c9`, and nil with no roots.
  - `activeGitRoot`: the focused tab's root, else the first.
  - The two confirmation strings, exactly.
  - `theDeleteAndDropsGateOnlyTheAgent`: dispatched with `origin: .agent` they park in the `ConfirmationBroker`; with `.ui` they run.
  - `aBlockedSwitchComesBackWithItsPaths`.
  - `aStashFileOpensAReadOnlyDiffTab` (subject carries the stash id; the sides are right for tracked and untracked).
- [ ] **Step 2: Run** `cd app && ../scripts/swift-test.sh --filter 'BranchPickerTests|WindowModelBranchesTests'` — Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `make app-test` — Expected: PASS.
- [ ] **Step 5: Commit** `3a-iv: branch and stash actions, and the picker's rows`.

### Task 6: WakilApp — the Branch segment and the picker

**Files:**
- Create `app/Sources/WakilApp/BranchPicker.swift` (the shared view: filter, root tabs, rows, the blocked-switch choice).
- Modify `app/Sources/WakilApp/ContextLine.swift` (the segment at rest and promoted).
- Modify `app/Sources/WakilApp/EditorColumn.swift` (the root header's branch name becomes a button that opens the picker for that root).
- ⌘K *Switch Branch…*: a palette command opening the picker for the active root.

- [ ] **Step 1: Implement** against Task 5's interfaces. Check against the spec's Interaction rules: the filter is focused 150 ms after appearing (the sheet-focus fix from 3a-iii), Escape closes, ↑↓ and Return work, a pick closes the picker and leaves focus where it was, and Fetch has a spinner and Cancel. Identifiers come from Global Constraints.
- [ ] **Step 2: Run** `make app-bundle` and `go test ./e2e/driver -run TestEveryAuditedControlIsNamed` — Expected: builds, and no new unnamed control (the EditorColumn `.onTapGesture` finding predates this plan).
- [ ] **Step 3: Commit** `3a-iv: the branch picker in the context line and the Changes view`.

### Task 7: WakilApp — ▾ submenus, the name field and the Stashes group

**Files:** Modify `app/Sources/WakilApp/EditorColumn.swift`; create `app/Sources/WakilApp/ChangesStashes.swift`.

- [ ] **Step 1: Implement:**
  - **▾ → Branch** (Create…, Create From…, Rename…, Delete…) and **▾ → Stash** (Stash, Stash Including Untracked, Stash Staged, Pop Latest Stash, Apply Latest Stash).
  - **The in-place name/message field:** focused when it appears; Return or **.go** runs it; leaving keeps the text and the field open; Escape cancels.
  - **The Stashes group:** collapsed by default and absent when there are no stashes. Rows show `message · on branch · age`, with Apply / Pop / Drop on hover. A row expands to its files, and a file opens the diff tab against the stash's parent.
  - **Delete and Drop confirm in place** with the exact copy.
- [ ] **Step 2: Run** `make app-bundle` and the control audit — Expected: as in Task 6.
- [ ] **Step 3: Commit** `3a-iv: branch and stash menus, the name field, the Stashes group`.

### Task 8: Charter and runbook

**Files:**
- `docs/wakil/decisions.md`: Decision 46, and a new Invariant 6 entry for branch delete and stash drop (with why they are priced by channel).
- `docs/wakil/north-star.md`: Invariant 6's count becomes "Eight have earned in".
- Create `docs/wakil/phase-3a-iv-acceptance.md`: a setup script modelled on 3a-iii's (a bare remote, a second clone, two branches, a stash) and at most ten rows.

- [ ] **Step 1: Edit**, then run `scripts/public-check.sh` on the changed files — Expected: no hits.
- [ ] **Step 2: Commit** `3a-iv: charter records and the runbook`.

**After the plan:** `superpowers:requesting-code-review` on the whole branch (opus); Cover (the e2e auditor): the segment and picker pressed, switch/stash parity, the blocked-switch choice, the Stashes group; the operator's walk.
