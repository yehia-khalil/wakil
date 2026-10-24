# 3a-v: conflicts, history and blame — accept current or incoming, the Timeline, inline blame

**Date:** 2026-10-23
**Status:** design written from the phase-map row at the operator's ask ("skip" the questions; VS Code
as the reference, as for 3a-iv); awaiting the operator's review
**Sub-phase:** 3a-v, the last Git row (3a-iv met 2026-10-23, #55/#56). Follows main c31d96c.

---

## Problem

Wakil commits, pushes, pulls, switches and stashes, but it steps around every conflict: a conflicting
pull is aborted ("Resolve them in a terminal, or wait for Wakil's conflict view"), a stash that clashes
is put back, and Merge and Rebase are not there at all. And it cannot answer the two questions asked
of a file most often after "what changed": *who wrote this line, and why* (blame), and *what has
happened to this file* (history). Today both are a terminal and `git log -p`.

## The reference: VS Code

What VS Code does, and what this design keeps:

- **Conflicts.** Source Control lists conflicted files in a **Merge Changes** group above the others.
  In the editor each conflict block is tinted (current green, incoming blue) with a row of actions
  above it: *Accept Current Change | Accept Incoming Change | Accept Both Changes | Compare Changes*.
  Staging a file marks it resolved. While a merge is in progress the commit button reads **Commit
  (Merge)** with git's message filled in; during a rebase it reads **Continue**. *Abort Merge*, *Abort
  Rebase* and *Skip* are commands. ⋯ → Branch has **Merge Branch…** and **Rebase Branch…**.
- **Timeline.** A **Timeline** section under the Explorer shows the active file's commits, newest first:
  subject, author, age. Clicking one opens that commit's change to the file as a diff. *Uncommitted
  Changes* sits on top when the file is dirty. Right-click copies the commit id or message.
- **Inline blame.** At the end of the cursor's line, faded: `Author, 3 days ago • subject`; a line not
  yet committed reads *Not Committed Yet*. Hovering shows the full commit with *Open Changes*.

## Decisions the operator took

- **VS Code's flow is the reference** (2026-10-23, "skip").
- **Option A carries over** (3a-iv, 2026-10-23): a write that throws work away asks the operator in place
  from the pane, and on the permission plane only when the agent or voice asks for it.

## Calls made for the operator (flagged for review)

1. **One design, two plans.** *3a-v-a, history and blame* — reads only, no new write — lands first;
   *3a-v-b, conflicts* — merge, rebase and resolving — second. Each is walkable on its own.
2. **Conflicts are left in place now, as VS Code leaves them.** A pull (Merge or Rebase strategy), a stash
   apply or pop, and Bring Them Along that clash no longer put things back: they stop with the conflicts
   in the tree and say so — `Pull stopped on conflicts in a.txt; resolve them below`. A popped stash that
   clashes stays in the list (git keeps it) until the operator drops it. This reverses 3a-iii's abort and
   3a-iv's "nothing is left half-merged" (Decisions 44 and 46 are amended); Abort brings back the tree
   from before.
3. **Accept actions edit the buffer, not git.** Accept Current / Incoming / Both rewrite that block in the
   open tab as one undoable edit (⌘Z), like typing; autosave or ⌘S writes the file. Only staging, Commit,
   Continue, Skip and Abort are git writes.
4. **Staging a file that still has markers is allowed** (Rule 7: override, don't refuse), and the row then
   reads `a.txt — staged with conflict markers` in amber until they are gone. No confirmation: staging
   destroys nothing. Wakil keeps no list of its own for this: `git_status` scans each staged file (up to
   1 MB) for a complete marker block — `<<<<<<< `, `=======`, `>>>>>>> ` at line starts — and flags it,
   and the editor's actions row shows for a tab whose file is conflicted *or* flagged.
5. **Whole-file choices on a conflicted row**, VS Code's right-click: **Accept All Current** and **Accept
   All Incoming** (`checkout --ours|--theirs`, then stage). A delete/modify conflict offers **Keep File**
   or **Delete File** instead.
6. **What throws work away asks, in place** (Rule 1), and is priced *gate* for the agent and voice (Option
   A):
   - **Abort Merge / Abort Rebase**: `Abort the merge? The tree goes back to before it, and your
     resolutions are lost.`
   - **Skip Commit**: `Skip abc1234 "Seed search"? Its changes are left out of the rebase.`
   - **Accept All Current / Accept All Incoming / Delete File**: `Take all of HEAD's a.txt? Any edits you
     made to it are lost.` (Delete File: `…the file is deleted.`)
   - **Undo Apply** (call 13).
   Everything else is *allow*: merge, rebase, continue, resolve-by-staging, Keep File, the Accepts in the
   editor (undoable).
7. **The Timeline lives under Files**, as VS Code's lives under the Explorer: a collapsible section at the
   bottom of the Files tab for the focused editor tab's file. Fifty commits, then **Load more**. Renames
   are followed.
8. **Inline blame is on by default**, with an On/Off row in Settings → Editor (VS Code defaults it off;
   the operator asked for blame). It shows only on the cursor's line, never on every line.
9. **Blame reads the tab's text, saved or not**, so its lines always match what is on screen: lines the
   operator has changed read *Not committed yet*.
10. **Not in this phase:** VS Code's three-way Merge Editor, the Source Control Graph, local (save)
   history, starting a cherry-pick or revert, and interactive rebase. A cherry-pick or revert begun in a
   terminal is still shown and can be resolved, continued and aborted like a merge.
11. **Charter tidy:** north-star's Invariant 6 table says "Eight have earned in" but lists seven; 3a-iv's
   branches-and-stash row is added with this phase's ninth.
12. **Merge and Rebase carry uncommitted changes with `--autostash`**, as Pull does (3a-iii), so Abort
   really returns the tree from before and a dirty tree is never refused for it.
13. **A stash clash can be put back.** Right after Wakil's own stash apply, pop or Bring Them Along stops
   on conflicts, the Merge Changes group's header offers **Undo Apply**: it restores the files the stash
   touched from HEAD and removes the untracked files it created (3a-iv's recovery, kept), and the stash
   is still in the list. Wakil remembers that clash for the session only; after a relaunch, or for a clash
   made in a terminal, the operator resolves it by hand, as in VS Code. The stash's non-conflicting
   changes are already in the tree (some staged, as git leaves them); Commit treats them as any other
   change.

## What the operator gets

### History and blame (3a-v-a)

- **Timeline** (Files tab, bottom, collapsible; remembers open/closed). Header `Timeline · a.txt`. Rows:
  subject, author, age; on top, `Uncommitted changes` when the file differs from HEAD. A row opens a
  read-only diff tab `a.txt (abc1234)`: the file before that commit on the left (absent for the commit
  that added it), after it on the right, the path as it was then. `Uncommitted changes` opens the
  existing HEAD ↔ working-tree diff. The tooltip carries the full message, author, email, date and id;
  the row's menu has **Copy Commit ID** and **Copy Commit Message**. No file, a scratch tab, an untracked
  file or a file outside a git root: `No history for this file.`
- **Inline blame.** At the end of the cursor's line, dim, after a gap: `Ada Lovelace, 3 days ago •
  Seed the search page`, or `Not committed yet`. Hovering it shows the commit (subject and body, author,
  date, short id) with **Open Changes** (the same diff tab as the Timeline's row) and **Copy Commit ID**.
  Not shown in diff tabs, read-only tabs, scratch tabs, untracked or binary files.

### Conflicts (3a-v-b)

- **Merge Branch…** and **Rebase Branch…** in ▾ → Branch: the 3a-iv picker, local and remote branches,
  pick one. A merge that applies cleanly commits with git's own message, as VS Code's does; a rebase that
  applies cleanly finishes. Either can stop on conflicts.
- **The root header names the state**, in amber: `merging feature/search`, `rebasing 2/5 onto main`,
  `cherry-picking abc1234`. The header's buttons follow it:
  - merge or cherry-pick: the commit button reads **Commit Merge**, its box filled from git's message
    when empty; **Abort Merge** sits in ▾;
  - rebase: **Continue Rebase** (keeps the commit's message), and in ▾ **Skip Commit** and **Abort
    Rebase**;
  - a stash clash has no state to abort: only the Merge Changes group, and the Stashes group still
    holding the stash.
- **Merge Changes**, a group above Staged with each conflicted file: `a.txt  both modified` (or *added
  by both*, *deleted by them*, …), + to mark it resolved, the row menu's whole-file choices (call 5).
  Commit Merge and Continue Rebase are disabled, with the reason beside them, while the group is not
  empty. After a Wakil stash clash its header also has **Undo Apply** (call 13).
- **In the editor**, each block between `<<<<<<<` and `>>>>>>>` is tinted, with the actions row above it:
  **Accept Current Change · Accept Incoming Change · Accept Both Changes · Compare Changes**. The labels
  name the sides as the markers do (`HEAD`, `feature/search`). Compare Changes opens a read-only diff tab
  of the whole file, current (stage 2) against incoming (stage 3). Opening a conflicted file reveals its
  first block; ⌘K has **Next Conflict** and **Previous Conflict**.

### The agent and voice

Reach every action the pane has, by the same names. The agent reads the Timeline and blame as tools, so
"who changed this line" and "what happened to the search page last week" are one call.

## What it does not do

- The three-way Merge Editor, the Source Control Graph, local history, starting cherry-pick or revert,
  interactive rebase, `merge --squash`, choosing a merge strategy.
- Push stays a fast-forward: after rebasing commits already pushed, Push is refused as behind (3a-iii),
  and the note says the branch was rewritten. Wakil never forces.
- Blame of a whole file in the gutter (VS Code's *Toggle Blame*): the cursor line only.

## Design

### `wakil-git` — reads (3a-v-a)
- The read allowlist gains `blame` with `--porcelain`, `--contents=-` (stdin) and `--`, and for `log`
  `--follow`, `--max-count=`, `--skip=` and `--name-status`. Signature formats stay refused.
- `git_file_history {root, path, skip?, count?}`: `{commits: [{id, parents, author, email, date, subject,
  body, path}]}` — `path` the file's name at that commit, from `--follow --name-status`.
- `git_blame {root, path, text?}`: one entry per line, `{line, id, author, date, subject}`, an all-zero id
  for uncommitted lines; `text` is the tab's buffer, sent on stdin. Ten-second deadline; past it, blame
  shows nothing and says nothing (it is decoration).
- `git_show` learns `commit:<sha>` and `commit-parent:<sha>` (40-hex only, as the stash sides) and, for
  3a-v-b, `ours` and `theirs` (index stages 2 and 3).

### `wakil-git` — writes (3a-v-b, Invariant 10)
On 3a-ii's write lock and safety args; never `--force`, never `--hard` except inside Abort's own git and Undo Apply:
- `git_status` keeps the unmerged XY code (today folded to `U`) as a `conflicts` group with a kind, and
  gains `state: {kind: merge|rebase|cherry-pick|revert, incoming, step, steps}` from the git dir, and a
  `markers` flag on staged files (call 4).
- `git_stash_undo_apply {root, id, paths, created}`: call 13's put-back, the 3a-iv recovery as its own
  write; refused unless every path is still unmerged or unchanged since the clash.
- `git_merge {root, branch}`, `git_rebase {root, onto}`: `--autostash` (call 12); stop on conflicts and
  report the paths.
- `git_continue {root}`: commit for a merge, cherry-pick or revert (message from the box, else git's);
  `rebase --continue` with `GIT_EDITOR=true`. Refused while a conflict is unstaged.
- `git_skip {root}` (rebase), `git_abort {root}` (`merge|rebase|cherry-pick|revert --abort`).
- `git_resolve {root, path, take: current|incoming|keep|delete}`: `checkout --ours|--theirs` then `add`,
  or `add` / `rm` for delete/modify.
- Pull (Merge, Rebase), stash apply/pop and Bring Them Along stop leaving conflicts (call 2), and report
  the clash's paths and created files so the app can offer Undo Apply (call 13). Pull's
  autostash, when git holds it across a stopped pull, comes back on Continue or Abort; the note says
  where it is if git keeps it.
- The `inProgress` checks in `gitbranch.go` and `gitremote.go` become one, learning cherry-pick and
  revert.

### Actions — WakilKit (Invariant 2)
- 3a-v-a: `editor_timeline {path?}` and `editor_blame {path?, line?}` (reads), `editor_open_commit_diff
  {root, path, commit}` (control). Agent-reachable, allow.
- 3a-v-b: `editor_changes_merge`, `_rebase`, `_continue`, `_skip`, `_abort`, `_resolve`, and
  `editor_conflict_accept {block, take: current|incoming|both}`, `editor_conflict_next|previous`,
  `editor_conflict_compare`, `editor_changes_stash_undo_apply`. `_abort`, `_skip`, `_resolve` with
  `current|incoming|delete`, and `_stash_undo_apply` carry `agentPrice: .gate`; the rest allow.
- The `.diff` tab subject gains `commit` beside `stash`; `conflicts` joins `GitGroup`.

### WakilApp
- `monaco-host.html`: an after-line decoration for the blame on the cursor line, driven by the `view`
  report it already sends, with a hover; conflict block decorations and an actions row above each block
  (a CodeLens provider or view zones — the builder's call), reporting presses back as a new message.
- `EditorColumn`: the Timeline section under the tree; the Merge Changes group and row menu; the header's
  state and buttons; the ▾ Merge/Rebase items reusing the 3a-iv picker in a new mode.
- Settings → Editor: **Inline blame** On/Off, the app tier, as Show ignored files; pushed to the page as
  ghost text's switch is.

### Interaction rules
1 — Abort, Skip, the whole-file Accept Alls, Delete File and Undo Apply confirm, in place (call 6);
the editor's Accepts are undoable and staging destroys nothing. 2 — the commit box's
filled message is the operator's to change; leaving keeps it. 3 — Merge/Rebase's picker filter arrives
focused. 4/5 — merge, rebase, continue and the Timeline's load show a spinner, are not fired twice, and
can be cancelled before git starts (never mid-merge). 6 — after an Accept the cursor stays at that
block's place; after a resolve the operator stays in the Changes list. 7 — staging with markers is
allowed and marked (call 4). 8 — git's stops and refusals are shown whole. 9 — nothing chooses a side
for the operator.

## Errors and edges
- Conflicts made in a terminal are shown the same way; Wakil does not need to have started them.
- A switch, stash, pull, merge or rebase while a merge or rebase is in progress: refused, naming it (as
  today).
- An unsaved tab of a conflicted file when Accept All / Abort runs: the tab is marked changed on disk, as
  an outside edit is today.
- Markers git did not write (a file that just contains `<<<<<<<`): the actions row appears only for files
  in the conflicts group.
- A huge file: blame past its deadline shows nothing; the Timeline still loads.
- A file renamed in history: the Timeline follows it; blame follows git's default rename detection.

## Testing
- Go, against fixture repositories with a bare remote: history with a rename and paging; blame of saved
  and unsaved text and the uncommitted line; the commit sides; every unmerged XY kind; merge and rebase
  clean and conflicted; continue refused with a conflict unstaged, then allowed; skip; abort of each
  kind; resolve each `take`; pull and stash pop leaving conflicts; the in-progress state read.
- WakilKit: Timeline rows and the uncommitted row; blame text and age; the conflict blocks parsed from
  text and each Accept's result (including nested-looking and CRLF text); the header state and button
  labels; prices (abort gated for the agent).
- e2e (the auditor): the Timeline row opening its diff; the blame annotation on the cursor line and its
  setting; a conflicted merge resolved by Accept and by row, then committed; abort's in-place confirm;
  parity by dispatch.

## Charter changes this sub-phase makes
- **Decision 47:** conflicts are left in place and resolved in Wakil, VS Code's way; merge, rebase,
  continue and resolve-by-staging priced allow; abort, skip, the whole-file takes and Undo Apply ask in
  place and are *gate* for the agent and voice; the amendments to
  Decisions 44 (Pull no longer aborts) and 46 (a stash clash is left to resolve).
- **Invariant 6:** the ninth row (merge, rebase, continue, skip, abort, resolve), and 3a-iv's missing
  eighth row (call 11).
- North-star §8: 3a-v's row stays as written; the plans are 3a-v-a and 3a-v-b.
