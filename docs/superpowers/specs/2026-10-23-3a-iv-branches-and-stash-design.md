# 3a-iv: branches and stash — the branch picker, switch, create, rename, delete, stash, pop, apply

**Date:** 2026-10-23
**Status:** design written from the phase-map row at the operator's ask ("skip questions. take vscode
flow as reference"); awaiting the operator's review
**Sub-phase:** 3a-iv, the Git row after 3a-iii (met 2026-10-22, #48/#49). Follows main 164af87.

---

## Problem

Wakil commits, pushes and pulls (3a-ii, 3a-iii), but every root stays on the branch it was on.
Starting a feature, looking at a teammate's branch or setting half-done work aside means a terminal
per root, or an agent turn spent on `git switch` and `git stash`. The context line says where the
operator is — organisation, project, environment — and says nothing about the one thing that changes
most often in a day: the branch.

## The reference: VS Code

The operator asked for VS Code's flow. What it does, and what this design keeps:

- **The branch in the status bar**, one click from a **Quick Pick**: a filter field on top, then
  *Create new branch…*, *Create new branch from…*, the local branches, then the remote branches
  (`origin/x` checks out a new local branch tracking it). Typing filters; Return checks out.
- **A switch with changes in the way** asks once: *Stash & Checkout*, *Migrate Changes* (stash, switch,
  pop), or *Cancel*. A switch git can make with the changes carried along just happens.
- **Source Control's ⋯ → Branch:** Create, Create From, Rename, Delete, Publish.
- **⋯ → Stash:** Stash, Stash (Include Untracked), Stash Staged, Apply Latest, Apply…, Pop Latest,
  Pop…, Drop…, Drop All…, View Stash. A stash asks for an optional message.

## Decisions the operator took

- **VS Code's flow is the reference** (2026-10-23), mapped onto Wakil's own surfaces below.

## Calls made for the operator (flagged for review)

1. **The picker lives in the context line.** A **Branch** segment after Environment, at rest and
   promoted, opening a dropdown like Project's and Environment's. The Changes view's root header makes
   its branch name a button that opens the same picker for that root. ⌘K gains *Switch Branch…*.
2. **Several roots, one segment.** The segment shows the branch of the *active root* — the root of the
   focused editor tab, else the first git root. With several roots it reads `api: main`, and the
   dropdown starts with the roots as tabs, each with its branch, so another root is one click away.
3. **A stash list in the Changes view.** Below a root's groups, a **Stashes** group (collapsed when
   there are any, absent when none) lists each stash — message, branch it was made on, age — with
   **Apply**, **Pop** and **Drop** on hover, as rows have + − ↺. A stash row expands into the files it
   holds (untracked ones included); a file opens the existing one-file diff tab against the stash's
   parent, read-only. This stands in for VS Code's Apply…/Pop…/Drop… pickers and View Stash.
   **A stash is named by its commit id as well as its position**: the list is shared with every
   worktree and the terminal, so an action whose position no longer holds that id is refused with
   `The stash list changed; look again` rather than touching another stash.
4. **The ▾ menu gets Branch and Stash submenus**, VS Code's ⋯ items: *Create Branch…*, *Create Branch
   From…*, *Rename Branch…*, *Delete Branch…*; *Stash*, *Stash Including Untracked*, *Stash Staged*,
   *Pop Latest Stash*, *Apply Latest Stash*. Publish stays the remote button's (3a-iii).
5. **A switch git refuses** (local changes would be overwritten) shows, in the picker where the operator
   is, `Your changes to a.txt would be overwritten by main.` and **Stash and Switch**, **Bring Them
   Along** (stash, switch, pop — VS Code's *Migrate*), **Cancel**. No force or discard option: throwing
   work away is ↺'s job, with its Trash copy.
6. **A clash keeps the stash and leaves the folder clean.** When Bring Them Along, Pop or Apply clashes,
   git leaves conflict markers; Wakil puts the folder back to the branch's clean state (the stash still
   holds every change, so nothing is lost) and says so: `Switched to main; your changes clash with it
   and are kept in git stash`. Resolving a clash is 3a-v's; until then the operator is never left in a
   state Wakil cannot get them out of.
7. **Names.** A typed branch name has its spaces replaced with `-` (VS Code's default); anything else
   git refuses (`check-ref-format`) is shown whole under the field, and the field keeps the text
   (Rules 7, 8). **Create** with a name that exists switches to it instead of failing (Rule 7). **Rename**
   renames the current branch only (as VS Code does), and a name that exists is refused with git's
   words — forcing it would destroy the other branch. **Delete Branch…** picks the branch in the
   picker, then confirms in place.
8. **Delete asks, in place** (Rule 1): `Delete feature/x? Its 3 commits not on main are kept only in
   git's reflog.` with **Delete** and **Keep it**; a fully merged branch says so and asks the same way.
   The current branch has no Delete (git cannot). Drop and Drop All ask the same way:
   `Drop "wip search"? It cannot be applied again.`
9. **Prices.** Switch, create, rename, stash, apply and pop stay on this Mac and undo — allow for every
   channel, voice and the agent included, as 3a-ii's writes are (Decision 43). **Delete Branch, Drop
   and Drop All are priced *gate* for the agent and voice** — the operator's confirmation in the
   permission plane, since they cannot be undone from Wakil; from the pane, their in-place confirmation
   is the operator's own (Rule 1).
10. **Remote branches** are listed from the last fetch; the picker has a **Fetch** row at the end, so a
    teammate's new branch is one row away. Deleting a remote branch is not in this phase.

## What the operator gets

### The Branch segment and its picker
- At rest: `main` beside the environment chip, or `api: main` with several roots; `detached at 3f2a1c9`
  on a detached HEAD; nothing for a project with no git root.
- Promoted, a click opens the picker in place:
  - a filter field, focused (Rule 3), Escape closes, ↑↓ move, Return picks;
  - with several roots, the roots as tabs on top, each `name · branch`;
  - **Create branch "‹typed›"** as the first row when the filter text names no branch, then **Create
    branch from…** (choose the base, then the name);
  - **Local** branches, most recently committed first, the current one marked, each with ↑↓ against
    its upstream when it has one;
  - **Remote** branches not checked out locally (`origin/feature-y`), picking one creates the local
    branch tracking it;
  - **Fetch** at the end, with its spinner and Cancel (Rules 4, 5).
- Picking switches the root; the picker closes and the operator stays where they were (Rule 6). The
  Changes view, Files tree, open tabs and the context line follow the new branch's tree on their own
  (the root watchers already do this for a terminal `git switch`).

### The Changes view
- The root header's branch name opens the picker for that root.
- ▾ → Branch: Create Branch… / Create Branch From… / Rename Branch… / Delete Branch…; ▾ → Stash: Stash,
  Stash Including Untracked, Stash Staged, Pop Latest Stash, Apply Latest Stash.
- *Create…*, *Rename…* and *Stash* (with its optional message) take their text in an in-place field
  under the header, focused (Rule 3). Return or the field's button runs it; leaving the field keeps the
  text and the field open (Rule 2) — leaving never stashes or renames by accident; Escape cancels.
- The **Stashes** group: rows `wip search · on feature/x · 2 h ago`, hover Apply / Pop / Drop; a click
  opens `stash@{n}` against its parent in a diff tab.

### The agent and voice
- "switch api to main", "stash my changes", "create a branch called fix-login" reach the same actions;
  delete and drop ask the operator first (call 9).

## What it does not do

- Merge or rebase one branch into another, and resolving conflicts: **3a-v**.
- Tags, checking out a commit or tag (detached), deleting a remote branch, branch protection.
- The agent's own shell is unchanged: a `git switch` it runs there is its own.

## Design

### `wakil-git` — `GitWriter` (Invariant 10)
New write tools under `WAKIL_GIT_WRITES`, on 3a-ii's write lock, with its safety args (hooks run as a
terminal's would; no pager, no fsmonitor):
- `git_branches` (read): local branches with upstream and ahead/behind, most recent first; remote
  branches without a local; the current branch or detached SHA.
- `git_switch {root, branch, create?, from?, track?, carry: "refuse"|"stash"|"bring"}`. `refuse` (the
  default) runs `git switch` and maps "would be overwritten" to a refusal listing the paths; `stash`
  stashes (with untracked) then switches; `bring` stashes, switches, pops, and reports a clash as call 6
  does. Never `--force`, never `--discard-changes`.
- `git_branch_rename {root, from, to}`, `git_branch_delete {root, branch, force}` — `force` only after
  the confirmation names the commits it loses.
- `git_stash {root, message?, mode: "default"|"untracked"|"staged"}`, `git_stashes` (read: index, id,
  message, branch, date, files), `git_stash_apply|pop|drop {root, index, id}` — refused when `index`
  no longer holds `id` — and `git_stash_drop_all {root}`. `git_show` learns stash revisions for the
  file diff.
- Names are normalised (spaces → `-`) and checked with `git check-ref-format --branch` before git runs.
- **Cancel** (Rule 4) stops a switch only before git begins the checkout, and a Bring Them Along only
  between its steps — never mid-checkout, which would leave a half-written tree. Cancelled between the
  stash and the pop, it says `Your changes are in git stash (stash@{0})`.

### Actions — WakilKit (Invariant 2)
`editor_changes_switch`, `editor_changes_branch_create`, `_branch_rename`, `_branch_delete`,
`editor_changes_stash`, `_stash_apply`, `_stash_pop`, `_stash_drop`, `_stash_drop_all`, and the reads
`editor_changes_branches`, `editor_changes_stashes`. Agent-reachable; delete and drop gated for the
agent's and voice's channels (call 9). One write per root at a time, as 3a-ii's `GitWriteFlights`.

### WakilApp
- `ContextLine`: the Branch segment and its dropdown (the picker view is shared with the root header).
- `EditorColumn`: the root header's branch button, the ▾ submenus, the in-place name/message field, the
  Stashes group, and the stash diff tab (an existing diff tab with `stash@{n}^` vs `stash@{n}`).

### Interaction rules
1 — only Delete, Drop and Drop All confirm, in place. 2 — the name and message fields keep their text on
leave. 3 — the filter field and the name field arrive focused. 4/5 — Fetch, a switch and a stash show
their spinner, are not fired twice, and the waits can be cancelled. 6 — after a switch or a stash the
operator stays where they were. 7 — an existing name switches; spaces become `-`. 8 — git's refusals are
shown whole. 9 — no default branch is forced; the picker suggests, the operator picks.

## Errors and edges
- A root mid-merge or mid-rebase: switch and stash refuse, naming it (as 3a-iii's Pull does).
- Unsaved editor tabs in the root: the switch goes ahead (git does not see them); each such tab is
  marked changed on disk, as an outside edit is today.
- An agent running in the place: allowed, and journalled; its next read sees the new tree.
- An empty stash (nothing to stash): `No local changes to stash`, shown under the header.
- A branch name that is also a remote branch: the local one is listed; the remote appears only when no
  local tracks it.

## Testing
- Go: each tool against a fixture repository with a bare remote — switch with carried, refused, stashed
  and brought-along changes; create from a base; track a remote branch; rename; delete merged and
  unmerged (force only when asked); stash in each mode; apply, pop and drop by index; a pop clash.
- WakilKit: the picker's rows from a `git_branches` answer (create row, local order, remote filtering,
  detached); the active root; the actions' prices (delete/drop gated for the agent); the refusal text.
- e2e (the auditor): the segment and picker pressed, a switch and a stash by button and by dispatch
  (parity), the refused-switch choice, the Stashes group's Apply/Pop/Drop.

## Charter changes this sub-phase makes
- **Decision 46:** branches and stash from the Changes view and the context line; local branch and
  stash writes priced allow; no force, no discard.
- **Invariant 6, an eighth row:** branch delete and stash drop, the first git writes Wakil cannot undo
  (the reflog and `git fsck` can, outside Wakil) — with the reasoning for how they are priced.
- North-star §8: 3a-iv's row stays as written.
