# Workspaces 1 — workspaces, checkouts and views: plan

**Spec:** `docs/superpowers/specs/2026-10-29-workspaces-design.md`, piece 1 (decisions 1, 4, 6–11, 22,
23, 28; calls 2–5, 9–14). **Branch:** `yehia-khalil/workspaces-1-model`.
Each task is test-first: the failing test, then the code, then `make test` / `make app-test` green,
then a commit `workspaces: <what>`.

## Seams left for the later pieces

| Piece | Seam | Where |
|---|---|---|
| 2 Running | `WorkspaceCheckout.ports` (a `PortBlock?`, `first`/`count`, nil until piece 2 hands one out); `WorkspaceCheckout.path` is where a recipe runs; `WorkspaceRunHook` (a closure slot on `WorkspaceStore`, `runInCheckout`) a piece-2 runner fills | `Workspace/WorkspaceModel.swift`, `Workspace/WorkspaceStore.swift`; Go `WorkspaceCheckout.Ports` |
| 3 Home | `WorkspaceStore.listing()` → `[WorkspaceListing]`: each workspace with its checkouts (repo, path, branch, holder), conversations (id, lineage root, state), environment, parent, archived; Main included | `Workspace/WorkspaceListing.swift`; the `workspace_list` action returns the same |
| 4 Messages, 5 Crews | `WorkspaceStore.workspace(ofConversation:)` → the workspace id; `session_list`'s `workspace` map per conversation | `Workspace/WorkspaceStore.swift` |

## Decisions this plan makes (recorded in the spec's amendment)

- **The record is Go's.** `internal/wakilcore/workspaces.go` owns `workspaces.json` (types, load that
  refuses an unreadable file whole, atomic save that never writes over one). Go needs it: its
  confinement (`wakil-git`, `wakil-files`) must admit a recorded checkout and nothing else. The window
  reads and writes it through `wakil-git`'s `workspaces_read` / `workspaces_write`; the agent's copy
  has neither write.
- **Snapshots never touch the shared stash list.** A snapshot is a stash-shaped commit made by
  `git stash create` (tracked) plus an untracked parent built in a temporary index, stored as
  `refs/wakil/snapshots/<workspace>/<repo>` and put back with `git stash apply <sha>`.
- **The record adds `id` and `conversations`** (lineage roots) to the spec's fields: Earlier,
  messages and crews need a past conversation's workspace.
- **The write rule runs in the action handlers**, through one seam (`WorkspaceWriteRouting`), at the
  head of every write. An operator dispatch passes through unchanged (call 12).

## Phase A — Go: worktrees, snapshots, the record (`internal/wakilcore`, `cmd/wakil-git`)

1. `WorktreeAdd / WorktreeRemove / WorktreeList / WorktreePrune` in `worktree.go`; temp-repo tests
   (a branch checked out elsewhere, a dirty worktree refused for remove, prune of a deleted folder).
2. `SnapshotCreate / SnapshotApply` (tracked + untracked, the ref kept, the stash list untouched).
3. `BranchOff` (a new branch from another branch's tip in a new worktree) and `TakeFromMain` (Main's
   folder switched to its base, its changes carried into the new worktree; refused whole on a clash).
4. `workspaces.go`: `Workspaces` record, `LoadWorkspaces` (missing → empty; unreadable → error),
   `SaveWorkspaces` (refuses over an unreadable file), `WorkspaceCheckoutPath`.
5. Confinement: `AllowedRootPaths(r)` = project roots + the project's recorded, unarchived checkouts;
   `wakil-git` and `wakil-files` use it.
6. `wakil-git` tools: `workspaces_read`, and (writes copy) `workspaces_write`, `git_worktree_add`,
   `git_worktree_remove`, `git_worktree_list`, `git_worktree_prune`, `git_snapshot_create`,
   `git_snapshot_apply`, `git_take_from_main`; schema test list.

## Phase B — Swift: the model, pure (`WakilKit/Workspace/`)

1. `WorkspaceModel.swift`: `Workspace`, `WorkspaceCheckout`, `PortBlock`, `WorkspaceSnapshot`,
   Codable round trip with Go's JSON.
2. `WriteRule.swift`: `decideWrite(...)` → `WriteDecision` (step 0, 1 free/own/take-over/branch-off,
   2 make, 2 take-from-Main, detached HEAD, branch switch to a branch held elsewhere); a test per case.
3. `WorkspacePaths.swift`: Main → checkout and back; `confinementRefusal` for another workspace's
   path (call 13), naming it.
4. `BranchNames.swift`: slug, `<KEY>-<slug>`, child suffix lengthened until unused.
5. `WorkspaceThreadLines.swift`: started, took over, branched off, took from Main, add failed (whole).

## Phase C — Swift: wiring the rule

1. `WorkspaceStore` (actor): the record in memory, holders, conversation → workspace; load/save
   through a `ToolCaller` (wakil-git); unreadable shown whole, never saved over.
2. `WorkspaceWriter`: runs a `WriteDecision` (worktree add, branch-off, take-from-Main), records
   holders, returns the translated root/path and the thread line.
3. Every agent write action routes through it: `editor_save/create/rename/trash/replace_undo`,
   `editor_changes_*` writes (stage … switch, branch create). Roots for confinement include the
   project's checkouts.
4. `WindowModel`: conversation states for the rule, thread lines, the conversation's workspace in
   `session_list` and the agent's instructions (its map).

## Phase D — actions

`workspace_list` (read), `workspace_archive`, `workspace_restore`, `workspace_bring_home`,
`conversation_move` (operator-only controls); `ActionClassificationTests` pinned list.

## Phase E — views (decision 22)

`LayoutScope.workspace`: a workspace's canvas filed by workspace id; Main's per project +
environment; step 0 copies the layout (editor tabs re-pointed into the copy, data panes kept,
terminals left). Tags "Main · your folder" / "workspace copy"; the context line names the workspace.

## Phase F — environment per workspace (decision 28)

## Phase G — Branches instructions (decision 10), quick-task draft, slug fallback

## Phase H — charter: glossary, Decision 94, state.md

## Phase I — e2e checks written (not run), or `uncoverable.tsv` lines

## Phase J — the three items left undone (amendment 2026-10-30)

1. **Terminals at step 0.** `LayoutStore.leave(id:for:replacedWith:title:)` (a pane leaves for another
   scope, a new one of its kind takes its place), `SnapGraph.rename`, `PaneStore.moveContents`,
   `TerminalStore.rehome(only:)`; `WindowModel.leaveTerminalsInMain` from `workspaceViewFollows`.
   Test: `step0LeavesTerminalsInMainsViewAndOpensTheViewsOwnInTheCopy`. E2E:
   `agent/workspaces-step0-terminals.jsonl`.
2. **Data panes follow the environment.** `WorkspaceRouterHooks.environmentChanged`, called by
   `setEnvironment` after the save (id or slug); `WindowModel.workspaceDataPanesFollow`. Tests:
   `anEnvironmentChangeTellsTheWindowWhatItWas`, `aWorkspacesDataPanesFollowItsEnvironment`. E2E:
   `agent/workspaces-environment-data-panes.jsonl`.
3. **The map in the instructions.** `workspaceMapText` (`Workspace/WorkspaceMap.swift`),
   `WindowModel.workspaceMapUpdate` after the words in `send`; `firstPrompt` drops the block; the
   stub matches the words and reads `{map}`. Tests: `WorkspaceMapTests`,
   `WindowModelWorkspaceMapTests`, `TestGetSession_FirstPromptLeavesOutTheWorkspaceMap`,
   `TestARuleMatchesTheWordsAndReadsTheMapAfterThem`. E2E: `agent/workspaces-map.jsonl`.
4. **A resumed thread's rows leave the map out.** `blockEntries` drops the block from user entries
   (`withoutWakilBlocks`, as `firstPrompt`). Test: `TestReadSession_UserRowsLeaveOutTheWorkspaceMap`.
   E2E: `agent/workspaces-map-resumed.jsonl`.
