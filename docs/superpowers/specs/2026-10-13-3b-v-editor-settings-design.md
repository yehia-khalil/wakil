# 3b-v: editor settings — font size, wrap, tabs, autosave, ignored files, heavy folders

**Date:** 2026-10-13
**Status:** design approved by the operator 2026-10-13, section by section
**Sub-phase:** 3b-v in the table the 3b-ii spec revised (`2026-10-13-3b-ii-editor-tree-design.md`,
*How Phase 3's editor work is split*). Part 1 waits on nothing; part 2 waits on 3b-ii's merge.

---

## Problem

3b-i hard-codes the editor's look and behaviour: `monaco-host.html` sets `fontSize: 12`, and tab
size, tabs or spaces and word wrap are left to Monaco's defaults. Nothing saves except ⌘S. 3b-ii
fixes the heavy folders at `vendor`, `node_modules` and `.git` and always shows gitignored files
dimmed. Its spec defers all of that here: *"No settings (3b-v): the heavy folders are fixed, and
the font, tabs and wrap stay as 3b-i set them."*

There is also nowhere to put a setting that belongs to the operator rather than to an org or a
project. design-language §14 names three scopes — Wakil (app-wide), organisation, project — and
only the last two exist in code.

## Decisions the operator took during this design (2026-10-13)

Recorded as **Decision 38** (3b-ii takes 37).

- **Two tiers, split by who the setting belongs to.**
  - **App-wide** (the operator's, every org and project): font size, word wrap, autosave, showing
    ignored files. Stored in a new `~/.wakil/settings.json` — the first file of design-language
    §14's *Wakil* scope.
  - **Per project** (the code's, committed with it): tab size, tabs or spaces, heavy folders.
    Stored in the project's `.wakil/project.json`, so a teammate gets the same values.
- **Autosave has three modes**, default **Off**: Off, *After a pause* (1 s after the last edit),
  *When focus leaves* (the pane loses focus, the tab switches, or Wakil resigns active).
- **Decision 30 stands.** The agent may read editor settings and never change them. Both writes are
  operator-only. The heavy-folder list decides what search and ⌘P cover, and an agent that could
  edit it could change that coverage without the operator seeing.
- **Go owns both tiers** (approach A). One read path for the pane and the agent; a UserDefaults
  store in Swift was rejected because it splits settings across two stores and the agent could not
  read the app-wide half through the same call.
- **Built in two parts.** Part 1 (font size, wrap, tabs, autosave) branches from `main` now. Part 2
  (ignored files, heavy folders) changes code 3b-ii is still writing, so it is built after 3b-ii
  merges, against 3b-ii's spec as the contract.

## What the operator gets

**The Settings tree gains two Editor nodes.**

```
Editor                font size, word wrap, autosave, show ignored files   ← new, app-wide
Organisation
Providers
Projects
  └ project
      ├ Editor        tab size, tabs or spaces, heavy folders               ← new, per project
      └ environment
          ├ Databases
          └ API
```

- **Editor (top level),** above Organisation. Its breadcrumb reads *Wakil › Editor*.

  | Setting | Control | Values | Default |
  |---|---|---|---|
  | Font size | stepper with a number field | 9–24 | 12 (3b-i's value) |
  | Word wrap | toggle | on, off | off |
  | Autosave | segmented | Off, After a pause, When focus leaves | Off |
  | Show ignored files | toggle | on, off | on (3b-ii's behaviour) |

- **Editor (under each project)** in the Projects list — every project in the organisation, not
  only the active one. Its breadcrumb reads *Projects › \<project\> › Editor*.

  | Setting | Control | Values | Default |
  |---|---|---|---|
  | Tab size | stepper with a number field | 1–16 | 4 |
  | Indent with | segmented | Spaces, Tabs | Spaces |
  | Heavy folders | editable list of folder names, one per row, with add and remove | names | `vendor`, `node_modules` |

  `.git` is always heavy and is shown in the list as a fixed, unremovable row.

- **No Save button.** A toggle or segment writes on click. A stepper writes on each step. A text
  field writes when focus leaves it or on Return (Rule 2). An invalid value keeps the typed text,
  shows why beside the field, and writes nothing (Rule 8).
- **Changes apply at once** to every open editor pane in the window: font size, wrap and tabs
  through Monaco's options; a heavy-folder or ignored-files change re-lists the trees, search and
  ⌘P.
- **A file's own indentation wins.** Monaco's `detectIndentation` stays on, so the project's tab
  size and tabs-or-spaces apply to a new file, a scratch tab, and a file whose indentation Monaco
  cannot detect (Rule 9).
- **Show ignored files off** hides gitignored files from the tree and from ⌘P. Search skips them
  either way, as 3b-ii specifies. Heavy folders still show in the tree, because the tree is how one
  is opened.
- **Heavy folders** are matched by name at any depth, among the folders git ignores — 3b-ii's
  meaning, with the names now from the project's list. `.git` is always heavy.

**Autosave.**

- *After a pause:* each edit to a dirty file tab re-arms a 1 s timer for that tab; when it fires,
  the tab saves.
- *When focus leaves:* a pane losing focus saves its dirty file tabs; switching away from a dirty
  tab saves that tab; Wakil resigning active saves every dirty file tab in the window.
- Both dispatch the existing `editor_save` — the same path as ⌘S, Decision 36's file write.
- **Never autosaved:**
  - a scratch tab (it has no file);
  - a tab marked *changed on disk* or *deleted* — autosave would overwrite the disk or recreate the
    file without the operator choosing to; 3b-i's Reload, Compare and ⌘S stay the operator's;
  - a tab whose save is already in flight (Rule 5).
- An agent edit makes a tab dirty like any other edit, so autosave saves it too. The agent can
  already save through `editor_save`; autosave adds no reach.
- **A failed autosave** shows its error whole on the tab, as a failed ⌘S does, and leaves the tab
  dirty (Rule 8). The next trigger tries again; there is no retry loop.

## What it does not do

- **No editor settings per organisation.** Two tiers only; an org tier can be added if a setting
  needs it.
- **No font family, theme, minimap, line numbers or rulers.** Not asked for.
- **No `.editorconfig`.** Project values live in `project.json`. Reading `.editorconfig` can be
  its own later step.
- **The non-git walk's skip list** (`internal/wakilcore/files.go`, `skippedDirs`) stays built in.
  The heavy-folder setting governs 3b-ii's heavy folders inside git repositories only.
- **No agent writes** (Decision 30).

## Design

### Go: `internal/wakilcore` and `cmd/wakil-ctx`

- **New `editorsettings.go`:**
  - `AppSettings` with an `Editor EditorAppSettings` field, stored at `~/.wakil/settings.json`
    (`WakilDir()`), under an `editor` key so the file can later hold the rest of §14's Wakil scope
    (theme, density).
  - `EditorAppSettings{FontSize int; WordWrap bool; Autosave string; ShowIgnored *bool}`;
    `Autosave` is `off`, `pause` or `focus`.
  - `EditorProjectSettings{TabSize int; InsertSpaces *bool; HeavyFolders []string}`, added to
    `Project` (`config.go`) as `Editor *EditorProjectSettings \`json:"editor,omitempty"\``.
  - A missing file, key or field reads as its default. No migration.
  - `LoadAppSettings`, `SaveAppSettings` (write to a temp file, then rename), and
    `ResolvedEditorSettings(project)` — the two tiers merged with defaults filled.
  - Validation, each failing as a `UserError` naming the field and the allowed range: font size
    9–24; tab size 1–16; autosave one of three; a heavy folder non-empty, no `/`, not `.` or
    `..`, not `.git` (always heavy), no duplicates.
  - Patches are pointer-typed, as `OrgPatch` is: read the file from disk, apply the fields the
    patch sets, validate, write. Never a flush of cached state (2e's rule).
- **`config_tree`** returns the app-wide `editor` block at the top and each project's resolved
  `editor` block, so the pane still draws from its one read.
- **Three wakil-ctx tools:**
  - `editor_settings` — read-only: the merged settings for the active project.
  - `set_editor_settings` — patches the app-wide tier.
  - `set_project_editor_settings` — patches one project's tier, the project named by name.
- **Part 2:** `files_list`, `files_search` and `files_list_dir` (3b-ii) take the heavy-folder
  list from the active project's resolved settings instead of the fixed list.

### WakilKit

- **`SettingsTree`** decodes the new `editor` blocks.
- **Registry actions:** `settings_editor_read` (`.read`, agent-reachable),
  `settings_editor_set` and `settings_project_editor_set` (`.control`, operator-only, Decision
  30). After a write, `refreshSettings` re-reads and every editor pane's options are re-applied.
- **`EditorSettings`** value type: the resolved settings the window holds after each read, and what
  each editor pane is given.
- **`Autosave`**, in `Editor/`: a small unit that takes edit, focus-loss, tab-switch and
  resign-active events plus a clock, and answers which tabs to save. It owns the per-tab pause
  timers and skips the never-autosaved tabs listed above. The window wires its answers to
  `editor_save`.
- **Part 2:** the ⌘P files source and the tree builder read `showIgnored`.

### WakilApp

- **`SettingsPane`** gains `SettingsNode.editor` and `.projectEditor(project:)`, their forms and
  breadcrumbs, following the Organisation node's draft-and-refusal pattern.
- **`monaco-host.html`** gains `wakilSetOptions({fontSize, wordWrap, tabSize, insertSpaces})`,
  calling `editor.updateOptions` and setting the model defaults for new models. The diff mode takes
  the font size too. `MonacoEditorRenderer` calls it when the page loads and whenever the settings
  change.
- Wakil resigning active (`NSApplication.willResignActiveNotification`) feeds `Autosave`.

## Errors and edges — against PRODUCT.md §Interaction Rules

| Rule | How 3b-v meets it |
|---|---|
| 1 Confirm only what destroys | No setting asks. Removing a heavy folder is undone by adding it back. Autosave is an ordinary edit's save. |
| 2 Enter is never required | Text fields write when focus leaves; toggles, segments and steppers write on change. |
| 3 A new input arrives focused | *Add folder* adds an empty row with its field focused. |
| 4 Anything that waits can be cancelled | A settings write is one small file write and has nothing to cancel. A re-list a heavy-folder change starts is cancelled by the next change, as 3b-ii's re-lists are. |
| 5 Work in flight shows it | Autosave never fires a second save for a tab whose save is in flight. |
| 6 Stay where the operator was | A write keeps the selected node, the scroll and the focused field. |
| 7 Override or ignore; don't refuse | The only refusals are out-of-range values and an agent write (Decision 30, named in the refusal). |
| 8 Errors are shown whole | An invalid value shows its message beside the field; an unreadable `settings.json` shows its error under the Editor node and the defaults apply; a failed autosave shows on the tab. |
| 9 Defaults suggest | Every setting has a default; the file's own indentation beats the project's. |

Edges:

- **A malformed `settings.json`:** the Editor node shows the parse error whole, the editor uses the
  defaults, and a write is refused until the file parses, so a write never discards what the
  operator wrote by hand.
- **A project with no `editor` block:** its Editor node shows the defaults; the first write adds the
  block.
- **Two windows:** each re-reads on every dispatch, so the second picks up the first's change on its
  next read.
- **Quitting with autosave on:** 3b-i's unsaved-changes prompt still runs for anything still dirty.
- **A tab saving through autosave while the operator types:** the save writes the text it was
  given; the tab stays dirty if the buffer moved on, and the pause timer re-arms.

## Testing

- **Go:**
  - Load: a missing file, a missing key, a partial file; defaults filled.
  - Validation: each range edge, each heavy-folder rule.
  - Patch: only the set fields change; a read-modify-write keeps a field written by hand.
  - `config_tree` and `editor_settings` output.
  - Part 2: `files_list` and `files_search` with a custom heavy-folder list.
- **WakilKit:**
  - `SettingsTree` decoding with and without the new blocks.
  - `Autosave` with a fake clock: the pause re-arms, focus loss and tab switch fire, resign active
    fires for every dirty file tab, and scratch, changed-on-disk, deleted and in-flight tabs are
    skipped.
  - The two write actions refuse the agent and name Decision 30.
  - Part 2: ⌘P and the tree with ignored files hidden.
- **e2e (the auditor):**
  - Each Editor node draws and writes; an invalid value shows its error and writes nothing.
  - A font-size change and a wrap change reach an open editor pane.
  - Autosave after a pause writes the file to disk; a scratch tab is not written.
  - `editor_settings` from the agent matches what the pane shows; an agent write is refused.
  - Part 2: hiding ignored files removes `.env` from the tree and ⌘P; adding a heavy folder makes
    it list only when opened.
- **Walk:** a runbook covering the two nodes, a live font and wrap change, each autosave mode,
  a project's tabs applied to a scratch tab, and (part 2) ignored files and heavy folders.

## Charter changes this sub-phase makes

- **Decisions:** **Decision 38**, recording the decisions above. Its **Reverse if** is: *"an editor
  setting needs a per-organisation value, or the agent needs to change a setting to do its job"*.
- **Design-language §14:** the Wakil scope gains its first file, `~/.wakil/settings.json`, and its
  first settings.
- **No invariant changes.** Settings writes stay operator-only (Decision 30); autosave uses
  Decision 36's file write.

## Open questions

None. The operator answered each one during the design.
