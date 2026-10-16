# #365 — terminal paste, and editing a selection on the input line: acceptance

**Spec:** [`2026-10-09-terminal-input-line-editing-design.md`](../superpowers/specs/2026-10-09-terminal-input-line-editing-design.md) ·
**Plan:** [`2026-10-09-terminal-input-line-editing.md`](../superpowers/plans/2026-10-09-terminal-input-line-editing.md)

**Walked by the operator 2026-10-09 — all ten steps pass**, on the build with the two walk fixes below.

The exit criterion: ⌘V pastes at the shell prompt, a multi-line paste waits for Enter, and a
selection on the input line can be typed over, deleted or pasted over — with Tab, history and
the operator's zsh plugins untouched.

## 0. Setup

In the repo root, on this Mac: `make build && make app-bundle`, quit any running Wakil, then
launch `WAKIL_ORG=initech app/Wakil.app/Contents/MacOS/Wakil` and open a terminal pane. Your own
zsh config loads in it, which is the point.

## 1. The walk

| # | Do | Expect | Walked |
|---|---|---|---|
| 1 | Copy `echo one` + newline + `echo two` from any editor; ⌘V at the prompt | Both lines appear in the prompt; nothing runs until Return, then `one` and `two` print | ☑ 2026-10-09 |
| 2 | Type `echo git checkout main`; drag across `checkout` with the mouse | `checkout` is highlighted, nothing else moves, the pane keeps keyboard focus | ☑ 2026-10-09 |
| 3 | With that selection, type `s` then `witch` | The line reads `echo git switch main`, cursor after `switch`; Return prints `git switch main` | ☑ 2026-10-09 |
| 4 | Type `echo keep drop`; drag over ` drop`; Backspace | The line reads `echo keep`; nothing asks to confirm | ☑ 2026-10-09 |
| 5 | Type `echo aaa bbb`; double-click `bbb`; ⌘V (clipboard: anything one-line) | `bbb` is replaced by the clipboard text | ☑ 2026-10-09 |
| 6 | Type `git che`, press Tab, then drag over the completed word and type `log` | Tab completes as before; the replace still works after Tab | ☑ 2026-10-09 |
| 7 | Run `ls`; drag over its output in the block above the prompt; ⌘C | The output is copied (paste it somewhere); typing does not change it | ☑ 2026-10-09 |
| 8 | Drag over part of the prompt itself (`~/… %`) plus a typed word; type `x` | Only the typed part is replaced; the prompt is untouched | ☑ 2026-10-09 |
| 9 | Select part of the line, then press ← | The selection clears and the cursor moves as usual; the next key types normally | ☑ 2026-10-09 |
| 10 | Look at the highlight | Reads as a selection, legible against the pane, never violet | ☑ 2026-10-09 |

### Found on the walk, fixed before it passed

- **→ did not move the drawn cursor, and the next ← made it jump.** zsh moves right with
  `ESC[C`, which SwiftTerm does not count as a screen change, and `TerminalStore` published only
  on one. It now also publishes when the cursor moved (d4242635). Pre-existing; pinned by the
  real-zsh test `aCursorThatMovesWithoutRedrawingIsStillPublished`.
- **⌥←, ⌥→ and ⌥⌫ did nothing word-wise.** The pane dropped ⌥. They now send `ESC b`, `ESC f` and
  `ESC DEL`, as Terminal.app and iTerm do (fa5e3e16). Pre-existing; pinned by
  `optionArrowsMoveByWordAndOptionBackspaceDeletesAWord`. Walked; no e2e check (residue §3).

## 2. Residue — what the walk cannot establish

- **bash 4 and later.** This Mac has no Homebrew bash; `homebrewBashReplacesTheSelectedWord`
  skips. The bash path ships behind the binding check, untested.
- **zsh-vi-mode and other plugins that rebuild keymaps late.** The pane stops offering selection
  edits when `\e[999~` no longer resolves to `__wakil_replace`, so the failure mode is "nothing
  happens", not a lost line — but no such plugin is installed here.
- **Deferred minors from review:** the widget's read loop has no timeout; ⌘C over CJK adds a
  space per wide character; keys sent very fast can arrive out of order (pre-existing).

## 3. Residue — what Cover could not reach, and why

Written by the e2e auditor (Cover rung, 2026-10-09). The checks are
`e2e/checks/seeded/365-terminal-{paste,select-type,select-backspace}.jsonl`; selection is made
with ⇧← because it is the one path a check can drive.

- **Drag and double-click selection** — the live region is a canvas with no identifier, and
  `drag` takes two identified controls. Walk steps 2–6, 8.
- **A multi-line paste waiting for Enter, through the GUI** — the clipboard is filled from the
  composer, where Return sends. Pinned by the real-zsh test
  `zshBracketedPasteOfTwoLinesDoesNotRunBeforeEnter`; walk step 1.
- **Copy-only over output** — needs a drag over the block history. Walk step 7.
- **⌘C of an input-line selection** — no step kind reads the pasteboard. Pinned by
  `selectedTextJoinsRowsWithNewlines`.
- **Replace after Tab completion** — completion output depends on the fixture's PATH. Walk step 6.
- **Rule 6 (cursor stays at the edit)** — `cursorCol` is readable but its value depends on the
  prompt width; pinned by the real-zsh tests (`CURSOR = start + len`). Walk step 3.
- **The highlight's look** — visual. The operator's ruling (step 10).
- **⌥←, ⌥→, ⌥⌫ and the drawn cursor after →** — walk findings fixed after Cover turned; pinned by
  unit and real-zsh tests and walked, not by an e2e check.
- **Pane focus after a drag** — review flagged that the live region's drag may not focus the pane.
  Walk step 2.

## 4. The machine walk

<!-- machine-walk: generated by `make e2e-runbook`; everything between these markers is overwritten -->

**The machine walk is green:** every check ran against this build, every check this branch added was seen to fail against the merge-base, and the surface it added carries checks.

Walked by `make e2e` against 9a835a40fa86, rendered 2026-10-09 20:06 UTC by `make e2e-runbook`. Re-render it with that target; edits between the markers are overwritten.

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
| `365-terminal-paste.jsonl` | ✓ exit 0 | ✓ red vs f25a762e5ee7 | 4 | — |
| `365-terminal-select-backspace.jsonl` | ✓ exit 0 | ✓ red vs f25a762e5ee7 | 3 | — |
| `365-terminal-select-type.jsonl` | ✓ exit 0 | ✓ red vs f25a762e5ee7 | 4 | — |
| `3a-i-git-drill.jsonl` | ✓ exit 0 | ✓ red vs a376e0796810, recorded 2026-10-09 | 27 | — |
| `3a-i-git-keys.jsonl` | ✓ exit 0 | ✓ red vs a376e0796810, recorded 2026-10-09 | 20 | — |
| `3a-i-git-list.jsonl` | ✓ exit 0 | ✓ red vs a376e0796810, recorded 2026-10-09 | 29 | — |
| `3a-i-git-live.jsonl` | ✓ exit 0 | ✓ red vs a376e0796810, recorded 2026-10-09 | 23 | — |
| `3a-i-git-press.jsonl` | ✓ exit 0 | ✓ red vs a376e0796810, recorded 2026-10-09 | 12 | — |
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
| `3a-i-git-voice-hint.jsonl` | ✓ exit 0 | ✓ red vs a376e0796810, recorded 2026-10-09 | 4 | — |
| `both-surfaces.jsonl` | ✓ exit 0 | not new on this branch | 6 | — |
| `two-enter.jsonl` | ✓ exit 0 | not new on this branch | 13 | — |

**`make e2e-new` saw every check this branch added go red against f25a762e5ee7.**

**the actions were observed from a tree carrying uncommitted changes, so they describe that tree rather than the commit**

**Every action and control this branch added carries a check.** 0 action(s) and 0 control(s) are new on this branch.

- actions:  31 of 73 dispatched by a check
- writes:   6 of 47 carry a parity check
- controls: 72 of 123 exercised by a check

**36 piece(s) of surface no check can reach**, each with the reason given in `e2e/checks/uncoverable.tsv`:

- `api_unbind` — its parity: the click returns the binding to its hole, and api_unbind refuses a position that holds no binding (`unbindNotABinding`), so the dispatch half cannot be given the same params — and a re-drag between the halves is not expressible. Both channels ARE covered by api-unbind.jsonl, each after its own drag, asserting the same hole back through read_pane; what no check can express is the comparison.
- `git_step` — its parity (3a-i): the operator's channel is ↑↓ with the diff open — keys, not a click or a drag — so the UI half of a parity step cannot be expressed, on api_fill_from_curl's precedent. The dispatch is covered by 3a-i-git-drill.jsonl (across roots, both directions, asserting the selection and the header through read_pane and the tree). The keyboard half is 3a-i-git-keys.jsonl: ↑↓ folded, across both roots, asserting the selection through read_pane.
- `api_undo_fill` — its parity: the Undo click forgets the fill it undoes, and api_undo_fill refuses a pane with nothing to undo, so the dispatch half cannot be given the same state after the click — and a second fill between the halves is not expressible inside one parity step. Both channels ARE covered by api-paste-curl.jsonl, the click after one fill and the dispatch after another, each asserting the same restored draft through read_pane; what no check can express is the comparison.
- `ctx_unlink_provider` — its parity: the click removes the binding, so the dispatch half cannot be given the same id. Dispatch and both channels' behaviour ARE covered by 2e-settings-unlink.jsonl; what no check can express is the comparison.
- `git_unfold` — its parity (3a-i): the operator's channel is Esc — a key, not a click or a drag — so the UI half of a parity step cannot be expressed. The dispatch is covered by 3a-i-git-drill.jsonl (unfold keeps the selection, the list is back). The keyboard half is 3a-i-git-keys.jsonl: Esc unfolds with the same file selected.
- `api_render_curl` — Two reasons, and the second is the one that lasts. A dispatch cannot hold the row id, which is minted per send and published only in read_pane; and the operator's own Copy as cURL puts its line on the PASTEBOARD, which no check can read — the act is real and its result leaves the window. `api_reopen`'s CLICK left this file when the recent strip gave it a button, because a reopen's effect lands in the draft where a check can see it; its dispatch half is still here, for the first of these reasons. Covered by WakilKitTests: curlIsPastTenseOnly, curlOnlyMentionsACredentialThereWasOne, curlEmitsAndNeverParses.
- `db_remove_database` — its parity: the click removes the database, and removing one that is gone is refused (`no database … in environment …`), so the dispatch half cannot be given the same params. Dispatch is covered by 2e-settings-databases-dispatch.jsonl and the click by 2e-settings-databases.jsonl; what no check can express is the comparison.
- `git_fold` — its parity (3a-i): there is no operator control for it at all — GitPane folds only by selecting, so git_fold is the agent's alone and no UI half exists to compare. The dispatch is covered by 3a-i-git-drill.jsonl (fold again, the same file and position).
- `settings_open` — its parity: the only UI path is the `Settings…` MENU item, and a menu's buttons are not in the accessibility tree until the menu is open — the same rule that excuses every other menu control. Checks drive it by its real gesture, cmd+comma, and 2e-settings-pane.jsonl also dispatches it.
- `ctx_provider_login` — #254. Opens a browser on the operator's machine and authenticates as them. No harness can drive it and none should: every run would leave a real credential behind.
- `api_fill_from_curl` — its parity: the UI half of a parity step is a click or a drag, and the operator's channel is a paste (cmd+v into the path editor), so the comparison cannot be expressed. Both channels ARE covered: the dispatch by api-paste-curl.jsonl, the paste by api-paste-curl-hotkey.jsonl, each asserting the same draft and the Filled from cURL line; what no check can express is the comparison.
- `api_reopen` — its dispatch: it needs a row id, which is minted per send and published only in read_pane — the same reason api_render_curl below is here. The operator's gesture IS covered: api-recent.jsonl presses api.recent.0.reopen and asserts the draft it rebuilds. Permanent, not blocked: nothing in the vocabulary carries a value from read_pane into a dispatch.
- `ctx_add_provider` — its parity: the click creates a binding under an id, so a dispatch with the same params collides with what the click just made. Covered by 2e-settings-doors.jsonl up to the browser leg.
- `api_cancel` — its parity: the click cancels the send in flight, and api_cancel refuses a pane with nothing in flight (`nothingInFlight`), so the dispatch half cannot be given the same state — and a second Send between the halves is not expressible. Both channels ARE covered by api-cancel.jsonl, each after its own Send, asserting the same cancelled response through read_pane; what no check can express is the comparison.
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
