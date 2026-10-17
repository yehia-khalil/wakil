# 3b-iii: the Changes view — the Git pane folded into the editor — and gutter change marks

**Date:** 2026-10-15
**Status:** design approved by the operator 2026-10-15, section by section; amended 2026-10-16 (rulings R1–R14, the build's B1–B6 and the final review's B8, at the end)
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
- **⌘P lists the changed files** too; choosing one opens its diff as a row of the Changes view
  does. With no editor pane open it opens one, entering the conversation as other palette opens
  do, and it focuses the editor pane it used (Rule 6).

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
  open until closed. A root whose `git status` failed, or that is still loading with no files, is
  *unknown*, not clean: its open diff tabs are left as they are and do not read *"No longer
  changed"*, and a diff opened in it is fetched normally. With no git client, a diff tab resolves
  to its error instead of loading forever.

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
- **A size cap:** a buffer or index text of more than 10,000 lines (`editorHunksLineCap`) gets no
  marks and no peek. The marks are computed off the main thread. The line diff costs about
  O(N·D), and a 10,000-line file where every line differs measured 1.3 s.
- A click on blank gutter space, where that line has no mark, opens nothing and shows no error.
- **Line endings (known, accepted for 3b-iii; B8).** Under `core.autocrlf` or an `eol` attribute
  the index text is LF while the buffer is CRLF, so every line shows as changed although
  `git diff` shows nothing.

### 4. The peek

**Clicking a mark** opens a peek under its hunk, inside the file:

- The hunk's old lines (muted) above its new lines (green), with a header
  `2 of 5 changes · ↑ ↓ · Revert · ×`.
- **↑ / ↓ (and the buttons) step** to the previous or next hunk in the file. The editor scrolls
  so the peek stays in view, and the peek moves with the cursor.
- **Revert** replaces the hunk's new lines with its old ones in the buffer. The tab turns dirty,
  ⌘Z undoes it, and nothing is saved until ⌘S. No dialog (Rule 1: undoable edits do not ask).
  After a Revert the peek lands on the next hunk, or on the one before when the reverted hunk was
  the last, and closes only when none remain (Rule 6).
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
  all read one status per root, so the window keeps a single status (one `git_status` per root per
  watcher wake): `GitStatus`, an actor in `Git/`, not pane state (R4). It is handed to the window,
  the editor actions, `GitSource` and the palette. Editor panes read it; none read git for
  themselves. `read_pane` carries the Changes column's highlight and collapsed roots and each diff
  tab's facts; the agent reads the rows with the agent-facing `git_status`, since `read_pane` is
  store-isolated and cannot await another actor.
- **`editor_refresh` takes `what`:** `all` (the default, and the agent's: it reads the status, then
  does both), `files` or `git`. The file watcher dispatches `files`; the git watcher reads the status
  once and dispatches `git` to each editor pane (R5).
- **The git watcher runs while any editor pane is open** (`syncGitWatcher`'s *has a git pane*
  becomes *has an editor pane*). A start reads first, as 3a-i's fix round 1 requires.
- **`EditorColumnState`** gains `view: changes`, `changesClosed: Set<String>` (collapsed roots)
  and `changesHighlight` (root, path, group). It is saved with the layout like `open`. Diff tabs are not saved: 3b-i saves file tabs only (R7).
- **`EditorTabSubject` gains `.diff(root, path, group)`.** The tab holds `GitDiffState`
  (original, modified, language, binary, bytes, lines, truncated, error, loading), fetched by the
  Git pane's `git_show` flight, which moves to `Editor/`, cancelling per tab.
- **`editorHunks(base: String, text: String) -> [EditorHunk]`**, a pure function. It splits both
  texts into lines on unicode scalars, so CRLF files diff and revert exactly (B5), without the text's
  final newline, so `a\nb` and `a\nb\n` are equal and a missing final newline is no hunk (R9). It returns
  no hunks past `editorHunksLineCap`, 10,000 lines (B1). It takes `text.difference(from: base)` and groups adjacent removals and insertions
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
  tabs and its column shown on Changes, keeping its frame and its id (`git-1`), so the snap graph, focus
  and maximize still name it (R8); its title becomes `Editor`, with no note, as the pane is not lost. It is the first kind migration. Today
  unknown kinds are dropped, and that stays true for every other kind.
- **Deleted:** `GitPaneKind`, `GitSnapshot`'s selection, fold and diff fields, `GitNavigation`'s
  fold logic, the `git_*` actions and their palette, rail and landing entries. What survives moves
  under `Editor/` or stays in `Git/` as the window's status: `GitRootState`, `GitFileRow`,
  `gitRootLine`, `gitRowLabel`, `gitStatusTone`, `gitRows`, `gitStep`, the
  watchers. `gitReselect` is replaced by the step-order rule (R6).

### WakilApp

- **One web view per editor pane.** `monaco-host.html`'s editor mode gains a diff editor beside
  its code editor, and the active tab chooses which is shown. `EditorRenderer` gains
  `showDiff(original:modified:language:)`. `MonacoDiffRenderer`, the `DiffRenderer` seam's only
  conformance, is deleted with the Git pane, and the seam folds into `EditorRenderer`. A diff
  tab costs no second page load. 3b-i's Compare (disk against buffer), `MonacoDiffRenderer`'s other
  user, shows through the same `showDiff`, with its Esc through the page's key capture; its controls
  and identifiers are unchanged (R2). `--probe-monaco`, which only `MonacoDiffRenderer` drove, is
  deleted: every diff tab now answers its question, *does Monaco's diff editor render offline?* (R3).
  The page takes ↑, ↓ and Esc only while the peek is open, and Esc only while Compare is open (R13).
- **Gutter marks** are Monaco decorations (`linesDecorationsClassName`) from the hunks. **The peek**
  is a Monaco view zone drawn from the hunk's old and new lines. Its buttons and keys post back
  to Swift, which dispatches the actions above.
- **`EditorColumn`** draws the Changes view from the window's status and the pane's column state,
  reusing `GitPane`'s header, group and row views, which move into it. The tree row gains a
  trailing status letter.
- ⌘⇧G joins ⌘B and ⌘⇧F in `AppScene`. ⌘⏎ opens the file in a focused editor pane whose active tab is
  a diff that may open its file, and is Maximize Pane everywhere else (R10). ⇧⌘G is Monaco's Find
  Previous, which the page hands to the menu for ⌘⇧G (R11); Find Previous stays on ⇧⏎ in the find bar.
- `GitPane.swift` is deleted.

## Errors and edges — against PRODUCT.md §Interaction Rules

- **Rule 1.** Revert asks nothing: it is an undoable buffer edit. Nothing in this sub-phase
  writes to git or to disk except ⌘S, unchanged.
- **Rule 4 / 5.** A diff being fetched shows *Loading* and is cancelled when another opens in its
  tab. A second click on the same row does not fetch twice.
- **Rule 6.** Esc closes the peek and leaves the cursor. After Revert the peek moves on, or
  closes. A refresh that removes the highlighted row moves the highlight to the next row of its root in
  step order, else the last, not to the top (R6); that replaces 3a-i's `gitReselect`. ⌘⏎ opens the file as a new tab and leaves the diff tab
  open beside it.
- **Rule 7.** `editor_changes_select` on a path that is no longer changed opens the diff tab
  reading *"No longer changed"*. A non-root still refuses, naming the roots, as 3a-i did.
- **Rule 8.** A root whose `git status` fails shows its error whole under its header (and is *unknown*,
  not clean, to its diff tabs). The other roots read normally. A baseline that fails to load drops that file's marks, with no error in
  the file.
- **A layout saved by 3b-iii, read by an older build.** The check found that a pane's `editorColumn`
  is decoded with `try?`, so an unknown `view` only drops that pane's column. But
  `LayoutSnapshot.editorColumnDefault` is decoded with `try`, and `setEditorColumn` copies the view
  into it, so a build that does not know `changes` rejects the whole layout file. `EditorColumnView`
  now decodes an unknown value as `files` (R1), landing in PR 1, before anything writes `changes`.
  Every build from PR 1 on reads a 3b-iii layout; a build from before cannot be changed, and shows
  the note any unreadable layout does.

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

None. The older-build decode was checked in the plan (R1).

## Amendment — 2026-10-16, while planning (`docs/superpowers/plans/2026-10-16-3b-iii-changes-view.md`)

The rulings R1–R14 of the plan, each with its reason. The body above is edited to match.

- **R1. The older-build decode.** The spec asked to check first. The check: a pane's `editorColumn`
  is decoded with `try?`, so an unknown `view` only drops that pane's column. But
  `LayoutSnapshot.editorColumnDefault` is decoded with `try`, and `setEditorColumn` copies the view
  into it. So a build that does not know `changes` rejects the **whole layout file**.
  - The fix: `EditorColumnView` decodes an unknown value as `.files`.
  - It lands in **Task 1 (PR 1)**, a PR before anything writes `changes`. Every build from PR 1 on
    reads a 3b-iii layout.
  - A build from before PR 1 cannot be changed. Going back that far shows the note, as any unreadable
    layout does.
- **R2. Compare moves onto the pane's page.** 3b-i's Compare (disk ↔ buffer) is the other user of
  `MonacoDiffRenderer`. With one web view per pane, it shows through the same `showDiff`, and its Esc
  through the page's key capture. Its controls and identifiers are unchanged.
- **R3. `--probe-monaco` is deleted** with `MonacoDiffRenderer`, which is all it drives. It was
  3a-i Task 1's stop gate: *does Monaco's diff editor render offline in the bundle?* Every diff tab
  now answers that. (Overrule this and it is rebuilt on `MonacoEditorRenderer.showDiff` instead.)
- **R4. The status is an actor in `Git/`, not pane state.**
  - What reads it: `GitStatus` is handed to the window, the editor actions, `GitSource` and the
    palette.
  - What `read_pane` carries: the Changes column's highlight and collapsed roots, and each diff tab's
    facts.
  - Rows: the agent reads them with `git_status`, which is agent-facing. (`read_pane` is
    store-isolated and cannot await another actor.)
- **R5. `editor_refresh` gains `what`:** `all` (default), `files` or `git`. Each watcher wake then
  reads `git_status` once:
  - the file watcher dispatches `what: files`;
  - the git watcher reads the status once, then dispatches `what: git` to each editor pane.
  - `all`, the agent's, reads the status and then does both.
- **R6. The highlight's neighbour comes from step order, not the old list.** If the highlighted row
  is gone, it moves to the next row of its root in step order, else the last. That needs no `before`
  list, which the window's status cannot hand a pane action. It replaces `gitReselect`. Its 3a-i
  tests are ported with the outcome they pinned.
- **R7. Diff tabs are not saved with the layout.** 3b-i saves file tabs only. A migrated Git pane
  opens empty, with its column on Changes.
- **R8. A migrated Git pane keeps its id** (`git-1`), so the snap graph, focus and maximize still
  name it. Its title becomes `Editor`. There is no note: the pane is not lost, only renamed.
- **R9. A missing final newline is no hunk.** Lines are compared without the text's final newline,
  so `a\nb` and `a\nb\n` are equal. A mark on a line that looks unchanged would be noise.
- **R10. ⌘⏎ is Maximize Pane everywhere else.** In a focused editor pane whose active tab is a diff
  that may open its file, ⌘⏎ opens it. Otherwise it maximizes, as today. WakilKit decides
  (`editorCommandReturnOpensFile`).
- **R11. ⇧⌘G is Monaco's Find Previous.** The page hands it to the menu for ⌘⇧G. Find Previous stays
  on ⇧⏎ in the find bar.
- **R12. After a Revert the peek index is clamped.** The reverted hunk's successor takes its index,
  so the peek lands on the next hunk. If the reverted hunk was the last, it lands on the one before.
  It closes only when none remain.
- **R13. The page takes ↑, ↓ and Esc only while the peek is open, and Esc only while Compare is
  open.** Every other key is Monaco's.
- **R14. e2e.** The 3a-i git checks and `palette-new-git-parity.jsonl` are deleted with the kind in
  PR 3, with their `uncoverable.tsv` rows. The `3b-iii-changes-*` rewrites and the new checks are the
  **Cover** rung's (the e2e auditor), handed the spec's list in the acceptance doc.

### Decisions taken during the build

- **B1. A size cap on the marks.** `editorHunks` gives no hunks (no marks, no peek) when the buffer
  or its index text has more than 10,000 lines (`editorHunksLineCap`). The marks are computed off
  the main thread. Reason: the line diff costs about O(N·D); a 10,000-line file where every line
  differs measured 1.3 s.
- **B2. A click on blank gutter space** (no mark on that line) opens nothing and shows no error.
- **B3. An unknown root.** A root whose `git status` failed, or that is still loading with no files,
  is "unknown". Its open diff tabs are left as they are and do not read "No longer changed", and a
  diff opened in it is fetched normally. Reason: an error or a read in flight says nothing about
  whether the file is still changed.
- **B4. No git client.** A diff tab resolves to its error instead of loading forever.
- **B5. Lines are split on unicode scalars,** so CRLF files diff and revert exactly. (A `Character`
  split joins CRLF into one character, and Revert would then not restore the line ending.)
- **B6. ⌘P and a changed file.** A ⌘P changed file with no editor pane opens one (entering the
  conversation as other palette opens do), and focuses the editor pane it used (Rule 6).
- **B8. Line endings the index does not hold** (final review, 2026-10-16). Under `core.autocrlf` or
  an `eol` attribute, the index text is LF while the buffer is CRLF, so every line shows as changed
  (marks, the peek, `read_pane`'s hunks) although `git diff` shows nothing. Known and accepted for
  3b-iii: the baseline is `git_show`'s index text as stored, with no smudge filter applied.
