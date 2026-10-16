# 3a-i — the Git pane, read-only: acceptance

**Spec:** [`2026-10-08-3a-i-git-pane-read-design.md`](../superpowers/specs/2026-10-08-3a-i-git-pane-read-design.md) ·
**Plan:** [`2026-10-08-3a-i-git-pane-read.md`](../superpowers/plans/2026-10-08-3a-i-git-pane-read.md)

**Walked by the operator 2026-10-09 — all ten steps pass.**

The exit criterion, from the spec: open a project with two roots; see each root's staged,
changed and untracked files; step through their diffs from the spine by hand, by voice and
through the agent; a change made in a terminal appears without a refresh.

The Cover rung's checks are in §3–§4. Everything that needs a real voice, a second terminal, a linked worktree or eyes
stays here either way.

## 0. Setup

There is no UI for adding roots. A project's roots are the `"roots"` array of its `project.json`,
read when Wakil launches and when the project is switched, **not live**: an edit to a running
window is not seen. So every root is declared up front, and the walk adds none.

Run this in the repo root, on this Mac, after `make build` and `make app-bundle`. It is safe to
re-run: it removes its own earlier registration first. Set `ORG` to one you have registered
(`./bin/wakil org list` shows them).

```bash
set -e
ORG=initech   # the org to walk under; initech or umbrella
cd /Users/operator/orca/workspaces/wakil/burrfish
rm -rf /tmp/walk-a /tmp/walk-b /tmp/walk-wt /tmp/walk-plain /tmp/walk-project
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
G="git -c user.name=walk -c user.email=walk@example.com"
mkdir -p /tmp/walk-a /tmp/walk-b /tmp/walk-plain /tmp/walk-project
# walk-a: a partly staged file, another change, an untracked file, a deletion, a 3 MB file
cd /tmp/walk-a && git init -q -b main
echo one > booking-controller.ts; echo one > other.ts; echo one > gone.ts
head -c 3145728 /dev/zero | tr '\0' x > big.txt
git add . && $G commit -qm init
echo two >> booking-controller.ts && git add booking-controller.ts && echo three >> booking-controller.ts
echo two >> other.ts; echo new > untracked.ts; rm gone.ts; printf 'yy' >> big.txt
# walk-b: one change, and the repo the linked worktree hangs off
cd /tmp/walk-b && git init -q -b main
echo one > tracked.ts && git add . && $G commit -qm init
echo two >> tracked.ts
git worktree add /tmp/walk-wt     # creates the branch walk-wt
# walk-plain is just a folder, not a repo
echo hi > /tmp/walk-plain/readme.txt
cat > /tmp/walk-project/project.json <<J
{"name":"walk","org":"$ORG",
 "roots":[{"path":"/tmp/walk-a"},{"path":"/tmp/walk-b"},{"path":"/tmp/walk-wt"},{"path":"/tmp/walk-plain"}],
 "scopes":{},"environments":{}}
J
cd /Users/operator/orca/workspaces/wakil/burrfish
./bin/wakil project rm walk --org "$ORG" || true   # a first run has nothing to remove
./bin/wakil project add walk --path /tmp/walk-project/project.json --org "$ORG"
```

Launch `WAKIL_ORG=initech app/Wakil.app/Contents/MacOS/Wakil`, then make the project active with
the project switcher (⌘P, choose `walk`). If you set `ORG=umbrella`, launch with `WAKIL_ORG=umbrella` instead. Registering does not select it.

`big.txt` is 3,145,730 bytes, so the truncation banner reads exactly `file is 3.0 MB · first 2 MB shown`.

## 1. The walk

Walk in order, in an agent-answering organisation, on the project `walk` from §0.

| # | Do | Expect | Walked |
|---|---|---|---|
| 1 | Open a Git pane | Titled Git. Four roots, in order: `walk-a`, `walk-b`, `walk-wt` and `walk-plain`, each under its own header. `walk-a` shows Staged, Changes and Untracked | ☑ 2026-10-09 |
| 2 | Look at `booking-controller.ts` in `walk-a` | It appears under Staged and under Changes, each with its own diff (staged shows `+two`, changed shows `+three`) | ☑ 2026-10-09 |
| 3 | Click it under Changes | The list folds into a spine of status marks and the Monaco diff fills the pane, inline. At ≥ 900 pt wide, file names instead of marks. Esc returns to the list with the same file selected | ☑ 2026-10-09 |
| 4 | Drill in again, press ↓ repeatedly, then ↑ | The selection steps through every file of `walk-a`, crosses into `walk-b`, and comes back. Esc lands on the file you stopped at | ☑ 2026-10-09 |
| 5 | Say *"show me booking controller"* | The pane selects `booking-controller.ts`, under Changes, and draws its diff | ☑ 2026-10-09 |
| 6 | Ask the agent to select that file in the Git pane, then to read the pane back | The selection moves as in step 3, and the agent quotes the same root, path and side the pane shows | ☑ 2026-10-09 |
| 7 | Open a terminal pane, `cd /tmp/walk-b` (it opens at the first root), run `echo x >> tracked.ts` | The `walk-b` diff for `tracked.ts` gains `+x` within a moment, with no refresh | ☑ 2026-10-09 |
| 8 | Look at `walk-plain` | Its header shows `not a git repository` whole, and the other three roots still list | ☑ 2026-10-09 |
| 9 | In the terminal, `cd /tmp/walk-wt && touch n && git add n` | `n` appears under Staged in the `walk-wt` root (branch `walk-wt`) without a refresh | ☑ 2026-10-09 |
| 10 | Open `big.txt`'s diff in `walk-a`, then `gone.ts`'s | `big.txt` reads `file is 3.0 MB · first 2 MB shown`. The deletion is drawn muted, not red | ☑ 2026-10-09 |

## 2. Residue — what the walk cannot establish

- **First-launch Monaco load on a cold cache** is not measured. Every run so far had the host's
  resources warm.
- **Journal noise.** A watcher refresh is journalled as `ui`, so a busy repo writes entries the
  operator did not act on. Not measured, not filtered.
- **A pruned linked worktree as a root** is untested. After `git worktree prune` the root's
  `.git` file points nowhere; step 9 does not delete it.
- **Side-by-side diff** is deferred (design-language §15); inline only.
- **Click-to-open into the editor** arrives with the editor.

## 3. Residue — what Cover could not reach, and why

Written by the e2e auditor (Cover rung, 2026-10-09). The checks are
`e2e/checks/seeded/3a-i-git-{list,drill,live}.jsonl` and
`e2e/checks/agent/3a-i-git-voice-hint.jsonl`, against the seeded `e2e-git` project
(roots `e2e-git` — not a repository — `e2e-api` and `e2e-portal`).

- **↑↓, Esc and Return in the pane** — no green check. In this build they do nothing: neither the
  harness's keys nor real HID key events (measured) step, unfold or select, after a landing
  click or after a real mouse click on a row. Defect D1 in the cover report. Covered through
  the agent's channel only (`git_step`, `git_unfold`, `git_fold` in 3a-i-git-drill.jsonl).
- **Rule 6, Esc returns to the same file** — the action is covered (`git_unfold` keeps the
  selection and the list returns); Esc itself is D1. Whether the file is *scrolled into view*
  is the walk's: no step kind reads scroll position.
- **Keys while an overlay owns the keyboard (org plane, confirmation)** — no check. With D1,
  "the keys did nothing" would pass whether or not the guard works: a check that cannot fail.
  Pinned by WakilKitTests keysByFoldAndOwnership; walk-only until D1 is fixed.
- **A row or spine mark pressed through accessibility** — AXPress succeeds and does nothing
  (defect D2): no VoiceOver user can open a file. A real mouse click works (measured). So
  `git_select`'s parity, `git.row:…` and `git.mark:…` are uncovered and the coverage gate is red
  on exactly those three until D2 is fixed.
- **Rule 4 (selecting another file cancels the diff in flight)** — no step kind can hold a
  diff in flight: `git_select` returns once its diff has landed. Pinned by WakilKitTests.
- **Rule 5 (the load mark)** — `git.loading` lives a few milliseconds against the fixture's
  repositories; no tree read sees it. The walk.
- **Rule 6, a refresh that only changes the file keeps the diff's scroll** — scroll position is
  not readable by any step kind. The walk.
- **The Monaco diff's content and tones** (green additions, muted deletions, inline) — the
  check sees only that the web view mounted. The operator's ruling.
- **The spine's look** (26 pt, 16 pt marks, the violet outline) — visual. The operator's ruling.
- **Banners (binary, truncated), a diff error, a multi-line root error** — not in the fixture;
  wording pinned by WakilKitTests and wakil-git's Go tests. Walk steps 10 and 8.
- **`wakil-git` called directly by the agent** (its own `git_status`/`git_diff`/`git_show`) —
  the scripted agent calls no tools; covered by wakil-git's Go tests. Read state through
  `read_pane` IS covered.
- **Voice reaching `git_select`** — the check proves GitSource hands the agent
  `"booking controller" → BookingController (file · git · e2e-api)`; that the agent then
  selects is a real agent's, so the walk (step 5).
- **The live checks' and the voice check's red proofs are missing.** `make e2e-new` saw both red
  against the merge-base for the right reason (no git pane), but refused to record either:
  #339's physical-input guard fired on a keyboard act in every run (cover report, H1).

## 4. The machine walk

<!-- machine-walk: generated by `make e2e-runbook`; everything between these markers is overwritten -->

**The machine walk is green:** every check ran against this build, every check this branch added was seen to fail against the merge-base, and the surface it added carries checks.

Walked by `make e2e` against 0d173f9a5c99, rendered 2026-10-09 16:35 UTC by `make e2e-runbook`. Re-render it with that target; edits between the markers are overwritten.

**The tree carried uncommitted changes**, so these checks ran against that tree rather than against the commit named above.

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
| `2d-i-palette-fold.jsonl` | ✓ exit 0 | ✓ red vs fb7e8f09d0f3, recorded 2026-10-06 | 4 | — |
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
| `3a-i-git-drill.jsonl` | ✓ exit 0 | ✓ red vs a376e0796810 | 27 | — |
| `3a-i-git-keys.jsonl` | ✓ exit 0 | ✓ red vs a376e0796810 | 20 | — |
| `3a-i-git-list.jsonl` | ✓ exit 0 | ✓ red vs a376e0796810 | 29 | — |
| `3a-i-git-live.jsonl` | ✓ exit 0 | ✓ red vs a376e0796810 | 23 | — |
| `3a-i-git-press.jsonl` | ✓ exit 0 | ✓ red vs a376e0796810 | 12 | — |
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
| `db-query-line-agent-replaces.jsonl` | ✓ exit 0 | ✓ red vs 3c9c923b17ca, recorded 2026-10-07 | 8 | — |
| `db-query-line-format.jsonl` | ✓ exit 0 | ✓ red vs 3c9c923b17ca, recorded 2026-10-07 | 5 | — |
| `db-query-line-long.jsonl` | ✓ exit 0 | **proved red vs 3c9c923b17ca on an earlier version — not re-proved** | 5 | — |
| `db-query-line-not-formatted.jsonl` | ✓ exit 0 | ✓ red vs 3c9c923b17ca, recorded 2026-10-07 | 6 | — |
| `db-query-line-return.jsonl` | ✓ exit 0 | ✓ red vs 3c9c923b17ca, recorded 2026-10-07 | 9 | — |
| `journal-error-reason.jsonl` | ✓ exit 0 | ✓ red vs dfb508b06420, recorded 2026-10-08 | 2 | — |
| `landing.jsonl` | ✓ exit 0 | not new on this branch | 5 | — |
| `vocabulary.jsonl` | ✓ exit 0 | not new on this branch | 6 | — |
| `2d-i-code-hint.jsonl` | ✓ exit 0 | **proved red vs fb7e8f09d0f3 on an earlier version — not re-proved** | 6 | — |
| `2d-i-failed-source.jsonl` | ✓ exit 0 | **proved red vs fb7e8f09d0f3 on an earlier version — not re-proved** | 5 | — |
| `2d-i-hint-or-plain.jsonl` | ✓ exit 0 | **proved red vs fb7e8f09d0f3 on an earlier version — not re-proved** | 8 | — |
| `2d-i-over-limit.jsonl` | ✓ exit 0 | **proved red vs fb7e8f09d0f3 on an earlier version — not re-proved** | 5 | — |
| `2d-i-pane-hint.jsonl` | ✓ exit 0 | **proved red vs fb7e8f09d0f3 on an earlier version — not re-proved** | 5 | — |
| `2d-i-schema-hint.jsonl` | ✓ exit 0 | **proved red vs fb7e8f09d0f3 on an earlier version — not re-proved** | 4 | — |
| `2d-ii-thread-earlier.jsonl` | ✓ exit 0 | not new on this branch | 12 | — |
| `2d-ii-voice-turn.jsonl` | ✓ exit 0 | not new on this branch | 10 | — |
| `3a-i-git-voice-hint.jsonl` | ✓ exit 0 | ✓ red vs a376e0796810 | 4 | — |
| `both-surfaces.jsonl` | ✓ exit 0 | not new on this branch | 6 | — |
| `two-enter.jsonl` | ✓ exit 0 | not new on this branch | 13 | — |
| `e2e/checks/seeded/zz-probe.jsonl` | — | — | — | a record for a check the corpus no longer holds |

**`make e2e-new` saw every check this branch added go red against a376e0796810.**

**Every action and control this branch added carries a check.** 5 action(s) and 10 control(s) are new on this branch.

- actions:  31 of 73 dispatched by a check
- writes:   6 of 47 carry a parity check
- controls: 72 of 123 exercised by a check

**36 piece(s) of surface no check can reach**, each with the reason given in `e2e/checks/uncoverable.tsv`:

- `api_fill_from_curl` — its parity: the UI half of a parity step is a click or a drag, and the operator's channel is a paste (cmd+v into the path editor), so the comparison cannot be expressed. Both channels ARE covered: the dispatch by api-paste-curl.jsonl, the paste by api-paste-curl-hotkey.jsonl, each asserting the same draft and the Filled from cURL line; what no check can express is the comparison.
- `git_step` — its parity (3a-i): the operator's channel is ↑↓ with the diff open — keys, not a click or a drag — so the UI half of a parity step cannot be expressed, on api_fill_from_curl's precedent. The dispatch is covered by 3a-i-git-drill.jsonl (across roots, both directions, asserting the selection and the header through read_pane and the tree). The keyboard half is 3a-i-git-keys.jsonl: ↑↓ folded, across both roots, asserting the selection through read_pane.
- `ctx_provider_login` — #254. Opens a browser on the operator's machine and authenticates as them. No harness can drive it and none should: every run would leave a real credential behind.
- `api_reopen` — its dispatch: it needs a row id, which is minted per send and published only in read_pane — the same reason api_render_curl below is here. The operator's gesture IS covered: api-recent.jsonl presses api.recent.0.reopen and asserts the draft it rebuilds. Permanent, not blocked: nothing in the vocabulary carries a value from read_pane into a dispatch.
- `ctx_unlink_provider` — its parity: the click removes the binding, so the dispatch half cannot be given the same id. Dispatch and both channels' behaviour ARE covered by 2e-settings-unlink.jsonl; what no check can express is the comparison.
- `git_fold` — its parity (3a-i): there is no operator control for it at all — GitPane folds only by selecting, so git_fold is the agent's alone and no UI half exists to compare. The dispatch is covered by 3a-i-git-drill.jsonl (fold again, the same file and position).
- `api_cancel` — its parity: the click cancels the send in flight, and api_cancel refuses a pane with nothing in flight (`nothingInFlight`), so the dispatch half cannot be given the same state — and a second Send between the halves is not expressible. Both channels ARE covered by api-cancel.jsonl, each after its own Send, asserting the same cancelled response through read_pane; what no check can express is the comparison.
- `db_remove_database` — its parity: the click removes the database, and removing one that is gone is refused (`no database … in environment …`), so the dispatch half cannot be given the same params. Dispatch is covered by 2e-settings-databases-dispatch.jsonl and the click by 2e-settings-databases.jsonl; what no check can express is the comparison.
- `api_unbind` — its parity: the click returns the binding to its hole, and api_unbind refuses a position that holds no binding (`unbindNotABinding`), so the dispatch half cannot be given the same params — and a re-drag between the halves is not expressible. Both channels ARE covered by api-unbind.jsonl, each after its own drag, asserting the same hole back through read_pane; what no check can express is the comparison.
- `api_render_curl` — Two reasons, and the second is the one that lasts. A dispatch cannot hold the row id, which is minted per send and published only in read_pane; and the operator's own Copy as cURL puts its line on the PASTEBOARD, which no check can read — the act is real and its result leaves the window. `api_reopen`'s CLICK left this file when the recent strip gave it a button, because a reopen's effect lands in the draft where a check can see it; its dispatch half is still here, for the first of these reasons. Covered by WakilKitTests: curlIsPastTenseOnly, curlOnlyMentionsACredentialThereWasOne, curlEmitsAndNeverParses.
- `settings_open` — its parity: the only UI path is the `Settings…` MENU item, and a menu's buttons are not in the accessibility tree until the menu is open — the same rule that excuses every other menu control. Checks drive it by its real gesture, cmd+comma, and 2e-settings-pane.jsonl also dispatches it.
- `git_unfold` — its parity (3a-i): the operator's channel is Esc — a key, not a click or a drag — so the UI half of a parity step cannot be expressed. The dispatch is covered by 3a-i-git-drill.jsonl (unfold keeps the selection, the list is back). The keyboard half is 3a-i-git-keys.jsonl: Esc unfolds with the same file selected.
- `ctx_add_provider` — its parity: the click creates a binding under an id, so a dispatch with the same params collides with what the click just made. Covered by 2e-settings-doors.jsonl up to the browser leg.
- `api_undo_fill` — its parity: the Undo click forgets the fill it undoes, and api_undo_fill refuses a pane with nothing to undo, so the dispatch half cannot be given the same state after the click — and a second fill between the halves is not expressible inside one parity step. Both channels ARE covered by api-paste-curl.jsonl, the click after one fill and the dispatch after another, each asserting the same restored draft through read_pane; what no check can express is the comparison.
- `api.recent.<…>.curl` — Its whole effect is a string on the SYSTEM PASTEBOARD, which no check can read — the act is real and its result leaves the window, so a check could press it and assert nothing, which is the check-that-cannot-fail this file exists to prevent rather than permit. `TerminalPane`'s own Copy is silent for the same reason and carries no indicator. The line it copies is `apiRenderCurl`'s, covered by WakilKitTests: curlIsPastTenseOnly, curlOnlyMentionsACredentialThereWasOne, curlEmitsAndNeverParses. If this pane ever draws a "copied" acknowledgement, the act becomes observable and this line should go.
- `api.response.<…>` — the Body · Headers choice (W20) is drawn only over a reply, and no fixture host ever replies — every entry is `.invalid` or the never-answering `slow`, and wakil-http refuses http://. apiResponseOffersHeaders and apiResponseHeaderRows are pinned in ApiPaneLayoutTests; the drawn table is the runbook's check 5.
- `db.<…>.notFormatted` — display text, not a control: a static `Text` (DBPane.swift) carrying Format's refusal reason, with no press action, and the vocabulary addresses only `click`/`focus` by identifier while `expect.tree` matches by text, so no step can "press" it. Its content IS asserted: db-query-line-not-formatted.jsonl expects `not formatted: a string opened at character 39 never closes` in the tree, then its absence after the next edit.
- `git.diff` — the Monaco host's container (3a-i): an NSViewRepresentable holding the WKWebView, with no press action of its own. 3a-i-git-drill.jsonl asserts the web view is mounted (`HTML content` in the tree); what it shows is the operator's ruling (§5 tones), not a check's.
- `git.diffBanner` — a Text (3a-i): `binary · 2.1 MB` or `file is 3.0 MB · first 2 MB shown`, drawn only over a binary or oversized diff. Display text with no press action; its wording is pinned by WakilKitTests banners and smallBinarySizes, and wakil-git's caps by its Go tests.
- `git.diffError` — a Text (3a-i): a diff's error, drawn whole. Display text with no press action; the fixture's diffs all load, and `diff.error` is asserted null by 3a-i-git-drill.jsonl.
- `git.diffHeader` — a Text (3a-i): `root / path · n of N · ↑↓`. Read, not pressed — 3a-i-git-drill.jsonl asserts it at 1, 2, 4 and 5 of 5, across both roots.
- `git.loading` — the load tick (3a-i, Rule 5): a 2 pt shape drawn only while a read or a diff is in flight, which against the fixture's tiny repositories lasts a few milliseconds — never long enough for a tree read to see. Pinned by WakilKitTests theClickedRowCarriesTheLoadingMarkUntilItsDiffArrives; seeing it is the runbook's walk.
- `git.pane` — the git pane's container (3a-i): it holds the list or the spine and diff, has no press action, and refuses AXFocused (measured: axresolve not_focusable) — its keyboard focus is SwiftUI's own, given when the pane is focused. What it draws is read by every 3a-i check; its rows are `git.row:…`.
- `git.root:<…>` — a Text (3a-i): a root's header, `e2e-api · main` or `e2e-git · not a git repository`. Read, not pressed — 3a-i-git-list.jsonl asserts both, and 3a-i-git-live.jsonl asserts `e2e-portal · main · clean` once the root empties.
- `git.rootError:<…>` — a Text (3a-i): the second and later lines of a root's error, drawn whole beneath its header — and only when the error HAS a second line. The fixture's non-repository error is one line, so it is never drawn; its split is pinned by WakilKitTests aLongErrorIsSplitBetweenTheHeaderAndTheLinesBeneath, and a multi-line error is the runbook's walk.
- `settings.login.cancel` — #254. Only exists while a browser trip is in flight.
- `settings.login.dismiss` — #254. Drawn only by the states a finished trip reaches — added, refused, cancelled, timedOut, uncertain, failed.
- `settings.login.someoneElse` — #254. Starts a fresh trip, and only appears when the config dir is already signed in, which itself needs a real credential.
- `settings.login.start` — #254. The control that does the above.
- `settings.mint.stopWaiting` — #254. Only exists while waiting on a live mint.
- `settings.org.speechProvider.note` — a Text: the Speech row's "unknown engine 'x', using Apple". Read, not pressed — 2d-ii-settings-speech.jsonl asserts it after a dispatched unknown id and a reload, and its absence after Apple is chosen.
- `settings.row.<…>.reauthenticate` — #254. Goes straight to the browser by design — no confirmation step — so pressing it IS starting a real trip.
- `window.composer.bar` — the composer bar's container (.contain), which holds the field, the heard text and the hint and takes no input itself. Its contents are read by every 2d-ii voice check; the field inside it is `window.composer`, which they type into.
- `window.composer.heard` — a Text: the words heard while ⌥ is held, or the notice that replaces them. Read, not pressed — 2d-ii-voice-silence.jsonl asserts "Hearing nothing from E2E Microphone" and the words that clear it; 2d-ii-voice-lands-unsent.jsonl and 2d-ii-voice-escape.jsonl assert the words mid-hold.
- `window.composer.hint` — a Text: the bar's hint. Read, not pressed — the keys hint ("TO SPEAK"), the listening hint ("RELEASE TO PUT IT IN THE LINE") and the landed hint ("HEARD · RETURN SENDS · EDIT FIRST") are asserted by the 2d-ii voice checks.
- `window.thread` — the thought thread's container (.contain), which takes hits only on its rows and the "earlier" line. Its rows are pressed by 2d-ii-thread-earlier.jsonl as window.thread.row.<id> and window.thread.earlier.

**This section knows nothing about what a machine cannot see.** The visual rulings and the live-provider question stay the operator's, permanently; they are the human section below.

<!-- /machine-walk -->
