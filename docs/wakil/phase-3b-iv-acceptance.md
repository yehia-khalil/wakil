# 3b-iv — file operations in the editor's tree: acceptance

**Spec:** [`2026-10-17-3b-iv-file-operations-design.md`](../superpowers/specs/2026-10-17-3b-iv-file-operations-design.md)

**Not walked yet.** Only the operator walks; every Walked cell below is empty until then.

The exit criterion, from the spec: create, rename, move and Move to Trash from the Files tree, with
open tabs following, and the same three operations for the agent (`editor_create`, `editor_rename`,
`editor_trash`). Decision 41 records the operator's choices (Trash with no dialog, F2 to rename, a
**+** per root, tabs follow a rename); the rulings made while planning and building are the spec's
2026-10-17 amendment (R1–R5).

## 0. Setup

Run this in the repo root, on this Mac, after `make build` and `make app-bundle`. It is safe to
re-run. The roots live under `$TMPDIR` (`/var/folders/…`), on purpose: a root reached through the
`/var` → `/private/var` symlink is one of the cases the build had to get right.

```bash
(
set -e
ORG=personal
cd ~/Desktop/scripts/wakil-public
W="$TMPDIR/walk-fileops"
rm -rf "$W"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
g() { git -c user.name=walk -c user.email=walk@example.com "$@"; }
mkdir -p "$W/api/app/Models" "$W/api/app/Http" "$W/api/src" "$W/docs/trash-me" "$W/docs/keep/sub" "$W/project"
cd "$W/api" && git init -q -b main
echo 'class User {}' > app/Models/User.php
echo 'class BookingController {}' > app/Http/BookingController.php
echo 'class Kernel {}' > app/Http/Kernel.php
for f in a b c; do echo "const $f = 1;" > "src/$f.ts"; done
echo 'api' > README.md
git add . && g commit -qm init
for f in a b c; do echo "$f" > "$W/docs/trash-me/$f.txt"; done
echo 'clean' > "$W/docs/keep/clean.txt"; echo 'dirty' > "$W/docs/keep/sub/dirty.txt"
cat > "$W/project/project.json" <<J
{"name":"walk-fileops","org":"$ORG","roots":[{"path":"$W/api"},{"path":"$W/docs"}],"scopes":{},"environments":{}}
J
cd ~/Desktop/scripts/wakil-public
./bin/wakil project rm walk-fileops --org "$ORG" || true
./bin/wakil project add walk-fileops --path "$W/project/project.json" --org "$ORG"
)
```

`api` is a git repository; `docs` is not. Launch with
`cd ~/Desktop/scripts/wakil-public && WAKIL_ORG=personal app/Wakil.app/Contents/MacOS/Wakil`, make
`walk-fileops` active with ⌘P, open an editor pane and show the tree with ⌘B.

## 1. The walk

Walk in order, on `walk-fileops`, in `personal`.

| # | Do | Expect | Walked |
|---|---|---|---|
| 1 | Right-click the `api` root row, then a file (`README.md`), then a folder (`app`) | Root: New File, New Folder only. File: Rename, Move to Trash only. Folder: all four, a separator before Rename. No root offers Rename or Move to Trash | |
| 2 | Hover the `api` root; press its **+**, New File; type `notes/today.md`, Enter; type `hi` | The **+** shows on hover and when the root is selected; the name field arrives focused; `notes` is made, `today.md` opens as a pinned tab and `hi` lands in it, not in the tree | |
| 3 | **+**, New Folder, `a/b`, Enter; right-click `a/b`, New Folder, `c`, Enter | Each new folder appears and is selected (violet outline); the selection never jumps to the top | |
| 4 | Open `app/Models/User.php`, type a word (unsaved). Select its row, press F2 | A field holding `User.php` with `User` selected, `.php` not | |
| 5 | Type `Account`, then click in the editor | The rename applies on the click; `Account.php` is selected in the tree; its tab follows, still unsaved; ⌘Z in the tab removes the word | |
| 6 | Open `app/Http/Kernel.php` in a second editor pane; expand `app/Http` in the first; F2 on `app`, `core`, Enter | Both panes' tabs now under `core/`, unsaved edits kept; `core` stays open in this pane and is selected | |
| 7 | F2 on `src/a.ts`, type `b`, Enter; then click the Files header, press ↓ and ⌘⌫ | `…/src/b.ts already exists` shown whole under the field, `b.ts` kept; after the click the tree takes ↓ and ⌘⌫ trashes the selected row, no dialog | |
| 8 | In `docs/trash-me`, select `b.txt` and press ⌘⌫ three times | `b.txt` goes and `c.txt` is selected; then `c.txt` goes and `a.txt` is selected; then `a.txt` goes and `trash-me` is selected. All three are in Finder's Trash; Put Back restores them | |
| 9 | Open `docs/keep/clean.txt`; open `docs/keep/sub/dirty.txt` and type; Move `keep` to Trash from its menu; set Settings → Editor → Autosave to *on focus change* and click another pane; then ⌘S in the dirty tab | The clean tab closes; the dirty one stays, marked deleted, and autosave does not bring it back; ⌘S recreates `keep/sub/dirty.txt` with what was typed | |
| 10 | F2 on a file, type a name, Enter, and press ⌘⌫ at once | The rename lands; nothing but the selected row is trashed, and no error about a missing file appears | |

## 2. Residue — what the walk cannot establish

- **macOS 14**: Move to Trash needs `/usr/bin/trash` (macOS 15); on 14 it fails with an error that
  says so. This Mac is on 15 or later, so the walk cannot see that message.
- **A move across volumes** is refused (R3); the walk's roots are on one volume.

## 3. Cover — what the e2e auditor covered and could not

Checks: `e2e/checks/seeded/3b-iv-*.jsonl`. The residue — what no check covers, and why:

- **Context menus** (row 1, and New Folder inside a folder in row 3) — walk-only: no `do` arm opens
  a context menu (no right-click, no `AXShowMenu`). The checks create inside a just-made folder by
  typing a path into the root's **+** instead.
- **F2 and Rename** (rows 4–7, 10) — walk-only: F2 cannot be sent. Orca's key table has no F-keys
  (it knows backspace, delete, down, escape, forwarddelete, home, left, pagedown, pageup, return,
  right, space), and typing F2's character (U+F705) does not reach the tree. So the stem
  preselection (Rule 9), a click away committing a rename (Rule 2), the renamed row selected
  (Rule 6) and ⌘⌫ during a rename in flight are walk-only. Tabs following a rename — in two panes,
  with unsaved edits, ⌘Z after it, typing across it, an open folder staying open — are checked
  through `editor_rename`, the same action the field dispatches (Invariant 2).
- `editor_create`, `editor_rename`, `editor_trash` — no parity: the operator's channels are a menu,
  typing and Enter, F2, and ⌘⌫, and a parity step's UI half is one click or one drag. Both channels
  are checked separately.
- `editor.tree.name.error` — display text, read, not pressed.
- **The violet outline, the + showing on hover** — visual, the operator's (rows 2–3).

Found by the checks, red and kept red until fixed (the machine walk below names the steps):

- **⌘⌫ trashes nothing** with a tree row selected and the tree focused (`3b-iv-trash-key`,
  `3b-iv-name-refused`); ↑↓, Return and type-ahead on the same focus work. A real keyboard event
  (System Events, key code 51 with ⌘) did the same. Likely `EditorColumn.swift:498`:
  SwiftUI's `KeyEquivalent.delete` is U+0008, the Delete key sends U+007F.
- **A trash that closes the front preview tab takes the keyboard out of the tree** into the editor
  (`3b-iv-trash-selection`, step 20): `EditorPane.swift:172–180` treats the tab that comes to the
  front as a new one (Rule 3) and focuses Monaco, against Rule 6. The selection itself moves right
  (next, else previous); the check gives the tree the keyboard back to prove it.
- **Intermittent: keystrokes doubled after an agent renames the open file** — once, `ghi` typed
  after `editor_rename` of the front tab read back `ghighi` (one act); passed on the next run.
  `3b-iv-rename-tabs` is quarantined by name until it is understood.

## 4. The machine walk

Rendered by `make e2e-runbook` after the Cover rung. Nothing is written here by hand.

<!-- machine-walk: generated by `make e2e-runbook`; everything between these markers is overwritten -->

**The machine walk is red** — 151 condition(s) of the Cover rung are not met:

```
e2e/checks/seeded/2c-iii-1-bundle-path.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/2c-iii-2-block.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/2c-iii-3-live-prompt.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/2c-iii-4-interrupt.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/2c-iii-5-full-screen.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/2c-iii-6-no-orphan.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/2c-iii-7-org-switch.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/2d-ii-composer-keeps-input.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/2d-ii-composer-return-sends.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/2d-ii-settings-speech.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/2d-ii-voice-escape.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/2d-ii-voice-lands-focused.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/2d-ii-voice-lands-unsent.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/2d-ii-voice-silence.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/2e-settings-databases-dispatch.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/2e-settings-databases.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/2e-settings-doors.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/2e-settings-narrow-rows.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/2e-settings-organisation.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/2e-settings-pane.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/2e-settings-unlink-indicator.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/2e-settings-unlink.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/365-terminal-option-word.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/365-terminal-paste.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/365-terminal-select-backspace.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/365-terminal-select-type.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-i-editor-close-keys.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-i-editor-files-palette.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-i-editor-read-only.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-i-editor-save-as-field.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-i-editor-save-as-replace.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-i-editor-scratch-save.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-i-editor-tabs-language.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-i-editor-unsaved-org-switch.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-i-editor-unsaved-quit.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-i-editor-unsaved-save.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-ii-b-replace-all.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-ii-b-replace-cancel.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-ii-b-replace-file.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-ii-b-replace-undo.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-ii-b-reveal.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-ii-b-tab-move.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-ii-find.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-ii-palette-ignored.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-ii-search-cancel.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-ii-search-errors.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-ii-search.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-ii-tree-ignored-heavy.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-ii-tree-live.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-ii-tree-toggle.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-iii-changes-drill.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-iii-changes-keys.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-iii-changes-list.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-iii-changes-live.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-iii-changes-press.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-iii-diff-open-file.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-iii-diff-refusals.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-iii-git-pane-migrates.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-iii-palette-changed-file.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-iii-peek.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-iii-tree-letters.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-iv-name-refused.jsonl is red: 3 failure(s), across 15 assertion(s):
  3b-iv-name-refused.jsonl step 40: "editor_trash" was expected to be refused with "/e2e-api/notes does not exist", and it ran
  3b-iv-name-refused.jsonl step 38: the act was made but reported unverified (synthetic input), and no confirming state read followed it — an act that may not have happened must never pass
  3b-iv-name-refused.jsonl step 39: the act was made but reported unverified (synthetic input), and no confirming state read followed it — an act that may not have happened must never pass
e2e/checks/seeded/3b-iv-rename-tabs.jsonl is red: no check ran, so nothing was proved
e2e/checks/seeded/3b-iv-trash-key.jsonl is red: 6 failure(s), across 10 assertion(s):
  3b-iv-trash-key.jsonl step 13: pane "editor-1" field "tabs[1]" is there (it holds {"diff":null,"dirty":false,"disk_state":"inSync","language":"plaintext","notice":null,"path":"/var/folders/0h/97h9cspn7vv3l2pl6g5r07h80000gn/T/wakil-e2e3017186408/e2e-api/notes","preview":true,"root":"/var/folders/0h/97h9cspn7vv3l2pl6g5r07h80000gn/T/wakil-e2e3017186408/e2e-api","saving":false,"scratch":null}), and it was asserted absent (still true after waiting 3s)
  3b-iv-trash-key.jsonl step 14: no journal entry carries "\"action\":\"editor_trash\"" (30 entries read) (still true after waiting 3s)
  3b-iv-trash-key.jsonl step 16: pane "editor-1" field "column.open" does not contain "/e2e-portal\""; it holds ["/var/folders/0h/97h9cspn7vv3l2pl6g5r07h80000gn/T/wakil-e2e3017186408/e2e-api"] (still true after waiting 3s)
  3b-iv-trash-key.jsonl step 17: "editor_trash" was expected to be refused with "/e2e-api/notes does not exist", and it ran
  3b-iv-trash-key.jsonl step 12: the act was made but reported unverified (synthetic input), and no confirming state read followed it — an act that may not have happened must never pass
  3b-iv-trash-key.jsonl step 15: the act was made but reported unverified (synthetic input), and no confirming state read followed it — an act that may not have happened must never pass
e2e/checks/seeded/3b-iv-trash-selection.jsonl is red: 1 failure(s), across 17 assertion(s):
  3b-iv-trash-selection.jsonl step 20: focus is not on editor.column: it is on AXTextArea, within editor.pane › SwiftUI.WindowGroup<SwiftUI.ModifiedContent<WakilApp.WakilWindow, SwiftUI._PreferenceWritingModifier<SwiftUI.PreferredColorSchemeKey>>>-1-AppWindow-1 (still true after waiting 3s)
e2e/checks/seeded/3b-v-click-focuses-pane.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-v-editor-autosave-focus.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-v-editor-autosave-pause.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-v-editor-autosave-prompt-guard.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-v-editor-indent-scratch.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-v-editor-live-options.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-v-editor-settings-nodes.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-v-heavy-folders-edit.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-v-heavy-folders-refusal.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-v-heavy-folders.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-v-project-editor-settings.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-v-show-ignored.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/agent-pane-is-drawn.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-bind.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-body-editor.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-body-hole-cursor.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-bound-locks.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-cancel.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-chip-keys-second-chip.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-chip-keys-text-after.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-chip-keys.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-editor-copy-bound.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-editor-json-holes.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-editor-wrap.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-env-roundtrip.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-hole.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-one-author-focus.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-open.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-paste-curl-hotkey.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-paste-curl-refused.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-paste-curl-www.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-paste-curl.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-query-sync.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-recent-root.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-recent-shared.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-recent.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-reopen-cross-entry.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-rows.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-saved-as-typed.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-send-what-it-shows.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-send.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-set-request.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-surface.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-the-rest.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-type-keeps-holes.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-unbind.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/capacity-low-reading.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/capacity-passed-reset.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/db-cancel-click.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/db-cancel-escape.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/db-detail-big-cells.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/db-detail-strip.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/db-grid-copy.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/db-query-line-agent-replaces.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/db-query-line-format.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/db-query-line-long.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/db-query-line-not-formatted.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/db-query-line-return.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/db-query-line-run.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/journal-error-reason.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/landing.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/palette-api-entry.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/palette-api-send.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/palette-command-step.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/palette-escape.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/palette-modes.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/palette-open-kinds.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/palette-run-error.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/palette-switch-environment.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/palette-table-row.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/project-root-note.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/vocabulary.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/agent/2d-i-code-hint.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/agent/2d-i-failed-source.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/agent/2d-i-hint-or-plain.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/agent/2d-i-over-limit.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/agent/2d-i-pane-hint.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/agent/2d-i-schema-hint.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/agent/2d-ii-thread-earlier.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/agent/2d-ii-voice-turn.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/agent/3b-iii-changes-voice-hint.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/agent/api-origin-after-account-switch.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/agent/both-surfaces.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/agent/capacity-after-turn.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/agent/two-enter.jsonl was never run against this build, so nothing is known about it — run `make e2e`
the failability record was written against 8ff80bd6f21b and this tree is on 15ea115ddde3 — run `make e2e-new`
```

Walked by `make e2e` against 15ea115ddde3, rendered 2026-10-17 16:17 UTC by `make e2e-runbook`. Re-render it with that target; edits between the markers are overwritten.

**The tree carried uncommitted changes**, so these checks ran against that tree rather than against the commit named above.

| Check | `make e2e` | Red against the base | Assertions | Evidence |
|---|---|---|---|---|
| `org-plane.jsonl` | ✓ exit 0 | not new on this branch | 3 | — |
| `2c-iii-1-bundle-path.jsonl` | **never run** | — | — | — |
| `2c-iii-2-block.jsonl` | **never run** | — | — | — |
| `2c-iii-3-live-prompt.jsonl` | **never run** | — | — | — |
| `2c-iii-4-interrupt.jsonl` | **never run** | — | — | — |
| `2c-iii-5-full-screen.jsonl` | **never run** | — | — | — |
| `2c-iii-6-no-orphan.jsonl` | **never run** | — | — | — |
| `2c-iii-7-org-switch.jsonl` | **never run** | — | — | — |
| `2d-ii-composer-keeps-input.jsonl` | **never run** | — | — | — |
| `2d-ii-composer-return-sends.jsonl` | **never run** | — | — | — |
| `2d-ii-settings-speech.jsonl` | **never run** | — | — | — |
| `2d-ii-voice-escape.jsonl` | **never run** | — | — | — |
| `2d-ii-voice-lands-focused.jsonl` | **never run** | — | — | — |
| `2d-ii-voice-lands-unsent.jsonl` | **never run** | — | — | — |
| `2d-ii-voice-silence.jsonl` | **never run** | — | — | — |
| `2e-settings-databases-dispatch.jsonl` | **never run** | — | — | — |
| `2e-settings-databases.jsonl` | **never run** | — | — | — |
| `2e-settings-doors.jsonl` | **never run** | — | — | — |
| `2e-settings-narrow-rows.jsonl` | **never run** | — | — | — |
| `2e-settings-organisation.jsonl` | **never run** | — | — | — |
| `2e-settings-pane.jsonl` | **never run** | — | — | — |
| `2e-settings-unlink-indicator.jsonl` | **never run** | — | — | — |
| `2e-settings-unlink.jsonl` | **never run** | — | — | — |
| `365-terminal-option-word.jsonl` | **never run** | — | — | — |
| `365-terminal-paste.jsonl` | **never run** | — | — | — |
| `365-terminal-select-backspace.jsonl` | **never run** | — | — | — |
| `365-terminal-select-type.jsonl` | **never run** | — | — | — |
| `3b-i-editor-close-keys.jsonl` | **never run** | — | — | — |
| `3b-i-editor-disk-changed.jsonl` | ✓ exit 0 | ✓ red vs 0c9e85c6f259, recorded 2026-10-12 | 34 | — |
| `3b-i-editor-files-palette.jsonl` | **never run** | — | — | — |
| `3b-i-editor-read-only.jsonl` | **never run** | — | — | — |
| `3b-i-editor-refusals.jsonl` | ✓ exit 0 | ✓ red vs 0c9e85c6f259, recorded 2026-10-12 | 24 | — |
| `3b-i-editor-save-as-field.jsonl` | **never run** | — | — | — |
| `3b-i-editor-save-as-replace.jsonl` | **never run** | — | — | — |
| `3b-i-editor-scratch-save.jsonl` | **never run** | — | — | — |
| `3b-i-editor-tabs-language.jsonl` | **never run** | — | — | — |
| `3b-i-editor-unsaved-org-switch.jsonl` | **never run** | — | — | — |
| `3b-i-editor-unsaved-quit.jsonl` | **never run** | — | — | — |
| `3b-i-editor-unsaved-save.jsonl` | **never run** | — | — | — |
| `3b-ii-b-replace-all.jsonl` | **never run** | — | — | — |
| `3b-ii-b-replace-cancel.jsonl` | **never run** | — | — | — |
| `3b-ii-b-replace-file.jsonl` | **never run** | — | — | — |
| `3b-ii-b-replace-undo.jsonl` | **never run** | — | — | — |
| `3b-ii-b-reveal.jsonl` | **never run** | — | — | — |
| `3b-ii-b-tab-move.jsonl` | **never run** | — | — | — |
| `3b-ii-find.jsonl` | **never run** | — | — | — |
| `3b-ii-palette-ignored.jsonl` | **never run** | — | — | — |
| `3b-ii-refusals.jsonl` | ✓ exit 0 | ✓ red vs 8e8ec7d29e7f, recorded 2026-10-14 | 5 | — |
| `3b-ii-search-cancel.jsonl` | **never run** | — | — | — |
| `3b-ii-search-errors.jsonl` | **never run** | — | — | — |
| `3b-ii-search.jsonl` | **never run** | — | — | — |
| `3b-ii-tree-ignored-heavy.jsonl` | **never run** | — | — | — |
| `3b-ii-tree-live.jsonl` | **never run** | — | — | — |
| `3b-ii-tree-preview.jsonl` | ✓ exit 0 | ✓ red vs 8e8ec7d29e7f, recorded 2026-10-14 | 19 | — |
| `3b-ii-tree-toggle.jsonl` | **never run** | — | — | — |
| `3b-iii-changes-drill.jsonl` | **never run** | — | — | — |
| `3b-iii-changes-keys.jsonl` | **never run** | — | — | — |
| `3b-iii-changes-list.jsonl` | **never run** | — | — | — |
| `3b-iii-changes-live.jsonl` | **never run** | — | — | — |
| `3b-iii-changes-press.jsonl` | **never run** | — | — | — |
| `3b-iii-diff-open-file.jsonl` | **never run** | — | — | — |
| `3b-iii-diff-refusals.jsonl` | **never run** | — | — | — |
| `3b-iii-git-pane-migrates.jsonl` | **never run** | — | — | — |
| `3b-iii-palette-changed-file.jsonl` | **never run** | — | — | — |
| `3b-iii-peek.jsonl` | **never run** | — | — | — |
| `3b-iii-tree-letters.jsonl` | **never run** | — | — | — |
| `3b-iv-create-file.jsonl` | ✓ exit 0 | ✓ red vs a2a8b3fc9050 | 22 | — |
| `3b-iv-create-folder.jsonl` | ✓ exit 0 | ✓ red vs a2a8b3fc9050 | 21 | — |
| `3b-iv-name-refused.jsonl` | **red**, exit 1 | ✓ red vs a2a8b3fc9050 | 15 | `.context/e2e/20261017-161424` |
| `3b-iv-rename-tabs.jsonl` | **red**, exit 1 | ✓ red vs a2a8b3fc9050 | 0 | `.context/e2e/20261017-161605` |
| `3b-iv-trash-key.jsonl` | **red**, exit 1 | ✓ red vs a2a8b3fc9050 | 10 | `.context/e2e/20261017-161459` |
| `3b-iv-trash-selection.jsonl` | **red**, exit 1 | ✓ red vs a2a8b3fc9050 | 17 | `.context/e2e/20261017-161524` |
| `3b-iv-trash-tabs.jsonl` | ✓ exit 0 | ✓ red vs a2a8b3fc9050 | 20 | — |
| `3b-v-click-focuses-pane.jsonl` | **never run** | — | — | — |
| `3b-v-editor-autosave-focus.jsonl` | **never run** | — | — | — |
| `3b-v-editor-autosave-pause.jsonl` | **never run** | — | — | — |
| `3b-v-editor-autosave-prompt-guard.jsonl` | **never run** | — | — | — |
| `3b-v-editor-indent-scratch.jsonl` | **never run** | — | — | — |
| `3b-v-editor-live-options.jsonl` | **never run** | — | — | — |
| `3b-v-editor-settings-nodes.jsonl` | **never run** | — | — | — |
| `3b-v-heavy-folders-edit.jsonl` | **never run** | — | — | — |
| `3b-v-heavy-folders-refusal.jsonl` | **never run** | — | — | — |
| `3b-v-heavy-folders.jsonl` | **never run** | — | — | — |
| `3b-v-project-editor-settings.jsonl` | **never run** | — | — | — |
| `3b-v-show-ignored.jsonl` | **never run** | — | — | — |
| `agent-pane-is-drawn.jsonl` | **never run** | — | — | — |
| `api-bind.jsonl` | **never run** | — | — | — |
| `api-body-editor.jsonl` | **never run** | — | — | — |
| `api-body-hole-cursor.jsonl` | **never run** | — | — | — |
| `api-bound-locks.jsonl` | **never run** | — | — | — |
| `api-cancel.jsonl` | **never run** | — | — | — |
| `api-chip-keys-second-chip.jsonl` | **never run** | — | — | — |
| `api-chip-keys-text-after.jsonl` | **never run** | — | — | — |
| `api-chip-keys.jsonl` | **never run** | — | — | — |
| `api-editor-copy-bound.jsonl` | **never run** | — | — | — |
| `api-editor-json-holes.jsonl` | **never run** | — | — | — |
| `api-editor-wrap.jsonl` | **never run** | — | — | — |
| `api-env-roundtrip.jsonl` | **never run** | — | — | — |
| `api-hole.jsonl` | **never run** | — | — | — |
| `api-one-author-focus.jsonl` | **never run** | — | — | — |
| `api-open.jsonl` | **never run** | — | — | — |
| `api-paste-curl-hotkey.jsonl` | **never run** | — | — | — |
| `api-paste-curl-refused.jsonl` | **never run** | — | — | — |
| `api-paste-curl-www.jsonl` | **never run** | — | — | — |
| `api-paste-curl.jsonl` | **never run** | — | — | — |
| `api-query-sync.jsonl` | **never run** | — | — | — |
| `api-recent-root.jsonl` | **never run** | — | — | — |
| `api-recent-shared.jsonl` | **never run** | — | — | — |
| `api-recent.jsonl` | **never run** | — | — | — |
| `api-reopen-cross-entry.jsonl` | **never run** | — | — | — |
| `api-rows.jsonl` | **never run** | — | — | — |
| `api-saved-as-typed.jsonl` | **never run** | — | — | — |
| `api-send-what-it-shows.jsonl` | **never run** | — | — | — |
| `api-send.jsonl` | **never run** | — | — | — |
| `api-set-request.jsonl` | **never run** | — | — | — |
| `api-surface.jsonl` | **never run** | — | — | — |
| `api-the-rest.jsonl` | **never run** | — | — | — |
| `api-type-keeps-holes.jsonl` | **never run** | — | — | — |
| `api-unbind.jsonl` | **never run** | — | — | — |
| `capacity-low-reading.jsonl` | **never run** | — | — | — |
| `capacity-passed-reset.jsonl` | **never run** | — | — | — |
| `db-cancel-click.jsonl` | **never run** | — | — | — |
| `db-cancel-escape.jsonl` | **never run** | — | — | — |
| `db-detail-big-cells.jsonl` | **never run** | — | — | — |
| `db-detail-strip.jsonl` | **never run** | — | — | — |
| `db-grid-copy.jsonl` | **never run** | — | — | — |
| `db-query-line-agent-replaces.jsonl` | **never run** | — | — | — |
| `db-query-line-format.jsonl` | **never run** | — | — | — |
| `db-query-line-long.jsonl` | **never run** | — | — | — |
| `db-query-line-not-formatted.jsonl` | **never run** | — | — | — |
| `db-query-line-return.jsonl` | **never run** | — | — | — |
| `db-query-line-run.jsonl` | **never run** | — | — | — |
| `journal-error-reason.jsonl` | **never run** | — | — | — |
| `landing.jsonl` | **never run** | — | — | — |
| `palette-api-entry.jsonl` | **never run** | — | — | — |
| `palette-api-send.jsonl` | **never run** | — | — | — |
| `palette-command-step.jsonl` | **never run** | — | — | — |
| `palette-escape.jsonl` | **never run** | — | — | — |
| `palette-modes.jsonl` | **never run** | — | — | — |
| `palette-open-kinds.jsonl` | **never run** | — | — | — |
| `palette-run-error.jsonl` | **never run** | — | — | — |
| `palette-switch-environment.jsonl` | **never run** | — | — | — |
| `palette-table-row.jsonl` | **never run** | — | — | — |
| `project-root-note.jsonl` | **never run** | — | — | — |
| `vocabulary.jsonl` | **never run** | — | — | — |
| `2d-i-code-hint.jsonl` | **never run** | — | — | — |
| `2d-i-failed-source.jsonl` | **never run** | — | — | — |
| `2d-i-hint-or-plain.jsonl` | **never run** | — | — | — |
| `2d-i-over-limit.jsonl` | **never run** | — | — | — |
| `2d-i-pane-hint.jsonl` | **never run** | — | — | — |
| `2d-i-schema-hint.jsonl` | **never run** | — | — | — |
| `2d-ii-thread-earlier.jsonl` | **never run** | — | — | — |
| `2d-ii-voice-turn.jsonl` | **never run** | — | — | — |
| `3b-iii-changes-voice-hint.jsonl` | **never run** | — | — | — |
| `api-origin-after-account-switch.jsonl` | **never run** | — | — | — |
| `both-surfaces.jsonl` | **never run** | — | — | — |
| `capacity-after-turn.jsonl` | **never run** | — | — | — |
| `two-enter.jsonl` | **never run** | — | — | — |
| `.scratch/3b-iv/probe/probe-hid.jsonl` | — | — | — | a record for a check the corpus no longer holds |
| `.scratch/3b-iv/probe/probe-menu.jsonl` | — | — | — | a record for a check the corpus no longer holds |
| `.scratch/3b-iv/probe/probe-rename.jsonl` | — | — | — | a record for a check the corpus no longer holds |
| `.scratch/3b-iv/probe/probe-trash.jsonl` | — | — | — | a record for a check the corpus no longer holds |
| `.scratch/3b-iv/probe/probe-trash2.jsonl` | — | — | — | a record for a check the corpus no longer holds |

**What went red, in the harness's own words:**

- 3b-iv-name-refused.jsonl step 40: "editor_trash" was expected to be refused with "/e2e-api/notes does not exist", and it ran
- 3b-iv-name-refused.jsonl step 38: the act was made but reported unverified (synthetic input), and no confirming state read followed it — an act that may not have happened must never pass
- 3b-iv-name-refused.jsonl step 39: the act was made but reported unverified (synthetic input), and no confirming state read followed it — an act that may not have happened must never pass
  - evidence: tree.txt, screenshot.png, panes.json, failure.txt, acts.txt, under `.context/e2e/20261017-161424/3b-iv-name-refused.jsonl/` (gitignored)
- 3b-iv-rename-tabs.jsonl: quarantined, and it passed this time — it is still not evidence until it is taken out of quarantine deliberately
- 3b-iv-trash-key.jsonl step 13: pane "editor-1" field "tabs[1]" is there (it holds {"diff":null,"dirty":false,"disk_state":"inSync","language":"plaintext","notice":null,"path":"/var/folders/0h/97h9cspn7vv3l2pl6g5r07h80000gn/T/wakil-e2e3017186408/e2e-api/notes","preview":true,"root":"/var/folders/0h/97h9cspn7vv3l2pl6g5r07h80000gn/T/wakil-e2e3017186408/e2e-api","saving":false,"scratch":null}), and it was asserted absent (still true after waiting 3s)
- 3b-iv-trash-key.jsonl step 14: no journal entry carries "\"action\":\"editor_trash\"" (30 entries read) (still true after waiting 3s)
- 3b-iv-trash-key.jsonl step 16: pane "editor-1" field "column.open" does not contain "/e2e-portal\""; it holds ["/var/folders/0h/97h9cspn7vv3l2pl6g5r07h80000gn/T/wakil-e2e3017186408/e2e-api"] (still true after waiting 3s)
- 3b-iv-trash-key.jsonl step 17: "editor_trash" was expected to be refused with "/e2e-api/notes does not exist", and it ran
- 3b-iv-trash-key.jsonl step 12: the act was made but reported unverified (synthetic input), and no confirming state read followed it — an act that may not have happened must never pass
- 3b-iv-trash-key.jsonl step 15: the act was made but reported unverified (synthetic input), and no confirming state read followed it — an act that may not have happened must never pass
  - evidence: tree.txt, screenshot.png, panes.json, failure.txt, acts.txt, under `.context/e2e/20261017-161459/3b-iv-trash-key.jsonl/` (gitignored)
- 3b-iv-trash-selection.jsonl step 20: focus is not on editor.column: it is on AXTextArea, within editor.pane › SwiftUI.WindowGroup<SwiftUI.ModifiedContent<WakilApp.WakilWindow, SwiftUI._PreferenceWritingModifier<SwiftUI.PreferredColorSchemeKey>>>-1-AppWindow-1 (still true after waiting 3s)
  - evidence: tree.txt, screenshot.png, panes.json, failure.txt, acts.txt, under `.context/e2e/20261017-161524/3b-iv-trash-selection.jsonl/` (gitignored)

**`make e2e-new` saw every check this branch added go red against a2a8b3fc9050.**

**Every action and control this branch added carries a check.** 3 action(s) and 3 control(s) are new on this branch.

- actions:  68 of 107 dispatched by a check
- writes:   20 of 78 carry a parity check
- controls: 122 of 213 exercised by a check

**95 piece(s) of surface no check can reach**, each with the reason given in `e2e/checks/uncoverable.tsv`:

- `db_cancel` — its parity: the click (or Esc) cancels the read in flight, and db_cancel refuses a pane with nothing running (`nothing is running on pane …`), so the dispatch half cannot be given the same state — and a second slow read between the halves is not expressible inside one parity step, api_cancel's case. Both channels ARE covered: db-cancel-click.jsonl cancels one recursive-CTE read by db.<pane>.cancel and the next by dispatch, asserting the same state after each through read_pane (running false, cancelledAfterMs, the previous 2 rows kept, sort empty) and "cancelled after" in the tree; db-cancel-escape.jsonl cancels by Esc. What no check can express is the comparison.
- `editor_rename` — its parity (3b-iv): the operator's channels are F2 and a row's context menu Rename, then typing — and neither can be driven: Orca's key table has no F-keys and no arm opens a context menu. So no UI half exists to compare, and the field's rename is walk-only (runbook rows 4–7). The dispatch is covered by 3b-iv-rename-tabs.jsonl: a folder and a file renamed under open tabs in two panes, unsaved edits and ⌘Z kept, typing across it, the open folder staying open, and its four refusals.
- `editor_peek` — its parity (3b-iii): the operator's channel is a click on a change mark in Monaco's gutter, inside the WKWebView — a web element with no accessibility identifier, which the resolver cannot address (editor_goto's case: inside Monaco, the one non-action path). The dispatch is covered by 3b-iii-peek.jsonl (opened on a mark, refused on an unmarked line, on an untracked file and on a diff tab in 3b-iii-diff-refusals.jsonl); the mark click is the runbook's row 8.
- `ctx_unlink_provider` — its parity: the click removes the binding, so the dispatch half cannot be given the same id. Dispatch and both channels' behaviour ARE covered by 2e-settings-unlink.jsonl; what no check can express is the comparison.
- `api_fill_from_curl` — its parity: the UI half of a parity step is a click or a drag, and the operator's channel is a paste (cmd+v into the path editor), so the comparison cannot be expressed. Both channels ARE covered: the dispatch by api-paste-curl.jsonl, the paste by api-paste-curl-hotkey.jsonl, each asserting the same draft and the Filled from cURL line; what no check can express is the comparison.
- `editor_restore` — its parity (3b-i): no operator control — it runs when a window relaunches onto saved tabs, and one check is one launch. The dispatch is covered by 3b-i-editor-disk-changed.jsonl (an open, dirty tab is kept as it is); restoring after a relaunch is the runbook's row 9.
- `db_remove_database` — its parity: the click removes the database, and removing one that is gone is refused (`no database … in environment …`), so the dispatch half cannot be given the same params. Dispatch is covered by 2e-settings-databases-dispatch.jsonl and the click by 2e-settings-databases.jsonl; what no check can express is the comparison.
- `api_cancel` — its parity: the click cancels the send in flight, and api_cancel refuses a pane with nothing in flight (`nothingInFlight`), so the dispatch half cannot be given the same state — and a second Send between the halves is not expressible. Both channels ARE covered by api-cancel.jsonl, each after its own Send, asserting the same cancelled response through read_pane; what no check can express is the comparison.
- `api_render_curl` — Two reasons, and the second is the one that lasts. A dispatch cannot hold the row id, which is minted per send and published only in read_pane; and the operator's own Copy as cURL puts its line on the PASTEBOARD, which no check can read — the act is real and its result leaves the window. `api_reopen`'s CLICK left this file when the recent strip gave it a button, because a reopen's effect lands in the draft where a check can see it; its dispatch half is still here, for the first of these reasons. Covered by WakilKitTests: curlIsPastTenseOnly, curlOnlyMentionsACredentialThereWasOne, curlEmitsAndNeverParses.
- `ctx_provider_login` — #254. Opens a browser on the operator's machine and authenticates as them. No harness can drive it and none should: every run would leave a real credential behind.
- `editor_new_scratch` — its parity (3b-i): the operator's channel is ⌘T, a menu key equivalent — a key, not a click or a drag, and the UI half of a parity step is a click or a drag only (api_fill_from_curl's case); the empty pane only names the key. The dispatch is covered by most 3b-i-editor-* checks; ⌘T by 3b-i-editor-scratch-save.jsonl and 3b-i-editor-close-keys.jsonl, asserting the Untitled-N tab through read_pane.
- `editor_changes_step` — its parity (3b-iii): the operator's channel is ↑↓ in the Changes view — keys, not a click or a drag — and the UI half of a parity step is a click or a drag only (api_fill_from_curl's case). Both channels ARE covered: the dispatch by 3b-iii-changes-drill.jsonl (across roots, both directions, clamped at the end, skipping a collapsed root, asserting the highlight and the diff tab through read_pane), the keys by 3b-iii-changes-keys.jsonl (↓ from nothing, ↑↓ across roots, after ⌘⇧G); what no check can express is the comparison.
- `editor_create` — its parity (3b-iv): the operator's channel is the root's + menu (New File / New Folder), a name typed into the field and Enter or a click away — a menu, typing and a key, not one click or drag, and the UI half of a parity step is a click or a drag only (api_fill_from_curl's case). Both channels ARE covered: the + by 3b-iv-create-file.jsonl and 3b-iv-create-folder.jsonl (a pinned tab with the cursor in it, a/b and a/b/c selected, a click away committing), the dispatch by the same two (a file opened pinned, a folder shown) and its refusals (an existing name, outside the roots, a bad kind); what no check can express is the comparison.
- `editor_replace_range` — its parity (3b-i): no operator control — the operator's own edits are typing in Monaco, the one non-action path (`editorBufferDidChange`), so no UI half exists. The dispatch is covered by most 3b-i-editor-* checks, and its read-only refusal by 3b-i-editor-read-only.jsonl.
- `api_unbind` — its parity: the click returns the binding to its hole, and api_unbind refuses a position that holds no binding (`unbindNotABinding`), so the dispatch half cannot be given the same params — and a re-drag between the halves is not expressible. Both channels ARE covered by api-unbind.jsonl, each after its own drag, asserting the same hole back through read_pane; what no check can express is the comparison.
- `editor_peek_close` — its parity (3b-iii): the operator's channels are Esc in the peek (a key), typing (which closes it in the store), and the peek's × (HTML inside the WKWebView, no accessibility identifier). Esc, typing and the dispatch ARE each covered by 3b-iii-peek.jsonl, asserting peek null with the cursor and the marks kept; the × button is walk-only, in no runbook row.
- `editor_peek_step` — its parity (3b-iii): the operator's channels are ↑↓ while the peek is open (keys Monaco hands back) and the peek's ↑ ↓ buttons, which are HTML inside the WKWebView with no accessibility identifier — neither is a click on a control the resolver can address. Both the dispatch and ↑↓ ARE covered by 3b-iii-peek.jsonl, each asserting peek.index and the cursor through read_pane; the buttons are walk-only (row 8 presses ↓, a key).
- `capacity_record` — its parity: the operator's channel is the agent's own stream — the window records a `rate_limit_event` frame from a turn on its own, with no click or drag — so the UI half of a parity step cannot be expressed: no click or drag of the operator's produces it, so there is no UI half to compare. Both channels ARE covered: the dispatch by capacity-low-reading.jsonl and capacity-passed-reset.jsonl, the stream by agent/capacity-after-turn.jsonl, each asserting the reading it lands on the indicator; what no check can express is the comparison.
- `editor_replace_undo` — its parity (3b-ii-b): the Undo click spends the pane's one undo, and the dispatch after it is then refused (`no replace to undo`) — api_undo_fill's case. The click is 3b-ii-b-replace-undo.jsonl's (undone, restored 2, and the changed-since line for the file changed on disk), and so is the refusal of the dispatch after it.
- `ctx_add_provider` — its parity: the click creates a binding under an id, so a dispatch with the same params collides with what the click just made. Covered by 2e-settings-doors.jsonl up to the browser leg.
- `editor_move_tab` — its parity (3b-ii-b): the drag moves a tab, and the same {from, to} dispatched on the moved strip moves a different tab, so the two halves cannot read back the same order. The drag and the dispatch are each 3b-ii-b-tab-move.jsonl's, each asserting the strip's order and the active tab through read_pane.
- `settings_open` — its parity: the only UI path is the `Settings…` MENU item, and a menu's buttons are not in the accessibility tree until the menu is open — the same rule that excuses every other menu control. Checks drive it by its real gesture, cmd+comma, and 2e-settings-pane.jsonl also dispatches it.
- `editor_goto` — its parity (3b-i): there is no operator control for it — the operator moves the cursor inside Monaco, the one non-action path (design-language §11), so no UI half exists to compare. The dispatch is covered by 3b-i-editor-tabs-language.jsonl (cursor.line and cursor.column through read_pane) and refused on an empty pane in 3b-i-editor-refusals.jsonl.
- `editor_trash` — its parity (3b-iv): the operator's channels are ⌘⌫ with the tree focused (a key) and a row's context menu Move to Trash (no arm opens one), so no UI half of one click or drag exists. ⌘⌫ is 3b-iv-trash-key.jsonl and 3b-iv-name-refused.jsonl; the dispatch is 3b-iv-trash-selection.jsonl (selection to the next row, else the previous; a clean tab closed; its refusals) and 3b-iv-trash-tabs.jsonl (a dirty tab kept, marked deleted, not autosaved back, recreated by ⌘S).
- `editor_select` — its parity (3b-i): no operator control — the operator selects inside Monaco, the one non-action path, so no UI half exists. The dispatch is covered by most 3b-i-editor-* checks, which read selected_text back to prove what a save wrote.
- `editor_replace` — its parity (3b-ii-b): the click replaces, and the same dispatch after it finds nothing left to replace and answers a different last_replace, so the two halves cannot read back the same pane (api_cancel's case: the click consumes its own subject). Both channels ARE covered: the click (Replace All) by 3b-ii-b-replace-all.jsonl and the dispatch by 3b-ii-b-replace-undo.jsonl, each asserting last_replace's files and the Replaced … line; Replace in this file by 3b-ii-b-replace-file.jsonl, and Cancel by 3b-ii-b-replace-cancel.jsonl.
- `editor_close` — its parity (3b-i): the operator's channels are ⌘W (a key) and the unsaved prompt's Don't Save, and the click consumes its own subject — the dispatch half after it would close a different tab or be refused (`the editor pane has no open tab`), api_cancel's case. Both channels ARE covered: 3b-i-editor-close-keys.jsonl (⌘W clean, ⌘W dirty → Esc / Cancel / Don't Save) and the dispatch with and without discard in 3b-i-editor-refusals.jsonl.
- `editor_open_file` — its parity (3b-iii): the operator's channel is ⌘⏎ in a diff tab, a menu key equivalent (Maximize Pane's item, which a diff tab redirects) — a key, not a click or a drag — so no UI half can be expressed. Both channels ARE covered by 3b-iii-diff-open-file.jsonl, each opening app.txt at the diff's cursor line with the diff tab kept, and ⌘⏎ on a scratch tab maximizing; its refusal on a deleted file by 3b-iii-changes-live.jsonl.
- `api_undo_fill` — its parity: the Undo click forgets the fill it undoes, and api_undo_fill refuses a pane with nothing to undo, so the dispatch half cannot be given the same state after the click — and a second fill between the halves is not expressible inside one parity step. Both channels ARE covered by api-paste-curl.jsonl, the click after one fill and the dispatch after another, each asserting the same restored draft through read_pane; what no check can express is the comparison.
- `api_reopen` — its dispatch: it needs a row id, which is minted per send and published only in read_pane — the same reason api_render_curl below is here. The operator's gesture IS covered: api-recent.jsonl presses api.recent.0.reopen and asserts the draft it rebuilds. Permanent, not blocked: nothing in the vocabulary carries a value from read_pane into a dispatch.
- `api.recent.<…>.curl` — Its whole effect is a string on the SYSTEM PASTEBOARD, which no check can read — the act is real and its result leaves the window, so a check could press it and assert nothing, which is the check-that-cannot-fail this file exists to prevent rather than permit. `TerminalPane`'s own Copy is silent for the same reason and carries no indicator. The line it copies is `apiRenderCurl`'s, covered by WakilKitTests: curlIsPastTenseOnly, curlOnlyMentionsACredentialThereWasOne, curlEmitsAndNeverParses. If this pane ever draws a "copied" acknowledgement, the act becomes observable and this line should go.
- `api.response.<…>` — the Body · Headers choice (W20) is drawn only over a reply, and no fixture host ever replies — every entry is `.invalid` or the never-answering `slow`, and wakil-http refuses http://. apiResponseOffersHeaders and apiResponseHeaderRows are pinned in ApiPaneLayoutTests; the drawn table is the runbook's check 5.
- `db.<…>.detail` — the row detail strip's container (.contain, RowDetailStrip.swift): its labels and values, with no press action of its own. What it draws is read by db-detail-strip.jsonl and db-detail-big-cells.jsonl; its values are db.<pane>.detail.<i>, read.
- `db.<…>.flight` — a Text (db pane footer): the flight line, "running …" while a read is in flight and "cancelled after …" once one is cancelled. Read, not pressed — db-cancel-click.jsonl and db-cancel-escape.jsonl assert "cancelled after" in the tree, and db-cancel-click.jsonl its absence after the next read.
- `db.<…>.grid` — the db grid's surface (.contain): it has no press action and refuses AXFocused (measured: axresolve not_focusable), as a focusable SwiftUI surface with no AX focus attribute — its keyboard focus is SwiftUI's own, given when the pane is focused, which the checks do by clicking rail.db-<n>. Its keys are driven that way: ↑↓, Space and Esc by db-detail-strip.jsonl, ⌘C by db-grid-copy.jsonl; its rows' contents are read through read_pane.
- `db.<…>.notFormatted` — display text, not a control: a static `Text` (DBPane.swift) carrying Format's refusal reason, with no press action, and the vocabulary addresses only `click`/`focus` by identifier while `expect.tree` matches by text, so no step can "press" it. Its content IS asserted: db-query-line-not-formatted.jsonl expects `not formatted: a string opened at character 39 never closes` in the tree, then its absence after the next edit.
- `db.<…>.row.<…>.detail` — the row's ⓘ: drawn only while the pointer hovers inside a row whose children are ignored by accessibility (.accessibilityElement(children: .ignore)), so it is never in the tree, and the vocabulary has no hover step (window.capacity's case). The same toggle is the row's "Show details" accessibility action and Space on the grid, and db-detail-strip.jsonl drives Space (open, close, another row). Pressing the ⓘ itself is walk-only.
- `editor.changes.loading` — the Changes header's load tick (3b-iii, Rule 5): a shape drawn only while a root's git status is being read, which against the fixture's tiny repositories lasts milliseconds — never long enough for a tree read to see (editor.tree.loading's case). Seeing it is the walk's.
- `editor.changes.rootError:<…>` — a Text (3b-iii, Rule 8): the second and later lines of a root's error, drawn whole beneath its Changes header — and only when the error HAS a second line. The fixture's non-repository error is one line (`e2e-git · not a git repository`, asserted in the header by 3b-iii-changes-list.jsonl), so it is never drawn; the split is pinned by WakilKitTests (gitRootErrorDetail), and a multi-line error is walk-only.
- `editor.column` — the editor's left column's container (.contain, 3b-ii): its header, the tree or the search view, and the edge, and it takes no input itself. What it draws is read by every 3b-ii-* check; its controls are editor.column.files / .search, pressed by 3b-ii-tree-toggle.jsonl, editor.column.edge, dragged there, and the tree's and search's own.
- `editor.compare.diff` — Compare's Monaco host (3b-i): a WKWebView container with no press action. 3b-i-editor-disk-changed.jsonl asserts Compare's header opens and closes (button and Esc); what the diff shows is the operator's ruling (runbook row 6).
- `editor.compare.failure` — a Text (3b-i, Rule 8): drawn only when the file cannot be read back for Compare. The fixture's files are always readable and no step can make one unreadable mid-launch; display text with no press action either way. The runbook walks Compare.
- `editor.diff.banner` — a Text (3b-iii): `binary · 3 bytes` or `file is … · first 2 MB shown` over a binary or oversized diff. Display text with no press action. Read, not pressed — 3b-iii-changes-live.jsonl writes an untracked binary and asserts `binary · 3 bytes` in the tree and diff.binary through read_pane.
- `editor.diff.error` — a Text (3b-iii, Rule 8): a diff tab's error, drawn whole — only when git_show fails, which no fixture file makes it do mid-launch. Display text with no press action; diff.error is asserted null by 3b-iii-changes-drill.jsonl, and the error path is pinned by WakilKitTests (EditorDiffTabsTests).
- `editor.diff.gone` — a Text (3b-iii, Rule 7): "No longer changed", over a diff tab whose file left its group. Display text with no press action. Read, not pressed — 3b-iii-changes-live.jsonl asserts it in the tree and diff.no_longer_changed through read_pane, after `git add`, `rm` and `git checkout` in a terminal.
- `editor.diff.loading` — a diff tab's Loading line (3b-iii, Rule 5): drawn only while git_show reads the two sides, milliseconds against the fixture; editor_changes_select returns after the fetch, so every check reads diff.loading false through read_pane (3b-iii-changes-drill.jsonl, 3b-iii-diff-refusals.jsonl). Display text with no press action.
- `editor.diskChanged` — the disk line's container (.contain, 3b-i): its text and two buttons. Read, not pressed — 3b-i-editor-disk-changed.jsonl asserts "disk.txt changed on disk" and its absence while comparing and after Reload; its buttons are editor.reload and editor.compare, pressed.
- `editor.empty` — the empty pane's hint (3b-i, .combine): "⌘P to open a file · ⌘T for a scratch tab", with no press action. Read, not pressed — 3b-i-editor-close-keys.jsonl asserts it after the last tab closes, and its absence after ⌘W closes the pane.
- `editor.monaco` — the Monaco host's container (3b-i): an NSViewRepresentable holding the WKWebView, with no press action of its own. Typing into it is driven by keys: 3b-i-editor-scratch-save.jsonl types after ⌘T and after a save, and asserts the text through read_pane.
- `editor.notice` — a Text (3b-i, Rule 8): a tab's notice, drawn whole. Read, not pressed — 3b-i-editor-read-only.jsonl asserts "ro.bin is a binary file" in the tree and through read_pane.
- `editor.replace.busy` — the replace tick (3b-ii-b, Rule 5): a shape with no press action, drawn while a replace or its undo is in flight (editor.search.busy's case). Read, not pressed — 3b-ii-b-replace-cancel.jsonl reads the tree for its label, "replacing", while the replace walks the 200 MiB haystack, then presses the Cancel beside it, editor.replace.cancel.
- `editor.replace.failure` — a Text (3b-ii-b, Rule 8): one file the replace or its undo could not write or put back, drawn whole. Read, not pressed — 3b-ii-b-replace-undo.jsonl asserts "changed since the replace — left as it is" in the tree for the file changed on disk after the replace.
- `editor.replace.result` — the replace's result line's container (.contain, 3b-ii-b): the summary Text, Undo replace (editor.replace.undo, pressed) and the failures under it. Read, not pressed — 3b-ii-b-replace-all.jsonl asserts "Replaced 3 in 3 files" in the tree and last_replace through read_pane; 3b-ii-b-replace-undo.jsonl asserts "Undid the replace in 2 files".
- `editor.saveAs.failure` — a Text (3b-i, Rule 8): the path field's failure, drawn whole. Read, not pressed — 3b-i-editor-save-as-field.jsonl asserts "is outside the active project's roots; editor reads and writes are confined to them (Invariant 6, Decision 36)" with the typed path still in the field.
- `editor.saveAs.replacePrompt` — the Save-As field's "Replace <name>?" line's container (.contain, 3b-i, Rule 1): its text and two buttons. Read, not pressed — 3b-i-editor-save-as-replace.jsonl asserts "Replace replace-me.txt?" and its absence after Cancel; its buttons editor.saveAs.replace / .replaceCancel are pressed there.
- `editor.saving` — the saving tick (3b-i, Rule 5): a 2 pt shape drawn only while a write is in flight, which against the fixture's tiny files lasts milliseconds — never long enough for a tree read to see. `saving` is asserted false after each save through read_pane; seeing the tick is the runbook's walk.
- `editor.saving.cancel` — the saving tick's Cancel (3b-i, Rule 4): a control that exists only while a write is in flight, which against the fixture lasts milliseconds — a press cannot land on it, and wakil-files writes through a temp file and a rename, so no fixture path can make a write wait. Cancelling a save is the runbook's walk.
- `editor.search.busy` — the search tick (3b-ii, Rule 5): a shape with no press action, drawn while a search is in flight. Read, not pressed — 3b-ii-search-cancel.jsonl reads the tree for its label, "searching", with no read_pane or other dispatch ending while the search runs (the regex switch is set on the empty query first, so typing starts the one search), so only the window's editor-flight redraw (final review C1) can draw it; it then presses the Cancel beside it, editor.search.cancel.
- `editor.search.cancelled` — the Search view's cancelled line's container (.contain, 3b-ii walk): the Text "search cancelled" and its Re-run, editor.search.rerunCancelled. Read, not pressed — 3b-ii-search-cancel.jsonl asserts "search cancelled" in the tree and search.cancelled through read_pane after Cancel, then presses Re-run and reads the search running again with cancelled cleared.
- `editor.search.error` — a Text (3b-ii, Rule 8): a search's error, drawn whole. Read, not pressed — 3b-ii-search-errors.jsonl asserts "missing closing )" in the tree and through read_pane, with the typed query kept.
- `editor.search.filesNote` — a Text (3b-ii): "only the first 50,000 files are searched", drawn only when a root's listing hit the cap. 50,000 files are not seeded (editor.tree.note:<…>'s reason); `files_truncated` is pinned by internal/wakilcore/files_test.go and WakilKitTests (EditorSearchActionsTests).
- `editor.search.noMatches` — a Text (3b-ii walk): "no matches", drawn under a finished search that found nothing. Display text with no press action. Read, not pressed — 3b-ii-search.jsonl asserts it in the tree after a search for a string no fixture file holds.
- `editor.search.note` — a Text (3b-ii): "only the first 2,000 matches are shown", drawn only over a search that hit the cap. 2,000 matches are not seeded; `truncated` is pinned by internal/wakilcore/files_test.go and WakilKitTests (EditorSearchActionsTests), and the note is the runbook's walk.
- `editor.strip` — not a control (3b-ii-b): the name of a SwiftUI coordinate space (`.coordinateSpace(name: "editor.strip")`, the visible tab strip's, where the middle-click converts a click), not an accessibility identifier — editor.tabs's case. Nothing in the accessibility tree carries it. The middle-click itself is walk-only: the harness posts no middle button (runbook row 8).
- `editor.tabs` — not a control (3b-ii-b): the name of a SwiftUI coordinate space (`.coordinateSpace(name: "editor.tabs")`, the tab strip's, which the drop target and the middle-click measure in), not an accessibility identifier. The harvest reads any `editor.…` literal; nothing in the accessibility tree carries this name, so no check can press or read it. The strip's tabs are editor.tab.<…>, dragged by 3b-ii-b-tab-move.jsonl.
- `editor.tree.error:<…>` — a Text (3b-ii, Rule 8): a root's or a heavy folder's listing error, drawn whole under its row. Every fixture root lists and vendor loads, and no step can make one unreadable mid-launch; display text with no press action either way. Pinned by WakilKitTests (EditorTreeTests), and an unreadable root is the runbook's walk.
- `editor.tree.loading` — the tree's load tick (3b-ii, Rule 5): a shape drawn only while a root lists or a heavy folder loads, which against the fixture's small roots lasts milliseconds — never long enough for a tree read to see. 3b-ii-tree-ignored-heavy.jsonl asserts what the load brings (autoload.php under vendor); seeing the tick is the runbook's walk.
- `editor.tree.name.error` — a Text (3b-iv, Rule 8): the tree's name field's refusal, drawn whole under it. Display text with no press action. Read, not pressed — 3b-iv-name-refused.jsonl asserts `/e2e-api/README.md already exists` in the tree, its frame inside editor.column, and its absence once the kept text, amended, commits.
- `editor.tree.note:<…>` — a Text (3b-ii): "only the first 50,000 files are listed", drawn only under a root whose listing hit the cap. The fixture's roots hold a few hundred files and seeding 50,000 per launch is not worth its minute; a note row is never selected or pressed. Its row is pinned by WakilKitTests (EditorTreeTests).
- `editor.tree.status:<…>` — a Text (3b-iii): a Files tree row's git status letter, `M` or `?`. Display text with no press action. Read, not pressed — 3b-iii-tree-letters.jsonl resolves it per row (app.txt, notes, BookingController.php, index.txt) and holds its frame inside its row and the column at the window's minimum; which letter and which tone is pinned by WakilKitTests (editorTreeStatus).
- `editor.unsaved` — the unsaved prompt's container (.contain, 3b-i): the message and three buttons. Read, not pressed — every prompt check asserts its message; its buttons editor.unsaved.save / .dontSave / .cancel are pressed by 3b-i-editor-close-keys.jsonl, 3b-i-editor-unsaved-save.jsonl and 3b-i-editor-unsaved-org-switch.jsonl.
- `editor.unsaved.message` — a Text (3b-i): the prompt's question. Read, not pressed — "Save changes to Untitled-2?" (3b-i-editor-close-keys.jsonl), "Save changes to kept.txt?" (3b-i-editor-unsaved-save.jsonl), "Unsaved changes in Untitled-1" (3b-i-editor-unsaved-org-switch.jsonl, 3b-i-editor-unsaved-quit.jsonl).
- `palette.error` — a Text (palette rework, rule 8): a run's error, drawn whole under the query line. Display text with no press action. Read, not pressed — palette-run-error.jsonl asserts "no entry in staging has that host" with the step and the typed line still there.
- `palette.plane` — the palette's container (.contain, palette rework): it holds the header, the query line, the rows and the footer, and takes no input itself — the dimmer around it takes the dismissing click. Its contents are read by every palette-*.jsonl check ("OPEN OR SWITCH TO", "RUN A COMMAND", the "N of M" count); the field inside it is palette.query, typed into, and its rows are palette.row.<id>, pressed.
- `palette.step` — a Text (palette rework): an input step's title, uppercased, where the mode's name was. Read, not pressed — palette-command-step.jsonl and palette-escape.jsonl assert "PANE KIND", palette-run-error.jsonl "CURL COMMAND", palette-switch-environment.jsonl "ENVIRONMENT", palette-table-row.jsonl a drill's "BOOKINGS"; palette-escape.jsonl asserts it gone after one Esc.
- `settings.capacity.strip` — the Settings capacity strip's scroll container (provider capacity), which takes no input. Its rows are read by capacity-low-reading.jsonl and capacity-passed-reset.jsonl, beside the accounts table's own CREDENTIAL and SIGN-IN headers.
- `settings.editor.autosave.refusal` — a Text (3b-v, Rule 8): drawn only when Go refuses an autosave mode the pane offers (off, pause, focus are each valid), which happens only over a settings.json that does not parse — no fixture or step can produce one (settings.editor.error's reason). Display text with no press action. 3b-v-editor-settings-nodes.jsonl drives all three modes and asserts each on disk.
- `settings.editor.error` — a Text (3b-v, Rule 8): settings.json's read or parse error, drawn only when ~/.wakil/settings.json cannot be read. The seed never writes that file, and no step can write it mid-launch — editor writes are confined to the active project's roots (Invariant 6, Decision 36) and ~/.wakil is outside them; display text with no press action either way. Its wording and the defaults it leaves in force are pinned by internal/wakilcore/editorsettings_test.go and WakilKitTests EditorSettingsTests; the runbook walks it with a hand-broken file.
- `settings.editor.showIgnored.refusal` — a Text (3b-v part 2, Rule 8): drawn only when Go refuses a Show ignored files write the pane itself offers (On or Off), and Go refuses a boolean only when settings.json does not parse — which, as for settings.editor.error, no fixture or step can produce. Display text with no press action. 3b-v-show-ignored.jsonl drives both choices and asserts each write.
- `settings.editor.wordWrap.refusal` — a Text (3b-v, Rule 8): drawn only when Go refuses a word-wrap write the pane itself offers (On or Off), and Go refuses a boolean only when settings.json does not parse — which, as for settings.editor.error, no fixture or step can produce. Display text with no press action. 3b-v-editor-settings-nodes.jsonl drives both choices and asserts each write on disk.
- `settings.login.cancel` — #254. Only exists while a browser trip is in flight.
- `settings.login.dismiss` — #254. Drawn only by the states a finished trip reaches — added, refused, cancelled, timedOut, uncertain, failed.
- `settings.login.someoneElse` — #254. Starts a fresh trip, and only appears when the config dir is already signed in, which itself needs a real credential.
- `settings.login.start` — #254. The control that does the above.
- `settings.mint.stopWaiting` — #254. Only exists while waiting on a live mint.
- `settings.org.speechProvider.note` — a Text: the Speech row's "unknown engine 'x', using Apple". Read, not pressed — 2d-ii-settings-speech.jsonl asserts it after a dispatched unknown id and a reload, and its absence after Apple is chosen.
- `settings.projectEditor.heavy.git` — the heavy-folder list's fixed .git row (3b-v part 2): a Text pair (".git", "always") with no press action — .git is always heavy and cannot be edited or removed. Read, not pressed — 3b-v-heavy-folders-edit.jsonl asserts its "always" beside the list.
- `settings.projectEditor.heavy.refusal` — a Text (3b-v part 2, Rule 8): a refused heavy folder's sentence, drawn whole under the list. Display text with no press action. Read, not pressed — 3b-v-heavy-folders-refusal.jsonl asserts the .git, a/b and duplicate sentences in the pane and refuses the same names by dispatch.
- `settings.projectEditor.indent.refusal` — a Text (3b-v, Rule 8): drawn only when Go refuses Spaces or Tabs, which it does only for a project.json filed under another organisation or unreadable — and either one drops the project from the settings tree, so its Editor node draws `gone` instead of this form and the refusal has nowhere to appear. Display text with no press action. 3b-v-project-editor-settings.jsonl drives both choices (Tabs through parity) and asserts each on disk.
- `settings.row.<…>.reauthenticate` — #254. Goes straight to the browser by design — no confirmation step — so pressing it IS starting a real trip.
- `window.capacity` — the capacity indicator beside ACCOUNT (provider capacity): it has no press action, and it refuses AXFocused (measured 2026-10-10: axresolve not_focusable), because `.focusable(interactions: .activate)` keeps a click from taking the composer's focus (Rule 6) and joins the key loop only with macOS Keyboard navigation on. Its card opens on hover or on that focus, and the vocabulary has no hover step, so opening the card is walk-only. What it draws is read by capacity-at-launch.jsonl (the launch probe, no turn), capacity-low-reading.jsonl, capacity-passed-reset.jsonl and agent/capacity-after-turn.jsonl.
- `window.composer.bar` — the composer bar's container (.contain), which holds the field, the heard text and the hint and takes no input itself. Its contents are read by every 2d-ii voice check; the field inside it is `window.composer`, which they type into.
- `window.composer.heard` — a Text: the words heard while ⌥ is held, or the notice that replaces them. Read, not pressed — 2d-ii-voice-silence.jsonl asserts "Hearing nothing from E2E Microphone" and the words that clear it; 2d-ii-voice-lands-unsent.jsonl and 2d-ii-voice-escape.jsonl assert the words mid-hold.
- `window.composer.hint` — a Text: the bar's hint. Read, not pressed — the keys hint ("TO SPEAK"), the listening hint ("RELEASE TO PUT IT IN THE LINE") and the landed hint ("HEARD · RETURN SENDS · EDIT FIRST") are asserted by the 2d-ii voice checks.
- `window.thread` — the thought thread's container (.contain), which takes hits only on its rows and the "earlier" line. Its rows are pressed by 2d-ii-thread-earlier.jsonl as window.thread.row.<id> and window.thread.earlier.

**This section knows nothing about what a machine cannot see.** The visual rulings and the live-provider question stay the operator's, permanently; they are the human section below.

<!-- /machine-walk -->
