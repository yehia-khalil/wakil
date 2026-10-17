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

## 4. The machine walk

Rendered by `make e2e-runbook` after the Cover rung. Nothing is written here by hand.

<!-- machine-walk: generated by `make e2e-runbook`; everything between these markers is overwritten -->
<!-- /machine-walk -->
