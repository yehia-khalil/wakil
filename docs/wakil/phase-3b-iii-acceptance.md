# 3b-iii — the Changes view, diff tabs, gutter marks and the peek: acceptance

**Spec:** [`2026-10-15-3b-iii-changes-view-design.md`](../superpowers/specs/2026-10-15-3b-iii-changes-view-design.md) ·
**Plan:** [`2026-10-16-3b-iii-changes-view.md`](../superpowers/plans/2026-10-16-3b-iii-changes-view.md)

**Not yet walked.**

The exit criterion, from the spec: see what changed without leaving the editor — the Git pane's
Changes in the editor's left column, each changed file a read-only diff tab, marks in the gutter of
a tracked file and a peek that reverts a change as an undoable buffer edit — all of it drivable by
the agent.

The decisions behind it are Decision 40 (the Git pane is the editor's Changes view; gutter marks and
the peek ship with it; nothing writes to git) and design-language §11's Git row (now the Changes
view), its Editor row (marks, peek and tree letters) and its left-column list. The rulings made while
planning (R1–R14) and the build (B1–B6) are the spec's 2026-10-16 amendment.

## 0. Setup

A project's roots are the `"roots"` array of its `project.json`, read at launch and on a project
switch, not live. Run this in the repo root, on this Mac, after `make build` and `make app-bundle`.
It is safe to re-run. Set `ORG` to one you have registered (`./bin/wakil org list`).

```bash
set -e
ORG=initech   # the org to walk under; initech or umbrella
cd /Users/operator/Desktop/scripts/wakil
rm -rf /tmp/walk-changes /tmp/walk-changes-project
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
G="git -c user.name=walk -c user.email=walk@example.com"
mkdir -p /tmp/walk-changes/api /tmp/walk-changes/portal /tmp/walk-changes/docs /tmp/walk-changes-project
cd /tmp/walk-changes/api && git init -q -b main
printf '.env\n' > .gitignore; echo 'token=walk' > .env
mkdir -p app/Models app/Http
echo 'class User {}' > app/Models/User.php
for i in $(seq 1 20); do echo "// line $i"; done > app/Http/BookingController.php
echo 'old name body' > app/Models/Legacy.php
echo 'gone soon' > app/Models/Obsolete.php
$G add . && $G commit -qm init
# a staged-and-changed file: one hunk staged, a second left in the working tree
sed -i.bak 's#^// line 3$#// line 3 staged#' app/Http/BookingController.php && rm app/Http/BookingController.php.bak
git add app/Http/BookingController.php
sed -i.bak 's#^// line 15$#// line 15 changed#' app/Http/BookingController.php && rm app/Http/BookingController.php.bak
echo 'fresh' > app/Models/Notes.php                 # untracked
rm app/Models/Obsolete.php                          # deleted in the working tree
git mv app/Models/Legacy.php app/Models/Modern.php  # a rename, staged
cd /tmp/walk-changes/portal && git init -q -b main
mkdir -p src && echo 'const a = 1;' > src/routes.ts
git add . && $G commit -qm init
echo 'const a = 2;' > src/routes.ts
echo 'plain notes, no repository' > /tmp/walk-changes/docs/README.txt
cat > /tmp/walk-changes-project/project.json <<J
{"name":"walk-changes","org":"$ORG","roots":[{"path":"/tmp/walk-changes/api"},{"path":"/tmp/walk-changes/portal"},{"path":"/tmp/walk-changes/docs"}],"scopes":{},"environments":{}}
J
cd /Users/operator/Desktop/scripts/wakil
./bin/wakil project rm walk-changes --org "$ORG" || true
./bin/wakil project add walk-changes --path /tmp/walk-changes-project/project.json --org "$ORG"
```

`api` holds `BookingController.php` staged and changed (two lines, one in each group), `Notes.php`
untracked, `Obsolete.php` deleted, and `Legacy.php` renamed to `Modern.php`; `.env` is gitignored.
`portal` holds one change, `src/routes.ts`. `docs` is not a repository.

Launch `WAKIL_ORG=initech app/Wakil.app/Contents/MacOS/Wakil` (or `umbrella`), then make the project
active with the project switcher (⌘P, choose `walk-changes`). Registering does not select it.

## 1. The walk

Walk in order, on the project `walk-changes` from §0, in an organisation where the agent answers.

| # | Do | Expect |
|---|---|---|
| 1 | Launch onto a layout saved with a Git pane. To make one: with `walk-changes` active, open an editor pane, quit, then run `f=$(ls -t ~/.wakil/layouts/initech/conversations/*.json ~/.wakil/layouts/initech/walk-changes.json 2>/dev/null \| head -1); cp "$f" "$f.bak"; jq '.panes \|= map(if .kind=="editor" then .kind="git" \| .id="git-1" \| .title="Git" \| del(.editorColumn) else . end)' "$f.bak" > "$f"`, and relaunch | The pane is the editor, in the same place, its column on Changes |
| 2 | ⌘⇧G three times from an editor on Files | Changes, then hidden, then Changes again; the keyboard is in the list each time it shows |
| 3 | Look at the Changes view | Headers `api · main · …`, `docs · not a git repository`; letters green / amber / muted, **no red**; a rename reads `old → new` |
| 4 | In a terminal pane, `git -C /tmp/walk-changes/portal add src/routes.ts`, then `git -C /tmp/walk-changes/portal -c user.name=walk -c user.email=walk@example.com commit -qm walk` | The row moves to Staged within about half a second, then leaves; the highlight moves to its neighbour, not the top |
| 5 | Click a row, then another; double-click a third | One preview tab replaced, then a pinned tab beside it; additions green, deletions muted, inline |
| 6 | In a diff tab, put the cursor on a line and press ⌘⏎ | The file opens as a tab at that line, the diff tab still open; on a scratch tab ⌘⏎ maximizes as before |
| 7 | Type in a tracked file | An amber bar beside the changed line within a moment; a deleted line leaves a muted triangle between two lines |
| 8 | Click a mark; press ↓, then Revert, then ⌘Z | The peek reads `1 of N changes · ↑ ↓ · Revert · ×`; Revert undoes that change in the buffer (tab dirty, file untouched); ⌘Z brings it back |
| 9 | Esc in the peek; then type | The peek closes and the cursor stays; typing with the peek open closes it, the marks stay |
| 10 | The Files tree | `M` beside the changed file, `?` beside the untracked one, folders untinted, ignored files still dimmed |

## 2. Residue — what the walk cannot establish

- **Nothing writes to git** (Decision 40): stage, unstage, commit and discard stay 3a-ii's; row 4
  uses a terminal for them.
- **Files past 10,000 lines show no marks and no peek** (B1); no fixture here is that long.
- **A saved layout from before PR 1** cannot be read by a build older than it (R1); the walk starts
  from a layout this build can read.
- **Diff tabs are not saved** (R7): after a relaunch a migrated pane has none open.

## 3. Cover — what 3b-iii hands the e2e auditor

**For the e2e auditor (`docs/agents/e2e.md`)** — what 3b-iii touched, for checks to cover:
- Rewrite 3a-i's six deleted checks as `3b-iii-changes-{list,drill,keys,live,press,voice-hint}` against
  the editor: the Changes rows and headers (`editor.changes.root:<…>`, `editor.changes.row:<…>/<…>:<…>`,
  `editor.changes.rootError:<…>`), collapse, ↑↓ and Return, live updates from a terminal, the voice
  hint for `BookingController.php`.
- New: ⌘⇧G's toggle; a diff tab's preview rule, its title, *No longer changed*, the banner
  (`editor.diff.loading`, `.error`, `.banner`, `.gone`); ⌘⏎ opening the file (and maximizing on a
  scratch tab); the tree's status letters; the peek (open from a mark, ↑↓, Revert dirty and ⌘Z, Esc);
  a saved Git pane migrating (seed a layout file with a `git` pane).
- `uncoverable.tsv` rows for any action no control dispatches by click: likely `editor_peek_step`
  (keys), `editor_changes_step` (keys), `editor_open_file` (a key), each on `git_step`'s precedent.

Left over from the build, for the same rung:
- `e2e/checks/uncoverable.tsv`: two surviving rows (`capacity_record` and `editor_goto`) cite the
  deleted `git_fold` precedent, and `editor_new_scratch` cites the deleted `git_step`. Restate their
  reasoning directly, so nothing rests on a deleted row.
- `e2e/driver/identifiers.go`: its `git` namespace notes (`git.row:…`, `git.mark:…`) describe deleted
  Git pane rows. `EditorColumn.swift`, where the Changes view lives, is not in `AuditedSources`.
- The proof for `palette-open-kinds.jsonl` is stale after its edit and needs re-proving.
- No test pins that choosing a ⌘P changed file on a fresh session enters the conversation
  (`paletteOpensAPane` gained `editor_changes_select`).

## 4. The machine walk

Rendered by `make e2e-runbook` after the Cover rung. Nothing is written here by hand.

<!-- machine-walk: generated by `make e2e-runbook`; everything between these markers is overwritten -->
<!-- /machine-walk -->
