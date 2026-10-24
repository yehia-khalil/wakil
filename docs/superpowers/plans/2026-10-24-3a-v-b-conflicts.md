# 3a-v-b Conflicts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A merge, rebase, pull, stash apply/pop or Bring Them Along that clashes leaves its conflicts in the tree, and the operator resolves them in Wakil the VS Code way — a Merge Changes group, per-block Accept Current / Incoming / Both in the editor, whole-file takes, then Commit Merge or Continue Rebase, or Abort; Merge Branch… and Rebase Branch… start one; the agent reaches every step by the same names.

**Architecture:** `internal/wakilcore` reads the operation in progress from the git dir into `GitStatus` (one reader replaces the two `inProgress` copies), keeps the unmerged XY as a `conflicts` group, and gains the writes `Merge`, `Rebase`, `Continue`, `Skip`, `Abort`, `Resolve` and `StashUndoApply`; Pull, `StashApply` and `Switch`'s Bring Them Along stop putting things back and report the clash. `wakil-git` exposes seven tools. WakilKit parses conflict blocks from tab text (pure, tested), computes each Accept, and registers the `editor_changes_*` and `editor_conflict_*` actions; WakilApp draws the group, header state, confirms and the picker's new mode, and `monaco-host.html` tints blocks with an actions row in an overlay widget.

**Tech Stack:** Go (`internal/wakilcore`, `cmd/wakil-git`), Swift 6 / SwiftUI, Swift Testing, Monaco in `app/Sources/WakilApp/monaco-host.html`.

**Spec:** `docs/superpowers/specs/2026-10-23-3a-v-conflicts-history-blame-design.md` (this plan builds its *3a-v-b, conflicts*; *3a-v-a* shipped as #63)

## Global Constraints

- Writes go through `GitWriter.git` (or `GitRemote.git` for Pull) on the root's write lock with `gitWriteSafetyArgs`; never `--force`; `reset --hard` only inside Abort's own `--abort` and Undo Apply's put-back. Every path list from git is read NUL-separated (`-z`).
- No editor ever opens: rebase and commit calls pass `-c core.editor=true -c sequence.editor=true` (the scrubbed env drops `EDITOR`; nothing sets `GIT_EDITOR`).
- Merge and Rebase run with `--autostash` (call 12); Merge with `--no-edit`.
- Exact copy — header state (amber): `merging <incoming>`, `rebasing <step>/<steps> onto <onto>`, `cherry-picking <id7>`, `reverting <id7>`.
- Exact copy — buttons: merge, cherry-pick, revert: `Commit Merge`, ▾ `Abort Merge`; rebase: `Continue Rebase`, ▾ `Skip Commit`, `Abort Rebase`; while conflicts remain, beside the disabled button: `Resolve 1 conflict first` / `Resolve <n> conflicts first`.
- Exact copy — group `Merge Changes`; row kinds: `UU both modified`, `AA both added`, `DU deleted by us`, `UD deleted by them`, `AU added by us`, `UA added by them`, `DD both deleted`; a staged file with markers: `a.txt — staged with conflict markers` (amber).
- Exact copy — row menu: `Accept All Current`, `Accept All Incoming`; delete/modify rows: `Keep File`, `Delete File`. Group header after a Wakil stash clash: `Undo Apply`.
- Exact copy — editor actions row: `Accept Current Change · Accept Incoming Change · Accept Both Changes · Compare Changes`; marker lines get the dim suffix `(Current Change)` / `(Incoming Change)`. ⌘K: `Next Conflict`, `Previous Conflict`. Compare tab title: `a.txt (Current ↔ Incoming)`.
- Exact copy — in-place confirms (Rule 1), each with `Keep it` and the action's verb:
  - Abort: `Abort the merge? The tree goes back to before it, and your resolutions are lost.` (`rebase`, `cherry-pick`, `revert` for the other kinds)
  - Skip: `Skip abc1234 "Seed search"? Its changes are left out of the rebase.`
  - Accept All Current / Incoming: `Take all of HEAD's a.txt? Any edits you made to it are lost.` / `Take all of <incoming>'s a.txt? Any edits you made to it are lost.`
  - Delete File: `Take all of <the side that deleted it>'s a.txt? Any edits you made to it are lost, and the file is deleted.`
  - Undo Apply: `Undo applying "<stash message>"? The files it touched go back to HEAD; the stash stays in the list.`
- Exact copy — notes (amber, `editor.changes.<root>.error`): Pull `Pull stopped on conflicts in a.txt, b c.txt; resolve them below`; Merge `Merge stopped on conflicts in a.txt; resolve them below`; Rebase `Rebase stopped on conflicts in a.txt (step 2 of 5); resolve them below`; stash `Your stash clashes with main in a.txt; resolve it below, or Undo Apply`; Bring Them Along `Switched to other; your changes clash with it in a.txt — resolve them below, or Undo Apply`; Continue refused `Resolve the conflicts in a.txt first`; Undo Apply refused `a.txt changed since the clash; Undo Apply would lose that — resolve it by hand`; in progress (all writes that refuse today): `A merge|A rebase|A cherry-pick|A revert is in progress in <root>; finish or abort it first`.
- Prices: `editor_changes_abort`, `_skip`, `_take` and `_stash_undo_apply` carry `agentPrice: .gate` and a `confirmationDescription` case; everything else is `(.allow, .allow)` with no agent price.
- Identifiers: `editor.changes.<root>.state`, `.commitMerge`, `.continueRebase`, `.abort`, `.skip`, `.abort.keep|.confirm`, `.skip.keep|.confirm`, `.conflictsReason`, `.undoApply`, `.undoApply.keep|.confirm`; group `editor.changes.group:<root>/conflicts`; row menu `editor.changes.row:<root>/<path>:conflicts.takeCurrent|takeIncoming|keep|delete` and `….take.keep|.confirm`; `editor.changes.<root>.branch.merge`, `.branch.rebase`; `branch.picker.*` reused.
- Every new action/tool updates the pinned lists: `AppWiringTests`, `WindowModelPaletteTests` (`registeredBeforeThePalette`; `agentToolsBeforeThePalette` for `.read`/`.control` ones), `StandardActionsTests`, `ActionClassificationTests`, `MCPServerTests` (`theGitDropsHaveSentencesToo` pattern), `CommandCatalogTests`, `cmd/wakil-git` `TestToolListIsTheReadsAndTheWrites`, `InvalidationContractTests` for new `WindowModel` properties, `e2e/driver/identifiers.go` `AuditedSources` for any new SwiftUI file.
- Public repository: example names only (Ada Lovelace, initech, umbrella) in committed text.

## Rulings

- **R1 — Gated takes are their own action.** `agentPrice` is per action, not per param (WriteGate.swift:143), so the spec's `_resolve` splits: `editor_changes_take {root, path, take: current|incoming|delete}` (gate) and `editor_changes_keep_file {root, path}` (allow); the row's `+` stays `editor_changes_stage` (allow, marks resolved). Cost if wrong: one action name differs from the spec.
- **R2 — Accept goes through the store, not the page.** WakilKit parses the blocks from the tab's text and computes the replacement; `editor_conflict_accept` applies it as the existing `editor_replace_range` edit does, so the page's `wakilApplyEdit` makes it one undoable step and the agent's call is the operator's. The page only reports presses. Cost if wrong: none to the operator.
- **R3 — The actions row is an overlay widget per block**, as the peek's buttons are (view-zone content gets no clicks, monaco-host.html:295), with `mousedown` + `preventDefault`. Cost if wrong: the row is unclickable.
- **R4 — A Wakil stash clash is remembered per root for the session** (`WindowModel.changesClashes: [String: GitStashClash]`), cleared by Undo Apply, by the conflicts group emptying, or by a relaunch. Cost if wrong: Undo Apply offered on a clash it can no longer undo — Go refuses it (Task 3).
- **R5 — Bring Them Along's clash now matches StashApply's**: no `reset --hard` / `clean -fdq`; the tree is left with the conflicts and the stash kept. Cost if wrong: none; the old wipe is what call 2 removes.
- **R6 — `onto` and `incoming` are named, else short ids.** Merge: `MERGE_MSG`'s `Merge branch '<name>'` (or `Merge remote-tracking branch '<name>'`), else `MERGE_HEAD`'s id7. Rebase: `rebase-merge/onto` (or `rebase-apply/onto`) matched to a local branch tip via `for-each-ref`, else id7. Cost if wrong: an id where a name would read better.
- **R7 — The copy marked exact above that the spec leaves open** (the notes, the disabled reason, the Compare title, Undo Apply's sentence) is this plan's; the operator may reword at review.

## Review Focus

1. **Paths with spaces or non-ASCII letters in a conflict** — listed whole in the note, the group and the clash record (today's Pull splits on spaces). Test in Task 3.
2. **Conflict text with CRLF endings, a block at the first or last line, and a file whose text contains `=======` outside any block** — blocks parse exactly and each Accept keeps the line endings. Tests in Task 6.
3. **A delete/modify conflict (no stage 2 or no stage 3)** — Compare shows the absent side empty, not an error; Keep File / Delete File resolve it. Tests in Tasks 3 and 6.
4. **Continue Rebase with no editor configured** — finishes without hanging, keeping each commit's message. Test in Task 2.
5. **The operator edits a clashed file, then presses Undo Apply** — refused naming the file; nothing is lost. Test in Task 3.

---

### Task 1: Go — the operation in progress, and conflicts in status

**Files:** Create `internal/wakilcore/gitop.go`, `internal/wakilcore/gitop_test.go`. Modify `gitstatus.go` (unmerged rows, `State`, `Markers`), `gitbranch.go:119` and `gitremote.go:348` (both `inProgress` copies call `ReadGitOp`), `gitwrite.go:271` (`merging` → any `Kind` but rebase), `gitstatus_test.go` (`TestStatusConflictIsOneChangedRow` becomes the group test).

**Interfaces:** Produces
- `type GitOp struct { Kind, Incoming, Onto string; Step, Steps int; Head, Subject, Message string }` json `kind, incoming, onto, step, steps, head, subject, message` — `Kind` is `merge|rebase|cherry-pick|revert` or `""`; `Head` and `Subject` the commit being applied (rebase, cherry-pick, revert), for Skip's sentence; `Message` git's prepared message (`MERGE_MSG`, comment lines dropped), which fills the empty commit box.
- `func ReadGitOp(ctx context.Context, g *GitRunner) (GitOp, error)` — from `rev-parse --absolute-git-dir` then file reads: `MERGE_HEAD`/`MERGE_MSG`, `rebase-merge/{onto,msgnum,end,stopped-sha}` or `rebase-apply/{onto,next,last}`, `CHERRY_PICK_HEAD`, `REVERT_HEAD`; names per R6.
- `func (op GitOp) InProgressError(root string) error` — `nil` when `Kind == ""`, else the exact in-progress text.
- `GitStatus.State *GitOp` json `state,omitempty`; `GitFile.Kind string` json `kind,omitempty` (the XY, e.g. `UU`) and `GitFile.Markers bool` json `markers,omitempty`; unmerged rows are `Group: "conflicts", Status: "U"`.

- [ ] **Step 1: Failing tests** in `gitop_test.go` (fixture: `branchFixture`; conflicts made with `git merge` / `git rebase` ignoring exit, as gitstatus_test.go:78 does):
  - `TestReadGitOpNamesAMerge` — merge `feature/search` conflicting → `{Kind:"merge", Incoming:"feature/search"}`.
  - `TestReadGitOpCountsARebase` — 3 commits rebased onto `main`, stopped on the 2nd → `{Kind:"rebase", Onto:"main", Step:2, Steps:3}`, `Head` the 40-hex id stopped on.
  - `TestReadGitOpSeesCherryPickAndRevert` — `Kind` `cherry-pick` / `revert`, `Head` set.
  - `TestReadGitOpIsEmptyOnACleanTree`.
  - `TestStatusKeepsEachConflictKind` (gitstatus_test.go) — UU, AA, DU, UD rows come back `Group:"conflicts"` with their `Kind`; `State` set; a staged file holding a full `<<<<<<< `/`=======`/`>>>>>>> ` block has `Markers:true`, one with only `<<<<<<<` does not, one over 1 MB is not scanned.
  - `TestEveryWriteRefusesMidCherryPick` — `Switch`, `Stash`, `StashApply`, `Pull` return `A cherry-pick is in progress in <root>; finish or abort it first`.
- [ ] **Step 2:** `go test ./internal/wakilcore -run 'GitOp|StatusKeeps|MidCherryPick'` — FAIL (undefined).
- [ ] **Step 3:** Implement `ReadGitOp`, `InProgressError`, the status changes (`ReadGitStatus` calls `ReadGitOp`; `markers` scans staged files ≤ 1 MB via `show :<path>`), and replace both `inProgress` copies and `merging`.
- [ ] **Step 4:** `go test ./internal/wakilcore` — PASS (existing mid-merge refusal tests keep their text).
- [ ] **Step 5:** Commit `3a-v-b: the operation in progress, and conflicts kept in status`.

### Task 2: Go — merge, rebase, continue, skip, abort

**Files:** Create `internal/wakilcore/gitmerge.go`, `gitmerge_test.go`.

**Interfaces:** Consumes `ReadGitOp`, `InProgressError` (Task 1). Produces
- `type GitMergeResult struct { Done bool; Conflicts []string; Summary string }` json `done, conflicts, summary` — `Done` false when it stopped on conflicts; `Summary` the note (exact copy) or git's one-line result.
- `func (w *GitWriter) Merge(ctx, branch string) (GitMergeResult, error)` — `merge --no-edit --autostash <branch>`.
- `func (w *GitWriter) Rebase(ctx, onto string) (GitMergeResult, error)` — `-c core.editor=true -c sequence.editor=true rebase --autostash <onto>`.
- `func (w *GitWriter) Continue(ctx, message string) (GitMergeResult, error)` — refused with the exact text while `ls-files -u -z` is non-empty; merge/cherry-pick/revert: `Commit(ctx, message, false)` (empty → `--no-edit`); rebase: `rebase --continue` with the editor args; a rebase may stop again → `Done:false`.
- `func (w *GitWriter) Skip(ctx) (GitMergeResult, error)` — rebase only, `rebase --skip`; else refused `Skip is for a rebase`.
- `func (w *GitWriter) Abort(ctx) error` — `<kind> --abort` per `ReadGitOp`; nothing in progress → `Nothing to abort`.
- Branch names starting with `-` are refused, as 3a-iv's.
- A rebase that rewrote commits the upstream already has ends its `Summary` with `; commits already pushed were rewritten, so Push is refused as behind`. Continue or Abort after which git kept an autostash it could not reapply ends with `; your uncommitted changes are in git stash`.

- [ ] **Step 1: Failing tests:** `TestMergeCleanCommitsWithGitsMessage` (subject `Merge branch 'feature/search'`), `TestMergeConflictStopsAndLists` (`Done:false`, `Conflicts:["a b.txt"]`, `MERGE_HEAD` kept), `TestMergeCarriesADirtyTree` (autostash; Abort gives it back), `TestRebaseCleanFinishes`, `TestRebaseConflictStops`, `TestContinueRefusedWhileAConflictIsUnstaged`, `TestContinueRebaseNeedsNoEditor` (Review Focus 4: two conflicting commits resolved in turn, finishes, messages kept, under a 10 s context), `TestContinueMergeUsesTheBoxOrGitsMessage`, `TestSkipDropsTheCommit`, `TestRebaseOfPushedCommitsSaysSo`, `TestAbortEachKindRestoresTheTree` (merge, rebase, cherry-pick, revert), `TestMergeRefusesADashBranch`, `TestMergeRefusedMidRebase`.
- [ ] **Step 2:** `go test ./internal/wakilcore -run 'Merge|Rebase|Continue|Skip|Abort'` — FAIL.
- [ ] **Step 3:** Implement in `gitmerge.go`; conflicts from `ls-files -u -z`, unique paths in order.
- [ ] **Step 4:** Same command — PASS.
- [ ] **Step 5:** Commit `3a-v-b: merge, rebase, continue, skip and abort`.

### Task 3: Go — resolve, clashes left in place, Undo Apply, the conflict sides

**Files:** Create `internal/wakilcore/gitresolve.go`, `gitresolve_test.go`. Modify `gitremote.go:331-338` (Pull), `gitstash.go:142-164` (`StashApply`), `gitbranch.go:239-245` (Bring Them Along, R5), `gitdiff.go:89` (`ours`, `theirs`), and the tests that pinned the old behaviour: `TestPullRebaseConflictAbortsAndListsPaths`, `TestAConflictingPullGivesTheUncommittedChangesBack`, `TestPopClashKeepsStashAndCleansTree`, `TestAClashNeverDeletesTheOperatorsFiles`, `TestBringAlongClashLeavesCleanTreeAndStash` (rename to what they now assert).

**Interfaces:** Consumes Task 1–2. Produces
- `func (w *GitWriter) Resolve(ctx, path, take string) error` — `take`: `current` (`checkout --ours -- p`, `add`), `incoming` (`--theirs`), `keep` (`add`), `delete` (`rm -q`); refused unless `p` is unmerged: `<p> has no conflict`.
- `type GitClashFile struct { Path, Hash string }` json `path, hash` (worktree blob id after the clash, `""` if absent); `type GitStashClash struct { ID string; Files []GitClashFile; Created, Conflicts []string }` json `id, files, created, conflicts`.
- `StashApply` returns `(string, *GitStashClash, error)`; `SwitchResult.Clash *GitStashClash` json `clash,omitempty`; notes per Global Constraints. `GitRemoteResult.Conflicts` read with `-z`; Pull no longer calls `abortInProgress` on conflicts (only on cancel).
- `func (w *GitWriter) StashUndoApply(ctx, c GitStashClash) error` — refused (exact text, first path) unless each file is still unmerged or its worktree hash equals `Hash`; then the 3a-iv put-back: `restore --source=HEAD --staged --worktree --` the tracked files, remove `Created` (via `removeInRoot`), and clear any leftover unmerged index entries.
- `GitShow(…, "ours"|"theirs")` → `show :2:<rel>` / `:3:<rel>`; a missing stage → `Absent: true`.

- [ ] **Step 1: Failing tests:** `TestResolveEachTake` (current, incoming, keep, delete on UU and UD fixtures), `TestResolveRefusesAResolvedFile`, `TestPullConflictIsLeftInPlace` (both strategies; note exact; `ls-files -u` non-empty; path `a b.txt` whole — Review Focus 1), `TestStashPopClashLeavesConflictsAndTheStash`, `TestBringAlongClashLeavesConflictsAndTheStash` (no file deleted), `TestUndoApplyRestoresAndKeepsTheStash`, `TestUndoApplyRefusesAnEditedFile` (Review Focus 5), `TestShowOursAndTheirs` (and `Absent` for the missing side of UD — Review Focus 3).
- [ ] **Step 2:** `go test ./internal/wakilcore -run 'Resolve|LeftInPlace|Clash|UndoApply|OursAndTheirs'` — FAIL.
- [ ] **Step 3:** Implement; record `Files`' hashes with `hash-object -- <p>` right after the clash.
- [ ] **Step 4:** `go test ./internal/wakilcore` — PASS.
- [ ] **Step 5:** Commit `3a-v-b: conflicts left in place, resolved by side, and a stash clash put back`.

### Task 4: wakil-git — seven tools

**Files:** Modify `cmd/wakil-git/main.go` (`addWriteTools`; descriptions of `git_status`, `git_pull`, `git_stash_apply`, `git_stash_pop`, `git_switch`, `git_show`'s rev), `cmd/wakil-git/main_test.go`.

**Interfaces:** Produces tools `git_merge {root, branch}`, `git_rebase {root, onto}`, `git_continue {root, message?}`, `git_skip {root}`, `git_abort {root}`, `git_resolve {root, path, take}`, `git_stash_undo_apply {root, clash}` — each the `git_switch` pattern (main.go:379) with `remoteContext`; merge/rebase/continue/skip return `GitMergeResult` (a stop is not an error); `git_stash_apply`/`_pop` return `{note, clash?}`.

- [ ] **Step 1:** Failing: `TestToolListIsTheReadsAndTheWrites` gains the seven names; `TestMergeToolStopsOnConflicts` (a client call returns `done:false` and the paths, not `IsError`).
- [ ] **Step 2:** `go test ./cmd/wakil-git` — FAIL. **Step 3:** Register the tools. **Step 4:** PASS.
- [ ] **Step 5:** Commit `3a-v-b: wakil-git merge, rebase, continue, skip, abort, resolve, undo apply`.

### Task 5: WakilKit — the conflicts group, state, and the Changes actions

**Files:** Modify `Git/GitStatus.swift` (`GitGroup` gains `conflicts` first; `GitFileRow.kind`, `.markers`; `GitRootState.state: GitOpState?`; decoding), every `GitGroup` switch the map found (`gitGroupRank`, `editorChangesRank`, `gitGroupLabel`, `editorDiffGroupTitle`, `editorDiffRevs`, the `groupSchema` enums), `Git/GitPaneLines.swift` (labels), `Editor/EditorChangesWrites.swift` (actions), `MCP/ConfirmationDescription.swift`, `App/WindowModel+Branches.swift` (clash memory, R4). Create `Git/GitConflicts.swift`. Tests: `GitStatusTests`, `GitPaneLinesTests`, `EditorChangesWritesTests`, `WindowModelBranchesTests`, `MCPServerTests`, pinned lists.

**Interfaces:** Consumes Task 4's tools. Produces
- `public struct GitOpState: Sendable, Equatable { kind, incoming, onto: String; step, steps: Int; head: String }`; `public struct GitStashClash: Sendable, Equatable, Codable` mirroring Go.
- `func gitOpStateLabel(_ s: GitOpState) -> String` (header copy); `func changesCommitTitle(_ r: GitRootState) -> String` (`Commit` / `Commit All` / `Commit Merge` / `Continue Rebase`, lifted from EditorColumn.swift:872); `func changesConflictsReason(_ r: GitRootState) -> String?`; `func gitConflictKindLabel(_ xy: String) -> String`; `func changesAbortConfirmation(_ s: GitOpState) -> String`, `changesSkipConfirmation(id7:subject:)`, `changesTakeConfirmation(path:take:incoming:)`, `changesUndoApplyConfirmation(message:)`.
- Actions (root absolute, `.mutate`, `.agentReachable`): `editor_changes_merge {root, branch}`, `_rebase {root, onto}`, `_continue {root, message?}`, `_skip`, `_abort`, `_take {root, path, take}`, `_keep_file {root, path}`, `_stash_undo_apply {root}` (reads `changesClashes[root]`; none → refused `No stash clash to undo`); prices per Global Constraints; `editor_changes_continue` uses the box's message when given.
- `WindowModel.changesClashes: [String: GitStashClash]`, set from stash apply/pop and switch results, cleared per R4.
- While a merge, cherry-pick or revert is in progress and the root's box is empty, the box is filled with `state.message` once (Rule 2: the operator's edits are kept; leaving keeps them).
- Every write goes through `write(root, action:)`, so the spinner, the single flight and Cancel-before-git-starts follow 3a-iii (Rules 4, 5).

- [ ] **Step 1: Failing tests:** `conflictsComeFirstWithTheirKind` (decoding a `conflicts` row and `state`), `theHeaderNamesTheState` (all four labels, exact), `theCommitButtonFollowsTheState`, `theReasonCountsConflicts` (`Resolve 1 conflict first`, `Resolve 2 conflicts first`, nil at 0), `theConfirmationsReadExactly`, `theBoxFillsOnceWithGitsMessage`, `theAbortSkipTakeAndUndoGateOnlyTheAgent` (WindowModelBranchesTests:66 pattern), `gatedGitWritesHaveSentences` (MCPServerTests), `aStashClashIsRememberedThenForgotten`, plus the pinned lists.
- [ ] **Step 2:** `make app-test` filtered: `cd app && swift test --filter 'GitStatusTests|GitPaneLinesTests|EditorChangesWritesTests|WindowModelBranchesTests|MCPServerTests'` — FAIL.
- [ ] **Step 3:** Implement. **Step 4:** `make app-test` — PASS.
- [ ] **Step 5:** Commit `3a-v-b: WakilKit conflicts group, state and the Changes actions`.

### Task 6: WakilKit — conflict blocks in the editor

**Files:** Create `Editor/EditorConflicts.swift`, `app/Tests/WakilKitTests/EditorConflictsTests.swift`. Modify `Git/GitHistory.swift` (`EditorDiffSource.conflict`, key, params, revs `("ours","theirs")`), `Editor/EditorTabs.swift` (title), `Editor/EditorActions.swift` (`fetchDiff`, actions), `Command/CommandCatalog.swift` (two `pane(...)` commands).

**Interfaces:** Consumes Task 5's group (a tab's file is conflicted iff its root lists it in `.conflicts`). Produces
- `public struct EditorConflictBlock: Sendable, Equatable { start, separator, end: Int; currentLabel, incomingLabel: String }` (1-based lines of `<<<<<<<`, `=======`, `>>>>>>>`; a diff3 `|||||||` base section is dropped from Accepts).
- `func editorConflictBlocks(_ text: String) -> [EditorConflictBlock]` — only complete blocks, markers at line start followed by a space or end of line.
- `func editorConflictAccept(_ text: String, _ b: EditorConflictBlock, take: EditorConflictTake) -> (range: EditorRange, text: String)`, `enum EditorConflictTake: String { current, incoming, both }` — keeps the file's line ending.
- Actions on the focused editor pane's active tab: `editor_conflict_accept {block, take}` (same kind/audience as `editor_replace_range`; applied through it, R2), `editor_conflict_next`, `_previous` (move the cursor to the next/previous block's start, wrapping), `editor_conflict_compare` (opens `.conflict` diff, `.control`). Refused on a tab whose file is not in the conflicts group: `a.txt has no conflict`.
- ⌘K `Next Conflict` / `Previous Conflict` (`scope: .pane("editor")`, available when the active tab is conflicted).

- [ ] **Step 1: Failing tests:** `blocksParseWithTheirLabels`, `aBlockAtTheFirstAndLastLine`, `crlfIsKept` (each take), `aLoneSeparatorIsNotABlock` (Review Focus 2), `diff3BaseIsDropped`, `eachTakeReplacesOnlyItsBlock`, `acceptIsRefusedOffAConflictedFile`, `nextAndPreviousWrap`, `compareOpensTheCurrentAndIncomingSides` (title `a.txt (Current ↔ Incoming)`, an absent side reads empty — Review Focus 3), `theConflictCommandsNameRegisteredActions`.
- [ ] **Step 2:** `cd app && swift test --filter 'EditorConflictsTests|CommandCatalogTests'` — FAIL. **Step 3:** Implement. **Step 4:** `make app-test` — PASS.
- [ ] **Step 5:** Commit `3a-v-b: conflict blocks, Accept, Compare and Next/Previous Conflict`.

### Task 7: WakilApp — the Changes view and the picker's Merge and Rebase

**Files:** Modify `app/Sources/WakilApp/EditorColumn.swift` (group drawing, rows with kind or markers label, row `.contextMenu` with the takes and their in-place confirm, header state and buttons, the reason, Abort/Skip confirms in ▾, Undo Apply on the group header; ▾ → Branch gains `Merge Branch…` / `Rebase Branch…`), `BranchPicker.swift` (`BranchPickerMode` gains `.merge`, `.rebase`: rows are local branches but the current, then remote; `pick` calls the new `BranchPickerActions.merge`/`.rebase` closures, defaulted so `ContextLine.swift:460` still builds), `Canvas.swift` (wiring), `ChangesStashes.swift` only if its `confirm` helper is reused (move it to a shared `ChangesConfirm.swift` and add that file to `AuditedSources`).

**Interfaces:** Consumes Task 5's helpers and actions; every label comes from those helpers, none is inline.

- [ ] **Step 1:** Build: `make app-bundle` — no warnings in the touched files; `go test ./e2e/driver -run TestEveryAuditedControlIsNamed` — no new unnamed control.
- [ ] **Step 2:** Run the app on a fixture repo with a conflicting merge (Task 9's setup) and check by screenshot: the group above Staged, `merging feature/search`, `Commit Merge` disabled with `Resolve 1 conflict first`, ▾ `Abort Merge` asks in place, a row's menu offers the takes and asks, `+` resolves, the picker's filter is focused in Merge mode (Rule 3) and Escape closes it.
- [ ] **Step 3:** Commit `3a-v-b: the Changes view for conflicts, and Merge and Rebase from the picker`.

### Task 8: WakilApp — the editor's conflict decorations and actions row

**Files:** Modify `monaco-host.html` (`wakilSetConflicts(key, blocks)`: tints current/incoming ranges, `(Current Change)` / `(Incoming Change)` after the marker lines, one overlay widget per block with the four actions posting `{type:'conflict', key, block, op}`; `wakilDispose`/`wakilRekey` learn the map), `MonacoEditorRenderer.swift` (`setConflicts`, `onConflict`), `EditorPane.swift` (push blocks for a conflicted file tab on each text change; a press dispatches `editor_conflict_accept` / `_compare`; opening a conflicted file reveals its first block).

**Interfaces:** Consumes Task 6's `editorConflictBlocks` and actions.

- [ ] **Step 1:** `make app-bundle`; run the app on the fixture: blocks tinted, the row above each block, each Accept replaces only its block and ⌘Z restores it, the cursor stays at the block's place (Rule 6), Compare opens the tab, ⌘K Next/Previous Conflict move between blocks; a file with markers that is not conflicted shows no row.
- [ ] **Step 2:** Commit `3a-v-b: conflict blocks tinted in the editor with their actions row`.

### Task 9: Charter, runbook, and the e2e strings that changed

**Files:** Modify `docs/wakil/north-star.md` (Invariant 6: `Nine have earned in`, row `Merge, rebase, continue, skip, abort, resolve — local git inside the roots | wakil-git | 2026-10-24`), `docs/wakil/decisions.md` (Decision 47 per the spec's *Charter changes*; amend 44 and 46 in place with a dated line; appendix entry `### 2026-10-24 — merge, rebase and resolving conflicts`), `e2e/checks/seeded/3a-iii-remote-conflict.jsonl` and `3a-iv-branch-blocked.jsonl` (new notes; the conflict is now left in place). Create `docs/wakil/phase-3a-v-b-acceptance.md` (setup script in `$TMPDIR/walk-3a-v-b` with a `main`/`feature/search` merge conflict, a rebase of three commits, a stash that clashes; at most ten walk steps covering: merge stop and per-block Accept then Commit Merge; a row take with its confirm; Abort; rebase Continue and Skip; stash clash Undo Apply; Pull left in place; the agent resolving a file without a plane for keep and with one for take).

- [ ] **Step 1:** `make docs-check` (north-star word budget; the pre-existing failure stays as it was), `bash scripts/public-check.sh` — exit 0.
- [ ] **Step 2:** `make e2e E2E_ONLY='e2e/checks/seeded/3a-iii-remote-conflict.jsonl e2e/checks/seeded/3a-iv-branch-blocked.jsonl'` — PASS (queue behind another session's run).
- [ ] **Step 3:** Commit `3a-v-b: Decision 47, Invariant 6's ninth write, and the runbook`.
