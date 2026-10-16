# 2d-ii — voice capture, the composer, and the listening room: acceptance

**Spec:** [`2026-10-07-2d-ii-voice-capture-design.md`](../superpowers/specs/2026-10-07-2d-ii-voice-capture-design.md) ·
**Plan:** [`2026-10-07-2d-ii-voice-capture.md`](../superpowers/plans/2026-10-07-2d-ii-voice-capture.md)

**Not yet walked.**

Before the walk, nine check files cover the push-to-talk hold, the composer, the thread and
the Speech row.

- **Seven seeded checks** were each seen to fail against the merge-base `3c9c923`, in a sound
  run, because their feature is absent there.
- **The thread check** fails against `5979778`. That is the first branch commit where Return
  sends, and it predates the four-row thread.
- **The voice-turn check** fails before its first send against `3c9c923`. Its `voice_turn`
  journal assertions have no build that can show them red. `backfill.tsv` records why.

The eight earlier agent checks now send with Return instead of the deleted Send button. Their
assertions are unchanged, and `backfill.tsv` redirects their failability. §0 below is rendered
from the run records, and nothing writes it by hand.

Every check and the coverage gate pass at the commit §0 names, in one per-check run with no
re-runs. Two checks have gone red intermittently in earlier runs; §2 records both.

The checks drive a scripted speech engine through `WAKIL_SPEECH_SCRIPT`, with a real ⌥
`flagsChanged` posted through the HID tap. They never drive the microphone. Everything that
needs a real voice, a real device, or eyes is below.

## 1. The walk

The spec's operator walk, plus what no check reaches. Walk the steps in order, in an
organisation with a project open and an agent that answers, on this Mac's own microphone.

| # | Do | Expect | Checks | Walked |
|---|---|---|---|---|
| 1 | Hold ⌥ alone for a second and say a sentence, then release | The room brightens into listening and the words appear in the bar, the unsettled tail dimmer. On release they land in the composer unsent, and the hint reads *heard · Return sends · edit first* | Spec 1–2; rules 1, 3 | ☑ 2026-10-08 |
| 2 | Before Return, correct a misheard identifier by hand (e.g. "2B8" → `2b-viii`), then press Return | The corrected text is what is sent and what the `you` row shows | Spec "No spoken aliases"; rule 1 | ☑ 2026-10-08 |
| 3 | In System Settings, turn Wakil's microphone access off, then hold ⌥ | The bar says *"Wakil can't use the microphone. Allow it in System Settings → Privacy & Security → Microphone"*. Typing still works | Spec 3; rule 8 | ☑ 2026-10-08 |
| 4 | Turn access back on and hold ⌥ again | Listening works, with no relaunch. The next hold re-checks access | Spec errors table, permission row | ☑ 2026-10-08 |
| 5 | On a Mac without the English model (or after removing it), hold ⌥ | The bar shows the download and its size. Esc cancels the wait. Releasing does not cancel the download, and a later hold reuses it | Spec 4; rule 4 | ☑ 2026-10-08 — the model was already installed, so the download path itself was not exercised |
| 6 | Mute the input (or pick a silent device) and hold ⌥ for two seconds | After about 1.5 s the bar says *"Hearing nothing from <your device's name>"*, in words, with no meter. It clears as soon as sound arrives | Spec 3; rule 8 | ☑ 2026-10-08 |
| 7 | Watch the room go into listening and back, with Reduce Motion off and then on | The breath stays continuous: no jump in phase, and amplitude and spread ease in over about 250 ms. Under Reduce Motion it brightens and tightens but does not breathe. Tune and approve listening's numbers (T18) | Spec 7 (visual ruling) | ☑ 2026-10-08 — numbers approved unchanged (T18) |
| 8 | Hold ⌥ until words are heard, then press ⌘K (or ⌘P) while still holding | The shortcut is swallowed, not run, and nothing types into the hidden field. Releasing lands the words | Final review, Walk line | ☑ 2026-10-08 |
| 9 | With a full-height pane open, look at the thread's bottom-left corner | The pane runs beneath the thread with no reserved gap. The thread rests at 32 % opacity, and errors stay red | Spec 6 | ☑ 2026-10-08 |
| 10 | Move the pointer over the thread, including its padding between rows | It rises to full within about 160 ms. Hovering over the padding counts as hovering (Task 13's Walk check) | Spec 6 | ☑ 2026-10-08 |
| 11 | Click in the thread's padding, then on the pane right beside a row | The click reaches the pane beneath. Only rows and the "earlier" line take clicks | Spec 6 | ☑ 2026-10-08 |
| 12 | Click a row to expand it, drag-select part of its text, and move the pointer out while still holding the button | The row expands in place, monospaced and wrapped. The selection is kept and the thread does not fold while the button is held. It folds and fades 1.2 s after release with the pointer away | Spec 6 | ☑ 2026-10-08 |
| 13 | Press Esc with the thread expanded | It folds at once. The Esc reaches nothing else when the composer has focus | Spec 6; rule 6 | ☑ 2026-10-08 |
| 14 | Open Settings (⌘,), keep its pane focused, hold ⌥ and speak | The words land in the agent composer. The settings pane is untouched (Decision 30) | Spec errors table, last row | ☑ 2026-10-08 |

**Walked by the operator, 2026-10-08**, on the bundle built from `36fba0f`, with this Mac's own
microphone: every step passes. What the walk found, and where each went:

- **The words appeared only on release, not while held.** Fixed in `36fba0f` (`.fastResults`
  and `prepareToAnalyze`); re-walked and passing in step 1.
- **"no project root available yet …" stayed on screen after a project with a root was open.**
  Pre-existing since 2b-v (`notes` fixed at launch); fixed in `80c97d7`, derived like
  `noActiveProviderNote`.
- **⌥ looked dead on some launches.** Measured: on a fresh ad-hoc build macOS asks for microphone
  access as listening starts, the prompt takes the key window, and Wakil reads that as a
  release, so the bar never shows anything. Separately, the bar's `WindowReader` sometimes never
  learns its window, so the key-window guard refuses every event. Both fixed after the walk — see §2.
- **Dropping a pane twitches.** Reproduced on the merge-base build, so pre-existing: #353.

## 2. Residue — what no check covers, and why

- **Fixed after the walk, not re-walked:** the bar now learns its window whenever it moves into
  one (`fa1c47d`), and the first-use permission prompt and a refusal are said in the bar until
  the next ⌥ press (`5b2e4f2`). `make app-test` passes (2082). The 2d-ii seeded checks and two
  agent checks were re-run against that bundle and pass. `2d-ii-voice-lands-unsent` went red
  2 runs in 12: instrumented, the red run is another app (Arc) taking the foreground mid-hold,
  which Wakil correctly reads as a release. §0 is re-rendered at the commit with both fixes,
  from one full per-check run in which every check passed first time.

- **A pane extends beneath the thread** (walk 9). No step kind asserts geometry. `read_layout`
  carries pane frames but not the thread's, and `expect` cannot read `read_layout`.
- **Hover, fade, fold timing and hit-testing** (walks 10–12). Opacity is not in the
  accessibility tree. No act moves the pointer, and AXPress bypasses hit-testing.
  `ThreadDisclosureTests` covers the logic.
- **Drag-select inside an expanded row** (walk 12). SwiftUI reports no text selection.
- **The real microphone, permission and the model download** (walks 1, 3–6). The scripted
  engine replaces the microphone by design. The `denied`, `downloading` and `failed` notices
  are unit-tested, but one script per launch serves every check, so no check plays them.
- **The listening breath** (walk 7). A visual ruling, permanently the operator's.
- **⌘ shortcuts swallowed mid-hold** (walk 8). What a check could observe is only that nothing
  happened.
- **⌥ released under 180 ms, or chorded inside the arm window** (rule 7). Each act costs more
  than 180 ms, so no check can land inside the window. `ListeningMachineTests` covers it.
- **Losing focus while holding lands what was heard** (rule 2). Taking the focus away means
  driving another app. Unit tests cover it.
- **A hold during a turn in flight** (rule 5). The scripted agent answers too fast for a hold
  to fall inside a turn deterministically. Unit tests cover it.
- **⇧Return breaks a line without sending.** No check, because how the accessibility dump
  prints a multi-line value is unmeasured.
- **Speech while the settings pane has focus** (walk 14). No check written yet. This is
  ordinary work, not a harness limit.
- **`voice_turn`'s journal assertions** cannot be shown red by any build. Voice turns were
  journalled (`978c0e6`) before Return started sending (`5979778`).
- **Display-only identifiers** (`window.composer.bar/.heard/.hint`, `window.thread`,
  `settings.org.speechProvider.note`) are read by the checks and pressed by none. They are
  listed in `uncoverable.tsv` §4.
- **`ThoughtThread.swift` is not under the control gate.** Its label column has a
  pointer-only second toggle that the gate flags. Open design call: drop that tap, or name it.
- **Intermittent, this branch: `2d-ii-thread-earlier.jsonl` went red 1 run in 3** on
  2026-10-08. In the full per-check run (bundle 62fc9c9) steps 18–21 failed: after expanding a
  row, `press Escape` was reported unverified and the thread stayed expanded. Two single re-runs
  then passed (`.context/e2e/20261008-091222`, `-091235`). §0's green record for it is the last
  of those re-runs, so it is a retry and not independent evidence. Walk step: expand a row, press
  Esc, and expect the thread to fold. Track as a flake until it is explained.
- **Machine flake, not this branch:** `2c-iii-4-interrupt.jsonl` (ctrl+c into `cat`) failed all
  morning on this Mac, identically on the merge-base bundle (`.context/e2e/20261008-075607`),
  and passed in the final run. It touches nothing on this branch.

<!-- machine-walk: generated by `make e2e-runbook`; everything between these markers is overwritten -->

**The machine walk is green:** every check ran against this build, every check this branch added was seen to fail against the merge-base, and the surface it added carries checks.

Walked by `make e2e` against 33581bb394d0, rendered 2026-10-08 12:31 UTC by `make e2e-runbook`. Re-render it with that target; edits between the markers are overwritten.

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
| `2d-i-palette-fold.jsonl` | ✓ exit 0 | not new on this branch | 4 | — |
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
| `api-unbind.jsonl` | ✓ exit 0 | not new on this branch | 7 | — |
| `landing.jsonl` | ✓ exit 0 | not new on this branch | 5 | — |
| `vocabulary.jsonl` | ✓ exit 0 | not new on this branch | 6 | — |
| `2d-i-code-hint.jsonl` | ✓ exit 0 | not new on this branch | 6 | — |
| `2d-i-failed-source.jsonl` | ✓ exit 0 | not new on this branch | 5 | — |
| `2d-i-hint-or-plain.jsonl` | ✓ exit 0 | not new on this branch | 8 | — |
| `2d-i-over-limit.jsonl` | ✓ exit 0 | not new on this branch | 5 | — |
| `2d-i-pane-hint.jsonl` | ✓ exit 0 | not new on this branch | 5 | — |
| `2d-i-schema-hint.jsonl` | ✓ exit 0 | not new on this branch | 4 | — |
| `2d-ii-thread-earlier.jsonl` | ✓ exit 0 | ✓ red vs 5979778 | 12 | — |
| `2d-ii-voice-turn.jsonl` | ✓ exit 0 | not new on this branch | 10 | — |
| `both-surfaces.jsonl` | ✓ exit 0 | not new on this branch | 6 | — |
| `two-enter.jsonl` | ✓ exit 0 | not new on this branch | 13 | — |

**`make e2e-new` saw every check this branch added go red against 5979778.**

**Every action and control this branch added carries a check.** 0 action(s) and 8 control(s) are new on this branch.

- actions:  25 of 68 dispatched by a check
- writes:   5 of 43 carry a parity check
- controls: 68 of 110 exercised by a check

**24 piece(s) of surface no check can reach**, each with the reason given in `e2e/checks/uncoverable.tsv`:

- `api_reopen` — its dispatch: it needs a row id, which is minted per send and published only in read_pane — the same reason api_render_curl below is here. The operator's gesture IS covered: api-recent.jsonl presses api.recent.0.reopen and asserts the draft it rebuilds. Permanent, not blocked: nothing in the vocabulary carries a value from read_pane into a dispatch.
- `ctx_provider_login` — #254. Opens a browser on the operator's machine and authenticates as them. No harness can drive it and none should: every run would leave a real credential behind.
- `api_unbind` — its parity: the click returns the binding to its hole, and api_unbind refuses a position that holds no binding (`unbindNotABinding`), so the dispatch half cannot be given the same params — and a re-drag between the halves is not expressible. Both channels ARE covered by api-unbind.jsonl, each after its own drag, asserting the same hole back through read_pane; what no check can express is the comparison.
- `ctx_unlink_provider` — its parity: the click removes the binding, so the dispatch half cannot be given the same id. Dispatch and both channels' behaviour ARE covered by 2e-settings-unlink.jsonl; what no check can express is the comparison.
- `db_remove_database` — its parity: the click removes the database, and removing one that is gone is refused (`no database … in environment …`), so the dispatch half cannot be given the same params. Dispatch is covered by 2e-settings-databases-dispatch.jsonl and the click by 2e-settings-databases.jsonl; what no check can express is the comparison.
- `api_fill_from_curl` — its parity: the UI half of a parity step is a click or a drag, and the operator's channel is a paste (cmd+v into the path editor), so the comparison cannot be expressed. Both channels ARE covered: the dispatch by api-paste-curl.jsonl, the paste by api-paste-curl-hotkey.jsonl, each asserting the same draft and the Filled from cURL line; what no check can express is the comparison.
- `api_cancel` — its parity: the click cancels the send in flight, and api_cancel refuses a pane with nothing in flight (`nothingInFlight`), so the dispatch half cannot be given the same state — and a second Send between the halves is not expressible. Both channels ARE covered by api-cancel.jsonl, each after its own Send, asserting the same cancelled response through read_pane; what no check can express is the comparison.
- `api_render_curl` — Two reasons, and the second is the one that lasts. A dispatch cannot hold the row id, which is minted per send and published only in read_pane; and the operator's own Copy as cURL puts its line on the PASTEBOARD, which no check can read — the act is real and its result leaves the window. `api_reopen`'s CLICK left this file when the recent strip gave it a button, because a reopen's effect lands in the draft where a check can see it; its dispatch half is still here, for the first of these reasons. Covered by WakilKitTests: curlIsPastTenseOnly, curlOnlyMentionsACredentialThereWasOne, curlEmitsAndNeverParses.
- `ctx_add_provider` — its parity: the click creates a binding under an id, so a dispatch with the same params collides with what the click just made. Covered by 2e-settings-doors.jsonl up to the browser leg.
- `api_undo_fill` — its parity: the Undo click forgets the fill it undoes, and api_undo_fill refuses a pane with nothing to undo, so the dispatch half cannot be given the same state after the click — and a second fill between the halves is not expressible inside one parity step. Both channels ARE covered by api-paste-curl.jsonl, the click after one fill and the dispatch after another, each asserting the same restored draft through read_pane; what no check can express is the comparison.
- `settings_open` — its parity: the only UI path is the `Settings…` MENU item, and a menu's buttons are not in the accessibility tree until the menu is open — the same rule that excuses every other menu control. Checks drive it by its real gesture, cmd+comma, and 2e-settings-pane.jsonl also dispatches it.
- `api.recent.<…>.curl` — Its whole effect is a string on the SYSTEM PASTEBOARD, which no check can read — the act is real and its result leaves the window, so a check could press it and assert nothing, which is the check-that-cannot-fail this file exists to prevent rather than permit. `TerminalPane`'s own Copy is silent for the same reason and carries no indicator. The line it copies is `apiRenderCurl`'s, covered by WakilKitTests: curlIsPastTenseOnly, curlOnlyMentionsACredentialThereWasOne, curlEmitsAndNeverParses. If this pane ever draws a "copied" acknowledgement, the act becomes observable and this line should go.
- `api.response.<…>` — the Body · Headers choice (W20) is drawn only over a reply, and no fixture host ever replies — every entry is `.invalid` or the never-answering `slow`, and wakil-http refuses http://. apiResponseOffersHeaders and apiResponseHeaderRows are pinned in ApiPaneLayoutTests; the drawn table is the runbook's check 5.
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
