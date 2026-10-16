# 3b-iii — the Changes view, diff tabs, gutter marks and the peek: acceptance

**Spec:** [`2026-10-15-3b-iii-changes-view-design.md`](../superpowers/specs/2026-10-15-3b-iii-changes-view-design.md) ·
**Plan:** [`2026-10-16-3b-iii-changes-view.md`](../superpowers/plans/2026-10-16-3b-iii-changes-view.md)

**Walked by the operator 2026-10-16 — all ten steps pass**, under the `personal` organisation
(this Mac has no initech or umbrella), on the 3b-iii worktree build with the two fixes the walk found (`phase-log.md`, 2026-10-16).

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
It is safe to re-run, and safe to paste into an interactive shell: it runs in a subshell, so `set -e`
and the git config it exports do not stay. Set `ORG` to one you have registered
(`./bin/wakil org list`). The path is the main checkout; a worktree's path works the same way.

```bash
(
set -e
ORG=initech   # the org to walk under; initech or umbrella
cd ~/Desktop/scripts/wakil-public
rm -rf /tmp/walk-changes /tmp/walk-changes-project
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
g() { git -c user.name=walk -c user.email=walk@example.com "$@"; }
mkdir -p /tmp/walk-changes/api /tmp/walk-changes/portal /tmp/walk-changes/docs /tmp/walk-changes-project
cd /tmp/walk-changes/api && git init -q -b main
printf '.env\n' > .gitignore; echo 'token=walk' > .env
mkdir -p app/Models app/Http
echo 'class User {}' > app/Models/User.php
for i in $(seq 1 20); do echo "// line $i"; done > app/Http/BookingController.php
echo 'old name body' > app/Models/Legacy.php
echo 'gone soon' > app/Models/Obsolete.php
git add . && g commit -qm init
# a staged-and-changed file: one hunk staged, a second left in the working tree
sed -i.bak 's#^// line 3$#// line 3 staged#' app/Http/BookingController.php && rm app/Http/BookingController.php.bak
git add app/Http/BookingController.php
sed -i.bak 's#^// line 15$#// line 15 changed#' app/Http/BookingController.php && rm app/Http/BookingController.php.bak
echo 'fresh' > app/Models/Notes.php                 # untracked
rm app/Models/Obsolete.php                          # deleted in the working tree
git mv app/Models/Legacy.php app/Models/Modern.php  # a rename, staged
cd /tmp/walk-changes/portal && git init -q -b main
mkdir -p src && echo 'const a = 1;' > src/routes.ts
git add . && g commit -qm init
echo 'const a = 2;' > src/routes.ts
echo 'plain notes, no repository' > /tmp/walk-changes/docs/README.txt
cat > /tmp/walk-changes-project/project.json <<J
{"name":"walk-changes","org":"$ORG","roots":[{"path":"/tmp/walk-changes/api"},{"path":"/tmp/walk-changes/portal"},{"path":"/tmp/walk-changes/docs"}],"scopes":{},"environments":{}}
J
cd ~/Desktop/scripts/wakil-public
./bin/wakil project rm walk-changes --org "$ORG" || true
./bin/wakil project add walk-changes --path /tmp/walk-changes-project/project.json --org "$ORG"
)
```

`api` holds `BookingController.php` staged and changed (two lines, one in each group), `Notes.php`
untracked, `Obsolete.php` deleted, and `Legacy.php` renamed to `Modern.php`; `.env` is gitignored.
`portal` holds one change, `src/routes.ts`. `docs` is not a repository.

Launch it with `cd ~/Desktop/scripts/wakil-public && ORG=initech && WAKIL_ORG=$ORG app/Wakil.app/Contents/MacOS/Wakil` (`ORG=umbrella` for the other), then make the project
active with the project switcher (⌘P, choose `walk-changes`). Registering does not select it.

## 1. The walk

Walk in order, on the project `walk-changes` from §0, in an organisation where the agent answers.

| # | Do | Expect | Walked |
|---|---|---|---|
| 1 | Launch onto a layout saved with a Git pane. To make one: with `walk-changes` active, open an editor pane, then quit (the project's seed file exists only once its arrangement has been saved). Run `ORG=initech; f=~/.wakil/layouts/$ORG/walk-changes.json; cp "$f" "$f.bak"; jq '.panes \|= map(if .kind=="editor" then .kind="git" \| .title="Git" \| del(.editorTabs, .editorColumn) else . end)' "$f.bak" > "$f"` (or `ORG=umbrella`; the pane keeps its id, as the migration does, so no snap-graph edge loses its pane), then relaunch and make `walk-changes` active | The pane is the editor, in the same place, its column on Changes | ☑ 2026-10-16 |
| 2 | ⌘⇧G three times from an editor on Files | Changes, then hidden, then Changes again; the keyboard is in the list each time it shows | ☑ 2026-10-16 |
| 3 | Look at the Changes view | Headers `api · main · …`, `docs · not a git repository`; letters green / amber / muted, **no red**; a rename reads `old → new` | ☑ 2026-10-16 |
| 4 | Click the `src/routes.ts` row under `portal`. In a terminal pane, `git -C /tmp/walk-changes/portal add src/routes.ts`, then `git -C /tmp/walk-changes/portal -c user.name=walk -c user.email=walk@example.com commit -qm walk` | The row moves to Staged within about half a second, then leaves; the highlight moves to its neighbour, not the top | ☑ 2026-10-16 |
| 5 | Click a row, then another; double-click a third | One preview tab replaced, then a pinned tab beside it; additions green, deletions muted, inline | ☑ 2026-10-16 |
| 6 | In a diff tab, put the cursor on a line and press ⌘⏎ | The file opens as a tab at that line, the diff tab still open; on a scratch tab ⌘⏎ maximizes as before | ☑ 2026-10-16 |
| 7 | Type in a tracked file | An amber bar beside the changed line within a moment; a deleted line leaves a muted triangle between two lines | ☑ 2026-10-16 |
| 8 | Click a mark; press ↓, then Revert, then ⌘Z | The peek reads `1 of N changes · ↑ ↓ · Revert · ×`; Revert undoes that change in the buffer (tab dirty, file untouched); ⌘Z brings it back | ☑ 2026-10-16 |
| 9 | Esc in the peek; then type | The peek closes and the cursor stays; typing with the peek open closes it, the marks stay | ☑ 2026-10-16 |
| 10 | The Files tree | `M` beside the changed file, `?` beside the untracked one, folders untinted, ignored files still dimmed | ☑ 2026-10-16 |

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

### Residue — what the Cover rung's checks do not cover

The e2e auditor's report (`docs/agents/e2e.md`, The residue report), one line per item.

- **Not proven yet** — every 3b-iii check below is written and unproven: `make e2e-new` and `make e2e`
  were refused at launch while a hand-opened Wakil from another worktree was running (#332's guard).
  The machine walk in §4 says so until both run.
- `editor_peek`, `editor_peek_step`, `editor_peek_close` — no parity. The mark, the peek's ↑ ↓,
  Revert and × are HTML inside Monaco's web view, with no accessibility identifier the resolver can
  address. The dispatches and the keys (↑↓, Esc, typing) are checked; clicking them is rows 8–9.
- **Revert by its button** — walk-only (row 8), for the reason above. The edit it dispatches
  (`editor_replace_range` with `expect`) and ⌘Z after it are checked.
- `editor_changes_step`, `editor_open_file` — no parity: their operator channels are keys (↑↓, ⌘⏎),
  and a parity step's UI half is a click or a drag. Both channels are checked separately.
- **Double-click pins a diff tab** — walk-only (row 5): the harness has no double-click; `pin: true`
  is checked by dispatch.
- **Tones** — green additions, muted deletions, amber marks, no red, folders untinted, ignored files
  dimmed: visual, the operator's (rows 3, 5, 7, 10).
- **Speed** — "within about half a second" (row 4) and "within a moment" (row 7): no step kind
  measures time; the checks only wait for the state.
- **A deleted line's triangle between two lines** (row 7) — visual; the `deleted` hunk is in no
  check because no fixture step deletes a tracked line, and its kind is pinned by WakilKitTests.
- **An unchanged file shows no letter** (row 10) — no step can assert a frame is absent;
  `editorTreeStatus` pins it in WakilKitTests.
- `editor.changes.rootError:<…>` — never drawn: the fixture's one root error is one line.
- `editor.diff.error` — never drawn: no fixture file makes `git_show` fail mid-launch.
- `editor.diff.loading`, `editor.changes.loading` — drawn for milliseconds; no tree read sees them.
- **⌘⏎ on a diff tab does not also maximize** — the journal step can only say what happened, not
  what did not; the check asserts the file tab opened.

## 4. The machine walk

Rendered by `make e2e-runbook` after the Cover rung. Nothing is written here by hand.

<!-- machine-walk: generated by `make e2e-runbook`; everything between these markers is overwritten -->

**The machine walk is red** — 71 condition(s) of the Cover rung are not met:

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
e2e/checks/seeded/3b-ii-b-replace-cancel.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-ii-palette-ignored.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-ii-refusals.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-ii-search-cancel.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-ii-search-errors.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-ii-tree-ignored-heavy.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-v-click-focuses-pane.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-v-editor-indent-scratch.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-v-editor-settings-nodes.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-v-heavy-folders-edit.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-v-heavy-folders-refusal.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-v-project-editor-settings.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/agent-pane-is-drawn.jsonl was never run against this build, so nothing is known about it — run `make e2e`
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
e2e/checks/seeded/landing.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/palette-api-entry.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/palette-command-step.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/palette-escape.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/palette-modes.jsonl was never run against this build, so nothing is known about it — run `make e2e`
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
e2e/checks/agent/both-surfaces.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/agent/capacity-after-turn.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/agent/two-enter.jsonl was never run against this build, so nothing is known about it — run `make e2e`
```

Walked by `make e2e` against 85a162bb5fb0, rendered 2026-10-16 19:38 UTC by `make e2e-runbook`. Re-render it with that target; edits between the markers are overwritten.

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
| `3b-i-editor-close-keys.jsonl` | ✓ exit 0 | ✓ red vs 0c9e85c6f259, recorded 2026-10-12 | 25 | — |
| `3b-i-editor-disk-changed.jsonl` | ✓ exit 0 | ✓ red vs 0c9e85c6f259, recorded 2026-10-12 | 34 | — |
| `3b-i-editor-files-palette.jsonl` | ✓ exit 0 | ✓ red vs 0c9e85c6f259, recorded 2026-10-12 | 13 | — |
| `3b-i-editor-read-only.jsonl` | ✓ exit 0 | ✓ red vs 0c9e85c6f259, recorded 2026-10-12 | 10 | — |
| `3b-i-editor-refusals.jsonl` | ✓ exit 0 | ✓ red vs 0c9e85c6f259, recorded 2026-10-12 | 24 | — |
| `3b-i-editor-save-as-field.jsonl` | ✓ exit 0 | ✓ red vs 0c9e85c6f259, recorded 2026-10-12 | 24 | — |
| `3b-i-editor-save-as-replace.jsonl` | ✓ exit 0 | ✓ red vs 0c9e85c6f259, recorded 2026-10-12 | 16 | — |
| `3b-i-editor-scratch-save.jsonl` | ✓ exit 0 | ✓ red vs 0c9e85c6f259, recorded 2026-10-12 | 27 | — |
| `3b-i-editor-tabs-language.jsonl` | ✓ exit 0 | ✓ red vs 0c9e85c6f259, recorded 2026-10-12 | 22 | — |
| `3b-i-editor-unsaved-org-switch.jsonl` | ✓ exit 0 | ✓ red vs 0c9e85c6f259, recorded 2026-10-12 | 10 | — |
| `3b-i-editor-unsaved-quit.jsonl` | ✓ exit 0 | ✓ red vs 0c9e85c6f259, recorded 2026-10-12 | 11 | — |
| `3b-i-editor-unsaved-save.jsonl` | ✓ exit 0 | ✓ red vs 0c9e85c6f259, recorded 2026-10-12 | 16 | — |
| `3b-ii-b-replace-all.jsonl` | ✓ exit 0 | ✓ red vs 5c38f72852bf, recorded 2026-10-14 | 22 | — |
| `3b-ii-b-replace-cancel.jsonl` | **never run** | — | — | — |
| `3b-ii-b-replace-file.jsonl` | ✓ exit 0 | ✓ red vs 5c38f72852bf, recorded 2026-10-14 | 17 | — |
| `3b-ii-b-replace-undo.jsonl` | ✓ exit 0 | ✓ red vs 5c38f72852bf, recorded 2026-10-14 | 18 | — |
| `3b-ii-b-reveal.jsonl` | ✓ exit 0 | ✓ red vs 5c38f72852bf, recorded 2026-10-14 | 11 | — |
| `3b-ii-b-tab-move.jsonl` | ✓ exit 0 | ✓ red vs 5c38f72852bf, recorded 2026-10-14 | 9 | — |
| `3b-ii-find.jsonl` | ✓ exit 0 | ✓ red vs 8e8ec7d29e7f, recorded 2026-10-14 | 8 | — |
| `3b-ii-palette-ignored.jsonl` | **never run** | — | — | — |
| `3b-ii-refusals.jsonl` | **never run** | — | — | — |
| `3b-ii-search-cancel.jsonl` | **never run** | — | — | — |
| `3b-ii-search-errors.jsonl` | **never run** | — | — | — |
| `3b-ii-search.jsonl` | ✓ exit 0 | **proved red vs 8e8ec7d29e7f on an earlier version — not re-proved** | 43 | — |
| `3b-ii-tree-ignored-heavy.jsonl` | **never run** | — | — | — |
| `3b-ii-tree-live.jsonl` | ✓ exit 0 | ✓ red vs 8e8ec7d29e7f, recorded 2026-10-14 | 11 | — |
| `3b-ii-tree-preview.jsonl` | ✓ exit 0 | ✓ red vs 8e8ec7d29e7f, recorded 2026-10-14 | 19 | — |
| `3b-ii-tree-toggle.jsonl` | ✓ exit 0 | ✓ red vs 8e8ec7d29e7f, recorded 2026-10-14 | 14 | — |
| `3b-iii-changes-drill.jsonl` | ✓ exit 0 | ✓ red vs 2dfec0ee0c10 | 57 | — |
| `3b-iii-changes-keys.jsonl` | ✓ exit 0 | ✓ red vs 2dfec0ee0c10 | 34 | — |
| `3b-iii-changes-list.jsonl` | ✓ exit 0 | ✓ red vs 2dfec0ee0c10 | 30 | — |
| `3b-iii-changes-live.jsonl` | ✓ exit 0 | ✓ red vs 2dfec0ee0c10 | 39 | — |
| `3b-iii-changes-press.jsonl` | ✓ exit 0 | ✓ red vs 2dfec0ee0c10 | 22 | — |
| `3b-iii-diff-open-file.jsonl` | ✓ exit 0 | ✓ red vs 2dfec0ee0c10 | 22 | — |
| `3b-iii-diff-refusals.jsonl` | ✓ exit 0 | ✓ red vs 2dfec0ee0c10 | 18 | — |
| `3b-iii-git-pane-migrates.jsonl` | ✓ exit 0 | ✓ red vs 2dfec0ee0c10 | 13 | — |
| `3b-iii-palette-changed-file.jsonl` | ✓ exit 0 | ✓ red vs 2dfec0ee0c10 | 13 | — |
| `3b-iii-peek.jsonl` | ✓ exit 0 | ✓ red vs 2dfec0ee0c10 | 41 | — |
| `3b-iii-tree-letters.jsonl` | ✓ exit 0 | ✓ red vs 2dfec0ee0c10 | 12 | — |
| `3b-v-click-focuses-pane.jsonl` | **never run** | — | — | — |
| `3b-v-editor-autosave-focus.jsonl` | ✓ exit 0 | ✓ red vs e6c782b4f52f, recorded 2026-10-13 | 22 | — |
| `3b-v-editor-autosave-pause.jsonl` | ✓ exit 0 | ✓ red vs e6c782b4f52f, recorded 2026-10-13 | 23 | — |
| `3b-v-editor-autosave-prompt-guard.jsonl` | ✓ exit 0 | ✓ red vs e6c782b4f52f, recorded 2026-10-13 | 18 | — |
| `3b-v-editor-indent-scratch.jsonl` | **never run** | — | — | — |
| `3b-v-editor-live-options.jsonl` | ✓ exit 0 | ✓ red vs e6c782b4f52f, recorded 2026-10-13 | 21 | — |
| `3b-v-editor-settings-nodes.jsonl` | **never run** | — | — | — |
| `3b-v-heavy-folders-edit.jsonl` | **never run** | — | — | — |
| `3b-v-heavy-folders-refusal.jsonl` | **never run** | — | — | — |
| `3b-v-heavy-folders.jsonl` | ✓ exit 0 | **proved red vs 5c38f72852bf on an earlier version — not re-proved** | 38 | — |
| `3b-v-project-editor-settings.jsonl` | **never run** | — | — | — |
| `3b-v-show-ignored.jsonl` | ✓ exit 0 | ✓ red vs 5c38f72852bf, recorded 2026-10-15 | 24 | — |
| `agent-pane-is-drawn.jsonl` | **never run** | — | — | — |
| `api-bind.jsonl` | ✓ exit 0 | not new on this branch | 9 | — |
| `api-body-editor.jsonl` | ✓ exit 0 | not new on this branch | 13 | — |
| `api-body-hole-cursor.jsonl` | ✓ exit 0 | not new on this branch | 3 | — |
| `api-bound-locks.jsonl` | ✓ exit 0 | not new on this branch | 16 | — |
| `api-cancel.jsonl` | ✓ exit 0 | not new on this branch | 15 | — |
| `api-chip-keys-second-chip.jsonl` | ✓ exit 0 | not new on this branch | 11 | — |
| `api-chip-keys-text-after.jsonl` | ✓ exit 0 | not new on this branch | 8 | — |
| `api-chip-keys.jsonl` | ✓ exit 0 | not new on this branch | 9 | — |
| `api-editor-copy-bound.jsonl` | ✓ exit 0 | not new on this branch | 7 | — |
| `api-editor-json-holes.jsonl` | ✓ exit 0 | not new on this branch | 8 | — |
| `api-editor-wrap.jsonl` | ✓ exit 0 | not new on this branch | 7 | — |
| `api-env-roundtrip.jsonl` | ✓ exit 0 | not new on this branch | 11 | — |
| `api-hole.jsonl` | ✓ exit 0 | not new on this branch | 12 | — |
| `api-one-author-focus.jsonl` | ✓ exit 0 | not new on this branch | 7 | — |
| `api-open.jsonl` | ✓ exit 0 | not new on this branch | 20 | — |
| `api-paste-curl-hotkey.jsonl` | ✓ exit 0 | not new on this branch | 7 | — |
| `api-paste-curl-refused.jsonl` | ✓ exit 0 | not new on this branch | 4 | — |
| `api-paste-curl-www.jsonl` | ✓ exit 0 | ✓ red vs 20a5384ca1f7, recorded 2026-10-15 | 4 | — |
| `api-paste-curl.jsonl` | ✓ exit 0 | not new on this branch | 20 | — |
| `api-query-sync.jsonl` | ✓ exit 0 | not new on this branch | 15 | — |
| `api-recent-root.jsonl` | ✓ exit 0 | ✓ red vs e51e847b8e5e, recorded 2026-10-15 | 2 | — |
| `api-recent-shared.jsonl` | ✓ exit 0 | not new on this branch | 8 | — |
| `api-recent.jsonl` | ✓ exit 0 | not new on this branch | 9 | — |
| `api-reopen-cross-entry.jsonl` | ✓ exit 0 | not new on this branch | 8 | — |
| `api-rows.jsonl` | ✓ exit 0 | not new on this branch | 30 | — |
| `api-saved-as-typed.jsonl` | ✓ exit 0 | not new on this branch | 6 | — |
| `api-send-what-it-shows.jsonl` | ✓ exit 0 | not new on this branch | 8 | — |
| `api-send.jsonl` | ✓ exit 0 | not new on this branch | 8 | — |
| `api-set-request.jsonl` | ✓ exit 0 | not new on this branch | 25 | — |
| `api-surface.jsonl` | ✓ exit 0 | not new on this branch | 20 | — |
| `api-the-rest.jsonl` | ✓ exit 0 | not new on this branch | 8 | — |
| `api-type-keeps-holes.jsonl` | ✓ exit 0 | ✓ red vs 9ecb83800726, recorded 2026-10-08 | 5 | — |
| `api-unbind.jsonl` | ✓ exit 0 | not new on this branch | 7 | — |
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
| `journal-error-reason.jsonl` | ✓ exit 0 | ✓ red vs dfb508b06420, recorded 2026-10-08 | 2 | — |
| `landing.jsonl` | **never run** | — | — | — |
| `palette-api-entry.jsonl` | **never run** | — | — | — |
| `palette-api-send.jsonl` | ✓ exit 0 | ✓ red vs f25a762e5ee7, recorded 2026-10-10 | 10 | — |
| `palette-command-step.jsonl` | **never run** | — | — | — |
| `palette-escape.jsonl` | **never run** | — | — | — |
| `palette-modes.jsonl` | **never run** | — | — | — |
| `palette-open-kinds.jsonl` | ✓ exit 0 | ✓ red vs 2dfec0ee0c10 | 15 | — |
| `palette-run-error.jsonl` | ✓ exit 0 | ✓ red vs f25a762e5ee7, recorded 2026-10-10 | 13 | — |
| `palette-switch-environment.jsonl` | ✓ exit 0 | ✓ red vs f25a762e5ee7, recorded 2026-10-10 | 17 | — |
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
| `3b-iii-changes-voice-hint.jsonl` | ✓ exit 0 | not new on this branch | 5 | — |
| `api-origin-after-account-switch.jsonl` | ✓ exit 0 | ✓ red vs 9e657511c804, recorded 2026-10-15 | 3 | — |
| `both-surfaces.jsonl` | **never run** | — | — | — |
| `capacity-after-turn.jsonl` | **never run** | — | — | — |
| `two-enter.jsonl` | **never run** | — | — | — |

**`make e2e-new` saw every check this branch added go red against 2dfec0ee0c10.**

**the actions were observed from a tree carrying uncommitted changes, so they describe that tree rather than the commit**

**Every action and control this branch added carries a check.** 8 action(s) and 10 control(s) are new on this branch.

- actions:  65 of 104 dispatched by a check
- writes:   20 of 75 carry a parity check
- controls: 120 of 210 exercised by a check

**91 piece(s) of surface no check can reach**, each with the reason given in `e2e/checks/uncoverable.tsv`:

- `editor_peek_step` — its parity (3b-iii): the operator's channels are ↑↓ while the peek is open (keys Monaco hands back) and the peek's ↑ ↓ buttons, which are HTML inside the WKWebView with no accessibility identifier — neither is a click on a control the resolver can address. Both the dispatch and ↑↓ ARE covered by 3b-iii-peek.jsonl, each asserting peek.index and the cursor through read_pane; the buttons are walk-only (row 8 presses ↓, a key).
- `editor_replace` — its parity (3b-ii-b): the click replaces, and the same dispatch after it finds nothing left to replace and answers a different last_replace, so the two halves cannot read back the same pane (api_cancel's case: the click consumes its own subject). Both channels ARE covered: the click (Replace All) by 3b-ii-b-replace-all.jsonl and the dispatch by 3b-ii-b-replace-undo.jsonl, each asserting last_replace's files and the Replaced … line; Replace in this file by 3b-ii-b-replace-file.jsonl, and Cancel by 3b-ii-b-replace-cancel.jsonl.
- `editor_changes_step` — its parity (3b-iii): the operator's channel is ↑↓ in the Changes view — keys, not a click or a drag — and the UI half of a parity step is a click or a drag only (api_fill_from_curl's case). Both channels ARE covered: the dispatch by 3b-iii-changes-drill.jsonl (across roots, both directions, clamped at the end, skipping a collapsed root, asserting the highlight and the diff tab through read_pane), the keys by 3b-iii-changes-keys.jsonl (↓ from nothing, ↑↓ across roots, after ⌘⇧G); what no check can express is the comparison.
- `api_undo_fill` — its parity: the Undo click forgets the fill it undoes, and api_undo_fill refuses a pane with nothing to undo, so the dispatch half cannot be given the same state after the click — and a second fill between the halves is not expressible inside one parity step. Both channels ARE covered by api-paste-curl.jsonl, the click after one fill and the dispatch after another, each asserting the same restored draft through read_pane; what no check can express is the comparison.
- `ctx_unlink_provider` — its parity: the click removes the binding, so the dispatch half cannot be given the same id. Dispatch and both channels' behaviour ARE covered by 2e-settings-unlink.jsonl; what no check can express is the comparison.
- `api_cancel` — its parity: the click cancels the send in flight, and api_cancel refuses a pane with nothing in flight (`nothingInFlight`), so the dispatch half cannot be given the same state — and a second Send between the halves is not expressible. Both channels ARE covered by api-cancel.jsonl, each after its own Send, asserting the same cancelled response through read_pane; what no check can express is the comparison.
- `editor_replace_undo` — its parity (3b-ii-b): the Undo click spends the pane's one undo, and the dispatch after it is then refused (`no replace to undo`) — api_undo_fill's case. The click is 3b-ii-b-replace-undo.jsonl's (undone, restored 2, and the changed-since line for the file changed on disk), and so is the refusal of the dispatch after it.
- `db_cancel` — its parity: the click (or Esc) cancels the read in flight, and db_cancel refuses a pane with nothing running (`nothing is running on pane …`), so the dispatch half cannot be given the same state — and a second slow read between the halves is not expressible inside one parity step, api_cancel's case. Both channels ARE covered: db-cancel-click.jsonl cancels one recursive-CTE read by db.<pane>.cancel and the next by dispatch, asserting the same state after each through read_pane (running false, cancelledAfterMs, the previous 2 rows kept, sort empty) and "cancelled after" in the tree; db-cancel-escape.jsonl cancels by Esc. What no check can express is the comparison.
- `editor_peek_close` — its parity (3b-iii): the operator's channels are Esc in the peek (a key), typing (which closes it in the store), and the peek's × (HTML inside the WKWebView, no accessibility identifier). Esc, typing and the dispatch ARE each covered by 3b-iii-peek.jsonl, asserting peek null with the cursor and the marks kept; the × button is walk-only, in no runbook row.
- `capacity_record` — its parity: the operator's channel is the agent's own stream — the window records a `rate_limit_event` frame from a turn on its own, with no click or drag — so the UI half of a parity step cannot be expressed: no click or drag of the operator's produces it, so there is no UI half to compare. Both channels ARE covered: the dispatch by capacity-low-reading.jsonl and capacity-passed-reset.jsonl, the stream by agent/capacity-after-turn.jsonl, each asserting the reading it lands on the indicator; what no check can express is the comparison.
- `ctx_provider_login` — #254. Opens a browser on the operator's machine and authenticates as them. No harness can drive it and none should: every run would leave a real credential behind.
- `api_fill_from_curl` — its parity: the UI half of a parity step is a click or a drag, and the operator's channel is a paste (cmd+v into the path editor), so the comparison cannot be expressed. Both channels ARE covered: the dispatch by api-paste-curl.jsonl, the paste by api-paste-curl-hotkey.jsonl, each asserting the same draft and the Filled from cURL line; what no check can express is the comparison.
- `editor_goto` — its parity (3b-i): there is no operator control for it — the operator moves the cursor inside Monaco, the one non-action path (design-language §11), so no UI half exists to compare. The dispatch is covered by 3b-i-editor-tabs-language.jsonl (cursor.line and cursor.column through read_pane) and refused on an empty pane in 3b-i-editor-refusals.jsonl.
- `editor_move_tab` — its parity (3b-ii-b): the drag moves a tab, and the same {from, to} dispatched on the moved strip moves a different tab, so the two halves cannot read back the same order. The drag and the dispatch are each 3b-ii-b-tab-move.jsonl's, each asserting the strip's order and the active tab through read_pane.
- `db_remove_database` — its parity: the click removes the database, and removing one that is gone is refused (`no database … in environment …`), so the dispatch half cannot be given the same params. Dispatch is covered by 2e-settings-databases-dispatch.jsonl and the click by 2e-settings-databases.jsonl; what no check can express is the comparison.
- `editor_close` — its parity (3b-i): the operator's channels are ⌘W (a key) and the unsaved prompt's Don't Save, and the click consumes its own subject — the dispatch half after it would close a different tab or be refused (`the editor pane has no open tab`), api_cancel's case. Both channels ARE covered: 3b-i-editor-close-keys.jsonl (⌘W clean, ⌘W dirty → Esc / Cancel / Don't Save) and the dispatch with and without discard in 3b-i-editor-refusals.jsonl.
- `editor_peek` — its parity (3b-iii): the operator's channel is a click on a change mark in Monaco's gutter, inside the WKWebView — a web element with no accessibility identifier, which the resolver cannot address (editor_goto's case: inside Monaco, the one non-action path). The dispatch is covered by 3b-iii-peek.jsonl (opened on a mark, refused on an unmarked line, on an untracked file and on a diff tab in 3b-iii-diff-refusals.jsonl); the mark click is the runbook's row 8.
- `editor_replace_range` — its parity (3b-i): no operator control — the operator's own edits are typing in Monaco, the one non-action path (`editorBufferDidChange`), so no UI half exists. The dispatch is covered by most 3b-i-editor-* checks, and its read-only refusal by 3b-i-editor-read-only.jsonl.
- `api_reopen` — its dispatch: it needs a row id, which is minted per send and published only in read_pane — the same reason api_render_curl below is here. The operator's gesture IS covered: api-recent.jsonl presses api.recent.0.reopen and asserts the draft it rebuilds. Permanent, not blocked: nothing in the vocabulary carries a value from read_pane into a dispatch.
- `editor_select` — its parity (3b-i): no operator control — the operator selects inside Monaco, the one non-action path, so no UI half exists. The dispatch is covered by most 3b-i-editor-* checks, which read selected_text back to prove what a save wrote.
- `editor_new_scratch` — its parity (3b-i): the operator's channel is ⌘T, a menu key equivalent — a key, not a click or a drag, and the UI half of a parity step is a click or a drag only (api_fill_from_curl's case); the empty pane only names the key. The dispatch is covered by most 3b-i-editor-* checks; ⌘T by 3b-i-editor-scratch-save.jsonl and 3b-i-editor-close-keys.jsonl, asserting the Untitled-N tab through read_pane.
- `ctx_add_provider` — its parity: the click creates a binding under an id, so a dispatch with the same params collides with what the click just made. Covered by 2e-settings-doors.jsonl up to the browser leg.
- `api_render_curl` — Two reasons, and the second is the one that lasts. A dispatch cannot hold the row id, which is minted per send and published only in read_pane; and the operator's own Copy as cURL puts its line on the PASTEBOARD, which no check can read — the act is real and its result leaves the window. `api_reopen`'s CLICK left this file when the recent strip gave it a button, because a reopen's effect lands in the draft where a check can see it; its dispatch half is still here, for the first of these reasons. Covered by WakilKitTests: curlIsPastTenseOnly, curlOnlyMentionsACredentialThereWasOne, curlEmitsAndNeverParses.
- `editor_restore` — its parity (3b-i): no operator control — it runs when a window relaunches onto saved tabs, and one check is one launch. The dispatch is covered by 3b-i-editor-disk-changed.jsonl (an open, dirty tab is kept as it is); restoring after a relaunch is the runbook's row 9.
- `api_unbind` — its parity: the click returns the binding to its hole, and api_unbind refuses a position that holds no binding (`unbindNotABinding`), so the dispatch half cannot be given the same params — and a re-drag between the halves is not expressible. Both channels ARE covered by api-unbind.jsonl, each after its own drag, asserting the same hole back through read_pane; what no check can express is the comparison.
- `settings_open` — its parity: the only UI path is the `Settings…` MENU item, and a menu's buttons are not in the accessibility tree until the menu is open — the same rule that excuses every other menu control. Checks drive it by its real gesture, cmd+comma, and 2e-settings-pane.jsonl also dispatches it.
- `editor_open_file` — its parity (3b-iii): the operator's channel is ⌘⏎ in a diff tab, a menu key equivalent (Maximize Pane's item, which a diff tab redirects) — a key, not a click or a drag — so no UI half can be expressed. Both channels ARE covered by 3b-iii-diff-open-file.jsonl, each opening app.txt at the diff's cursor line with the diff tab kept, and ⌘⏎ on a scratch tab maximizing; its refusal on a deleted file by 3b-iii-changes-live.jsonl.
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
