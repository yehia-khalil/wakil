# 3a-ii-b — Stage and Unstage Selected Ranges, and a drafted commit message: acceptance

**Spec:** [`2026-10-22-3a-ii-b-ranges-and-drafts-design.md`](../superpowers/specs/2026-10-22-3a-ii-b-ranges-and-drafts-design.md)
· **Charter:** Decision 42 (amended 2026-10-22), Decision 43's last sentence

The exit criterion, from the spec: in a Changes diff tab the operator stages only the lines they
selected; in a Staged diff tab they unstage only those. ✨ in the commit box drafts a message
from what Commit would commit, with the org's quick model, and the operator edits it and commits.
Nothing asks (Rule 1), a replaced draft is one ⌘Z away, and typing always wins over a draft.

Nothing here is walked yet: the Walked column is empty until the operator ticks it.

## 0. Setup

Run this in the repo root of this branch, on this Mac, after `make build` and `make app-bundle`.
It is safe to re-run.

```bash
(
set -e
ORG=personal
W="$TMPDIR/walk-3a-ii-b"
REPO="$PWD"
rm -rf "$W"
mkdir -p "$W/api" "$W/project"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
seedgit() { git -c user.name=seed -c user.email=seed@example.com "$@"; }
cd "$W/api" && git init -q -b main
printf 'one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\n' > confirm.go
printf 'alpha\nbeta\n' > notes.md
git add . && seedgit commit -qm seed
printf 'ONE\ntwo\nthree\nfour\nfive\nSIX\nSEVEN\neight\nnine\n' > confirm.go
printf 'alpha\nBETA\ngamma\n' > notes.md
cat > "$W/project/project.json" <<J
{"name":"walk-3a-ii-b","org":"$ORG","roots":[{"path":"$W/api"}],"scopes":{},"environments":{}}
J
cd "$REPO"
./bin/wakil project rm walk-3a-ii-b --org "$ORG" || true
./bin/wakil project add walk-3a-ii-b --path "$W/project/project.json" --org "$ORG"
)
```

`confirm.go` has three separate changes against the index (lines 1, 6–7, and an added line 9), and
`notes.md` has one change block (`BETA` and an added `gamma`). Launch with
`WAKIL_ORG=personal app/Wakil.app/Contents/MacOS/Wakil` from the repo root, make `walk-3a-ii-b`
active with ⌘P, and open an editor pane. Keep a Terminal window open. Settings → Providers →
QUICK TASKS needs a model (a local one, or Same as agent) and **Commit drafts** on.

## 1. The walk

Walk in order, on `walk-3a-ii-b`, in `personal`.

| # | Do | Expect | Walked |
|---|---|---|---|
| 1 | ⌘⇧G, click `confirm.go` under **Changes**. In the diff, drag over lines 6–7 (the `SIX`/`SEVEN` block) and press **Stage Selected Ranges** in the strip above the diff | No dialog. `confirm.go` shows under both **Staged** and **Changes**; the diff still shows lines 1 and 9 as changes, and the cursor and scroll stay where they were. Terminal: `git -C "$TMPDIR/walk-3a-ii-b/api" diff --cached` shows only `six`→`SIX` and `seven`→`SEVEN` | |
| 2 | Drag from the start of line 1 down to the start of line 2 (a whole-line drag), then press **Stage Selected Ranges** | Only line 1 is staged: line 2 is untouched, and line 9 is still unstaged | |
| 3 | Click line 9 (no selection, just the cursor there). Right-click → **Stage Selected Ranges** | The right-click menu shows the entry (and no **Unstage** entry). Line 9 is staged; the Changes diff has nothing left | |
| 4 | Open `confirm.go` under **Staged**. ⌥-click to put cursors on lines 1 and 9, then press **Unstage Selected Ranges** | Both lines go back under Changes; `SIX`/`SEVEN` stay staged. `git diff --cached` shows only that block | |
| 5 | Open `notes.md` under **Changes**, select only the `gamma` line, press ⌘K and run **Stage Selected Ranges** | ⌘K offers the command (and offers no **Unstage**). Only `gamma` is staged; `BETA` stays unstaged; `git diff --cached -- notes.md` adds `gamma` and does not touch `beta` | |
| 6 | In the commit box, press ✨ | A spinner replaces ✨ for the model's time; then a short imperative message about the staged lines fills the box. Nothing is committed | |
| 7 | Type `wip` over the box's text, press ✨, and press ⌘Z once the draft lands | The draft replaces `wip`; ⌘Z puts `wip` back | |
| 8 | Press ✨ and, before it lands, click into the diff and type a few characters, or hover ✨ and press ✕ | With ✕: the spinner goes and the box keeps its text, with no error. While typing elsewhere: the draft lands in the box, but the keystrokes stay where you typed them, and the keyboard is not pulled back to the box (Rules 3, 6) | |
| 9 | ⌘, → Providers → QUICK TASKS: **Commit drafts** Off, then back to the Changes view | ✨ is gone from the box. In the composer, "draft a commit message for api" is refused with `commit drafts are off for personal — Settings → Providers → Quick tasks`. Switch it back On | |
| 10 | Hold ⌥ and say "draft a commit message", release, Return. Then edit it and press **Commit** | An agent turn calls `editor_changes_draft_message` and the box fills; ⌘Z right after puts back what was there. **Commit** commits it: `git -C "$TMPDIR/walk-3a-ii-b/api" log -1 --format=%B` prints the message as you left it | |

## 2. Known and not fixed

- **Several cursors:** the button's enabled state follows the main cursor only; the press stages
  every selection.
- **New files** are named in the draft without their contents or line counts.
- **The draft's ⌘Z** has no redo, and can outlive an org switch (the box's text it restores is the
  old org's).
- **The Stage / Unstage strip hides** while the diff refreshes (a moment after each write) instead
  of greying out.
- **Draft counts** (`path +a −d`) are skewed by content lines that start with `--` or `++`.
- **Each repaint re-diffs** the tab for the strip's enabled state; near 10,000 lines that is slow.

**Found by Cover, and fixed on this branch:**

- The **Commit drafts** switch did nothing: `ctx_update_org` forwarded only listed keys and
  `commitDrafts` was not one of them (`theCommitDraftsSwitchIsForwarded`).
- Unstaging part of a changed block put HEAD's old line back *beside* the new line that stayed
  staged, and staging only an added line of a block staged the removal of its unselected neighbour.
  A block now pairs its old and new lines one to one (spec amendment 2026-10-22).

## 3. Residue: what the checks cannot establish

- **A mouse drag in Monaco** (rows 1, 2), **⌥-click cursors** (row 4) and **the right-click menu**
  (row 3) are inside the web view; the checks stage by line numbers through the dispatch and by the
  caret through the strip's buttons.
- **⌘K's two commands** are pinned by `CommandCatalogTests`; no check opens ⌘K over a diff tab.
- **A real quick model's draft** (rows 6, 10): the checks answer with a stub's fixed message.
- **⌘Z after a draft** (rows 7, 10), **✕** and **typing to cancel** (row 8): pinned by
  `WindowModelCommitDraftTests` on the model; the window's undo registration and the keyboard
  staying where the operator types are walk-only.
- **✨ hidden when the switch is off** (row 9): no step kind asserts a control's absence; the check
  asserts the switch's state and the action's refusal.
- **The parity of the range writes** is excused in `uncoverable.tsv`: the click consumes its own
  subject (`editor_changes_commit`'s case); both channels are covered by `3a-ii-b-ranges.jsonl`.

<!-- machine-walk: generated by `make e2e-runbook`; everything between these markers is overwritten -->

**The machine walk is red** — 199 condition(s) of the Cover rung are not met:

```
e2e/checks/unseeded/org-plane.jsonl was never run against this build, so nothing is known about it — run `make e2e`
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
e2e/checks/seeded/2d-ii-voice-second-hold.jsonl was never run against this build, so nothing is known about it — run `make e2e`
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
e2e/checks/seeded/3a-ii-b-draft.jsonl was run against 7366af3c0cc2 and this tree is on 1f0899f0c459 — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3a-ii-b-ranges.jsonl was run against 7366af3c0cc2 and this tree is on 1f0899f0c459 — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3a-ii-commit-all.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3a-ii-commit.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3a-ii-discard.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3a-ii-hook-fails.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3a-ii-identity.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3a-ii-message-box.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3a-ii-settings-tree-collapse.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3a-ii-stage-change.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3a-ii-undo.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-i-editor-close-keys.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-i-editor-disk-changed.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-i-editor-files-palette.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-i-editor-read-only.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-i-editor-refusals.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-i-editor-save-as-field.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-i-editor-save-as-replace.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-i-editor-scratch-save.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-i-editor-tabs-language.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-i-editor-unsaved-org-switch.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-i-editor-unsaved-quit.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-i-editor-unsaved-save.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-ii-b-replace-all.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-ii-b-replace-cancel.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-ii-b-replace-file.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-ii-b-replace-undo.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-ii-b-reveal.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-ii-b-tab-move.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-ii-find.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-ii-palette-ignored.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-ii-refusals.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-ii-search-cancel.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-ii-search-errors.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-ii-search.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-ii-tree-ignored-heavy.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-ii-tree-live.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-ii-tree-preview.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-ii-tree-toggle.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-iii-changes-drill.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-iii-changes-keys.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-iii-changes-list.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-iii-changes-live.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-iii-changes-press.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-iii-diff-open-file.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-iii-diff-refusals.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-iii-git-pane-migrates.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-iii-palette-changed-file.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-iii-peek.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-iii-tree-letters.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-iv-create-file.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-iv-create-folder.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-iv-name-refused.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-iv-rename-tabs.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-iv-trash-key.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-iv-trash-selection.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-iv-trash-tabs.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-iv-tree-pinned-click.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-ix-fast-path-ask-agent.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-ix-fast-path-names-database.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-ix-fast-path-open-file.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-ix-fast-path-refused.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-ix-fast-path-runs.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-ix-fast-path-switch.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-ix-fast-path-to-agent.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-ix-quick-tasks-about.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-v-click-focuses-pane.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-v-editor-autosave-focus.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-v-editor-autosave-pause.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-v-editor-autosave-prompt-guard.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-v-editor-indent-scratch.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-v-editor-live-options.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-v-editor-settings-nodes.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-v-heavy-folders-edit.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-v-heavy-folders-refusal.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-v-heavy-folders.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-v-project-editor-settings.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-v-show-ignored.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-vii-log-follow.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-vii-log-tail.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-viii-ghost-text-setting.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-viii-ghost-unreachable-editor.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-viii-ghost-unreachable-query-line.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-viii-local-provider-add-focused.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-viii-local-provider-add.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-viii-local-provider-dispatch.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-viii-local-provider-remove.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-viii-quick-provider-unlinked.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-viii-quick-provider.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/agent-pane-is-drawn.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-bind.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-body-editor.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-body-hole-cursor.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-bound-locks.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-cancel.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-chip-keys-second-chip.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-chip-keys-text-after.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-chip-keys.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-editor-copy-bound.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-editor-json-holes.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-editor-wrap.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-env-roundtrip.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-hole.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-one-author-focus.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-open.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-paste-curl-hotkey.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-paste-curl-refused.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-paste-curl-www.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-paste-curl.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-query-sync.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-recent-root.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-recent-shared.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-recent.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-reopen-cross-entry.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-rows.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-saved-as-typed.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-send-what-it-shows.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-send.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-set-request.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-surface.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-the-rest.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-type-keeps-holes.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/api-unbind.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/bg-env-switch-own-canvas.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/bg-org-switch-asks-nothing.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/bg-org-switch-keeps-the-terminal.jsonl was never run against this build, so nothing is known about it — run `make e2e`
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
e2e/checks/seeded/journal-error-reason.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/landing.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/palette-api-entry.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/palette-api-send.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/palette-command-step.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/palette-escape.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/palette-modes.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/palette-open-kinds.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/palette-run-error.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/palette-switch-environment.jsonl was never run against this build, so nothing is known about it — run `make e2e`
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
e2e/checks/agent/3b-iii-changes-voice-hint.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/agent/api-origin-after-account-switch.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/agent/bg-agent-chip-more.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/agent/bg-agent-chip-narrow.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/agent/bg-agent-chip-over-landing.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/agent/bg-agent-chip-return.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/agent/both-surfaces.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/agent/capacity-after-turn.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/agent/two-enter.jsonl was never run against this build, so nothing is known about it — run `make e2e`
the failability record was written against 46b5f76748af and this tree is on 1f0899f0c459 — run `make e2e-new`
coverage could not be computed, so nothing here says whether the surface this branch added carries checks: the action denominator was observed against 7366af3c0cc2 and this tree is on 1f0899f0c459 — measured against the wrong build the gate cannot see an action this branch added, and would pass by being blind. Run `make e2e` to record the current one
```

Walked by `make e2e` against 1f0899f0c459, rendered 2026-10-22 12:03 UTC by `make e2e-runbook`. Re-render it with that target; edits between the markers are overwritten.

| Check | `make e2e` | Red against the base | Assertions | Evidence |
|---|---|---|---|---|
| `org-plane.jsonl` | **never run** | — | — | — |
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
| `2d-ii-voice-second-hold.jsonl` | **never run** | — | — | — |
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
| `3a-ii-b-draft.jsonl` | **another build** (7366af3c0cc2) | — | — | — |
| `3a-ii-b-ranges.jsonl` | **another build** (7366af3c0cc2) | — | — | — |
| `3a-ii-commit-all.jsonl` | **never run** | — | — | — |
| `3a-ii-commit.jsonl` | **never run** | — | — | — |
| `3a-ii-discard.jsonl` | **never run** | — | — | — |
| `3a-ii-hook-fails.jsonl` | **never run** | — | — | — |
| `3a-ii-identity.jsonl` | **never run** | — | — | — |
| `3a-ii-message-box.jsonl` | **never run** | — | — | — |
| `3a-ii-settings-tree-collapse.jsonl` | **never run** | — | — | — |
| `3a-ii-stage-change.jsonl` | **never run** | — | — | — |
| `3a-ii-undo.jsonl` | **never run** | — | — | — |
| `3b-i-editor-close-keys.jsonl` | **never run** | — | — | — |
| `3b-i-editor-disk-changed.jsonl` | **never run** | — | — | — |
| `3b-i-editor-files-palette.jsonl` | **never run** | — | — | — |
| `3b-i-editor-read-only.jsonl` | **never run** | — | — | — |
| `3b-i-editor-refusals.jsonl` | **never run** | — | — | — |
| `3b-i-editor-save-as-field.jsonl` | **never run** | — | — | — |
| `3b-i-editor-save-as-replace.jsonl` | **never run** | — | — | — |
| `3b-i-editor-scratch-save.jsonl` | **never run** | — | — | — |
| `3b-i-editor-tabs-language.jsonl` | **never run** | — | — | — |
| `3b-i-editor-unsaved-org-switch.jsonl` | **never run** | — | — | — |
| `3b-i-editor-unsaved-quit.jsonl` | **never run** | — | — | — |
| `3b-i-editor-unsaved-save.jsonl` | **never run** | — | — | — |
| `3b-ii-b-replace-all.jsonl` | **never run** | — | — | — |
| `3b-ii-b-replace-cancel.jsonl` | **never run** | — | — | — |
| `3b-ii-b-replace-file.jsonl` | **never run** | — | — | — |
| `3b-ii-b-replace-undo.jsonl` | **never run** | — | — | — |
| `3b-ii-b-reveal.jsonl` | **never run** | — | — | — |
| `3b-ii-b-tab-move.jsonl` | **never run** | — | — | — |
| `3b-ii-find.jsonl` | **never run** | — | — | — |
| `3b-ii-palette-ignored.jsonl` | **never run** | — | — | — |
| `3b-ii-refusals.jsonl` | **never run** | — | — | — |
| `3b-ii-search-cancel.jsonl` | **never run** | — | — | — |
| `3b-ii-search-errors.jsonl` | **never run** | — | — | — |
| `3b-ii-search.jsonl` | **never run** | — | — | — |
| `3b-ii-tree-ignored-heavy.jsonl` | **never run** | — | — | — |
| `3b-ii-tree-live.jsonl` | **never run** | — | — | — |
| `3b-ii-tree-preview.jsonl` | **never run** | — | — | — |
| `3b-ii-tree-toggle.jsonl` | **never run** | — | — | — |
| `3b-iii-changes-drill.jsonl` | **never run** | — | — | — |
| `3b-iii-changes-keys.jsonl` | **never run** | — | — | — |
| `3b-iii-changes-list.jsonl` | **never run** | — | — | — |
| `3b-iii-changes-live.jsonl` | **never run** | — | — | — |
| `3b-iii-changes-press.jsonl` | **never run** | — | — | — |
| `3b-iii-diff-open-file.jsonl` | **never run** | — | — | — |
| `3b-iii-diff-refusals.jsonl` | **never run** | — | — | — |
| `3b-iii-git-pane-migrates.jsonl` | **never run** | — | — | — |
| `3b-iii-palette-changed-file.jsonl` | **never run** | — | — | — |
| `3b-iii-peek.jsonl` | **never run** | — | — | — |
| `3b-iii-tree-letters.jsonl` | **never run** | — | — | — |
| `3b-iv-create-file.jsonl` | **never run** | — | — | — |
| `3b-iv-create-folder.jsonl` | **never run** | — | — | — |
| `3b-iv-name-refused.jsonl` | **never run** | — | — | — |
| `3b-iv-rename-tabs.jsonl` | **never run** | — | — | — |
| `3b-iv-trash-key.jsonl` | **never run** | — | — | — |
| `3b-iv-trash-selection.jsonl` | **never run** | — | — | — |
| `3b-iv-trash-tabs.jsonl` | **never run** | — | — | — |
| `3b-iv-tree-pinned-click.jsonl` | **never run** | — | — | — |
| `3b-ix-fast-path-ask-agent.jsonl` | **never run** | — | — | — |
| `3b-ix-fast-path-names-database.jsonl` | **never run** | — | — | — |
| `3b-ix-fast-path-open-file.jsonl` | **never run** | — | — | — |
| `3b-ix-fast-path-refused.jsonl` | **never run** | — | — | — |
| `3b-ix-fast-path-runs.jsonl` | **never run** | — | — | — |
| `3b-ix-fast-path-switch.jsonl` | **never run** | — | — | — |
| `3b-ix-fast-path-to-agent.jsonl` | **never run** | — | — | — |
| `3b-ix-quick-tasks-about.jsonl` | **never run** | — | — | — |
| `3b-v-click-focuses-pane.jsonl` | **never run** | — | — | — |
| `3b-v-editor-autosave-focus.jsonl` | **never run** | — | — | — |
| `3b-v-editor-autosave-pause.jsonl` | **never run** | — | — | — |
| `3b-v-editor-autosave-prompt-guard.jsonl` | **never run** | — | — | — |
| `3b-v-editor-indent-scratch.jsonl` | **never run** | — | — | — |
| `3b-v-editor-live-options.jsonl` | **never run** | — | — | — |
| `3b-v-editor-settings-nodes.jsonl` | **never run** | — | — | — |
| `3b-v-heavy-folders-edit.jsonl` | **never run** | — | — | — |
| `3b-v-heavy-folders-refusal.jsonl` | **never run** | — | — | — |
| `3b-v-heavy-folders.jsonl` | **never run** | — | — | — |
| `3b-v-project-editor-settings.jsonl` | **never run** | — | — | — |
| `3b-v-show-ignored.jsonl` | **never run** | — | — | — |
| `3b-vii-log-follow.jsonl` | **never run** | — | — | — |
| `3b-vii-log-tail.jsonl` | **never run** | — | — | — |
| `3b-viii-ghost-text-setting.jsonl` | **never run** | — | — | — |
| `3b-viii-ghost-unreachable-editor.jsonl` | **never run** | — | — | — |
| `3b-viii-ghost-unreachable-query-line.jsonl` | **never run** | — | — | — |
| `3b-viii-local-provider-add-focused.jsonl` | **never run** | — | — | — |
| `3b-viii-local-provider-add.jsonl` | **never run** | — | — | — |
| `3b-viii-local-provider-dispatch.jsonl` | **never run** | — | — | — |
| `3b-viii-local-provider-remove.jsonl` | **never run** | — | — | — |
| `3b-viii-quick-provider-unlinked.jsonl` | **never run** | — | — | — |
| `3b-viii-quick-provider.jsonl` | **never run** | — | — | — |
| `agent-pane-is-drawn.jsonl` | **never run** | — | — | — |
| `api-bind.jsonl` | **never run** | — | — | — |
| `api-body-editor.jsonl` | **never run** | — | — | — |
| `api-body-hole-cursor.jsonl` | **never run** | — | — | — |
| `api-bound-locks.jsonl` | **never run** | — | — | — |
| `api-cancel.jsonl` | **never run** | — | — | — |
| `api-chip-keys-second-chip.jsonl` | **never run** | — | — | — |
| `api-chip-keys-text-after.jsonl` | **never run** | — | — | — |
| `api-chip-keys.jsonl` | **never run** | — | — | — |
| `api-editor-copy-bound.jsonl` | **never run** | — | — | — |
| `api-editor-json-holes.jsonl` | **never run** | — | — | — |
| `api-editor-wrap.jsonl` | **never run** | — | — | — |
| `api-env-roundtrip.jsonl` | **never run** | — | — | — |
| `api-hole.jsonl` | **never run** | — | — | — |
| `api-one-author-focus.jsonl` | **never run** | — | — | — |
| `api-open.jsonl` | **never run** | — | — | — |
| `api-paste-curl-hotkey.jsonl` | **never run** | — | — | — |
| `api-paste-curl-refused.jsonl` | **never run** | — | — | — |
| `api-paste-curl-www.jsonl` | **never run** | — | — | — |
| `api-paste-curl.jsonl` | **never run** | — | — | — |
| `api-query-sync.jsonl` | **never run** | — | — | — |
| `api-recent-root.jsonl` | **never run** | — | — | — |
| `api-recent-shared.jsonl` | **never run** | — | — | — |
| `api-recent.jsonl` | **never run** | — | — | — |
| `api-reopen-cross-entry.jsonl` | **never run** | — | — | — |
| `api-rows.jsonl` | **never run** | — | — | — |
| `api-saved-as-typed.jsonl` | **never run** | — | — | — |
| `api-send-what-it-shows.jsonl` | **never run** | — | — | — |
| `api-send.jsonl` | **never run** | — | — | — |
| `api-set-request.jsonl` | **never run** | — | — | — |
| `api-surface.jsonl` | **never run** | — | — | — |
| `api-the-rest.jsonl` | **never run** | — | — | — |
| `api-type-keeps-holes.jsonl` | **never run** | — | — | — |
| `api-unbind.jsonl` | **never run** | — | — | — |
| `bg-env-switch-own-canvas.jsonl` | **never run** | — | — | — |
| `bg-org-switch-asks-nothing.jsonl` | **never run** | — | — | — |
| `bg-org-switch-keeps-the-terminal.jsonl` | **never run** | — | — | — |
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
| `journal-error-reason.jsonl` | **never run** | — | — | — |
| `landing.jsonl` | **never run** | — | — | — |
| `palette-api-entry.jsonl` | **never run** | — | — | — |
| `palette-api-send.jsonl` | **never run** | — | — | — |
| `palette-command-step.jsonl` | **never run** | — | — | — |
| `palette-escape.jsonl` | **never run** | — | — | — |
| `palette-modes.jsonl` | **never run** | — | — | — |
| `palette-open-kinds.jsonl` | **never run** | — | — | — |
| `palette-run-error.jsonl` | **never run** | — | — | — |
| `palette-switch-environment.jsonl` | **never run** | — | — | — |
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
| `3b-iii-changes-voice-hint.jsonl` | **never run** | — | — | — |
| `api-origin-after-account-switch.jsonl` | **never run** | — | — | — |
| `bg-agent-chip-more.jsonl` | **never run** | — | — | — |
| `bg-agent-chip-narrow.jsonl` | **never run** | — | — | — |
| `bg-agent-chip-over-landing.jsonl` | **never run** | — | — | — |
| `bg-agent-chip-return.jsonl` | **never run** | — | — | — |
| `both-surfaces.jsonl` | **never run** | — | — | — |
| `capacity-after-turn.jsonl` | **never run** | — | — | — |
| `two-enter.jsonl` | **never run** | — | — | — |

**`make e2e-new` saw every check this branch added go red against 91f64b7b89da.**

**Coverage is unknown**, so nothing here says whether the surface this branch added carries checks. Run `make e2e`, which ends in the gate.

```
the action denominator was observed against 7366af3c0cc2 and this tree is on 1f0899f0c459 — measured against the wrong build the gate cannot see an action this branch added, and would pass by being blind. Run `make e2e` to record the current one
```


<!-- /machine-walk -->
