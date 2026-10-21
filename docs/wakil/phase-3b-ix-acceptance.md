# 3b-ix — the fast path: acceptance

**Spec:** [`2026-10-20-3b-ix-fast-path-design.md`](../superpowers/specs/2026-10-20-3b-ix-fast-path-design.md)
· **Charter:** Decision 10 amended (the fast path); Decision 42 amended

The exit criterion, from the spec: Return in the composer on a one-line navigation command
(*switch to staging*) runs it at once on the org's quick-tasks model, about 0.1 s on a local
model, with a receipt under the composer and **Ask the agent instead**. Anything else goes to the
agent as before. **Fast path** in Settings turns it off.

Nothing here is walked yet: the Walked column is empty until the operator ticks it.

## 0. Setup

Run in the repo root, on this Mac, after `make build` and `make app-bundle`.

Local server (once; the first start downloads the model):

```bash
brew install llama.cpp
llama-server -hf Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF:Q4_K_M --port 8012 -c 8192
```

Leave it running in its own Terminal window. Check it answers:
`curl -s http://127.0.0.1:8012/health` prints `{"status":"ok"}`.

Org and local provider (re-runnable; the org is `personal`, Claude account already linked):

```bash
export WAKIL_ORG=personal
./bin/wakil provider rm local || true
./bin/wakil provider add local --kind local --base-url http://127.0.0.1:8012
```

Launch with `WAKIL_ORG=personal app/Wakil.app/Contents/MacOS/Wakil`. Use a project with a
`staging` environment next to the active one, a source file `confirm.go` and no `orders.go`, and
a SQL environment with a `bookings` table. Open a DB pane and an editor tab with unsaved edits
ready for row 10.

Settings is ⌘, ; **QUICK TASKS** and **LOCAL MODELS** are on the organisation's Providers page.

## 1. The walk

| # | Do | Expect | Walked |
|---|---|---|---|
| 1 | Settings, Providers: read **QUICK TASKS** | Three rows: **Model** (dropdown: Same as agent, Accounts, Local models; *Code completion goes to …* under it), **Ghost-text** and **Fast path**, each an Off/On choice with a one-line hint. **LOCAL MODELS** rows have no checkboxes. Settings, Editor has no Ghost-text row | |
| 2 | Look at the accessibility ids (Accessibility Inspector) | `settings.org.quickProvider`, `settings.org.ghostText.off` and `.on`, `settings.org.fastPath.off` and `.on` are present | |
| 3 | With **Model** on Same as agent, read **Fast path** | **Off** is chosen (it defaults on only for a local model). Set **Model** to `local`: **Fast path** is **On** unless you set it before | |
| 4 | **Model**: `local`, **Fast path**: On. In the composer type `switch to staging`, Return | The context line changes to staging at once (about 0.1 s). No agent turn starts. A receipt shows under the composer: *Ran: switch environment to staging*, with **Ask the agent instead** | |
| 5 | Type `open confirm.go`, Return | `confirm.go` opens in an editor tab; receipt *Ran: open confirm.go*. The composer keeps focus | |
| 6 | Type `go to line 40`, Return | The editor caret goes to line 40; the receipt says so | |
| 7 | Type `show bookings`, Return | The DB pane shows the `bookings` table; the receipt says so | |
| 8 | Type `close the db pane`, Return | The DB pane closes, with no confirmation; the receipt says so | |
| 9 | Type a question (`why is checkout slow?`), Return | No receipt. An agent turn starts as it did before 3b-ix, about 0.1 s later | |
| 10 | Type `delete the draft bookings`, Return | No receipt, no action: the line goes to the agent as a normal turn (deletes are never on the list) | |
| 11 | Type `open orders.go`, Return (no such file) | No receipt: the line goes to the agent, which says it cannot find the file | |
| 12 | After row 4, click **Ask the agent instead** | The original line (`switch to staging`) is sent to the agent as a normal turn; the receipt goes | |
| 13 | After any receipt, press Esc in the empty composer | The receipt clears. Esc with text in the composer leaves the receipt | |
| 14 | With the editor tab that has unsaved edits focused, type `close this tab`, Return | The tab stays open. The receipt shows the refusal whole, in the warning colour, with **Ask the agent instead**; the line is not lost | |
| 15 | Stop the server (Ctrl-C in its Terminal), type `switch to staging`, Return | The line goes to the agent unchanged; Settings shows the connection error whole under the **Model** row | |
| 16 | Start the server again, repeat row 4 | The fast path runs it again; the error is gone | |
| 17 | Set **Fast path** to **Off**, type `switch to staging`, Return | No fast path: the line is an agent turn at once, no receipt. Set it **On** again and row 4 works | |
| 18 | Set **Model** to Same as agent and **Fast path** to On, type `switch to staging`, Return | It works on the Claude account, about 1 to 2.5 s with nothing shown while it waits; past 2.5 s the line goes to the agent | |
| 19 | Hold ⌥ and say a file name the speech model garbles (for example "open confirm dot go" heard as *open con firm go*), release, press Return | If the name is not an exact file in scope, the line goes to the agent, which resolves it as before; nothing wrong is opened | |
| 20 | Type `switch to staging`, press Return, and at once switch the project or environment in the context line | The fast path sends nothing; the line still goes to the agent of the place it was typed in | |

## 2. Known and not fixed

- **`term_open`'s `path` is kept only when it is a project root**; otherwise the terminal opens
  where it would with no path. The model is shown no directories.
- **A delete is caught by its first word** (delete, drop, remove, truncate, erase, purge, wipe).
  "Please get rid of the drafts" still reaches the model, whose prompt says a delete is the agent's.
- **File scope is the top 20 of the project's files**, gathered by ranking each word of the line
  with ⌘P's matcher and interleaving the lists. A file outside the top 20 for every word is out of
  scope, so the line goes to the agent.
- **A warm-up request runs after each quick-tasks rebuild**, so the first line after a Settings
  change is not slower than the rest. It is not shown anywhere.

## 3. Residue: what the walk cannot establish

- **The real Claude path is walked by hand and costs quota.** The e2e auditor uses a stub
  server on loopback.
- **Timing figures** (0.1 s local, 1 to 2.5 s on Claude) are the spec's measurements on one
  M5 Pro; the walk confirms they feel that way, not that they hold on other machines.
- **What the model answers for lines not in the examples** varies with the model; the checks
  pin the code that gates the answer, not the answer.

## 4. The machine walk

<!-- machine-walk: generated by `make e2e-runbook`; everything between these markers is overwritten -->

**The machine walk is green:** every check ran against this build, every check this branch added was seen to fail against the merge-base, and the surface it added carries checks.

Walked by `make e2e` against 0f063a1baa06, rendered 2026-10-21 12:43 UTC by `make e2e-runbook`. Re-render it with that target; edits between the markers are overwritten.

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
| `2c-iii-7-org-switch.jsonl` | ✓ exit 0 | not new on this branch | 13 | — |
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
| `3b-i-editor-unsaved-org-switch.jsonl` | ✓ exit 0 | ✓ red vs a2a8b3fc9050, recorded 2026-10-18 | 11 | — |
| `3b-i-editor-unsaved-quit.jsonl` | ✓ exit 0 | ✓ red vs 0c9e85c6f259, recorded 2026-10-12 | 11 | — |
| `3b-i-editor-unsaved-save.jsonl` | ✓ exit 0 | ✓ red vs 0c9e85c6f259, recorded 2026-10-12 | 16 | — |
| `3b-ii-b-replace-all.jsonl` | ✓ exit 0 | **proved red vs 5c38f72852bf on an earlier version — not re-proved** | 25 | — |
| `3b-ii-b-replace-cancel.jsonl` | ✓ exit 0 | **proved red vs 5c38f72852bf on an earlier version — not re-proved** | 14 | — |
| `3b-ii-b-replace-file.jsonl` | ✓ exit 0 | **proved red vs 5c38f72852bf on an earlier version — not re-proved** | 20 | — |
| `3b-ii-b-replace-undo.jsonl` | ✓ exit 0 | **proved red vs 5c38f72852bf on an earlier version — not re-proved** | 21 | — |
| `3b-ii-b-reveal.jsonl` | ✓ exit 0 | **proved red vs 5c38f72852bf on an earlier version — not re-proved** | 14 | — |
| `3b-ii-b-tab-move.jsonl` | ✓ exit 0 | **proved red vs 5c38f72852bf on an earlier version — not re-proved** | 12 | — |
| `3b-ii-find.jsonl` | ✓ exit 0 | **proved red vs 8e8ec7d29e7f on an earlier version — not re-proved** | 11 | — |
| `3b-ii-palette-ignored.jsonl` | ✓ exit 0 | **proved red vs 8e8ec7d29e7f on an earlier version — not re-proved** | 9 | — |
| `3b-ii-refusals.jsonl` | ✓ exit 0 | **proved red vs 8e8ec7d29e7f on an earlier version — not re-proved** | 8 | — |
| `3b-ii-search-cancel.jsonl` | ✓ exit 0 | **proved red vs 8e8ec7d29e7f on an earlier version — not re-proved** | 15 | — |
| `3b-ii-search-errors.jsonl` | ✓ exit 0 | **proved red vs 8e8ec7d29e7f on an earlier version — not re-proved** | 12 | — |
| `3b-ii-search.jsonl` | ✓ exit 0 | **proved red vs 8e8ec7d29e7f on an earlier version — not re-proved** | 46 | — |
| `3b-ii-tree-ignored-heavy.jsonl` | ✓ exit 0 | **proved red vs 8e8ec7d29e7f on an earlier version — not re-proved** | 12 | — |
| `3b-ii-tree-live.jsonl` | ✓ exit 0 | **proved red vs 8e8ec7d29e7f on an earlier version — not re-proved** | 14 | — |
| `3b-ii-tree-preview.jsonl` | ✓ exit 0 | **proved red vs 8e8ec7d29e7f on an earlier version — not re-proved** | 22 | — |
| `3b-ii-tree-toggle.jsonl` | ✓ exit 0 | **proved red vs 8e8ec7d29e7f on an earlier version — not re-proved** | 17 | — |
| `3b-iii-changes-drill.jsonl` | ✓ exit 0 | **proved red vs 2dfec0ee0c10 on an earlier version — not re-proved** | 60 | — |
| `3b-iii-changes-keys.jsonl` | ✓ exit 0 | **proved red vs 2dfec0ee0c10 on an earlier version — not re-proved** | 37 | — |
| `3b-iii-changes-list.jsonl` | ✓ exit 0 | **proved red vs 2dfec0ee0c10 on an earlier version — not re-proved** | 33 | — |
| `3b-iii-changes-live.jsonl` | ✓ exit 0 | **proved red vs 2dfec0ee0c10 on an earlier version — not re-proved** | 42 | — |
| `3b-iii-changes-press.jsonl` | ✓ exit 0 | **proved red vs 2dfec0ee0c10 on an earlier version — not re-proved** | 25 | — |
| `3b-iii-diff-open-file.jsonl` | ✓ exit 0 | **proved red vs 2dfec0ee0c10 on an earlier version — not re-proved** | 25 | — |
| `3b-iii-diff-refusals.jsonl` | ✓ exit 0 | **proved red vs 2dfec0ee0c10 on an earlier version — not re-proved** | 21 | — |
| `3b-iii-git-pane-migrates.jsonl` | ✓ exit 0 | **proved red vs 2dfec0ee0c10 on an earlier version — not re-proved** | 16 | — |
| `3b-iii-palette-changed-file.jsonl` | ✓ exit 0 | **proved red vs 2dfec0ee0c10 on an earlier version — not re-proved** | 16 | — |
| `3b-iii-peek.jsonl` | ✓ exit 0 | **proved red vs 2dfec0ee0c10 on an earlier version — not re-proved** | 44 | — |
| `3b-iii-tree-letters.jsonl` | ✓ exit 0 | **proved red vs 2dfec0ee0c10 on an earlier version — not re-proved** | 15 | — |
| `3b-iv-create-file.jsonl` | ✓ exit 0 | ✓ red vs a2a8b3fc9050, recorded 2026-10-18 | 25 | — |
| `3b-iv-create-folder.jsonl` | ✓ exit 0 | ✓ red vs a2a8b3fc9050, recorded 2026-10-18 | 24 | — |
| `3b-iv-name-refused.jsonl` | ✓ exit 0 | ✓ red vs a2a8b3fc9050, recorded 2026-10-18 | 20 | — |
| `3b-iv-rename-tabs.jsonl` | ✓ exit 0 | ✓ red vs a2a8b3fc9050, recorded 2026-10-18 | 25 | — |
| `3b-iv-trash-key.jsonl` | ✓ exit 0 | ✓ red vs a2a8b3fc9050, recorded 2026-10-18 | 13 | — |
| `3b-iv-trash-selection.jsonl` | ✓ exit 0 | ✓ red vs a2a8b3fc9050, recorded 2026-10-18 | 23 | — |
| `3b-iv-trash-tabs.jsonl` | ✓ exit 0 | ✓ red vs a2a8b3fc9050, recorded 2026-10-18 | 20 | — |
| `3b-iv-tree-pinned-click.jsonl` | ✓ exit 0 | ✓ red vs a2a8b3fc9050, recorded 2026-10-18 | 19 | — |
| `3b-ix-fast-path-ask-agent.jsonl` | ✓ exit 0 | ✓ red vs 2a491bfe7b06 | 8 | — |
| `3b-ix-fast-path-names-database.jsonl` | ✓ exit 0 | ✓ red vs 2a491bfe7b06 | 8 | — |
| `3b-ix-fast-path-open-file.jsonl` | ✓ exit 0 | ✓ red vs 2a491bfe7b06 | 10 | — |
| `3b-ix-fast-path-refused.jsonl` | ✓ exit 0 | ✓ red vs 2a491bfe7b06 | 8 | — |
| `3b-ix-fast-path-runs.jsonl` | ✓ exit 0 | ✓ red vs 2a491bfe7b06 | 14 | — |
| `3b-ix-fast-path-switch.jsonl` | ✓ exit 0 | ✓ red vs 2a491bfe7b06 | 10 | — |
| `3b-ix-fast-path-to-agent.jsonl` | ✓ exit 0 | ✓ red vs 2a491bfe7b06 | 8 | — |
| `3b-ix-quick-tasks-about.jsonl` | ✓ exit 0 | ✓ red vs 2a491bfe7b06 | 7 | — |
| `3b-v-click-focuses-pane.jsonl` | ✓ exit 0 | ✓ red vs 570f9eee022f, recorded 2026-10-15 | 0 | — |
| `3b-v-editor-autosave-focus.jsonl` | ✓ exit 0 | ✓ red vs e6c782b4f52f, recorded 2026-10-13 | 22 | — |
| `3b-v-editor-autosave-pause.jsonl` | ✓ exit 0 | ✓ red vs e6c782b4f52f, recorded 2026-10-13 | 23 | — |
| `3b-v-editor-autosave-prompt-guard.jsonl` | ✓ exit 0 | ✓ red vs e6c782b4f52f, recorded 2026-10-13 | 18 | — |
| `3b-v-editor-indent-scratch.jsonl` | ✓ exit 0 | ✓ red vs e6c782b4f52f, recorded 2026-10-13 | 11 | — |
| `3b-v-editor-live-options.jsonl` | ✓ exit 0 | ✓ red vs e6c782b4f52f, recorded 2026-10-13 | 21 | — |
| `3b-v-editor-settings-nodes.jsonl` | ✓ exit 0 | **proved red vs e6c782b4f52f on an earlier version — not re-proved** | 28 | — |
| `3b-v-heavy-folders-edit.jsonl` | ✓ exit 0 | ✓ red vs 5c38f72852bf, recorded 2026-10-14 | 21 | — |
| `3b-v-heavy-folders-refusal.jsonl` | ✓ exit 0 | **proved red vs 5c38f72852bf on an earlier version — not re-proved** | 24 | — |
| `3b-v-heavy-folders.jsonl` | ✓ exit 0 | **proved red vs 5c38f72852bf on an earlier version — not re-proved** | 41 | — |
| `3b-v-project-editor-settings.jsonl` | ✓ exit 0 | **proved red vs e6c782b4f52f on an earlier version — not re-proved** | 19 | — |
| `3b-v-show-ignored.jsonl` | ✓ exit 0 | **proved red vs 5c38f72852bf on an earlier version — not re-proved** | 27 | — |
| `3b-vii-log-follow.jsonl` | ✓ exit 0 | ✓ red vs 1d1a6f2b959a, recorded 2026-10-18 | 9 | — |
| `3b-vii-log-tail.jsonl` | ✓ exit 0 | ✓ red vs 1d1a6f2b959a, recorded 2026-10-18 | 14 | — |
| `3b-viii-ghost-text-setting.jsonl` | ✓ exit 0 | ✓ red vs 2a491bfe7b06 | 6 | — |
| `3b-viii-ghost-unreachable-editor.jsonl` | ✓ exit 0 | ✓ red vs 8ebeb01dfcd2, recorded 2026-10-20 | 10 | — |
| `3b-viii-ghost-unreachable-query-line.jsonl` | ✓ exit 0 | ✓ red vs 8ebeb01dfcd2, recorded 2026-10-20 | 6 | — |
| `3b-viii-local-provider-add-focused.jsonl` | ✓ exit 0 | ✓ red vs 8ebeb01dfcd2, recorded 2026-10-20 | 4 | — |
| `3b-viii-local-provider-add.jsonl` | ✓ exit 0 | ✓ red vs 2a491bfe7b06 | 20 | — |
| `3b-viii-local-provider-dispatch.jsonl` | ✓ exit 0 | ✓ red vs 2a491bfe7b06 | 25 | — |
| `3b-viii-local-provider-remove.jsonl` | ✓ exit 0 | ✓ red vs 8ebeb01dfcd2, recorded 2026-10-20 | 7 | — |
| `3b-viii-quick-provider-unlinked.jsonl` | ✓ exit 0 | ✓ red vs 8ebeb01dfcd2, recorded 2026-10-20 | 8 | — |
| `3b-viii-quick-provider.jsonl` | ✓ exit 0 | ✓ red vs 8ebeb01dfcd2, recorded 2026-10-20 | 13 | — |
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
| `api-env-roundtrip.jsonl` | ✓ exit 0 | ✓ red vs a2a8b3fc9050, recorded 2026-10-18 | 23 | — |
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
| `bg-env-switch-own-canvas.jsonl` | ✓ exit 0 | ✓ red vs a2a8b3fc9050, recorded 2026-10-18 | 16 | — |
| `bg-org-switch-asks-nothing.jsonl` | ✓ exit 0 | ✓ red vs a2a8b3fc9050, recorded 2026-10-18 | 8 | — |
| `bg-org-switch-keeps-the-terminal.jsonl` | ✓ exit 0 | ✓ red vs a2a8b3fc9050, recorded 2026-10-18 | 10 | — |
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
| `palette-open-kinds.jsonl` | ✓ exit 0 | ✓ red vs 2dfec0ee0c10, recorded 2026-10-16 | 0 | — |
| `palette-run-error.jsonl` | ✓ exit 0 | ✓ red vs f25a762e5ee7, recorded 2026-10-10 | 13 | — |
| `palette-switch-environment.jsonl` | ✓ exit 0 | ✓ red vs a2a8b3fc9050, recorded 2026-10-18 | 19 | — |
| `palette-table-row.jsonl` | ✓ exit 0 | **proved red vs f25a762e5ee7 on an earlier version — not re-proved** | 11 | — |
| `project-root-note.jsonl` | ✓ exit 0 | **proved red vs 8089dd200320 on an earlier version — not re-proved** | 11 | — |
| `vocabulary.jsonl` | ✓ exit 0 | ✓ red vs f25a762e5ee7, recorded 2026-10-10 | 8 | — |
| `2d-i-code-hint.jsonl` | ✓ exit 0 | **proved red vs fb7e8f09d0f3 on an earlier version — not re-proved** | 16 | — |
| `2d-i-failed-source.jsonl` | ✓ exit 0 | **proved red vs fb7e8f09d0f3 on an earlier version — not re-proved** | 15 | — |
| `2d-i-hint-or-plain.jsonl` | ✓ exit 0 | **proved red vs fb7e8f09d0f3 on an earlier version — not re-proved** | 8 | — |
| `2d-i-over-limit.jsonl` | ✓ exit 0 | **proved red vs fb7e8f09d0f3 on an earlier version — not re-proved** | 5 | — |
| `2d-i-pane-hint.jsonl` | ✓ exit 0 | **proved red vs fb7e8f09d0f3 on an earlier version — not re-proved** | 5 | — |
| `2d-i-schema-hint.jsonl` | ✓ exit 0 | **proved red vs fb7e8f09d0f3 on an earlier version — not re-proved** | 14 | — |
| `2d-ii-thread-earlier.jsonl` | ✓ exit 0 | not new on this branch | 12 | — |
| `2d-ii-voice-turn.jsonl` | ✓ exit 0 | not new on this branch | 10 | — |
| `3b-iii-changes-voice-hint.jsonl` | ✓ exit 0 | not new on this branch | 8 | — |
| `api-origin-after-account-switch.jsonl` | ✓ exit 0 | ✓ red vs 9e657511c804, recorded 2026-10-15 | 3 | — |
| `bg-agent-chip-more.jsonl` | ✓ exit 0 | ✓ red vs a2a8b3fc9050, recorded 2026-10-18 | 25 | — |
| `bg-agent-chip-narrow.jsonl` | ✓ exit 0 | ✓ red vs a2a8b3fc9050, recorded 2026-10-18 | 16 | — |
| `bg-agent-chip-over-landing.jsonl` | ✓ exit 0 | ✓ red vs a2a8b3fc9050, recorded 2026-10-18 | 14 | — |
| `bg-agent-chip-return.jsonl` | ✓ exit 0 | ✓ red vs a2a8b3fc9050, recorded 2026-10-18 | 30 | — |
| `both-surfaces.jsonl` | ✓ exit 0 | not new on this branch | 6 | — |
| `capacity-after-turn.jsonl` | ✓ exit 0 | ✓ red vs 1402c099d411, recorded 2026-10-11 | 7 | — |
| `two-enter.jsonl` | ✓ exit 0 | not new on this branch | 13 | — |
| `e2e/checks/seeded/zz-probe.jsonl` | — | — | — | a record for a check the corpus no longer holds |

**`make e2e-new` saw every check this branch added go red against 2a491bfe7b06.**

**the actions were observed from a tree carrying uncommitted changes, so they describe that tree rather than the commit**

**Every action and control this branch added carries a check.** 0 action(s) and 6 control(s) are new on this branch.

- actions:  68 of 108 dispatched by a check
- writes:   20 of 79 carry a parity check
- controls: 131 of 232 exercised by a check

**107 piece(s) of surface no check can reach**, each with the reason given in `e2e/checks/uncoverable.tsv`:

- `editor_create` — its parity (3b-iv): the operator's channel is the root's + menu (New File / New Folder), a name typed into the field and Enter or a click away — a menu, typing and a key, not one click or drag, and the UI half of a parity step is a click or a drag only (api_fill_from_curl's case). Both channels ARE covered: the + by 3b-iv-create-file.jsonl and 3b-iv-create-folder.jsonl (a pinned tab with the cursor in it, a/b and a/b/c selected, a click away committing), the dispatch by the same two (a file opened pinned, a folder shown) and its refusals (an existing name, outside the roots, a bad kind); what no check can express is the comparison.
- `ctx_unlink_provider` — its parity: the click removes the binding, so the dispatch half cannot be given the same id. Dispatch and both channels' behaviour ARE covered by 2e-settings-unlink.jsonl; what no check can express is the comparison.
- `editor_open_file` — its parity (3b-iii): the operator's channel is ⌘⏎ in a diff tab, a menu key equivalent (Maximize Pane's item, which a diff tab redirects) — a key, not a click or a drag — so no UI half can be expressed. Both channels ARE covered by 3b-iii-diff-open-file.jsonl, each opening app.txt at the diff's cursor line with the diff tab kept, and ⌘⏎ on a scratch tab maximizing; its refusal on a deleted file by 3b-iii-changes-live.jsonl.
- `editor_peek_step` — its parity (3b-iii): the operator's channels are ↑↓ while the peek is open (keys Monaco hands back) and the peek's ↑ ↓ buttons, which are HTML inside the WKWebView with no accessibility identifier — neither is a click on a control the resolver can address. Both the dispatch and ↑↓ ARE covered by 3b-iii-peek.jsonl, each asserting peek.index and the cursor through read_pane; the buttons are walk-only (row 8 presses ↓, a key).
- `editor_move_tab` — its parity (3b-ii-b): the drag moves a tab, and the same {from, to} dispatched on the moved strip moves a different tab, so the two halves cannot read back the same order. The drag and the dispatch are each 3b-ii-b-tab-move.jsonl's, each asserting the strip's order and the active tab through read_pane.
- `db_cancel` — its parity: the click (or Esc) cancels the read in flight, and db_cancel refuses a pane with nothing running (`nothing is running on pane …`), so the dispatch half cannot be given the same state — and a second slow read between the halves is not expressible inside one parity step, api_cancel's case. Both channels ARE covered: db-cancel-click.jsonl cancels one recursive-CTE read by db.<pane>.cancel and the next by dispatch, asserting the same state after each through read_pane (running false, cancelledAfterMs, the previous 2 rows kept, sort empty) and "cancelled after" in the tree; db-cancel-escape.jsonl cancels by Esc. What no check can express is the comparison.
- `editor_rename` — its parity (3b-iv): the operator's channels are F2 and a row's context menu Rename, then typing — and neither can be driven: Orca's key table has no F-keys and no arm opens a context menu. So no UI half exists to compare, and the field's rename is walk-only (runbook rows 4–7). The dispatch is covered by 3b-iv-rename-tabs.jsonl: a folder and a file renamed under open tabs in two panes, unsaved edits and ⌘Z kept, typing across it, the open folder staying open, and its four refusals.
- `editor_peek` — its parity (3b-iii): the operator's channel is a click on a change mark in Monaco's gutter, inside the WKWebView — a web element with no accessibility identifier, which the resolver cannot address (editor_goto's case: inside Monaco, the one non-action path). The dispatch is covered by 3b-iii-peek.jsonl (opened on a mark, refused on an unmarked line, on an untracked file and on a diff tab in 3b-iii-diff-refusals.jsonl); the mark click is the runbook's row 8.
- `editor_goto` — its parity (3b-i): there is no operator control for it — the operator moves the cursor inside Monaco, the one non-action path (design-language §11), so no UI half exists to compare. The dispatch is covered by 3b-i-editor-tabs-language.jsonl (cursor.line and cursor.column through read_pane) and refused on an empty pane in 3b-i-editor-refusals.jsonl.
- `editor_new_scratch` — its parity (3b-i): the operator's channel is ⌘T, a menu key equivalent — a key, not a click or a drag, and the UI half of a parity step is a click or a drag only (api_fill_from_curl's case); the empty pane only names the key. The dispatch is covered by most 3b-i-editor-* checks; ⌘T by 3b-i-editor-scratch-save.jsonl and 3b-i-editor-close-keys.jsonl, asserting the Untitled-N tab through read_pane.
- `editor_close` — its parity (3b-i): the operator's channels are ⌘W (a key) and the unsaved prompt's Don't Save, and the click consumes its own subject — the dispatch half after it would close a different tab or be refused (`the editor pane has no open tab`), api_cancel's case. Both channels ARE covered: 3b-i-editor-close-keys.jsonl (⌘W clean, ⌘W dirty → Esc / Cancel / Don't Save) and the dispatch with and without discard in 3b-i-editor-refusals.jsonl.
- `api_cancel` — its parity: the click cancels the send in flight, and api_cancel refuses a pane with nothing in flight (`nothingInFlight`), so the dispatch half cannot be given the same state — and a second Send between the halves is not expressible. Both channels ARE covered by api-cancel.jsonl, each after its own Send, asserting the same cancelled response through read_pane; what no check can express is the comparison.
- `editor_changes_step` — its parity (3b-iii): the operator's channel is ↑↓ in the Changes view — keys, not a click or a drag — and the UI half of a parity step is a click or a drag only (api_fill_from_curl's case). Both channels ARE covered: the dispatch by 3b-iii-changes-drill.jsonl (across roots, both directions, clamped at the end, skipping a collapsed root, asserting the highlight and the diff tab through read_pane), the keys by 3b-iii-changes-keys.jsonl (↓ from nothing, ↑↓ across roots, after ⌘⇧G); what no check can express is the comparison.
- `api_render_curl` — Two reasons, and the second is the one that lasts. A dispatch cannot hold the row id, which is minted per send and published only in read_pane; and the operator's own Copy as cURL puts its line on the PASTEBOARD, which no check can read — the act is real and its result leaves the window. `api_reopen`'s CLICK left this file when the recent strip gave it a button, because a reopen's effect lands in the draft where a check can see it; its dispatch half is still here, for the first of these reasons. Covered by WakilKitTests: curlIsPastTenseOnly, curlOnlyMentionsACredentialThereWasOne, curlEmitsAndNeverParses.
- `db_remove_database` — its parity: the click removes the database, and removing one that is gone is refused (`no database … in environment …`), so the dispatch half cannot be given the same params. Dispatch is covered by 2e-settings-databases-dispatch.jsonl and the click by 2e-settings-databases.jsonl; what no check can express is the comparison.
- `ctx_provider_login` — #254. Opens a browser on the operator's machine and authenticates as them. No harness can drive it and none should: every run would leave a real credential behind.
- `editor_replace_undo` — its parity (3b-ii-b): the Undo click spends the pane's one undo, and the dispatch after it is then refused (`no replace to undo`) — api_undo_fill's case. The click is 3b-ii-b-replace-undo.jsonl's (undone, restored 2, and the changed-since line for the file changed on disk), and so is the refusal of the dispatch after it.
- `api_unbind` — its parity: the click returns the binding to its hole, and api_unbind refuses a position that holds no binding (`unbindNotABinding`), so the dispatch half cannot be given the same params — and a re-drag between the halves is not expressible. Both channels ARE covered by api-unbind.jsonl, each after its own drag, asserting the same hole back through read_pane; what no check can express is the comparison.
- `api_fill_from_curl` — its parity: the UI half of a parity step is a click or a drag, and the operator's channel is a paste (cmd+v into the path editor), so the comparison cannot be expressed. Both channels ARE covered: the dispatch by api-paste-curl.jsonl, the paste by api-paste-curl-hotkey.jsonl, each asserting the same draft and the Filled from cURL line; what no check can express is the comparison.
- `editor_select` — its parity (3b-i): no operator control — the operator selects inside Monaco, the one non-action path, so no UI half exists. The dispatch is covered by most 3b-i-editor-* checks, which read selected_text back to prove what a save wrote.
- `api_undo_fill` — its parity: the Undo click forgets the fill it undoes, and api_undo_fill refuses a pane with nothing to undo, so the dispatch half cannot be given the same state after the click — and a second fill between the halves is not expressible inside one parity step. Both channels ARE covered by api-paste-curl.jsonl, the click after one fill and the dispatch after another, each asserting the same restored draft through read_pane; what no check can express is the comparison.
- `api_reopen` — its dispatch: it needs a row id, which is minted per send and published only in read_pane — the same reason api_render_curl below is here. The operator's gesture IS covered: api-recent.jsonl presses api.recent.0.reopen and asserts the draft it rebuilds. Permanent, not blocked: nothing in the vocabulary carries a value from read_pane into a dispatch.
- `settings_open` — its parity: the only UI path is the `Settings…` MENU item, and a menu's buttons are not in the accessibility tree until the menu is open — the same rule that excuses every other menu control. Checks drive it by its real gesture, cmd+comma, and 2e-settings-pane.jsonl also dispatches it.
- `capacity_record` — its parity: the operator's channel is the agent's own stream — the window records a `rate_limit_event` frame from a turn on its own, with no click or drag — so the UI half of a parity step cannot be expressed: no click or drag of the operator's produces it, so there is no UI half to compare. Both channels ARE covered: the dispatch by capacity-low-reading.jsonl and capacity-passed-reset.jsonl, the stream by agent/capacity-after-turn.jsonl, each asserting the reading it lands on the indicator; what no check can express is the comparison.
- `editor_restore` — its parity (3b-i): no operator control — it runs when a window relaunches onto saved tabs, and one check is one launch. The dispatch is covered by 3b-i-editor-disk-changed.jsonl (an open, dirty tab is kept as it is); restoring after a relaunch is the runbook's row 9.
- `editor_replace_range` — its parity (3b-i): no operator control — the operator's own edits are typing in Monaco, the one non-action path (`editorBufferDidChange`), so no UI half exists. The dispatch is covered by most 3b-i-editor-* checks, and its read-only refusal by 3b-i-editor-read-only.jsonl.
- `editor_trash` — its parity (3b-iv): the operator's channels are ⌘⌫ with the tree focused (a key) and a row's context menu Move to Trash (no arm opens one), so no UI half of one click or drag exists. ⌘⌫ is 3b-iv-trash-key.jsonl and 3b-iv-name-refused.jsonl; the dispatch is 3b-iv-trash-selection.jsonl (selection to the next row, else the previous; a clean tab closed; its refusals) and 3b-iv-trash-tabs.jsonl (a dirty tab kept, marked deleted, not autosaved back, recreated by ⌘S).
- `ctx_add_provider` — its parity: the click creates a binding under an id, so a dispatch with the same params collides with what the click just made. Covered by 2e-settings-doors.jsonl up to the browser leg.
- `editor_replace` — its parity (3b-ii-b): the click replaces, and the same dispatch after it finds nothing left to replace and answers a different last_replace, so the two halves cannot read back the same pane (api_cancel's case: the click consumes its own subject). Both channels ARE covered: the click (Replace All) by 3b-ii-b-replace-all.jsonl and the dispatch by 3b-ii-b-replace-undo.jsonl, each asserting last_replace's files and the Replaced … line; Replace in this file by 3b-ii-b-replace-file.jsonl, and Cancel by 3b-ii-b-replace-cancel.jsonl.
- `editor_peek_close` — its parity (3b-iii): the operator's channels are Esc in the peek (a key), typing (which closes it in the store), and the peek's × (HTML inside the WKWebView, no accessibility identifier). Esc, typing and the dispatch ARE each covered by 3b-iii-peek.jsonl, asserting peek null with the cursor and the marks kept; the × button is walk-only, in no runbook row.
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
- `editor.search.largeNote` — a Text (3b-vii, Rule 8): "1 file over 2 MB not searched: big.log", drawn under the results when files_search skipped files over 2 MB. Display text with no press action. Read, not pressed — 3b-vii-log-tail.jsonl asserts it in the tree and search.skipped_large in the pane after searching beside a 3 MB log.
- `editor.search.noMatches` — a Text (3b-ii walk): "no matches", drawn under a finished search that found nothing. Display text with no press action. Read, not pressed — 3b-ii-search.jsonl asserts it in the tree after a search for a string no fixture file holds.
- `editor.search.note` — a Text (3b-ii): "only the first 2,000 matches are shown", drawn only over a search that hit the cap. 2,000 matches are not seeded; `truncated` is pinned by internal/wakilcore/files_test.go and WakilKitTests (EditorSearchActionsTests), and the note is the runbook's walk.
- `editor.strip` — not a control (3b-ii-b): the name of a SwiftUI coordinate space (`.coordinateSpace(name: "editor.strip")`, the visible tab strip's, where the middle-click converts a click), not an accessibility identifier — editor.tabs's case. Nothing in the accessibility tree carries it. The middle-click itself is walk-only: the harness posts no middle button (runbook row 8).
- `editor.tabs` — not a control (3b-ii-b): the name of a SwiftUI coordinate space (`.coordinateSpace(name: "editor.tabs")`, the tab strip's, which the drop target and the middle-click measure in), not an accessibility identifier. The harvest reads any `editor.…` literal; nothing in the accessibility tree carries this name, so no check can press or read it. The strip's tabs are editor.tab.<…>, dragged by 3b-ii-b-tab-move.jsonl.
- `editor.tree.error:<…>` — a Text (3b-ii, Rule 8): a root's or a heavy folder's listing error, drawn whole under its row. Every fixture root lists and vendor loads, and no step can make one unreadable mid-launch; display text with no press action either way. Pinned by WakilKitTests (EditorTreeTests), and an unreadable root is the runbook's walk.
- `editor.tree.loading` — the tree's load tick (3b-ii, Rule 5): a shape drawn only while a root lists or a heavy folder loads, which against the fixture's small roots lasts milliseconds — never long enough for a tree read to see. 3b-ii-tree-ignored-heavy.jsonl asserts what the load brings (autoload.php under vendor); seeing the tick is the runbook's walk.
- `editor.tree.name.error` — a Text (3b-iv, Rule 8): the tree's name field's refusal, drawn whole under it. Display text with no press action. Read, not pressed — 3b-iv-name-refused.jsonl asserts `/e2e-api/README.md already exists` in the tree, its frame inside editor.column, and its absence once the kept text, amended, commits.
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
- `settings.localProvider.<…>.refusal` — a Text (3b-viii, Rule 8): a refused URL or Serves save, drawn whole under the row. Display text with no press action. Read, not pressed — 3b-viii-local-provider-add.jsonl asserts `baseURL must be an http or https URL, e.g. http://127.0.0.1:8012; got "ftp://x"` with the typed ftp://x kept in the field, and its frame clear of the URL field at 1000×888.
- `settings.localProvider.<…>.status` — a Text (3b-viii, Rule 8): a local model's status line — "not tried yet", "reachable", or its last error whole. Display text with no press action. Read, not pressed — 3b-viii-local-provider-add.jsonl and 3b-viii-local-provider-dispatch.jsonl assert "not tried yet"; 3b-viii-ghost-unreachable-editor.jsonl and 3b-viii-ghost-unreachable-query-line.jsonl assert "Could not connect to the server." after a ghost request to http://127.0.0.1:1, and "not tried yet" gone.
- `settings.login.cancel` — #254. Only exists while a browser trip is in flight.
- `settings.login.dismiss` — #254. Drawn only by the states a finished trip reaches — added, refused, cancelled, timedOut, uncertain, failed.
- `settings.login.someoneElse` — #254. Starts a fresh trip, and only appears when the config dir is already signed in, which itself needs a real credential.
- `settings.login.start` — #254. The control that does the above.
- `settings.mint.stopWaiting` — #254. Only exists while waiting on a live mint.
- `settings.org.<…>.refusal` — a Text (3b-ix, Rule 8): the Ghost-text or Fast path switch's refusal, drawn only when Go refuses the ctx_update_org write the switch itself offers. Go refuses a boolean on the open organisation only when its org.json does not parse, and no fixture or step can corrupt it mid-launch — as for settings.editor.wordWrap.refusal. Display text with no press action.
- `settings.org.quickProvider.configError` — a Text (3b-viii, Rule 8): why the configuration quick tasks are built from could not be read, drawn only when the config tree read fails. The seed writes a readable organisation and no step can corrupt it mid-launch. Display text with no press action; the error path is pinned by WindowModelQuickTasksTests.
- `settings.org.quickProvider.error` — a Text (3b-viii, Rule 8): the last error of the provider code completion routes to first, drawn whole under the Quick tasks row. Display text with no press action. Read, not pressed — 3b-viii-ghost-unreachable-editor.jsonl holds its frame on the Providers page after Quick tasks is set to a local model on http://127.0.0.1:1 and an editor tab asks.
- `settings.org.quickProvider.note` — a Text (3b-viii): "Ghost-text needs a Claude or local provider", drawn only when neither the chosen quick provider nor the window's running account serves infill. Every fixture launch runs as a claude-code account, which always serves infill, and no step can make a window run as another kind mid-launch. Display text with no press action; quickTaskNote is pinned by QuickTaskSettingsTests.
- `settings.org.quickProvider.refusal` — a Text (3b-viii, Rule 8): drawn only when Go refuses a Quick tasks segment the row itself offers, i.e. a provider gone between draw and press. Measured on this branch: an unlink (ctx_unlink_provider) re-reads the pane and the segment is gone before any press can reach it (3b-viii-quick-provider-unlinked.jsonl), so no step can press a stale one. The dispatch refusal of an unknown id is asserted by 3b-viii-quick-provider.jsonl.
- `settings.org.quickProvider.route` — a Text (3b-viii): "Code completion goes to <provider>", drawn under the Quick tasks row once quick tasks are built. Display text with no press action; its wording is pinned by QuickTaskSettingsTests.quickTaskRouteLineNamesTheProviderCodeCompletionGoesTo.
- `settings.org.speechProvider.note` — a Text: the Speech row's "unknown engine 'x', using Apple". Read, not pressed — 2d-ii-settings-speech.jsonl asserts it after a dispatched unknown id and a reload, and its absence after Apple is chosen.
- `settings.projectEditor.heavy.git` — the heavy-folder list's fixed .git row (3b-v part 2): a Text pair (".git", "always") with no press action — .git is always heavy and cannot be edited or removed. Read, not pressed — 3b-v-heavy-folders-edit.jsonl asserts its "always" beside the list.
- `settings.projectEditor.heavy.refusal` — a Text (3b-v part 2, Rule 8): a refused heavy folder's sentence, drawn whole under the list. Display text with no press action. Read, not pressed — 3b-v-heavy-folders-refusal.jsonl asserts the .git, a/b and duplicate sentences in the pane and refuses the same names by dispatch.
- `settings.projectEditor.indent.refusal` — a Text (3b-v, Rule 8): drawn only when Go refuses Spaces or Tabs, which it does only for a project.json filed under another organisation or unreadable — and either one drops the project from the settings tree, so its Editor node draws `gone` instead of this form and the refusal has nowhere to appear. Display text with no press action. 3b-v-project-editor-settings.jsonl drives both choices (Tabs through parity) and asserts each on disk.
- `settings.quickTasks.about.text` — a Text (3b-ix): the quick tasks ⓘ popover's words, drawn whole. Display text with no press action. Read, not pressed — 3b-ix-quick-tasks-about.jsonl opens the popover from settings.quickTasks.about and asserts "Ask the agent instead", "It never edits, queries or runs commands" and "slower than 0.4 s", then that Esc closes it.
- `settings.row.<…>.reauthenticate` — #254. Goes straight to the browser by design — no confirmation step — so pressing it IS starting a real trip.
- `window.capacity` — the capacity indicator beside ACCOUNT (provider capacity): it has no press action, and it refuses AXFocused (measured 2026-10-10: axresolve not_focusable), because `.focusable(interactions: .activate)` keeps a click from taking the composer's focus (Rule 6) and joins the key loop only with macOS Keyboard navigation on. Its card opens on hover or on that focus, and the vocabulary has no hover step, so opening the card is walk-only. What it draws is read by capacity-at-launch.jsonl (the launch probe, no turn), capacity-low-reading.jsonl, capacity-passed-reset.jsonl and agent/capacity-after-turn.jsonl.
- `window.composer.bar` — the composer bar's container (.contain), which holds the field, the heard text and the hint and takes no input itself. Its contents are read by every 2d-ii voice check; the field inside it is `window.composer`, which they type into.
- `window.composer.heard` — a Text: the words heard while ⌥ is held, or the notice that replaces them. Read, not pressed — 2d-ii-voice-silence.jsonl asserts "Hearing nothing from E2E Microphone" and the words that clear it; 2d-ii-voice-lands-unsent.jsonl and 2d-ii-voice-escape.jsonl assert the words mid-hold.
- `window.composer.hint` — a Text: the bar's hint. Read, not pressed — the keys hint ("TO SPEAK"), the listening hint ("RELEASE TO PUT IT IN THE LINE") and the landed hint ("HEARD · RETURN SENDS · EDIT FIRST") are asserted by the 2d-ii voice checks.
- `window.composer.receipt` — a Text (3b-ix): the fast path's receipt, what ran or the refusal whole. Display text with no press action. Read, not pressed — 3b-ix-fast-path-runs.jsonl asserts "Ran: switch environment to qa" and its frame clear of Ask the agent instead at the window's minimum; 3b-ix-fast-path-refused.jsonl asserts the refusal whole.
- `window.contextLine` — the context line's container (.contain, background agents 4 of 4): it holds the organisation, project and environment segments and takes no input itself — a click lands on a segment. Named so a layout check can hold the agent chips clear of it; read by frame, not pressed — agent/bg-agent-chip-narrow.jsonl and agent/bg-agent-chip-over-landing.jsonl assert the chip `clear` of it at the window's minimum.
- `window.thread` — the thought thread's container (.contain), which takes hits only on its rows and the "earlier" line. Its rows are pressed by 2d-ii-thread-earlier.jsonl as window.thread.row.<id> and window.thread.earlier.

**This section knows nothing about what a machine cannot see.** The visual rulings and the live-provider question stay the operator's, permanently; they are the human section below.

<!-- /machine-walk -->
