# 3a-ii — git writes from the Changes view: acceptance

**Spec:** [`2026-10-21-3a-ii-git-writes-design.md`](../superpowers/specs/2026-10-21-3a-ii-git-writes-design.md)
· **Charter:** Invariant 6 (the sixth write), Decision 43; Decision 40's last sentence

The exit criterion, from the spec: in the Changes view (⌘⇧G) the operator stages, unstages,
discards and commits each root, amends and undoes the last commit, and stages one change from the
gutter peek, all without a dialog. Every commit from Wakil carries the organisation's git name and
email from Settings → Organisation → Git, and `git log` in a terminal shows it.

Nothing here is walked yet: the Walked column is empty until the operator ticks it.

## 0. Setup

Run this in the repo root, on this Mac, after `make build` and `make app-bundle`. It is safe to
re-run.

```bash
(
set -e
ORG=personal
W="$TMPDIR/walk-3a-ii"
rm -rf "$W"
mkdir -p "$W/api" "$W/hooked" "$W/project"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
g() { git -c user.name=seed -c user.email=seed@example.com "$@"; }
cd "$W/api" && git init -q -b main
printf 'one\ntwo\nthree\nfour\nfive\nsix\nseven\n' > confirm.go
echo 'api' > README.md
git add . && g commit -qm seed
git config user.email walk-config@example.com
git config user.name 'Walk Config'
printf 'ONE\ntwo\nthree\nfour\nfive\nsix\nSEVEN\n' > confirm.go
echo 'notes' > notes
echo 'scratch' > scratch.txt
cd "$W/hooked" && git init -q -b main
echo 'hooked' > index.txt
git add . && g commit -qm seed
echo 'hooked, edited' > index.txt
cat > .git/hooks/pre-commit <<'H'
#!/bin/sh
if [ -e .git/SLOW ]; then sleep 120; fi
if [ -e .git/BLOCK ]; then echo 'walk hook: BLOCK is present, refusing' >&2; exit 1; fi
H
chmod +x .git/hooks/pre-commit
cat > "$W/project/project.json" <<J
{"name":"walk-3a-ii","org":"$ORG","roots":[{"path":"$W/api"},{"path":"$W/hooked"}],"scopes":{},"environments":{}}
J
cd ~/Desktop/scripts/wakil-public
./bin/wakil project rm walk-3a-ii --org "$ORG" || true
./bin/wakil project add walk-3a-ii --path "$W/project/project.json" --org "$ORG"
)
```

`api` has a repository-local identity (`walk-config@example.com`), two separate changes in
`confirm.go`, and two untracked files. `hooked` has a pre-commit hook that refuses while a file
named `.git/BLOCK` exists and sleeps two minutes while `.git/SLOW` does (inside `.git`, so
neither is ever staged). Clear Settings →
Organisation → Git Name and Email in `personal` before row 1 if an earlier walk set them.

Launch with
`cd ~/Desktop/scripts/wakil-public && WAKIL_ORG=personal app/Wakil.app/Contents/MacOS/Wakil`, make
`walk-3a-ii` active with ⌘P, and open an editor pane. Keep a Terminal window open for rows 15, 16
and 20.

## 1. The walk

Walk in order, on `walk-3a-ii`, in `personal`.

| # | Do | Expect | Walked |
|---|---|---|---|
| 1 | Press ⌘⇧G | Each root with changes has a message box, a **Commit** bar the box's width (disabled while the box is empty) with a **▾** at its right edge; a clean root is one line. `api`'s box reads `Message · as walk-config@example.com (from git config) (⌘⏎)`; `hooked`'s reads `Message (⌘⏎ to commit)` (no identity anywhere) | |
| 2 | ⌘, → Organisation → **GIT**: type Name `Walk Org`, press Tab, type Email `walk-org@example.com`, click the Display name field. Close Settings, press ⌘B then ⌘⇧G | Both fields keep what was typed and are saved without Return or Save (reopen Settings: they are there). Both roots' boxes read `Message · as walk-org@example.com (⌘⏎)` | |
| 3 | Hover a row under **Changes**, then one under **Untracked**, then a group header | **+** and **↺** on Changes and Untracked rows; the header carries them for the whole group. Click a row: its buttons stay while it is highlighted | |
| 4 | Press **+** on `notes` | `notes` moves to **Staged** as `A` and stays highlighted (Rule 6); the Files tree's letter for it changes at the same time. The button now reads **Commit** | |
| 5 | Press **−** on `notes` under Staged, then **+** again | It goes back to Untracked, then to Staged; no dialog either way | |
| 6 | In `api`'s box type `walk: first`, press ⌘⏎ | `notes` leaves the list; the box empties. The other rows stay | |
| 7 | Click the empty box, press ↑, then ↓ | ↑ shows `walk: first`; ↓ empties the box. Typing after ↑ edits a new message | |
| 8 | Press ↺ on `scratch.txt` (untracked) | It leaves the list with no dialog; Finder's Trash holds `scratch.txt`, and Put Back restores it | |
| 9 | Open `confirm.go` from the tree. Click the gutter mark on line 1; in the peek press **Stage** | `confirm.go` shows under both **Staged** and **Changes**; line 1's mark is gone and line 7's stays | |
| 10 | With nothing typed, ▾ → **Amend Last Commit** | No dialog. In Terminal, `git -C "$TMPDIR/walk-3a-ii/api" log -1 --format=%s` still prints `walk: first`, and `git -C "$TMPDIR/walk-3a-ii/api" show --stat HEAD` lists `confirm.go` | |
| 11 | ▾ → **Undo Last Commit** | The box holds `walk: first`; `notes` and `confirm.go` are back under Staged | |
| 12 | ▾ → **Undo Last Commit** again | Under the box, whole: `nothing to undo: this is the first commit`. The box keeps its text | |
| 13 | With the box still holding `walk: first`, press **Commit** | The staged files leave the list; `confirm.go` stays under Changes (line 7) | |
| 14 | Press ↺ on `confirm.go` under Changes | It leaves the list, no dialog; Finder's Trash holds `confirm.go (discarded HH:MM)` with today's time; the open tab shows line 7 as `seven` again, and its gutter mark is gone | |
| 15 | In Terminal, `touch "$TMPDIR/walk-3a-ii/hooked/.git/BLOCK"`. In `hooked`'s box type `walk: blocked`, press **Commit All** | Under the box, whole, in amber: the hook's `walk hook: BLOCK is present, refusing`. `walk: blocked` is still in the box | |
| 16 | `rm "$TMPDIR/walk-3a-ii/hooked/.git/BLOCK"; touch "$TMPDIR/walk-3a-ii/hooked/.git/SLOW"`, then press **Commit** | A spinner and **Cancel** replace the button; **▾** and the row buttons are disabled. Press **Cancel**: the button comes back, the message is kept, nothing is committed | |
| 17 | Type a message in `hooked`'s box, press ⌘B, then ⌘⇧G | The message is still there (Rule 2) | |
| 18 | `rm "$TMPDIR/walk-3a-ii/hooked/.git/SLOW"`. Hold ⌥ and say "commit everything in hooked as walk voice", release, Return | An agent turn calls `editor_changes_commit`; `hooked` reads `· clean` with no confirmation asked | |
| 19 | In the composer: `stage scratch.txt in api`, Return | The agent calls `editor_changes_stage`; `scratch.txt` (back from row 8's Put Back) moves to Staged as row 4's `notes` did | |
| 20 | In Terminal: `git -C "$TMPDIR/walk-3a-ii/api" log -3 --format='%an <%ae> %s'` and `git -C "$TMPDIR/walk-3a-ii/hooked" log -2 --format='%an <%ae> %s'` | Every commit made from Wakil reads `Walk Org <walk-org@example.com> …`; only `seed` reads `seed <seed@example.com>` | |

## 2. Known and not fixed

- **The agent's own shell commits under git config.** A `git commit` the agent runs in its
  terminal or harness uses the repository's or the global identity, not Settings → Organisation →
  Git; only the `editor_changes_*` actions carry the organisation's.
- **Drafts do not survive a relaunch** (ruling R3). The message box keeps its text across views
  and org switches; quitting Wakil loses it, and the ↑ history with it.

**Found by the e2e checks, not yet ruled on** (each is in the 3a-ii build report):

- Cancelling a commit shows `editor_changes_commit: CancellationError()` under the box.
- A **Commit All** a hook refuses leaves every file staged: `git add -A` ran before the hook.
- Unstaging a path that is untracked (`editor_changes_unstage` on `notes` once it is back under Untracked)
  is git's refusal, not the no-op Rule 7 asks for.
- ⌘⇧G gives the keyboard to the list, not to the message box (spec Rule 3).
- After a Settings save the hint changes only once the Changes view is shown again (row 2's ⌘B).

## 3. Residue: what the walk cannot establish

- **Signing.** A repository with `commit.gpgsign` and a pinentry asks for its passphrase as it
  does for VS Code; the walk's repositories do not sign, so that prompt is not seen.
- **The Trash's names** (rows 8 and 14) are pinned by `internal/wakilcore` tests; no e2e check
  reads Finder's Trash.
- **Stage's button** (the peek's) is HTML inside Monaco's web view, which the harness cannot press; the
  checks dispatch `editor_changes_stage_hunk` and row 9 presses it.
- **The button's label** (Commit vs Commit All) is not in the accessibility tree the checks read;
  rows 4 and 15 see it.
- **Hover** shows the row and group buttons; the checks reach them by highlighting a row, so
  row 3's hover is walk-only.
- **Voice** (row 18) and the agent's choice of action (row 19) run a real provider and cost
  quota; the checks dispatch the same actions on the agent's socket.

## 4. The machine walk

<!-- machine-walk: generated by `make e2e-runbook`; everything between these markers is overwritten -->

**The machine walk is red** — 197 condition(s) of the Cover rung are not met:

```
e2e/checks/unseeded/org-plane.jsonl was run against bbfc8cf83317 and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/2c-iii-1-bundle-path.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/2c-iii-2-block.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/2c-iii-3-live-prompt.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/2c-iii-4-interrupt.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/2c-iii-5-full-screen.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/2c-iii-6-no-orphan.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/2c-iii-7-org-switch.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/2d-ii-composer-keeps-input.jsonl was run against 3a764b4f6811 and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/2d-ii-composer-return-sends.jsonl was run against 3a764b4f6811 and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/2d-ii-settings-speech.jsonl was run against 3a764b4f6811 and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/2d-ii-voice-escape.jsonl was run against 3a764b4f6811 and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/2d-ii-voice-lands-focused.jsonl was run against 3a764b4f6811 and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/2d-ii-voice-lands-unsent.jsonl was run against 3a764b4f6811 and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/2d-ii-voice-second-hold.jsonl was run against 3a764b4f6811 and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/2d-ii-voice-silence.jsonl was run against 3a764b4f6811 and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/2e-settings-databases-dispatch.jsonl was run against bbfc8cf83317 and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/2e-settings-databases.jsonl was run against bbfc8cf83317 and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/2e-settings-doors.jsonl was run against bbfc8cf83317 and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/2e-settings-narrow-rows.jsonl was run against bbfc8cf83317 and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/2e-settings-organisation.jsonl was run against bbfc8cf83317 and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/2e-settings-pane.jsonl was run against bbfc8cf83317 and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/2e-settings-unlink-indicator.jsonl was run against bbfc8cf83317 and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/2e-settings-unlink.jsonl was run against bbfc8cf83317 and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/365-terminal-option-word.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/365-terminal-paste.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/365-terminal-select-backspace.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/365-terminal-select-type.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3a-ii-commit-all.jsonl was run against 3a764b4f6811 and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3a-ii-commit.jsonl was run against 3a764b4f6811 and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3a-ii-discard.jsonl was run against 3a764b4f6811 and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3a-ii-hook-fails.jsonl was run against 3a764b4f6811 and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3a-ii-identity.jsonl was run against 3a764b4f6811 and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3a-ii-message-box.jsonl was run against 3a764b4f6811 and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3a-ii-settings-tree-collapse.jsonl was run against 3a764b4f6811 and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3a-ii-stage-change.jsonl was run against 3a764b4f6811 and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3a-ii-undo.jsonl was run against 3a764b4f6811 and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
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
e2e/checks/seeded/3b-iii-changes-drill.jsonl was run against 3a764b4f6811 and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-iii-changes-keys.jsonl was run against 3a764b4f6811 and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-iii-changes-list.jsonl was run against 3a764b4f6811 and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-iii-changes-live.jsonl was run against 3a764b4f6811 and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-iii-changes-press.jsonl was run against 3a764b4f6811 and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-iii-diff-open-file.jsonl was run against 9912fad1ff30 and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-iii-diff-refusals.jsonl was run against 9912fad1ff30 and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-iii-git-pane-migrates.jsonl was run against bbfc8cf83317 and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-iii-palette-changed-file.jsonl was run against 9912fad1ff30 and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-iii-peek.jsonl was run against bbfc8cf83317 and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-iii-tree-letters.jsonl was run against 9912fad1ff30 and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-iv-create-file.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-iv-create-folder.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-iv-name-refused.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-iv-rename-tabs.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-iv-trash-key.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-iv-trash-selection.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-iv-trash-tabs.jsonl was run against bbfc8cf83317 and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-iv-tree-pinned-click.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-ix-fast-path-ask-agent.jsonl was run against bbfc8cf83317 and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-ix-fast-path-names-database.jsonl was run against bbfc8cf83317 and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-ix-fast-path-open-file.jsonl was run against bbfc8cf83317 and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-ix-fast-path-refused.jsonl was run against bbfc8cf83317 and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-ix-fast-path-runs.jsonl was run against bbfc8cf83317 and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-ix-fast-path-switch.jsonl was run against bbfc8cf83317 and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-ix-fast-path-to-agent.jsonl was run against bbfc8cf83317 and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-ix-quick-tasks-about.jsonl was run against bbfc8cf83317 and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
.scratch/settings-redesign/seeded/3b-v-click-focuses-pane.jsonl was run against c426bc129ca6 and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-v-editor-autosave-focus.jsonl was run against 2815327da8bc and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-v-editor-autosave-pause.jsonl was run against 2815327da8bc and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-v-editor-autosave-prompt-guard.jsonl was run against c426bc129ca6 and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-v-editor-indent-scratch.jsonl was run against 2815327da8bc and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-v-editor-live-options.jsonl was run against 2815327da8bc and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-v-editor-settings-nodes.jsonl was run against 2815327da8bc and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-v-heavy-folders-edit.jsonl was run against c426bc129ca6 and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-v-heavy-folders-refusal.jsonl was run against 2815327da8bc and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-v-heavy-folders.jsonl was run against 2815327da8bc and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-v-project-editor-settings.jsonl was run against 2815327da8bc and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-v-show-ignored.jsonl was run against 2815327da8bc and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-vii-log-follow.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-vii-log-tail.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/3b-viii-ghost-text-setting.jsonl was run against bbfc8cf83317 and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-viii-ghost-unreachable-editor.jsonl was run against bbfc8cf83317 and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-viii-ghost-unreachable-query-line.jsonl was run against bbfc8cf83317 and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-viii-local-provider-add-focused.jsonl was run against bbfc8cf83317 and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-viii-local-provider-add.jsonl was run against bbfc8cf83317 and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-viii-local-provider-dispatch.jsonl was run against bbfc8cf83317 and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-viii-local-provider-remove.jsonl was run against bbfc8cf83317 and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-viii-quick-provider-unlinked.jsonl was run against bbfc8cf83317 and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-viii-quick-provider.jsonl was run against bbfc8cf83317 and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
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
e2e/checks/seeded/capacity-low-reading.jsonl was run against bbfc8cf83317 and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/capacity-passed-reset.jsonl was run against bbfc8cf83317 and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
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
e2e/checks/agent/api-origin-after-account-switch.jsonl was run against bbfc8cf83317 and this tree is on 71a133cd32bc — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/agent/bg-agent-chip-more.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/agent/bg-agent-chip-narrow.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/agent/bg-agent-chip-over-landing.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/agent/bg-agent-chip-return.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/agent/both-surfaces.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/agent/capacity-after-turn.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/agent/two-enter.jsonl was never run against this build, so nothing is known about it — run `make e2e`
the run itself is unsound, so nothing it reports is evidence:
  3a-ii-discard.jsonl failed, and keyboard or pointer input the harness did not post arrived during 3a-ii-discard.jsonl step 3: 50 mouseMoved from a device (pid 0) — the act may have been delivered outside the fixture, so the check's result is not evidence about this build
  3a-ii-discard.jsonl failed, and keyboard or pointer input the harness did not post arrived during 3a-ii-discard.jsonl step 8: 1 leftMouseUp from a device (pid 0), 14 mouseMoved from a device (pid 0) — the act may have been delivered outside the fixture, so the check's result is not evidence about this build
coverage could not be computed, so nothing here says whether the surface this branch added carries checks: the action denominator was observed against 3a764b4f6811 and this tree is on 71a133cd32bc — measured against the wrong build the gate cannot see an action this branch added, and would pass by being blind. Run `make e2e` to record the current one
```

Walked by `make e2e` against 71a133cd32bc, rendered 2026-10-22 08:30 UTC by `make e2e-runbook`. Re-render it with that target; edits between the markers are overwritten.

| Check | `make e2e` | Red against the base | Assertions | Evidence |
|---|---|---|---|---|
| `org-plane.jsonl` | **another build** (bbfc8cf83317) | — | — | — |
| `2c-iii-1-bundle-path.jsonl` | **never run** | — | — | — |
| `2c-iii-2-block.jsonl` | **never run** | — | — | — |
| `2c-iii-3-live-prompt.jsonl` | **never run** | — | — | — |
| `2c-iii-4-interrupt.jsonl` | **never run** | — | — | — |
| `2c-iii-5-full-screen.jsonl` | **never run** | — | — | — |
| `2c-iii-6-no-orphan.jsonl` | **never run** | — | — | — |
| `2c-iii-7-org-switch.jsonl` | **never run** | — | — | — |
| `2d-ii-composer-keeps-input.jsonl` | **another build** (3a764b4f6811) | — | — | — |
| `2d-ii-composer-return-sends.jsonl` | **another build** (3a764b4f6811) | — | — | — |
| `2d-ii-settings-speech.jsonl` | **another build** (3a764b4f6811) | — | — | — |
| `2d-ii-voice-escape.jsonl` | **another build** (3a764b4f6811) | — | — | — |
| `2d-ii-voice-lands-focused.jsonl` | **another build** (3a764b4f6811) | — | — | — |
| `2d-ii-voice-lands-unsent.jsonl` | **another build** (3a764b4f6811) | — | — | — |
| `2d-ii-voice-second-hold.jsonl` | **another build** (3a764b4f6811) | — | — | — |
| `2d-ii-voice-silence.jsonl` | **another build** (3a764b4f6811) | — | — | — |
| `2e-settings-databases-dispatch.jsonl` | **another build** (bbfc8cf83317) | — | — | — |
| `2e-settings-databases.jsonl` | **another build** (bbfc8cf83317) | — | — | — |
| `2e-settings-doors.jsonl` | **another build** (bbfc8cf83317) | — | — | — |
| `2e-settings-narrow-rows.jsonl` | **another build** (bbfc8cf83317) | — | — | — |
| `2e-settings-organisation.jsonl` | **another build** (bbfc8cf83317) | — | — | — |
| `2e-settings-pane.jsonl` | **another build** (bbfc8cf83317) | — | — | — |
| `2e-settings-unlink-indicator.jsonl` | **another build** (bbfc8cf83317) | — | — | — |
| `2e-settings-unlink.jsonl` | **another build** (bbfc8cf83317) | — | — | — |
| `365-terminal-option-word.jsonl` | **never run** | — | — | — |
| `365-terminal-paste.jsonl` | **never run** | — | — | — |
| `365-terminal-select-backspace.jsonl` | **never run** | — | — | — |
| `365-terminal-select-type.jsonl` | **never run** | — | — | — |
| `3a-ii-commit-all.jsonl` | **another build** (3a764b4f6811) | — | — | — |
| `3a-ii-commit.jsonl` | **another build** (3a764b4f6811) | — | — | — |
| `3a-ii-discard.jsonl` | **another build** (3a764b4f6811) | — | — | — |
| `3a-ii-hook-fails.jsonl` | **another build** (3a764b4f6811) | — | — | — |
| `3a-ii-identity.jsonl` | **another build** (3a764b4f6811) | — | — | — |
| `3a-ii-message-box.jsonl` | **another build** (3a764b4f6811) | — | — | — |
| `3a-ii-settings-tree-collapse.jsonl` | **another build** (3a764b4f6811) | — | — | — |
| `3a-ii-stage-change.jsonl` | **another build** (3a764b4f6811) | — | — | — |
| `3a-ii-undo.jsonl` | **another build** (3a764b4f6811) | — | — | — |
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
| `3b-iii-changes-drill.jsonl` | **another build** (3a764b4f6811) | — | — | — |
| `3b-iii-changes-keys.jsonl` | **another build** (3a764b4f6811) | — | — | — |
| `3b-iii-changes-list.jsonl` | **another build** (3a764b4f6811) | — | — | — |
| `3b-iii-changes-live.jsonl` | **another build** (3a764b4f6811) | — | — | — |
| `3b-iii-changes-press.jsonl` | **another build** (3a764b4f6811) | — | — | — |
| `3b-iii-diff-open-file.jsonl` | **another build** (9912fad1ff30) | — | — | — |
| `3b-iii-diff-refusals.jsonl` | **another build** (9912fad1ff30) | — | — | — |
| `3b-iii-git-pane-migrates.jsonl` | **another build** (bbfc8cf83317) | — | — | — |
| `3b-iii-palette-changed-file.jsonl` | **another build** (9912fad1ff30) | — | — | — |
| `3b-iii-peek.jsonl` | **another build** (bbfc8cf83317) | — | — | — |
| `3b-iii-tree-letters.jsonl` | **another build** (9912fad1ff30) | — | — | — |
| `3b-iv-create-file.jsonl` | **never run** | — | — | — |
| `3b-iv-create-folder.jsonl` | **never run** | — | — | — |
| `3b-iv-name-refused.jsonl` | **never run** | — | — | — |
| `3b-iv-rename-tabs.jsonl` | **never run** | — | — | — |
| `3b-iv-trash-key.jsonl` | **never run** | — | — | — |
| `3b-iv-trash-selection.jsonl` | **never run** | — | — | — |
| `3b-iv-trash-tabs.jsonl` | **another build** (bbfc8cf83317) | — | — | — |
| `3b-iv-tree-pinned-click.jsonl` | **never run** | — | — | — |
| `3b-ix-fast-path-ask-agent.jsonl` | **another build** (bbfc8cf83317) | — | — | — |
| `3b-ix-fast-path-names-database.jsonl` | **another build** (bbfc8cf83317) | — | — | — |
| `3b-ix-fast-path-open-file.jsonl` | **another build** (bbfc8cf83317) | — | — | — |
| `3b-ix-fast-path-refused.jsonl` | **another build** (bbfc8cf83317) | — | — | — |
| `3b-ix-fast-path-runs.jsonl` | **another build** (bbfc8cf83317) | — | — | — |
| `3b-ix-fast-path-switch.jsonl` | **another build** (bbfc8cf83317) | — | — | — |
| `3b-ix-fast-path-to-agent.jsonl` | **another build** (bbfc8cf83317) | — | — | — |
| `3b-ix-quick-tasks-about.jsonl` | **another build** (bbfc8cf83317) | — | — | — |
| `3b-v-click-focuses-pane.jsonl` | **another build** (c426bc129ca6) | — | — | — |
| `3b-v-editor-autosave-focus.jsonl` | **another build** (2815327da8bc) | — | — | — |
| `3b-v-editor-autosave-pause.jsonl` | **another build** (2815327da8bc) | — | — | — |
| `3b-v-editor-autosave-prompt-guard.jsonl` | **another build** (c426bc129ca6) | — | — | — |
| `3b-v-editor-indent-scratch.jsonl` | **another build** (2815327da8bc) | — | — | — |
| `3b-v-editor-live-options.jsonl` | **another build** (2815327da8bc) | — | — | — |
| `3b-v-editor-settings-nodes.jsonl` | **another build** (2815327da8bc) | — | — | — |
| `3b-v-heavy-folders-edit.jsonl` | **another build** (c426bc129ca6) | — | — | — |
| `3b-v-heavy-folders-refusal.jsonl` | **another build** (2815327da8bc) | — | — | — |
| `3b-v-heavy-folders.jsonl` | **another build** (2815327da8bc) | — | — | — |
| `3b-v-project-editor-settings.jsonl` | **another build** (2815327da8bc) | — | — | — |
| `3b-v-show-ignored.jsonl` | **another build** (2815327da8bc) | — | — | — |
| `3b-vii-log-follow.jsonl` | **never run** | — | — | — |
| `3b-vii-log-tail.jsonl` | **never run** | — | — | — |
| `3b-viii-ghost-text-setting.jsonl` | **another build** (bbfc8cf83317) | — | — | — |
| `3b-viii-ghost-unreachable-editor.jsonl` | **another build** (bbfc8cf83317) | — | — | — |
| `3b-viii-ghost-unreachable-query-line.jsonl` | **another build** (bbfc8cf83317) | — | — | — |
| `3b-viii-local-provider-add-focused.jsonl` | **another build** (bbfc8cf83317) | — | — | — |
| `3b-viii-local-provider-add.jsonl` | **another build** (bbfc8cf83317) | — | — | — |
| `3b-viii-local-provider-dispatch.jsonl` | **another build** (bbfc8cf83317) | — | — | — |
| `3b-viii-local-provider-remove.jsonl` | **another build** (bbfc8cf83317) | — | — | — |
| `3b-viii-quick-provider-unlinked.jsonl` | **another build** (bbfc8cf83317) | — | — | — |
| `3b-viii-quick-provider.jsonl` | **another build** (bbfc8cf83317) | — | — | — |
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
| `capacity-low-reading.jsonl` | **another build** (bbfc8cf83317) | — | — | — |
| `capacity-passed-reset.jsonl` | **another build** (bbfc8cf83317) | — | — | — |
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
| `api-origin-after-account-switch.jsonl` | **another build** (bbfc8cf83317) | — | — | — |
| `bg-agent-chip-more.jsonl` | **never run** | — | — | — |
| `bg-agent-chip-narrow.jsonl` | **never run** | — | — | — |
| `bg-agent-chip-over-landing.jsonl` | **never run** | — | — | — |
| `bg-agent-chip-return.jsonl` | **never run** | — | — | — |
| `both-surfaces.jsonl` | **never run** | — | — | — |
| `capacity-after-turn.jsonl` | **never run** | — | — | — |
| `two-enter.jsonl` | **never run** | — | — | — |
| `.scratch/settings-redesign/base-click.jsonl` | — | — | — | a record for a check the corpus no longer holds |
| `.scratch/settings-redesign/seeded/3b-v-click-focuses-pane.jsonl` | — | — | — | a record for a check the corpus no longer holds |
| `.scratch/settings-redesign/seeded/a-fast-path-runs.jsonl` | — | — | — | a record for a check the corpus no longer holds |
| `.scratch/settings-redesign/seeded/b-click.jsonl` | — | — | — | a record for a check the corpus no longer holds |
| `.scratch/settings-redesign/seeded/head-click.jsonl` | — | — | — | a record for a check the corpus no longer holds |
| `.scratch/settings-redesign/seeded/probe-click.jsonl` | — | — | — | a record for a check the corpus no longer holds |
| `e2e/checks/seeded/zz-probe.jsonl` | — | — | — | a record for a check the corpus no longer holds |
| `e2e/checks/seeded/zz-shot-1-changes.jsonl` | — | — | — | a record for a check the corpus no longer holds |
| `e2e/checks/seeded/zz-shot-2-menu.jsonl` | — | — | — | a record for a check the corpus no longer holds |
| `e2e/checks/seeded/zz-shot-3-hook.jsonl` | — | — | — | a record for a check the corpus no longer holds |
| `e2e/checks/seeded/zz-shot-4-peek.jsonl` | — | — | — | a record for a check the corpus no longer holds |
| `e2e/checks/seeded/zz-shot-5-settings-org.jsonl` | — | — | — | a record for a check the corpus no longer holds |
| `e2e/checks/seeded/zz-shot-5-settings.jsonl` | — | — | — | a record for a check the corpus no longer holds |
| `e2e/checks/seeded/zz-shot-6-settings-tree.jsonl` | — | — | — | a record for a check the corpus no longer holds |
| `e2e/checks/seeded/zz-shot-7-settings-providers.jsonl` | — | — | — | a record for a check the corpus no longer holds |
| `e2e/checks/seeded/zz-shot-providers.jsonl` | — | — | — | a record for a check the corpus no longer holds |

**`make e2e-new` did not prove every new check failable:**

```
the run itself is unsound, so nothing it reports is evidence:
  3a-ii-discard.jsonl failed, and keyboard or pointer input the harness did not post arrived during 3a-ii-discard.jsonl step 3: 50 mouseMoved from a device (pid 0) — the act may have been delivered outside the fixture, so the check's result is not evidence about this build
  3a-ii-discard.jsonl failed, and keyboard or pointer input the harness did not post arrived during 3a-ii-discard.jsonl step 8: 1 leftMouseUp from a device (pid 0), 14 mouseMoved from a device (pid 0) — the act may have been delivered outside the fixture, so the check's result is not evidence about this build
```

**Coverage is unknown**, so nothing here says whether the surface this branch added carries checks. Run `make e2e`, which ends in the gate.

```
the action denominator was observed against 3a764b4f6811 and this tree is on 71a133cd32bc — measured against the wrong build the gate cannot see an action this branch added, and would pass by being blind. Run `make e2e` to record the current one
```


<!-- /machine-walk -->
