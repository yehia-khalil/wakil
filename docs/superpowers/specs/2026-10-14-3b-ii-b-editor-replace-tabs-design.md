# 3b-ii-b: replace across the project, revealing the open file, and moving and closing tabs

**Date:** 2026-10-14
**Status:** design approved by the operator 2026-10-14, section by section
**Sub-phase:** 3b-ii-b, which follows 3b-ii (the editor's left column, #403–#413, main 5c38f728)
and comes before 3b-iii. It waits on nothing. It is numbered *ii-b* so the later sub-phases keep
their numbers.

---

## Problem

The operator walked 3b-ii on 2026-10-14 and asked for four things it lacks:

- *"we would need to have a button that locates the open file inside the tree and move to it"*
- *"can we move and rearrange open tabs?"*
- *"and close tabs by clicking on scroll button?"*
- *"we will need a find all replace all like global search we need global replace"*

Search across the project finds text in many files, but changing it means opening each file and
using the find bar's replace, one file at a time. The tree shows the project but cannot show
*where the file you are reading lives*. Tabs open in the order they were opened, and only ⌘W or
the × closes one.

## What the operator gets

### 1. Replace across the project

- **A ▸ toggle** beside the Search view's query line opens a **Replace** field under it. The field
  keeps its text when it is closed and opened again (Rule 2).
- **The preview.** While the Replace field holds text, each result line shows the change inline: the
  match struck through, and the replacement after it in violet. An empty Replace field with the
  toggle open previews deleting the matches. With `.*` on, `$1`, `${name}` and `$$` work as Go's
  `regexp.Expand` reads them, the same engine the search uses.
- **Two buttons:** *Replace All* in the Search view's header, and *Replace in this file* on each file
  group's header (shown on hover and when the group is selected). **Neither asks first** (Rule 1):
  the replace is undoable (below).
- **What is replaced.** At the moment of the press, Go searches again and replaces **every** match —
  past the 2,000 the view shows — in exactly the files the search covers: ignored files, the heavy
  folders, binary files and files over 2 MB are skipped, as search skips them. It never writes
  against results the operator saw before the disk changed.
- **Open tabs are edited, not written.** A file open in any editor pane of the window gets the
  replacement in its buffer: the tab turns dirty and ⌘Z undoes it there. Its file on disk is not
  touched, so unsaved work is never overwritten. (3b-v's autosave then saves it on its own terms, if
  the operator turned autosave on.) Every other file is written to disk, atomically.
- **While it runs**, the tick and *Cancel* show (Rules 4, 5), and both buttons are disabled. Cancel
  stops between files; what was already written stays and can be undone.
- **After it runs**, one line: *Replaced 37 in 12 files · Undo replace*, then the search runs again
  to show what is left. A file that could not be written is listed under that line with its error
  whole; the others went through (Rule 8).
- **Undo replace** restores every file the replace wrote, **only while that file is still exactly
  as the replace left it** (its modification time unchanged). A file changed since is listed as
  *"changed since the replace — left as it is"*, and the rest are still restored. Buffer edits are
  not part of it: they are undone with ⌘Z in their tab. One undo is kept — the latest replace's —
  in memory for the window's life. A new replace replaces it; quitting drops it.

### 2. Revealing the open file in the tree

- **An icon button** in the Files header, and a ⌘P command, *Reveal Active File in Tree*.
- It opens every folder above the active tab's file (the chain `editor_tree_expand` already opens),
  then selects that row and scrolls it into view. The keyboard stays where it was (Rule 6).
- **Disabled** when the pane has no file tab in front — an empty pane or a scratch tab — with a
  tooltip saying so. A file outside the roots cannot be open, so there is nothing to refuse.
- **Never automatic.** The tree does not follow the active file by itself: that would open folders
  and move the tree while the operator browses (Rule 6). A *follow* setting can join 3b-v's editor
  settings later.

### 3. Moving tabs

- **Drag** a tab along its own pane's strip; a violet line shows where it will drop. Dropping moves
  it there. The tab that was active stays active.
- The order is the pane's saved tab order, so it **comes back after a relaunch**.
- A drag that ends outside the strip, or on the tab's own place, changes nothing.
- **Within one pane only.** Dragging a tab into another editor pane would carry its unsaved text
  and undo history across; it is not part of this sub-phase.

### 4. Middle-click closes a tab

- A middle-click on a tab closes it through the same action ⌘W uses: a clean tab closes at once, a
  dirty one gets 3b-i's Save / Don't Save / Cancel prompt.

### Agent actions (Invariant 2 — one path for both)

| Action | What it does | Price |
|---|---|---|
| `editor_replace` | `replacement` (string, may be empty), optional `file` (absolute path: one file only). Query and switches are the pane's Search view's. Answers counts, failures and the pane's `read_pane`. | *allow* — the file write of Decision 36 (Decision 39) |
| `editor_replace_undo` | Undoes the pane's latest replace as described above. Refused when there is none to undo (the one refusal; Rule 7 allows it — there is nothing to override). | *allow* |
| `editor_tree_reveal` | Opens the folders above `path` (default: the active file). It opens folders only: the selection and the scroll are the operator's view, which no agent action moves (3b-ii's ruling on the keyboard, Rule 6). | control |
| `editor_move_tab` | `from`, `to` (0-based, strip order). | control |

`read_pane`'s `search` gains `replace` (the field's text, or null while the toggle is closed),
`replace_in_flight`, and `last_replace` (`{replaced, files, failures: [{path, error}],
undoable}` or null).

## What it does not do

- Replace one match at a time from the results. Open the file and use ⌥⌘F for that.
- Move a tab between panes, or tear one off into a new pane.
- Follow the active file in the tree automatically.
- Keep Undo replace across a relaunch.
- Rename, move or delete files (3b-iv).

## Design

### Go: `internal/wakilcore/files.go` and `cmd/wakil-files`

- **`ReplaceText(text, query, replacement) (newText string, count int, err error)`** — the pure
  core. It compiles the same pattern `SearchFiles` compiles (`searchPattern`), and expands the
  replacement with `regexp.Expand` when `regex` is set, literally otherwise. The whole-word and
  case switches behave as in search.
- **`files_replace_text`** — that function as a tool, batched: `{texts[], query, case, word, regex,
  replacement}` → `{results: [{text, count}]}`, in order. Read-only: it touches no file. Wakil uses
  it for open tabs (one text per tab) and for the preview (every shown result line in one call), so
  all three agree with the search.
- **`files_replace`** — `{roots?, query, case, word, regex, replacement, only?, skip[]}`:
  - It walks exactly the files `SearchFiles` walks for those roots (the same listing, skips and
    caps), or only the file `only` names, confined by `ConfineFilePath` after resolving symlinks.
  - It skips every path in `skip` (the open tabs).
  - For each file with a match, it writes the new text atomically (`WriteFile`'s temp-and-rename),
    keeping the file's mode.
  - It answers `{files: [{path, count, original, mtime}], failures: [{path, error}],
    truncated_files}`. `original` is the text before the write, so the undo can restore it, and
    `mtime` is the time after it.
  - Context cancellation stops it between files, and it answers what it had written so far.
- `files_write` stays the one other write. **Undo** uses it: for each file, a `files_read` checks the
  mtime, then `files_write` puts `original` back.

### WakilKit: the `Editor/` folder

- **`EditorReplace.swift`** — the replace state per pane (field text, toggle, in flight, last
  replace with its undo records), and the pure helpers: undo records, the result line's text, and
  the preview spans.
- **`EditorActions.swift`** gains the four actions.
  - `editor_replace`:
    1. collects the open tabs' paths across the window's editor panes;
    2. calls `files_replace` with them as `skip`;
    3. for each open tab that matches, calls `files_replace_text` on its buffer and applies the
       result as one undoable agent edit (3b-i's `editor_replace_range` path, so ⌘Z takes it back
       whole);
    4. records the undo;
    5. re-runs the search.

    A cancel reaches the tool call, as search's does.
  - `editor_replace_undo` restores what is still unchanged and reports the rest.
  - `editor_move_tab` reorders `tabs` and keeps `active` on the same tab. The order persists through
    `setEditorTabs`.
  - `editor_tree_reveal` uses `editor_tree_expand`'s chain.
- **The preview** sends every shown result line to `files_replace_text` in one call, 250 ms after
  the Replace field or the results change, and draws each line from the answer. Only the 2,000
  shown lines are previewed; Replace All still replaces past them.

### WakilApp

- `EditorColumn.swift`:
  - the ▸ toggle and the Replace field;
  - the struck-through and violet preview in each result line;
  - *Replace All* and *Replace in this file*;
  - the result line and its *Undo replace*;
  - the reveal button.

  The reveal button selects and scrolls its row in the view after the action opens the folders.
- `EditorPane.swift`: the tab strip's drag and drop (a drop indicator; dispatches `editor_move_tab`)
  and the middle-click. SwiftUI has no middle-click gesture, so an `NSView` overlay on each tab
  takes `otherMouseDown` with `buttonNumber == 2` and dispatches `editor_close` for that tab.
- The palette gains the *Reveal Active File in Tree* command.

## Errors and edges — against PRODUCT.md §Interaction Rules

| Rule | How 3b-ii-b meets it |
|---|---|
| 1 Confirm only what destroys | Replace All asks nothing: it is undoable, and its price is *allow* (Decision 39). Middle-click on a dirty tab asks, as ⌘W does. |
| 2 Enter is never required | The preview follows the Replace field as it is typed. The field keeps its text when the toggle closes. |
| 3 A new input arrives focused | Opening the toggle focuses the Replace field. |
| 4 Anything that waits can be cancelled | A replace shows Cancel; it stops between files. |
| 5 Work in flight shows it | The tick shows, and the buttons are disabled while a replace runs, so it cannot fire twice. |
| 6 Stay where the operator was | A replace keeps the results' scroll and selection; the search that follows keeps them where rows survive. Reveal moves the tree only because the operator pressed it, and never the keyboard. A tab move keeps the active tab. |
| 7 Override or ignore; don't refuse | Refusals: a path outside the roots (Invariant 6), and an undo with nothing to undo. |
| 8 Errors are shown whole | Each file that failed is listed with its error whole; an invalid regex shows Go's error and disables the buttons; the rest of a replace goes through. |
| 9 Defaults suggest | Nothing new is defaulted. |

Edges:

- **The search was stale** (*files changed since this search*): the replace searches again first, so
  it writes what is on disk now. The preview may differ from what is written; the result line
  says what was written.
- **A file open in a tab of another editor pane** is a buffer edit in that pane, as for the
  current pane's tabs.
- **A read-only file** fails with its error; the rest go through.
- **A file over 2 MB, binary or not UTF-8** is skipped, as in search, and never listed as a failure.
- **A replacement that leaves the text the same** writes nothing and counts nothing.
- **The agent's replace while the operator types in a tab** lands as an agent edit with 3b-i's
  edit-serial guard, so neither loses text.
- **An org or project switch** drops the undo with the rest of the editor's per-window state.

## Testing

- **Go:**
  - `ReplaceText`: literal, case, whole word, regex with `$1`, `${name}` and `$$`; an empty
    replacement; no match.
  - `files_replace`:
    - confinement, including through a symlink;
    - every match past 2,000;
    - `skip` and `only`;
    - the 2 MB, binary and ignored skips;
    - cancellation between files;
    - a failed write listed while the others go through;
    - `original` and `mtime` returned;
    - the file's mode kept.
- **WakilKit:**
  - `editor_replace`:
    - a dirty open tab gets a buffer edit and its file is untouched;
    - closed files are written;
    - the undo record;
    - a cancel keeps what was written;
    - a failure is reported whole;
    - `file` limits it to one file.
  - `editor_replace_undo`: restores unchanged files; lists a file changed since; refused with
    nothing to undo.
  - `editor_move_tab`: order, the active tab kept, persisted and restored.
  - `editor_tree_reveal`: the chain opened; the active file by default.
  - `read_pane`'s new fields.
- **e2e:**
  - Replace All across the git project, with one target open and dirty: the disk changes
    elsewhere, the open file's disk does not, and its buffer does.
  - Undo replace, after one file is changed on disk in between: that file is listed and left; the
    rest are restored.
  - Replace in this file.
  - Reveal by the button, and the agent's `editor_tree_reveal` (parity on the open folders).
  - A tab dragged to a new place (the harness's synthetic drag); the order after a relaunch.
  - The middle-click goes in `uncoverable.tsv`: the harness posts no middle button. The runbook
    walks it.
- **Walk:** about eight rows:
  - a real replace across `walk-tree`, with an open dirty tab;
  - Undo replace;
  - replace in one file with `$1`;
  - Cancel on a long replace;
  - reveal;
  - drag tabs and relaunch;
  - middle-click a clean tab and a dirty one;
  - the agent replacing and undoing.

## Charter changes this sub-phase makes

- **Decision 39:** a replace across many files is Decision 36's file write, one file at a time,
  priced *allow* for the operator and the agent alike. It writes only inside the roots, and it
  never writes a file open in a tab (its buffer is edited instead). Its undo is in memory and
  conditional. *Reverse if:* a replace is found to have overwritten work the operator had not
  saved — then the price becomes *gate*.
- **Design-language §11:** the Editor entry gains the Replace field and its preview, the reveal
  button, tab drag and middle-click.
- **The 3b-ii spec's roadmap table** gains the 3b-ii-b row, between 3b-ii and 3b-iii.
- **No invariant changes.** Invariant 6's writes are unchanged in kind: this is more of the same
  file write, inside the same roots.

## Open questions

None. The operator answered each one during the design.
