# Background agents: acceptance

**Spec:** [`2026-10-16-background-agents-design.md`](../superpowers/specs/2026-10-16-background-agents-design.md)

**Not walked.**

Before the walk: the machine walk at the end of this document is rendered from the run
records by `make e2e-runbook`, and nothing writes it by hand.

## 1. The walk

Use an organisation with a real provider, two environments and a second project.

| # | Do | Expect | Walked |
|---|---|---|---|
| 1 | Ask the agent for something that takes a while, then switch environment from the context line | Nothing is asked. A chip appears top right with a violet dot that breathes, reading `org · project · env` | ✓ 2026-10-18 |
| 2 | Turn on Reduce Motion in System Settings, with a chip working | The dot holds still, full | not walked — left out of the essential walk, 2026-10-18 |
| 3 | Leave an agent working in a production environment | The chip's environment segment is production red | not walked — left out of the essential walk, 2026-10-18 |
| 4 | Have an agent in a background place raise a confirmation | Its chip turns amber and reads `— waiting`; nothing moves you | not walked — left out of the essential walk, 2026-10-18 |
| 5 | Let a background agent finish | The chip turns green and reads `— done`; nothing moves you | ✓ 2026-10-18 |
| 6 | Click the chip | You land in its place, asked nothing: its thread, its canvas, the chip gone | ✓ 2026-10-18 |
| 7 | Leave agents working in three other places | Two chips and `+1 more`; its popover lists the third, and a click there goes to it | not walked — left out of the essential walk, 2026-10-18 |
| 8 | Quit with agents working, relaunch, open ⌘P | Nothing was asked at quit; each agent's session is in Continue | ✓ 2026-10-18 |

## 2. Residue: what no check covers, and why

- **Chip hue, the working dot's breathing, Reduce Motion, production red in the environment
  segment, the `+N more` popover's look** (Rule 5, Invariant 8; walk 1, 2, 3, 7): colour and
  motion are not expressible. The checks hold the chip's state (its value), place (its
  identifier) and frame.
- **The amber `— waiting` chip** (Rule 4; walk 4): no check. The seeded fixture has no
  production environment and the scripted agent no gated write, so no agent can park an
  approval in a background place. `WakilKit` covers the state transitions.
- **The red `— failed` chip** (Rule 8): no check. A failed turn needs the stub to die mid-turn;
  the only way today is a hold left to its 120 s ceiling, too slow for the suite.
- **One journal line carrying both the session and the place** (spec §5): the journal arm
  matches a substring and a line's keys come in no fixed order, so `bg-agent-chip-return`
  asserts each agent's call, a session and the `qa` place on separate lines, not tied together.
- **An agent's own `ctx_set_*` is refused** (Invariant 5, amended): not asserted here. The
  harness's dispatch is now the place's agent and is refused ("place is pinned"), which a
  `dispatch` with `refuses` could hold; no check carries it yet.
- **Quitting with agents running asks nothing; each resumes from Continue** (Rule 1; walk 8):
  a check cannot quit and relaunch inside one launch.
- **A chip over the Landing at 1000 wide** (layout): `bg-agent-chip-over-landing` is red and
  quarantined. With the Landing shown the window's content is wider than the window, so the chip
  sits at x 777–1048 in a 1000-wide window. The overflow predates this branch: the capacity
  indicator is at x 894–1040 at the merge-base too.
- **Switching out of the rootless project**: `project-root-note` is intermittent and
  quarantined. Twice in three runs the palette's switch to `e2e-project` was still "working"
  after 3 s.
- **The api pane's path-part controls**: `api-bound-locks` and `api-unbind` are red and
  quarantined. `api.path.part.N.remove` and `.unbind` resolve to no element. Both fail the same
  way against the merge-base, so this predates the branch.
- **A click on a part-covered editor takes focus** (Rule 6): `3b-v-click-focuses-pane` is red
  and quarantined. The check moves `editor-2` to x 720, the canvas clamps it to 620, and the
  click lands at the pane's centre (≈786 pt in the window), under the 220 pt Rail — so the
  Rail's list (the unnamed `AXOutline`) takes focus, `editor-2` is never focused and "q" goes
  nowhere. It fails the same way against the merge-base bundle (2dfec0e), so this predates the
  branch; the Files tree change (389378a) is not the cause.
- **A regex search over the 200 MiB haystack before Replace All** (`3b-ii-b-replace-cancel`):
  intermittent and quarantined. Green in the first seven full runs on this stack, red in the last
  two, both times at step 15 alone: the search must walk all of `bulk/` to reach `zz-marker.txt`,
  and its one result was in the pane when the evidence was taken, just past the 3 s settle.
  Latency, not a wrong answer; every later step (the cancel, its journal line) passed. Two reds
  running means the search now sits at the edge of the settle — worth timing before it leaves
  quarantine.
- **Did the right real account get used** against a live provider: the operator's, always.

<!-- machine-walk: generated by `make e2e-runbook`; everything between these markers is overwritten -->

**The machine walk is green:** every check ran against this build, every check this branch added was seen to fail against the merge-base, and the surface it added carries checks.

Walked by `make e2e` against 02f8a4d87eaa, rendered 2026-10-18 11:26 UTC by `make e2e-runbook`. Re-render it with that target; edits between the markers are overwritten.

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
| `2c-iii-7-org-switch.jsonl` | ✓ exit 0 | proved elsewhere: make e2e-retrodict: 5-switch-stops-the-journal | 13 | — |
| `2d-ii-composer-keeps-input.jsonl` | ✓ exit 0 | not new on this branch | 5 | — |
| `2d-ii-composer-return-sends.jsonl` | ✓ exit 0 | not new on this branch | 4 | — |
| `2d-ii-settings-speech.jsonl` | ✓ exit 0 | not new on this branch | 8 | — |
| `2d-ii-voice-escape.jsonl` | ✓ exit 0 | not new on this branch | 8 | — |
| `2d-ii-voice-lands-focused.jsonl` | ✓ exit 0 | not new on this branch | 5 | — |
| `2d-ii-voice-lands-unsent.jsonl` | ✓ exit 0 | not new on this branch | 7 | — |
| `2d-ii-voice-silence.jsonl` | ✓ exit 0 | not new on this branch | 5 | — |
| `2e-settings-databases-dispatch.jsonl` | ✓ exit 0 | not new on this branch | 10 | — |
| `2e-settings-databases.jsonl` | ✓ exit 0 | not new on this branch | 20 | — |
| `2e-settings-doors.jsonl` | ✓ exit 0 | not new on this branch | 7 | — |
| `2e-settings-narrow-rows.jsonl` | ✓ exit 0 | ✓ red vs c861b6eaed61, recorded 2026-10-15 | 2 | — |
| `2e-settings-organisation.jsonl` | ✓ exit 0 | not new on this branch | 7 | — |
| `2e-settings-pane.jsonl` | ✓ exit 0 | not new on this branch | 10 | — |
| `2e-settings-unlink-indicator.jsonl` | ✓ exit 0 | ✓ red vs b4410759858c, recorded 2026-10-15 | 4 | — |
| `2e-settings-unlink.jsonl` | ✓ exit 0 | not new on this branch | 11 | — |
| `365-terminal-option-word.jsonl` | ✓ exit 0 | ✓ red vs d42426358835, recorded 2026-10-15 | 3 | — |
| `365-terminal-paste.jsonl` | ✓ exit 0 | ✓ red vs f25a762e5ee7, recorded 2026-10-09 | 4 | — |
| `365-terminal-select-backspace.jsonl` | ✓ exit 0 | ✓ red vs f25a762e5ee7, recorded 2026-10-09 | 3 | — |
| `365-terminal-select-type.jsonl` | ✓ exit 0 | ✓ red vs f25a762e5ee7, recorded 2026-10-09 | 4 | — |
| `3b-i-editor-close-keys.jsonl` | ✓ exit 0 | ✓ red vs 0c9e85c6f259, recorded 2026-10-12 | 25 | — |
| `3b-i-editor-disk-changed.jsonl` | ✓ exit 0 | ✓ red vs 0c9e85c6f259, recorded 2026-10-12 | 34 | — |
| `3b-i-editor-files-palette.jsonl` | ✓ exit 0 | ✓ red vs 0c9e85c6f259, recorded 2026-10-12 | 13 | — |
| `3b-i-editor-read-only.jsonl` | ✓ exit 0 | ✓ red vs 0c9e85c6f259, recorded 2026-10-12 | 10 | — |
| `3b-i-editor-refusals.jsonl` | ✓ exit 0 | ✓ red vs 0c9e85c6f259, recorded 2026-10-12 | 24 | — |
| `3b-i-editor-save-as-field.jsonl` | ✓ exit 0 | ✓ red vs 0c9e85c6f259, recorded 2026-10-12 | 24 | — |
| `3b-i-editor-save-as-replace.jsonl` | ✓ exit 0 | ✓ red vs 0c9e85c6f259, recorded 2026-10-12 | 16 | — |
| `3b-i-editor-scratch-save.jsonl` | ✓ exit 0 | ✓ red vs 0c9e85c6f259, recorded 2026-10-12 | 27 | — |
| `3b-i-editor-tabs-language.jsonl` | ✓ exit 0 | ✓ red vs 0c9e85c6f259, recorded 2026-10-12 | 22 | — |
| `3b-i-editor-unsaved-org-switch.jsonl` | ✓ exit 0 | ✓ red vs a2a8b3fc9050 | 11 | — |
| `3b-i-editor-unsaved-quit.jsonl` | ✓ exit 0 | ✓ red vs 0c9e85c6f259, recorded 2026-10-12 | 11 | — |
| `3b-i-editor-unsaved-save.jsonl` | ✓ exit 0 | ✓ red vs 0c9e85c6f259, recorded 2026-10-12 | 16 | — |
| `3b-ii-b-replace-all.jsonl` | ✓ exit 0 | proved elsewhere: assertions unchanged; only the switch at the top changed, from a dispatched ctx_set_* (refused since 35a82d2: the channel is the place's own agent) to the operator's ⌘P/⌘K — proved red on its own branch (e2e/checks/proofs/3b-ii-b-replace-all.json) | 25 | — |
| `3b-ii-b-replace-cancel.jsonl` | ✓ exit 0 | proved elsewhere: assertions unchanged; only the switch at the top changed, from a dispatched ctx_set_* (refused since 35a82d2: the channel is the place's own agent) to the operator's ⌘P/⌘K — proved red on its own branch (e2e/checks/proofs/3b-ii-b-replace-cancel.json) | 0 | — |
| `3b-ii-b-replace-file.jsonl` | ✓ exit 0 | proved elsewhere: assertions unchanged; only the switch at the top changed, from a dispatched ctx_set_* (refused since 35a82d2: the channel is the place's own agent) to the operator's ⌘P/⌘K — proved red on its own branch (e2e/checks/proofs/3b-ii-b-replace-file.json) | 20 | — |
| `3b-ii-b-replace-undo.jsonl` | ✓ exit 0 | proved elsewhere: assertions unchanged; only the switch at the top changed, from a dispatched ctx_set_* (refused since 35a82d2: the channel is the place's own agent) to the operator's ⌘P/⌘K — proved red on its own branch (e2e/checks/proofs/3b-ii-b-replace-undo.json) | 21 | — |
| `3b-ii-b-reveal.jsonl` | ✓ exit 0 | proved elsewhere: assertions unchanged; only the switch at the top changed, from a dispatched ctx_set_* (refused since 35a82d2: the channel is the place's own agent) to the operator's ⌘P/⌘K — proved red on its own branch (e2e/checks/proofs/3b-ii-b-reveal.json) | 14 | — |
| `3b-ii-b-tab-move.jsonl` | ✓ exit 0 | proved elsewhere: assertions unchanged; only the switch at the top changed, from a dispatched ctx_set_* (refused since 35a82d2: the channel is the place's own agent) to the operator's ⌘P/⌘K — proved red on its own branch (e2e/checks/proofs/3b-ii-b-tab-move.json) | 12 | — |
| `3b-ii-find.jsonl` | ✓ exit 0 | proved elsewhere: assertions unchanged; only the switch at the top changed, from a dispatched ctx_set_* (refused since 35a82d2: the channel is the place's own agent) to the operator's ⌘P/⌘K — proved red on its own branch (e2e/checks/proofs/3b-ii-find.json) | 11 | — |
| `3b-ii-palette-ignored.jsonl` | ✓ exit 0 | proved elsewhere: assertions unchanged; only the switch at the top changed, from a dispatched ctx_set_* (refused since 35a82d2: the channel is the place's own agent) to the operator's ⌘P/⌘K — proved red on its own branch (e2e/checks/proofs/3b-ii-palette-ignored.json) | 9 | — |
| `3b-ii-refusals.jsonl` | ✓ exit 0 | proved elsewhere: assertions unchanged; only the switch at the top changed, from a dispatched ctx_set_* (refused since 35a82d2: the channel is the place's own agent) to the operator's ⌘P/⌘K — proved red on its own branch (e2e/checks/proofs/3b-ii-refusals.json) | 8 | — |
| `3b-ii-search-cancel.jsonl` | ✓ exit 0 | proved elsewhere: assertions unchanged; only the switch at the top changed, from a dispatched ctx_set_* (refused since 35a82d2: the channel is the place's own agent) to the operator's ⌘P/⌘K — proved red on its own branch (e2e/checks/proofs/3b-ii-search-cancel.json) | 15 | — |
| `3b-ii-search-errors.jsonl` | ✓ exit 0 | proved elsewhere: assertions unchanged; only the switch at the top changed, from a dispatched ctx_set_* (refused since 35a82d2: the channel is the place's own agent) to the operator's ⌘P/⌘K — proved red on its own branch (e2e/checks/proofs/3b-ii-search-errors.json) | 12 | — |
| `3b-ii-search.jsonl` | ✓ exit 0 | proved elsewhere: assertions unchanged; only the switch at the top changed, from a dispatched ctx_set_* (refused since 35a82d2: the channel is the place's own agent) to the operator's ⌘P/⌘K — proved red on its own branch (e2e/checks/proofs/3b-ii-search.json) | 46 | — |
| `3b-ii-tree-ignored-heavy.jsonl` | ✓ exit 0 | proved elsewhere: assertions unchanged; only the switch at the top changed, from a dispatched ctx_set_* (refused since 35a82d2: the channel is the place's own agent) to the operator's ⌘P/⌘K — proved red on its own branch (e2e/checks/proofs/3b-ii-tree-ignored-heavy.json) | 12 | — |
| `3b-ii-tree-live.jsonl` | ✓ exit 0 | proved elsewhere: assertions unchanged; only the switch at the top changed, from a dispatched ctx_set_* (refused since 35a82d2: the channel is the place's own agent) to the operator's ⌘P/⌘K — proved red on its own branch (e2e/checks/proofs/3b-ii-tree-live.json) | 14 | — |
| `3b-ii-tree-preview.jsonl` | ✓ exit 0 | proved elsewhere: assertions unchanged; only the switch at the top changed, from a dispatched ctx_set_* (refused since 35a82d2: the channel is the place's own agent) to the operator's ⌘P/⌘K — proved red on its own branch (e2e/checks/proofs/3b-ii-tree-preview.json) | 22 | — |
| `3b-ii-tree-toggle.jsonl` | ✓ exit 0 | proved elsewhere: assertions unchanged; only the switch at the top changed, from a dispatched ctx_set_* (refused since 35a82d2: the channel is the place's own agent) to the operator's ⌘P/⌘K — proved red on its own branch (e2e/checks/proofs/3b-ii-tree-toggle.json) | 17 | — |
| `3b-iii-changes-drill.jsonl` | ✓ exit 0 | proved elsewhere: assertions unchanged; only the switch to e2e-git changed, from a dispatched ctx_set_project (refused since 35a82d2: the channel is the place's own agent) to the operator's ⌘P — proved red on 3b-iii's own branch (e2e/checks/proofs/3b-iii-changes-drill.json) | 60 | — |
| `3b-iii-changes-keys.jsonl` | ✓ exit 0 | proved elsewhere: assertions unchanged; only the switch to e2e-git changed, from a dispatched ctx_set_project (refused since 35a82d2: the channel is the place's own agent) to the operator's ⌘P — proved red on 3b-iii's own branch (e2e/checks/proofs/3b-iii-changes-keys.json) | 37 | — |
| `3b-iii-changes-list.jsonl` | ✓ exit 0 | proved elsewhere: assertions unchanged; only the switch to e2e-git changed, from a dispatched ctx_set_project (refused since 35a82d2: the channel is the place's own agent) to the operator's ⌘P — proved red on 3b-iii's own branch (e2e/checks/proofs/3b-iii-changes-list.json) | 33 | — |
| `3b-iii-changes-live.jsonl` | ✓ exit 0 | proved elsewhere: assertions unchanged; only the switch to e2e-git changed, from a dispatched ctx_set_project (refused since 35a82d2: the channel is the place's own agent) to the operator's ⌘P — proved red on 3b-iii's own branch (e2e/checks/proofs/3b-iii-changes-live.json) | 42 | — |
| `3b-iii-changes-press.jsonl` | ✓ exit 0 | proved elsewhere: assertions unchanged; only the switch to e2e-git changed, from a dispatched ctx_set_project (refused since 35a82d2: the channel is the place's own agent) to the operator's ⌘P — proved red on 3b-iii's own branch (e2e/checks/proofs/3b-iii-changes-press.json) | 25 | — |
| `3b-iii-diff-open-file.jsonl` | ✓ exit 0 | proved elsewhere: assertions unchanged; only the switch to e2e-git changed, from a dispatched ctx_set_project (refused since 35a82d2: the channel is the place's own agent) to the operator's ⌘P — proved red on 3b-iii's own branch (e2e/checks/proofs/3b-iii-diff-open-file.json) | 25 | — |
| `3b-iii-diff-refusals.jsonl` | ✓ exit 0 | proved elsewhere: assertions unchanged; only the switch to e2e-git changed, from a dispatched ctx_set_project (refused since 35a82d2: the channel is the place's own agent) to the operator's ⌘P — proved red on 3b-iii's own branch (e2e/checks/proofs/3b-iii-diff-refusals.json) | 21 | — |
| `3b-iii-git-pane-migrates.jsonl` | ✓ exit 0 | proved elsewhere: assertions unchanged; only the switch to e2e-git changed, from a dispatched ctx_set_project (refused since 35a82d2: the channel is the place's own agent) to the operator's ⌘P — proved red on 3b-iii's own branch (e2e/checks/proofs/3b-iii-git-pane-migrates.json) | 16 | — |
| `3b-iii-palette-changed-file.jsonl` | ✓ exit 0 | proved elsewhere: assertions unchanged; only the switch to e2e-git changed, from a dispatched ctx_set_project (refused since 35a82d2: the channel is the place's own agent) to the operator's ⌘P — proved red on 3b-iii's own branch (e2e/checks/proofs/3b-iii-palette-changed-file.json) | 16 | — |
| `3b-iii-peek.jsonl` | ✓ exit 0 | proved elsewhere: assertions unchanged; only the switch to e2e-git changed, from a dispatched ctx_set_project (refused since 35a82d2: the channel is the place's own agent) to the operator's ⌘P — proved red on 3b-iii's own branch (e2e/checks/proofs/3b-iii-peek.json) | 44 | — |
| `3b-iii-tree-letters.jsonl` | ✓ exit 0 | proved elsewhere: assertions unchanged; only the switch to e2e-git changed, from a dispatched ctx_set_project (refused since 35a82d2: the channel is the place's own agent) to the operator's ⌘P — proved red on 3b-iii's own branch (e2e/checks/proofs/3b-iii-tree-letters.json) | 15 | — |
| `3b-v-click-focuses-pane.jsonl` | ✓ exit 0 | ✓ red vs 570f9eee022f, recorded 2026-10-15 | 0 | — |
| `3b-v-editor-autosave-focus.jsonl` | ✓ exit 0 | ✓ red vs e6c782b4f52f, recorded 2026-10-13 | 22 | — |
| `3b-v-editor-autosave-pause.jsonl` | ✓ exit 0 | ✓ red vs e6c782b4f52f, recorded 2026-10-13 | 23 | — |
| `3b-v-editor-autosave-prompt-guard.jsonl` | ✓ exit 0 | ✓ red vs e6c782b4f52f, recorded 2026-10-13 | 18 | — |
| `3b-v-editor-indent-scratch.jsonl` | ✓ exit 0 | ✓ red vs e6c782b4f52f, recorded 2026-10-13 | 11 | — |
| `3b-v-editor-live-options.jsonl` | ✓ exit 0 | ✓ red vs e6c782b4f52f, recorded 2026-10-13 | 21 | — |
| `3b-v-editor-settings-nodes.jsonl` | ✓ exit 0 | **proved red vs e6c782b4f52f on an earlier version — not re-proved** | 28 | — |
| `3b-v-heavy-folders-edit.jsonl` | ✓ exit 0 | ✓ red vs 5c38f72852bf, recorded 2026-10-14 | 21 | — |
| `3b-v-heavy-folders-refusal.jsonl` | ✓ exit 0 | **proved red vs 5c38f72852bf on an earlier version — not re-proved** | 24 | — |
| `3b-v-heavy-folders.jsonl` | ✓ exit 0 | proved elsewhere: make e2e-new E2E_NEW_ARGS='--base 5c38f728 e2e/checks/seeded/3b-v-heavy-folders.jsonl': red at step 5, the Show ignored files control not there | 41 | — |
| `3b-v-project-editor-settings.jsonl` | ✓ exit 0 | **proved red vs e6c782b4f52f on an earlier version — not re-proved** | 19 | — |
| `3b-v-show-ignored.jsonl` | ✓ exit 0 | proved elsewhere: make e2e-new E2E_NEW_ARGS='--base 5c38f728 e2e/checks/seeded/3b-v-show-ignored.jsonl': red at step 5, no SHOW IGNORED FILES section | 27 | — |
| `agent-pane-is-drawn.jsonl` | ✓ exit 0 | not new on this branch | 4 | — |
| `api-bind.jsonl` | ✓ exit 0 | not new on this branch | 9 | — |
| `api-body-editor.jsonl` | ✓ exit 0 | not new on this branch | 13 | — |
| `api-body-hole-cursor.jsonl` | ✓ exit 0 | not new on this branch | 3 | — |
| `api-bound-locks.jsonl` | ✓ exit 0 | not new on this branch | 0 | — |
| `api-cancel.jsonl` | ✓ exit 0 | not new on this branch | 15 | — |
| `api-chip-keys-second-chip.jsonl` | ✓ exit 0 | not new on this branch | 11 | — |
| `api-chip-keys-text-after.jsonl` | ✓ exit 0 | not new on this branch | 8 | — |
| `api-chip-keys.jsonl` | ✓ exit 0 | not new on this branch | 9 | — |
| `api-editor-copy-bound.jsonl` | ✓ exit 0 | not new on this branch | 7 | — |
| `api-editor-json-holes.jsonl` | ✓ exit 0 | not new on this branch | 8 | — |
| `api-editor-wrap.jsonl` | ✓ exit 0 | not new on this branch | 7 | — |
| `api-env-roundtrip.jsonl` | ✓ exit 0 | ✓ red vs a2a8b3fc9050 | 23 | — |
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
| `api-unbind.jsonl` | ✓ exit 0 | not new on this branch | 0 | — |
| `bg-env-switch-own-canvas.jsonl` | ✓ exit 0 | ✓ red vs a2a8b3fc9050 | 16 | — |
| `bg-org-switch-asks-nothing.jsonl` | ✓ exit 0 | ✓ red vs a2a8b3fc9050 | 8 | — |
| `bg-org-switch-keeps-the-terminal.jsonl` | ✓ exit 0 | ✓ red vs a2a8b3fc9050 | 10 | — |
| `capacity-low-reading.jsonl` | ✓ exit 0 | ✓ red vs 1402c099d411, recorded 2026-10-11 | 9 | — |
| `capacity-passed-reset.jsonl` | ✓ exit 0 | ✓ red vs 1402c099d411, recorded 2026-10-11 | 6 | — |
| `db-cancel-click.jsonl` | ✓ exit 0 | **proved red vs e6c782b4f52f on an earlier version — not re-proved** | 23 | — |
| `db-cancel-escape.jsonl` | ✓ exit 0 | **proved red vs e6c782b4f52f on an earlier version — not re-proved** | 10 | — |
| `db-detail-big-cells.jsonl` | ✓ exit 0 | **proved red vs e6c782b4f52f on an earlier version — not re-proved** | 13 | — |
| `db-detail-strip.jsonl` | ✓ exit 0 | **proved red vs e6c782b4f52f on an earlier version — not re-proved** | 25 | — |
| `db-grid-copy.jsonl` | ✓ exit 0 | **proved red vs e6c782b4f52f on an earlier version — not re-proved** | 7 | — |
| `db-query-line-agent-replaces.jsonl` | ✓ exit 0 | **proved red vs 3c9c923b17ca on an earlier version — not re-proved** | 8 | — |
| `db-query-line-format.jsonl` | ✓ exit 0 | **proved red vs 3c9c923b17ca on an earlier version — not re-proved** | 5 | — |
| `db-query-line-long.jsonl` | ✓ exit 0 | **proved red vs 3c9c923b17ca on an earlier version — not re-proved** | 5 | — |
| `db-query-line-not-formatted.jsonl` | ✓ exit 0 | **proved red vs 3c9c923b17ca on an earlier version — not re-proved** | 6 | — |
| `db-query-line-return.jsonl` | ✓ exit 0 | **proved red vs 3c9c923b17ca on an earlier version — not re-proved** | 9 | — |
| `db-query-line-run.jsonl` | ✓ exit 0 | not new on this branch | 9 | — |
| `journal-error-reason.jsonl` | ✓ exit 0 | ✓ red vs dfb508b06420, recorded 2026-10-08 | 2 | — |
| `landing.jsonl` | ✓ exit 0 | not new on this branch | 5 | — |
| `palette-api-entry.jsonl` | ✓ exit 0 | ✓ red vs f25a762e5ee7, recorded 2026-10-10 | 9 | — |
| `palette-api-send.jsonl` | ✓ exit 0 | ✓ red vs f25a762e5ee7, recorded 2026-10-10 | 10 | — |
| `palette-command-step.jsonl` | ✓ exit 0 | ✓ red vs f25a762e5ee7, recorded 2026-10-10 | 12 | — |
| `palette-escape.jsonl` | ✓ exit 0 | ✓ red vs f25a762e5ee7, recorded 2026-10-10 | 11 | — |
| `palette-modes.jsonl` | ✓ exit 0 | ✓ red vs f25a762e5ee7, recorded 2026-10-10 | 16 | — |
| `palette-open-kinds.jsonl` | ✓ exit 0 | ✓ red vs 2dfec0ee0c10, recorded 2026-10-16 | 15 | — |
| `palette-run-error.jsonl` | ✓ exit 0 | ✓ red vs f25a762e5ee7, recorded 2026-10-10 | 13 | — |
| `palette-switch-environment.jsonl` | ✓ exit 0 | ✓ red vs a2a8b3fc9050 | 19 | — |
| `palette-table-row.jsonl` | ✓ exit 0 | **proved red vs f25a762e5ee7 on an earlier version — not re-proved** | 11 | — |
| `project-root-note.jsonl` | ✓ exit 0 | proved elsewhere: make e2e-new E2E_NEW_ARGS='--base 80c97d7e^ …': red at step 4, the note was fixed at launch and never appeared for the rootless project | 0 | — |
| `vocabulary.jsonl` | ✓ exit 0 | ✓ red vs f25a762e5ee7, recorded 2026-10-10 | 8 | — |
| `2d-i-code-hint.jsonl` | ✓ exit 0 | proved elsewhere: assertions unchanged from 2d-i, where make e2e-new proved them red vs fb7e8f09d0f3 (docs/wakil/phase-2d-i-acceptance.md); 2d-ii changed only the send act (window.send → Return), proved red vs the merge-base by seeded/2d-ii-composer-return-sends.jsonl | 16 | — |
| `2d-i-failed-source.jsonl` | ✓ exit 0 | proved elsewhere: assertions unchanged from 2d-i, where make e2e-new proved them red vs fb7e8f09d0f3 (docs/wakil/phase-2d-i-acceptance.md); 2d-ii changed only the send act (window.send → Return), proved red vs the merge-base by seeded/2d-ii-composer-return-sends.jsonl | 15 | — |
| `2d-i-hint-or-plain.jsonl` | ✓ exit 0 | **proved red vs fb7e8f09d0f3 on an earlier version — not re-proved** | 8 | — |
| `2d-i-over-limit.jsonl` | ✓ exit 0 | **proved red vs fb7e8f09d0f3 on an earlier version — not re-proved** | 5 | — |
| `2d-i-pane-hint.jsonl` | ✓ exit 0 | **proved red vs fb7e8f09d0f3 on an earlier version — not re-proved** | 5 | — |
| `2d-i-schema-hint.jsonl` | ✓ exit 0 | proved elsewhere: assertions unchanged from 2d-i, where make e2e-new proved them red vs fb7e8f09d0f3 (docs/wakil/phase-2d-i-acceptance.md); 2d-ii changed only the send act (window.send → Return), proved red vs the merge-base by seeded/2d-ii-composer-return-sends.jsonl | 14 | — |
| `2d-ii-thread-earlier.jsonl` | ✓ exit 0 | not new on this branch | 12 | — |
| `2d-ii-voice-turn.jsonl` | ✓ exit 0 | not new on this branch | 10 | — |
| `3b-iii-changes-voice-hint.jsonl` | ✓ exit 0 | proved elsewhere: assertions unchanged; only the switch to e2e-git changed, from a dispatched ctx_set_project (refused since 35a82d2: the channel is the place's own agent) to the operator's ⌘P. main carried it with no proof (docs/wakil/phase-3b-iii-acceptance.md: "not new on this branch"), so it was run against 2dfec0e, main before 3b-iii, with `wakil-e2e-new --base 2dfec0e` on 2026-10-18: red at step 9, column.view "files", want "changes". That run was flagged for a click during bg-agent-chip-return.jsonl only; none arrived during this check | 8 | — |
| `api-origin-after-account-switch.jsonl` | ✓ exit 0 | ✓ red vs 9e657511c804, recorded 2026-10-15 | 3 | — |
| `bg-agent-chip-more.jsonl` | ✓ exit 0 | ✓ red vs a2a8b3fc9050 | 25 | — |
| `bg-agent-chip-narrow.jsonl` | ✓ exit 0 | ✓ red vs a2a8b3fc9050 | 16 | — |
| `bg-agent-chip-over-landing.jsonl` | ✓ exit 0 | ✓ red vs a2a8b3fc9050 | 0 | — |
| `bg-agent-chip-return.jsonl` | ✓ exit 0 | ✓ red vs a2a8b3fc9050 | 30 | — |
| `both-surfaces.jsonl` | ✓ exit 0 | not new on this branch | 6 | — |
| `capacity-after-turn.jsonl` | ✓ exit 0 | ✓ red vs 1402c099d411, recorded 2026-10-11 | 7 | — |
| `two-enter.jsonl` | ✓ exit 0 | not new on this branch | 13 | — |
| `.scratch/background-work/e2e/probe/landing-after-panes.jsonl` | — | — | — | a record for a check the corpus no longer holds |
| `.scratch/background-work/e2e/probe/landing-width.jsonl` | — | — | — | a record for a check the corpus no longer holds |
| `.scratch/background-work/e2e/probe/org-landing.jsonl` | — | — | — | a record for a check the corpus no longer holds |
| `.scratch/background-work/e2e/probe/show-ignored-head.jsonl` | — | — | — | a record for a check the corpus no longer holds |
| `.scratch/background-work/e2e/probe/tree-no-settings.jsonl` | — | — | — | a record for a check the corpus no longer holds |
| `e2e/checks/agent/3a-i-git-voice-hint.jsonl` | — | — | — | a record for a check the corpus no longer holds |
| `e2e/checks/seeded/3a-i-git-drill.jsonl` | — | — | — | a record for a check the corpus no longer holds |
| `e2e/checks/seeded/3a-i-git-keys.jsonl` | — | — | — | a record for a check the corpus no longer holds |
| `e2e/checks/seeded/3a-i-git-list.jsonl` | — | — | — | a record for a check the corpus no longer holds |
| `e2e/checks/seeded/3a-i-git-live.jsonl` | — | — | — | a record for a check the corpus no longer holds |
| `e2e/checks/seeded/3a-i-git-press.jsonl` | — | — | — | a record for a check the corpus no longer holds |
| `e2e/checks/seeded/palette-new-git-parity.jsonl` | — | — | — | a record for a check the corpus no longer holds |

**`make e2e-new` saw every check this branch added go red against a2a8b3fc9050.**

**Every action and control this branch added carries a check.** 0 action(s) and 3 control(s) are new on this branch.

- actions:  63 of 104 dispatched by a check
- writes:   20 of 75 carry a parity check
- controls: 122 of 211 exercised by a check

**92 piece(s) of surface no check can reach**, each with the reason given in `e2e/checks/uncoverable.tsv`:

- `api_cancel` — its parity: the click cancels the send in flight, and api_cancel refuses a pane with nothing in flight (`nothingInFlight`), so the dispatch half cannot be given the same state — and a second Send between the halves is not expressible. Both channels ARE covered by api-cancel.jsonl, each after its own Send, asserting the same cancelled response through read_pane; what no check can express is the comparison.
- `editor_close` — its parity (3b-i): the operator's channels are ⌘W (a key) and the unsaved prompt's Don't Save, and the click consumes its own subject — the dispatch half after it would close a different tab or be refused (`the editor pane has no open tab`), api_cancel's case. Both channels ARE covered: 3b-i-editor-close-keys.jsonl (⌘W clean, ⌘W dirty → Esc / Cancel / Don't Save) and the dispatch with and without discard in 3b-i-editor-refusals.jsonl.
- `ctx_provider_login` — #254. Opens a browser on the operator's machine and authenticates as them. No harness can drive it and none should: every run would leave a real credential behind.
- `editor_new_scratch` — its parity (3b-i): the operator's channel is ⌘T, a menu key equivalent — a key, not a click or a drag, and the UI half of a parity step is a click or a drag only (api_fill_from_curl's case); the empty pane only names the key. The dispatch is covered by most 3b-i-editor-* checks; ⌘T by 3b-i-editor-scratch-save.jsonl and 3b-i-editor-close-keys.jsonl, asserting the Untitled-N tab through read_pane.
- `editor_replace_undo` — its parity (3b-ii-b): the Undo click spends the pane's one undo, and the dispatch after it is then refused (`no replace to undo`) — api_undo_fill's case. The click is 3b-ii-b-replace-undo.jsonl's (undone, restored 2, and the changed-since line for the file changed on disk), and so is the refusal of the dispatch after it.
- `api_undo_fill` — its parity: the Undo click forgets the fill it undoes, and api_undo_fill refuses a pane with nothing to undo, so the dispatch half cannot be given the same state after the click — and a second fill between the halves is not expressible inside one parity step. Both channels ARE covered by api-paste-curl.jsonl, the click after one fill and the dispatch after another, each asserting the same restored draft through read_pane; what no check can express is the comparison.
- `editor_goto` — its parity (3b-i): there is no operator control for it — the operator moves the cursor inside Monaco, the one non-action path (design-language §11), so no UI half exists to compare. The dispatch is covered by 3b-i-editor-tabs-language.jsonl (cursor.line and cursor.column through read_pane) and refused on an empty pane in 3b-i-editor-refusals.jsonl.
- `editor_move_tab` — its parity (3b-ii-b): the drag moves a tab, and the same {from, to} dispatched on the moved strip moves a different tab, so the two halves cannot read back the same order. The drag and the dispatch are each 3b-ii-b-tab-move.jsonl's, each asserting the strip's order and the active tab through read_pane.
- `api_render_curl` — Two reasons, and the second is the one that lasts. A dispatch cannot hold the row id, which is minted per send and published only in read_pane; and the operator's own Copy as cURL puts its line on the PASTEBOARD, which no check can read — the act is real and its result leaves the window. `api_reopen`'s CLICK left this file when the recent strip gave it a button, because a reopen's effect lands in the draft where a check can see it; its dispatch half is still here, for the first of these reasons. Covered by WakilKitTests: curlIsPastTenseOnly, curlOnlyMentionsACredentialThereWasOne, curlEmitsAndNeverParses.
- `editor_replace_range` — its parity (3b-i): no operator control — the operator's own edits are typing in Monaco, the one non-action path (`editorBufferDidChange`), so no UI half exists. The dispatch is covered by most 3b-i-editor-* checks, and its read-only refusal by 3b-i-editor-read-only.jsonl.
- `editor_select` — its parity (3b-i): no operator control — the operator selects inside Monaco, the one non-action path, so no UI half exists. The dispatch is covered by most 3b-i-editor-* checks, which read selected_text back to prove what a save wrote.
- `settings_open` — its parity: the only UI path is the `Settings…` MENU item, and a menu's buttons are not in the accessibility tree until the menu is open — the same rule that excuses every other menu control. Checks drive it by its real gesture, cmd+comma, and 2e-settings-pane.jsonl also dispatches it.
- `editor_restore` — its parity (3b-i): no operator control — it runs when a window relaunches onto saved tabs, and one check is one launch. The dispatch is covered by 3b-i-editor-disk-changed.jsonl (an open, dirty tab is kept as it is); restoring after a relaunch is the runbook's row 9.
- `editor_peek_step` — its parity (3b-iii): the operator's channels are ↑↓ while the peek is open (keys Monaco hands back) and the peek's ↑ ↓ buttons, which are HTML inside the WKWebView with no accessibility identifier — neither is a click on a control the resolver can address. Both the dispatch and ↑↓ ARE covered by 3b-iii-peek.jsonl, each asserting peek.index and the cursor through read_pane; the buttons are walk-only (row 8 presses ↓, a key).
- `ctx_add_provider` — its parity: the click creates a binding under an id, so a dispatch with the same params collides with what the click just made. Covered by 2e-settings-doors.jsonl up to the browser leg.
- `db_remove_database` — its parity: the click removes the database, and removing one that is gone is refused (`no database … in environment …`), so the dispatch half cannot be given the same params. Dispatch is covered by 2e-settings-databases-dispatch.jsonl and the click by 2e-settings-databases.jsonl; what no check can express is the comparison.
- `api_reopen` — its dispatch: it needs a row id, which is minted per send and published only in read_pane — the same reason api_render_curl below is here. The operator's gesture IS covered: api-recent.jsonl presses api.recent.0.reopen and asserts the draft it rebuilds. Permanent, not blocked: nothing in the vocabulary carries a value from read_pane into a dispatch.
- `db_cancel` — its parity: the click (or Esc) cancels the read in flight, and db_cancel refuses a pane with nothing running (`nothing is running on pane …`), so the dispatch half cannot be given the same state — and a second slow read between the halves is not expressible inside one parity step, api_cancel's case. Both channels ARE covered: db-cancel-click.jsonl cancels one recursive-CTE read by db.<pane>.cancel and the next by dispatch, asserting the same state after each through read_pane (running false, cancelledAfterMs, the previous 2 rows kept, sort empty) and "cancelled after" in the tree; db-cancel-escape.jsonl cancels by Esc. What no check can express is the comparison.
- `api_fill_from_curl` — its parity: the UI half of a parity step is a click or a drag, and the operator's channel is a paste (cmd+v into the path editor), so the comparison cannot be expressed. Both channels ARE covered: the dispatch by api-paste-curl.jsonl, the paste by api-paste-curl-hotkey.jsonl, each asserting the same draft and the Filled from cURL line; what no check can express is the comparison.
- `editor_peek_close` — its parity (3b-iii): the operator's channels are Esc in the peek (a key), typing (which closes it in the store), and the peek's × (HTML inside the WKWebView, no accessibility identifier). Esc, typing and the dispatch ARE each covered by 3b-iii-peek.jsonl, asserting peek null with the cursor and the marks kept; the × button is walk-only, in no runbook row.
- `ctx_unlink_provider` — its parity: the click removes the binding, so the dispatch half cannot be given the same id. Dispatch and both channels' behaviour ARE covered by 2e-settings-unlink.jsonl; what no check can express is the comparison.
- `editor_replace` — its parity (3b-ii-b): the click replaces, and the same dispatch after it finds nothing left to replace and answers a different last_replace, so the two halves cannot read back the same pane (api_cancel's case: the click consumes its own subject). Both channels ARE covered: the click (Replace All) by 3b-ii-b-replace-all.jsonl and the dispatch by 3b-ii-b-replace-undo.jsonl, each asserting last_replace's files and the Replaced … line; Replace in this file by 3b-ii-b-replace-file.jsonl, and Cancel by 3b-ii-b-replace-cancel.jsonl.
- `editor_open_file` — its parity (3b-iii): the operator's channel is ⌘⏎ in a diff tab, a menu key equivalent (Maximize Pane's item, which a diff tab redirects) — a key, not a click or a drag — so no UI half can be expressed. Both channels ARE covered by 3b-iii-diff-open-file.jsonl, each opening app.txt at the diff's cursor line with the diff tab kept, and ⌘⏎ on a scratch tab maximizing; its refusal on a deleted file by 3b-iii-changes-live.jsonl.
- `editor_changes_step` — its parity (3b-iii): the operator's channel is ↑↓ in the Changes view — keys, not a click or a drag — and the UI half of a parity step is a click or a drag only (api_fill_from_curl's case). Both channels ARE covered: the dispatch by 3b-iii-changes-drill.jsonl (across roots, both directions, clamped at the end, skipping a collapsed root, asserting the highlight and the diff tab through read_pane), the keys by 3b-iii-changes-keys.jsonl (↓ from nothing, ↑↓ across roots, after ⌘⇧G); what no check can express is the comparison.
- `editor_peek` — its parity (3b-iii): the operator's channel is a click on a change mark in Monaco's gutter, inside the WKWebView — a web element with no accessibility identifier, which the resolver cannot address (editor_goto's case: inside Monaco, the one non-action path). The dispatch is covered by 3b-iii-peek.jsonl (opened on a mark, refused on an unmarked line, on an untracked file and on a diff tab in 3b-iii-diff-refusals.jsonl); the mark click is the runbook's row 8.
- `capacity_record` — its parity: the operator's channel is the agent's own stream — the window records a `rate_limit_event` frame from a turn on its own, with no click or drag — so the UI half of a parity step cannot be expressed: no click or drag of the operator's produces it, so there is no UI half to compare. Both channels ARE covered: the dispatch by capacity-low-reading.jsonl and capacity-passed-reset.jsonl, the stream by agent/capacity-after-turn.jsonl, each asserting the reading it lands on the indicator; what no check can express is the comparison.
- `api_unbind` — its parity: the click returns the binding to its hole, and api_unbind refuses a position that holds no binding (`unbindNotABinding`), so the dispatch half cannot be given the same params — and a re-drag between the halves is not expressible. Both channels ARE covered by api-unbind.jsonl, each after its own drag, asserting the same hole back through read_pane; what no check can express is the comparison.
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
- `window.contextLine` — the context line's container (.contain, background agents 4 of 4): it holds the organisation, project and environment segments and takes no input itself — a click lands on a segment. Named so a layout check can hold the agent chips clear of it; read by frame, not pressed — agent/bg-agent-chip-narrow.jsonl and agent/bg-agent-chip-over-landing.jsonl assert the chip `clear` of it at the window's minimum.
- `window.thread` — the thought thread's container (.contain), which takes hits only on its rows and the "earlier" line. Its rows are pressed by 2d-ii-thread-earlier.jsonl as window.thread.row.<id> and window.thread.earlier.

**This section knows nothing about what a machine cannot see.** The visual rulings and the live-provider question stay the operator's, permanently; they are the human section below.

<!-- /machine-walk -->
