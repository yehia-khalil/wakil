# 3b-ii — the editor's left column: acceptance

**Spec:** [`2026-10-13-3b-ii-editor-tree-design.md`](../superpowers/specs/2026-10-13-3b-ii-editor-tree-design.md) ·
**Plan:** [`2026-10-13-3b-ii-editor-tree.md`](../superpowers/plans/2026-10-13-3b-ii-editor-tree.md)

**Not yet walked.**

The exit criterion, from the spec: browse the project from the editor's left column, search across
its files and find in one, with ignored files reachable, the tree following the disk, and each
pane's column coming back after a relaunch — all of it drivable by the agent as well.

The decisions behind it are Decision 37 (root focus dropped; file operations are 3b-iv and editor
settings 3b-v) and design-language §1 and §11 (the left column is the second sanctioned sidebar,
shown and hidden only by the operator or the agent, never by width).

## 0. Setup

A project's roots are the `"roots"` array of its `project.json`, read at launch and on a project
switch, not live. Run this in the repo root, on this Mac, after `make build` and `make app-bundle`.
It is safe to re-run. Set `ORG` to one you have registered (`./bin/wakil org list`).

```bash
set -e
ORG=initech   # the org to walk under; initech or umbrella
cd /Users/operator/Desktop/scripts/wakil
rm -rf /tmp/walk-tree /tmp/walk-tree-project
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
G="git -c user.name=walk -c user.email=walk@example.com"
mkdir -p /tmp/walk-tree/api /tmp/walk-tree/portal /tmp/walk-tree-project
cd /tmp/walk-tree/api && git init -q -b main
printf '.env\nvendor/\n' > .gitignore; echo 'DB_PASSWORD=walk' > .env
mkdir -p app/Models vendor/laravel config && echo '<?php $bookingId = 1;' > app/Models/Booking.php && echo '<?php' > vendor/autoload.php
echo '<?php return [];' > config/env.php
mkdir -p big && for i in $(seq -w 1 200); do yes 'lorem ipsum dolor sit amet' | head -c 1048576 > big/$i.txt; done
git add . && $G commit -qm init
cd /tmp/walk-tree/portal && git init -q -b main
mkdir -p src && echo 'const bookingId = 2;' > src/routes.ts && git add . && $G commit -qm init
cat > /tmp/walk-tree-project/project.json <<J
{"name":"walk-tree","org":"$ORG","roots":[{"path":"/tmp/walk-tree"}],"scopes":{},"environments":{}}
J
cd /Users/operator/Desktop/scripts/wakil
./bin/wakil project rm walk-tree --org "$ORG" || true
./bin/wakil project add walk-tree --path /tmp/walk-tree-project/project.json --org "$ORG"
```

The one root is a folder of two repositories, so the walk sees child-repository nodes. `api/big/`
is 200 MiB of committed text (200 files of 1 MiB): enough that a regex search with no literal
prefix runs for seconds, long enough to press Cancel (row 7). `config/env.php` is the tracked
`env` file ⌘P ranks above `.env` (row 4).

Launch `WAKIL_ORG=initech app/Wakil.app/Contents/MacOS/Wakil` (or `umbrella`), then make the project
active with the project switcher (⌘P, choose `walk-tree`). Registering does not select it.

## 1. The walk

Walk in order, in an agent-answering organisation, on the project `walk-tree` from §0.

| # | Do | Expect |
|---|---|---|
| 1 | ⌘T, then ⌘B; drag the column's edge right, then far right | The column shows `walk-tree` with `api` and `portal` as nodes. The edge drags, and stops at half the pane |
| 2 | Open `api` → `app` → `Models`; click `Booking.php`, then `routes.ts` under `portal` | Each opens in one italic preview tab, replaced by the next. ↑↓ moves through the tree without Monaco taking the keyboard |
| 3 | Double-click `routes.ts`'s row; type a character in it | The tab title is no longer italic. Typing also keeps a preview tab |
| 4 | Open `api`'s `.env` from the tree, then ⌘P `env`. Then open `vendor` | `.env` is dimmed in both; ⌘P ranks it below any tracked `env` file, and it opens. `vendor` is one dimmed row until opened; then `laravel` and `autoload.php`, dimmed |
| 5 | Open a terminal pane from ⌘P and click into it. ⌘P back to the editor pane and press ⌘B at once, then ↓. Click into the terminal again, then click a row in the editor's column and press ↓ | ⌘B on the pane just switched to shows (or hides) its column, and when shown the column holds the keyboard: ↓ moves the tree, nothing reaches Monaco or the terminal. The click into the unfocused pane's column keeps the keyboard there: ↓ moves the tree |
| 6 | ⌘⇧F, type `bookingId` (no Enter) | Results after a short pause: `api` and `portal` groups, each match marked; a group header folds its results. Return on `routes.ts:1` opens it at the match, with Monaco's find bar on `bookingId` |
| 7 | Switch on `.*` and replace the query with `book(`. Then replace it with `\w+zq\d` and press Cancel while *searching* shows | `missing closing )` in full; nothing runs. The second search shows the tick and Cancel; Cancel stops it at once: the tick goes, *search cancelled · Re-run* shows, no results and no error, and the query stays. Re-run searches again and ends on *no matches* |
| 8 | Replace the query with `bookingId`. In a terminal: `cd /tmp/walk-tree/api && git checkout -qb x && touch born.php`. Then `echo '// bookingId' >> /tmp/walk-tree/api/app/Models/Booking.php` | `born.php` appears within about a second; open folders stay open. The Search view offers no Re-run after the first command (no result's file changed), and shows *files changed since this search · Re-run* after the second |
| 9 | In a file, ⌘F `booking`, ⌥⌘F `booking_id`, replace all; Esc. Then ask the agent "find bookingId in this file" and "search the project for bookingId" | The find bar is in Wakil's colours, the tab turns dirty, and ⌘Z undoes it. The agent's find opens the bar on its query; its search fills the Search view; neither moves the keyboard from where it was |
| 10 | Quit (clean) and relaunch | Each pane's column is back: shown, view, width and open folders. A new ⌘T pane starts as the last one was left |

## 2. Residue — what the walk cannot establish

- **The tree's selection is view-local**, so `read_pane` does not report the highlighted row; only
  the walk sees it (rows 2 and 5).
- **Changed since follows the burst's paths** (final review I4): only a change to a result's file, or
  to a folder FSEvents asks to rescan that holds one, offers Re-run; a log or a build elsewhere under
  the root does not. A burst of more than 2,000 paths (an install) counts as the whole root.
- **The 2,000-match note** (`editor.search.note`) is walk-only, and needs a project with that many
  matches; this walk's files do not reach it. **Cancel on a search** is walked in row 7 against
  `api/big/`, whatever the controller's measured run decides for `editor.search.cancel` (§3).
- **File operations and settings** are 3b-iv and 3b-v (Decision 37): the tree is read-only, the heavy
  folders are a fixed list, and nothing here walks either.

## 3. Residue — what Cover could not reach, and why

Written by the e2e auditor (Cover rung). Ten checks, `e2e/checks/seeded/3b-ii-*.jsonl`, over the git
project's seed, which now carries a gitignored `.env` and `vendor/` (and, for the Cancel check's
launch only, a committed `bulk/` haystack).
They cover all six new actions — `editor_tree`, `editor_tree_expand`, `editor_tree_collapse`,
`editor_search` and `editor_find` each with a parity step, and `files_search` dispatched — and every
new control but those below. What they cannot reach:

- **The ticks** (`editor.tree.loading`, `editor.search.busy`, Rule 5): shapes with no press action;
  a fixture root lists in milliseconds. `search.in_flight` is asserted through `read_pane` instead.
- **Cancel on a search** (`editor.search.cancel`, Rule 4): pressed by `3b-ii-search-cancel.jsonl`
  against the `bulk/` haystack, which only that check's launch seeds (`SeedSpec.SearchHaystack`).
  If the controller's measured run shows the search finishing before a press can land, the check is
  dropped and the control excused on `editor.saving.cancel`'s precedent; the unit test
  `cancelStopsTheSearchInFlight` pins that the tool call stops either way, and row 7 walks it.
- **The caps' notes** (`editor.search.note`, `editor.search.filesNote`, `editor.tree.note:<…>`):
  2,000 matches and 50,000 files are not seeded; the caps are pinned by Go and WakilKit tests.
- **A listing error** (`editor.tree.error:<…>`): every fixture root lists.
- **Containers and drawn text** (`editor.column`, `editor.search.error`): read, not pressed;
  `missing closing )` is asserted by `3b-ii-search-errors.jsonl`.
- **The operator's keyboard** (rows 2, 3 and 5): ↑↓, ←→, type-ahead, a double-click and where focus
  lands after ⌘B are keys and focus, which no step asserts. ⌘B and ⌘⇧F are pressed and their
  column read back; Rule 3's focus timing and Rule 6's "the agent never moves the keyboard" are walked.
- **Live update from a terminal** (row 8): the check saves `born.txt` from a second editor pane; a
  dispatched terminal command as the route is #401.
- **Relaunch restore** (row 10): one check is one launch.
- **Visual rulings** (rows 1–4, 9): italics, dimming, the marked match and the find bar's colours
  are the operator's.
- **The agent in the loop** (row 9): the checks dispatch the same actions over the same socket; that
  a real model chooses them is the operator's.

## 4. The machine walk

Rendered by `make e2e-runbook` after the Cover rung. Nothing is written here by hand.

<!-- machine-walk: generated by `make e2e-runbook`; everything between these markers is overwritten -->

**The machine walk is green:** every check ran against this build, every check this branch added was seen to fail against the merge-base, and the surface it added carries checks.

Walked by `make e2e` against 0866f76fbf30, rendered 2026-10-14 15:43 UTC by `make e2e-runbook`. Re-render it with that target; edits between the markers are overwritten.

| Check | `make e2e` | Red against the base | Assertions | Evidence |
|---|---|---|---|---|
| `org-plane.jsonl` | ✓ exit 0 | not new on this branch | 3 | — |
| `2c-iii-1-bundle-path.jsonl` | ✓ exit 0 | not new on this branch | 8 | — |
| `2c-iii-2-block.jsonl` | ✓ exit 0 | not new on this branch | 7 | — |
| `2c-iii-3-live-prompt.jsonl` | ✓ exit 0 | not new on this branch | 7 | — |
| `2c-iii-4-interrupt.jsonl` | ✓ exit 0 | not new on this branch | 8 | — |
| `2c-iii-5-full-screen.jsonl` | ✓ exit 0 | not new on this branch | 7 | — |
| `2c-iii-6-no-orphan.jsonl` | ✓ exit 0 | not new on this branch | 5 | — |
| `2c-iii-7-org-switch.jsonl` | ✓ exit 0 | not new on this branch | 8 | — |
| `2d-ii-composer-keeps-input.jsonl` | ✓ exit 0 | not new on this branch | 5 | — |
| `2d-ii-composer-return-sends.jsonl` | ✓ exit 0 | not new on this branch | 4 | — |
| `2d-ii-settings-speech.jsonl` | ✓ exit 0 | not new on this branch | 8 | — |
| `2d-ii-voice-escape.jsonl` | ✓ exit 0 | not new on this branch | 8 | — |
| `2d-ii-voice-lands-focused.jsonl` | ✓ exit 0 | not new on this branch | 5 | — |
| `2d-ii-voice-lands-unsent.jsonl` | ✓ exit 0 | not new on this branch | 7 | — |
| `2d-ii-voice-silence.jsonl` | ✓ exit 0 | not new on this branch | 5 | — |
| `2e-settings-databases-dispatch.jsonl` | ✓ exit 0 | not new on this branch | 10 | — |
| `2e-settings-databases.jsonl` | ✓ exit 0 | not new on this branch | 20 | — |
| `2e-settings-doors.jsonl` | ✓ exit 0 | not new on this branch | 8 | — |
| `2e-settings-organisation.jsonl` | ✓ exit 0 | not new on this branch | 7 | — |
| `2e-settings-pane.jsonl` | ✓ exit 0 | not new on this branch | 10 | — |
| `2e-settings-unlink.jsonl` | ✓ exit 0 | not new on this branch | 11 | — |
| `365-terminal-paste.jsonl` | ✓ exit 0 | ✓ red vs f25a762e5ee7, recorded 2026-10-09 | 4 | — |
| `365-terminal-select-backspace.jsonl` | ✓ exit 0 | ✓ red vs f25a762e5ee7, recorded 2026-10-09 | 3 | — |
| `365-terminal-select-type.jsonl` | ✓ exit 0 | ✓ red vs f25a762e5ee7, recorded 2026-10-09 | 4 | — |
| `3a-i-git-drill.jsonl` | ✓ exit 0 | ✓ red vs a376e0796810, recorded 2026-10-09 | 27 | — |
| `3a-i-git-keys.jsonl` | ✓ exit 0 | ✓ red vs a376e0796810, recorded 2026-10-09 | 20 | — |
| `3a-i-git-list.jsonl` | ✓ exit 0 | ✓ red vs a376e0796810, recorded 2026-10-09 | 29 | — |
| `3a-i-git-live.jsonl` | ✓ exit 0 | ✓ red vs f25a762e5ee7, recorded 2026-10-10 | 25 | — |
| `3a-i-git-press.jsonl` | ✓ exit 0 | ✓ red vs a376e0796810, recorded 2026-10-09 | 12 | — |
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
| `3b-ii-find.jsonl` | ✓ exit 0 | ✓ red vs 8e8ec7d29e7f | 8 | — |
| `3b-ii-palette-ignored.jsonl` | ✓ exit 0 | ✓ red vs 8e8ec7d29e7f | 6 | — |
| `3b-ii-refusals.jsonl` | ✓ exit 0 | ✓ red vs 8e8ec7d29e7f | 5 | — |
| `3b-ii-search-cancel.jsonl` | ✓ exit 0 | ✓ red vs 8e8ec7d29e7f | 12 | — |
| `3b-ii-search-errors.jsonl` | ✓ exit 0 | ✓ red vs 8e8ec7d29e7f | 9 | — |
| `3b-ii-search.jsonl` | ✓ exit 0 | ✓ red vs 8e8ec7d29e7f | 43 | — |
| `3b-ii-tree-ignored-heavy.jsonl` | ✓ exit 0 | ✓ red vs 8e8ec7d29e7f | 9 | — |
| `3b-ii-tree-live.jsonl` | ✓ exit 0 | ✓ red vs 8e8ec7d29e7f | 11 | — |
| `3b-ii-tree-preview.jsonl` | ✓ exit 0 | ✓ red vs 8e8ec7d29e7f | 19 | — |
| `3b-ii-tree-toggle.jsonl` | ✓ exit 0 | ✓ red vs 8e8ec7d29e7f | 14 | — |
| `3b-v-click-focuses-pane.jsonl` | ✓ exit 0 | ✓ red vs e6c782b4f52f, recorded 2026-10-13 | 8 | — |
| `3b-v-editor-autosave-focus.jsonl` | ✓ exit 0 | ✓ red vs e6c782b4f52f, recorded 2026-10-13 | 22 | — |
| `3b-v-editor-autosave-pause.jsonl` | ✓ exit 0 | ✓ red vs e6c782b4f52f, recorded 2026-10-13 | 23 | — |
| `3b-v-editor-autosave-prompt-guard.jsonl` | ✓ exit 0 | ✓ red vs e6c782b4f52f, recorded 2026-10-13 | 18 | — |
| `3b-v-editor-indent-scratch.jsonl` | ✓ exit 0 | ✓ red vs e6c782b4f52f, recorded 2026-10-13 | 11 | — |
| `3b-v-editor-live-options.jsonl` | ✓ exit 0 | ✓ red vs e6c782b4f52f, recorded 2026-10-13 | 21 | — |
| `3b-v-editor-settings-nodes.jsonl` | ✓ exit 0 | ✓ red vs e6c782b4f52f, recorded 2026-10-13 | 28 | — |
| `3b-v-project-editor-settings.jsonl` | ✓ exit 0 | ✓ red vs e6c782b4f52f, recorded 2026-10-13 | 19 | — |
| `agent-pane-is-drawn.jsonl` | ✓ exit 0 | not new on this branch | 4 | — |
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
| `api-paste-curl.jsonl` | ✓ exit 0 | not new on this branch | 20 | — |
| `api-query-sync.jsonl` | ✓ exit 0 | not new on this branch | 15 | — |
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
| `capacity-low-reading.jsonl` | ✓ exit 0 | ✓ red vs 1402c099d411, recorded 2026-10-11 | 9 | — |
| `capacity-passed-reset.jsonl` | ✓ exit 0 | ✓ red vs 1402c099d411, recorded 2026-10-11 | 6 | — |
| `db-query-line-agent-replaces.jsonl` | ✓ exit 0 | ✓ red vs 3c9c923b17ca, recorded 2026-10-07 | 8 | — |
| `db-query-line-format.jsonl` | ✓ exit 0 | ✓ red vs 3c9c923b17ca, recorded 2026-10-07 | 5 | — |
| `db-query-line-long.jsonl` | ✓ exit 0 | **proved red vs 3c9c923b17ca on an earlier version — not re-proved** | 5 | — |
| `db-query-line-not-formatted.jsonl` | ✓ exit 0 | ✓ red vs 3c9c923b17ca, recorded 2026-10-07 | 6 | — |
| `db-query-line-return.jsonl` | ✓ exit 0 | ✓ red vs 3c9c923b17ca, recorded 2026-10-07 | 9 | — |
| `journal-error-reason.jsonl` | ✓ exit 0 | ✓ red vs dfb508b06420, recorded 2026-10-08 | 2 | — |
| `landing.jsonl` | ✓ exit 0 | not new on this branch | 5 | — |
| `palette-api-entry.jsonl` | ✓ exit 0 | ✓ red vs f25a762e5ee7, recorded 2026-10-10 | 9 | — |
| `palette-api-send.jsonl` | ✓ exit 0 | ✓ red vs f25a762e5ee7, recorded 2026-10-10 | 10 | — |
| `palette-command-step.jsonl` | ✓ exit 0 | ✓ red vs f25a762e5ee7, recorded 2026-10-10 | 12 | — |
| `palette-escape.jsonl` | ✓ exit 0 | ✓ red vs f25a762e5ee7, recorded 2026-10-10 | 11 | — |
| `palette-modes.jsonl` | ✓ exit 0 | ✓ red vs f25a762e5ee7, recorded 2026-10-10 | 16 | — |
| `palette-new-git-parity.jsonl` | ✓ exit 0 | ✓ red vs f25a762e5ee7, recorded 2026-10-10 | 14 | — |
| `palette-open-kinds.jsonl` | ✓ exit 0 | ✓ red vs f25a762e5ee7, recorded 2026-10-10 | 17 | — |
| `palette-run-error.jsonl` | ✓ exit 0 | ✓ red vs f25a762e5ee7, recorded 2026-10-10 | 13 | — |
| `palette-switch-environment.jsonl` | ✓ exit 0 | ✓ red vs f25a762e5ee7, recorded 2026-10-10 | 17 | — |
| `palette-table-row.jsonl` | ✓ exit 0 | ✓ red vs f25a762e5ee7, recorded 2026-10-10 | 11 | — |
| `vocabulary.jsonl` | ✓ exit 0 | ✓ red vs f25a762e5ee7, recorded 2026-10-10 | 8 | — |
| `2d-i-code-hint.jsonl` | ✓ exit 0 | **proved red vs fb7e8f09d0f3 on an earlier version — not re-proved** | 6 | — |
| `2d-i-failed-source.jsonl` | ✓ exit 0 | **proved red vs fb7e8f09d0f3 on an earlier version — not re-proved** | 5 | — |
| `2d-i-hint-or-plain.jsonl` | ✓ exit 0 | **proved red vs fb7e8f09d0f3 on an earlier version — not re-proved** | 8 | — |
| `2d-i-over-limit.jsonl` | ✓ exit 0 | **proved red vs fb7e8f09d0f3 on an earlier version — not re-proved** | 5 | — |
| `2d-i-pane-hint.jsonl` | ✓ exit 0 | **proved red vs fb7e8f09d0f3 on an earlier version — not re-proved** | 5 | — |
| `2d-i-schema-hint.jsonl` | ✓ exit 0 | **proved red vs fb7e8f09d0f3 on an earlier version — not re-proved** | 4 | — |
| `2d-ii-thread-earlier.jsonl` | ✓ exit 0 | not new on this branch | 12 | — |
| `2d-ii-voice-turn.jsonl` | ✓ exit 0 | not new on this branch | 10 | — |
| `3a-i-git-voice-hint.jsonl` | ✓ exit 0 | ✓ red vs a376e0796810, recorded 2026-10-09 | 4 | — |
| `both-surfaces.jsonl` | ✓ exit 0 | not new on this branch | 6 | — |
| `capacity-after-turn.jsonl` | ✓ exit 0 | ✓ red vs 1402c099d411, recorded 2026-10-11 | 7 | — |
| `two-enter.jsonl` | ✓ exit 0 | not new on this branch | 13 | — |
| `/private/tmp/claude-501/-Users-operator-Desktop-scripts-wakil/d983c257-2b0f-4190-b61b-6790b0bb2616/scratchpad/probe/a-term-only.jsonl` | — | — | — | a record for a check the corpus no longer holds |
| `/private/tmp/claude-501/-Users-operator-Desktop-scripts-wakil/d983c257-2b0f-4190-b61b-6790b0bb2616/scratchpad/probe/b-editor-then-term.jsonl` | — | — | — | a record for a check the corpus no longer holds |
| `/private/tmp/claude-501/-Users-operator-Desktop-scripts-wakil/d983c257-2b0f-4190-b61b-6790b0bb2616/scratchpad/probe/c-compare.jsonl` | — | — | — | a record for a check the corpus no longer holds |
| `/private/tmp/claude-501/-Users-operator-Desktop-scripts-wakil/d983c257-2b0f-4190-b61b-6790b0bb2616/scratchpad/probe/d-palette.jsonl` | — | — | — | a record for a check the corpus no longer holds |
| `/private/tmp/claude-501/-Users-operator-Desktop-scripts-wakil/d983c257-2b0f-4190-b61b-6790b0bb2616/scratchpad/probe/e-tab.jsonl` | — | — | — | a record for a check the corpus no longer holds |
| `/private/tmp/claude-501/-Users-operator-Desktop-scripts-wakil/d983c257-2b0f-4190-b61b-6790b0bb2616/scratchpad/probe/f-tree.jsonl` | — | — | — | a record for a check the corpus no longer holds |
| `e2e/checks/seeded/2d-i-palette-fold.jsonl` | — | — | — | a record for a check the corpus no longer holds |

**`make e2e-new` saw every check this branch added go red against 8e8ec7d29e7f.**

**Every action and control this branch added carries a check.** 6 action(s) and 24 control(s) are new on this branch.

- actions:  54 of 96 dispatched by a check
- writes:   17 of 66 carry a parity check
- controls: 102 of 181 exercised by a check

**75 piece(s) of surface no check can reach**, each with the reason given in `e2e/checks/uncoverable.tsv`:

- `settings_open` — its parity: the only UI path is the `Settings…` MENU item, and a menu's buttons are not in the accessibility tree until the menu is open — the same rule that excuses every other menu control. Checks drive it by its real gesture, cmd+comma, and 2e-settings-pane.jsonl also dispatches it.
- `capacity_record` — its parity: the operator's channel is the agent's own stream — the window records a `rate_limit_event` frame from a turn on its own, with no click or drag — so the UI half of a parity step cannot be expressed, on git_fold's precedent. Both channels ARE covered: the dispatch by capacity-low-reading.jsonl and capacity-passed-reset.jsonl, the stream by agent/capacity-after-turn.jsonl, each asserting the reading it lands on the indicator; what no check can express is the comparison.
- `api_unbind` — its parity: the click returns the binding to its hole, and api_unbind refuses a position that holds no binding (`unbindNotABinding`), so the dispatch half cannot be given the same params — and a re-drag between the halves is not expressible. Both channels ARE covered by api-unbind.jsonl, each after its own drag, asserting the same hole back through read_pane; what no check can express is the comparison.
- `editor_replace_range` — its parity (3b-i): no operator control — the operator's own edits are typing in Monaco, the one non-action path (`editorBufferDidChange`), so no UI half exists. The dispatch is covered by most 3b-i-editor-* checks, and its read-only refusal by 3b-i-editor-read-only.jsonl.
- `ctx_add_provider` — its parity: the click creates a binding under an id, so a dispatch with the same params collides with what the click just made. Covered by 2e-settings-doors.jsonl up to the browser leg.
- `api_reopen` — its dispatch: it needs a row id, which is minted per send and published only in read_pane — the same reason api_render_curl below is here. The operator's gesture IS covered: api-recent.jsonl presses api.recent.0.reopen and asserts the draft it rebuilds. Permanent, not blocked: nothing in the vocabulary carries a value from read_pane into a dispatch.
- `api_cancel` — its parity: the click cancels the send in flight, and api_cancel refuses a pane with nothing in flight (`nothingInFlight`), so the dispatch half cannot be given the same state — and a second Send between the halves is not expressible. Both channels ARE covered by api-cancel.jsonl, each after its own Send, asserting the same cancelled response through read_pane; what no check can express is the comparison.
- `git_step` — its parity (3a-i): the operator's channel is ↑↓ with the diff open — keys, not a click or a drag — so the UI half of a parity step cannot be expressed, on api_fill_from_curl's precedent. The dispatch is covered by 3a-i-git-drill.jsonl (across roots, both directions, asserting the selection and the header through read_pane and the tree). The keyboard half is 3a-i-git-keys.jsonl: ↑↓ folded, across both roots, asserting the selection through read_pane.
- `editor_select` — its parity (3b-i): no operator control — the operator selects inside Monaco, the one non-action path, so no UI half exists. The dispatch is covered by most 3b-i-editor-* checks, which read selected_text back to prove what a save wrote.
- `db_remove_database` — its parity: the click removes the database, and removing one that is gone is refused (`no database … in environment …`), so the dispatch half cannot be given the same params. Dispatch is covered by 2e-settings-databases-dispatch.jsonl and the click by 2e-settings-databases.jsonl; what no check can express is the comparison.
- `editor_restore` — its parity (3b-i): no operator control — it runs when a window relaunches onto saved tabs, and one check is one launch. The dispatch is covered by 3b-i-editor-disk-changed.jsonl (an open, dirty tab is kept as it is); restoring after a relaunch is the runbook's row 9.
- `git_fold` — its parity (3a-i): there is no operator control for it at all — GitPane folds only by selecting, so git_fold is the agent's alone and no UI half exists to compare. The dispatch is covered by 3a-i-git-drill.jsonl (fold again, the same file and position).
- `editor_new_scratch` — its parity (3b-i): the operator's channel is ⌘T, a menu key equivalent — a key, not a click or a drag — on git_step's precedent; the empty pane only names the key. The dispatch is covered by most 3b-i-editor-* checks; ⌘T by 3b-i-editor-scratch-save.jsonl and 3b-i-editor-close-keys.jsonl, asserting the Untitled-N tab through read_pane.
- `editor_goto` — its parity (3b-i): there is no operator control for it — the operator moves the cursor inside Monaco, the one non-action path (design-language §11), so no UI half exists to compare, on git_fold's precedent. The dispatch is covered by 3b-i-editor-tabs-language.jsonl (cursor.line and cursor.column through read_pane) and refused on an empty pane in 3b-i-editor-refusals.jsonl.
- `ctx_unlink_provider` — its parity: the click removes the binding, so the dispatch half cannot be given the same id. Dispatch and both channels' behaviour ARE covered by 2e-settings-unlink.jsonl; what no check can express is the comparison.
- `ctx_provider_login` — #254. Opens a browser on the operator's machine and authenticates as them. No harness can drive it and none should: every run would leave a real credential behind.
- `api_fill_from_curl` — its parity: the UI half of a parity step is a click or a drag, and the operator's channel is a paste (cmd+v into the path editor), so the comparison cannot be expressed. Both channels ARE covered: the dispatch by api-paste-curl.jsonl, the paste by api-paste-curl-hotkey.jsonl, each asserting the same draft and the Filled from cURL line; what no check can express is the comparison.
- `api_undo_fill` — its parity: the Undo click forgets the fill it undoes, and api_undo_fill refuses a pane with nothing to undo, so the dispatch half cannot be given the same state after the click — and a second fill between the halves is not expressible inside one parity step. Both channels ARE covered by api-paste-curl.jsonl, the click after one fill and the dispatch after another, each asserting the same restored draft through read_pane; what no check can express is the comparison.
- `git_unfold` — its parity (3a-i): the operator's channel is Esc — a key, not a click or a drag — so the UI half of a parity step cannot be expressed. The dispatch is covered by 3a-i-git-drill.jsonl (unfold keeps the selection, the list is back). The keyboard half is 3a-i-git-keys.jsonl: Esc unfolds with the same file selected.
- `editor_open` — its parity (3b-i): the operator's channel is ⌘P — typing and Return — and a file row's identifier carries this launch's absolute path (`palette.row.editorfile:<root>/<rel>`), while `{fixtureRoot}` expands only in dispatch and parity params, never in a click. So no UI half can name the row. The dispatch is covered by every 3b-i-editor-* check that opens a file; the operator's gesture by 3b-i-editor-files-palette.jsonl (⌘P, the file's name, Return, asserting the tab and its text through read_pane).
- `editor_close` — its parity (3b-i): the operator's channels are ⌘W (a key) and the unsaved prompt's Don't Save, and the click consumes its own subject — the dispatch half after it would close a different tab or be refused (`the editor pane has no open tab`), api_cancel's case. Both channels ARE covered: 3b-i-editor-close-keys.jsonl (⌘W clean, ⌘W dirty → Esc / Cancel / Don't Save) and the dispatch with and without discard in 3b-i-editor-refusals.jsonl.
- `api_render_curl` — Two reasons, and the second is the one that lasts. A dispatch cannot hold the row id, which is minted per send and published only in read_pane; and the operator's own Copy as cURL puts its line on the PASTEBOARD, which no check can read — the act is real and its result leaves the window. `api_reopen`'s CLICK left this file when the recent strip gave it a button, because a reopen's effect lands in the draft where a check can see it; its dispatch half is still here, for the first of these reasons. Covered by WakilKitTests: curlIsPastTenseOnly, curlOnlyMentionsACredentialThereWasOne, curlEmitsAndNeverParses.
- `api.recent.<…>.curl` — Its whole effect is a string on the SYSTEM PASTEBOARD, which no check can read — the act is real and its result leaves the window, so a check could press it and assert nothing, which is the check-that-cannot-fail this file exists to prevent rather than permit. `TerminalPane`'s own Copy is silent for the same reason and carries no indicator. The line it copies is `apiRenderCurl`'s, covered by WakilKitTests: curlIsPastTenseOnly, curlOnlyMentionsACredentialThereWasOne, curlEmitsAndNeverParses. If this pane ever draws a "copied" acknowledgement, the act becomes observable and this line should go.
- `api.response.<…>` — the Body · Headers choice (W20) is drawn only over a reply, and no fixture host ever replies — every entry is `.invalid` or the never-answering `slow`, and wakil-http refuses http://. apiResponseOffersHeaders and apiResponseHeaderRows are pinned in ApiPaneLayoutTests; the drawn table is the runbook's check 5.
- `db.<…>.notFormatted` — display text, not a control: a static `Text` (DBPane.swift) carrying Format's refusal reason, with no press action, and the vocabulary addresses only `click`/`focus` by identifier while `expect.tree` matches by text, so no step can "press" it. Its content IS asserted: db-query-line-not-formatted.jsonl expects `not formatted: a string opened at character 39 never closes` in the tree, then its absence after the next edit.
- `editor.column` — the editor's left column's container (.contain, 3b-ii): its header, the tree or the search view, and the edge, and it takes no input itself. What it draws is read by every 3b-ii-* check; its controls are editor.column.files / .search, pressed by 3b-ii-tree-toggle.jsonl, editor.column.edge, dragged there, and the tree's and search's own.
- `editor.compare.diff` — Compare's Monaco host (3b-i): a WKWebView container with no press action. 3b-i-editor-disk-changed.jsonl asserts Compare's header opens and closes (button and Esc); what the diff shows is the operator's ruling (runbook row 6).
- `editor.compare.failure` — a Text (3b-i, Rule 8): drawn only when the file cannot be read back for Compare. The fixture's files are always readable and no step can make one unreadable mid-launch; display text with no press action either way. The runbook walks Compare.
- `editor.diskChanged` — the disk line's container (.contain, 3b-i): its text and two buttons. Read, not pressed — 3b-i-editor-disk-changed.jsonl asserts "disk.txt changed on disk" and its absence while comparing and after Reload; its buttons are editor.reload and editor.compare, pressed.
- `editor.empty` — the empty pane's hint (3b-i, .combine): "⌘P to open a file · ⌘T for a scratch tab", with no press action. Read, not pressed — 3b-i-editor-close-keys.jsonl asserts it after the last tab closes, and its absence after ⌘W closes the pane.
- `editor.monaco` — the Monaco host's container (3b-i): an NSViewRepresentable holding the WKWebView, with no press action of its own (git.diff's case). Typing into it is driven by keys: 3b-i-editor-scratch-save.jsonl types after ⌘T and after a save, and asserts the text through read_pane.
- `editor.notice` — a Text (3b-i, Rule 8): a tab's notice, drawn whole. Read, not pressed — 3b-i-editor-read-only.jsonl asserts "ro.bin is a binary file" in the tree and through read_pane.
- `editor.saveAs.failure` — a Text (3b-i, Rule 8): the path field's failure, drawn whole. Read, not pressed — 3b-i-editor-save-as-field.jsonl asserts "is outside the active project's roots; editor reads and writes are confined to them (Invariant 6, Decision 36)" with the typed path still in the field.
- `editor.saveAs.replacePrompt` — the Save-As field's "Replace <name>?" line's container (.contain, 3b-i, Rule 1): its text and two buttons. Read, not pressed — 3b-i-editor-save-as-replace.jsonl asserts "Replace replace-me.txt?" and its absence after Cancel; its buttons editor.saveAs.replace / .replaceCancel are pressed there.
- `editor.saving` — the saving tick (3b-i, Rule 5): a 2 pt shape drawn only while a write is in flight, which against the fixture's tiny files lasts milliseconds — never long enough for a tree read to see (git.loading's case). `saving` is asserted false after each save through read_pane; seeing the tick is the runbook's walk.
- `editor.saving.cancel` — the saving tick's Cancel (3b-i, Rule 4): a control that exists only while a write is in flight, which against the fixture lasts milliseconds — a press cannot land on it, and wakil-files writes through a temp file and a rename, so no fixture path can make a write wait. Cancelling a save is the runbook's walk.
- `editor.search.busy` — the search tick (3b-ii, Rule 5): a shape with no press action, drawn while a search is in flight. Read, not pressed — 3b-ii-search-cancel.jsonl reads the tree for its label, "searching", with no read_pane or other dispatch ending while the search runs (the regex switch is set on the empty query first, so typing starts the one search), so only the window's editor-flight redraw (final review C1) can draw it; it then presses the Cancel beside it, editor.search.cancel.
- `editor.search.cancelled` — the Search view's cancelled line's container (.contain, 3b-ii walk): the Text "search cancelled" and its Re-run, editor.search.rerunCancelled. Read, not pressed — 3b-ii-search-cancel.jsonl asserts "search cancelled" in the tree and search.cancelled through read_pane after Cancel, then presses Re-run and reads the search running again with cancelled cleared.
- `editor.search.error` — a Text (3b-ii, Rule 8): a search's error, drawn whole. Read, not pressed — 3b-ii-search-errors.jsonl asserts "missing closing )" in the tree and through read_pane, with the typed query kept.
- `editor.search.filesNote` — a Text (3b-ii): "only the first 50,000 files are searched", drawn only when a root's listing hit the cap. 50,000 files are not seeded (editor.tree.note:<…>'s reason); `files_truncated` is pinned by internal/wakilcore/files_test.go and WakilKitTests (EditorSearchActionsTests).
- `editor.search.noMatches` — a Text (3b-ii walk): "no matches", drawn under a finished search that found nothing. Display text with no press action. Read, not pressed — 3b-ii-search.jsonl asserts it in the tree after a search for a string no fixture file holds.
- `editor.search.note` — a Text (3b-ii): "only the first 2,000 matches are shown", drawn only over a search that hit the cap. 2,000 matches are not seeded; `truncated` is pinned by internal/wakilcore/files_test.go and WakilKitTests (EditorSearchActionsTests), and the note is the runbook's walk.
- `editor.tree.error:<…>` — a Text (3b-ii, Rule 8): a root's or a heavy folder's listing error, drawn whole under its row. Every fixture root lists and vendor loads, and no step can make one unreadable mid-launch; display text with no press action either way. Pinned by WakilKitTests (EditorTreeTests), and an unreadable root is the runbook's walk.
- `editor.tree.loading` — the tree's load tick (3b-ii, Rule 5): a shape drawn only while a root lists or a heavy folder loads, which against the fixture's small roots lasts milliseconds — never long enough for a tree read to see (git.loading's case). 3b-ii-tree-ignored-heavy.jsonl asserts what the load brings (autoload.php under vendor); seeing the tick is the runbook's walk.
- `editor.tree.note:<…>` — a Text (3b-ii): "only the first 50,000 files are listed", drawn only under a root whose listing hit the cap. The fixture's roots hold a few hundred files and seeding 50,000 per launch is not worth its minute; a note row is never selected or pressed. Its row is pinned by WakilKitTests (EditorTreeTests).
- `editor.unsaved` — the unsaved prompt's container (.contain, 3b-i): the message and three buttons. Read, not pressed — every prompt check asserts its message; its buttons editor.unsaved.save / .dontSave / .cancel are pressed by 3b-i-editor-close-keys.jsonl, 3b-i-editor-unsaved-save.jsonl and 3b-i-editor-unsaved-org-switch.jsonl.
- `editor.unsaved.message` — a Text (3b-i): the prompt's question. Read, not pressed — "Save changes to Untitled-2?" (3b-i-editor-close-keys.jsonl), "Save changes to kept.txt?" (3b-i-editor-unsaved-save.jsonl), "Unsaved changes in Untitled-1" (3b-i-editor-unsaved-org-switch.jsonl, 3b-i-editor-unsaved-quit.jsonl).
- `git.diff` — the Monaco host's container (3a-i): an NSViewRepresentable holding the WKWebView, with no press action of its own. 3a-i-git-drill.jsonl asserts the web view is mounted (`HTML content` in the tree); what it shows is the operator's ruling (§5 tones), not a check's.
- `git.diffBanner` — a Text (3a-i): `binary · 2.1 MB` or `file is 3.0 MB · first 2 MB shown`, drawn only over a binary or oversized diff. Display text with no press action; its wording is pinned by WakilKitTests banners and smallBinarySizes, and wakil-git's caps by its Go tests.
- `git.diffError` — a Text (3a-i): a diff's error, drawn whole. Display text with no press action; the fixture's diffs all load, and `diff.error` is asserted null by 3a-i-git-drill.jsonl.
- `git.diffHeader` — a Text (3a-i): `root / path · n of N · ↑↓`. Read, not pressed — 3a-i-git-drill.jsonl asserts it at 1, 2, 4 and 5 of 5, across both roots.
- `git.loading` — the load tick (3a-i, Rule 5): a 2 pt shape drawn only while a read or a diff is in flight, which against the fixture's tiny repositories lasts a few milliseconds — never long enough for a tree read to see. Pinned by WakilKitTests theClickedRowCarriesTheLoadingMarkUntilItsDiffArrives; seeing it is the runbook's walk.
- `git.pane` — the git pane's container (3a-i): it holds the list or the spine and diff, has no press action, and refuses AXFocused (measured: axresolve not_focusable) — its keyboard focus is SwiftUI's own, given when the pane is focused. What it draws is read by every 3a-i check; its rows are `git.row:…`.
- `git.root:<…>` — a Text (3a-i): a root's header, `e2e-api · main` or `e2e-git · not a git repository`. Read, not pressed — 3a-i-git-list.jsonl asserts both, and 3a-i-git-live.jsonl asserts `e2e-portal · main · clean` once the root empties.
- `git.rootError:<…>` — a Text (3a-i): the second and later lines of a root's error, drawn whole beneath its header — and only when the error HAS a second line. The fixture's non-repository error is one line, so it is never drawn; its split is pinned by WakilKitTests aLongErrorIsSplitBetweenTheHeaderAndTheLinesBeneath, and a multi-line error is the runbook's walk.
- `palette.error` — a Text (palette rework, rule 8): a run's error, drawn whole under the query line. Display text with no press action. Read, not pressed — palette-run-error.jsonl asserts "no entry in staging has that host" with the step and the typed line still there.
- `palette.plane` — the palette's container (.contain, palette rework): it holds the header, the query line, the rows and the footer, and takes no input itself — the dimmer around it takes the dismissing click. Its contents are read by every palette-*.jsonl check ("OPEN OR SWITCH TO", "RUN A COMMAND", the "N of M" count); the field inside it is palette.query, typed into, and its rows are palette.row.<id>, pressed.
- `palette.step` — a Text (palette rework): an input step's title, uppercased, where the mode's name was. Read, not pressed — palette-command-step.jsonl and palette-escape.jsonl assert "PANE KIND", palette-run-error.jsonl "CURL COMMAND", palette-switch-environment.jsonl "ENVIRONMENT", palette-table-row.jsonl a drill's "BOOKINGS"; palette-escape.jsonl asserts it gone after one Esc.
- `settings.capacity.strip` — the Settings capacity strip's scroll container (provider capacity), which takes no input. Its rows are read by capacity-low-reading.jsonl and capacity-passed-reset.jsonl, beside the accounts table's own CREDENTIAL and SIGN-IN headers.
- `settings.editor.autosave.refusal` — a Text (3b-v, Rule 8): drawn only when Go refuses an autosave mode the pane offers (off, pause, focus are each valid), which happens only over a settings.json that does not parse — no fixture or step can produce one (settings.editor.error's reason). Display text with no press action. 3b-v-editor-settings-nodes.jsonl drives all three modes and asserts each on disk.
- `settings.editor.error` — a Text (3b-v, Rule 8): settings.json's read or parse error, drawn only when ~/.wakil/settings.json cannot be read. The seed never writes that file, and no step can write it mid-launch — editor writes are confined to the active project's roots (Invariant 6, Decision 36) and ~/.wakil is outside them; display text with no press action either way. Its wording and the defaults it leaves in force are pinned by internal/wakilcore/editorsettings_test.go and WakilKitTests EditorSettingsTests; the runbook walks it with a hand-broken file.
- `settings.editor.wordWrap.refusal` — a Text (3b-v, Rule 8): drawn only when Go refuses a word-wrap write the pane itself offers (On or Off), and Go refuses a boolean only when settings.json does not parse — which, as for settings.editor.error, no fixture or step can produce. Display text with no press action. 3b-v-editor-settings-nodes.jsonl drives both choices and asserts each write on disk.
- `settings.login.cancel` — #254. Only exists while a browser trip is in flight.
- `settings.login.dismiss` — #254. Drawn only by the states a finished trip reaches — added, refused, cancelled, timedOut, uncertain, failed.
- `settings.login.someoneElse` — #254. Starts a fresh trip, and only appears when the config dir is already signed in, which itself needs a real credential.
- `settings.login.start` — #254. The control that does the above.
- `settings.mint.stopWaiting` — #254. Only exists while waiting on a live mint.
- `settings.org.speechProvider.note` — a Text: the Speech row's "unknown engine 'x', using Apple". Read, not pressed — 2d-ii-settings-speech.jsonl asserts it after a dispatched unknown id and a reload, and its absence after Apple is chosen.
- `settings.projectEditor.indent.refusal` — a Text (3b-v, Rule 8): drawn only when Go refuses Spaces or Tabs, which it does only for a project.json filed under another organisation or unreadable — and either one drops the project from the settings tree, so its Editor node draws `gone` instead of this form and the refusal has nowhere to appear. Display text with no press action. 3b-v-project-editor-settings.jsonl drives both choices (Tabs through parity) and asserts each on disk.
- `settings.row.<…>.reauthenticate` — #254. Goes straight to the browser by design — no confirmation step — so pressing it IS starting a real trip.
- `window.capacity` — the capacity indicator beside ACCOUNT (provider capacity): it has no press action, and it refuses AXFocused (measured 2026-10-10: axresolve not_focusable), because `.focusable(interactions: .activate)` keeps a click from taking the composer's focus (Rule 6) and joins the key loop only with macOS Keyboard navigation on. Its card opens on hover or on that focus, and the vocabulary has no hover step, so opening the card is walk-only. What it draws is read by capacity-at-launch.jsonl (the launch probe, no turn), capacity-low-reading.jsonl, capacity-passed-reset.jsonl and agent/capacity-after-turn.jsonl.
- `window.composer.bar` — the composer bar's container (.contain), which holds the field, the heard text and the hint and takes no input itself. Its contents are read by every 2d-ii voice check; the field inside it is `window.composer`, which they type into.
- `window.composer.heard` — a Text: the words heard while ⌥ is held, or the notice that replaces them. Read, not pressed — 2d-ii-voice-silence.jsonl asserts "Hearing nothing from E2E Microphone" and the words that clear it; 2d-ii-voice-lands-unsent.jsonl and 2d-ii-voice-escape.jsonl assert the words mid-hold.
- `window.composer.hint` — a Text: the bar's hint. Read, not pressed — the keys hint ("TO SPEAK"), the listening hint ("RELEASE TO PUT IT IN THE LINE") and the landed hint ("HEARD · RETURN SENDS · EDIT FIRST") are asserted by the 2d-ii voice checks.
- `window.thread` — the thought thread's container (.contain), which takes hits only on its rows and the "earlier" line. Its rows are pressed by 2d-ii-thread-earlier.jsonl as window.thread.row.<id> and window.thread.earlier.

**This section knows nothing about what a machine cannot see.** The visual rulings and the live-provider question stay the operator's, permanently; they are the human section below.

<!-- /machine-walk -->
