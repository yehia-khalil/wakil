# 3b-iii: the Changes view — the Git pane folded into the editor — and gutter change marks

**Date:** 2026-10-15
**Status:** design approved by the operator 2026-10-15, section by section
**Sub-phase:** 3b-iii, which follows 3b-ii-b (yehia-khalil/rafiq#421–#427, main 7c151c3d, archived). It waits on nothing.
Decision 36 (the fold) and Decision 37 (Changes' root groups collapse per pane) are its starting
point.

---

## Problem

Seeing what changed means a separate Git pane beside the editor, and that pane cannot open the
file it shows. Decision 36 settled that the Git pane folds into the editor, because git and the
editor are both project-level across roots. While a file is being edited, nothing in it shows
which lines differ from git.

## Decisions the operator took during this design (2026-10-15, recorded as Decision 40)

- **Gutter marks ship in 3b-iii**, not in a sub-phase of their own.
- **Clicking a gutter mark opens an inline peek** under the change (old lines against new), not
  the diff tab. The peek offers previous / next change and **Revert**. Revert is a buffer edit,
  undoable with ⌘Z and unsaved until ⌘S, so it asks nothing (Rule 1).
- **The Files tree shows git status** on changed files: the status letter in its tone. Folders
  are not tinted.
- **Gutter hunks are computed in WakilKit**, from the index text that `git_show` already
  returns, diffed with Swift's `CollectionDifference`. No new Go tool, and nothing diffed in
  JavaScript.
- **⌘⏎ in a diff tab opens the file itself** at the same line.

## What the operator gets

### 1. The Changes view (⌘⇧G)

The left column's third view, beside Files (⌘B) and Search (⌘⇧F). ⌘⇧G toggles it on the same
terms: on Changes it hides the column, on another view it switches to Changes, and with the
column hidden it shows the column on Changes.

- **One header per root:** `api · main · ↑2 ↓1`, or `api · main · clean`, or a detached SHA, as
  `gitRootLine` reads today. A header collapses its root. Which roots are collapsed is kept per
  pane and apart from Files' open folders (Decision 37), and saved with the layout.
- **Groups Staged, Changes and Untracked** under each root. An empty group is not drawn. A partly
  staged file appears twice, once in each group.
- **Rows** show the status letter in its tone (the Git pane's tones: added green, modified amber,
  deleted muted) and the name. A rename reads `old → new`.
- **↑↓ move the highlight** across groups and roots. **Click or Return opens the diff tab.** The
  list stays beside the diff, so the Git pane's spine and its wide name column have no successor.
- **Live:** an edit, a `git add`, a commit or a branch switch from anywhere shows within about
  half a second, with no refresh control.
- A root that is not a repository reads `docs · not a git repository` and has no groups.

### 2. The diff tab

- Titled `User.php (Changes)` or `User.php (Staged)`. The same file's two diffs are two tabs.
- **Read-only, inline**, drawn by Monaco's diff editor and themed as 3a-i's was: additions §5
  green, deletions a muted tone, never red.
- **Changes** diffs the index against the working tree. **Staged** diffs HEAD against the index.
  An untracked file diffs against nothing, and a deleted file against nothing on the right.
- **The preview-tab rule applies** (3b-ii): a single click or Return opens a preview diff tab,
  which the next one replaces; a double-click pins it.
- **⌘⏎ opens the file** as a file tab, at the line under the diff's cursor. It is not offered on
  a deleted file's diff or a Staged diff whose file is gone from the working tree.
- Binary files, files over the cap and read errors show 3a-i's banner, whole (Rule 8).
- **It stays live:** when the watcher reports the file's root changed, an open diff tab
  re-reads. A diff whose file is no longer in its group shows *"No longer changed"* and stays
  open until closed.

### 3. Gutter marks

In a file tab whose file is tracked in a repository:

- **A green bar** beside added lines, **an amber bar** beside changed lines, **a small muted
  triangle** between the lines where lines were deleted.
- **Against the index**, the same comparison the Changes group makes. A hunk staged in a
  terminal loses its mark.
- **Updated as the operator or the agent types**, from the buffer, not the disk. The index text
  is refetched when the watcher reports the root changed.
- Untracked files, files outside a repository, scratch tabs and read-only files (over cap,
  binary, not UTF-8) have no marks.

### 4. The peek

**Clicking a mark** opens a peek under its hunk, inside the file:

- The hunk's old lines (muted) above its new lines (green), with a header
  `2 of 5 changes · ↑ ↓ · Revert · ×`.
- **↑ / ↓ (and the buttons) step** to the previous or next hunk in the file. The editor scrolls
  so the peek stays in view, and the peek moves with the cursor.
- **Revert** replaces the hunk's new lines with its old ones in the buffer. The tab turns dirty,
  ⌘Z undoes it, and nothing is saved until ⌘S. No dialog (Rule 1: undoable edits do not ask).
  After a Revert the peek moves to the next hunk, or closes when none remain (Rule 6).
- **Esc or ×** closes the peek and leaves the cursor where it was (Rule 6).
- Typing in the file closes the peek. The marks stay.

### 5. Git status in the Files tree

A changed file's row shows its status letter, in its tone, at the right edge. A file both staged
and changed shows its working-tree status. Folders are not tinted. Ignored files keep 3b-ii's
dimming.

### Agent actions (Invariant 2 — one path for both)

| Action | Does | Replaces |
|---|---|---|
| `editor_tree(view: "changes")` | shows the column on Changes | — |
| `editor_changes_select(root, path, group)` | opens that diff tab (preview, unless `pin: true`) | `git_select` |
| `editor_changes_step(delta)` | moves the highlight and opens its diff | `git_step` |
| `editor_changes_collapse` / `editor_changes_expand(root)` | collapses or expands a root's group | — |
| `editor_open_file` | from a diff tab, opens the file at the cursor's line (⌘⏎) | — |
| `editor_peek(line)` | opens the peek on the hunk at `line` | — |
| `editor_peek_step(delta)` | moves the peek | — |
| `editor_peek_close` | closes it | — |
| `editor_replace_range` | Revert dispatches it with the hunk's range and old lines | (existing) |
| `editor_refresh` | also re-reads git for every root | `git_refresh` |

`git_fold` and `git_unfold` are deleted: nothing folds any more. Every action takes `pane`, as
the editor's do.

## What it does not do

- **No write to git.** Stage, unstage, commit, discard and checkout stay 3a-ii's; push and pull
  stay 3a-iii's. Revert edits the buffer only.
- No side-by-side diff, history or branch graph (still deferred, §15).
- No editing inside a diff tab. ⌘⏎ opens the file for that.
- No marks against HEAD, and no choice between HEAD and the index.
- No folder tint and no status counts on folders.
- No submodule descent: a submodule is one changed entry, as 3a-i lists it.

## Design

### Go

Nothing changes. `wakil-git`'s `git_status`, `git_diff` and `git_show` already return everything
this needs, with 3a-i's read-only-by-construction runner.

### WakilKit

- **Git status belongs to the window.** Today each Git pane holds its own `GitSnapshot.roots`
  and reads `git_status` for itself. The Changes view, the tree's tints and the gutter baselines
  all read one status per root, so the window keeps a single `[GitRootState]` (one
  `git_status` per root per watcher wake). Editor panes read it; none read git for themselves.
- **The git watcher runs while any editor pane is open** (`syncGitWatcher`'s *has a git pane*
  becomes *has an editor pane*). A start reads first, as 3a-i's fix round 1 requires.
- **`EditorColumnState`** gains `view: changes`, `changesClosed: Set<String>` (collapsed roots)
  and `changesHighlight` (root, path, group). It is saved with the layout like `open`.
- **`EditorTabSubject` gains `.diff(root, path, group)`.** The tab holds `GitDiffState`
  (original, modified, language, binary, bytes, lines, truncated, error, loading), fetched by the
  Git pane's `git_show` flight, which moves to `Editor/`, cancelling per tab.
- **`editorHunks(base: String, text: String) -> [EditorHunk]`**, a pure function. It splits both
  texts into lines, takes `text.difference(from: base)` and groups adjacent removals and insertions
  into hunks: `added` (new lines, no old), `changed` (old and new) and `deleted` (old lines, no
  new, anchored between two lines). Each hunk carries its new-line range and its old lines, which
  is all Revert needs. It is computed on the edit counter's change, debounced like the tree's
  reads.
- **The baseline:** each open file tab in a repository keeps the index text
  (`git_show(rev: index)`), fetched on open and refetched on a wake for its root. An untracked or
  unreadable baseline means no marks.
- **The peek is state on the tab:** `peek: Int?`, the hunk index. Typing clears it. A step
  clamps.
- **The layout migration.** `LayoutPersistence` maps a saved `git` pane to an editor pane with no
  tabs and its column shown on Changes, keeping its frame. It is the first kind migration. Today
  unknown kinds are dropped, and that stays true for every other kind.
- **Deleted:** `GitPaneKind`, `GitSnapshot`'s selection, fold and diff fields, `GitNavigation`'s
  fold logic, the `git_*` actions and their palette, rail and landing entries. What survives moves
  under `Editor/` or stays in `Git/` as the window's status: `GitRootState`, `GitFileRow`,
  `gitRootLine`, `gitRowLabel`, `gitStatusTone`, `gitRows`, `gitStep`, `gitReselect`, the
  watchers.

### WakilApp

- **One web view per editor pane.** `monaco-host.html`'s editor mode gains a diff editor beside
  its code editor, and the active tab chooses which is shown. `EditorRenderer` gains
  `showDiff(original:modified:language:)`. `MonacoDiffRenderer`, the `DiffRenderer` seam's only
  conformance, is deleted with the Git pane, and the seam folds into `EditorRenderer`. A diff
  tab costs no second page load.
- **Gutter marks** are Monaco decorations (`linesDecorationsClassName`) from the hunks. **The peek**
  is a Monaco view zone drawn from the hunk's old and new lines. Its buttons and keys post back
  to Swift, which dispatches the actions above.
- **`EditorColumn`** draws the Changes view from the window's status and the pane's column state,
  reusing `GitPane`'s header, group and row views, which move into it. The tree row gains a
  trailing status letter.
- ⌘⇧G joins ⌘B and ⌘⇧F in `AppScene`. ⌘⏎ is bound in a diff tab only.
- `GitPane.swift` is deleted.

## Errors and edges — against PRODUCT.md §Interaction Rules

- **Rule 1.** Revert asks nothing: it is an undoable buffer edit. Nothing in this sub-phase
  writes to git or to disk except ⌘S, unchanged.
- **Rule 4 / 5.** A diff being fetched shows *Loading* and is cancelled when another opens in its
  tab. A second click on the same row does not fetch twice.
- **Rule 6.** Esc closes the peek and leaves the cursor. After Revert the peek moves on, or
  closes. A refresh that removes the highlighted row moves the highlight to its neighbour
  (3a-i's `gitReselect`), not to the top. ⌘⏎ opens the file as a new tab and leaves the diff tab
  open beside it.
- **Rule 7.** `editor_changes_select` on a path that is no longer changed opens the diff tab
  reading *"No longer changed"*. A non-root still refuses, naming the roots, as 3a-i did.
- **Rule 8.** A root whose `git status` fails shows its error whole under its header. The other
  roots read normally. A baseline that fails to load drops that file's marks, with no error in
  the file.
- **A layout saved by 3b-iii, read by an older build.** The plan checks first whether
  `EditorColumnState` decodes an unknown `view` leniently. If it does not, it is made to fall
  back to `files`, so the migration has a way back.

## Testing

**WakilKit (Swift Testing):**

- `editorHunks`, table-driven: an added line, a changed line, a deleted line, a deletion at the
  end of the file, a deletion at the start, a missing final newline, CRLF, an empty base, an
  empty text, identical texts, and two hunks separated by one unchanged line.
- The migration: a saved `git` pane loads as an editor pane on Changes with its frame. An
  unknown kind is still dropped.
- The window status: one `git_status` per root per wake, whatever the number of editor panes. No
  read with no editor pane open. A start reads first.
- Diff tabs: the preview rule, the two groups as two tabs, *No longer changed*, cancel on
  replace.
- Every new action, through the action registry, with its refusals.
- The peek: open, step, clamp, cleared by typing, Revert dispatches `editor_replace_range` with
  the hunk's old lines.
- Ported from the Git pane's suites: root lines, row labels, tones, step and reselect. The
  fold, spine and diff-host tests are deleted with the code.

**e2e (the auditor, `docs/agents/e2e.md`):**

- `3a-i-git-{list,drill,keys,live,press,voice-hint}` are rewritten as `3b-iii-changes-*` against
  the editor.
- New: the peek (step, Revert, Esc), the tree's status letters, ⌘⏎, ⌘⇧G, and a saved Git
  pane migrating.
- `e2e/checks/uncoverable.tsv` loses its `git_step`, `git_fold` and `git_unfold` rows, and gains
  rows for any new agent-only action.

**The walk** (`docs/wakil/phase-3b-iii-acceptance.md`): 3a-i's ten steps redone in the editor,
plus the peek, Revert and the tree.

## How it lands — one unit of work per PR, stacked

1. The window's git status, and the watcher running while an editor pane is open. The Git pane
   reads the shared status, so nothing changes on screen.
2. The Changes view and the tree's status letters.
3. Diff tabs and one web view per pane. The Git pane is deleted and its layouts migrate.
4. Gutter marks.
5. The peek and Revert.
6. The acceptance doc, the walk and the charter changes.

## Charter changes this sub-phase makes

- **Decision 40** records the five decisions above, and that the Git pane kind is gone, with the
  first kind migration.
- **Design language §11:** the Git row says it is the editor's Changes view. The editor row
  gains gutter marks and the peek.
- **Design language §15:** the open item *"Editor gutter change-indicators + inline diff"* is
  settled.
- **The 3b-ii spec's roadmap table** keeps 3b-iii's row. Nothing moves.

## Open questions

None. The older-build decode is checked first in the plan, with its fallback already decided.
