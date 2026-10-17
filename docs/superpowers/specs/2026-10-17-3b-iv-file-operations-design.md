# 3b-iv: file operations in the editor's tree — create, rename, move, Move to Trash

**Date:** 2026-10-17
**Status:** design approved by the operator 2026-10-17, section by section
**Sub-phase:** 3b-iv, which follows 3b-iii (stack #12, main a2a8b3f). It waits on nothing.
Decision 36 (file write) and Decision 37 (file operations are 3b-iv) are its starting point.

---

## Problem

The Files tree is read-only. A new file, a rename, a move or a delete sends the operator to
Finder or a terminal, and the editor's open tabs then point at a path that no longer exists.
Decision 37 put these operations in 3b-iv; Invariant 6 still lists file delete and rename as
refused, so each has to earn its way in.

## Decisions the operator took during this design (2026-10-17, recorded as Decision 41)

- **Delete is Move to Trash, with no dialog.** The Trash is undoable from Finder, so it does not
  destroy, and Rule 1 asks nothing. There is no permanent delete.
- **Rename is F2**, not Enter: Enter keeps opening the selected row, as today.
- **Creation has a button and a menu.** Each root row has one **+** button offering New File and
  New Folder; right-clicking a folder offers them too, with Rename and Move to Trash.
  Right-clicking a file offers Rename and Move to Trash.
- **Open tabs follow a rename or move**, unsaved edits and all. **Move to Trash closes clean
  tabs**; a tab with unsaved edits stays open, marked deleted, and saving it recreates the file.
- **The price is *allow*, for the operator and the agent, voice included.** Decision 36's
  argument carries over: the agent's harness already has `mv`, `mkdir` and `rm`, so the editor
  adds no reach, and the Trash is gentler than `rm`.
- **All three writes live in `wakil-files`** (approach A). Go is built with `CGO_ENABLED=0`, so it
  cannot call `NSFileManager`; it runs `/usr/bin/trash`, which macOS ships from 15. On macOS 14
  Move to Trash fails with an error that says so; nothing else is affected. Approach B (Swift
  trashes after Go confines) was rejected because it splits the check and the write across two
  processes; approach C (raise the floor to macOS 15) is out of scope.

## What the operator gets

### 1. Creating

- The **+** on a root row (shown on hover and when the row is selected) opens a menu: New File,
  New Folder. A folder's context menu has the same two. They create inside that root or folder.
- A **name field** appears as a row inside the target folder, which expands to show it. It arrives
  focused (Rule 3). Enter or focus leaving it creates (Rule 2); Esc, or leaving it empty, cancels.
- A name with slashes (`a/b.ts`) creates the folders on the way.
- A new **file** opens as a pinned tab with the cursor in it. A new **folder** is selected in the
  tree.

### 2. Renaming and moving

- **F2** on the selected row, or **Rename** in a row's context menu, turns the row into a field
  holding its name, the stem selected (not the extension).
- Enter or focus leaving it applies (Rule 2); Esc cancels.
- The name is relative to the item's folder: `sub/x.ts` moves it into a subfolder, `../x.ts` up
  one. Missing folders on the way are created. A move across roots is an agent action only
  (`editor_rename` with a `to` in another root); the field stays within the item's root.
- After a rename the renamed row is selected (Rule 6).

### 3. Move to Trash

- **⌘⌫** with the tree focused, or **Move to Trash** in a file's or folder's context menu.
  No dialog (Rule 1; Decision 41).
- The selection moves to the next row in tree order, else the previous — never to the top
  (Rule 6), the rule Changes uses when its row goes.
- A root cannot be trashed; its menu does not offer it.

### 4. Open tabs, in every editor pane

| Operation | Clean tab | Tab with unsaved edits | Diff tab |
|---|---|---|---|
| Rename / move (a file, or a folder above it) | re-pointed to the new path | re-pointed; edits, undo history kept; autosave writes to the new path | closed; Changes relists the file |
| Move to Trash | closed | stays open, `diskState = .deleted` (the existing state); ⌘S recreates the file | closed |

A rename, move or delete made outside Wakil (Finder, a terminal, the agent's own `mv`) behaves as
today: the watcher refreshes the tree and marks an open tab deleted. Only operations made through
these actions re-point tabs.

### Agent actions (Invariant 2 — one path for both)

| Action | Arguments | Price |
|---|---|---|
| `editor_create` | `path` (absolute, inside a root), `kind`: `file` \| `dir` | allow |
| `editor_rename` | `path`, `to` (both absolute, inside the roots) | allow |
| `editor_trash` | `path` | allow |

Each description says what it refuses. The action journal records each, with `from` and `to` for
a rename. `editor_create` with `kind: file` opens the new file as the operator's button does.

## What it does not do

- No permanent delete, and no undo inside Wakil: the Trash is the undo (Finder's Put Back).
- No drag and drop, no copy, no duplicate, no multi-select.
- No `git mv`: a move is a filesystem move, so Changes shows a delete and an add until staged — the
  same as a Finder move.
- No cancel control (Rule 4): each operation is one filesystem call that does not wait on anything.

## Design

### Go — `internal/wakilcore/files.go`, `cmd/wakil-files/main.go`

Three tools beside `files_write`, each confined to the active project's roots:

| Tool | Does | Refuses |
|---|---|---|
| `files_create {path, kind}` | creates an empty file (mode 0644) or a folder, and missing parents | an existing name; a path outside the roots |
| `files_move {from, to}` | `os.Rename`, creating missing parents of `to` | an existing `to` (unless it is `from` itself, so a case-only rename works on a case-insensitive volume); `from` or `to` outside the roots; `from` a root; `to` under `from` |
| `files_trash {path}` | runs `/usr/bin/trash -s <path>` | a missing `/usr/bin/trash` ("Move to Trash needs macOS 15: /usr/bin/trash is missing"); a path outside the roots; a root |

- **Confinement on the parent, the name kept.** `ConfineFilePath` resolves symlinks, so a link
  would be judged by its target. These three confine the *parent* folder (`mustExist` for move's
  `from` and for trash) and act on the last name with `Lstat`, so a link is created, moved or
  trashed as itself and nothing outside the roots is touched. `.` and `..` as a last name are
  refused.
- **The trash binary is a variable** (`trashBin = "/usr/bin/trash"`) so tests point it at a fake.
- Errors are `UserError`s that name the path and the reason, whole (Rule 8).
- `files_write`'s description drops "delete and rename are not offered".

### WakilKit

- **`EditorActions.swift`**: `editor_create`, `editor_rename`, `editor_trash`, each calling its
  tool and then updating the store; price *allow*, as `editor_save` declares it.
- **Tab re-pointing** (new, in `EditorTabs.swift`): a pure function from (tabs, from, to) to tabs —
  a `.file` tab whose path is `from` or under `from/` gets the new path; `.diff` tabs at or under
  `from` are dropped. Applied to every editor pane's tabs.
- **After a trash**: a pure function from (tabs, path) — clean `.file` tabs at or under `path` are
  closed, dirty ones get `diskState = .deleted`; `.diff` tabs closed.
- **Selection after a trash**: a pure function on the tree's rows, beside `editorTreeStep`.
- The file lists refresh through the watcher as today; the actions also dispatch `editor_refresh`
  for the touched folders so the tree does not wait on FSEvents.

### WakilApp — `EditorColumn.swift`

- The **+** button on root rows; `.contextMenu` on root, folder and file rows.
- An **inline name field** row (create) and an in-place field (rename): focused on appearance,
  commits on Enter or focus loss, Esc cancels; disabled while its write is in flight (Rule 5);
  an error shown whole under it, the typed text kept (Rule 8).
- `treeKey` gains F2 and ⌘⌫ (⌘⌫ is a chord, so it is matched before `isChord` returns).

## Errors and edges — against PRODUCT.md §Interaction Rules

| Rule | How 3b-iv meets it |
|---|---|
| 1 Confirm only what destroys | Move to Trash is undoable, so no dialog; nothing else destroys — create and move refuse an existing name rather than overwrite |
| 2 Enter never required | The name field commits on focus loss |
| 3 New input focused | The name field arrives focused; a new file's tab takes the cursor |
| 4 Cancel what waits | Nothing waits; each operation is one filesystem call |
| 5 In flight shows, not twice | The field is disabled while its write runs |
| 6 Stay where the operator was | Rename selects the renamed row; Trash selects the next row |
| 7 Override or ignore; don't refuse | Refusals are only Invariant 6's (outside the roots, a root) and data loss (an existing name) — each says which |
| 8 Errors whole | Shown in full under the field; the typed text kept |
| 9 Defaults suggest | Rename preselects the stem only; the whole name stays editable |

## Testing

- **Go** (`internal/wakilcore/files_test.go`, `cmd/wakil-files/main_test.go`): create a file, a
  folder, nested parents; refuse an existing name, outside the roots, a symlinked parent escaping
  them, `.`/`..`; move within a root, across roots, case-only, a folder; refuse an existing `to`,
  `to` under `from`, moving a root; a link inside the roots pointing outside is moved and trashed
  as itself; trash through a fake binary that records its argument; the missing-binary error.
- **Swift** (`WakilKitTests`): tab re-pointing for a file, a folder above it, dirty and clean,
  across two panes; diff tabs dropped; trash closing clean tabs and marking dirty ones; the
  selection after a trash (middle, last, only row); each action's journal entry and refusal path.
- **e2e** (the auditor, at Cover): create from the **+** with the field focused; F2 rename with
  focus loss committing; ⌘⌫ with the selection on the next row; a dirty tab surviving Trash; the
  context menus' entries per row kind.

## How it lands — one unit of work per PR, stacked

1. Go: the three tools and their tests.
2. WakilKit: the three actions, tab re-pointing, selection after trash.
3. WakilApp: the **+**, context menus, the name field, F2 and ⌘⌫.
4. Docs and charter (below), then Cover and Walk.

## Charter changes this sub-phase makes

- **North-star §4, Invariant 6**: the table gains *File create, move and Move to Trash — local
  files inside the project's roots — wakil-files — 2026-10-17*; "and file delete and rename" leaves
  the still-refused list; "Four have earned in" becomes five.
- **`decisions.md`**: Decision 41 (above), and an entry in *Invariant 6 — the writes that have
  earned in* dated 2026-10-17 with the justification. Decision 36's "Still refused" sentence gains
  "(earned in 2026-10-17, Decision 41)".
- **North-star §8**: no row — §8 has no 3b rows and the charter is already over its 4,000 words
  (4,026); the phase log records 3b-iv, as it did 3b-iii. Invariant 6's edit must not add words
  net.
- **`design-language.md`**: the root row's **+** and the inline name field.

## Open questions

None.

## Amendment — 2026-10-17, while planning and building

- **R1.** `files_list` reports empty folders (`empty`): git lists files, never folders, so a new
  folder would not show.
- **R2.** A renamed tab's Monaco model is re-keyed, not reopened, so undo history survives.
- **R3.** A move across volumes is refused (EXDEV), not done as copy-then-delete.
- **R4.** Renaming to the same name is ignored (Rule 7).
- **R5.** A tab keeps its last four former keys (`formerKeys`), so a double rename before a render
  still finds its model, and a stale key never picks the wrong active tab.
- The name field takes focus back after a refused commit only when the commit came from Enter;
  after a click away it keeps the error and the typed text without taking focus (Rule 6).
- Refusals reach the name field through a new rethrowing `WindowModel.dispatchFromSurfaceThrowing`
  beside `bindFromSurface` (Rule 8: the field shows the refusal whole).
