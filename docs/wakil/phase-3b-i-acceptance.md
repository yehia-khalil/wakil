# 3b-i — the editor core: acceptance

**Spec:** [`2026-10-11-3b-i-editor-core-design.md`](../superpowers/specs/2026-10-11-3b-i-editor-core-design.md) ·
**Plan:** [`2026-10-11-3b-i-editor-core.md`](../superpowers/plans/2026-10-11-3b-i-editor-core.md)

**Walked 2026-10-12 by the operator, against 30b6bff1: all ten rows pass.** Row 5's second save was corrected during the walk: it now targets `third.txt`, because a path already open in the pane is refused by design (`editor_save`), not asked about.

The exit criterion, from the spec: open a file from ⌘P, edit and save it, drive the same editor
through the agent, and lose no edit: an unsaved tab asks before a close, a pane, an organisation
switch or a quit drops it, and a file changed on disk is never overwritten quietly.

**One deviation from the spec, operator-visible.** *Compare* is a diff view **inside the pane**,
closed with Esc, not a tab of its own (design-language §11). Row 6 walks it as built.

The decisions behind the one new write are Decision 36 and Invariant 6's 2026-10-11 entry.

## 0. Setup

A project's roots are the `"roots"` array of its `project.json`, read at launch and on a project
switch, not live. Run this in the repo root, on this Mac, after `make build` and `make app-bundle`.
It is safe to re-run. Set `ORG` to one you have registered (`./bin/wakil org list`).

```bash
set -e
ORG=initech   # the org to walk under; initech or umbrella
cd /Users/operator/Desktop/scripts/wakil
rm -rf /tmp/walk-edit /tmp/walk-edit-project
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
G="git -c user.name=walk -c user.email=walk@example.com"
mkdir -p /tmp/walk-edit /tmp/walk-edit-project
cd /tmp/walk-edit && git init -q -b main
{ echo 'package main'; echo; echo 'var bookingId = 1'; for i in $(seq 4 60); do echo "// line $i"; done; } > config.go
echo 'one' > notes.txt; echo 'two' > other.txt; echo 'three' > third.txt
git add . && $G commit -qm init
cat > /tmp/walk-edit-project/project.json <<J
{"name":"walk-edit","org":"$ORG","roots":[{"path":"/tmp/walk-edit"}],"scopes":{},"environments":{}}
J
cd /Users/operator/Desktop/scripts/wakil
./bin/wakil project rm walk-edit --org "$ORG" || true
./bin/wakil project add walk-edit --path /tmp/walk-edit-project/project.json --org "$ORG"
```

Launch `WAKIL_ORG=initech app/Wakil.app/Contents/MacOS/Wakil` (or `umbrella`), then make the project
active with the project switcher (⌘P, choose `walk-edit`). Registering does not select it.

## 1. The walk

Walk in order, in an agent-answering organisation, on the project `walk-edit` from §0. **Monaco has
focus for every keystroke below**, so each ⌘ key is also a check that the editor does not swallow it.

| # | Do | Expect |
|---|---|---|
| 1 | ⌘P, type `confgo`, Return. Then press ⌘K, ⌘P and ⌘T once each (Esc out of each) while the cursor is in the text. Switch to an Arabic keyboard layout and press ⌘K once more | `config.go` opens in a new editor pane, focused, highlighted as Go. ⌘K, ⌘P and ⌘T open their own surfaces and are not typed into the file, on both layouts |
| 2 | Type a character, then ⌘S | The dirty dot appears, then clears; no dialog; `cd /tmp/walk-edit && git diff` shows the change |
| 3 | Ask the agent "go to line 40 and select that line" | The cursor moves to 40 and the line is selected |
| 4 | Ask the agent to rename `bookingId` on screen | The edit appears, the tab is dirty, ⌘Z undoes it. Typing in the file afterwards does not lose the agent's edit |
| 5 | ⌘T, type `select 1`, ⌘K → *Set language…* → SQL, ⌘S. The path field appears: type `/tmp/walk-edit/q.sql`, Return. Then ⌘T, type `x`, ⌘S, `/tmp/walk-edit/third.txt`, Return, then Replace | The field takes focus from Monaco, so typing lands in it. The tab becomes `q.sql` and `git status` lists it as untracked. The second save asks *Replace third.txt?* inline before writing, and the tab becomes `third.txt`. (A path already open in the pane, such as `q.sql`, is refused instead: two tabs of one file) |
| 6 | Make the `config.go` tab dirty, then in a terminal `echo x >> /tmp/walk-edit/config.go`. Press Compare, then Esc. Press Compare again and press Reload | *"changed on disk"* with Reload and Compare. Compare draws both texts as a diff inside the pane, not a tab; Esc closes it and the tab is as it was. Reload takes the disk's text |
| 7 | Clean tab on `notes.txt`; in a terminal, `echo y >> /tmp/walk-edit/notes.txt` | The tab reloads in place; cursor and scroll stay |
| 8 | Dirty a tab, ⌘W; press Esc; ⌘W again, then Don't Save. Dirty a tab again and press ⌘Q; Esc. Dirty it again, minimise the window, press ⌘Q (Wakil from the Dock menu), then restore the window and press Return. Do the same with the window's red close button | *Save changes?* appears each time and takes the keyboard from Monaco: Esc is Cancel and keeps the tab, Return is Save, Don't Save closes the tab. ⌘Q and the close button ask too, also while the window is minimised |
| 9 | Open `config.go`, `notes.txt` and `other.txt`, scroll and move the cursor in each, quit (clean), relaunch | The three tabs are back, cursor and scroll where they were |
| 10 | Ask the agent to open `/etc/hosts` | Refused, naming Invariant 6 and Decision 36 |

## 2. Residue — what the walk cannot establish

- **A real Arabic input source's own shortcuts** are walked on one layout switch only (row 1);
  other layouts and input methods are untested.
- **Delete, rename and move** are refused by Decision 36 and have no control; nothing to walk.
- **The Git pane's fold into the editor** is 3b-iii; Git still opens its own pane.
- **Dirty tabs left in another project or conversation** are listed by ⌘Q and an org switch with
  Don't Save and Cancel only (Save would write outside an action, or jump scope). WakilKit tests
  (`WindowModelUnsavedScopesTests`) cover it; switch to that scope to save them.

## 3. Residue — what Cover could not reach, and why

Written by the e2e auditor (Cover rung). Eleven checks, `e2e/checks/seeded/3b-i-editor-*.jsonl`,
cover every new action, every editor control but one, and Rules 1, 2, 3, 6, 7 and 8. What they
cannot reach:

- **Rule 5, the saving tick** (`editor.saving`): a fixture write lasts milliseconds, so no read
  sees the tick, and a second ⌘S during a save cannot be timed. `saving` is asserted false after
  each save. Walk it on a slow disk if anywhere.
- **Rule 4, Cancel on a save** (`editor.saving.cancel`): exists only while a write is in flight;
  wakil-files writes through a temp file and a rename, so no fixture path makes a write wait.
- **⌘K, ⌘P and ⌘T under an Arabic layout** (row 1): the harness sends US key codes. The checks
  do press ⌘T, ⌘S, ⌘W, ⌘K and ⌘Z with Monaco focused, on the US layout.
- **The red close button and a minimised window's ⌘Q** (row 8): the window's own buttons carry
  no identifier in a registered surface, and minimising is not an act. ⌘Q's prompt with Esc and
  Return is checked; a quit that goes through is not, because it would end the run.
- **Relaunch restore** (row 9): one check is one launch. `editor_restore` is dispatched and keeps
  an open, dirty tab as it was; tabs, cursors and scroll coming back after a relaunch are walked.
- **Highlighting, Compare's diff and typing feel** (rows 1, 6): visual. The checks assert the
  language id and that Compare opens and closes (button and Esc), not what Monaco draws.
- **The agent in the loop** (rows 3, 4, 10): the checks dispatch the same actions over the same
  socket; that a real model chooses them is the operator's.
- **Compare that cannot read the file** (`editor.compare.failure`): the fixture's files are always
  readable.
- **Parity for seven actions** (`uncoverable.tsv` §1): editor_open's ⌘P row names a per-launch
  path; ⌘T and ⌘W are keys; editor_close consumes its tab; goto, select, replace_range and restore
  have no operator control. Each channel is checked on its own.

## 4. The machine walk

Rendered by `make e2e-runbook` after the Cover rung. Nothing is written here by hand.

<!-- machine-walk: generated by `make e2e-runbook`; everything between these markers is overwritten -->

**The machine walk is green:** every check ran against this build, every check this branch added was seen to fail against the merge-base, and the surface it added carries checks.

Walked by `make e2e` against 20192da7ac00, rendered 2026-10-12 20:18 UTC by `make e2e-runbook`. Re-render it with that target; edits between the markers are overwritten.

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
| `3b-i-editor-close-keys.jsonl` | ✓ exit 0 | ✓ red vs 0c9e85c6f259 | 25 | — |
| `3b-i-editor-disk-changed.jsonl` | ✓ exit 0 | ✓ red vs 0c9e85c6f259 | 34 | — |
| `3b-i-editor-files-palette.jsonl` | ✓ exit 0 | ✓ red vs 0c9e85c6f259 | 13 | — |
| `3b-i-editor-read-only.jsonl` | ✓ exit 0 | ✓ red vs 0c9e85c6f259 | 10 | — |
| `3b-i-editor-refusals.jsonl` | ✓ exit 0 | ✓ red vs 0c9e85c6f259 | 24 | — |
| `3b-i-editor-save-as-field.jsonl` | ✓ exit 0 | ✓ red vs 0c9e85c6f259 | 24 | — |
| `3b-i-editor-save-as-replace.jsonl` | ✓ exit 0 | ✓ red vs 0c9e85c6f259 | 16 | — |
| `3b-i-editor-scratch-save.jsonl` | ✓ exit 0 | ✓ red vs 0c9e85c6f259 | 27 | — |
| `3b-i-editor-tabs-language.jsonl` | ✓ exit 0 | ✓ red vs 0c9e85c6f259 | 22 | — |
| `3b-i-editor-unsaved-org-switch.jsonl` | ✓ exit 0 | ✓ red vs 0c9e85c6f259 | 10 | — |
| `3b-i-editor-unsaved-quit.jsonl` | ✓ exit 0 | ✓ red vs 0c9e85c6f259 | 11 | — |
| `3b-i-editor-unsaved-save.jsonl` | ✓ exit 0 | ✓ red vs 0c9e85c6f259 | 16 | — |
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

**`make e2e-new` saw every check this branch added go red against 0c9e85c6f259.**

**Every action and control this branch added carries a check.** 12 action(s) and 25 control(s) are new on this branch.

- actions:  45 of 87 dispatched by a check
- writes:   10 of 59 carry a parity check
- controls: 82 of 148 exercised by a check

**62 piece(s) of surface no check can reach**, each with the reason given in `e2e/checks/uncoverable.tsv`:

- `editor_goto` — its parity (3b-i): there is no operator control for it — the operator moves the cursor inside Monaco, the one non-action path (design-language §11), so no UI half exists to compare, on git_fold's precedent. The dispatch is covered by 3b-i-editor-tabs-language.jsonl (cursor.line and cursor.column through read_pane) and refused on an empty pane in 3b-i-editor-refusals.jsonl.
- `git_fold` — its parity (3a-i): there is no operator control for it at all — GitPane folds only by selecting, so git_fold is the agent's alone and no UI half exists to compare. The dispatch is covered by 3a-i-git-drill.jsonl (fold again, the same file and position).
- `ctx_provider_login` — #254. Opens a browser on the operator's machine and authenticates as them. No harness can drive it and none should: every run would leave a real credential behind.
- `api_cancel` — its parity: the click cancels the send in flight, and api_cancel refuses a pane with nothing in flight (`nothingInFlight`), so the dispatch half cannot be given the same state — and a second Send between the halves is not expressible. Both channels ARE covered by api-cancel.jsonl, each after its own Send, asserting the same cancelled response through read_pane; what no check can express is the comparison.
- `ctx_unlink_provider` — its parity: the click removes the binding, so the dispatch half cannot be given the same id. Dispatch and both channels' behaviour ARE covered by 2e-settings-unlink.jsonl; what no check can express is the comparison.
- `git_unfold` — its parity (3a-i): the operator's channel is Esc — a key, not a click or a drag — so the UI half of a parity step cannot be expressed. The dispatch is covered by 3a-i-git-drill.jsonl (unfold keeps the selection, the list is back). The keyboard half is 3a-i-git-keys.jsonl: Esc unfolds with the same file selected.
- `capacity_record` — its parity: the operator's channel is the agent's own stream — the window records a `rate_limit_event` frame from a turn on its own, with no click or drag — so the UI half of a parity step cannot be expressed, on git_fold's precedent. Both channels ARE covered: the dispatch by capacity-low-reading.jsonl and capacity-passed-reset.jsonl, the stream by agent/capacity-after-turn.jsonl, each asserting the reading it lands on the indicator; what no check can express is the comparison.
- `api_unbind` — its parity: the click returns the binding to its hole, and api_unbind refuses a position that holds no binding (`unbindNotABinding`), so the dispatch half cannot be given the same params — and a re-drag between the halves is not expressible. Both channels ARE covered by api-unbind.jsonl, each after its own drag, asserting the same hole back through read_pane; what no check can express is the comparison.
- `settings_open` — its parity: the only UI path is the `Settings…` MENU item, and a menu's buttons are not in the accessibility tree until the menu is open — the same rule that excuses every other menu control. Checks drive it by its real gesture, cmd+comma, and 2e-settings-pane.jsonl also dispatches it.
- `editor_new_scratch` — its parity (3b-i): the operator's channel is ⌘T, a menu key equivalent — a key, not a click or a drag — on git_step's precedent; the empty pane only names the key. The dispatch is covered by most 3b-i-editor-* checks; ⌘T by 3b-i-editor-scratch-save.jsonl and 3b-i-editor-close-keys.jsonl, asserting the Untitled-N tab through read_pane.
- `ctx_add_provider` — its parity: the click creates a binding under an id, so a dispatch with the same params collides with what the click just made. Covered by 2e-settings-doors.jsonl up to the browser leg.
- `editor_restore` — its parity (3b-i): no operator control — it runs when a window relaunches onto saved tabs, and one check is one launch. The dispatch is covered by 3b-i-editor-disk-changed.jsonl (an open, dirty tab is kept as it is); restoring after a relaunch is the runbook's row 9.
- `editor_open` — its parity (3b-i): the operator's channel is ⌘P — typing and Return — and a file row's identifier carries this launch's absolute path (`palette.row.editorfile:<root>/<rel>`), while `{fixtureRoot}` expands only in dispatch and parity params, never in a click. So no UI half can name the row. The dispatch is covered by every 3b-i-editor-* check that opens a file; the operator's gesture by 3b-i-editor-files-palette.jsonl (⌘P, the file's name, Return, asserting the tab and its text through read_pane).
- `db_remove_database` — its parity: the click removes the database, and removing one that is gone is refused (`no database … in environment …`), so the dispatch half cannot be given the same params. Dispatch is covered by 2e-settings-databases-dispatch.jsonl and the click by 2e-settings-databases.jsonl; what no check can express is the comparison.
- `api_fill_from_curl` — its parity: the UI half of a parity step is a click or a drag, and the operator's channel is a paste (cmd+v into the path editor), so the comparison cannot be expressed. Both channels ARE covered: the dispatch by api-paste-curl.jsonl, the paste by api-paste-curl-hotkey.jsonl, each asserting the same draft and the Filled from cURL line; what no check can express is the comparison.
- `api_undo_fill` — its parity: the Undo click forgets the fill it undoes, and api_undo_fill refuses a pane with nothing to undo, so the dispatch half cannot be given the same state after the click — and a second fill between the halves is not expressible inside one parity step. Both channels ARE covered by api-paste-curl.jsonl, the click after one fill and the dispatch after another, each asserting the same restored draft through read_pane; what no check can express is the comparison.
- `api_render_curl` — Two reasons, and the second is the one that lasts. A dispatch cannot hold the row id, which is minted per send and published only in read_pane; and the operator's own Copy as cURL puts its line on the PASTEBOARD, which no check can read — the act is real and its result leaves the window. `api_reopen`'s CLICK left this file when the recent strip gave it a button, because a reopen's effect lands in the draft where a check can see it; its dispatch half is still here, for the first of these reasons. Covered by WakilKitTests: curlIsPastTenseOnly, curlOnlyMentionsACredentialThereWasOne, curlEmitsAndNeverParses.
- `git_step` — its parity (3a-i): the operator's channel is ↑↓ with the diff open — keys, not a click or a drag — so the UI half of a parity step cannot be expressed, on api_fill_from_curl's precedent. The dispatch is covered by 3a-i-git-drill.jsonl (across roots, both directions, asserting the selection and the header through read_pane and the tree). The keyboard half is 3a-i-git-keys.jsonl: ↑↓ folded, across both roots, asserting the selection through read_pane.
- `editor_close` — its parity (3b-i): the operator's channels are ⌘W (a key) and the unsaved prompt's Don't Save, and the click consumes its own subject — the dispatch half after it would close a different tab or be refused (`the editor pane has no open tab`), api_cancel's case. Both channels ARE covered: 3b-i-editor-close-keys.jsonl (⌘W clean, ⌘W dirty → Esc / Cancel / Don't Save) and the dispatch with and without discard in 3b-i-editor-refusals.jsonl.
- `api_reopen` — its dispatch: it needs a row id, which is minted per send and published only in read_pane — the same reason api_render_curl below is here. The operator's gesture IS covered: api-recent.jsonl presses api.recent.0.reopen and asserts the draft it rebuilds. Permanent, not blocked: nothing in the vocabulary carries a value from read_pane into a dispatch.
- `editor_select` — its parity (3b-i): no operator control — the operator selects inside Monaco, the one non-action path, so no UI half exists. The dispatch is covered by most 3b-i-editor-* checks, which read selected_text back to prove what a save wrote.
- `editor_replace_range` — its parity (3b-i): no operator control — the operator's own edits are typing in Monaco, the one non-action path (`editorBufferDidChange`), so no UI half exists. The dispatch is covered by most 3b-i-editor-* checks, and its read-only refusal by 3b-i-editor-read-only.jsonl.
- `api.recent.<…>.curl` — Its whole effect is a string on the SYSTEM PASTEBOARD, which no check can read — the act is real and its result leaves the window, so a check could press it and assert nothing, which is the check-that-cannot-fail this file exists to prevent rather than permit. `TerminalPane`'s own Copy is silent for the same reason and carries no indicator. The line it copies is `apiRenderCurl`'s, covered by WakilKitTests: curlIsPastTenseOnly, curlOnlyMentionsACredentialThereWasOne, curlEmitsAndNeverParses. If this pane ever draws a "copied" acknowledgement, the act becomes observable and this line should go.
- `api.response.<…>` — the Body · Headers choice (W20) is drawn only over a reply, and no fixture host ever replies — every entry is `.invalid` or the never-answering `slow`, and wakil-http refuses http://. apiResponseOffersHeaders and apiResponseHeaderRows are pinned in ApiPaneLayoutTests; the drawn table is the runbook's check 5.
- `db.<…>.notFormatted` — display text, not a control: a static `Text` (DBPane.swift) carrying Format's refusal reason, with no press action, and the vocabulary addresses only `click`/`focus` by identifier while `expect.tree` matches by text, so no step can "press" it. Its content IS asserted: db-query-line-not-formatted.jsonl expects `not formatted: a string opened at character 39 never closes` in the tree, then its absence after the next edit.
- `editor.compare.diff` — Compare's Monaco host (3b-i): a WKWebView container with no press action. 3b-i-editor-disk-changed.jsonl asserts Compare's header opens and closes (button and Esc); what the diff shows is the operator's ruling (runbook row 6).
- `editor.compare.failure` — a Text (3b-i, Rule 8): drawn only when the file cannot be read back for Compare. The fixture's files are always readable and no step can make one unreadable mid-launch; display text with no press action either way. The runbook walks Compare.
- `editor.diskChanged` — the disk line's container (.contain, 3b-i): its text and two buttons. Read, not pressed — 3b-i-editor-disk-changed.jsonl asserts "disk.txt changed on disk" and its absence while comparing and after Reload; its buttons are editor.reload and editor.compare, pressed.
- `editor.empty` — the empty pane's hint (3b-i, .combine): "⌘P to open a file · ⌘T for a scratch tab", with no press action. Read, not pressed — 3b-i-editor-close-keys.jsonl asserts it after the last tab closes, and its absence after ⌘W closes the pane.
- `editor.monaco` — the Monaco host's container (3b-i): an NSViewRepresentable holding the WKWebView, with no press action of its own (git.diff's case). Typing into it is driven by keys: 3b-i-editor-scratch-save.jsonl types after ⌘T and after a save, and asserts the text through read_pane.
- `editor.notice` — a Text (3b-i, Rule 8): a tab's notice, drawn whole. Read, not pressed — 3b-i-editor-read-only.jsonl asserts "ro.bin is a binary file" in the tree and through read_pane.
- `editor.pane` — the editor pane's container (3b-i): it holds the strip, the lines and Monaco and takes no input itself. What it draws is read by every 3b-i-editor-* check; its controls are editor.tab.<i>, editor.reload, editor.compare and the save-as field's.
- `editor.saveAs.failure` — a Text (3b-i, Rule 8): the path field's failure, drawn whole. Read, not pressed — 3b-i-editor-save-as-field.jsonl asserts "is outside the active project's roots; editor reads and writes are confined to them (Invariant 6, Decision 36)" with the typed path still in the field.
- `editor.saveAs.replacePrompt` — the Save-As field's "Replace <name>?" line's container (.contain, 3b-i, Rule 1): its text and two buttons. Read, not pressed — 3b-i-editor-save-as-replace.jsonl asserts "Replace replace-me.txt?" and its absence after Cancel; its buttons editor.saveAs.replace / .replaceCancel are pressed there.
- `editor.saving` — the saving tick (3b-i, Rule 5): a 2 pt shape drawn only while a write is in flight, which against the fixture's tiny files lasts milliseconds — never long enough for a tree read to see (git.loading's case). `saving` is asserted false after each save through read_pane; seeing the tick is the runbook's walk.
- `editor.saving.cancel` — the saving tick's Cancel (3b-i, Rule 4): a control that exists only while a write is in flight, which against the fixture lasts milliseconds — a press cannot land on it, and wakil-files writes through a temp file and a rename, so no fixture path can make a write wait. Cancelling a save is the runbook's walk.
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
- `settings.login.cancel` — #254. Only exists while a browser trip is in flight.
- `settings.login.dismiss` — #254. Drawn only by the states a finished trip reaches — added, refused, cancelled, timedOut, uncertain, failed.
- `settings.login.someoneElse` — #254. Starts a fresh trip, and only appears when the config dir is already signed in, which itself needs a real credential.
- `settings.login.start` — #254. The control that does the above.
- `settings.mint.stopWaiting` — #254. Only exists while waiting on a live mint.
- `settings.org.speechProvider.note` — a Text: the Speech row's "unknown engine 'x', using Apple". Read, not pressed — 2d-ii-settings-speech.jsonl asserts it after a dispatched unknown id and a reload, and its absence after Apple is chosen.
- `settings.row.<…>.reauthenticate` — #254. Goes straight to the browser by design — no confirmation step — so pressing it IS starting a real trip.
- `window.capacity` — the capacity indicator beside ACCOUNT (provider capacity): it has no press action, and it refuses AXFocused (measured 2026-10-10: axresolve not_focusable), because `.focusable(interactions: .activate)` keeps a click from taking the composer's focus (Rule 6) and joins the key loop only with macOS Keyboard navigation on. Its card opens on hover or on that focus, and the vocabulary has no hover step, so opening the card is walk-only. What it draws is read by capacity-at-launch.jsonl (the launch probe, no turn), capacity-low-reading.jsonl, capacity-passed-reset.jsonl and agent/capacity-after-turn.jsonl.
- `window.composer.bar` — the composer bar's container (.contain), which holds the field, the heard text and the hint and takes no input itself. Its contents are read by every 2d-ii voice check; the field inside it is `window.composer`, which they type into.
- `window.composer.heard` — a Text: the words heard while ⌥ is held, or the notice that replaces them. Read, not pressed — 2d-ii-voice-silence.jsonl asserts "Hearing nothing from E2E Microphone" and the words that clear it; 2d-ii-voice-lands-unsent.jsonl and 2d-ii-voice-escape.jsonl assert the words mid-hold.
- `window.composer.hint` — a Text: the bar's hint. Read, not pressed — the keys hint ("TO SPEAK"), the listening hint ("RELEASE TO PUT IT IN THE LINE") and the landed hint ("HEARD · RETURN SENDS · EDIT FIRST") are asserted by the 2d-ii voice checks.
- `window.thread` — the thought thread's container (.contain), which takes hits only on its rows and the "earlier" line. Its rows are pressed by 2d-ii-thread-earlier.jsonl as window.thread.row.<id> and window.thread.earlier.

**This section knows nothing about what a machine cannot see.** The visual rulings and the live-provider question stay the operator's, permanently; they are the human section below.

<!-- /machine-walk -->
