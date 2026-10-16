# 3b-ii: the editor's left column — the file tree, search across files, and find in file

**Date:** 2026-10-13
**Status:** design approved by the operator 2026-10-13, section by section
**Sub-phase:** 3b-ii, which follows 3b-i (the editor core, #389–#399, main e6c782b4). Waits on nothing.

---

## Problem

3b-i can open any file through ⌘P, but only when you already know its name. Using the editor to
*orient* — use 6 in the 3b-i spec — means browsing the project, searching it, and finding text in
a file. None of those exists today. `.env`, the file config work opens most, is gitignored, so ⌘P
never lists it.

## How Phase 3's editor work is split (revised)

This sub-phase revises the 3b-i table. It adds two sub-phases after 3b-iii, and the later rows
move down by two:

| | Delivers | Covers |
|---|---|---|
| 3b-i (merged) | Open, edit, save, tabs, scratch tabs, files in ⌘P, the editor actions, restore | 1, 4 |
| **3b-ii** (this spec) | The left column: the file tree (⌘B), search across files (⌘⇧F), find in file (⌘F) | 6 (orient) |
| **3b-ii-b** | Replace across the project, reveal the open file in the tree, move tabs, middle-click close | 4, 6 (orient) |
| 3b-iii | The Changes view (the Git pane folded in), gutter change marks | 2 |
| **3b-iv** | File operations: new file, new folder, rename, move, delete | 4 |
| **3b-v** | Editor settings: font size, tab size and spaces, word wrap, showing ignored files, the list of heavy folders, autosave | 1, 3, 4 |
| 3b-vi | Scratch buffers sent to the database, API and terminal panes (was 3b-iv) | 5 |
| 3b-vii | Large files and logs (was 3b-v) | 6 (logs) |
| 3b-viii | AI ghost-text (was 3b-vi) | 3 |
| 3b-ix | LSP (was 3b-vii) | 3, 6 |

Decisions the operator took during this design (2026-10-13), recorded as Decision 37:

- **Root focus is dropped.** 3b-i recorded it for this sub-phase, but it would have hidden files
  from ⌘P. ⌘P belongs to the whole window while focus belongs to one pane, so files would have
  vanished from ⌘P with no visible reason. Remembering which nodes are open in each pane gives
  each pane its own view without a new idea to learn. Scoping can come back with a later feature
  that needs it.
- **Changes' root groups collapse (3b-iii).** They use the tree's collapsible rows, and their open
  or closed state is remembered per pane, separately from Files. The Git pane stays as it is until
  3b-iii replaces it.
- **File operations get their own sub-phase (3b-iv).** They need a decision that extends Decision
  36 and Invariant 6's file write. Until then the tree is read-only, and rename and delete stay
  refused.
- **Editor settings get their own sub-phase (3b-v), autosave included.** Until then, 3b-ii's heavy
  folders are a fixed list.

## What the operator gets

**The left column.** Every editor pane gets a column on its left with two views: **Files** (⌘B)
and **Search** (⌘⇧F).

- **Showing and hiding:**
  - Nothing hides the column automatically, at any width.
  - It shows or hides only through ⌘B, ⌘⇧F, the toggle at the top of the column, or the agent.
  - ⌘B on Files hides the column; on Search it switches to Files. ⌘⇧F does the same for Search.
- **Width:**
  - The edge between the column and the file can be dragged.
  - The column starts at 240 pt and can go from 160 pt up to half the pane's width.
- **What each pane remembers, across a relaunch:**
  - whether the column is showing;
  - which view it shows;
  - its width;
  - which nodes are open.
- **A new pane** takes the column state you last left any editor pane in.

**Files.**

- **What the tree lists:**
  - The project's roots are the top level.
  - A child repo inside a root (a folder holding `.git`) shows as its own node.
  - Folders come before files, each sorted by name.
  - Gitignored files show dimmed.
  - `vendor`, `node_modules` and `.git` show as one dimmed row each, and their contents load only
    when you open them.
- **Keys:**
  - ↑↓ move the selection.
  - ← closes a folder or moves to its parent; → opens it.
  - Typing jumps to the next name that starts with what you typed.
- **The preview tab:**
  - A click or Return opens a file in the pane's one *preview tab*, whose title is in italics.
  - The next file opened that way replaces it.
  - The tab is kept as an ordinary tab when you edit the file, when the agent edits it, when you
    double-click the row, or when you double-click the tab.
  - A file that is already open in a tab is switched to, not opened again.
- **Staying current:**
  - The tree follows the disk: a file created, deleted or moved outside Wakil shows within about a
    second.
  - Open folders stay open, and the selected row stays selected while it exists (Rule 6).
- **Starting a new file:**
  - ⌘T then ⌘S starts the path field at the folder selected in the tree.
  - This replaces the first root as the default; with nothing selected, the first root is still
    the default.

**Search.**

- **The query line:**
  - It has three switches: case, whole word and regex.
  - It arrives focused (Rule 3) and searches as you type, after a 250 ms pause (Rule 2).
  - Enter runs the search at once.
- **Results:**
  - They are grouped by root, then by file. Each line shows its line number and text, with the
    match marked.
  - Groups collapse like tree rows.
- **Moving and opening:**
  - ↑↓ move through the results.
  - Return or a click opens the file in the preview tab at the match, with Monaco's find bar
    showing the same term.
- **While a search runs:**
  - It shows a tick and a **Cancel** (Rules 4 and 5).
  - A new query cancels the one in flight.
- **Limits and errors:**
  - A search stops at 2,000 matches and says *"only the first 2,000 matches are shown"*.
  - Search skips gitignored files and the heavy folders.
  - An invalid regex shows its error in full and runs nothing (Rule 8).
- **When files change afterwards:** if a searched file changes, the results stay and the view adds
  *"files changed since this search · Re-run"*.

**Find in file.**

- Monaco's own find bar, recoloured with Wakil's tokens.
- ⌘F finds; ⌘G and ⇧⌘G go to the next and previous match; ⌥⌘F replaces.
- It has the case, whole-word and regex switches and a match count.
- Replacing is typing in Monaco, the one edit path that does not go through an action
  (design-language §11).
- Esc closes the bar and leaves the cursor on the current match.

**⌘P** also lists gitignored files outside the heavy folders, dimmed and ranked below every
tracked file. For example, `api/.env` comes up for `env`.

**The agent** can do everything you can, through these actions:

- show or hide the column, and switch its view;
- open and close nodes;
- find in a file;
- search across files.

`read_pane` reports the column, the find query and the search results.

## What it does not do

- **No root focus** (Decision 37).
- **No new file, new folder, rename, move or delete from the tree** (3b-iv).
- **No replace across files**, because it writes many files at once. It can be its own later step
  if wanted.
- **No settings** (3b-v): the heavy folders are fixed, and the font, tabs and wrap stay as 3b-i set
  them.
- **No Changes view** (3b-iii).

## Design

### Go: `internal/wakilcore/files.go` and `cmd/wakil-files`

All three tools are read-only and confined to the active project's roots, in the same way as
3b-i's `files_read`.

**`files_list {root}` gains two fields.**

- `ignored`: the gitignored files outside the heavy folders, relative and sorted.
  - In a repository the list comes from `git ls-files --others --ignored --exclude-standard
    --exclude=<each heavy name>` for the root and each child repository.
  - Outside one, the walk lists no ignored files: every folder it skips by its own rules is
    reported as heavy instead (amended — Decision 37's 2026-10-13 amendment).
- `heavy`: the relative paths of the heavy folders found, listed as folders and never walked.
- The heavy names are a fixed list: `vendor`, `node_modules`, `.git`. Outside a repository the
  walk's skip list (which now includes `vendor`) is heavy too: `.venv`, `__pycache__`, `Pods`, and
  the rest (amended — Decision 37).

The 50,000 cap now counts `files` and `ignored` together, and `truncated` still says when it was
hit. A tracked file is never dropped while an ignored one is kept: tracked files are taken first.

**`files_list_dir {root, dir}`** (new):

- returns one folder's direct entries as `{name, kind: file|dir}`, sorted;
- is used only to open a heavy folder;
- refuses a `dir` that resolves outside the root, after symlinks, naming Invariant 6 and Decision
  36.

**`files_search {roots, query, case, word, regex}`** (new):

- **Returns** `{matches: [{root, path, line, column, preview}], truncated}`.
  - `preview` is the matching line, trimmed to 400 characters around the match.
- **How it searches** (amended — Decision 37's 2026-10-13 amendment; the spec first said
  `git grep` in a repository):
  - Every root the same way: the files `files_list` lists for it — tracked and untracked, never
    ignored or heavy, each child repository's included — read and matched with Go's `regexp`, so
    a pattern means the same thing inside and outside a repository. The switches map onto it:
    literal unless regex, `(?i)` unless case, `\b` around the pattern for word. Binary files and
    files over 2 MB are skipped.
- **Stops** at 2,000 matches, sets `truncated`, and stops when the call's context is cancelled.
- **An invalid regex** is an error carrying Go's own text.

### WakilKit: the `Editor/` folder

- **`EditorTree.swift`** (new, pure):
  - Builds nodes from the file lists: roots, child repositories, folders, files, ignored and heavy
    marks.
  - Carries the open set, the selection, and the rule that moves the selection to the nearest
    surviving row after a re-list.
  - Is tested without a window.
- **`EditorSearch.swift`** (new):
  - Holds the query, the switches, the results and `inFlight`.
  - Holds the *changed since* flag, which a watcher event on a path in the results sets.
  - Owns the 250 ms debounce and the cancellation of a superseded search.
- **The pane's column state** — `shown`, `view` (files or search), `width`, `open` (paths) —
  joins the editor's per-pane state.
  - It is saved and restored through 3b-i's per-kind restore hook.
  - Paths that no longer exist are dropped quietly on restore.
- **The preview tab** is a flag on one tab, `preview: true`.
  - Opening from the tree or from search replaces the tab holding the flag.
  - An edit by either author, or a keep, clears the flag.
- **One file list per root** is kept for the window and feeds ⌘P's Files source and every editor
  pane's tree, so the two never disagree.
  - It is re-listed when the existing `RootWatcher` (FSEvents, one-second burst window) reports a
    change under that root.
  - ⌘P ranks `ignored` entries below every tracked file.
- **New actions**, with every write through the one dispatch path (Invariant 2):

| Action | Kind | Params | Does |
|---|---|---|---|
| `editor_tree` | control | `pane`, `shown?`, `view?`, `width?` | shows or hides the column, switches view, sets width |
| `editor_tree_expand` | control | `pane`, `path` | opens a node, and its parents |
| `editor_tree_collapse` | control | `pane`, `path` | closes a node |
| `editor_find` | control | `pane`, `query`, `case?`, `word?`, `regex?` | opens the find bar on the active tab and returns every match's line and column |
| `editor_search` | control | `pane`, `query`, `case?`, `word?`, `regex?` | runs the search into this pane's Search view and returns the matches |
| `files_search` | read | `query`, `case?`, `word?`, `regex?` | the same search, with nothing drawn |

The `editor_*` actions are `control` for the same reason 3b-i's are: they change what a pane shows,
never the disk. `read_pane` on an editor gains:

- `column {shown, view, width, open}`;
- `tabs[].preview`;
- `find {query, case, word, regex, count}`;
- `search {query, …, in_flight, truncated, changed_since, results}`.

### WakilApp

- **`EditorPane`** draws the column natively in SwiftUI:
  - rows, using the Git pane's root-header style;
  - the drag edge, the toggle and the Search view.
- **Dimmed rows** use the existing tertiary text token.
- **`monaco-host.html`**:
  - restyles Monaco's find widget through the theme's colour keys;
  - reports find state (query, switches, count) back through the existing `report()` channel;
  - takes `editor_find` through a new `wakilFind` entry.

## Errors and edges — against PRODUCT.md §Interaction Rules

| Rule | How 3b-ii meets it |
|---|---|
| 1 Confirm only what destroys | Nothing here writes, so nothing asks. Replace in the find bar is typing; ⌘Z undoes it. |
| 2 Enter is never required | Search runs on a 250 ms pause; the find bar searches as you type. |
| 3 A new input arrives focused | ⌘⇧F focuses the query line; ⌘F focuses Monaco's find field. |
| 4 Anything that waits can be cancelled | A search shows Cancel, and a new query cancels the old one. Listing a heavy folder can be cancelled by closing it. |
| 5 Work in flight shows it | Search shows a tick. A heavy folder that is loading shows the same tick on its row. |
| 6 Stay where the operator was | A re-list keeps open folders, the selection and the scroll. Opening from search keeps the result selected, and switching back to Search keeps the results where they were. |
| 7 Override or ignore; don't refuse | The only refusals are paths outside the roots (Invariant 6, Decision 36). |
| 8 Errors are shown whole | An invalid regex, an unreadable root (under its node, as in the Git pane) and a failed heavy-folder listing (under its row) are each shown in full, and nothing else is blocked. |
| 9 Defaults suggest | The column's width and its showing state are only starting points, and each pane keeps its own. |

Edges:

- **More than 50,000 files:** that root shows *"only the first 50,000 files are listed"* at its top,
  as ⌘P does.
- **The open file is deleted or moved outside Wakil:** its row goes, the tab gets 3b-i's *deleted*
  mark, and the selection moves to the nearest row.
- **A project switch:** each pane's column state is saved. Paths missing in the new project are
  dropped on restore.
- **A burst of watcher events during a build:** the one-second window applies, and a re-list never
  moves the scroll.

## Testing

- **Go:**
  - `files_list`: the `ignored` and `heavy` fields, inside and outside a repository and in child
    repositories; the cap counting both lists, with tracked files kept first.
  - `files_list_dir`: confinement, including through a symlink.
  - `files_search`: in a repository, a child repository and a walk, over the listed files only;
    each switch; the 2,000 cap; context
    cancellation; an invalid regex; a binary file skipped; confinement.
- **WakilKit:**
  - Tree building: nesting, child repositories, ignored and heavy marks.
  - The open set and the selection surviving a re-list, including the nearest-row fallback.
  - The preview tab: replaced, kept by an operator edit, an agent edit or a keep, and an
    already-open file switched to.
  - The column state round-tripping through restore, with missing paths dropped.
  - Search: the debounce, cancellation on a new query, *changed since*, and truncation.
  - ⌘P ranking ignored files last.
  - Each new action, its refusals, and the `read_pane` fields.
- **e2e:**
  - ⌘B and the toggle show and hide the column, and it is still there after a relaunch.
  - Opening a folder, opening a file in the preview tab, and keeping it.
  - A dimmed `.env` opens from the tree and from ⌘P.
  - A heavy folder lists only when opened.
  - ⌘⇧F finds matches across two roots and opens the file at the match.
  - Cancel stops a search, and an invalid regex shows its error.
  - `editor_find` and `editor_search` give the same result from the agent and from the operator
    (parity).
  - A file created on disk appears in the tree.
  - A path outside the roots is refused.
- **Walk:** a ten-row runbook:
  - the column's look and the drag edge;
  - browsing with the preview tab;
  - `.env` from the tree and from ⌘P;
  - search across two repositories, with Cancel and an invalid regex;
  - a `git checkout` in a terminal updating the tree live;
  - find and replace in a file;
  - the agent driving find and search;
  - a relaunch restoring the column.

## Charter changes this sub-phase makes

- **Design-language:**
  - §1: the sidebar principle names the editor's left column as its second sanctioned exception.
    Unlike the Git column, it is shown and hidden only by the operator or the agent, never by width.
  - §11: the Editor entry gains the column's two views, the preview tab and search; the File tree
    bullet is replaced.
- **Decisions:**
  - **Decision 37:** root focus dropped, Changes' collapsible groups, and file operations and
    settings as their own sub-phases. Its reasons are recorded under *Problem*, above.
  - **The 3b-i spec's roadmap note** gains a pointer to Decision 37 where it describes root focus.
- **No invariant changes.** Every new tool is read-only, and the one file write stays Decision 36's.

## Open questions

None. The operator answered each one during the design.
