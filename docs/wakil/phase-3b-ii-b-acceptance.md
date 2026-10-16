# 3b-ii-b — replace across the project, reveal, moving tabs: acceptance

**Spec:** [`2026-10-14-3b-ii-b-editor-replace-tabs-design.md`](../superpowers/specs/2026-10-14-3b-ii-b-editor-replace-tabs-design.md) ·
**Plan:** [`2026-10-14-3b-ii-b-editor-replace-tabs.md`](../superpowers/plans/2026-10-14-3b-ii-b-editor-replace-tabs.md)

**Not yet walked.**

The exit criterion, from the spec: replace across the project with open tabs safe and one undo,
reveal the open file, move and middle-click-close tabs — all of it drivable by the agent.

The decisions behind it are Decision 39 (a replace across many files is Decision 36's file write,
one file at a time: *allow*, never writing a file open in a tab, one in-memory undo guarded by each
file's modification time) and design-language §11 (the left column's Replace, the reveal button,
tabs moved by dragging and closed on a middle-click).

## 0. Setup

A project's roots are the `"roots"` array of its `project.json`, read at launch and on a project
switch, not live. Run this in the repo root, on this Mac, after `make build` and `make app-bundle`.
It is safe to re-run. Set `ORG` to one you have registered (`./bin/wakil org list`).

```bash
set -e
ORG=initech   # the org to walk under; initech or umbrella
cd /Users/operator/Desktop/scripts/wakil
rm -rf /tmp/walk-replace /tmp/walk-replace-project
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
G="git -c user.name=walk -c user.email=walk@example.com"
mkdir -p /tmp/walk-replace/api /tmp/walk-replace/portal /tmp/walk-replace-project
cd /tmp/walk-replace/api && git init -q -b main
printf '.env\n' > .gitignore; echo 'bookingId=walk' > .env
mkdir -p app/Models && echo '<?php $bookingId = 1;' > app/Models/Booking.php
mkdir -p big && for i in $(seq -w 1 200); do yes 'lorem ipsum dolor sit amet' | head -c 1048576 > big/$i.txt; done
echo 'replace-marker-qz7' > big/zz-marker.txt
git add . && $G commit -qm init
cd /tmp/walk-replace/portal && git init -q -b main
mkdir -p src && echo 'const bookingId = 2;' > src/routes.ts
echo 'const bookingId = 3;' > src/a.ts && echo 'const bookingId = 4;' > src/b.ts
git add . && $G commit -qm init
cat > /tmp/walk-replace-project/project.json <<J
{"name":"walk-replace","org":"$ORG","roots":[{"path":"/tmp/walk-replace"}],"scopes":{},"environments":{}}
J
cd /Users/operator/Desktop/scripts/wakil
./bin/wakil project rm walk-replace --org "$ORG" || true
./bin/wakil project add walk-replace --path /tmp/walk-replace-project/project.json --org "$ORG"
```

`api/.env` is gitignored, so a replace never touches it. `api/big/` is 200 MiB of committed text
(200 files of 1 MiB): a regex with no literal prefix makes a replace run for seconds, long enough
to press Cancel (row 5); `big/zz-marker.txt`, sorted last, is its one match.

Launch `WAKIL_ORG=initech app/Wakil.app/Contents/MacOS/Wakil` (or `umbrella`), then make the project
active with the project switcher (⌘P, choose `walk-replace`). Registering does not select it.

## 1. The walk

Walk in order, in an agent-answering organisation, on the project `walk-replace` from §0.

| # | Do | Expect |
|---|---|---|
| 1 | ⌘T; ⌘P `Booking.php`, type a character in it. ⌘⇧F `bookingId`; press ▸, type `booking_id` (no Enter); then clear the field | The Replace field has the keyboard as soon as it opens. After a pause each result shows `bookingId` struck through and `booking_id` in violet; `.env` is not among them. Cleared, each shows the match struck through only |
| 2 | Type `booking_id` again; press **Replace All** | The tick and Cancel flash; *Replaced 4 in 4 files · Undo replace*. The Search view re-runs and lists only `Booking.php:1` (its file). `Booking.php`'s tab is dirty and reads `booking_id`; ⌘Z there takes it back whole. In a terminal, `cat /tmp/walk-replace/portal/src/*.ts` shows `booking_id` three times and `git -C /tmp/walk-replace/api status --short` shows nothing |
| 3 | In a terminal: `echo '// mine' >> /tmp/walk-replace/portal/src/b.ts`. Press **Undo replace** | *Undid the replace in 2 files*, and `…/b.ts: changed since the replace — left as it is` under it. `cat` shows `routes.ts` and `a.ts` back to `bookingId`, `b.ts` as left. Undo replace is gone |
| 4 | Switch on `.*`; query `const (\w+)`, Replace `let $1`. Hover `routes.ts`'s group and press **Replace in this file**. Then press ↓ from the query until an `a.ts` result is selected, without hovering, and look at `a.ts`'s group | The preview showed `let bookingId` in violet before the press. Only `routes.ts` becomes `let bookingId = 2;`; `a.ts` and `b.ts` are untouched. The button shows on the hovered group, and on `a.ts`'s group while its result is selected; on no other group |
| 5 | Query `\w+-qz\d` (still `.*`), Replace `x`; when `zz-marker.txt` is listed, press **Replace All** and then **Cancel** while *replacing* shows | It stops within a moment: *Replace cancelled · replaced …*; anything written is undoable. `git -C /tmp/walk-replace/api status --short` matches what the line says |
| 6 | ⌘B; collapse `walk-replace`; ⌘P `Booking.php`; press the Files header's reveal button. Collapse again; ⌘K *Reveal Active File in Tree*. Then ⌘T and hover the button | The folders open, `Booking.php`'s row is selected and scrolled into view, and typing still goes into the file. ⌘K does the same. With the scratch in front the button is dimmed, its tooltip says there is nothing to reveal, and ⌘K does not offer the command |
| 7 | Single-click `routes.ts` in the tree, then double-click its tab. Open `a.ts` and `b.ts`; click each tab in turn; close one with its ×. Reopen it; drag the first tab past the last; drag one up out of the strip and let go. Quit (Don't Save for `Booking.php`) and relaunch | The single click opens an italic preview tab; the double-click keeps it (not italic). A click on a tab shows it; × closes it. While dragging, a violet line marks the drop; the tab lands there and the active tab stays active. The drag out of the strip changes nothing. After the relaunch the order is as left |
| 8 | ⌘T until the tab strip scrolls; scroll it to the right end. Middle-click a clean tab; type in another and middle-click it | The tab under the pointer closes at once — the one clicked, not the one at that place before the scroll. The dirty one asks *Save changes to …?* with Save / Don't Save / Cancel |
| 9 | Ask the agent "replace bookingId with booking_ref across the project", then "undo that replace" | A result line and an Undo; neither moves the keyboard |

## 2. Residue — what the walk cannot establish

- **The undo is in memory** (Decision 39): a relaunch drops it; nothing keeps it.
- **Only the latest replace undoes**, and buffer edits are ⌘Z's in their tab.
- **The preview covers the 2,000 shown lines**; Replace All replaces past them, which no fixture here
  reaches.
- **Moving a tab between panes** is not part of 3b-ii-b.

## 3. Residue — what Cover could not reach, and why

Written by the e2e auditor (Cover rung). Six checks, `e2e/checks/seeded/3b-ii-b-*.jsonl`, over the
git project's seed (and, for the replace-Cancel check's launch only, the committed `bulk/` haystack
with its one marker line, `bulk/zz-marker.txt`). They cover all four new actions —
`editor_tree_reveal` with a parity step; `editor_replace`, `editor_replace_undo` and
`editor_move_tab` down both channels in separate steps, excused from parity in
`uncoverable.tsv` because each click consumes its own subject — and every new control but those
below. What they cannot reach:

- **Middle-click** (row 8): the harness posts no middle button, and the strip's one
  event monitor has no accessibility action, so it has no identifier and no check. Both halves of
  what it does are covered elsewhere: `closeEditorTab` by
  `WindowModelEditorTests.aMiddleClickClosesACleanTabAndAsksAboutADirtyOne`, and the walk
  middle-clicks a clean tab and a dirty one after the strip scrolls.
- **The order after a relaunch** (row 7): one check is one launch; `aMovedOrderComesBackOnRestore`
  pins the saved order.
- **The tab drag** is `3b-ii-b-tab-move.jsonl`'s synthetic drag; if the controller's measured run
  shows it not moving a `DragGesture` tab, the drag is excused with the measurement and row 7 walks it.
- **Cancel on a replace** (`editor.replace.cancel`, Rule 4): pressed by `3b-ii-b-replace-cancel.jsonl`
  against the haystack; if the measured run shows the replace finishing before the press lands, the
  check is dropped and the control excused on `editor.saving.cancel`'s precedent, and row 5 walks it.
- **The tick and drawn text** (`editor.replace.busy`, `editor.replace.result`,
  `editor.replace.failure`): read, not pressed — `replacing`, *Replaced 3 in 3 files* and the
  changed-since line are asserted in the tree.
- **Two coordinate-space names** (`editor.tabs`, `editor.strip`): the identifier harvest reads them
  as controls; they are not in the accessibility tree.
- **The visual rulings**: strike-through, violet, the drop line, the selected revealed row, the
  Replace field taking the keyboard, the disabled reveal button's tooltip (rows 1, 4, 6, 7).
- **The agent in the loop** (row 9): the checks dispatch the same actions over the same socket; that
  a real model chooses them is the operator's.

## 4. The machine walk

Rendered by `make e2e-runbook` after the Cover rung. Nothing is written here by hand.

<!-- machine-walk: generated by `make e2e-runbook`; everything between these markers is overwritten -->

**The machine walk is green:** every check ran against this build, every check this branch added was seen to fail against the merge-base, and the surface it added carries checks.

Walked by `make e2e` against ecb8a3459760, rendered 2026-10-14 19:28 UTC by `make e2e-runbook`. Re-render it with that target; edits between the markers are overwritten.

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
| `3b-ii-b-replace-all.jsonl` | ✓ exit 0 | ✓ red vs 5c38f72852bf | 22 | — |
| `3b-ii-b-replace-cancel.jsonl` | ✓ exit 0 | ✓ red vs 5c38f72852bf | 11 | — |
| `3b-ii-b-replace-file.jsonl` | ✓ exit 0 | ✓ red vs 5c38f72852bf | 17 | — |
| `3b-ii-b-replace-undo.jsonl` | ✓ exit 0 | ✓ red vs 5c38f72852bf | 18 | — |
| `3b-ii-b-reveal.jsonl` | ✓ exit 0 | ✓ red vs 5c38f72852bf | 11 | — |
| `3b-ii-b-tab-move.jsonl` | ✓ exit 0 | ✓ red vs 5c38f72852bf | 9 | — |
| `3b-ii-find.jsonl` | ✓ exit 0 | ✓ red vs 8e8ec7d29e7f, recorded 2026-10-14 | 8 | — |
| `3b-ii-palette-ignored.jsonl` | ✓ exit 0 | ✓ red vs 8e8ec7d29e7f, recorded 2026-10-14 | 6 | — |
| `3b-ii-refusals.jsonl` | ✓ exit 0 | ✓ red vs 8e8ec7d29e7f, recorded 2026-10-14 | 5 | — |
| `3b-ii-search-cancel.jsonl` | ✓ exit 0 | ✓ red vs 8e8ec7d29e7f, recorded 2026-10-14 | 12 | — |
| `3b-ii-search-errors.jsonl` | ✓ exit 0 | ✓ red vs 8e8ec7d29e7f, recorded 2026-10-14 | 9 | — |
| `3b-ii-search.jsonl` | ✓ exit 0 | ✓ red vs 8e8ec7d29e7f, recorded 2026-10-14 | 43 | — |
| `3b-ii-tree-ignored-heavy.jsonl` | ✓ exit 0 | ✓ red vs 8e8ec7d29e7f, recorded 2026-10-14 | 9 | — |
| `3b-ii-tree-live.jsonl` | ✓ exit 0 | ✓ red vs 8e8ec7d29e7f, recorded 2026-10-14 | 11 | — |
| `3b-ii-tree-preview.jsonl` | ✓ exit 0 | ✓ red vs 8e8ec7d29e7f, recorded 2026-10-14 | 19 | — |
| `3b-ii-tree-toggle.jsonl` | ✓ exit 0 | ✓ red vs 8e8ec7d29e7f, recorded 2026-10-14 | 14 | — |
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

**`make e2e-new` saw every check this branch added go red against 5c38f72852bf.**

**Every action and control this branch added carries a check.** 4 action(s) and 12 control(s) are new on this branch.

- actions:  58 of 100 dispatched by a check
- writes:   18 of 70 carry a parity check
- controls: 109 of 193 exercised by a check

**83 piece(s) of surface no check can reach**, each with the reason given in `e2e/checks/uncoverable.tsv`:

- `editor_select` — its parity (3b-i): no operator control — the operator selects inside Monaco, the one non-action path, so no UI half exists. The dispatch is covered by most 3b-i-editor-* checks, which read selected_text back to prove what a save wrote.
- `git_step` — its parity (3a-i): the operator's channel is ↑↓ with the diff open — keys, not a click or a drag — so the UI half of a parity step cannot be expressed, on api_fill_from_curl's precedent. The dispatch is covered by 3a-i-git-drill.jsonl (across roots, both directions, asserting the selection and the header through read_pane and the tree). The keyboard half is 3a-i-git-keys.jsonl: ↑↓ folded, across both roots, asserting the selection through read_pane.
- `db_remove_database` — its parity: the click removes the database, and removing one that is gone is refused (`no database … in environment …`), so the dispatch half cannot be given the same params. Dispatch is covered by 2e-settings-databases-dispatch.jsonl and the click by 2e-settings-databases.jsonl; what no check can express is the comparison.
- `editor_close` — its parity (3b-i): the operator's channels are ⌘W (a key) and the unsaved prompt's Don't Save, and the click consumes its own subject — the dispatch half after it would close a different tab or be refused (`the editor pane has no open tab`), api_cancel's case. Both channels ARE covered: 3b-i-editor-close-keys.jsonl (⌘W clean, ⌘W dirty → Esc / Cancel / Don't Save) and the dispatch with and without discard in 3b-i-editor-refusals.jsonl.
- `ctx_add_provider` — its parity: the click creates a binding under an id, so a dispatch with the same params collides with what the click just made. Covered by 2e-settings-doors.jsonl up to the browser leg.
- `editor_replace_range` — its parity (3b-i): no operator control — the operator's own edits are typing in Monaco, the one non-action path (`editorBufferDidChange`), so no UI half exists. The dispatch is covered by most 3b-i-editor-* checks, and its read-only refusal by 3b-i-editor-read-only.jsonl.
- `editor_goto` — its parity (3b-i): there is no operator control for it — the operator moves the cursor inside Monaco, the one non-action path (design-language §11), so no UI half exists to compare, on git_fold's precedent. The dispatch is covered by 3b-i-editor-tabs-language.jsonl (cursor.line and cursor.column through read_pane) and refused on an empty pane in 3b-i-editor-refusals.jsonl.
- `ctx_unlink_provider` — its parity: the click removes the binding, so the dispatch half cannot be given the same id. Dispatch and both channels' behaviour ARE covered by 2e-settings-unlink.jsonl; what no check can express is the comparison.
- `api_undo_fill` — its parity: the Undo click forgets the fill it undoes, and api_undo_fill refuses a pane with nothing to undo, so the dispatch half cannot be given the same state after the click — and a second fill between the halves is not expressible inside one parity step. Both channels ARE covered by api-paste-curl.jsonl, the click after one fill and the dispatch after another, each asserting the same restored draft through read_pane; what no check can express is the comparison.
- `editor_replace_undo` — its parity (3b-ii-b): the Undo click spends the pane's one undo, and the dispatch after it is then refused (`no replace to undo`) — api_undo_fill's case. The click is 3b-ii-b-replace-undo.jsonl's (undone, restored 2, and the changed-since line for the file changed on disk), and so is the refusal of the dispatch after it.
- `editor_restore` — its parity (3b-i): no operator control — it runs when a window relaunches onto saved tabs, and one check is one launch. The dispatch is covered by 3b-i-editor-disk-changed.jsonl (an open, dirty tab is kept as it is); restoring after a relaunch is the runbook's row 9.
- `api_unbind` — its parity: the click returns the binding to its hole, and api_unbind refuses a position that holds no binding (`unbindNotABinding`), so the dispatch half cannot be given the same params — and a re-drag between the halves is not expressible. Both channels ARE covered by api-unbind.jsonl, each after its own drag, asserting the same hole back through read_pane; what no check can express is the comparison.
- `api_fill_from_curl` — its parity: the UI half of a parity step is a click or a drag, and the operator's channel is a paste (cmd+v into the path editor), so the comparison cannot be expressed. Both channels ARE covered: the dispatch by api-paste-curl.jsonl, the paste by api-paste-curl-hotkey.jsonl, each asserting the same draft and the Filled from cURL line; what no check can express is the comparison.
- `capacity_record` — its parity: the operator's channel is the agent's own stream — the window records a `rate_limit_event` frame from a turn on its own, with no click or drag — so the UI half of a parity step cannot be expressed, on git_fold's precedent. Both channels ARE covered: the dispatch by capacity-low-reading.jsonl and capacity-passed-reset.jsonl, the stream by agent/capacity-after-turn.jsonl, each asserting the reading it lands on the indicator; what no check can express is the comparison.
- `api_reopen` — its dispatch: it needs a row id, which is minted per send and published only in read_pane — the same reason api_render_curl below is here. The operator's gesture IS covered: api-recent.jsonl presses api.recent.0.reopen and asserts the draft it rebuilds. Permanent, not blocked: nothing in the vocabulary carries a value from read_pane into a dispatch.
- `editor_open` — its parity (3b-i): the operator's channel is ⌘P — typing and Return — and a file row's identifier carries this launch's absolute path (`palette.row.editorfile:<root>/<rel>`), while `{fixtureRoot}` expands only in dispatch and parity params, never in a click. So no UI half can name the row. The dispatch is covered by every 3b-i-editor-* check that opens a file; the operator's gesture by 3b-i-editor-files-palette.jsonl (⌘P, the file's name, Return, asserting the tab and its text through read_pane).
- `git_fold` — its parity (3a-i): there is no operator control for it at all — GitPane folds only by selecting, so git_fold is the agent's alone and no UI half exists to compare. The dispatch is covered by 3a-i-git-drill.jsonl (fold again, the same file and position).
- `editor_new_scratch` — its parity (3b-i): the operator's channel is ⌘T, a menu key equivalent — a key, not a click or a drag — on git_step's precedent; the empty pane only names the key. The dispatch is covered by most 3b-i-editor-* checks; ⌘T by 3b-i-editor-scratch-save.jsonl and 3b-i-editor-close-keys.jsonl, asserting the Untitled-N tab through read_pane.
- `settings_open` — its parity: the only UI path is the `Settings…` MENU item, and a menu's buttons are not in the accessibility tree until the menu is open — the same rule that excuses every other menu control. Checks drive it by its real gesture, cmd+comma, and 2e-settings-pane.jsonl also dispatches it.
- `ctx_provider_login` — #254. Opens a browser on the operator's machine and authenticates as them. No harness can drive it and none should: every run would leave a real credential behind.
- `editor_move_tab` — its parity (3b-ii-b): the drag moves a tab, and the same {from, to} dispatched on the moved strip moves a different tab, so the two halves cannot read back the same order. The drag and the dispatch are each 3b-ii-b-tab-move.jsonl's, each asserting the strip's order and the active tab through read_pane.
- `git_unfold` — its parity (3a-i): the operator's channel is Esc — a key, not a click or a drag — so the UI half of a parity step cannot be expressed. The dispatch is covered by 3a-i-git-drill.jsonl (unfold keeps the selection, the list is back). The keyboard half is 3a-i-git-keys.jsonl: Esc unfolds with the same file selected.
- `editor_replace` — its parity (3b-ii-b): the click replaces, and the same dispatch after it finds nothing left to replace and answers a different last_replace, so the two halves cannot read back the same pane (api_cancel's case: the click consumes its own subject). Both channels ARE covered: the click (Replace All) by 3b-ii-b-replace-all.jsonl and the dispatch by 3b-ii-b-replace-undo.jsonl, each asserting last_replace's files and the Replaced … line; Replace in this file by 3b-ii-b-replace-file.jsonl, and Cancel by 3b-ii-b-replace-cancel.jsonl.
- `api_cancel` — its parity: the click cancels the send in flight, and api_cancel refuses a pane with nothing in flight (`nothingInFlight`), so the dispatch half cannot be given the same state — and a second Send between the halves is not expressible. Both channels ARE covered by api-cancel.jsonl, each after its own Send, asserting the same cancelled response through read_pane; what no check can express is the comparison.
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
- `editor.replace.busy` — the replace tick (3b-ii-b, Rule 5): a shape with no press action, drawn while a replace or its undo is in flight (editor.search.busy's case). Read, not pressed — 3b-ii-b-replace-cancel.jsonl reads the tree for its label, "replacing", while the replace walks the 200 MiB haystack, then presses the Cancel beside it, editor.replace.cancel.
- `editor.replace.failure` — a Text (3b-ii-b, Rule 8): one file the replace or its undo could not write or put back, drawn whole. Read, not pressed — 3b-ii-b-replace-undo.jsonl asserts "changed since the replace — left as it is" in the tree for the file changed on disk after the replace.
- `editor.replace.result` — the replace's result line's container (.contain, 3b-ii-b): the summary Text, Undo replace (editor.replace.undo, pressed) and the failures under it. Read, not pressed — 3b-ii-b-replace-all.jsonl asserts "Replaced 3 in 3 files" in the tree and last_replace through read_pane; 3b-ii-b-replace-undo.jsonl asserts "Undid the replace in 2 files".
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
- `editor.strip` — not a control (3b-ii-b): the name of a SwiftUI coordinate space (`.coordinateSpace(name: "editor.strip")`, the visible tab strip's, where the middle-click converts a click), not an accessibility identifier — editor.tabs's case. Nothing in the accessibility tree carries it. The middle-click itself is walk-only: the harness posts no middle button (runbook row 8).
- `editor.tabs` — not a control (3b-ii-b): the name of a SwiftUI coordinate space (`.coordinateSpace(name: "editor.tabs")`, the tab strip's, which the drop target and the middle-click measure in), not an accessibility identifier. The harvest reads any `editor.…` literal; nothing in the accessibility tree carries this name, so no check can press or read it. The strip's tabs are editor.tab.<…>, dragged by 3b-ii-b-tab-move.jsonl.
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
