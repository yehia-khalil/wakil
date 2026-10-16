# 3b-i: the editor core — files, tabs, scratch, save, and the actions that drive them

**Date:** 2026-10-11
**Status:** design approved by the operator 2026-10-11, section by section
**Sub-phase:** 3b-i — the first of Phase 3's editor work. Follows 3a-i (Git pane, #366) and the
pluggable pane kinds (#378–#386). Waits on nothing.

---

## Problem

Decision 17 makes the editor native Monaco and dual-driven, and design-language §11 describes it
(multi-tab, multi-root tree, ⌘P, three-tier autocomplete). None of it exists. Today the agent can
name a file and a line, and the operator has to leave Wakil to look at it, fix it, or keep a
scratch query anywhere.

## What the editor is for

Agreed with the operator 2026-10-11 — all six, which is why the editor is split into sub-phases:

1. quick read-and-fix next to the agent;
2. reviewing what the agent changed;
3. writing new code by hand — *light* writing; §5's "heavy hands-on coding stays in real VS Code"
   stands, and replacing VS Code would be a charter change, not scope creep;
4. editing config and data files;
5. scratch buffers sent to other panes;
6. reading code to orient, and viewing logs and large output.

## How Phase 3's editor work is split

Each row gets its own spec, plan and walk.

| | Delivers | Covers |
|---|---|---|
| **3b-i** (this spec) | Open, edit, save, tabs, scratch tabs (⌘T), syntax highlighting, files in ⌘P, the editor actions, restore | 1, 4 |
| **3b-ii** | Multi-root tree (⌘B), **root focus**, find in file | 6 (orient) |
| **3b-iii** | **Changes view — the Git pane folded into the editor**, gutter change marks | 2 |
| **3b-iv** | Scratch buffers sent to the database, API and terminal panes | 5 |
| **3b-v** | Large files and logs: read-only large-file mode, follow tail, search | 6 (logs) |
| **3b-vi** | AI ghost-text from the organisation's provider | 3 |
| **3b-vii** | LSP, PHP and TS first: go-to-definition, type-aware completion | 3, 6 |

*(Revised by 3b-ii — Decision 37: file operations become 3b-iv and editor settings 3b-v, so the
rows from 3b-iv down move down by two, to 3b-vi–3b-ix.)*

Decisions taken for later sub-phases during this design, recorded so their specs start from them:

- **The Git pane folds into the editor (3b-iii).** The editor's left column has two views, *Files*
  (the tree, ⌘B) and *Changes* (today's Git list, grouped by root, ⌘⇧G). A changed file opens its
  diff as an editor tab, drawn by the 3a-i Monaco host; one key opens the file itself. A saved
  layout's Git pane migrates to an editor pane opened on Changes. This reverses Decision 17's
  *"Git is a separate dual-driven pane"* — recorded as Decision 36 below. Until 3b-iii the Git pane
  stays as it is, and 3b-i adds no Git click-to-open.
- **The editor is project-level (3b-ii).** The tree's top level is the active project's roots, as
  §11 already says. **Root focus:** each root has a focus toggle; turning one off hides it from the
  tree, ⌘P, search and Changes at once; each editor pane keeps its own focus set. A root that is a
  folder of repos also lists its child repos (folders holding `.git`) as focusable units, so
  `~/code/umbrella/api` can be focused without editing `project.json`. (Dropped in 3b-ii — Decision 37.) Several Wakil *projects* in
  one editor was ruled out: it crosses project boundaries (scopes, environments).

## What the operator gets

- **⌘P finds any file in the project.** Wakil's own palette gains a *Files* source in its
  Resources group — `config.go · file · wakilcore` — so there is no second finder. Return opens it
  in an editor pane: a new tab in the focused or most recent editor pane, or a new editor pane if
  none is open. When an editor pane has focus, file rows rank first. Files excluded by
  `.gitignore` are left out.
- **Tabs.** One editor pane holds many files. A tab shows its name, a dirty dot, and a
  *changed on disk* or *deleted* mark.
- **⌘T opens a scratch tab** — `Untitled-1`, focused, plain text. *Set language…* in ⌘K picks
  SQL, JSON, Go and the rest. ⌘S on a scratch tab opens a path field, focused, prefilled with the
  first root and confined to the project's roots; once saved, the tab becomes that file.
- **⌘S saves, no dialog** (Rule 1). Syntax highlighting comes from Monaco's built-in languages,
  chosen by extension.
- **⌘W in a focused editor pane closes the active tab**; with no tabs left the next ⌘W closes the
  pane. Every other pane keeps today's ⌘W.
- **Unsaved work is never lost silently.** Closing a dirty tab, or a non-empty scratch tab, asks
  inline: *"Save changes to `confirm.go`?"* — Save / Don't Save / Cancel. Closing the pane,
  switching organisation or quitting with dirty tabs asks once, listing them. An empty scratch tab
  closes without asking.
- **The agent drives it.** "Open the confirm method", "go to line 40", "fix that null check" —
  through the same actions the controls dispatch.

## What it does not do

- No tree, root focus or find (3b-ii); no Changes view, gutter marks or Git click-to-open (3b-iii);
  no sending a buffer to another pane (3b-iv); no files over 2 MB (3b-v); no ghost-text (3b-vi);
  no LSP (3b-vii).
- No file delete, rename or move. Each would be its own earned write.
- UTF-8 only. A file that is not UTF-8 opens read-only with a notice.
- Unsaved edits and scratch contents are not restored across a relaunch (see Restore).

## Design

### `wakil-files` — a capability (Invariant 10)

A new MCP binary, window-owned (its tools change pane state), following CONTRIBUTING.md's
*A new MCP binary* recipe. Logic in `internal/wakilcore/files.go`; errors through `mcpx.ToolErr`.

| Tool | Params | Returns |
|---|---|---|
| `files_list` | `root` | the root's files, relative paths, `.gitignore` respected (via `git ls-files -co --exclude-standard` in a repo, a walk skipping `.git` otherwise); capped at 50,000 entries, `truncated` says so |
| `files_read` | `path` (absolute) | `text`, `size`, `mtime`, `binary`, `utf8`; text capped at 2 MB — over the cap, or binary, returns no text and says why |
| `files_write` | `path` (absolute), `text`, `create` | the new `size` and `mtime`; `create: false` refuses a path that does not exist, `true` creates it and missing parent folders inside the root |

**Confinement.** Every call resolves the active project (`wakilcore.Resolve()`) and checks the
path against `ProjectRootPaths`, the way `NewGitRunner` does — after resolving symlinks and `..`,
so a link inside a root that points outside it is refused. A refused path names Invariant 6 and
Decision 36. Writes go to a temporary file in the same folder and are renamed into place, so a
failed write never leaves a half-written file. Line endings are written as the buffer holds them;
the buffer keeps whatever the file had.

### `WakilKit/Editor/` — the pane kind

A new folder, following CONTRIBUTING.md's *A new pane kind* recipe.

- **`EditorPaneKind`** — `names: ["editor"]`. `Contents` is the pane's tabs and the active index.
  A tab is either a file (`path`, `root`) or a scratch tab (`number`, `language`), and carries
  `text`, `savedText` (the text last read or written; dirty is `text != savedText`), `diskState` (`inSync`, `changedOnDisk`,
  `deleted`), `mtime`, `cursor`, `selection`, `visibleRange`, `scrollTop`, `language`, `notice`
  (over the cap, binary, not UTF-8, a write failure) and `saving`.
  `rerunsSubjectOnRestore` stays false: restore goes through the per-kind hook below.
- **`PaneStore+Editor`** — the store methods the actions and the view call, including the one
  non-action path for the operator's typing (below). Updates the pane's contents in place, which
  the pane-kinds work deferred to the editor (`updateContents`).
- **`EditorActions`** — `registerEditorActions`, called from `WakilWiring.build` with the
  `wakil-files` client.
- **The watcher** — the editor watches the roots of files it has open on the existing
  `RootWatcher` seam (`GitRootWatcher` is the model); a change re-reads the open files under it
  through `files_read` and compares `mtime` and text.
- **`EditorTabs`** — the pure rules a view needs: tab titles (with a parent folder when two
  names clash), ⌘W's tab-then-pane rule, the next scratch number. In WakilKit, never `WakilApp`.

### Actions

UI controls and the agent dispatch the same actions (Invariant 2). All are `.agentReachable`.

| Action | Kind | Params | Does |
|---|---|---|---|
| `editor_open` | control | `path`, `line?`, `column?` | opens the file as a tab, or focuses its tab, and reveals the line |
| `editor_new_scratch` | control | `language?` | opens a scratch tab (⌘T) |
| `editor_close` | control | `path?`, `discard?` | closes a tab, the active one by default; a dirty tab closes only with `discard: true` (the prompt's *Don't Save* dispatches it), otherwise it answers that the tab has unsaved edits — so the agent never discards by accident |
| `editor_goto` | control | `line`, `column?` | moves the cursor and reveals the line |
| `editor_select` | control | `range` | selects a range |
| `editor_set_language` | control | `language` | the active tab's language (*Set language…* in ⌘K) |
| `editor_replace_range` | control | `path?`, `range`, `text` | edits the buffer; the change is unsaved |
| `editor_save` | mutate | `path?`, `as?` | writes the buffer through `files_write`; `as` names the path for a scratch tab |
| `editor_reload` | control | `path?` | replaces the buffer with the disk's text (the *Reload* button) |

`editor_save`'s **price is allow in production and allow otherwise** (Decision 25), so it runs
without a prompt for the operator and the agent alike, voice included. `editor_replace_range` is a
`.control` because it changes only a buffer; the disk changes only through `editor_save`.

**The one exception.** The operator's keystrokes in Monaco are not actions — §11's *"the one
partial exception to dual-drive"*. They reach the store through one path,
`PaneStore.editorBufferDidChange`, and nothing else uses it.

### Data flow — the store owns the text, Monaco mirrors it

- **Typing:** Monaco sends content changes, debounced to the next frame, to
  `editorBufferDidChange`, which updates the tab's text and dirty flag.
- **Agent edits:** `editor_replace_range` changes the store's text, then the view applies the same
  edit in Monaco with `executeEdits`, so ⌘Z undoes agent edits too.
- **Save:** `editor_save` sends the store's text to `files_write`, records the new `mtime`, and
  clears the dirty flag. While it is in flight the tab shows *saving* and a second ⌘S is ignored
  (Rule 5); it can be cancelled (Rule 4).
- **Disk changes:**
  - a clean tab reloads in place, keeping cursor and scroll (Rule 6);
  - a dirty tab keeps the operator's text and shows a line at its top — *"`confirm.go` changed on
    disk"* with **Reload** and **Compare**. Compare opens a diff tab, disk against buffer, in the
    3a-i Monaco host. Reload is destructive and the button is its confirmation (Rule 1). ⌘S
    without either writes the buffer over the disk (Rule 7);
  - a deleted file keeps its tab and text, marked *deleted*; ⌘S recreates it.
- **Monaco reports back** cursor, selection, visible range and scroll top; they feed `read_pane`
  and restore.

### `read_pane`

Every key always present (the `PaneKind.readPane` contract):

- `tabs` — each with `path` (or `scratch` and its number), `root`, `language`, `dirty`,
  `disk_state`, `notice`;
- `active` — the active tab's index, or null;
- for the active tab: `cursor`, `selection`, `visible_range`, `visible_text` and `selected_text`.

Whole-file text is left out — the agent reads files itself — so deictic references ("this line",
"this function") resolve against what is on screen (Invariant 3) and the envelope stays small.
The pane-kinds work's deferred `read_pane` envelope-key clash is checked here: no editor key may
shadow `kind` or `failure`.

### Files in ⌘P

`PaletteSources` gains a Files source in the Resources group, through the seam the palette spec
left for it (*"All files in a root join when the editor ships, through the same source seam"*).
It lists `files_list` for each root, fetched once per open of the palette and kept until a root
changes. A row is `name · file · root`; Return dispatches `editor_open`. When an editor pane has
focus, file rows rank above every other Resources row. Root focus (3b-ii) will filter this source. (Dropped in 3b-ii — Decision 37.)

### ⌘T and ⌘W

- **⌘T** dispatches `editor_new_scratch` into the focused editor pane, or a new editor pane if the
  focused pane is not an editor.
- **⌘W** keeps its menu item. When the focused pane is an editor with a tab open, it closes the
  active tab (with the dirty prompt); otherwise it closes the pane as today.

### Restore — the per-kind hook

The pane-kinds work deferred a per-kind restore hook to the editor; 3b-i builds it.
`WindowModel.restorePaneContents` today re-runs git by name and treats every other re-running pane
as a db pane. It gains a hook on `PaneKind` — `restore(contents:in:)`, defaulting to nothing —
and the git and db branches move behind it, so the loop names no kind.

What the editor restores: its file tabs, the active tab, each tab's cursor and scroll. Each file is
re-read through `files_read`; one that no longer exists comes back marked *deleted*, the others
unaffected (Rule 8). Unsaved edits and scratch contents are **not** restored: quitting already
asked, so nothing unsaved reaches a relaunch. Empty scratch tabs are dropped.

### The Monaco host — an editor mode

`monaco-host.html` gains an editor mode beside its diff mode: one `monaco.editor.create` per
pane, one model per tab (`setModel` on tab switch keeps each tab's undo stack), and messages for
content changes, cursor, selection, scroll and visible range. The diff mode is unchanged and is
what Compare uses. One web view per editor pane; pooling (design-language §13) is not needed yet.
Behind a seam in WakilKit (`EditorRenderer`, as `DiffRenderer` is for diffs) so the store and
actions are testable without a web view.

## Errors and edges — against PRODUCT.md §Interaction Rules

| Rule | How 3b-i meets it |
|---|---|
| 1 Confirm only what destroys | ⌘S saves with no dialog. Closing a dirty tab and Reload destroy unsaved work, so they ask (inline prompt) or are themselves the confirmation (the button). |
| 2 Enter is never required | The scratch path field keeps its text when focus leaves; Return is a shortcut for Save. |
| 3 A new input arrives focused | A scratch tab, and the scratch path field, arrive focused. |
| 4 Anything that waits can be cancelled | An in-flight save can be cancelled; the buffer stays dirty. |
| 5 Work in flight shows it, cannot double-fire | The tab shows *saving*; ⌘S during a save is ignored. |
| 6 Stay where the operator was | A reload keeps cursor and scroll; closing a tab focuses its neighbour, not the first tab. |
| 7 Override or ignore; don't refuse | ⌘S over a changed-on-disk file writes the buffer. The only refusal is a path outside the roots, and it names Invariant 6 and Decision 36. |
| 8 Errors whole, block only what they must | Over-cap, binary, non-UTF-8 and write failures show whole in their own tab; other tabs carry on. A failed write keeps the buffer dirty. |
| 9 Defaults suggest | The scratch path field's prefilled root is editable to any root. |

## Testing

- **Go (`wakilcore`, `cmd/wakil-files`):** confinement table — `..`, a symlink inside a root
  pointing out, an absolute path elsewhere, a second project's root; the 2 MB cap; binary and
  non-UTF-8 detection; `.gitignore` filtering in a repo and the walk outside one; the list cap;
  `create` false and true; atomic write (a failed rename leaves the original); `main_test.go` and
  `schema_test.go` (`mcpxtest.AssertObjectOutputSchemas`).
- **WakilKit (`Editor/`):** every action against a fake `wakil-files` client; dirty,
  changed-on-disk and deleted transitions; agent edit then operator typing in one buffer; save in
  flight and cancel; a golden `read_pane` for the editor kind; `EditorTabs` rules (title clashes,
  ⌘W tab-then-pane, scratch numbering); restore — tabs back, a missing file marked deleted;
  `editor_save`'s price; the palette Files source and its ranking. `PaneKindsTests` covers
  registration unchanged.
- **Restore hook:** a test that restored git and db panes still re-run through the hook, and that
  `restorePaneContents` names no kind.
- **e2e auditor (Cover):** a check for each control (⌘P file row, ⌘T, ⌘S, ⌘W, the dirty prompt,
  Reload, Compare, *Set language…*, the scratch path field) and for Rules 1, 3, 5, 7 and 8 above,
  or a line in `e2e/checks/uncoverable.tsv` with its reason.
- **Walk:** `docs/wakil/phase-3b-i-acceptance.md`.

## Charter changes this sub-phase makes

Made in the implementation PRs, not in this spec:

- **Decision 36** in `decisions.md`: *the editor is the project's one code surface* — file write
  earns its way in under Invariant 6 (local files inside the active project's roots; price allow
  everywhere, for both origins, voice included, because the agent's harness already has a bare
  file-write tool, so an editor write adds no reach — the terminal's argument); delete, rename and
  any path outside the roots stay refused; and the Git pane folds into the editor in 3b-iii,
  revising Decision 17's *"Git is a separate dual-driven pane"*.
- **Invariant 6's table** gains the row *File write · local files · 2026-10-11*; its "Still
  refused" line gains file delete and rename. The charter sits at 3998/4000 words, so the
  reasoning lives in Decision 36 and the table row is the only charter text added; if it does not
  fit, an equal number of words is cut from the same section.
- **design-language §11:** the Editor row names scratch tabs (⌘T) and files in ⌘P; the Git row
  says it folds into the editor in 3b-iii.
- **open-questions Q4** (*is the embedded editor ever genuinely needed?*) is answered by the
  operator's six uses above, and closed.

## Open questions

None blocking 3b-i.
